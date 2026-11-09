import CoreAudio
import Foundation

/// Makes CodecBlue the system output while it streams, and puts back what was there before.
///
/// Why this exists: the virtual device is published by a HAL plug-in, so it is in the output list
/// whether or not anything is feeding it. Choosing it is therefore a separate act from starting
/// the stream, and it used to be a manual one — `scripts/setoutput.swift CodecBlue` — with a
/// silent failure for anyone who did not know: the device accepts audio and throws it away.
///
/// The restore is deliberately conservative: the previous device is remembered and put back at the
/// end, but only if CodecBlue is still the default. If the listener changed the output by hand
/// while streaming — headphones, a USB interface, the speakers — that choice wins, because a
/// program that takes the output back at the end of a stream is a program that fights the user.
public enum DefaultOutput {
    /// What was the default output when the stream took over.
    ///
    /// The UID, not the object id. Measured 2026-11-09: the first version stored the `AudioDeviceID`
    /// and set it back at the end — and it silently did nothing, because by then the headphones'
    /// device had been destroyed and recreated by the hand-back, and setting a device id that no
    /// longer exists returns `noErr` and changes nothing. The id is a handle for as long as the
    /// device lives; the UID survives.
    public struct Saved: Sendable {
        public let uid: String
        public let name: String
    }

    /// The UID of a device, which is what a saved choice has to be keyed on.
    public static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
            let value
        else { return nil }
        return value.takeUnretainedValue() as String
    }

    /// The name of a device, for the log and for the menu. Never a reason to fail: an unnamed
    /// device is still a device, and refusing to restore it would be worse than a vague log line.
    public static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
            let value
        else { return nil }
        return value.takeUnretainedValue() as String
    }

    /// Every output device the system currently lists, with its UID.
    public static func devices() -> [(device: AudioDeviceID, uid: String, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard let uid = uid(of: id) else { return nil }
            return (id, uid, name(of: id) ?? uid)
        }
    }

    /// The device with that UID, if it is present right now.
    public static func device(withUID uid: String) -> AudioDeviceID? {
        devices().first { $0.uid == uid }?.device
    }

    /// The current default output device.
    public static func currentDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != 0
        else { return nil }
        return device
    }

    /// The current default output, as something that can be put back later.
    public static func current() -> Saved? {
        guard let device = currentDevice(), let uid = uid(of: device) else { return nil }
        return Saved(uid: uid, name: name(of: device) ?? uid)
    }

    /// Makes `device` the default output. Returns false if the system refused, which is worth
    /// saying out loud: the stream would run and nobody would hear it.
    @discardableResult
    public static func set(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = device
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        return status == noErr
    }

    /// Makes CodecBlue the default output, remembering what was there.
    ///
    /// Returns nil when there is nothing to do: the device is not installed, or it already was the
    /// default. Nil is not a failure — a stream can run without being the system output, it just
    /// plays silence, and the caller says so.
    public static func takeOver(deviceNamed name: String = "CodecBlue") -> Saved? {
        // Wait for the device to be *listed*, then for it to be visible.
        //
        // Both waits are needed and they are different questions. A hidden device is not returned
        // by `kAudioHardwarePropertyDevices` at all — measured 2026-11-09: seven devices listed,
        // CodecBlue among none of them — so looking it up once, before the driver has noticed the
        // ring, finds nothing and the stream runs without being the output. The old order looked
        // it up first and waited afterwards, which only appeared to work because macOS had
        // restored CodecBlue as the default by itself.
        guard let ours = waitUntilListed(name: name) else { return nil }
        _ = waitUntilVisible(ours)
        guard let previous = current() else { return nil }
        if previous.uid == uid(of: ours) { return nil }
        guard set(ours) else { return nil }
        // Written down, because the restore happens in this process and this process can die.
        remember(previous)
        return previous
    }

    /// Where the previous output is remembered, so a crash can still give it back.
    ///
    /// Measured 2026-11-09: `kill -9` mid-stream left CodecBlue as the system output with nothing
    /// feeding it. The device hid itself correctly, and the Mac was then silent — every app playing
    /// into a device that was not there. The restore lived in a `defer` in the process that died,
    /// which is the same mistake as the `feeding` flag: anything that must survive a crash cannot
    /// live only in a process.
    static var savedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodecBlue/previous-output.json")
    }

    private struct Remembered: Codable {
        var uid: String
        var name: String
    }

    static func remember(_ saved: Saved) {
        let url = savedURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = Remembered(uid: saved.uid, name: saved.name)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The output that was remembered, if any.
    public static func remembered() -> Saved? {
        guard let data = try? Data(contentsOf: savedURL),
            let record = try? JSONDecoder().decode(Remembered.self, from: data)
        else { return nil }
        return Saved(uid: record.uid, name: record.name)
    }

    public static func forget() {
        try? FileManager.default.removeItem(at: savedURL)
    }

    /// Gives back a remembered output that was never given back, because the process died.
    ///
    /// Called at startup and by `codecblue stop`. It only acts when CodecBlue is still the default
    /// and nothing is feeding it: a remembered choice from a healthy stream must not be applied
    /// while that stream is running, and a choice the listener made by hand must not be undone.
    @discardableResult
    public static func recoverIfOrphaned(deviceNamed name: String = "CodecBlue") -> Restore {
        guard let saved = remembered() else { return .nothingToDo }
        // Not `forget()` when the device is missing. A hidden device is not listed by every
        // enumeration path, and forgetting a debt because the device was momentarily invisible
        // loses the only record of what the output was. Measured 2026-11-09: the record was
        // dropped at startup, the restart then found CodecBlue already selected, saved "CodecBlue"
        // as the thing to restore, and the real answer was gone for good.
        guard let ours = SystemVolume.findDevice(named: name) else { return .nothingToDo }
        guard let now = currentDevice(), now == ours else {
            // The listener already moved on: the record is stale, not a debt.
            forget()
            return .nothingToDo
        }
        guard let target = device(withUID: saved.uid) else { return .gone(saved.name) }
        guard set(target), currentDevice() == target else { return .leftAlone(saved.name) }
        forget()
        return .restored(saved.name)
    }

    /// Waits until the named device appears in the system's device list.
    ///
    /// Separate from `waitUntilVisible`, and not a duplicate: a hidden device is not listed at
    /// all, so "not in the list" and "listed but hidden" are different states that a single
    /// lookup cannot tell apart.
    public static func waitUntilListed(name: String, timeout: TimeInterval = 3) -> AudioDeviceID? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let device = SystemVolume.findDevice(named: name) { return device }
            usleep(50_000)
        }
        return SystemVolume.findDevice(named: name)
    }

    /// Waits until a device stops being hidden, up to `timeout`.
    ///
    /// Needed because the driver hides its device while nothing is feeding it, and a hidden device
    /// is not eligible as the default. The stream marks the ring as fed and then immediately wants
    /// to be the output; the driver notices the change on its own half-second poll, so without this
    /// wait the two race and the output is set — or refused — depending on the millisecond.
    public static func waitUntilVisible(
        _ device: AudioDeviceID, timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isHidden(device) { return true }
            usleep(50_000)
        }
        return !isHidden(device)
    }

    /// Whether the device says it is hidden. A device that does not answer is not hidden: the
    /// property is optional, and treating silence as "hidden" would refuse to use devices that
    /// simply do not implement it.
    public static func isHidden(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    /// What happened when the output was given back.
    public enum Restore: Sendable, Equatable {
        case restored(String)
        /// The listener chose another output while streaming; it was left alone.
        case leftAlone(String)
        /// The device that was there before never came back (unplugged, out of range).
        case gone(String)
        case nothingToDo
    }

    /// Puts `saved` back, but only if CodecBlue is still the default.
    ///
    /// `wait` is how long to wait for the previous device to reappear. It is not politeness: the
    /// headphones are handed back to macOS a moment before this runs, so their audio device is
    /// destroyed and republished, and setting it while it is gone returns `noErr` and does nothing.
    /// Measured 2026-11-09 — the log said "back to HUAWEI FreeBuds 5" and the system stayed on
    /// CodecBlue, which is the worst kind of success message.
    public static func giveBack(
        _ saved: Saved?, deviceNamed name: String = "CodecBlue", wait: TimeInterval = 5
    ) async -> Restore {
        guard let saved else { return .nothingToDo }
        guard let ours = SystemVolume.findDevice(named: name) else { return .nothingToDo }
        guard let now = currentDevice() else { return .nothingToDo }
        guard now == ours else {
            return .leftAlone(current().map { $0.name } ?? "another device")
        }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if let target = device(withUID: saved.uid) {
                guard set(target) else { return .leftAlone(saved.name) }
                // Verify, because `set` returning `noErr` is not the same as the system agreeing.
                if currentDevice() == target { return .restored(saved.name) }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .gone(saved.name)
    }
}
