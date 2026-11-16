import AppKit
import SwiftUI

/// What one overlay flash shows.
final class OverlayModel: ObservableObject {
    @Published var kind = AlertKind.smile
    @Published var title = ""
    @Published var subtitle: String?
    @Published var quiet = false
}

/// Click-through, borderless windows (one per screen) that draw a soft glow around the screen edge.
/// They never take focus and never block clicks.
final class OverlayController {
    static let shared = OverlayController()

    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var windows: [OverlayWindow] = []
    private let model = OverlayModel()
    private var generation = 0

    func flash(_ kind: AlertKind, title: String, subtitle: String?, quiet: Bool) {
        model.kind = kind
        model.title = title
        model.subtitle = subtitle
        model.quiet = quiet
        rebuildWindowsIfNeeded()

        generation += 1
        let current = generation
        for w in windows {
            w.alphaValue = 0
            w.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            for w in windows { w.animator().alphaValue = 1 }
        }
        // Fade in 0.15 s, hold 0.8 s, fade out 0.6 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.6
                for w in self.windows { w.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                guard let self, self.generation == current else { return }
                for w in self.windows { w.orderOut(nil) }
            })
        }
    }

    private func rebuildWindowsIfNeeded() {
        let screens = NSScreen.screens
        if windows.count == screens.count, zip(windows, screens).allSatisfy({ $0.frame == $1.frame }) { return }
        windows.forEach { $0.orderOut(nil) }
        windows = screens.map { screen in
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .screenSaver
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.setFrame(screen.frame, display: false)
            w.contentView = NSHostingView(rootView: OverlayView(model: model, geometry: ScreenGeometry(screen)))
            return w
        }
    }
}

/// Shape details of a screen: rounded corners, notch, menu bar height.
struct ScreenGeometry {
    var size: CGSize
    var cornerRadius: CGFloat
    /// Notch rectangle in top-left-origin view coordinates, if the screen has one.
    var notch: CGRect?
    var menuBarHeight: CGFloat

    init(_ screen: NSScreen) {
        size = screen.frame.size
        menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let x0 = left.maxX - screen.frame.minX
            let x1 = right.minX - screen.frame.minX
            notch = CGRect(x: x0, y: 0, width: max(0, x1 - x0), height: top)
            cornerRadius = 12
        } else {
            notch = nil
            // Built-in displays without a notch still have slightly rounded corners.
            cornerRadius = screen.localizedName.lowercased().contains("built-in") ? 10 : 0
        }
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    let geometry: ScreenGeometry
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let color = model.kind.color
        let glowWidth: CGFloat = model.quiet ? 10 : 22
        let intensity: Double = model.quiet ? 0.45 : 0.9
        let shape = RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)

        ZStack(alignment: .top) {
            ZStack {
                shape.strokeBorder(color.opacity(intensity), lineWidth: glowWidth)
                    .blur(radius: glowWidth * 0.8)
                shape.strokeBorder(
                    LinearGradient(colors: [color.opacity(intensity), color.opacity(intensity * 0.6)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: model.quiet ? 2 : 3)
                    .blur(radius: 2)
            }
            .mask(notchMask)

            label
                .padding(.top, geometry.menuBarHeight + 12)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .allowsHitTesting(false)
    }

    /// Everything except the notch, so the glow stays clear of the camera housing.
    private var notchMask: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.white)
            if let notch = geometry.notch {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black)
                    .frame(width: notch.width + 24, height: notch.height + 12)
                    .offset(x: notch.minX - 12, y: -6)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: model.kind.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.kind.color)
                .font(.system(size: model.quiet ? 12 : 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(model.quiet ? .callout.weight(.medium) : .headline)
                if let subtitle = model.subtitle, !model.quiet {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, model.quiet ? 12 : 16)
        .padding(.vertical, model.quiet ? 6 : 10)
        .background {
            if reduceTransparency {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
        .overlay(Capsule().strokeBorder(model.kind.color.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .opacity(model.quiet ? 0.75 : 1)
        .accessibilityElement(children: .combine)
    }
}
