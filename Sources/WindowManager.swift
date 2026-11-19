import AppKit
import SwiftUI

/// Creates and remembers Steady's windows. Sizes and positions are saved between launches.
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]

    func window(_ id: String) -> NSWindow? { windows[id] }

    func isOpen(_ id: String) -> Bool { windows[id]?.isVisible ?? false }

    @discardableResult
    func show<V: View>(_ id: String, title: String, size: NSSize, minSize: NSSize? = nil,
                       resizable: Bool = true, onClose: (() -> Void)? = nil, content: () -> V) -> NSWindow {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return existing
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        if let minSize { window.contentMinSize = minSize }
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.center()
        window.setFrameAutosaveName("Steady.\(id)")
        windows[id] = window
        if let onClose { closeHandlers[id] = onClose }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return window
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        let handler = closeHandlers.removeValue(forKey: id)
        // Let SwiftUI tear down after the close finishes.
        DispatchQueue.main.async { handler?() }
    }
}

/// Things the menu, hotkeys and windows can ask for.
enum Actions {
    static func falseAlarm() {
        Engine.shared.falseAlarm()
        StatsStore.shared.update { $0.falseAlarms += 1 }
    }

    static func missedOne() {
        guard AppState.shared.settings.detects(.smile) else {
            EventLog.shared.add(.feedback, .smile, "Missed one: expression detection is off")
            return
        }
        guard ModelStore.shared.smile != nil else {
            EventLog.shared.add(.feedback, .smile, "Missed one: calibrate the expression first")
            return
        }
        Engine.shared.missedOne()
        StatsStore.shared.update { $0.missed += 1 }
    }

    static func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    static func showSettings() {
        WindowManager.shared.show("settings", title: "Steady Settings", size: NSSize(width: 720, height: 560),
                                  minSize: NSSize(width: 640, height: 440)) {
            SettingsView()
        }
    }

    static func showDebug() {
        DebugWindow.show()
    }

    static func showClips() {
        WindowManager.shared.show("clips", title: "Clips", size: NSSize(width: 1040, height: 620),
                                  minSize: NSSize(width: 820, height: 460)) {
            ClipsView()
        }
    }

    static func showStats() {
        WindowManager.shared.show("stats", title: "Stats", size: NSSize(width: 760, height: 640),
                                  minSize: NSSize(width: 620, height: 520)) {
            StatsView()
        }
    }

    static func showSmileCalibration() {
        if WindowManager.shared.isOpen("smileCalibration") {
            WindowManager.shared.window("smileCalibration")?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let controller = SmileCalibrationController()
        controller.open()
        WindowManager.shared.show("smileCalibration", title: "Calibrate Expression", size: NSSize(width: 760, height: 640),
                                  minSize: NSSize(width: 680, height: 600), onClose: { controller.cancel() },
                                  content: { SmileCalibrationView(controller: controller) })
    }

    static func showGazeCalibration() {
        GazeCalibration.shared.begin()
    }

    static func showSessionSummary(_ summary: FocusContext.SessionSummary) {
        WindowManager.shared.close("summary")
        let w = WindowManager.shared.show("summary", title: "Study Session", size: NSSize(width: 380, height: 300),
                                          resizable: false) {
            SessionSummaryView(summary: summary)
        }
        w.level = .floating
    }
}
