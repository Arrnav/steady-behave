import AppKit
import SwiftUI

/// The four habits Steady can notice. Each has one colour, sound, symbol and text used everywhere.
enum AlertKind: String, Codable, CaseIterable, Identifiable {
    case smile
    case lookAway
    case overActive
    case handsAtFace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smile: return "Smile"
        case .lookAway: return "Look-away"
        case .overActive: return "Over-active"
        case .handsAtFace: return "Hands at face"
        }
    }

    /// Soft, slightly desaturated colours that read well in light and dark mode.
    var nsColor: NSColor {
        switch self {
        case .smile: return NSColor(srgbRed: 0.93, green: 0.60, blue: 0.36, alpha: 1)
        case .lookAway: return NSColor(srgbRed: 0.38, green: 0.58, blue: 0.90, alpha: 1)
        case .overActive: return NSColor(srgbRed: 0.63, green: 0.50, blue: 0.86, alpha: 1)
        case .handsAtFace: return NSColor(srgbRed: 0.30, green: 0.71, blue: 0.68, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var symbol: String {
        switch self {
        case .smile: return "mouth"
        case .lookAway: return "eyes"
        case .overActive: return "figure.walk.motion"
        case .handsAtFace: return "hand.raised"
        }
    }

    var overlayText: String {
        switch self {
        case .smile: return "Relax your face"
        case .lookAway: return "Back to the screen"
        case .overActive: return "Slow down, settle"
        case .handsAtFace: return "Hands down"
        }
    }

    var defaultSound: String {
        switch self {
        case .smile: return "Tink"
        case .lookAway: return "Pop"
        case .overActive: return "Purr"
        case .handsAtFace: return "Pop"
        }
    }

    /// Over-active and hands-at-face alerts play at a lower volume.
    var volumeFactor: Float {
        switch self {
        case .smile, .lookAway: return 1.0
        case .overActive, .handsAtFace: return 0.45
        }
    }
}

/// Small layout constants on an 8-point grid.
enum Metrics {
    static let corner: CGFloat = 12
    static let smallCorner: CGFloat = 8
    static let spacing: CGFloat = 16
    static let tight: CGFloat = 8
}

extension View {
    /// Rounded material card that falls back to a solid colour when Reduce Transparency is on.
    func cardBackground(cornerRadius: CGFloat = Metrics.corner) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor),
                               in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// Formatting helpers for durations shown in the UI.
enum Format {
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
