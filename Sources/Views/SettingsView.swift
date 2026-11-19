import AppKit
import AVFoundation
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, smile, gaze, activity, alerts, repeating, haptics, clips, privacy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .smile: return "Expression"
        case .gaze: return "Looking Away"
        case .activity: return "Activity"
        case .alerts: return "Alerts"
        case .repeating: return "Repeated Habits"
        case .haptics: return "Haptics"
        case .clips: return "Clips"
        case .privacy: return "Privacy and Data"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .smile: return "mouth"
        case .gaze: return "eyes"
        case .activity: return "figure.walk.motion"
        case .alerts: return "bell"
        case .repeating: return "arrow.clockwise.circle"
        case .haptics: return "hand.tap"
        case .clips: return "film"
        case .privacy: return "lock.shield"
        }
    }
}

struct SettingsView: View {
    @State private var pane: SettingsPane? = SettingsView.initialPane

    /// `--pane <name>` at launch picks the first pane shown (used for layout checks).
    static var initialPane: SettingsPane {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--pane"), i + 1 < args.count, let p = SettingsPane(rawValue: args[i + 1]) { return p }
        return .general
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralPane()
                case .smile: SmilePane()
                case .gaze: GazePane()
                case .activity: ActivityPane()
                case .alerts: AlertsPane()
                case .repeating: RepeatedHabitsPane()
                case .haptics: HapticsPane()
                case .clips: ClipsPane()
                case .privacy: PrivacyPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

/// A slider row with its value shown on the right.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let format: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                if let step {
                    Slider(value: $value, in: range, step: step).frame(minWidth: 160)
                } else {
                    Slider(value: $value, in: range).frame(minWidth: 160)
                }
                Text(String(format: format, value)).monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(String(format: format, value))
        }
    }
}

// MARK: General

private struct GeneralPane: View {
    @ObservedObject private var app = AppState.shared
    @State private var loginOn = LoginItem.isEnabled
    @State private var devices: [AVCaptureDevice] = CameraService.availableDevices()

    var body: some View {
        Form {
            Section {
                Toggle("Monitoring", isOn: Binding(get: { !app.isPaused }, set: { on in
                    if on { app.resume() } else { app.monitoringEnabled = false }
                    FocusContext.shared.refresh()
                }))
                Toggle("Open at login", isOn: Binding(get: { loginOn }, set: { on in
                    LoginItem.set(on)
                    loginOn = LoginItem.isEnabled
                }))
            }
            Section {
                kindToggle(.smile, isOn: app.detectionBinding(.smile))
                kindToggle(.lookAway, isOn: app.detectionBinding(.lookAway))
                kindToggle(.overActive, isOn: app.detectionBinding(.overActive))
                kindToggle(.handsAtFace, isOn: app.detectionBinding(.handsAtFace))
            } header: {
                Text("Detections")
            } footer: {
                Text("A detection that is off gives no alerts, adds nothing to stats and saves no clips. Also in the menu bar, under Detections.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Camera", selection: $app.settings.cameraID) {
                    Text("Built-in camera").tag(String?.none)
                    ForEach(devices, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(Optional(d.uniqueID))
                    }
                }
                Picker("Quality", selection: $app.settings.cameraQuality) {
                    ForEach(CameraQuality.allCases) { q in
                        Text("\(q.title) (\(q.detail))").tag(q)
                    }
                }
                Toggle("Use Battery Saver on battery power", isOn: $app.settings.batterySaverOnBattery)
                Picker("Watch", selection: $app.settings.watchSchedule) {
                    ForEach(WatchSchedule.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Turn the camera off when I step away", isOn: $app.settings.cameraOffWhenAway)
                Stepper("After \(Int(app.settings.awayMinutes)) min with no one in view and no input",
                        value: $app.settings.awayMinutes, in: 1...15, step: 1)
                    .disabled(!app.settings.cameraOffWhenAway)
                LabeledContent("In use") {
                    Text("\(app.effectiveQuality.title), \(app.qualityReason.lowercased())").foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    Text(cameraStatus).foregroundStyle(.secondary)
                }
                if app.cameraAuthorization != .authorized {
                    Button("Open Camera Settings") { Actions.openCameraSettings() }
                }
            } header: {
                Text("Camera")
            } footer: {
                Text("The camera itself uses the most power, so turning it off saves the most. "
                    + "After stepping away it turns back on with any key press or trackpad movement. "
                    + "Only while studying keeps it on during study sessions and study apps. "
                    + "Lower quality analyses fewer frames; with nobody in view for 10 seconds, Steady checks only twice a second.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Pause detection while I use the Mac", isOn: $app.settings.typingSuppression)
                Group {
                    Toggle("Keyboard", isOn: $app.settings.inputKeyboard)
                    Toggle("Mouse and trackpad", isOn: $app.settings.inputMouse)
                    SliderRow(title: "Pause for", value: $app.settings.typingWindow, range: 0.5...10, format: "%.1f s")
                }
                .disabled(!app.settings.typingSuppression)
            } header: {
                Text("Keyboard and Trackpad")
            } footer: {
                Text("The pause lasts this long after the last key press or pointer movement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                kindToggle(.smile, isOn: app.inputPauseBinding(.smile))
                kindToggle(.lookAway, isOn: app.inputPauseBinding(.lookAway))
                kindToggle(.overActive, isOn: app.inputPauseBinding(.overActive))
                kindToggle(.handsAtFace, isOn: app.inputPauseBinding(.handsAtFace))
            } header: {
                Text("Pause These Detections")
            } footer: {
                Text("Leave a detection unpaused to keep catching it while you type or use the trackpad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!app.settings.typingSuppression)
            Section {
                Picker("Session length", selection: $app.settings.sessionMinutes) {
                    Text("25 minutes").tag(25)
                    Text("50 minutes").tag(50)
                    Text("90 minutes").tag(90)
                    Text("Open-ended").tag(0)
                }
            } header: {
                Text("Study")
            }
            Section {
                TextField("Competing response", text: $app.settings.competingResponse, axis: .vertical)
                    .lineLimit(2...4)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Competing response")
            } header: {
                Text("Competing response")
            } footer: {
                Text("The small, calm action shown with each expression alert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Lower the frame rate when CPU use is high", isOn: $app.settings.adaptivePerformance)
            } header: {
                Text("Performance")
            } footer: {
                Text("Drops to 10 frames per second when Steady uses more than 15% of one CPU core.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { devices = CameraService.availableDevices(); loginOn = LoginItem.isEnabled }
    }

    /// Rows are written out one by one: a ForEach as the content of a grouped section
    /// drew its last row outside the section box.
    private func kindToggle(_ kind: AlertKind, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(kind.detectionTitle, systemImage: kind.symbol)
        }
    }

    private var cameraStatus: String {
        switch app.cameraAuthorization {
        case .authorized: return app.cameraRunning ? "On: \(app.cameraName)" : "Off"
        case .denied, .restricted: return "No access"
        default: return "Not asked yet"
        }
    }
}

// MARK: Smile

private struct SmilePane: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        let model = ModelStore.shared.smile
        Form {
            Section {
                Toggle("Detect the stretched expression", isOn: app.detectionBinding(.smile))
            }
            Section("Model") {
                ModelStatusRow(model: model, emptyText: "Not calibrated. Expression alerts start after calibration.")
                Button(model == nil ? "Calibrate Expression…" : "Calibrate Again…") { Actions.showSmileCalibration() }
            }
            Section("When") {
                Picker("Expression alerts", selection: $app.settings.smileMode) {
                    ForEach(SmileMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                SliderRow(title: "Threshold", value: $app.settings.smileThreshold, range: 0.3...0.98, format: "%.2f")
                SliderRow(title: "Hold time", value: $app.settings.smileHold, range: 0.1...3, format: "%.1f s")
                SliderRow(title: "Cooldown", value: $app.settings.smileCooldown, range: 2...60, step: 1, format: "%.0f s")
                Stepper("Alerts per episode: \(app.settings.smileMaxRepeats)", value: $app.settings.smileMaxRepeats, in: 1...10)
            } header: {
                Text("Detection")
            } footer: {
                Text("An alert fires when the expression score stays above the threshold for the hold time. "
                    + "While the expression continues, it repeats after each cooldown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feedback") {
                LabeledContent("False alarm", value: "⌃⌥X")
                LabeledContent("Missed one", value: "⌃⌥M")
                LabeledContent("Training frames") {
                    let data = ModelStore.shared.file.smileData
                    Text("\(data.positives.count) stretched, \(data.negatives.count) other")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .id(app.modelVersion)
    }
}

struct ModelStatusRow: View {
    let model: LogisticModel?
    let emptyText: String

    var body: some View {
        if let model {
            LabeledContent("Accuracy") {
                Text(model.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "Not measured").monospacedDigit()
            }
            LabeledContent("Trained") {
                Text(model.trainedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
        } else {
            Text(emptyText).foregroundStyle(.secondary)
        }
    }
}

// MARK: Looking away

private struct GazePane: View {
    @ObservedObject private var app = AppState.shared
    @State private var catalog: [AppCatalog.App] = []
    @State private var search = ""

    var body: some View {
        let model = ModelStore.shared.gaze
        Form {
            Section {
                Toggle("Detect looking away", isOn: app.detectionBinding(.lookAway))
            }
            Section("Model") {
                ModelStatusRow(model: model, emptyText: "Not calibrated. Until then, Steady uses head angle only.")
                Button(model == nil ? "Calibrate Gaze…" : "Calibrate Again…") { Actions.showGazeCalibration() }
            }
            Section {
                SliderRow(title: "Threshold", value: $app.settings.gazeThreshold, range: 0.3...0.98, format: "%.2f")
                SliderRow(title: "Grace time", value: $app.settings.gazeGrace, range: 0.5...10, format: "%.1f s")
                SliderRow(title: "Repeat every", value: $app.settings.gazeRepeat, range: 5...60, step: 1, format: "%.0f s")
                Stepper("Alerts per look-away: \(app.settings.gazeMaxRepeats)", value: $app.settings.gazeMaxRepeats, in: 1...10)
            } header: {
                Text("Detection")
            } footer: {
                Text("Look-away alerts only run during a study session, or while a study app is in front when auto mode is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Pause while typing or using the trackpad", isOn: app.inputPauseBinding(.lookAway))
                    .disabled(!app.settings.typingSuppression)
            } footer: {
                Text("While paused, looking at the keyboard or trackpad counts as on screen. Choose the inputs in General, Keyboard and Trackpad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Auto mode: watch gaze while a study app is in front", isOn: $app.settings.autoMode)
            } header: {
                Text("Auto mode")
            } footer: {
                Text("Steady checks only which app is in front. It never reads window titles or screen contents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if app.settings.autoMode {
                Section("Study apps") {
                    TextField("Search apps", text: $search)
                    ForEach(filtered) { item in
                        Toggle(isOn: Binding(
                            get: { app.settings.studyApps.contains(item.bundleID) },
                            set: { on in
                                app.settings.studyApps.removeAll { $0 == item.bundleID }
                                if on { app.settings.studyApps.append(item.bundleID) }
                                FocusContext.shared.refresh()
                            })) {
                            HStack(spacing: 8) {
                                Image(nsImage: item.icon).resizable().frame(width: 18, height: 18)
                                Text(item.name)
                            }
                        }
                    }
                }
            }
        }
        .id(app.modelVersion)
        .task {
            if catalog.isEmpty { catalog = await AppCatalog.load() }
        }
    }

    private var filtered: [AppCatalog.App] {
        let selected = Set(app.settings.studyApps)
        let list = search.isEmpty ? catalog : catalog.filter { $0.name.localizedCaseInsensitiveContains(search) }
        // Chosen apps first, then alphabetical.
        return list.sorted { a, b in
            let sa = selected.contains(a.bundleID), sb = selected.contains(b.bundleID)
            if sa != sb { return sa }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: Activity

private struct ActivityPane: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        Form {
            Section {
                Toggle("Detect moving a lot", isOn: app.detectionBinding(.overActive))
                Toggle("Detect hands at face", isOn: app.detectionBinding(.handsAtFace))
            }
            Section {
                SliderRow(title: "Threshold", value: $app.settings.activityThreshold, range: 1.2...6, format: "%.1fx")
                SliderRow(title: "Hold time", value: $app.settings.activityHold, range: 1...10, format: "%.1f s")
                SliderRow(title: "Cooldown", value: $app.settings.activityCooldown, range: 10...300, step: 5, format: "%.0f s")
            } header: {
                Text("Over-active")
            } footer: {
                Text("The activity score compares movement in the last 6 seconds with your calm level. 1x is calm.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Score weights") {
                SliderRow(title: "Motion", value: $app.settings.weightMotion, range: 0...3, format: "%.1f")
                SliderRow(title: "Head movement", value: $app.settings.weightHead, range: 0...3, format: "%.1f")
                SliderRow(title: "Upper body", value: $app.settings.weightBody, range: 0...3, format: "%.1f")
                SliderRow(title: "Hands near face", value: $app.settings.weightHands, range: 0...3, format: "%.1f")
            }
            Section("Hands at face") {
                SliderRow(title: "Hold time", value: $app.settings.handsHold, range: 0.5...10, format: "%.1f s")
                SliderRow(title: "Cooldown", value: $app.settings.handsCooldown, range: 5...300, step: 5, format: "%.0f s")
                SliderRow(title: "Save a clip after", value: $app.settings.handsClipAfter, range: 2...20, format: "%.0f s")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset Detection Settings") { app.settings.resetTuning() }
                }
            }
        }
    }
}

// MARK: Alerts

private struct AlertsPane: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Volume") {
                    HStack(spacing: 10) {
                        Slider(value: $app.settings.volume, in: 0...1).frame(minWidth: 160)
                            .accessibilityLabel("Volume")
                        Text("\(Int((app.settings.volume * 100).rounded()))%").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }
            ForEach(AlertKind.allCases) { kind in
                Section {
                    Toggle("Sound", isOn: Binding(get: { app.settings.sound(for: kind) },
                                                  set: { app.settings.soundEnabled[kind.rawValue] = $0 }))
                    Picker("Sound name", selection: Binding(get: { app.settings.soundName(for: kind) },
                                                            set: { app.settings.soundNames[kind.rawValue] = $0 })) {
                        ForEach(AlertCenter.systemSounds, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(!app.settings.sound(for: kind))
                    Toggle("Trackpad haptic", isOn: Binding(get: { app.settings.haptic(for: kind) },
                                                            set: { app.settings.hapticEnabled[kind.rawValue] = $0 }))
                    ColorPicker("Glow color", selection: app.colorBinding(kind), supportsOpacity: false)
                    HStack {
                        if app.settings.alertColors[kind.rawValue] != nil {
                            Button("Reset Color") { app.settings.alertColors[kind.rawValue] = nil }
                        }
                        Spacer()
                        Button("Show Test Alert") { AlertCenter.shared.simulate(kind) }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(kind.color).frame(width: 8, height: 8)
                        Text(kind.title)
                        Text("· \(kind.overlayText)").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle("Quiet mode during calls", isOn: $app.settings.quietDuringCalls)
                Toggle("Turn the camera off during calls", isOn: $app.settings.cameraOffDuringCalls)
                if app.isQuietManual {
                    Button("End Quiet Hour") { app.quietUntil = nil; FocusContext.shared.refresh() }
                } else {
                    Button("Quiet for 1 Hour") {
                        app.quietUntil = Date().addingTimeInterval(3600)
                        FocusContext.shared.refresh()
                    }
                }
            } header: {
                Text("Calls")
            } footer: {
                Text("While Zoom, Microsoft Teams, FaceTime or Webex is in front, alerts have no sound or haptic and a smaller, "
                    + "fainter glow. macOS lets several apps use the camera at once, so Steady can keep watching during a call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Haptics

private struct HapticsPane: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        let h = Haptics.shared
        Form {
            Section {
                LabeledContent("Backend", value: h.backend.rawValue)
                LabeledContent("Details", value: h.detail.isEmpty ? "–" : h.detail)
            } header: {
                Text("Trackpad")
            } footer: {
                Text(h.backend == .privateAPI
                     ? "Taps work even without a finger on the trackpad."
                     : "Taps are only felt while a finger rests on the trackpad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Test each waveform") {
                ForEach(Haptics.waveforms, id: \.id) { w in
                    LabeledContent("\(w.id). \(w.name)") {
                        Button("Play") { Haptics.shared.pattern([(w.id, 0)]) }
                            .accessibilityLabel("Play \(w.name)")
                    }
                }
            }
            Section {
                Picker("Expression alert", selection: $app.settings.smileWaveform) {
                    ForEach(Haptics.waveforms, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Look-away alert", selection: $app.settings.lookAwayWaveform) {
                    ForEach(Haptics.waveforms, id: \.id) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Spacer()
                    Button("Play Expression Pattern") { Haptics.shared.alert(.smile, settings: app.settings) }
                    Button("Play Look-Away Pattern") { Haptics.shared.alert(.lookAway, settings: app.settings) }
                }
            } header: {
                Text("Patterns")
            } footer: {
                Text("An expression alert plays its waveform twice, 120 ms apart. Turn haptics on or off for each alert type in Alerts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Clips

private struct ClipsPane: View {
    @ObservedObject private var app = AppState.shared
    @State private var usage: Int = 0
    @State private var count = 0

    var body: some View {
        Form {
            Section {
                Toggle("Save clips of over-active moments and hands at face", isOn: $app.settings.clipsEnabled)
                Toggle("Also save clips of expression episodes", isOn: $app.settings.smileClips)
                    .disabled(!app.settings.clipsEnabled)
            } footer: {
                Text("Each clip has the 10 seconds before the moment and 4 seconds after, unmirrored, so it shows how others see you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Limits") {
                Stepper("At most 1 clip every \(Int(app.settings.clipMinInterval / 60)) min",
                        value: Binding(get: { app.settings.clipMinInterval / 60 }, set: { app.settings.clipMinInterval = $0 * 60 }),
                        in: 1...60)
                Stepper("At most \(app.settings.clipsPerDay) clips a day", value: $app.settings.clipsPerDay, in: 1...200)
                Stepper("Total size up to \(app.settings.clipCapMB) MB", value: $app.settings.clipCapMB, in: 50...5000, step: 50)
                Stepper("Delete clips after \(app.settings.clipRetentionDays) days", value: $app.settings.clipRetentionDays, in: 1...90)
            }
            Section("Storage") {
                LabeledContent("Used") {
                    Text("\(count) clips, \(ByteCountFormatter.string(fromByteCount: Int64(usage), countStyle: .file))")
                        .monospacedDigit()
                }
                HStack {
                    Button("Open Clips…") { Actions.showClips() }
                    Button("Show in Finder") { NSWorkspace.shared.open(Paths.clips) }
                    Spacer()
                    Button("Apply Limits Now") { applyLimits() }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .steadyClipsChanged)) { _ in refresh() }
    }

    private func refresh() {
        let all = ClipStorage.all(root: Paths.clips)
        count = all.count
        usage = all.reduce(0) { $0 + $1.bytes }
    }

    private func applyLimits() {
        let s = app.settings
        ClipStorage.enforceLimits(root: Paths.clips, retentionDays: s.clipRetentionDays, capBytes: s.clipCapMB * 1_048_576)
        NotificationCenter.default.post(name: .steadyClipsChanged, object: nil)
    }
}

// MARK: Privacy

private struct PrivacyPane: View {
    @State private var confirm = false
    @State private var deleted = false

    var body: some View {
        Form {
            Section {
                Label("Steady has no network code and makes no internet connections.", systemImage: "wifi.slash")
                Label("Face and hand detection use Apple's Vision framework on this Mac.", systemImage: "cpu")
                Label("The camera turns off when monitoring is paused, the screen is locked or the Mac sleeps.", systemImage: "video.slash")
                Label("Clips are ordinary video files that other apps running as you can read. Turn clips off in Clips if you prefer.",
                      systemImage: "film")
            } header: {
                Text("On this Mac only")
            }
            Section("Data") {
                LabeledContent("Location") {
                    Text("~/Library/Application Support/Steady").foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.open(Paths.support) }
                    Spacer()
                    Button("Delete All Steady Data…", role: .destructive) { confirm = true }
                }
                if deleted {
                    Text("Models, stats and clips were deleted. Settings were kept.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Delete all Steady data?", isPresented: $confirm) {
            Button("Delete Models, Stats and Clips", role: .destructive) {
                DataReset.deleteAll()
                deleted = true
            }
        } message: {
            Text("This removes your trained models, daily stats and every clip. Settings stay. You will need to calibrate again.")
        }
    }
}
