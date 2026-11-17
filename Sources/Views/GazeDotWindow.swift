import AppKit
import SwiftUI

/// Gaze calibration: a fullscreen dot to follow (on-screen samples), then looking away (off-screen samples).
final class GazeCalibration: ObservableObject {
    static let shared = GazeCalibration()

    enum Phase: Equatable {
        case intro
        case getReady
        case onScreen
        case lookAwayIntro
        case offScreen
        case training
        case retry(String)
        case result
    }

    @Published var phase = Phase.intro
    @Published var elapsed = 0.0
    @Published var model: LogisticModel?
    @Published var onCount = 0
    @Published var offCount = 0

    let readyDuration = 3.0
    let onScreenDuration = 20.0
    let lookAwayIntroDuration = 5.0
    let offScreenDuration = 15.0

    private var window: NSWindow?
    private var keyMonitor: Any?
    private var timer: Timer?
    private var phaseStart = Date()
    private var onScreen: [[Double]] = []
    private var offScreen: [[Double]] = []

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    // MARK: Window

    func begin() {
        if window != nil { window?.makeKeyAndOrderFront(nil); return }
        // Calibrate the main display only.
        guard let screen = NSScreen.screens.first else { return }
        let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.blendingMode = .behindWindow
        blur.material = .fullScreenUI
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: GazeCalibrationView(calibration: self))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        w.contentView = blur
        w.setFrame(screen.frame, display: true)
        window = w

        phase = .intro
        model = nil
        AppState.shared.calibrationActive = true
        FocusContext.shared.refresh()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: // Esc
                self.close(); return nil
            case 49, 36: // Space, Return
                switch self.phase {
                case .intro, .retry: self.start(); return nil
                case .result: self.close(); return nil
                default: return nil
                }
            default:
                return event
            }
        }
    }

    func close() {
        timer?.invalidate(); timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        Engine.shared.calibrationSink.set(nil)
        window?.orderOut(nil)
        window = nil
        AppState.shared.calibrationActive = false
        FocusContext.shared.refresh()
    }

    // MARK: Flow

    func start() {
        onScreen = []; offScreen = []
        onCount = 0; offCount = 0
        Engine.shared.calibrationSink.set { [weak self] a in self?.receive(a) }
        setPhase(.getReady)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func setPhase(_ p: Phase) {
        phase = p
        phaseStart = Date()
        elapsed = 0
    }

    private func tick() {
        elapsed = Date().timeIntervalSince(phaseStart)
        switch phase {
        case .getReady where elapsed >= readyDuration:
            setPhase(.onScreen)
        case .onScreen where elapsed >= onScreenDuration:
            setPhase(.lookAwayIntro)
        case .lookAwayIntro where elapsed >= lookAwayIntroDuration:
            AlertCenter.shared.playSound("Tink", volume: 0.5)
            setPhase(.offScreen)
        case .offScreen where elapsed >= offScreenDuration:
            AlertCenter.shared.playSound("Glass", volume: 0.7)
            finish()
        default:
            break
        }
    }

    private func receive(_ a: FrameAnalysis) {
        guard a.facePresent, let f = a.gazeFeatures else { return }
        switch phase {
        case .onScreen where elapsed > 0.8:
            // Skip the first moment so the eyes have caught the dot.
            onScreen.append(f); onCount = onScreen.count
        case .offScreen where elapsed > 1.5:
            offScreen.append(f); offCount = offScreen.count
        default:
            break
        }
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        Engine.shared.calibrationSink.set(nil)
        guard onScreen.count >= 40 else {
            setPhase(.retry("Only \(onScreen.count) frames showed your face while you followed the dot. Sit facing the camera and try again."))
            return
        }
        guard offScreen.count >= 20 else {
            setPhase(.retry("Only \(offScreen.count) frames showed your face while you looked away. Turning very far hides the face, "
                + "which Steady already counts as looking away. Try again and look away a little less far."))
            return
        }
        setPhase(.training)
        // Off-screen is the positive class: the model gives p(off-screen).
        ModelStore.shared.calibrate(.gaze, positives: offScreen, negatives: onScreen) { [weak self] model in
            guard let self else { return }
            self.model = model
            if let model {
                EventLog.shared.add(.info, .lookAway, String(format: "Gaze model trained, accuracy %.0f%%", (model.accuracy ?? 0) * 100))
                self.setPhase(.result)
            } else {
                self.setPhase(.retry("Training did not finish. Please try again."))
            }
        }
    }

    // MARK: Dot path

    /// Waypoints in normalized screen coordinates (origin top-left): centre, corners and edges.
    static let path: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.06, y: 0.08), CGPoint(x: 0.5, y: 0.08), CGPoint(x: 0.94, y: 0.08),
        CGPoint(x: 0.94, y: 0.5), CGPoint(x: 0.94, y: 0.92), CGPoint(x: 0.5, y: 0.92), CGPoint(x: 0.06, y: 0.92),
        CGPoint(x: 0.06, y: 0.5), CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.5, y: 0.5)
    ]

    func dotPosition(at t: Double) -> CGPoint {
        let segments = Self.path.count - 1
        let progress = max(0, min(1, t / onScreenDuration)) * Double(segments)
        let i = min(segments - 1, Int(progress))
        var f = progress - Double(i)
        f = f * f * (3 - 2 * f) // ease in and out at each waypoint
        let a = Self.path[i], b = Self.path[i + 1]
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}

struct GazeCalibrationView: View {
    @ObservedObject var calibration: GazeCalibration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.55)
                switch calibration.phase {
                case .onScreen:
                    dot(in: geo.size)
                default:
                    panel
                        .frame(maxWidth: 520)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func dot(in size: CGSize) -> some View {
        TimelineView(.animation) { _ in
            let p = calibration.dotPosition(at: calibration.elapsed)
            ZStack {
                Circle().fill(Color.white.opacity(0.25)).frame(width: 44, height: 44).blur(radius: 10)
                Circle().fill(Color.white).frame(width: 14, height: 14)
                    .shadow(color: .white.opacity(0.9), radius: 8)
                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
            }
            .position(x: p.x * size.width, y: p.y * size.height)
            .accessibilityLabel("Calibration dot")
        }
        .overlay(alignment: .bottom) {
            Text("Follow the dot with your eyes")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 40)
        }
    }

    private var panel: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
            Text(title).font(.largeTitle.weight(.semibold)).foregroundStyle(.white)
            Text(message)
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            countdown
            buttons
        }
        .padding(32)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black.opacity(0.35)))
        .environment(\.colorScheme, .dark)
    }

    private var icon: String {
        switch calibration.phase {
        case .intro, .getReady: return "scope"
        case .lookAwayIntro, .offScreen: return "arrow.up.left.and.arrow.down.right"
        case .training: return "gearshape.2"
        case .retry: return "arrow.counterclockwise"
        case .result: return "checkmark.circle"
        case .onScreen: return "scope"
        }
    }

    private var title: String {
        switch calibration.phase {
        case .intro: return "Calibrate gaze"
        case .getReady: return "Get ready"
        case .onScreen: return ""
        case .lookAwayIntro: return "Now look away"
        case .offScreen: return "Keep looking away"
        case .training: return "Training"
        case .retry: return "One more try"
        case .result:
            if let acc = calibration.model?.accuracy { return "\(Int((acc * 100).rounded()))% accuracy" }
            return "Calibration done"
        }
    }

    private var message: String {
        switch calibration.phase {
        case .intro:
            return "First, a dot moves slowly around the screen for 20 seconds. Follow it with your eyes. "
                + "Then you look away for 15 seconds. Press Space to start or Esc to cancel."
        case .getReady:
            return "Look at the dot when it appears."
        case .onScreen:
            return ""
        case .lookAwayIntro:
            return "Look at the left wall, the right side, the ceiling, your phone in your lap and over the laptop. "
                + "Move between them. A sound plays when you can look back."
        case .offScreen:
            return "Keep moving your gaze between places away from the screen. \(calibration.offCount) frames so far."
        case .training:
            return "Learning from \(calibration.onCount) on-screen and \(calibration.offCount) away frames."
        case .retry(let text):
            return text
        case .result:
            guard let acc = calibration.model?.accuracy else { return "The gaze model is ready." }
            if acc >= 0.9 { return "Steady can tell when your eyes leave the screen. Press Return to finish." }
            if acc >= 0.75 { return "This should work. If look-away alerts feel off, calibrate again in even light." }
            return "On-screen and away looked similar to the model. Try again and look further away in step 2."
        }
    }

    @ViewBuilder
    private var countdown: some View {
        switch calibration.phase {
        case .getReady:
            Text("\(Int((calibration.readyDuration - calibration.elapsed).rounded(.up)))")
                .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
        case .lookAwayIntro:
            Text("Starting in \(Int((calibration.lookAwayIntroDuration - calibration.elapsed).rounded(.up))) s")
                .font(.headline).monospacedDigit().foregroundStyle(.white.opacity(0.9))
        case .offScreen:
            ProgressView(value: min(1, calibration.elapsed / calibration.offScreenDuration))
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 280)
        case .training:
            ProgressView().controlSize(.large)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch calibration.phase {
        case .intro, .retry:
            HStack(spacing: 12) {
                Button("Cancel") { calibration.close() }
                Button("Start") { calibration.start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        case .result:
            HStack(spacing: 12) {
                Button("Calibrate Again") { calibration.start() }
                Button("Done") { calibration.close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        default:
            Button("Cancel") { calibration.close() }
                .controlSize(.regular)
        }
    }
}
