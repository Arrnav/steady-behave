import SwiftUI

/// Shown when a study session ends.
struct SessionSummaryView: View {
    let summary: FocusContext.SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                Text(summary.completed ? "Session finished" : "Session ended")
                    .font(.title2.weight(.semibold))
            }
            Text(sentence)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                row("Focus time", Format.duration(summary.focusSeconds), color: .accentColor)
                row("Look-aways", "\(summary.lookAways)", color: AlertKind.lookAway.color)
                row("Smiles", "\(summary.smiles)", color: AlertKind.smile.color)
                row("Over-active", "\(summary.overActive)", color: AlertKind.overActive.color)
                row("Hands at face", "\(summary.handsAtFace)", color: AlertKind.handsAtFace.color)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { WindowManager.shared.close("summary") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var sentence: String {
        let minutes = max(1, Int((summary.focusSeconds / 60).rounded()))
        let looks = summary.lookAways == 1 ? "1 time" : "\(summary.lookAways) times"
        return "Looked away \(looks) in \(minutes) min."
    }

    private func row(_ label: String, _ value: String, color: Color) -> some View {
        GridRow {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
            }
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .accessibilityElement(children: .combine)
    }
}
