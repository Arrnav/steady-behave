import Foundation

/// Turns a stream of "is the habit happening" values into episodes and alerts.
///
/// - The condition must hold for `hold` seconds before an episode starts.
/// - Alerts are at least `cooldown` seconds apart, both inside an episode (repeats)
///   and across episodes.
/// - At most `maxAlerts` alerts per episode, then it stays quiet until the episode ends.
/// - An episode ends after the condition has been false for `release` seconds.
///
/// Time is passed in, so tests can drive it with a fake clock.
struct EpisodeTracker {
    var hold: Double
    var cooldown: Double
    var maxAlerts: Int
    var release: Double = 0.5

    enum Event: Equatable {
        case started
        case alert(index: Int)
        case suppressedCooldown
        case ended(duration: Double, alerts: Int, peak: Double)
    }

    private(set) var activeSince: Double?
    private(set) var inEpisode = false
    private(set) var episodeStart = 0.0
    private(set) var alerts = 0
    private(set) var lastAlert = -Double.infinity
    private(set) var peak = 0.0
    private var inactiveSince: Double?
    private var cooldownReported = false

    init(hold: Double, cooldown: Double, maxAlerts: Int, release: Double = 0.5) {
        self.hold = hold
        self.cooldown = cooldown
        self.maxAlerts = maxAlerts
        self.release = release
    }

    /// Seconds the condition has held so far (0 if not active).
    func heldFor(now: Double) -> Double {
        guard let since = activeSince else { return 0 }
        return max(0, now - since)
    }

    mutating func update(active: Bool, value: Double = 0, now: Double) -> [Event] {
        var events: [Event] = []
        if active {
            inactiveSince = nil
            if activeSince == nil { activeSince = now }
            if inEpisode { peak = max(peak, value) }

            if !inEpisode, now - (activeSince ?? now) >= hold {
                inEpisode = true
                episodeStart = activeSince ?? now
                alerts = 0
                peak = value
                cooldownReported = false
                events.append(.started)
            }
            if inEpisode, alerts < maxAlerts {
                if now - lastAlert >= cooldown {
                    alerts += 1
                    lastAlert = now
                    events.append(.alert(index: alerts))
                } else if alerts == 0, !cooldownReported {
                    cooldownReported = true
                    events.append(.suppressedCooldown)
                }
            }
        } else {
            if inEpisode {
                if inactiveSince == nil { inactiveSince = now }
                if let since = inactiveSince, now - since >= release {
                    events.append(.ended(duration: since - episodeStart, alerts: alerts, peak: peak))
                    inEpisode = false
                    activeSince = nil
                    inactiveSince = nil
                }
            } else {
                activeSince = nil
            }
        }
        return events
    }

    /// Ends any running episode right away, for example when monitoring pauses.
    mutating func reset(now: Double) -> [Event] {
        var events: [Event] = []
        if inEpisode {
            events.append(.ended(duration: now - episodeStart, alerts: alerts, peak: peak))
        }
        inEpisode = false
        activeSince = nil
        inactiveSince = nil
        return events
    }
}
