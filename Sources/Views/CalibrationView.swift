import SwiftUI

/// Runs the three smile calibration steps, trains the model and offers a live test.
final class SmileCalibrationController: ObservableObject {
    enum Phase: Equatable {
        case intro
        case getReady(Int)
        case capture(Int)
        case training
        case retry(String)
        case result
        case testing
    }

    struct Step {
        let title: String
        let instruction: String
    }

    static let steps = [
        Step(title: "Relaxed", instruction: "Read this paragraph normally."),
        Step(title: "Normal expressions", instruction: "Talk out loud, give a small natural smile, raise your eyebrows, yawn, purse your lips."),
        Step(title: "The stretched expression", instruction: "Do the stretched expression and hold it. Release and do it again 3 or 4 times.")
    ]

    static let readingText = """
    A SQL JOIN combines rows from two tables using a related column. An INNER JOIN returns only the rows \
    that have a match in both tables. A LEFT JOIN returns every row from the left table, and fills the \
    columns from the right table with NULL when there is no match. Indexes on the join columns let the \
    database find matching rows without scanning the whole table, which matters once tables grow past a \
    few thousand rows. When a query feels slow, the execution plan shows which join strategy was chosen: \
    nested loops for small inputs, hash joins for large unsorted inputs, and merge joins when both sides \
    are already sorted on the join key.
    """

    @Published var phase = Phase.intro
    @Published var remaining = 0.0
    @Published var stepProgress = 0.0
    @Published var framesThisStep = 0
    @Published var model: LogisticModel?
    @Published var keptPositives = 0
    /// True when only the stretched-smile step needs repeating.
    @Published var retryStep3 = false

    let stepDuration = 15.0
    let readyDuration = 3.0
    let testDuration = 20.0

    private var relaxed: [[Double]] = []
    private var expressions: [[Double]] = []
    private var stretchedRaw: [[Double]] = []
    private var motion: [Double] = []
    private var phaseStart = Date()
    private var timer: Timer?
    private var active = false

    var cameraAvailable: Bool { AppState.shared.cameraAuthorization == .authorized }

    /// Called when the window opens: the camera turns on for the preview and alerts pause.
    func open() {
        active = true
        AppState.shared.calibrationActive = true
        FocusContext.shared.refresh()
    }

    func begin() {
        open()
        relaxed = []; expressions = []; stretchedRaw = []; motion = []
        Engine.shared.calibrationSink.set { [weak self] a in self?.receive(a) }
        startPhase(.getReady(1))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        active = false
        Engine.shared.calibrationSink.set(nil)
        AppState.shared.calibrationActive = false
        FocusContext.shared.refresh()
    }

    func retryStretched() {
        stretchedRaw = []
        startPhase(.getReady(3))
    }

    func startTest() {
        startPhase(.testing)
    }

    private func startPhase(_ p: Phase) {
        phase = p
        phaseStart = Date()
        framesThisStep = 0
        stepProgress = 0
        switch p {
        case .getReady: remaining = readyDuration
        case .capture: remaining = stepDuration
        case .testing: remaining = testDuration
        default: remaining = 0
        }
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(phaseStart)
        switch phase {
        case .getReady(let step):
            remaining = max(0, readyDuration - elapsed)
            if elapsed >= readyDuration { startPhase(.capture(step)) }
        case .capture(let step):
            remaining = max(0, stepDuration - elapsed)
            stepProgress = min(1, elapsed / stepDuration)
            if elapsed >= stepDuration { finishCapture(step) }
        case .testing:
            remaining = max(0, testDuration - elapsed)
            stepProgress = min(1, elapsed / testDuration)
            if elapsed >= testDuration { phase = .result }
        default:
            break
        }
    }

    private func receive(_ a: FrameAnalysis) {
        guard case .capture(let step) = phase, a.facePresent, let f = a.smileFeatures else { return }
        framesThisStep += 1
        switch step {
        case 1:
            relaxed.append(f)
            motion.append(a.motionEnergy)
        case 2: expressions.append(f)
        default: stretchedRaw.append(f)
        }
    }

    private func finishCapture(_ step: Int) {
        if step < 3 {
            if step == 1, relaxed.count < 30 {
                retryStep3 = false
                phase = .retry("Only \(relaxed.count) frames had a clear view of your face. Sit facing the camera in even light and try again.")
                relaxed = []
                return
            }
            startPhase(.getReady(step + 1))
            return
        }
        // Keep only frames where the mouth is clearly wider than when relaxed,
        // so release moments are not labelled as the smile.
        let widths = relaxed.map { $0[0] }
        let mean = widths.reduce(0, +) / Double(max(1, widths.count))
        let std = (widths.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, widths.count))).squareRoot()
        let cut = mean + max(2 * std, 0.04 * mean)
        let positives = stretchedRaw.filter { $0[0] > cut }
        keptPositives = positives.count
        guard positives.count >= 15 else {
            retryStep3 = true
            phase = .retry("Only \(positives.count) frames looked wider than your relaxed mouth. "
                + "Try step 3 again and pull the corners a little wider.")
            return
        }
        phase = .training
        let negatives = relaxed + expressions
        let relaxedMeans = (0..<FaceFeatures.smileCount).map { i in relaxed.map { $0[i] }.reduce(0, +) / Double(relaxed.count) }
        let calm = motion.sorted()[motion.count / 2]
        ModelStore.shared.update { file in
            file.smileRelaxedMeans = relaxedMeans
            file.calmMotion = calm
            file.calmMotionQuality = Engine.shared.quality.get().rawValue
        }
        Engine.shared.setCalmMotion(calm)
        ModelStore.shared.calibrate(.smile, positives: positives, negatives: negatives) { [weak self] model in
            guard let self else { return }
            self.model = model
            if model == nil {
                self.retryStep3 = false
                self.phase = .retry("Training did not finish. Please run the calibration again.")
            } else {
                EventLog.shared.add(.info, .smile, String(format: "Expression model trained, accuracy %.0f%%", (model?.accuracy ?? 0) * 100))
                self.phase = .result
            }
        }
    }
}

struct SmileCalibrationView: View {
    @ObservedObject var controller: SmileCalibrationController
    @ObservedObject private var app = AppState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 600)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.3), value: controller.phase)
    }

    // MARK: Header

    private var stepNumber: Int? {
        switch controller.phase {
        case .getReady(let s), .capture(let s): return s
        default: return nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(1...3, id: \.self) { i in
                    Capsule()
                        .fill(i <= (stepNumber ?? (isFinished ? 3 : 0)) ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 28, height: 4)
                }
                if let s = stepNumber {
                    Text("Step \(s) of 3").font(.callout).foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stepNumber.map { "Step \($0) of 3" } ?? "Expression calibration")
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isFinished: Bool {
        switch controller.phase {
        case .result, .testing, .training: return true
        default: return false
        }
    }

    private var title: String {
        switch controller.phase {
        case .intro: return "Calibrate expression"
        case .getReady(let s), .capture(let s): return SmileCalibrationController.steps[s - 1].title
        case .training: return "Training"
        case .retry: return "One more try"
        case .result: return "Calibration done"
        case .testing: return "Test it now"
        }
    }

    private var subtitle: String {
        switch controller.phase {
        case .intro:
            return "Three short steps of 15 seconds each, about a minute in total. "
                + "Steady learns how your face looks when relaxed, during normal expressions, and during the stretched expression."
        case .getReady: return "Get ready. Recording starts in a moment."
        case .capture(let s): return SmileCalibrationController.steps[s - 1].instruction
        case .training: return "Learning from your frames. This takes a few seconds."
        case .retry(let message): return message
        case .result: return resultSentence
        case .testing: return "Relax, then do the stretched expression. The meter shows what the model sees."
        }
    }

    private var resultSentence: String {
        guard let acc = controller.model?.accuracy else { return "The model is ready." }
        if acc >= 0.9 { return "The model tells your stretched expression apart from your normal face well." }
        if acc >= 0.75 { return "This should work. If alerts feel off, run calibration again in brighter, even light." }
        return "Your expression and your normal face look similar to the model. Try again with brighter, even light and a clearer expression."
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !controller.cameraAvailable {
            Label("Steady needs camera access for calibration. Allow it in System Settings, then open this window again.",
                  systemImage: "video.slash")
                .font(.body)
            Button("Open Camera Settings") { Actions.openCameraSettings() }
        } else {
            switch controller.phase {
            case .intro:
                introContent
            case .getReady, .capture:
                captureContent
            case .training:
                HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }.padding(.top, 60)
            case .retry:
                preview.frame(maxHeight: 320)
            case .result:
                resultContent
            case .testing:
                testContent
            }
        }
    }

    private var preview: some View {
        CameraOverlayView(layers: [.face], mirrored: app.settings.debugMirror, showBanner: false)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .accessibilityLabel("Camera preview")
    }

    private var introContent: some View {
        HStack(alignment: .top, spacing: 24) {
            preview.frame(maxWidth: 360)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(SmileCalibrationController.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)").font(.headline).monospacedDigit()
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.accentColor.opacity(0.15)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.headline)
                            Text(step.instruction).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Sit as you normally do when you study, facing the screen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var captureContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                preview
                    .frame(maxWidth: stepNumber == 1 ? 320 : 440)
                    .overlay(alignment: .topTrailing) { countdownRing.padding(10) }
                if stepNumber == 1 {
                    ScrollView {
                        Text(SmileCalibrationController.readingText)
                            .font(.body)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Metrics.spacing)
                    }
                    .frame(maxHeight: 280)
                    .cardBackground()
                }
            }
            ProgressView(value: controller.stepProgress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Step progress")
            Text("\(controller.framesThisStep) frames with your face so far")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var countdownRing: some View {
        let total = controller.phase == .capture(stepNumber ?? 1) ? controller.stepDuration : controller.readyDuration
        let fraction = total > 0 ? controller.remaining / total : 0
        return ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 4)
            Circle().trim(from: 0, to: fraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(controller.remaining.rounded(.up)))")
                .font(.headline).monospacedDigit().foregroundStyle(.white)
        }
        .frame(width: 48, height: 48)
        .background(Circle().fill(.black.opacity(0.35)))
        .accessibilityLabel("\(Int(controller.remaining.rounded(.up))) seconds left")
    }

    private var resultContent: some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 6) {
                Text(controller.model?.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "Ready")
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("accuracy on frames held back from training")
                    .font(.callout).foregroundStyle(.secondary)
                if let m = controller.model {
                    Text("\(m.positives) stretched-expression frames, \(m.negatives) relaxed and normal frames")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            preview.frame(maxWidth: 320)
        }
        .padding(.top, 12)
    }

    private var testContent: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in
            let snap = Engine.shared.snapshot.get()
            let p = snap.smile.smoothed
            let above = p > app.settings.smileThreshold
            VStack(alignment: .leading, spacing: 14) {
                preview.frame(maxWidth: 440)
                MeterRow(label: "Expression p", value: p, threshold: app.settings.smileThreshold,
                         color: AlertKind.smile.color, text: String(format: "%.2f", p))
                HStack {
                    Label(above ? "Above threshold" : "Below threshold", systemImage: above ? "mouth.fill" : "mouth")
                        .foregroundStyle(above ? AlertKind.smile.color : .secondary)
                    Spacer()
                    Text("\(Int(controller.remaining.rounded(.up))) s left").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
                .opacity(isDone ? 0 : 1)
                .disabled(isDone)
            Spacer()
            switch controller.phase {
            case .intro:
                Button("Start Calibration") { controller.begin() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.cameraAvailable)
            case .retry:
                if controller.retryStep3 {
                    Button("Redo Step 3") { controller.retryStretched() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Again") { controller.begin() }.keyboardShortcut(.defaultAction)
                }
            case .result:
                Button("Calibrate Again") { controller.begin() }
                Button("Test It Now") { controller.startTest() }
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            case .testing:
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            default:
                EmptyView()
            }
        }
    }

    private var isDone: Bool {
        if case .result = controller.phase { return true }
        if case .testing = controller.phase { return true }
        return false
    }

    private func close() {
        controller.cancel()
        WindowManager.shared.close("smileCalibration")
    }
}
