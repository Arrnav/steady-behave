import Foundation
import os

/// A short in-memory history of detections, alerts and suppressed alerts, shown in debug mode.
final class EventLog {
    static let shared = EventLog()

    enum Kind: String {
        case detected = "Detected"
        case alert = "Alert"
        case suppressed = "Suppressed"
        case ended = "Ended"
        case feedback = "Feedback"
        case info = "Info"
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let kind: Kind
        let type: AlertKind?
        let message: String
        let peak: Double?
        let duration: Double?

        var line: String {
            var parts = [Format.time(date), kind.rawValue]
            if let type { parts.append(type.title) }
            parts.append(message)
            if let peak { parts.append(String(format: "peak %.2f", peak)) }
            if let duration { parts.append(String(format: "%.1f s", duration)) }
            return parts.joined(separator: "  ")
        }
    }

    private let entries = Locked<[Entry]>([])
    private let logger = Logger(subsystem: "com.arnav.steady", category: "events")
    private let capacity = 50

    func add(_ kind: Kind, _ type: AlertKind?, _ message: String, peak: Double? = nil, duration: Double? = nil) {
        let entry = Entry(date: Date(), kind: kind, type: type, message: message, peak: peak, duration: duration)
        entries.update { list in
            list.append(entry)
            if list.count > capacity { list.removeFirst(list.count - capacity) }
        }
        // Public, so `log show --predicate 'subsystem == "com.arnav.steady"'` shows it.
        logger.notice("\(entry.line, privacy: .public)")
    }

    var all: [Entry] { entries.get() }

    var text: String { all.map(\.line).joined(separator: "\n") }

    func clear() { entries.set([]) }
}
