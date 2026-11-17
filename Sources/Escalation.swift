import AppKit
import AVFoundation

/// Decides when repeated alerts should escalate to a screen blur or a spoken reminder.
/// Time is passed in, so tests can drive it with a fake clock.
struct EscalationTracker {
    struct Decision: Equatable {
        var blur = false
        var speak = false
        /// Alerts for this habit in the look-back window, including this one.
        var sameCount = 0
        /// Alerts of any kind in the look-back window.
        var totalCount = 0
        /// True when the mix of habits, not one habit alone, crossed the limit.
        var combined = false
    }

    private var alerts: [(t: Double, kind: AlertKind)] = []
    private var lastSpeech = -Double.infinity

    /// Alerts per habit still inside the look-back window, without recording anything.
    func counts(now: Double, settings: Settings) -> [AlertKind: Int] {
        let window = settings.escalationWindowMinutes * 60
        var result: [AlertKind: Int] = [:]
        for alert in alerts where now - alert.t <= window { result[alert.kind, default: 0] += 1 }
        return result
    }

    mutating func record(_ kind: AlertKind, now: Double, settings: Settings) -> Decision {
        let window = settings.escalationWindowMinutes * 60
        alerts.append((now, kind))
        alerts.removeAll { now - $0.t > window }

        var d = Decision()
        d.sameCount = alerts.filter { $0.kind == kind }.count
        d.totalCount = alerts.count
        let sameDue = d.sameCount >= settings.blurAfter
        let combinedDue = d.totalCount >= settings.combinedAfter
        d.combined = combinedDue && !sameDue
        d.blur = settings.blurEnabled && (sameDue || combinedDue)

        let speakDue = d.sameCount >= settings.speakAfter || d.totalCount >= settings.combinedAfter + 2
        if settings.speakEnabled, speakDue, now - lastSpeech >= settings.speakCooldownMinutes * 60 {
            d.speak = true
            lastSpeech = now
        }
        return d
    }

    /// What the spoken reminder says: plain facts, then the usual calm instruction.
    static func sentence(for kind: AlertKind, decision d: Decision, minutes: Int, competingResponse: String) -> String {
        let span = minutes == 1 ? "the last minute" : "the last \(minutes) minutes"
        if d.combined {
            return "\(d.totalCount) nudges in \(span). Take a slow breath and settle."
        }
        let n = d.sameCount
        switch kind {
        case .smile:
            return "\(n) stretched smiles in \(span). \(competingResponse)"
        case .lookAway:
            return "\(n) look-aways in \(span). Back to the screen."
        case .overActive:
            return "Moving a lot, \(n) times in \(span). Slow down and settle."
        case .handsAtFace:
            return "Hands at your face \(n) times in \(span). Hands down."
        }
    }
}

/// Runs escalations: the screen blur and spoken reminders. Main thread only.
final class EscalationCenter {
    static let shared = EscalationCenter()

    private var tracker = EscalationTracker()
    private let synthesizer = AVSpeechSynthesizer()
    private let blur = BlurOverlay()

    /// Called for every real alert. Quiet mode (calls, quiet hour) never escalates.
    func alertFired(_ kind: AlertKind, quiet: Bool) {
        let settings = AppState.shared.settings
        guard !quiet else { return }
        let d = tracker.record(kind, now: monotonicNow(), settings: settings)
        if d.blur {
            blur.show(kind: kind, strength: settings.blurStrength, seconds: settings.blurSeconds)
            EventLog.shared.add(.alert, kind, d.combined ? "Screen blur, \(d.totalCount) alerts of any kind" : "Screen blur, \(d.sameCount) in a row")
        }
        if d.speak {
            let text = EscalationTracker.sentence(for: kind, decision: d, minutes: Int(settings.escalationWindowMinutes),
                                                  competingResponse: settings.competingResponse)
            if settings.speakOnlyWithHeadphones && !AudioOutput.isHeadphones {
                EventLog.shared.add(.suppressed, kind, "Spoken reminder skipped, no headphones connected")
            } else {
                speak(text)
                EventLog.shared.add(.alert, kind, "Spoken reminder: \(text)")
            }
        }
    }

    /// Current alert counts in the look-back window, for the tolerance meter.
    func currentCounts() -> [AlertKind: Int] {
        tracker.counts(now: monotonicNow(), settings: AppState.shared.settings)
    }

    /// Clears the blur as soon as the habit that caused it stops.
    func episodeEnded(_ kind: AlertKind) {
        blur.hide(ifCausedBy: kind)
    }

    func testBlur() {
        let settings = AppState.shared.settings
        blur.show(kind: .smile, strength: settings.blurStrength, seconds: min(settings.blurSeconds, 3))
    }

    /// Plays a sample reminder. It always plays, because it is started on purpose.
    func testVoice() {
        let d = EscalationTracker.Decision(sameCount: 5, totalCount: 5)
        let settings = AppState.shared.settings
        speak(EscalationTracker.sentence(for: .smile, decision: d, minutes: Int(settings.escalationWindowMinutes),
                                         competingResponse: settings.competingResponse))
    }

    private func speak(_ text: String) {
        let settings = AppState.shared.settings
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = settings.voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Self.automaticVoice()
        utterance.volume = Float(settings.speechVolume)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        synthesizer.speak(utterance)
    }

    /// Natural-sounding voices installed on this Mac: best quality first, female voices first within a quality.
    static func voices() -> [AVSpeechSynthesisVoice] {
        let language = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int) { (v.quality.rawValue, v.gender == .female ? 1 : 0) }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.identifier.hasPrefix("com.apple.voice.") && $0.language.hasPrefix(language) }
            .sorted { a, b in rank(a) != rank(b) ? rank(a) > rank(b) : a.name < b.name }
    }

    /// The best installed female voice, or the best voice if no female voice is installed.
    static func automaticVoice() -> AVSpeechSynthesisVoice? {
        let all = voices()
        return all.first { $0.gender == .female } ?? all.first
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }
}

/// A light, click-through blur over every screen.
final class BlurOverlay {
    private final class BlurWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var windows: [BlurWindow] = []
    private var cause: AlertKind?
    private var shownAt = Date.distantPast
    private var generation = 0

    func show(kind: AlertKind, strength: Double, seconds: Double) {
        rebuildWindowsIfNeeded()
        cause = kind
        shownAt = Date()
        generation += 1
        let current = generation
        for w in windows {
            if !w.isVisible { w.alphaValue = 0 }
            w.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            for w in windows { w.animator().alphaValue = CGFloat(max(0.1, min(1, strength))) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == current else { return }
            self.fadeOut()
        }
    }

    /// Hides the blur early when its habit stops, but keeps it at least 1.5 seconds so it registers.
    func hide(ifCausedBy kind: AlertKind) {
        guard cause == kind, windows.contains(where: \.isVisible) else { return }
        let wait = max(0, 1.5 - Date().timeIntervalSince(shownAt))
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.generation == current else { return }
            self.fadeOut()
        }
    }

    private func fadeOut() {
        cause = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.8
            for w in self.windows { w.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard let self, self.cause == nil else { return }
            for w in self.windows { w.orderOut(nil) }
        })
    }

    private func rebuildWindowsIfNeeded() {
        let screens = NSScreen.screens
        if windows.count == screens.count, zip(windows, screens).allSatisfy({ $0.frame == $1.frame }) { return }
        windows.forEach { $0.orderOut(nil) }
        windows = screens.map { screen in
            let w = BlurWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            // Just below the alert glow, so the glow and its label stay sharp on top of the blur.
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            effect.blendingMode = .behindWindow
            effect.material = .fullScreenUI
            effect.state = .active
            effect.autoresizingMask = [.width, .height]
            w.contentView = effect
            w.setFrame(screen.frame, display: false)
            return w
        }
    }
}
