import AppKit
import AVFoundation
import Combine
import SwiftUI

/// A value guarded by a lock, for state shared between the main thread and the camera queue.
final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&value); lock.unlock() }
}

enum Paths {
    /// The data folder holds camera clips, so only the owner can read it.
    static var support: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("Steady", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    static var models: URL { support.appendingPathComponent("models.json") }
    static var stats: URL { support.appendingPathComponent("stats.json") }
    static var clips: URL {
        let url = support.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// How many camera frames are analysed. Lower settings use less battery and react a little slower.
enum CameraQuality: String, Codable, CaseIterable, Identifiable {
    case high, balanced, batterySaver
    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: return "High"
        case .balanced: return "Balanced"
        case .batterySaver: return "Battery Saver"
        }
    }

    var fps: Double {
        switch self {
        case .high: return 15
        case .balanced: return 10
        case .batterySaver: return 5
        }
    }

    /// Hand and body pose run on every nth frame.
    var poseEvery: Int { self == .batterySaver ? 4 : 3 }

    var detail: String { "\(Int(fps)) frames per second" }
}

enum SmileMode: String, Codable, CaseIterable, Identifiable {
    case always, studyOnly
    var id: String { rawValue }
    var title: String { self == .always ? "Always while monitoring" : "Only while studying" }
}

/// Every user setting. Stored as JSON in UserDefaults. New fields fall back to their defaults.
struct Settings: Codable, Equatable {
    var cameraID: String?
    var cameraQuality = CameraQuality.balanced
    var batterySaverOnBattery = true

    // Smile
    var smileThreshold = 0.75
    var smileHold = 0.6
    var smileCooldown = 8.0
    var smileMaxRepeats = 3
    var smileMode = SmileMode.always

    // Looking away
    var gazeThreshold = 0.7
    var gazeGrace = 2.5
    var gazeRepeat = 15.0
    var gazeMaxRepeats = 3
    var autoMode = false
    var studyApps: [String] = Settings.defaultStudyApps
    var sessionMinutes = 50

    // Activity
    var activityThreshold = 2.5
    var activityHold = 3.0
    var activityCooldown = 60.0
    var weightMotion = 1.0
    var weightHead = 1.0
    var weightBody = 0.5
    var weightHands = 1.0
    var handsHold = 2.0
    var handsCooldown = 30.0
    var handsClipAfter = 5.0

    // Keyboard and mouse
    /// Pause some detections while the keyboard or mouse is in use.
    var typingSuppression = true
    var inputKeyboard = true
    var inputMouse = true
    /// Seconds after the last input event that still count as "in use".
    var typingWindow = 2.5
    /// Which detections pause during input. Missing keys: only looking away pauses.
    var inputPauses: [String: Bool] = [:]

    /// Each detection can be switched off on its own. Missing keys mean on.
    var detectionEnabled: [String: Bool] = [:]

    // Alerts
    /// Alert colours as "#RRGGBB", keyed by alert kind. Missing keys use the default palette.
    var alertColors: [String: String] = [:]
    var volume = 0.6
    var soundEnabled: [String: Bool] = [:]
    var soundNames: [String: String] = [:]
    var hapticEnabled: [String: Bool] = [:]
    var competingResponse = "Lips gently together, jaw loose, slow breath out."
    var quietDuringCalls = true
    var cameraOffDuringCalls = false

    // When a habit keeps repeating
    var escalationWindowMinutes = 10.0
    var blurEnabled = true
    var blurAfter = 3
    var combinedAfter = 6
    var blurStrength = 0.6
    var blurSeconds = 6.0
    var speakEnabled = true
    var speakAfter = 5
    var speakCooldownMinutes = 5.0
    var voiceID: String?
    /// Separate from alert sounds, so the spoken reminder can stay quiet.
    var speechVolume = 0.5
    /// Avoids speaking out loud through the Mac's own speakers.
    var speakOnlyWithHeadphones = true

    // Haptics
    var smileWaveform = 6
    var lookAwayWaveform = 2

    // Clips
    var clipsEnabled = true
    var smileClips = true
    var clipMinInterval = 180.0
    var clipsPerDay = 25
    var clipCapMB = 500
    var clipRetentionDays = 14

    // Debug and performance
    var debugMirror = true
    var debugLayers: [String: Bool] = [:]
    var debugKeepOnTop = false
    var adaptivePerformance = true

    static let defaultStudyApps = [
        "com.jetbrains.rider", "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.apple.Preview",
        "com.apple.iBooksX", "com.apple.Terminal", "com.azuredatastudio.oss", "org.jkiss.dbeaver.core.product"
    ]

    static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.webex.meetingmanager": "Webex",
        "Cisco-Systems.Spark": "Webex"
    ]

    /// One "tolerance" value that sets every escalation threshold: blur after N alerts for one habit,
    /// a spoken reminder after N + 2, and a blur after 2N alerts of any kind.
    var escalationTolerance: Int {
        get { blurAfter }
        set {
            blurAfter = newValue
            speakAfter = newValue + 2
            combinedAfter = newValue * 2
        }
    }

    func detects(_ kind: AlertKind) -> Bool { detectionEnabled[kind.rawValue] ?? true }
    func pausesOnInput(_ kind: AlertKind) -> Bool { inputPauses[kind.rawValue] ?? (kind == .lookAway) }
    func sound(for kind: AlertKind) -> Bool { soundEnabled[kind.rawValue] ?? true }
    func soundName(for kind: AlertKind) -> String { soundNames[kind.rawValue] ?? kind.defaultSound }
    func haptic(for kind: AlertKind) -> Bool {
        hapticEnabled[kind.rawValue] ?? (kind == .smile || kind == .lookAway)
    }
    func layer(_ layer: DebugLayer) -> Bool { debugLayers[layer.rawValue] ?? layer.defaultOn }

    /// Decodes by laying stored values over the defaults, so adding a setting never loses the others.
    static func load(from data: Data?) -> Settings {
        guard let data,
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(Settings()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else { return Settings() }
        for (key, value) in stored { merged[key] = value }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(Settings.self, from: mergedData)
        else { return Settings() }
        return settings
    }

    /// Tuning values exposed in debug mode. "Reset to defaults" restores only these.
    mutating func resetTuning() {
        let d = Settings()
        smileThreshold = d.smileThreshold; smileHold = d.smileHold; smileCooldown = d.smileCooldown
        gazeThreshold = d.gazeThreshold; gazeGrace = d.gazeGrace; gazeRepeat = d.gazeRepeat
        activityThreshold = d.activityThreshold; activityHold = d.activityHold; activityCooldown = d.activityCooldown
        weightMotion = d.weightMotion; weightHead = d.weightHead; weightBody = d.weightBody; weightHands = d.weightHands
        handsHold = d.handsHold; handsCooldown = d.handsCooldown
    }
}

enum DebugLayer: String, CaseIterable, Identifiable {
    case face, headPose, gaze, hands, handZone, body, motion
    var id: String { rawValue }
    var title: String {
        switch self {
        case .face: return "Face"
        case .headPose: return "Head pose"
        case .gaze: return "Gaze"
        case .hands: return "Hands"
        case .handZone: return "Hand zone"
        case .body: return "Body"
        case .motion: return "Motion"
        }
    }
    var defaultOn: Bool { self != .motion }
}

/// Why gaze monitoring is on or off right now.
enum GazeReason: Equatable {
    case session
    case autoApp(String)
    case inactive

    var label: String {
        switch self {
        case .session: return "Study session"
        case .autoApp(let name): return "Study app: \(name)"
        case .inactive: return "Inactive"
        }
    }
}

/// What the camera queue needs to know about the focus context, refreshed from the main thread.
struct FocusSnapshot {
    var gazeReason: GazeReason = .inactive
    var quietReason: String?
    var paused = false
    var calibrating = false
    var sessionActive = false
    var gazeActive: Bool { gazeReason != .inactive }
}

/// App-wide state that lives on the main thread. Background code reads `settingsSnapshot`.
final class AppState: ObservableObject {
    static let shared = AppState()

    static let settingsSnapshot = Locked(Settings())

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            AppState.settingsSnapshot.set(settings)
            AlertKind.refreshColors(from: settings)
            scheduleSave()
        }
    }

    @Published var monitoringEnabled: Bool {
        didSet { UserDefaults.standard.set(monitoringEnabled, forKey: "monitoringEnabled"); onCameraConditionsChanged?() }
    }
    @Published var pausedUntil: Date? { didSet { onCameraConditionsChanged?() } }
    @Published var quietUntil: Date?

    @Published var cameraAuthorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var cameraRunning = false
    @Published var cameraName = ""

    @Published var screenLocked = false { didSet { onCameraConditionsChanged?() } }
    @Published var displayAsleep = false { didSet { onCameraConditionsChanged?() } }
    @Published var systemAsleep = false { didSet { onCameraConditionsChanged?() } }
    @Published var callAppFrontmost: String? { didSet { onCameraConditionsChanged?() } }
    /// Bumped whenever a model is trained, so views refresh.
    @Published var modelVersion = 0

    private var qualityApplied = false

    /// The camera quality in use right now, after battery rules.
    @Published var effectiveQuality = CameraQuality.balanced
    @Published var qualityReason = ""
    /// `--quality <name>` at launch overrides the setting without saving it.
    let qualityOverride: CameraQuality? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--quality"), i + 1 < args.count else { return nil }
        return CameraQuality(rawValue: args[i + 1])
    }()

    /// Picks the camera quality from the setting, the power source and Low Power Mode.
    func refreshQuality() {
        var quality = settings.cameraQuality
        var reason = "Chosen in Settings"
        if let override = qualityOverride {
            quality = override
            reason = "Set at launch"
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
            quality = .batterySaver
            reason = "Low Power Mode is on"
        } else if settings.batterySaverOnBattery, PowerSource.onBattery {
            quality = .batterySaver
            reason = "Running on battery"
        }
        if qualityReason != reason { qualityReason = reason }
        guard quality != effectiveQuality || !qualityApplied else { return }
        qualityApplied = true
        effectiveQuality = quality
        Engine.shared.quality.set(quality)
        EventLog.shared.add(.info, nil, "Camera quality: \(quality.title) (\(quality.detail)), \(reason.lowercased())")
    }

    /// Calibration windows need the camera even while monitoring is paused.
    @Published var calibrationActive = false { didSet { onCameraConditionsChanged?() } }

    var onCameraConditionsChanged: (() -> Void)?

    private init() {
        let loaded = Settings.load(from: UserDefaults.standard.data(forKey: "settings"))
        settings = loaded
        AppState.settingsSnapshot.set(loaded)
        AlertKind.refreshColors(from: loaded)
        monitoringEnabled = UserDefaults.standard.object(forKey: "monitoringEnabled") as? Bool ?? true
    }

    private var saveWork: DispatchWorkItem?

    /// Sliders and the color picker change settings many times a second, so saving waits for a pause.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSettingsNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveSettingsNow() {
        saveWork?.cancel()
        saveWork = nil
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
    }

    func setDetection(_ kind: AlertKind, enabled: Bool) {
        guard settings.detects(kind) != enabled else { return }
        settings.detectionEnabled[kind.rawValue] = enabled
        EventLog.shared.add(.info, kind, enabled ? "Detection on" : "Detection off")
    }

    var isPaused: Bool {
        if !monitoringEnabled { return true }
        if let until = pausedUntil, until > Date() { return true }
        return false
    }

    var isQuietManual: Bool {
        if let until = quietUntil, until > Date() { return true }
        return false
    }

    /// The camera runs only when there is a reason for it and nothing says it must be off.
    var cameraShouldRun: Bool {
        guard cameraAuthorization == .authorized else { return false }
        if screenLocked || displayAsleep || systemAsleep { return false }
        if calibrationActive { return true }
        if isPaused { return false }
        if settings.cameraOffDuringCalls && callAppFrontmost != nil { return false }
        return true
    }

    func pause(for seconds: TimeInterval?) {
        if let seconds {
            pausedUntil = Date().addingTimeInterval(seconds)
        } else {
            pausedUntil = .distantFuture
        }
    }

    func resume() {
        pausedUntil = nil
        if !monitoringEnabled { monitoringEnabled = true }
    }
}
