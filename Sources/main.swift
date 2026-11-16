import AppKit
import AVFoundation
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var cancellables: Set<AnyCancellable> = []
    private var cleanupTimer: Timer?
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

    /// `--show debug,settings,...` opens windows at launch (handy for checking layouts).
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
                case "smile": Actions.showSmileCalibration()
                case "gaze": Actions.showGazeCalibration()
                default: break
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        StatsStore.shared.saveNow()
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
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.app.screenLocked = true
        }
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.app.screenLocked = false
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.app.displayAsleep = true
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.app.displayAsleep = false
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.app.systemAsleep = true
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.app.systemAsleep = false
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
