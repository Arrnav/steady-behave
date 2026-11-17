import AppKit
import Combine
import Foundation

/// Decides when gaze monitoring is active (study session or study app), when alerts are quiet
/// (call apps, quiet hour) and runs study sessions. Main thread only.
final class FocusContext: ObservableObject {
    static let shared = FocusContext()

    struct Session {
        let start: Date
        /// nil for an open-ended session.
        let length: TimeInterval?
        var activeSeconds: Double = 0
        var awayFromDesk = false
        let startStats: DayStats
    }

    struct SessionSummary: Identifiable {
        let id = UUID()
        let focusSeconds: Double
        let lookAways: Int
        let smiles: Int
        let overActive: Int
        let handsAtFace: Int
        let completed: Bool
    }

    @Published private(set) var session: Session?
    @Published private(set) var frontmostBundleID: String?
    @Published private(set) var frontmostName: String?
    @Published private(set) var gazeReason = GazeReason.inactive
    @Published private(set) var quietReason: String?
    @Published var lastSummary: SessionSummary?

    /// Called after a session ends, with its summary.
    var onSessionEnded: ((SessionSummary) -> Void)?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let app = AppState.shared

    func start() {
        updateFrontmost(NSWorkspace.shared.frontmostApplication)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.updateFrontmost(running)
            })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        refresh()
    }

    private func updateFrontmost(_ running: NSRunningApplication?) {
        // Steady's own windows don't change the context.
        if running?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        frontmostBundleID = running?.bundleIdentifier
        frontmostName = running?.localizedName
        refresh()
    }

    var sessionActive: Bool { session != nil }

    func startSession(minutes: Int?) {
        let length = minutes.map { TimeInterval($0 * 60) }
        session = Session(start: Date(), length: length, startStats: StatsStore.shared.today)
        let label = minutes.map { "\($0) min" } ?? "open-ended"
        EventLog.shared.add(.info, nil, "Study session started (\(label))")
        refresh()
    }

    func toggleSession() {
        if session != nil {
            stopSession(completed: false)
        } else {
            let m = app.settings.sessionMinutes
            startSession(minutes: m > 0 ? m : nil)
        }
    }

    /// Called when Steady quits: keeps the session's minutes in the stats without showing a summary.
    func endSessionForQuit() {
        guard let s = session else { return }
        session = nil
        StatsStore.shared.update { d in
            d.sessions += 1
            d.sessionMinutes += s.activeSeconds / 60
        }
    }

    func stopSession(completed: Bool) {
        guard let s = session else { return }
        session = nil
        let now = StatsStore.shared.today
        let summary = SessionSummary(
            focusSeconds: s.activeSeconds,
            lookAways: max(0, now.lookAways - s.startStats.lookAways),
            smiles: max(0, now.smileEpisodes - s.startStats.smileEpisodes),
            overActive: max(0, now.overActive - s.startStats.overActive),
            handsAtFace: max(0, now.handsAtFace - s.startStats.handsAtFace),
            completed: completed)
        StatsStore.shared.update { d in
            d.sessions += 1
            d.sessionMinutes += s.activeSeconds / 60
        }
        EventLog.shared.add(.info, nil, "Study session ended after \(Format.duration(s.activeSeconds))")
        lastSummary = summary
        refresh()
        onSessionEnded?(summary)
    }

    /// Seconds left, or seconds so far for an open-ended session.
    var sessionClock: Double? {
        guard let s = session else { return nil }
        if let length = s.length { return max(0, length - s.activeSeconds) }
        return s.activeSeconds
    }

    /// Short menu bar title, for example "32m".
    var menuTitle: String? {
        guard let clock = sessionClock else { return nil }
        let minutes = Int((clock / 60).rounded(session?.length == nil ? .down : .up))
        return "\(minutes)m"
    }

    private var ticks = 0

    private func tick() {
        ticks += 1
        // Plugging in or unplugging the charger changes the camera quality within 10 seconds.
        if ticks % 10 == 0 { app.refreshQuality() }

        // Expire timed pause and quiet mode.
        if let until = app.pausedUntil, until != .distantFuture, until <= Date() {
            app.pausedUntil = nil
            EventLog.shared.add(.info, nil, "Pause ended")
        }
        if let until = app.quietUntil, until <= Date() {
            app.quietUntil = nil
        }

        if var s = session {
            let state = Engine.shared.snapshot.get().gaze.state
            s.awayFromDesk = state == .leftDesk && app.cameraRunning
            // The timer pauses while away from the desk or while monitoring is paused.
            if !s.awayFromDesk && !app.isPaused {
                s.activeSeconds += 1
            }
            session = s
            if let length = s.length, s.activeSeconds >= length {
                stopSession(completed: true)
            }
        }
        refresh()
    }

    /// Recomputes the context and hands a copy to the camera queue.
    func refresh() {
        let settings = app.settings
        let newReason: GazeReason
        if session != nil {
            newReason = .session
        } else if settings.autoMode, let id = frontmostBundleID, settings.studyApps.contains(id) {
            newReason = .autoApp(frontmostName ?? id)
        } else {
            newReason = .inactive
        }
        if newReason != gazeReason { gazeReason = newReason }

        let callName = frontmostBundleID.flatMap { Settings.callApps[$0] }
        if app.callAppFrontmost != callName { app.callAppFrontmost = callName }
        var quiet: String?
        if settings.quietDuringCalls, let callName { quiet = callName }
        if app.isQuietManual { quiet = quiet ?? "Quiet hour" }
        if quiet != quietReason { quietReason = quiet }

        var snap = FocusSnapshot()
        snap.gazeReason = gazeReason
        snap.quietReason = quietReason
        snap.paused = app.isPaused || app.calibrationActive
        snap.calibrating = app.calibrationActive
        snap.sessionActive = session != nil
        Engine.shared.focus.set(snap)
    }
}
