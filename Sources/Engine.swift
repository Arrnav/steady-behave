import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// The latest state of the detection pipeline, read by the UI at display rate.
struct EngineSnapshot {
    var analysis: FrameAnalysis?
    var hands: [HandPose] = []
    var body: [String: Joint] = [:]
    var image: CGImage?
    var smile = SmileDetector.Output()
    var gaze = AttentionDetector.Output()
    var gazeReason = GazeReason.inactive
    var activity = ActivityDetector.Output()
    var paused = false
    var calibrating = false
    var quietReason: String?
    var fps = 0.0
    var visionMs = 0.0
    var targetFps = 15.0
    var handEvery = 3
    var missedActive = false
    var clipFrames = 0
    var quality = CameraQuality.balanced
    var idle = false
    var inputPaused: [AlertKind] = []
}

/// Which detections run on a frame. Decided in one place from settings and the focus context.
struct DetectionGates: Equatable {
    var smile = false
    var lookAway = false
    var overActive = false
    var hands = false

    /// Detections paused because the keyboard or mouse is in use.
    var inputPaused: [AlertKind] = []

    init(settings: Settings, focus: FocusSnapshot, inputActive: Bool = false) {
        let live = !focus.paused
        let wouldRun: [AlertKind: Bool] = [
            .smile: live && settings.detects(.smile) && (settings.smileMode == .always || focus.gazeActive),
            .lookAway: live && settings.detects(.lookAway) && focus.gazeActive,
            .overActive: live && settings.detects(.overActive),
            .handsAtFace: live && settings.detects(.handsAtFace)
        ]
        // Only detections that would otherwise run count as paused by input.
        inputPaused = AlertKind.allCases.filter { inputActive && settings.pausesOnInput($0) && wouldRun[$0] == true }
        smile = wouldRun[.smile] == true && !inputPaused.contains(.smile)
        // Look-away keeps running during input, so eyes-on time is still counted; input counts as on-task.
        lookAway = wouldRun[.lookAway] == true
        overActive = wouldRun[.overActive] == true && !inputPaused.contains(.overActive)
        hands = wouldRun[.handsAtFace] == true && !inputPaused.contains(.handsAtFace)
    }
}

struct HistoryPoint: Identifiable {
    var id: Double { t }
    let t: Double
    let smile: Double
    let gaze: Double
    let activity: Double
}

struct AlertMarker: Identifiable {
    let id = UUID()
    let t: Double
    let kind: AlertKind
}

/// Process CPU and memory, for the debug window and automatic performance tuning.
enum SystemUsage {
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + sys
    }

    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// Ties the camera, Vision and the detectors together. Detection runs on the camera queue;
/// alerts and stats are handed to the main thread.
final class Engine {
    static let shared = Engine()

    let camera = CameraService()
    private let vision = VisionPipeline()
    private let smile = SmileDetector()
    private let attention = AttentionDetector()
    private let activity = ActivityDetector()
    let clips = ClipRecorder(root: Paths.clips)

    /// Focus context, written by FocusContext on the main thread.
    let focus = Locked(FocusSnapshot())
    let snapshot = Locked(EngineSnapshot())
    let history = Locked<[HistoryPoint]>([])
    let markers = Locked<[AlertMarker]>([])
    /// How many open windows want a camera preview image.
    let previewConsumers = Locked(0)
    /// Calibration hooks: called on the main thread with each analysed frame.
    let calibrationSink = Locked<((FrameAnalysis) -> Void)?>(nil)
    let cpuPercent = Locked(0.0)
    /// Camera quality in use, set by AppState from the setting and the power source.
    let quality = Locked(CameraQuality.balanced)

    private let previewContext = CIContext(options: [.cacheIntermediates: false])

    // Camera-queue state.
    private var lastProcessed = -Double.infinity
    private var nextFrameDue = -Double.infinity
    private var frameIndex = 0
    private var targetFps = 15.0
    private var handEvery = 3
    /// Caps from automatic performance tuning, on top of the chosen quality.
    private var fpsCap = 15.0
    private var poseEveryFloor = 3
    private var activeQuality: CameraQuality?
    private var noFaceSince: Double?
    private var fpsCounter: [Double] = []
    private var lastHands: [HandPose] = []
    private var lastHandsTime = -Double.infinity
    private var lastBody: [String: Joint] = [:]
    private var lastBodyTime = -Double.infinity
    private var wasPaused = true
    private var lastHistory = -Double.infinity
    private var recent: [(t: Double, smile: [Double]?, gaze: [Double]?)] = []
    private var lastAlert: (kind: AlertKind, t: Double)?
    private var missedUntil: Double?
    private var missedSamples: [[Double]] = []
    private var inputPauseLogged = false
    private var lastStatsFlush = -Double.infinity
    private var focusedAccum = 0.0
    private var lastFrameTime: Double?
    private var smileStart: Double?
    private var smileFocusedAtStart = false
    private var cpuWindowStart: (wall: Double, cpu: Double)?
    private var firstFrameTime: Double?

    private init() {
        camera.onFrame = { [weak self] buffer, now in self?.handle(buffer, now: now) }
        clips.onSaved = { url, info in
            EventLog.shared.add(.info, info.type, "Clip saved: \(url.lastPathComponent)")
            NotificationCenter.default.post(name: .steadyClipsChanged, object: nil)
        }
    }

    // MARK: Frame handling (camera queue)

    private func handle(_ buffer: CVPixelBuffer, now: Double) {
        // The camera always delivers 15 fps; take a frame each time the next slot at the target rate is due.
        guard now >= nextFrameDue - 0.01 else { return }
        nextFrameDue = max(nextFrameDue + 1 / targetFps, now - 1 / targetFps)
        lastProcessed = now
        frameIndex += 1

        let settings = AppState.settingsSnapshot.get()
        let focus = self.focus.get()
        let models = ModelStore.shared.file
        let quality = self.quality.get()
        if quality != activeQuality {
            // Motion between frames depends on the frame rate, so the calm level starts over.
            activeQuality = quality
            vision.reset()
            let calm = models.calmMotionQuality == quality.rawValue ? models.calmMotion : nil
            activity.resetBaselines(calmMotion: calm)
        }

        // With no face for a while, only look for a face, at a low rate.
        let idle = (noFaceSince.map { now - $0 > 10 } ?? false) && !focus.calibrating
        targetFps = idle ? 2 : min(quality.fps, fpsCap)
        handEvery = max(quality.poseEvery, poseEveryFloor)

        // Hand and body pose only run when a detection (or the debug preview) uses them.
        let inputActive = InputActivity.isActive(settings: settings)
        let gates = DetectionGates(settings: settings, focus: focus, inputActive: inputActive)
        let preview = previewConsumers.get() > 0
        let needHands = gates.hands || preview
        let needBody = (gates.overActive && settings.weightBody > 0) || preview
        let runHands = !idle && needHands && frameIndex % handEvery == 0
        let runBody = !idle && needBody && frameIndex % handEvery == 1
        let a = vision.analyze(buffer, time: now, runHands: runHands, runBody: runBody)
        noFaceSince = a.facePresent ? nil : (noFaceSince ?? now)
        if let h = a.hands { lastHands = h; lastHandsTime = now }
        if let b = a.body { lastBody = b; lastBodyTime = now }
        if now - lastHandsTime > 1 { lastHands = [] }
        if now - lastBodyTime > 1 { lastBody = [:] }

        let dt = min(0.5, max(0, now - (lastFrameTime ?? now)))
        lastFrameTime = now

        let paused = focus.paused
        if paused != wasPaused {
            if paused { endAllEpisodes(now: now) }
            wasPaused = paused
        }

        let typing = gates.inputPaused.contains(.lookAway)
        let s = smile.update(features: a.smileFeatures, model: models.smile, enabled: gates.smile, settings: settings, now: now)
        let g = attention.update(analysis: a, model: models.gaze, active: gates.lookAway,
                                 typing: typing, settings: settings, now: now)
        let act = activity.update(analysis: a, overActiveEnabled: gates.overActive, handsEnabled: gates.hands,
                                  settings: settings, now: now)

        handleSmile(s.events, value: s.smoothed, focus: focus, settings: settings, now: now)
        handleGaze(g, focus: focus, settings: settings, now: now)
        if gates.inputPaused.isEmpty {
            inputPauseLogged = false
        } else if !inputPauseLogged {
            inputPauseLogged = true
            EventLog.shared.add(.suppressed, nil, "Keyboard or mouse in use, paused: "
                                + gates.inputPaused.map(\.title).joined(separator: ", "))
        }
        handleActivity(act, focus: focus, settings: settings, now: now)

        // Feedback windows.
        recent.append((now, a.smileFeatures, a.gazeFeatures))
        while let first = recent.first, now - first.t > 3 { recent.removeFirst() }
        if let until = missedUntil {
            if let f = a.smileFeatures { missedSamples.append(f) }
            if now >= until { finishMissed() }
        }

        // Clip buffer.
        if settings.clipsEnabled && !paused {
            clips.append(buffer, now: now, meta: ClipFrameMeta(activityScore: act.score, handNear: act.handNear, smileActive: s.inEpisode))
        } else if clips.bufferedFrames > 0 {
            clips.clear()
        }

        // Stats time counters, flushed every 5 seconds.
        if !paused, focus.gazeActive, g.state != .leftDesk { focusedAccum += dt }
        if now - lastStatsFlush >= 5 { flushTimeStats(now: now) }

        // History for the graphs, 5 points a second.
        if now - lastHistory >= 0.2 {
            lastHistory = now
            history.update { list in
                list.append(HistoryPoint(t: now, smile: s.smoothed, gaze: g.smoothed, activity: act.score))
                while let first = list.first, now - first.t > 60 { list.removeFirst() }
            }
            markers.update { list in
                while let first = list.first, now - first.t > 60 { list.removeFirst() }
            }
        }

        fpsCounter.append(now)
        while let first = fpsCounter.first, now - first > 2 { fpsCounter.removeFirst() }
        adaptPerformance(now: now, settings: settings)

        var image: CGImage?
        if previewConsumers.get() > 0 {
            image = previewContext.createCGImage(CIImage(cvPixelBuffer: buffer),
                                                 from: CGRect(origin: .zero, size: a.imageSize))
        }

        var snap = EngineSnapshot()
        snap.analysis = a
        snap.hands = lastHands
        snap.body = lastBody
        snap.image = image
        snap.smile = s
        snap.gaze = g
        snap.gazeReason = focus.gazeReason
        snap.activity = act
        snap.paused = paused
        snap.calibrating = focus.calibrating
        snap.quietReason = focus.quietReason
        snap.fps = Double(fpsCounter.count) / 2
        snap.visionMs = a.processingMs
        snap.targetFps = targetFps
        snap.handEvery = handEvery
        snap.missedActive = missedUntil != nil
        snap.quality = quality
        snap.inputPaused = gates.inputPaused
        snap.idle = idle
        snap.clipFrames = clips.bufferedFrames
        snapshot.set(snap)

        if let sink = calibrationSink.get() {
            DispatchQueue.main.async { sink(a) }
        }
    }

    private func handleSmile(_ events: [EpisodeTracker.Event], value: Double, focus: FocusSnapshot, settings: Settings, now: Double) {
        for e in events {
            switch e {
            case .started:
                smileStart = now
                smileFocusedAtStart = focus.gazeActive
                EventLog.shared.add(.detected, .smile, "Stretched smile", peak: value)
                let focused = focus.gazeActive
                DispatchQueue.main.async {
                    StatsStore.shared.update { d in
                        d.smileEpisodes += 1
                        if focused { d.smileEpisodesFocused += 1 }
                    }
                }
            case .alert(let index):
                fireAlert(.smile, focus: focus, now: now, note: index > 1 ? "repeat \(index)" : nil)
                if index == 1, settings.smileClips { triggerClip(.smile, settings: settings, now: now) }
            case .suppressedCooldown:
                EventLog.shared.add(.suppressed, .smile, "Cooldown")
            case .ended(let duration, _, let peak):
                EventLog.shared.add(.ended, .smile, "Smile episode", peak: peak, duration: duration)
                DispatchQueue.main.async { StatsStore.shared.update { $0.smileSeconds += duration } }
            }
        }
    }

    private func handleGaze(_ g: AttentionDetector.Output, focus: FocusSnapshot, settings: Settings, now: Double) {
        for e in g.events {
            switch e {
            case .started:
                EventLog.shared.add(.detected, .lookAway, "Looking away", peak: g.smoothed)
                DispatchQueue.main.async { StatsStore.shared.update { $0.lookAways += 1 } }
            case .alert(let index):
                fireAlert(.lookAway, focus: focus, now: now, note: index > 1 ? "repeat \(index)" : nil)
            case .suppressedCooldown:
                EventLog.shared.add(.suppressed, .lookAway, "Cooldown")
            case .ended(let duration, _, let peak):
                EventLog.shared.add(.ended, .lookAway, "Back on screen", peak: peak, duration: duration)
            }
        }
    }

    private func handleActivity(_ act: ActivityDetector.Output, focus: FocusSnapshot, settings: Settings, now: Double) {
        for e in act.overActiveEvents {
            switch e {
            case .started:
                EventLog.shared.add(.detected, .overActive, "Moving a lot", peak: act.score)
                DispatchQueue.main.async { StatsStore.shared.update { $0.overActive += 1 } }
            case .alert:
                fireAlert(.overActive, focus: focus, now: now, note: nil)
                triggerClip(.overActive, settings: settings, now: now)
            case .suppressedCooldown:
                EventLog.shared.add(.suppressed, .overActive, "Cooldown")
            case .ended(let duration, _, let peak):
                EventLog.shared.add(.ended, .overActive, "Settled", peak: peak, duration: duration)
            }
        }
        for e in act.handsEvents {
            switch e {
            case .started:
                EventLog.shared.add(.detected, .handsAtFace, "Hand near face")
                DispatchQueue.main.async { StatsStore.shared.update { $0.handsAtFace += 1 } }
            case .alert:
                fireAlert(.handsAtFace, focus: focus, now: now, note: nil)
            case .suppressedCooldown:
                EventLog.shared.add(.suppressed, .handsAtFace, "Cooldown")
            case .ended(let duration, _, let peak):
                EventLog.shared.add(.ended, .handsAtFace, "Hands down", peak: peak, duration: duration)
            }
        }
        if act.handsClipDue { triggerClip(.handsAtFace, settings: settings, now: now) }
    }

    private func fireAlert(_ kind: AlertKind, focus: FocusSnapshot, now: Double, note: String?) {
        lastAlert = (kind, now)
        markers.update { $0.append(AlertMarker(t: now, kind: kind)) }
        var message = note ?? "Nudge"
        if let quiet = focus.quietReason { message += " (quiet: \(quiet))" }
        EventLog.shared.add(.alert, kind, message)
        let quiet = focus.quietReason != nil
        DispatchQueue.main.async { AlertCenter.shared.fire(kind, quiet: quiet) }
    }

    private func triggerClip(_ kind: AlertKind, settings: Settings, now: Double) {
        guard settings.clipsEnabled else { return }
        if let reason = ClipLimits.blockReason(settings: settings, root: clips.root) {
            EventLog.shared.add(.suppressed, kind, "Clip skipped: \(reason)")
            return
        }
        if clips.trigger(kind, now: now) {
            ClipLimits.recordStarted()
            EventLog.shared.add(.info, kind, "Recording clip")
        }
    }

    private func endAllEpisodes(now: Double) {
        handleSmile(smile.reset(now: now), value: 0, focus: FocusSnapshot(), settings: AppState.settingsSnapshot.get(), now: now)
        _ = attention.reset(now: now)
        activity.reset(now: now)
    }

    private func flushTimeStats(now: Double) {
        lastStatsFlush = now
        let eyesOn = attention.eyesOnSeconds, away = attention.awaySeconds, focused = focusedAccum
        attention.eyesOnSeconds = 0
        attention.awaySeconds = 0
        focusedAccum = 0
        guard eyesOn + away + focused > 0 else { return }
        DispatchQueue.main.async {
            StatsStore.shared.update { d in
                d.eyesOnSeconds += eyesOn
                d.awaySeconds += away
                d.focusedSeconds += focused
            }
        }
    }

    /// Lowers the frame rate when CPU use runs high with the debug window closed.
    private func adaptPerformance(now: Double, settings: Settings) {
        let cpu = SystemUsage.cpuSeconds()
        // Start measuring 15 s after the first frame, so start-up work (loading Vision models) doesn't count.
        if firstFrameTime == nil { firstFrameTime = now }
        guard now - (firstFrameTime ?? now) >= 15 else { return }
        guard let start = cpuWindowStart else { cpuWindowStart = (now, cpu); return }
        guard now - start.wall >= 10 else { return }
        let percent = 100 * (cpu - start.cpu) / (now - start.wall)
        cpuPercent.set(percent)
        cpuWindowStart = (now, cpu)
        guard settings.adaptivePerformance, previewConsumers.get() == 0 else { return }
        if percent > 15, fpsCap > 10 {
            fpsCap = 10; poseEveryFloor = 4
            EventLog.shared.add(.info, nil, String(format: "CPU at %.0f%%, lowering to 10 fps", percent))
        } else if percent < 8, fpsCap < 15 {
            fpsCap = 15; poseEveryFloor = 3
            EventLog.shared.add(.info, nil, String(format: "CPU at %.0f%%, back to the full frame rate", percent))
        }
    }

    // MARK: Feedback (called from the main thread)

    /// "False alarm": the last 2 seconds of samples for the last alert type become negatives.
    func falseAlarm() {
        camera.frameQueue.async { [self] in
            let now = monotonicNow()
            guard let last = lastAlert, now - last.t < 120 else {
                EventLog.shared.add(.feedback, nil, "False alarm noted, no recent alert to learn from")
                return
            }
            let window = recent.filter { now - $0.t <= 2 }
            switch last.kind {
            case .smile:
                let samples = window.compactMap(\.smile)
                ModelStore.shared.addFeedback(.smile, negatives: Self.weighted(samples))
                _ = smile.reset(now: now)
                EventLog.shared.add(.feedback, .smile, "False alarm: \(samples.count) frames added as relaxed, retraining")
            case .lookAway:
                let samples = window.compactMap(\.gaze)
                ModelStore.shared.addFeedback(.gaze, negatives: Self.weighted(samples))
                _ = attention.reset(now: now)
                EventLog.shared.add(.feedback, .lookAway, "False alarm: \(samples.count) frames added as on-screen, retraining")
            case .overActive, .handsAtFace:
                EventLog.shared.add(.feedback, last.kind, "False alarm noted. Raise the threshold in debug mode if this repeats")
            }
        }
    }

    /// "Missed one": the next 1.5 seconds of frames become smile positives.
    func missedOne() {
        camera.frameQueue.async { [self] in
            missedSamples = []
            missedUntil = monotonicNow() + 1.5
            EventLog.shared.add(.feedback, .smile, "Missed one: recording 1.5 s as smile")
        }
    }

    private func finishMissed() {
        missedUntil = nil
        let samples = missedSamples
        missedSamples = []
        guard !samples.isEmpty else {
            EventLog.shared.add(.feedback, .smile, "Missed one: no face found, nothing added")
            return
        }
        ModelStore.shared.addFeedback(.smile, positives: Self.weighted(samples))
        EventLog.shared.add(.feedback, .smile, "Missed one: \(samples.count) frames added as smile, retraining")
    }

    /// Feedback samples count three times, so a few seconds of feedback can move the model.
    private static func weighted(_ samples: [[Double]]) -> [[Double]] {
        samples + samples + samples
    }

    func setCalmMotion(_ value: Double) {
        camera.frameQueue.async { [self] in activity.setCalmMotion(value) }
    }

    func resetPipeline() {
        camera.frameQueue.async { [self] in
            vision.reset()
            clips.clear()
            lastFrameTime = nil
        }
    }
}

extension Notification.Name {
    static let steadyClipsChanged = Notification.Name("steadyClipsChanged")
}

/// Clip rate limits: at most one clip per interval and a daily maximum.
enum ClipLimits {
    private static let lastStart = Locked<Date?>(nil)

    static func recordStarted() { lastStart.set(Date()) }

    static func blockReason(settings: Settings, root: URL, now: Date = Date()) -> String? {
        if let last = lastStart.get(), now.timeIntervalSince(last) < settings.clipMinInterval {
            return "one clip per \(Int(settings.clipMinInterval / 60)) min"
        }
        if ClipStorage.clipCount(root: root, on: now) >= settings.clipsPerDay {
            return "daily limit of \(settings.clipsPerDay) reached"
        }
        return nil
    }
}
