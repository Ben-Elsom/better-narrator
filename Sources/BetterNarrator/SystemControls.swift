import AppKit
import AudioToolbox
import CoreAudio

/// Working copies of the Control Strip's buttons, so Better Narrator can show
/// them next to its own controls: media keys, mute, volume and brightness.
enum SystemControls {
    // MARK: Media keys (the same events the keyboard's F7–F9 keys send)

    enum MediaKey: Int32 { case play = 16, next = 17, previous = 18, mute = 7 }

    static func press(_ key: MediaKey) {
        func post(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }

    // MARK: Volume and mute (Core Audio, default output)

    private static var outputDevice: AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    static var volume: Float {
        get {
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(outputDevice, &volumeAddress, 0, nil, &size, &v)
            return v
        }
        set {
            var v = Float32(max(0, min(1, newValue)))
            let size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectSetPropertyData(outputDevice, &volumeAddress, 0, nil, size, &v)
            if v > 0 && isMuted { isMuted = false }
        }
    }

    static var isMuted: Bool {
        get {
            var m = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(outputDevice, &muteAddress, 0, nil, &size, &m)
            return m != 0
        }
        set {
            var m = UInt32(newValue ? 1 : 0)
            AudioObjectSetPropertyData(outputDevice, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }

    // MARK: Brightness (the built-in display)

    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetBrightness? = displayServices.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetBrightness.self) }
    private static let setBrightness: SetBrightness? = displayServices.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetBrightness.self) }

    static var brightness: Float {
        get {
            var b: Float = 0.5
            _ = getBrightness?(CGMainDisplayID(), &b)
            return b
        }
        set { _ = setBrightness?(CGMainDisplayID(), max(0, min(1, newValue))) }
    }
}
