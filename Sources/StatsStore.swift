import Combine
import Foundation

/// Counters for one day.
struct DayStats: Codable, Equatable {
    var smileEpisodes = 0
    var smileSeconds = 0.0
    /// Smile episodes that happened while gaze monitoring was active (study time).
    var smileEpisodesFocused = 0
    var lookAways = 0
    var eyesOnSeconds = 0.0
    var awaySeconds = 0.0
    var overActive = 0
    var handsAtFace = 0
    var sessions = 0
    var sessionMinutes = 0.0
    /// Seconds with gaze monitoring active (study session or study app).
    var focusedSeconds = 0.0
    var falseAlarms = 0
    var missed = 0

    var focusedHours: Double { focusedSeconds / 3600 }

    /// nil when there is too little study time for a fair rate.
    var smilesPerHour: Double? { focusedSeconds >= 300 ? Double(smileEpisodesFocused) / focusedHours : nil }
    var lookAwaysPerHour: Double? { focusedSeconds >= 300 ? Double(lookAways) / focusedHours : nil }

    init() {}

    // Decode field by field so older files keep working when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smileEpisodes = try c.decodeIfPresent(Int.self, forKey: .smileEpisodes) ?? 0
        smileSeconds = try c.decodeIfPresent(Double.self, forKey: .smileSeconds) ?? 0
        smileEpisodesFocused = try c.decodeIfPresent(Int.self, forKey: .smileEpisodesFocused) ?? 0
        lookAways = try c.decodeIfPresent(Int.self, forKey: .lookAways) ?? 0
        eyesOnSeconds = try c.decodeIfPresent(Double.self, forKey: .eyesOnSeconds) ?? 0
        awaySeconds = try c.decodeIfPresent(Double.self, forKey: .awaySeconds) ?? 0
        overActive = try c.decodeIfPresent(Int.self, forKey: .overActive) ?? 0
        handsAtFace = try c.decodeIfPresent(Int.self, forKey: .handsAtFace) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        sessionMinutes = try c.decodeIfPresent(Double.self, forKey: .sessionMinutes) ?? 0
        focusedSeconds = try c.decodeIfPresent(Double.self, forKey: .focusedSeconds) ?? 0
        falseAlarms = try c.decodeIfPresent(Int.self, forKey: .falseAlarms) ?? 0
        missed = try c.decodeIfPresent(Int.self, forKey: .missed) ?? 0
    }
}

/// Per-day counters saved to stats.json. Main thread only. Writes are debounced.
final class StatsStore: ObservableObject {
    static let shared = StatsStore(url: Paths.stats)

    @Published private(set) var days: [String: DayStats] = [:]
    private let url: URL
    private var saveWork: DispatchWorkItem?
    private let debounce: TimeInterval

    static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String { keyFormatter.string(from: date) }

    init(url: URL, debounce: TimeInterval = 5) {
        self.url = url
        self.debounce = debounce
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: DayStats].self, from: data) {
            days = decoded
        } else {
            days = [:]
        }
    }

    func day(_ date: Date = Date()) -> DayStats { days[Self.key(for: date)] ?? DayStats() }

    var today: DayStats { day() }

    func update(on date: Date = Date(), _ change: (inout DayStats) -> Void) {
        let k = Self.key(for: date)
        var d = days[k] ?? DayStats()
        change(&d)
        days[k] = d
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(days) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func deleteAll() {
        saveWork?.cancel()
        days = [:]
        try? FileManager.default.removeItem(at: url)
    }

    /// One line for the menu, for example "Today: 14 smiles · 6 look-aways · 1h 40m focused".
    var todaySummary: String {
        let t = today
        let smiles = t.smileEpisodes == 1 ? "1 smile" : "\(t.smileEpisodes) smiles"
        let looks = t.lookAways == 1 ? "1 look-away" : "\(t.lookAways) look-aways"
        return "Today: \(smiles) · \(looks) · \(Format.duration(t.focusedSeconds)) focused"
    }
}
