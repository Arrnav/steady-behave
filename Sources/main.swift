import AppKit
import AVFoundation
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var cancellables: Set<AnyCancellable> = []
    private var cleanupTimer: Timer?
    private var systemObservers: [NSObjectProtocol] = []
    private let app = AppState.shared
    private let engine = Engine.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        ModelStore.shared.onChange = { [weak self] in
            self?.app.modelVersion += 1
        }
        if let calm = ModelStore.shared.file.calmMotion { engine.setCalmMotion(calm) }

        engine.camera.onStateChange = { [weak self] running, name in
            self?.app.cameraRunning = running
            self?.app.cameraName = name
        }
        app.onCameraConditionsChanged = { [weak self] in
            DispatchQueue.main.async { self?.updateCamera() }
        }

        FocusContext.shared.onSessionEnded = { summary in
            AlertCenter.shared.chime()
            Actions.showSessionSummary(summary)
        }
        FocusContext.shared.start()
        statusBar = StatusBarController()

        HotKeys.shared.register(.s) { FocusContext.shared.toggleSession() }
        HotKeys.shared.register(.x) { Actions.falseAlarm() }
        HotKeys.shared.register(.m) { Actions.missedOne() }
        HotKeys.shared.register(.d) { Actions.showDebug() }

        observeSystemState()

        // Restart the camera when a different one is picked in Settings.
        app.$settings
            .map(\.cameraID)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.engine.camera.stop()
                    self.engine.resetPipeline()
                    self.updateCamera()
                }
            }
            .store(in: &cancellables)
        app.refreshQuality()
        app.$settings
            .map { "\($0.cameraQuality.rawValue) \($0.batterySaverOnBattery)" }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.app.refreshQuality() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.app.refreshQuality() }
            .store(in: &cancellables)
        app.$settings
            .map { [$0.quietDuringCalls, $0.autoMode, $0.cameraOffDuringCalls] }
            .removeDuplicates()
            .sink { _ in DispatchQueue.main.async { FocusContext.shared.refresh() } }
            .store(in: &cancellables)

        cleanUpClips()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.cleanUpClips() }

        engine.camera.requestAccess { [weak self] status in
            self?.app.cameraAuthorization = status
            if status != .authorized {
                EventLog.shared.add(.info, nil, "Camera access is off. Allow it in System Settings, Privacy and Security, Camera")
            }
            self?.updateCamera()
        }
        EventLog.shared.add(.info, nil, "Steady started")
        openWindowsFromArguments()
    }

    /// `--show debug,settings,...` opens windows at launch (handy for checking layouts); `session` starts a 25 min session, `alert` shows a test smile alert, `menu` opens the menu.
    private func openWindowsFromArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--show"), i + 1 < args.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for name in args[i + 1].split(separator: ",") {
                switch name {
                case "debug": Actions.showDebug()
                case "settings": Actions.showSettings()
                case "clips": Actions.showClips()
                case "stats": Actions.showStats()
                case "expression": Actions.showSmileCalibration()
                case "gaze": Actions.showGazeCalibration()
                case "session": FocusContext.shared.startSession(minutes: 25)
                case "alert": AlertCenter.shared.simulate(.smile)
                case "pause": self.app.pause(for: nil); FocusContext.shared.refresh()
                case "blur": EscalationCenter.shared.testBlur()
                case "voice": EscalationCenter.shared.testVoice()
                case "menu": self.statusBar?.openMenu()
                case "mini": Actions.showDebug(); DebugWindow.setMini(true)
                default: break
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FocusContext.shared.endSessionForQuit()
        StatsStore.shared.saveNow()
        app.saveSettingsNow()
        engine.camera.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func updateCamera() {
        app.cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        if app.cameraShouldRun {
            engine.camera.start(deviceID: app.settings.cameraID)
        } else {
            engine.camera.stop()
            engine.resetPipeline()
        }
        FocusContext.shared.refresh()
    }

    /// Camera off when the screen locks, the display sleeps or the Mac sleeps.
    private func observeSystemState() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        let rules: [(NotificationCenter, Notification.Name, (AppState) -> Void)] = [
            (distributed, Notification.Name("com.apple.screenIsLocked"), { $0.screenLocked = true }),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), { $0.screenLocked = false }),
            (workspace, NSWorkspace.screensDidSleepNotification, { $0.displayAsleep = true }),
            (workspace, NSWorkspace.screensDidWakeNotification, { $0.displayAsleep = false }),
            (workspace, NSWorkspace.willSleepNotification, { $0.systemAsleep = true }),
            (workspace, NSWorkspace.didWakeNotification, { $0.systemAsleep = false })
        ]
        systemObservers = rules.map { center, name, apply in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                apply(self.app)
            }
        }
    }

    private func cleanUpClips() {
        let s = app.settings
        DispatchQueue.global(qos: .utility).async {
            let deleted = ClipStorage.enforceLimits(root: Paths.clips, retentionDays: s.clipRetentionDays,
                                                    capBytes: s.clipCapMB * 1_048_576)
            if !deleted.isEmpty {
                EventLog.shared.add(.info, nil, "Removed \(deleted.count) old clips to stay within limits")
                DispatchQueue.main.async { NotificationCenter.default.post(name: .steadyClipsChanged, object: nil) }
            }
        }
    }

    /// A menu bar app has no visible main menu, but text fields still need Edit shortcuts.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Steady", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

let application = NSApplication.shared
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
