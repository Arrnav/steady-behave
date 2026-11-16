import Carbon
import Foundation

/// Global hotkeys through Carbon's RegisterEventHotKey. Needs no Accessibility permission.
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false
    private let signature: OSType = 0x5354_4459 // "STDY"

    /// Virtual key codes for the letters Steady uses.
    enum Key: UInt32 {
        case s = 1, d = 2, x = 7, m = 46
    }

    func register(_ key: Key, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(key.rawValue, UInt32(controlKey | optionKey), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            EventLog.shared.add(.info, nil, "Hotkey for key \(key) is taken by another app")
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeys.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
