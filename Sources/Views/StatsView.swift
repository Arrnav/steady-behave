import Charts
import SwiftUI

struct StatsView: View {
    @ObservedObject private var stats = StatsStore.shared
    /// Observed so alert colors update when they change in Settings.
    @ObservedObject private var app = AppState.shared

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d")
        return f
    }()

    private struct DayPoint: Identifiable {
        var id: String { key }
        let key: String
        let label: String
        let stats: DayStats
    }

    private var lastSevenDays: [DayPoint] {
        let cal = Calendar.current
        return (0..<7).reversed().compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return DayPoint(key: StatsStore.key(for: date), label: Self.dayLabel.string(from: date), stats: stats.day(date))
        }
    }

    /// Smiles per study hour over a range of days, or nil without enough study time.
    private func rate(daysAgo range: ClosedRange<Int>, _ count: (DayStats) -> Int) -> Double? {
        let cal = Calendar.current
        var events = 0, seconds = 0.0
        for offset in range {
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let d = stats.day(date)
            events += count(d)
            seconds += d.focusedSeconds
        }
        return seconds >= 1800 ? Double(events) / (seconds / 3600) : nil
    }

    private var summarySentence: String {
        guard let thisWeek = rate(daysAgo: 0...6, { $0.smileEpisodesFocused }) else {
            return "Study for at least 30 minutes this week to see your rates per hour."
        }
        guard let lastWeek = rate(daysAgo: 7...13, { $0.smileEpisodesFocused }) else {
            return String(format: "%.1f smile episodes per study hour this week. Next week shows the change.", thisWeek)
        }
        let diff = thisWeek - lastWeek
        if abs(diff) < 0.5 { return String(format: "About the same as last week: %.1f smile episodes per study hour.", thisWeek) }
        let n = Int(abs(diff).rounded())
        let unit = n == 1 ? "smile episode" : "smile episodes"
        return "\(n) \(diff < 0 ? "fewer" : "more") \(unit) per hour than last week."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Today").font(.largeTitle.weight(.semibold))
                    Text(summarySentence).font(.body).foregroundStyle(.secondary)
                }
                todayGrid
                GroupBox {
                    rateChart(title: "Smiles per study hour", color: AlertKind.smile.color) { $0.smilesPerHour }
                } label: {
                    Label("Smiles per study hour", systemImage: AlertKind.smile.symbol)
                }
                GroupBox {
                    rateChart(title: "Look-aways per study hour", color: AlertKind.lookAway.color) { $0.lookAwaysPerHour }
                } label: {
                    Label("Look-aways per study hour", systemImage: AlertKind.lookAway.symbol)
                }
                GroupBox {
                    focusChart
                } label: {
                    Label("Study time", systemImage: "book")
                }
                Text("Rates appear for days with at least 5 minutes of study time (a study session or a study app in front).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var todayGrid: some View {
        let t = stats.today
        let eyesTotal = t.eyesOnSeconds + t.awaySeconds
        let eyesPercent = eyesTotal > 0 ? "\(Int((100 * t.eyesOnSeconds / eyesTotal).rounded()))%" : "–"
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(title: "Smile episodes", value: "\(t.smileEpisodes)",
                     detail: "\(Format.duration(t.smileSeconds)) in total", color: AlertKind.smile.color)
            StatTile(title: "Look-aways", value: "\(t.lookAways)", detail: "Eyes on screen \(eyesPercent)", color: AlertKind.lookAway.color)
            StatTile(title: "Focused", value: Format.duration(t.focusedSeconds),
                     detail: "\(t.sessions == 1 ? "1 session" : "\(t.sessions) sessions"), \(Int(t.sessionMinutes.rounded())) min",
                     color: .accentColor)
            StatTile(title: "Over-active", value: "\(t.overActive)", detail: "Moving a lot for 3 s or more", color: AlertKind.overActive.color)
            StatTile(title: "Hands at face", value: "\(t.handsAtFace)", detail: "2 s or more", color: AlertKind.handsAtFace.color)
            StatTile(title: "Feedback", value: "\(t.falseAlarms + t.missed)",
                     detail: "\(t.falseAlarms) false alarms, \(t.missed) missed", color: .secondary)
        }
    }

    private func rateChart(title: String, color: Color, value: @escaping (DayStats) -> Double?) -> some View {
        let days = lastSevenDays
        let hasData = days.contains { value($0.stats) != nil }
        let top = max(1, (days.compactMap { value($0.stats) }.max() ?? 0) * 1.2)
        return VStack(alignment: .leading, spacing: 8) {
            Chart(days) { day in
                if let v = value(day.stats) {
                    BarMark(x: .value("Day", day.label), y: .value(title, v), width: .ratio(0.55))
                        .foregroundStyle(color.gradient)
                        .cornerRadius(6)
                        .annotation(position: .top) {
                            Text(String(format: "%.1f", v)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                } else {
                    BarMark(x: .value("Day", day.label), y: .value(title, 0), width: .ratio(0.55))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel()
                }
            }
            .chartYScale(domain: 0...top)
            .chartYAxisLabel("per hour")
            .frame(height: 160)
            .overlay {
                if !hasData {
                    Text("No day in the last week had 5 minutes of study time yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .cardBackground(cornerRadius: Metrics.smallCorner)
                }
            }
            .accessibilityLabel(title + " for the last 7 days")
        }
        .padding(8)
    }

    private var focusChart: some View {
        Chart(lastSevenDays) { day in
            BarMark(x: .value("Day", day.label), y: .value("Minutes", day.stats.focusedSeconds / 60), width: .ratio(0.55))
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(6)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel()
            }
        }
        .chartYAxisLabel("minutes")
        .frame(height: 140)
        .padding(8)
        .accessibilityLabel("Focused minutes for the last 7 days")
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
            Text(value).font(.title.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}
