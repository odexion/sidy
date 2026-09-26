import AudioToolbox
import CoreAudio

/// The system output volume, read and set through Core Audio, so no permission is needed.
enum SystemVolume {
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static var device: AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// 0...1, or nil when the output (e.g. some HDMI and USB devices) has no adjustable volume.
    static var level: Float? {
        guard let device, AudioObjectHasProperty(device, &volumeAddress) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    /// Sets the volume and unmutes, or mutes at zero. Returns the level that was set.
    @discardableResult
    static func set(_ level: Float) -> Float? {
        guard let device else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr, settable.boolValue else { return nil }
        var volume = Float32(min(max(level, 0), 1))
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        if AudioObjectHasProperty(device, &muteAddress) {
            var mute: UInt32 = volume == 0 ? 1 : 0
            AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
        }
        return volume
    }
}
