import CoreAudio
import Foundation

// Lists output devices, or sets the default output by name substring.
func devices() -> [(AudioDeviceID, String)] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    var out: [(AudioDeviceID, String)] = []
    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var nsize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsize, &name) == noErr else { continue }
        // only devices with output streams
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var ssize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &ssize)
        if ssize == 0 { continue }
        out.append((id, name as String))
    }
    return out
}

let args = CommandLine.arguments
let list = devices()
if args.count < 2 {
    for (id, name) in list { print("\(id)\t\(name)") }
    exit(0)
}
guard let match = list.first(where: { $0.1.localizedCaseInsensitiveContains(args[1]) }) else {
    print("not found"); exit(1)
}
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var id = match.0
let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                        UInt32(MemoryLayout<AudioDeviceID>.size), &id)
print(status == noErr ? "set \(match.1)" : "failed \(status)")
