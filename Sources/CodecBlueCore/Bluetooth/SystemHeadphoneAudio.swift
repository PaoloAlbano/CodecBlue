import CoreAudio
import Foundation

/// Whether macOS (coreaudiod) currently has audio devices for given headphones.
///
/// coreaudiod publishes Bluetooth headphones with UIDs such as "AA-BB-CC-DD-EE-FF:output"
/// (observed by Blue Bloom). They disappear in the same millisecond macOS's AVDTP
/// signaling channel closes, which tells us when the headphones are free to grab.
public enum SystemHeadphoneAudio {
    public static func uidPrefix(for address: String) -> String {
        address.uppercased().replacingOccurrences(of: ":", with: "-")
    }

    /// macOS has any audio device (music or call) for the headphones.
    public static func hasDevice(address: String) -> Bool {
        !devices(address: address).isEmpty
    }

    /// UIDs of macOS's audio devices for the headphones (diagnostics).
    public static func devices(address: String) -> [String] {
        let prefix = uidPrefix(for: address)
        return deviceUIDs().filter { $0.uppercased().replacingOccurrences(of: ":", with: "-").hasPrefix(prefix) }
    }

    static func deviceUIDs() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else {
                return nil
            }
            return uid.takeRetainedValue() as String
        }
    }
}
