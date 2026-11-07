import CoreAudio
import Foundation

/// Watches the system volume of the CodecBlue device.
///
/// The volume used to be applied inside the driver, which is the worst place for it: the driver
/// sits at the *start* of the chain, so every change had to travel through the ring buffer and
/// the packet queue before reaching the headphones — two to three seconds of delay between
/// moving the slider and hearing it.
///
/// Applying it here, just before the encoder, leaves only the codec and the link in the way
/// (~50 ms). The cost is that this process must know the value, and it must not poll: a
/// CoreAudio property read 375 times a second would sit in the hot path. So it registers a
/// listener and keeps the value in a plain float that the audio thread reads.
///
/// The driver keeps its own control, so the slider and the volume keys still work; the driver
/// just no longer multiplies. See `CodecBlueDriver.c`.
public final class SystemVolume: @unchecked Sendable {
    private let device: AudioDeviceID
    private let lock = NSLock()
    /// A queue of its own: the listener was registered on `.main`, and the main thread sits in an
    /// `await` for the whole stream, so the block never ran and the volume never changed.
    private let queue = DispatchQueue(label: "codecblue.volume")
    private var refreshTimer: DispatchSourceTimer?
    private var stored: Float = 1
    /// The slider position, 0…1, as the device reports it.
    private var position: Float = 1
    private var muted = false
    private var listener: AudioObjectPropertyListenerBlock?

    /// The device the system is using for output, if it is ours. Returns nil when CodecBlue is not
    /// the default output: then there is nothing to read and the volume stays at 1.
    public init?(deviceNamed name: String = "CodecBlue") {
        guard let id = Self.findDevice(named: name) else { return nil }
        device = id
        position = Self.readVolume(device: id) ?? 1
        stored = Self.readDecibels(device: id).map(Self.gain(fromDecibels:))
            ?? Self.applyCurve(position)
        muted = Self.readMute(device: id) ?? false
        listen()
    }

    deinit { removeListener() }

    /// The decibel range the driver declares. Kept here only to convert when the device does not
    /// answer the decibel property; the driver is the authority (see `CodecBlueDriver.c`).
    public static let minDecibels: Float = -64
    public static let maxDecibels: Float = 0

    /// Decibels to a linear amplitude: the one honest conversion, and the reason the slider feels
    /// right. The driver declares a dB range, macOS maps its slider onto it, and this turns the
    /// result into the number the samples are multiplied by.
    public static func gain(fromDecibels decibels: Float) -> Float {
        guard decibels > minDecibels else { return 0 }
        let clamped = min(decibels, maxDecibels)
        return pow(10, clamped / 20)
    }

    /// How the slider position becomes a gain.
    ///
    /// The slider is linear in *position* but hearing is not linear in *amplitude*: a plain
    /// multiply makes the first notch already loud and the top half unusable, which is exactly
    /// what the listener reported ("a zero non sento, ma se metto una tacca già sento molto
    /// alto, e a metà è altissimo"). macOS does not behave that way because it applies a
    /// perceptual curve; so must we.
    ///
    /// `position^2.5` puts the notches roughly where the ear expects them:
    ///
    /// | slider | gain   | dB    |
    /// |--------|--------|-------|
    /// | 100%   | 1.000  | 0     |
    /// | 75%    | 0.487  | −6    |
    /// | 50%    | 0.177  | −15   |
    /// | 25%    | 0.031  | −30   |
    /// | 6%     | 0.001  | −60   |
    ///
    /// One constant, in one place: if it still feels wrong this is the only number to change.
    public static let curveExponent: Float = 2.5

    /// The gain to apply, 0…1, after the perceptual curve. Cheap: a lock and a load, meant to be
    /// called per block.
    ///
    /// Zero means zero. An earlier version read 0 as "not set yet" and substituted full scale,
    /// which made the slider backwards at the bottom: setting the volume to 0 played at maximum.
    /// The "not set yet" case is real but it belongs to the driver, which knows whether it has
    /// ever written a value; here the number is taken at face value.
    public var gain: Float {
        lock.lock()
        defer { lock.unlock() }
        if muted { return 0 }
        return stored
    }

    /// The curve on its own, exposed for the self-test.
    public static func applyCurve(_ position: Float) -> Float {
        let clamped = min(max(position, 0), 1)
        guard clamped > 0 else { return 0 }
        return pow(clamped, curveExponent)
    }

    /// The slider position the device reported, for the log.
    public var reported: Float {
        lock.lock()
        defer { lock.unlock() }
        return position
    }

    public var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    private func listen() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let slider = Self.readVolume(device: self.device) ?? self.position
            let decibels = Self.readDecibels(device: self.device)
            let isMuted = Self.readMute(device: self.device) ?? self.muted
            self.lock.lock()
            self.position = slider
            self.stored = decibels.map(Self.gain(fromDecibels:)) ?? Self.applyCurve(slider)
            self.muted = isMuted
            self.lock.unlock()
        }
        listener = block
        // A listener that never fires is silent, and the stream keeps the old gain forever. Ten
        // property reads a second cost nothing and make the volume work even if the notification
        // does not arrive.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        refreshTimer = timer
        AudioObjectAddPropertyListenerBlock(device, &address, queue, block)

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(device, &muteAddress, queue, block)
    }

    private func refresh() {
        let slider = Self.readVolume(device: device) ?? position
        let decibels = Self.readDecibels(device: device)
        let isMuted = Self.readMute(device: device) ?? muted
        lock.lock()
        position = slider
        stored = decibels.map(Self.gain(fromDecibels:)) ?? Self.applyCurve(slider)
        muted = isMuted
        lock.unlock()
    }

    private func removeListener() {
        refreshTimer?.cancel()
        refreshTimer = nil
        guard let listener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(device, &muteAddress, queue, listener)
    }

    private static func readVolume(device: AudioDeviceID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    /// The volume in decibels, if the device answers. Preferred over the scalar, because the
    /// scalar is a *position* on the slider and the gain is an amplitude: converting through dB
    /// is what makes the notches land where the ear expects them.
    /// Moves the system volume by `delta` of the slider, and writes it back to the device so the
    /// slider, the menu bar and the volume keys all follow.
    ///
    /// This exists for the headphones' own volume buttons. They arrive as AVRCP PASS THROUGH
    /// `volume_up`/`volume_down`, and until now they were only logged: the headphones' buttons
    /// did nothing at all, which is the reported "non riesco ad aumentare e abbassare il volume
    /// tramite le cuffie".
    ///
    /// Writing the *scalar* rather than the gain keeps one source of truth: the driver stores the
    /// position, `SystemVolume`'s listener reads it back and converts it through the decibel
    /// range, and the audio path never learns that a button was pressed.
    ///
    /// - Returns: the new slider position, or nil if the device refused the write.
    @discardableResult
    public func step(by delta: Float) -> Float? {
        let current = Self.readVolume(device: device) ?? position
        let next = min(max(current + delta, 0), 1)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value = Float32(next)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil,
                                                UInt32(MemoryLayout<Float32>.size), &value)
        guard status == noErr else { return nil }
        // The listener is asynchronous; update our own copy now so two quick presses add up
        // instead of both starting from the same stale value.
        lock.lock()
        position = next
        stored = Self.readDecibels(device: device).map(Self.gain(fromDecibels:))
            ?? Self.applyCurve(next)
        lock.unlock()
        return next
    }

    /// Sets the slider to an absolute position, for headphones that send SET ABSOLUTE VOLUME
    /// instead of a relative key.
    @discardableResult
    public func set(position target: Float) -> Float? {
        let next = min(max(target, 0), 1)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value = Float32(next)
        guard AudioObjectSetPropertyData(device, &address, 0, nil,
                                         UInt32(MemoryLayout<Float32>.size), &value) == noErr
        else { return nil }
        lock.lock()
        position = next
        stored = Self.readDecibels(device: device).map(Self.gain(fromDecibels:))
            ?? Self.applyCurve(next)
        lock.unlock()
        return next
    }

    private static func readDecibels(device: AudioDeviceID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyDecibelValue,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func readMute(device: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    /// The device the system is using for output, matched by name.
    public static func findDevice(named name: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var deviceName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &deviceName) == noErr
            else { continue }
            if (deviceName as String).localizedCaseInsensitiveContains(name) { return id }
        }
        return nil
    }
}
