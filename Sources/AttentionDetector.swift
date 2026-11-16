import CoreGraphics
import Foundation

/// Decides whether eyes are on the screen and when a look-away deserves a nudge.
/// Runs on the camera queue.
final class AttentionDetector {
    enum State: String {
        case onScreen = "On screen"
        case away = "Looking away"
        case noFace = "No face"
        case leftDesk = "Away from desk"
    }

    struct Output {
        var raw: Double?
        var smoothed = 0.0
        var held = 0.0
        var state = State.onScreen
        var active = false
        var typing = false
        var usingModel = false
        var events: [EpisodeTracker.Event] = []
    }

    private let alpha = 0.3
    private var smoothed = 0.0
    private var tracker = EpisodeTracker(hold: 2.5, cooldown: 15, maxAlerts: 3, release: 0.6)
    private var lastFaceTime: Double?
    private var startTime: Double?
    private var lastTime: Double?
    private(set) var output = Output()

    /// Seconds with eyes on the screen and away from it, while gaze monitoring was active. Read and reset by the engine.
    var eyesOnSeconds = 0.0
    var awaySeconds = 0.0

    /// Used before gaze calibration: a simple head-angle rule.
    static func heuristic(yaw: Double, pitch: Double) -> Double {
        func sig(_ x: Double) -> Double { 1 / (1 + exp(-x)) }
        return max(sig((abs(yaw) - 0.42) * 12), sig((abs(pitch) - 0.38) * 12))
    }

    func update(analysis a: FrameAnalysis, model: LogisticModel?, active: Bool, typing: Bool,
                settings: Settings, now: Double) -> Output {
        tracker.hold = settings.gazeGrace
        tracker.cooldown = settings.gazeRepeat
        tracker.maxAlerts = settings.gazeMaxRepeats
        if startTime == nil { startTime = now }
        let dt = min(0.5, max(0, now - (lastTime ?? now)))
        lastTime = now

        var out = Output()
        out.active = active
        out.usingModel = model != nil
        var p: Double

        if a.facePresent {
            lastFaceTime = now
            if let model, let f = a.gazeFeatures {
                p = model.probability(f)
            } else {
                p = Self.heuristic(yaw: a.yaw, pitch: a.pitch)
            }
            out.raw = p
            out.state = .onScreen
        } else {
            let since = now - (lastFaceTime ?? startTime ?? now)
            if lastFaceTime != nil, since <= 30 {
                // Turning the head far loses the face, so a recent face counts as looking away.
                p = 1
                out.state = .noFace
            } else {
                p = 0
                out.state = since > 45 ? .leftDesk : .noFace
            }
        }

        if typing && settings.typingSuppression {
            // Looking at the keyboard while typing is on-task.
            p = 0
            out.typing = true
        }

        smoothed = alpha * p + (1 - alpha) * smoothed
        out.smoothed = smoothed
        let away = smoothed > settings.gazeThreshold
        if a.facePresent, away { out.state = .away }

        if active, out.state != .leftDesk {
            out.events = tracker.update(active: away, value: smoothed, now: now)
            if away { awaySeconds += dt } else { eyesOnSeconds += dt }
        } else {
            out.events = tracker.reset(now: now)
        }
        out.held = tracker.heldFor(now: now)
        output = out
        return out
    }

    func reset(now: Double) -> [EpisodeTracker.Event] {
        smoothed = 0
        lastTime = nil
        return tracker.reset(now: now)
    }
}
