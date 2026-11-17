import AppKit
import Foundation

/// Shows a nudge: edge glow, menu bar icon flash, sound and trackpad haptic. Main thread only.
final class AlertCenter {
    static let shared = AlertCenter()

    /// Set by the status bar controller to flash the menu bar icon.
    var onFlash: ((AlertKind) -> Void)?

    /// System sounds available in /System/Library/Sounds.
    static let systemSounds: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let names = files.filter { $0.hasSuffix(".aiff") }.map { ($0 as NSString).deletingPathExtension }.sorted()
        return names.isEmpty ? ["Basso", "Frog", "Glass", "Pop", "Purr", "Submarine", "Tink"] : names
    }()

    /// Shows an alert. Real alerts also count toward escalation; test alerts don't.
    func fire(_ kind: AlertKind, quiet: Bool, escalate: Bool = true) {
        let settings = AppState.shared.settings
        let subtitle = kind == .smile ? settings.competingResponse : nil
        OverlayController.shared.flash(kind, title: kind.overlayText, subtitle: subtitle, quiet: quiet)
        onFlash?(kind)
        if escalate { EscalationCenter.shared.alertFired(kind, quiet: quiet) }
        // Quiet mode (calls or the quiet hour) keeps only a small, faint visual.
        guard !quiet else { return }
        if settings.sound(for: kind) {
            playSound(settings.soundName(for: kind), volume: Float(settings.volume) * kind.volumeFactor)
        }
        if settings.haptic(for: kind) {
            Haptics.shared.alert(kind, settings: settings)
        }
    }

    /// Plays a test alert from debug mode or settings, logged as a simulation.
    func simulate(_ kind: AlertKind) {
        EventLog.shared.add(.info, kind, "Simulated alert")
        Engine.shared.markers.update { $0.append(AlertMarker(t: monotonicNow(), kind: kind)) }
        fire(kind, quiet: FocusContext.shared.quietReason != nil, escalate: false)
    }

    func playSound(_ name: String, volume: Float) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = max(0, min(1, volume))
        sound.play()
    }

    func chime() {
        playSound("Glass", volume: Float(AppState.shared.settings.volume))
    }
}
