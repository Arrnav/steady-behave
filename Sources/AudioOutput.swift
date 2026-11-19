import CoreAudio

/// The current sound output, to avoid speaking out loud through the Mac's speakers in public.
enum AudioOutput {
    private static func defaultDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func uint32(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// True for Bluetooth audio (AirPods, other headphones, speakers).
    static var isBluetooth: Bool {
        guard let device = defaultDevice() else { return false }
        let transport = uint32(kAudioDevicePropertyTransportType, of: device)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// True for Bluetooth audio (AirPods and other headphones) and for wired headphones on the built-in jack.
    static var isHeadphones: Bool {
        guard let device = defaultDevice() else { return false }
        let transport = uint32(kAudioDevicePropertyTransportType, of: device)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        // The built-in output reports "hdpn" as its data source when headphones are plugged in.
        let headphonesSource: UInt32 = 0x6864_706E // 'hdpn'
        return transport == kAudioDeviceTransportTypeBuiltIn
            && uint32(kAudioDevicePropertyDataSource, of: device, scope: kAudioDevicePropertyScopeOutput) == headphonesSource
    }

    static var name: String {
        guard let device = defaultDevice() else { return "None" }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let value = name else { return "Unknown" }
        return value.takeRetainedValue() as String
    }
}
