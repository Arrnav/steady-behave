import CoreGraphics

/// Recent keyboard and mouse use. Only the time since the last event is read (no keys or positions),
/// so this needs no Input Monitoring permission.
enum InputActivity {
    static let keyboardEvents: [CGEventType] = [.keyDown, .flagsChanged]
    static let mouseEvents: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .scrollWheel
    ]

    static func secondsSince(_ events: [CGEventType]) -> Double {
        events.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    /// True when a watched input was used within the pause window and pausing is turned on.
    static func isActive(settings: Settings) -> Bool {
        guard settings.typingSuppression else { return false }
        if settings.inputKeyboard, secondsSince(keyboardEvents) < settings.typingWindow { return true }
        if settings.inputMouse, secondsSince(mouseEvents) < settings.typingWindow { return true }
        return false
    }
}
