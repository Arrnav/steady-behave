import AppKit
import Foundation

/// Trackpad haptics. MacBooks have no vibration motor, but the Force Touch trackpad has an actuator.
///
/// Primary backend: the private MultitouchSupport framework, loaded at runtime with dlopen
/// (never linked). It can tap the trackpad even with no finger on it.
/// Fallback: NSHapticFeedbackManager, which only works while a finger is on the trackpad.
/// Every private call is checked, so a missing symbol only means falling back.
final class Haptics {
    static let shared = Haptics()

    enum Backend: String {
        case privateAPI = "Private API (MultitouchSupport)"
        case fallback = "Fallback (finger on trackpad)"
        case none = "None"
    }

    /// Waveform IDs documented by mactic.
    static let waveforms: [(id: Int, name: String)] = [
        (1, "Weak click"), (2, "Strong click"), (3, "Buzz"), (4, "Light tap"), (5, "Medium tap"), (6, "Strong tap")
    ]

    // C signatures, from niw's MTActuator sample:
    //   CFTypeRef MTActuatorCreateFromDeviceID(UInt64 deviceID)
    //   IOReturn  MTActuatorOpen(CFTypeRef)
    //   IOReturn  MTActuatorActuate(CFTypeRef, SInt32 actuationID, UInt32, Float32, Float32)
    //   IOReturn  MTActuatorClose(CFTypeRef)
    //   CFArrayRef MTDeviceCreateList(void)
    //   OSStatus  MTDeviceGetDeviceID(MTDeviceRef, UInt64 *)
    private typealias CreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias OpenCloseFn = @convention(c) (CFTypeRef) -> Int32
    private typealias ActuateFn = @convention(c) (CFTypeRef, Int32, UInt32, Float32, Float32) -> Int32
    private typealias ListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetIDFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32

    private var actuator: CFTypeRef?
    private var actuate: ActuateFn?
    private(set) var backend = Backend.none
    private(set) var deviceID: UInt64?
    private(set) var detail = ""
    private let queue = DispatchQueue(label: "steady.haptics")

    /// The device ID hardcoded in niw's sample, tried last.
    private static let fallbackDeviceID: UInt64 = 0x200000001000000

    private init() {
        load()
    }

    private func load() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            useFallback("MultitouchSupport could not be loaded")
            return
        }
        guard let createSym = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let openSym = dlsym(handle, "MTActuatorOpen"),
              let actuateSym = dlsym(handle, "MTActuatorActuate") else {
            useFallback("MTActuator symbols are missing")
            return
        }
        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let open = unsafeBitCast(openSym, to: OpenCloseFn.self)

        // Enumerate multitouch devices and read their IDs; built-in first.
        var ids: [UInt64] = []
        if let listSym = dlsym(handle, "MTDeviceCreateList"), let idSym = dlsym(handle, "MTDeviceGetDeviceID") {
            let list = unsafeBitCast(listSym, to: ListFn.self)
            let getID = unsafeBitCast(idSym, to: GetIDFn.self)
            if let array = list()?.takeRetainedValue() {
                for i in 0..<CFArrayGetCount(array) {
                    guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
                    var id: UInt64 = 0
                    if getID(UnsafeMutableRawPointer(mutating: raw), &id) == 0, id != 0 { ids.append(id) }
                }
            }
        }
        ids.append(Self.fallbackDeviceID)

        for id in ids {
            guard let ref = create(id)?.takeRetainedValue() else { continue }
            if open(ref) == 0 {
                actuator = ref
                actuate = unsafeBitCast(actuateSym, to: ActuateFn.self)
                deviceID = id
                backend = .privateAPI
                detail = String(format: "Device 0x%llx", id)
                return
            }
        }
        useFallback("No trackpad actuator could be opened")
    }

    private func useFallback(_ reason: String) {
        backend = .fallback
        detail = reason
        EventLog.shared.add(.info, nil, "Haptics using fallback: \(reason)")
    }

    /// Plays a single waveform. Returns true if the private API accepted it.
    @discardableResult
    func play(_ waveform: Int) -> Bool {
        if backend == .privateAPI, let actuator, let actuate {
            return actuate(actuator, Int32(waveform), 0, 0, 0) == 0
        }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = waveform >= 5 ? .levelChange : (waveform == 3 ? .alignment : .generic)
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
        return false
    }

    /// Plays waveforms with gaps in milliseconds between them, off the main thread.
    func pattern(_ steps: [(waveform: Int, delayMs: Int)]) {
        queue.async { [self] in
            for step in steps {
                if step.delayMs > 0 { usleep(useconds_t(step.delayMs * 1000)) }
                play(step.waveform)
            }
        }
    }

    func alert(_ kind: AlertKind, settings: Settings) {
        switch kind {
        case .smile: pattern([(settings.smileWaveform, 0), (settings.smileWaveform, 120)])
        case .lookAway: pattern([(settings.lookAwayWaveform, 0)])
        case .overActive, .handsAtFace: pattern([(4, 0)])
        }
    }
}
