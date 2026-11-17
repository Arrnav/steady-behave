import AppKit
import AVFoundation
import SwiftUI

/// Settings for escalation: a light screen blur and a spoken reminder when a habit keeps repeating.
struct RepeatedHabitsPane: View {
    @ObservedObject private var app = AppState.shared
    private let voices = EscalationCenter.voices()

    var body: some View {
        Form {
            Section {
                LabeledContent("Tolerance") {
                    HStack(spacing: 10) {
                        Text("Sooner").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { Double(app.settings.escalationTolerance) },
                                              set: { app.settings.escalationTolerance = Int($0.rounded()) }),
                               in: 2...10, step: 1)
                            .frame(minWidth: 160)
                            .accessibilityLabel("Tolerance")
                            .accessibilityValue("\(app.settings.escalationTolerance) alerts")
                        Text("Later").font(.caption).foregroundStyle(.secondary)
                        Text("\(app.settings.escalationTolerance)").monospacedDigit().frame(width: 24, alignment: .trailing)
                    }
                }
                Stepper("Look back over the last \(Int(app.settings.escalationWindowMinutes)) minutes",
                        value: $app.settings.escalationWindowMinutes, in: 2...60, step: 1)
            } footer: {
                Text("When alerts start to feel routine, Steady steps up: first a light blur over the screen, then a spoken reminder. "
                    + "Tolerance sets how many alerts that takes; the numbers below can be fine-tuned.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Right now") {
                ToleranceMeter()
            }
            Section {
                Toggle("Blur the screen a little", isOn: $app.settings.blurEnabled)
                Group {
                    Stepper("After \(app.settings.blurAfter) alerts for the same habit", value: $app.settings.blurAfter, in: 2...20)
                    Stepper("Or \(app.settings.combinedAfter) alerts of any kind", value: $app.settings.combinedAfter, in: 2...30)
                    SliderRow(title: "Strength", value: $app.settings.blurStrength, range: 0.2...1, format: "%.1f")
                    SliderRow(title: "Up to", value: $app.settings.blurSeconds, range: 2...30, step: 1, format: "%.0f s")
                }
                .disabled(!app.settings.blurEnabled)
                HStack {
                    Spacer()
                    Button("Test Blur") { EscalationCenter.shared.testBlur() }
                }
            } header: {
                Text("Screen blur")
            } footer: {
                Text("The blur lets clicks through and clears as soon as the habit stops.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Speak a reminder", isOn: $app.settings.speakEnabled)
                Group {
                    Stepper("After \(app.settings.speakAfter) alerts for the same habit", value: $app.settings.speakAfter, in: 2...30)
                    Stepper("At most every \(Int(app.settings.speakCooldownMinutes)) minutes",
                            value: $app.settings.speakCooldownMinutes, in: 1...60, step: 1)
                    Picker("Voice", selection: $app.settings.voiceID) {
                        Text("Automatic (\(EscalationCenter.automaticVoice()?.name ?? "system voice"))").tag(String?.none)
                        ForEach(voices, id: \.identifier) { voice in
                            Text(Self.label(for: voice)).tag(Optional(voice.identifier))
                        }
                    }
                    SliderRow(title: "Voice volume", value: $app.settings.speechVolume, range: 0.05...1, format: "%.2f")
                    Toggle("Only speak when headphones are connected", isOn: $app.settings.speakOnlyWithHeadphones)
                    LabeledContent("Sound output") {
                        Text(AudioOutput.name + (AudioOutput.isHeadphones ? ", headphones" : "")).foregroundStyle(.secondary)
                    }
                }
                .disabled(!app.settings.speakEnabled)
                HStack {
                    Button("Get More Voices") { Self.openSpokenContentSettings() }
                    Spacer()
                    Button("Test Voice") { EscalationCenter.shared.testVoice() }
                }
            } header: {
                Text("Spoken reminder")
            } footer: {
                Text("macOS doesn't let other apps use Siri's voices, so Steady speaks with the system voices on your Mac, "
                    + "without any network. The Premium voices sound closest to Siri: Get More Voices opens Spoken Content, "
                    + "where System Voice, Manage Voices lets you download them. Test Voice always plays.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Nothing escalates during calls or the quiet hour, and test alerts don't count.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func label(for voice: AVSpeechSynthesisVoice) -> String {
        var parts: [String] = []
        switch voice.quality {
        case .premium: parts.append("Premium")
        case .enhanced: parts.append("Enhanced")
        default: break
        }
        switch voice.gender {
        case .female: parts.append("female")
        case .male: parts.append("male")
        default: break
        }
        return parts.isEmpty ? voice.name : "\(voice.name) (\(parts.joined(separator: ", ")))"
    }

    private static func openSpokenContentSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// How close each habit is to a blur or a spoken reminder, from alerts in the look-back window.
struct ToleranceMeter: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let counts = EscalationCenter.shared.currentCounts()
            let s = app.settings
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AlertKind.allCases) { kind in
                    row(title: kind.detectionTitle, color: kind.color, count: counts[kind, default: 0],
                        blurAt: s.blurAfter, voiceAt: s.speakAfter)
                }
                row(title: "All habits", color: .secondary, count: counts.values.reduce(0, +),
                    blurAt: s.combinedAfter, voiceAt: s.combinedAfter + 2)
            }
        }
    }

    private func row(title: String, color: Color, count: Int, blurAt: Int, voiceAt: Int) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.callout).frame(width: 120, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color).frame(width: geo.size.width * min(1, Double(count) / Double(max(1, voiceAt))))
                    marker(at: Double(blurAt) / Double(max(1, voiceAt)), width: geo.size.width)
                }
            }
            .frame(height: 8)
            Text(status(count: count, blurAt: blurAt, voiceAt: voiceAt))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(status(count: count, blurAt: blurAt, voiceAt: voiceAt))
    }

    private func marker(at fraction: Double, width: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(0.6))
            .frame(width: 1.5, height: 12)
            .offset(x: width * min(1, fraction) - 0.75)
    }

    private func status(count: Int, blurAt: Int, voiceAt: Int) -> String {
        if count >= voiceAt { return "\(count), voice reached" }
        if count >= blurAt { return "\(count) of \(voiceAt) to voice" }
        return "\(count) of \(blurAt) to blur"
    }
}
