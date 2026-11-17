import AppKit
import SwiftUI

extension AppState {
    func detectionBinding(_ kind: AlertKind) -> Binding<Bool> {
        Binding(get: { self.settings.detects(kind) },
                set: { self.setDetection(kind, enabled: $0) })
    }

    func inputPauseBinding(_ kind: AlertKind) -> Binding<Bool> {
        Binding(get: { self.settings.pausesOnInput(kind) },
                set: { self.settings.inputPauses[kind.rawValue] = $0 })
    }

    func colorBinding(_ kind: AlertKind) -> Binding<Color> {
        Binding(get: { kind.color },
                set: { color in
                    guard let hex = NSColor(color).hexString, hex != self.settings.alertColors[kind.rawValue] else { return }
                    self.settings.alertColors[kind.rawValue] = hex
                })
    }
}

/// Installed and running apps, for the study app picker.
enum AppCatalog {
    struct App: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage
    }

    static func load() async -> [App] {
        await Task.detached(priority: .userInitiated) {
            var found: [String: (String, URL)] = [:]
            let fm = FileManager.default
            let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                           NSHomeDirectory() + "/Applications"]
            for folder in folders {
                for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                    if let id = Bundle(url: url)?.bundleIdentifier {
                        found[id] = ((name as NSString).deletingPathExtension, url)
                    }
                }
            }
            return found
        }.value
        .merging(await MainActor.run {
            var running: [String: (String, URL)] = [:]
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                if let id = app.bundleIdentifier, let url = app.bundleURL { running[id] = (app.localizedName ?? id, url) }
            }
            return running
        }) { a, _ in a }
        .filter { $0.key != Bundle.main.bundleIdentifier }
        .map { id, value in
            let icon = NSWorkspace.shared.icon(forFile: value.1.path)
            icon.size = NSSize(width: 18, height: 18)
            return App(bundleID: id, name: value.0, icon: icon)
        }
    }
}

enum DataReset {
    static func deleteAll() {
        ModelStore.shared.deleteAll()
        StatsStore.shared.deleteAll()
        try? FileManager.default.removeItem(at: Paths.support.appendingPathComponent("Clips"))
        Engine.shared.resetPipeline()
        EventLog.shared.clear()
        EventLog.shared.add(.info, nil, "All Steady data deleted")
        NotificationCenter.default.post(name: .steadyClipsChanged, object: nil)
    }
}
