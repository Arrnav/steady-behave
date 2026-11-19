import AppKit
import Combine
import ServiceManagement

/// The menu bar icon and its menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var flashKind: AlertKind?
    private var flashWork: DispatchWorkItem?

    private let app = AppState.shared
    private let focus = FocusContext.shared

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityLabel("Steady")

        app.objectWillChange
            .merge(with: focus.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateButton() }
            .store(in: &cancellables)
        AlertCenter.shared.onFlash = { [weak self] kind in self?.flash(kind) }
        updateButton()
    }

    // MARK: Icon

    private func symbolName() -> String {
        if app.isPaused { return "eye.slash" }
        if focus.sessionActive { return "book" }
        return "eye"
    }

    func updateButton() {
        guard let button = item.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        var image = NSImage(systemSymbolName: symbolName(), accessibilityDescription: "Steady")?
            .withSymbolConfiguration(config)
        if let kind = flashKind {
            // Brief colour flash during an alert; otherwise a monochrome template icon.
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [kind.nsColor]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        if let title = focus.menuTitle {
            button.title = " " + title
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            button.title = ""
        }
    }

    func flash(_ kind: AlertKind) {
        flashKind = kind
        updateButton()
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flashKind = nil
            self?.updateButton()
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    // MARK: Menu

    func openMenu() {
        item.button?.performClick(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(NSMenuItem.sectionHeader(title: "Steady"))

        if app.cameraAuthorization == .denied || app.cameraAuthorization == .restricted {
            menu.addItem(item("Allow Camera Access", symbol: "video.slash", action: #selector(openCameraSettings)))
        }

        let paused = app.isPaused
        let monitoring = item(paused ? "Monitoring: Paused" : "Monitoring: On",
                              symbol: paused ? "eye.slash" : "eye", action: #selector(toggleMonitoring))
        menu.addItem(monitoring)

        if let session = focus.session {
            let clock = focus.sessionClock ?? 0
            let text = session.length == nil ? "\(Format.duration(clock)) so far" : "\(Format.duration(clock)) left"
            let end = item("End Study Session (\(text))", symbol: "book.closed", action: #selector(endSession))
            end.keyEquivalent = "s"
            end.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(end)
        } else {
            let start = item("Start Study Session", symbol: "book", action: #selector(startDefaultSession))
            start.keyEquivalent = "s"
            start.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(start)
            let lengths = NSMenuItem(title: "Session Length", action: nil, keyEquivalent: "")
            setIcon(lengths, "timer")
            let sub = NSMenu()
            for (title, minutes) in [("25 Minutes", 25), ("50 Minutes", 50), ("90 Minutes", 90), ("Open-Ended", 0)] {
                let m = item("Start \(title)", symbol: nil, action: #selector(startSession(_:)))
                m.tag = minutes
                sub.addItem(m)
            }
            lengths.submenu = sub
            menu.addItem(lengths)
        }

        menu.addItem(.separator())
        let summary = NSMenuItem(title: StatsStore.shared.todaySummary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        summary.attributedTitle = NSAttributedString(string: StatsStore.shared.todaySummary, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.menuFont(ofSize: 0)
        ])
        menu.addItem(summary)
        let smileOn = app.settings.detects(.smile)
        if smileOn, ModelStore.shared.smile == nil {
            menu.addItem(disabled("Expression alerts start after calibration"))
        }
        if app.cameraRunning == false, !paused, app.cameraAuthorization == .authorized {
            if app.screenLocked || app.displayAsleep { menu.addItem(disabled("Camera off while the screen is locked")) }
        }
        if let hold = app.cameraHold, !paused {
            menu.addItem(disabled(hold.menuText))
        }
        if let quiet = focus.quietReason {
            menu.addItem(disabled("Quiet mode: \(quiet)"))
        }

        menu.addItem(.separator())
        let falseAlarm = item("False Alarm", symbol: "xmark.circle", action: #selector(falseAlarm))
        falseAlarm.keyEquivalent = "x"
        falseAlarm.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(falseAlarm)
        let missed = item("Missed One (I'm Doing It Now)", symbol: "plus.circle", action: #selector(missedOne))
        missed.keyEquivalent = "m"
        missed.keyEquivalentModifierMask = [.control, .option]
        missed.isEnabled = smileOn && ModelStore.shared.smile != nil
        menu.addItem(missed)

        menu.addItem(.separator())
        if app.isQuietManual {
            menu.addItem(item("End Quiet Hour", symbol: "speaker.wave.2", action: #selector(endQuiet)))
        } else {
            menu.addItem(item("Quiet for 1 Hour", symbol: "speaker.slash", action: #selector(quietHour)))
        }
        if paused {
            menu.addItem(item(resumeTitle(), symbol: "play.circle", action: #selector(resume)))
        } else {
            let pause = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
            setIcon(pause, "pause.circle")
            let sub = NSMenu()
            for (title, seconds) in [("15 Minutes", 900), ("1 Hour", 3600), ("Until Resumed", 0)] {
                let m = item(title, symbol: nil, action: #selector(pause(_:)))
                m.tag = seconds
                sub.addItem(m)
            }
            pause.submenu = sub
            menu.addItem(pause)
        }

        let detections = NSMenuItem(title: "Detections", action: nil, keyEquivalent: "")
        setIcon(detections, "checklist")
        let detectionMenu = NSMenu()
        for kind in AlertKind.allCases {
            let m = NSMenuItem(title: kind.detectionTitle, action: #selector(toggleDetection(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = kind.rawValue
            m.state = app.settings.detects(kind) ? .on : .off
            detectionMenu.addItem(m)
        }
        detections.submenu = detectionMenu
        menu.addItem(detections)

        menu.addItem(.separator())
        menu.addItem(item("Clips", symbol: "film", action: #selector(openClips)))
        menu.addItem(item("Stats", symbol: "chart.bar", action: #selector(openStats)))
        menu.addItem(item("Calibrate Expression", symbol: "mouth", action: #selector(calibrateSmile)))
        menu.addItem(item("Calibrate Gaze", symbol: "scope", action: #selector(calibrateGaze)))
        let debug = item("Debug Mode", symbol: "waveform.path.ecg", action: #selector(openDebug))
        debug.keyEquivalent = "d"
        debug.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(debug)
        // macOS adds its own gear icon to a "Settings" item with Command-comma.
        let settings = item("Settings", symbol: nil, action: #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)

        menu.addItem(.separator())
        let login = item("Open at Login", symbol: nil, action: #selector(toggleLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        let quit = item("Quit Steady", symbol: nil, action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func resumeTitle() -> String {
        if let until = app.pausedUntil, until != .distantFuture {
            let mins = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
            return "Resume (Paused for \(mins) More Min)"
        }
        return "Resume Monitoring"
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func item(_ title: String, symbol name: String?, action: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
        m.target = self
        if let name { setIcon(m, name) }
        return m
    }

    /// Recent macOS versions don't draw `NSMenuItem.image` in status menus, but they do draw
    /// state images, in the same column native menus use for icons.
    private func setIcon(_ m: NSMenuItem, _ name: String) {
        let image = symbol(name)
        m.onStateImage = image
        m.offStateImage = image
        m.state = .off
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        m.isEnabled = false
        return m
    }

    // MARK: Actions

    @objc private func toggleMonitoring() {
        if app.isPaused { app.resume() } else { app.monitoringEnabled = false }
        FocusContext.shared.refresh()
    }

    @objc private func toggleDetection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = AlertKind(rawValue: raw) else { return }
        app.setDetection(kind, enabled: !app.settings.detects(kind))
    }

    @objc private func startDefaultSession() { focus.toggleSession() }
    @objc private func endSession() { focus.stopSession(completed: false) }
    @objc private func startSession(_ sender: NSMenuItem) {
        focus.startSession(minutes: sender.tag > 0 ? sender.tag : nil)
    }

    @objc private func falseAlarm() { Actions.falseAlarm() }
    @objc private func missedOne() { Actions.missedOne() }

    @objc private func quietHour() {
        app.quietUntil = Date().addingTimeInterval(3600)
        EventLog.shared.add(.info, nil, "Quiet for 1 hour")
        focus.refresh()
    }

    @objc private func endQuiet() {
        app.quietUntil = nil
        focus.refresh()
    }

    @objc private func pause(_ sender: NSMenuItem) {
        app.pause(for: sender.tag > 0 ? TimeInterval(sender.tag) : nil)
        EventLog.shared.add(.info, nil, sender.tag > 0 ? "Paused for \(sender.tag / 60) min" : "Paused until resumed")
        focus.refresh()
    }

    @objc private func resume() {
        app.resume()
        EventLog.shared.add(.info, nil, "Monitoring resumed")
        focus.refresh()
    }

    @objc private func openCameraSettings() { Actions.openCameraSettings() }
    @objc private func openClips() { Actions.showClips() }
    @objc private func openStats() { Actions.showStats() }
    @objc private func calibrateSmile() { Actions.showSmileCalibration() }
    @objc private func calibrateGaze() { Actions.showGazeCalibration() }
    @objc private func openDebug() { Actions.showDebug() }
    @objc private func openSettings() { Actions.showSettings() }
    @objc private func toggleLogin() { LoginItem.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Open at login through SMAppService.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        set(!isEnabled)
    }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            EventLog.shared.add(.info, nil, "Open at login could not be changed: \(error.localizedDescription)")
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}
