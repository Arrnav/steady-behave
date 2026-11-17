import Foundation

/// Scores each frame with the personal smile model and decides when to alert.
/// Runs on the camera queue.
final class SmileDetector {
    struct Output {
        var raw: Double?
        var smoothed = 0.0
        var held = 0.0
        var inEpisode = false
        var enabled = false
        var events: [EpisodeTracker.Event] = []
    }

    private(set) var smoothed = 0.0
    private var lastTime: Double?
    private var tracker = EpisodeTracker(hold: 0.6, cooldown: 8, maxAlerts: 3)
    private(set) var output = Output()

    func update(features: [Double]?, model: LogisticModel?, enabled: Bool, settings: Settings, now: Double) -> Output {
        tracker.hold = settings.smileHold
        tracker.cooldown = settings.smileCooldown
        tracker.maxAlerts = settings.smileMaxRepeats

        var out = Output()
        out.enabled = enabled && model != nil
        let alpha = Smoothing.alpha(dt: now - (lastTime ?? now - 1.0 / 15))
        lastTime = now

        if let model, let features {
            let p = model.probability(features)
            out.raw = p
            smoothed = alpha * p + (1 - alpha) * smoothed
        } else {
            // No usable face: let the score fall away.
            smoothed *= (1 - alpha)
        }
        out.smoothed = smoothed

        if out.enabled {
            out.events = tracker.update(active: smoothed > settings.smileThreshold, value: smoothed, now: now)
        } else {
            out.events = tracker.reset(now: now)
        }
        out.held = tracker.heldFor(now: now)
        out.inEpisode = tracker.inEpisode
        output = out
        return out
    }

    func reset(now: Double) -> [EpisodeTracker.Event] {
        smoothed = 0
        return tracker.reset(now: now)
    }
}
