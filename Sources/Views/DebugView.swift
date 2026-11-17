import AppKit
import Charts
import SwiftUI

/// Pulls readouts from the engine ten times a second for the debug window.
final class DebugModel: ObservableObject {
    @Published var snap = EngineSnapshot()
    @Published var history: [HistoryPoint] = []
    @Published var markers: [AlertMarker] = []
    @Published var log: [EventLog.Entry] = []
    @Published var cpu = 0.0
    @Published var memory = 0.0
    @Published var now = monotonicNow()

    private var timer: Timer?
    private var cpuMark: (wall: Double, cpu: Double)?
    private var ticks = 0

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let engine = Engine.shared
        var s = engine.snapshot.get()
        s.image = nil
        snap = s
        now = monotonicNow()
        ticks += 1
        if ticks % 2 == 0 {
            history = engine.history.get()
            markers = engine.markers.get()
        }
        if ticks % 5 == 0 {
            log = Array(EventLog.shared.all.reversed())
        }
        if ticks % 10 == 0 {
            let cpuNow = SystemUsage.cpuSeconds()
            if let mark = cpuMark, now > mark.wall {
                cpu = 100 * (cpuNow - mark.cpu) / (now - mark.wall)
            }
            cpuMark = (now, cpuNow)
            memory = SystemUsage.memoryMB()
        }
    }
}

/// Whether the debug window shows the compact mini layout.
final class DebugWindowState: ObservableObject {
    static let shared = DebugWindowState()
    @Published var mini = false
}

enum DebugWindow {
    static let id = "debug"
    static let fullSize = NSSize(width: 1220, height: 800)
    static let miniSize = NSSize(width: 340, height: 430)

    static func show() {
        let w = WindowManager.shared.show(id, title: "Steady Debug", size: fullSize, minSize: NSSize(width: 320, height: 400),
                                          onClose: { DebugWindowState.shared.mini = false },
                                          content: { DebugView() })
        // A window closed in mini layout must not reopen at the mini size.
        if !DebugWindowState.shared.mini, w.frame.width < 900 {
            w.setContentSize(fullSize)
        }
        w.level = AppState.shared.settings.debugKeepOnTop ? .floating : .normal
    }

    static func setMini(_ mini: Bool) {
        guard let w = WindowManager.shared.window(id) else { return }
        withAnimation(.snappy(duration: 0.25)) { DebugWindowState.shared.mini = mini }
        let size = mini ? miniSize : fullSize
        var frame = w.frame
        let newFrame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        w.setFrame(frame, display: true, animate: true)
        w.level = mini || AppState.shared.settings.debugKeepOnTop ? .floating : .normal
        w.title = mini ? "Steady" : "Steady Debug"
    }

    static func setKeepOnTop(_ on: Bool) {
        WindowManager.shared.window(id)?.level = on ? .floating : .normal
    }
}

struct DebugView: View {
    @StateObject private var model = DebugModel()
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var focus = FocusContext.shared
    @ObservedObject private var windowState = DebugWindowState.shared
    private var mini: Bool { windowState.mini }

    private var layers: Set<DebugLayer> {
        Set(DebugLayer.allCases.filter { app.settings.layer($0) })
    }

    var body: some View {
        Group {
            if mini {
                miniLayout
            } else {
                fullLayout
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Layouts

    private var fullLayout: some View {
        HStack(alignment: .top, spacing: Metrics.spacing) {
            VStack(alignment: .leading, spacing: 12) {
                CameraOverlayView(layers: layers, mirrored: app.settings.debugMirror)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .frame(minWidth: 480)
                    .accessibilityLabel("Camera view with debug overlays")
                layerToggles
                windowControls
                GroupBox("System") { systemReadout }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 480, maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Smile classifier") { smileReadout }
                    GroupBox("Gaze classifier") { gazeReadout }
                    GroupBox("Activity") { activityReadout }
                    GroupBox("Last 60 seconds") { graphs }
                    GroupBox("Expressions") { expressions }
                    GroupBox("Tuning") { tuning }
                    GroupBox("Simulate alert") { simulate }
                    GroupBox("Event log") { eventLog }
                }
                .padding(.trailing, 4)
            }
            .frame(width: 440)
        }
        .padding(Metrics.spacing)
        .frame(minWidth: 960, minHeight: 620)
    }

    private var miniLayout: some View {
        VStack(spacing: 10) {
            CameraOverlayView(layers: layers, mirrored: app.settings.debugMirror)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
            VStack(spacing: 8) {
                MeterRow(label: "Smile", value: model.snap.smile.smoothed, threshold: app.settings.smileThreshold,
                         color: AlertKind.smile.color, text: String(format: "%.2f", model.snap.smile.smoothed))
                MeterRow(label: "Off-screen", value: model.snap.gaze.smoothed, threshold: app.settings.gazeThreshold,
                         color: AlertKind.lookAway.color, text: String(format: "%.2f", model.snap.gaze.smoothed))
                MeterRow(label: "Activity", value: min(1, model.snap.activity.score / 6), threshold: app.settings.activityThreshold / 6,
                         color: AlertKind.overActive.color, text: String(format: "%.1fx", model.snap.activity.score))
            }
            .padding(10)
            .cardBackground()
            Button("Show Full Debug") { setMini(false) }
                .controlSize(.small)
        }
        .padding(10)
        .frame(minWidth: 300, maxHeight: .infinity, alignment: .top)
    }

    private func setMini(_ value: Bool) {
        DebugWindow.setMini(value)
    }

    // MARK: Left column

    private var layerToggles: some View {
        HStack(spacing: 14) {
            ForEach(DebugLayer.allCases) { layer in
                Toggle(layer.title, isOn: Binding(
                    get: { app.settings.layer(layer) },
                    set: { app.settings.debugLayers[layer.rawValue] = $0 }))
                    .toggleStyle(.checkbox)
            }
        }
        .font(.callout)
    }

    private var windowControls: some View {
        HStack(spacing: 14) {
            Toggle("Mirror preview", isOn: $app.settings.debugMirror)
                .toggleStyle(.checkbox)
            Toggle("Keep on top", isOn: Binding(
                get: { app.settings.debugKeepOnTop },
                set: { app.settings.debugKeepOnTop = $0; DebugWindow.setKeepOnTop($0) }))
                .toggleStyle(.checkbox)
            Spacer()
            if app.isPaused {
                Button("Resume Monitoring") { app.resume(); focus.refresh() }
            }
            Button("Mini View") { setMini(true) }
        }
        .font(.callout)
    }

    private var systemReadout: some View {
        let s = model.snap
        let clipMB = Double(s.clipFrames * ClipRecorder.width * ClipRecorder.height * 3 / 2) / 1_048_576
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                ReadoutCell(label: "Camera", value: app.cameraRunning ? app.cameraName : "Off")
                ReadoutCell(label: "Frames per second", value: String(format: "%.1f of %.0f", s.fps, s.targetFps))
            }
            GridRow {
                ReadoutCell(label: "Vision per frame", value: String(format: "%.1f ms", s.visionMs))
                ReadoutCell(label: "Quality", value: s.idle ? "Idle, no face in view" : "\(s.quality.title), pose every \(s.handEvery) frames")
            }
            GridRow {
                ReadoutCell(label: "CPU", value: String(format: "%.1f%%", model.cpu))
                ReadoutCell(label: "Memory", value: String(format: "%.0f MB", model.memory))
            }
            GridRow {
                ReadoutCell(label: "Clip buffer", value: String(format: "%d frames, %.0f MB", s.clipFrames, clipMB))
                ReadoutCell(label: "Haptics", value: Haptics.shared.backend.rawValue)
            }
            GridRow {
                ReadoutCell(label: "Frame size", value: s.analysis.map { "\(Int($0.imageSize.width)) x \(Int($0.imageSize.height))" } ?? "–")
                ReadoutCell(label: "Preview image", value: Engine.shared.snapshot.get().image.map { "\($0.width) x \($0.height)" } ?? "–")
            }
            GridRow {
                ReadoutCell(label: "Signed with", value: Bundle.main.object(forInfoDictionaryKey: "SteadySigningIdentity") as? String ?? "Unknown")
                    .gridCellColumns(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Right column

    private var smileReadout: some View {
        let s = model.snap.smile
        return VStack(alignment: .leading, spacing: 8) {
            if ModelStore.shared.smile == nil {
                Text("Not calibrated yet. Run Calibrate Smile from the menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            MeterRow(label: "Raw p", value: s.raw ?? 0, threshold: app.settings.smileThreshold, color: AlertKind.smile.color.opacity(0.6),
                     text: s.raw.map { String(format: "%.2f", $0) } ?? "–")
            MeterRow(label: "Smoothed p", value: s.smoothed, threshold: app.settings.smileThreshold, color: AlertKind.smile.color,
                     text: String(format: "%.2f", s.smoothed))
            HStack {
                Text("Hold").foregroundStyle(.secondary)
                Text(String(format: "%.1f of %.1f s", s.held, app.settings.smileHold)).monospacedDigit()
                Spacer()
                Text(s.enabled ? (s.inEpisode ? "In episode" : "Watching") : modeText)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var modeText: String {
        if !app.settings.detects(.smile) { return "Turned off" }
        if ModelStore.shared.smile == nil { return "Needs calibration" }
        if model.snap.paused { return "Paused" }
        return "Only while studying"
    }

    private var gazeReadout: some View {
        let g = model.snap.gaze
        return VStack(alignment: .leading, spacing: 8) {
            MeterRow(label: "Raw p", value: g.raw ?? 0, threshold: app.settings.gazeThreshold, color: AlertKind.lookAway.color.opacity(0.6),
                     text: g.raw.map { String(format: "%.2f", $0) } ?? "–")
            MeterRow(label: "Smoothed p", value: g.smoothed, threshold: app.settings.gazeThreshold, color: AlertKind.lookAway.color,
                     text: String(format: "%.2f", g.smoothed))
            HStack {
                Text("Grace").foregroundStyle(.secondary)
                Text(String(format: "%.1f of %.1f s", g.held, app.settings.gazeGrace)).monospacedDigit()
                Spacer()
                Text(g.state.rawValue).foregroundStyle(.secondary)
            }
            .font(.callout)
            HStack {
                Text("Monitoring").foregroundStyle(.secondary)
                Text(model.snap.gazeReason.label)
                Spacer()
                Text(g.usingModel ? "Personal model" : "Head angle only")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            if g.typing {
                Label("Typing or mouse input in the last \(String(format: "%.1f", app.settings.typingWindow)) s",
                      systemImage: "keyboard")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var activityReadout: some View {
        let a = model.snap.activity
        let maxScale = 6.0
        return VStack(alignment: .leading, spacing: 8) {
            MeterRow(label: "Score", value: min(1, a.score / maxScale), threshold: app.settings.activityThreshold / maxScale,
                     color: AlertKind.overActive.color, text: String(format: "%.2fx", a.score))
            MeterRow(label: "Motion", value: min(1, a.motionRatio / maxScale), threshold: nil, color: AlertKind.overActive.color.opacity(0.6),
                     text: String(format: "%.2fx", a.motionRatio))
            MeterRow(label: "Head speed", value: min(1, a.headRatio / maxScale), threshold: nil, color: AlertKind.overActive.color.opacity(0.6),
                     text: String(format: "%.2fx", a.headRatio))
            MeterRow(label: "Upper body", value: min(1, a.bodyRatio / maxScale), threshold: nil, color: AlertKind.overActive.color.opacity(0.6),
                     text: String(format: "%.2fx", a.bodyRatio))
            MeterRow(label: "Hand at face", value: a.handFraction, threshold: nil, color: AlertKind.handsAtFace.color,
                     text: String(format: "%.0f%%", a.handFraction * 100))
            HStack {
                Text("Calm baseline").foregroundStyle(.secondary)
                Text(String(format: "motion %.2f · head %.2f · body %.3f", a.motionBaseline, a.headBaseline, a.bodyBaseline))
                    .monospacedDigit()
                Spacer()
            }
            .font(.callout)
            if a.warmingUp {
                Label("Learning your calm level (motion \(a.baselineSeconds.0) s, "
                    + "head \(a.baselineSeconds.1) s of 30). Over-active alerts start after that.", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text("Hand near face").foregroundStyle(.secondary)
                Text(a.handNear ? String(format: "Yes, %.1f s", a.handHeld) : "No").monospacedDigit()
                Spacer()
            }
            .font(.callout)
        }
    }

    private var graphs: some View {
        VStack(alignment: .leading, spacing: 10) {
            HistoryChart(title: "Smile p", points: model.history, markers: model.markers, now: model.now,
                         value: \.smile, threshold: app.settings.smileThreshold, maxY: 1, color: AlertKind.smile.color)
            HistoryChart(title: "Off-screen p", points: model.history, markers: model.markers, now: model.now,
                         value: \.gaze, threshold: app.settings.gazeThreshold, maxY: 1, color: AlertKind.lookAway.color)
            HistoryChart(title: "Activity score", points: model.history, markers: model.markers, now: model.now,
                         value: \.activity, threshold: app.settings.activityThreshold,
                         maxY: max(4, (model.history.map(\.activity).max() ?? 0) * 1.1), color: AlertKind.overActive.color)
        }
    }

    private var expressions: some View {
        let features = model.snap.analysis?.smileFeatures
        let smileModel = ModelStore.shared.smile
        let relaxed = ModelStore.shared.file.smileRelaxedMeans
        return VStack(alignment: .leading, spacing: 6) {
            if features == nil {
                Text("No usable face right now (turned too far, too small or out of view).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(0..<FaceFeatures.smileCount, id: \.self) { i in
                let value = features?[i]
                // Position on a ±3 standard deviation scale learned at calibration.
                let pos: Double? = value.flatMap { v in smileModel.map { m in 0.5 + (v - m.mean[i]) / m.std[i] / 6 } }
                let tick: Double? = relaxed.flatMap { r in smileModel.map { m in 0.5 + (r[i] - m.mean[i]) / m.std[i] / 6 } }
                FeatureRow(name: FaceFeatures.smileNames[i], value: value, position: pos, tick: tick)
            }
            if smileModel == nil {
                Text("Bars and relaxed ticks appear after smile calibration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var tuning: some View {
        VStack(alignment: .leading, spacing: 8) {
            TuningSlider(label: "Smile threshold", value: $app.settings.smileThreshold, range: 0.3...0.98, format: "%.2f")
            TuningSlider(label: "Smile hold", value: $app.settings.smileHold, range: 0.1...3, format: "%.1f s")
            TuningSlider(label: "Smile cooldown", value: $app.settings.smileCooldown, range: 2...60, format: "%.0f s")
            Divider()
            TuningSlider(label: "Gaze threshold", value: $app.settings.gazeThreshold, range: 0.3...0.98, format: "%.2f")
            TuningSlider(label: "Gaze grace", value: $app.settings.gazeGrace, range: 0.5...10, format: "%.1f s")
            TuningSlider(label: "Gaze repeat", value: $app.settings.gazeRepeat, range: 5...60, format: "%.0f s")
            Divider()
            TuningSlider(label: "Activity threshold", value: $app.settings.activityThreshold, range: 1.2...6, format: "%.1fx")
            TuningSlider(label: "Activity hold", value: $app.settings.activityHold, range: 1...10, format: "%.1f s")
            TuningSlider(label: "Activity cooldown", value: $app.settings.activityCooldown, range: 10...300, format: "%.0f s")
            TuningSlider(label: "Weight: motion", value: $app.settings.weightMotion, range: 0...3, format: "%.1f")
            TuningSlider(label: "Weight: head", value: $app.settings.weightHead, range: 0...3, format: "%.1f")
            TuningSlider(label: "Weight: body", value: $app.settings.weightBody, range: 0...3, format: "%.1f")
            TuningSlider(label: "Weight: hands", value: $app.settings.weightHands, range: 0...3, format: "%.1f")
            Divider()
            TuningSlider(label: "Hands hold", value: $app.settings.handsHold, range: 0.5...10, format: "%.1f s")
            TuningSlider(label: "Hands cooldown", value: $app.settings.handsCooldown, range: 5...300, format: "%.0f s")
            HStack {
                Spacer()
                Button("Reset to Defaults") { app.settings.resetTuning() }
            }
        }
    }

    private var simulate: some View {
        HStack(spacing: 8) {
            ForEach(AlertKind.allCases) { kind in
                Button {
                    AlertCenter.shared.simulate(kind)
                } label: {
                    Label(kind.title, systemImage: kind.symbol)
                        .labelStyle(.titleAndIcon)
                }
                .tint(kind.color)
                .help("Show the \(kind.title.lowercased()) alert with its sound and haptic")
            }
        }
        .controlSize(.small)
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(model.log.count) recent events").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(EventLog.shared.text, forType: .string)
                }
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.log.prefix(50)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(entry.type?.color ?? Color.secondary).frame(width: 6, height: 6)
                        Text(Format.time(entry.date)).foregroundStyle(.secondary).monospacedDigit()
                        Text(entry.kind.rawValue).fontWeight(entry.kind == .alert ? .semibold : .regular)
                        Text([entry.type?.title, entry.message].compactMap { $0 }.joined(separator: ": "))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if let peak = entry.peak { Text(String(format: "%.2f", peak)).monospacedDigit().foregroundStyle(.secondary) }
                        if let d = entry.duration { Text(String(format: "%.1f s", d)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                }
            }
            .textSelection(.enabled)
        }
    }
}

// MARK: Building blocks

/// A horizontal meter with an optional threshold line.
struct MeterRow: View {
    let label: String
    let value: Double
    let threshold: Double?
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color).frame(width: max(0, min(1, value)) * geo.size.width)
                    if let threshold {
                        Rectangle().fill(Color.primary.opacity(0.7))
                            .frame(width: 1.5, height: geo.size.height + 4)
                            .offset(x: max(0, min(1, threshold)) * geo.size.width - 0.75)
                    }
                }
            }
            .frame(height: 8)
            Text(text).font(.callout).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text)
    }
}

/// One smile feature: its value and where it sits compared with the relaxed average.
struct FeatureRow: View {
    let name: String
    let value: Double?
    let position: Double?
    let tick: Double?

    var body: some View {
        HStack(spacing: 10) {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    if let position {
                        Circle().fill(AlertKind.smile.color)
                            .frame(width: 8, height: 8)
                            .offset(x: max(0, min(1, position)) * (geo.size.width - 8))
                    }
                    if let tick {
                        Rectangle().fill(Color.primary.opacity(0.6))
                            .frame(width: 1.5, height: geo.size.height + 4)
                            .offset(x: max(0, min(1, tick)) * (geo.size.width - 8) + 3.25)
                    }
                }
            }
            .frame(height: 8)
            Text(value.map { String(format: "%.3f", $0) } ?? "–")
                .font(.caption).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(value.map { String(format: "%.3f", $0) } ?? "No value")
    }
}

struct ReadoutCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TuningSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 130, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
                .accessibilityLabel(label)
                .accessibilityValue(String(format: format, value))
            Text(String(format: format, value)).font(.callout).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}

/// A scrolling 60 second line graph with a dashed threshold and alert markers.
struct HistoryChart: View {
    let title: String
    let points: [HistoryPoint]
    let markers: [AlertMarker]
    let now: Double
    let value: KeyPath<HistoryPoint, Double>
    let threshold: Double
    let maxY: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("Seconds", p.t - now), y: .value(title, min(p[keyPath: value], maxY)))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                RuleMark(y: .value("Threshold", threshold))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ForEach(markers) { m in
                    RuleMark(x: .value("Alert", m.t - now))
                        .foregroundStyle(m.kind.color.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartXScale(domain: -60...0)
            .chartYScale(domain: 0...maxY)
            .chartXAxis {
                AxisMarks(values: [-60, -45, -30, -15, 0]) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel { if let s = v.as(Double.self) { Text(s == 0 ? "now" : "\(Int(s)) s") } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel()
                }
            }
            .frame(height: 70)
            .accessibilityLabel("\(title) over the last 60 seconds")
        }
    }
}
