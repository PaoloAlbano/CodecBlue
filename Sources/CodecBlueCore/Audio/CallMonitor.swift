import CoreAudio
import Foundation

/// Watches who is using the microphone, so that a call can take the headphones back.
///
/// Why this exists: CodecBlue owns the headphones' link, and a call needs them — the microphone
/// above all. Until now "during calls CodecBlue gives the headphones back to macOS" was a line in
/// the plan and nothing more: the only way to answer a call was to stop CodecBlue by hand, and
/// nobody does that in the two seconds before a call starts. So the microphone was simply not
/// there, and nothing said why.
///
/// The signal is `kAudioProcessPropertyIsRunningInput`: it says *which process* has the microphone
/// open, right now, for every app. That is better than a list of call applications, which goes
/// stale and gets the browser wrong — a Meet call is a Chrome tab, not Chrome.
///
/// What it cannot tell: a recorder, a dictation session and a call all look the same. So there is
/// an exclusion list, and every decision is logged with the bundle id that caused it — a wrong
/// exclusion is then one line in a log away from being fixed, instead of a mystery.
public final class CallMonitor: @unchecked Sendable {
    /// Bundle ids that open the microphone without being a call.
    ///
    /// Kept short on purpose. Each entry is a *measured* nuisance, not a guess: an entry added
    /// speculatively makes calls go undetected, which is the failure this class exists to prevent.
    /// The one entry that matters today is dictation: it holds the microphone open for as long as
    /// the feature is on, so without this the stream would stop the moment the user dictated
    /// anything and never come back.
    public static let notACall: Set<String> = [
        "com.apple.SpeechRecognitionCore",
        "com.apple.speech.recognition.AppleSpeechRecognition.prefpane",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.audio.AudioComponentRegistrar",
        "com.apple.CoreSpeech",
    ]

    /// The rule, as a pure function so it can be tested without a microphone.
    ///
    /// `nil` bundle id means a process that has no bundle (a command-line tool, a daemon). Those
    /// are treated as *not* a call: `rec`, `sox` and `ffmpeg` are far more common than a
    /// command-line phone, and stopping the music for them would be wrong.
    public static func isCall(bundleID: String?, isOurOwn: Bool) -> Bool {
        if isOurOwn { return false }
        guard let bundleID, !bundleID.isEmpty else { return false }
        return !notACall.contains(bundleID)
    }

    /// How long after the last microphone user disappears before the call counts as over.
    ///
    /// Calls hand the microphone back a moment before the app notices the call ended, and a
    /// re-dial in the same minute is common. Resuming the stream and immediately taking the
    /// headphones away again is worse than waiting five seconds.
    public var hangover: TimeInterval = 5

    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "codecblue.callmonitor")
    private var timer: DispatchSourceTimer?
    private var stateLock = NSLock()
    private var active = false
    private var lastSeen: Date?
    private var reported: String?

    public init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// Whether a call is using the microphone right now, hangover included.
    public var isCallActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active
    }

    /// Called when the state changes, on the monitor's own queue. `true` means a call has taken
    /// the microphone and the headphones must go back to macOS; `false` means it is over.
    public var onChange: (@Sendable (Bool) -> Void)?

    /// Starts looking, once a second.
    ///
    /// A second is the right period: the cost of being late is a second of a call where the
    /// microphone is not there yet, and the cost of being early is nothing. Property listeners
    /// would answer sooner and cost far more code — three listeners per process, each with a
    /// lifetime to get wrong — for a latency nobody can hear.
    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// One look at the microphone's users.
    private func poll() {
        let now = Date()
        // An open microphone is not a call: it is a promise to use one.
        //
        // Measured 2026-11-09, and it is the whole reason this check exists: Chrome's renderer
        // helper had `IsRunningInput = 1` continuously for four days — `lstart Thu 5 Nov 12:02`,
        // checked on the 9th — while the input device reported `DeviceIsRunningSomewhere = 0`. It
        // had the microphone *opened* and was running no IO at all. The first version of this
        // class believed `IsRunningInput` alone, so it handed the headphones back at the first
        // poll of every stream, with no call anywhere in sight.
        //
        // `DeviceIsRunningSomewhere` is the difference between "an app holds the microphone" and
        // "sound is being captured": 0 with Chrome idling, 1 the moment a real capture starts.
        // Both facts are needed — the device says whether audio flows, the process says who is
        // taking it, the exclusion list says whether that is a call.
        guard Self.inputIsRunning() else {
            settle(now: now)
            return
        }
        let users = Self.microphoneUsers()
        let call = users.first { Self.isCall(bundleID: $0.bundleID, isOurOwn: $0.isOurs) }

        stateLock.lock()
        if let call {
            lastSeen = now
            if !active {
                active = true
                let name = call.bundleID ?? "pid \(call.pid)"
                let changed = reported != name
                reported = name
                stateLock.unlock()
                if changed {
                    log("a call is using the microphone (\(name)): handing the headphones back")
                }
                onChange?(true)
                return
            }
            stateLock.unlock()
            return
        }

        settle(now: now)
    }

    /// Nobody is capturing audio: wait out the hangover, then declare the call over.
    private func settle(now: Date) {
        stateLock.lock()
        guard active else {
            stateLock.unlock()
            return
        }
        let quiet = now.timeIntervalSince(lastSeen ?? now)
        if quiet >= hangover {
            active = false
            reported = nil
            stateLock.unlock()
            log("the microphone is free again: the call is over")
            onChange?(false)
            return
        }
        stateLock.unlock()
    }

    /// Whether any input device is capturing audio right now.
    ///
    /// Every input device, not just the default one: a call can be on the headphones' microphone
    /// while the system's default input is the Mac's, and the question here is "is anyone
    /// recording", not "is the device I would have picked recording".
    public static func inputIsRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return false
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return false
        }
        return ids.contains { device in
            // Only devices that have an input at all: `DeviceIsRunningSomewhere` is true for the
            // speakers while a song plays, and a playing song is not a call.
            hasInput(device) && runningSomewhere(device)
        }
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func runningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    public struct MicrophoneUser: Sendable {
        public var pid: pid_t
        public var bundleID: String?
        /// True for this process (or a helper of ours): never a call.
        public var isOurs: Bool
    }

    /// Every process the audio system knows about that has the microphone open.
    public static func microphoneUsers() -> [MicrophoneUser] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        return ids.compactMap { id in
            guard running(id, selector: kAudioProcessPropertyIsRunningInput) else { return nil }
            let pid = pidValue(id)
            return MicrophoneUser(
                pid: pid, bundleID: bundleID(id), isOurs: pid == ourPID)
        }
    }

    private static func running(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func pidValue(_ id: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    private static func bundleID(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
            let value
        else { return nil }
        return value.takeUnretainedValue() as String
    }
}
