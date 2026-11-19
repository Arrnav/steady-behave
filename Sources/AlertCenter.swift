import AppKit
import Foundation

/// Shows a nudge: edge glow, menu bar icon flash, sound and trackpad haptic. Main thread only.
final class AlertCenter: NSObject, NSSoundDelegate {
    static let shared = AlertCenter()

    /// Sounds are kept here until they finish, so none is released while still playing.
    private var playing: [NSSound] = []

    /// A short stretch of silence. Bluetooth headphones idle when nothing plays and need a moment to wake,
    /// which swallows most of a short alert sound; playing this first wakes them.
    static let wakeSilence: NSSound? = {
        let sampleRate = 44_100, seconds = 0.4
        let samples = Int(Double(sampleRate) * seconds)
        let dataBytes = samples * 2
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
        wav.append(Data(count: dataBytes))
        return NSSound(data: wav)
    }()

    /// Set by the status bar controller to flash the menu bar icon.
    var onFlash: ((AlertKind) -> Void)?

    /// System sounds available in /System/Library/Sounds.
    static let systemSounds: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let names = files.filter { $0.hasSuffix(".aiff") }.map { ($0 as NSString).deletingPathExtension }.sorted()
        return names.isEmpty ? ["Basso", "Frog", "Glass", "Pop", "Purr", "Submarine", "Tink"] : names
    }()

    /// Shows an alert. Real alerts also count toward escalation; test alerts don't.
    func fire(_ kind: AlertKind, quiet: Bool, escalate: Bool = true) {
        let settings = AppState.shared.settings
        let subtitle = kind == .smile ? settings.competingResponse : nil
        OverlayController.shared.flash(kind, title: kind.overlayText, subtitle: subtitle, quiet: quiet)
        onFlash?(kind)
        if escalate { EscalationCenter.shared.alertFired(kind, quiet: quiet) }
        // Quiet mode (calls or the quiet hour) keeps only a small, faint visual.
        guard !quiet else { return }
        if settings.sound(for: kind) {
            playSound(settings.soundName(for: kind), volume: Float(settings.volume) * kind.volumeFactor)
        }
        if settings.haptic(for: kind) {
            Haptics.shared.alert(kind, settings: settings)
        }
    }

    /// Plays a test alert from debug mode or settings, logged as a simulation.
    func simulate(_ kind: AlertKind) {
        EventLog.shared.add(.info, kind, "Simulated alert")
        Engine.shared.markers.update { $0.append(AlertMarker(t: monotonicNow(), kind: kind)) }
        fire(kind, quiet: FocusContext.shared.quietReason != nil, escalate: false)
    }

    func playSound(_ name: String, volume: Float) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = max(0, min(1, volume))
        if AudioOutput.isBluetooth, let silence = Self.wakeSilence?.copy() as? NSSound {
            start(silence)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.start(sound) }
        } else {
            start(sound)
        }
    }

    private func start(_ sound: NSSound) {
        sound.delegate = self
        playing.append(sound)
        sound.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        playing.removeAll { $0 === sound }
    }

    func chime() {
        playSound("Glass", volume: Float(AppState.shared.settings.volume))
    }
}
