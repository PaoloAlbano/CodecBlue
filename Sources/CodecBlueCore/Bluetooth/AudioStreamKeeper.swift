import Foundation

/// Keeps bluetoothd believing that an A2DP stream is running, so that it keeps the link in its
/// "A2DP Link Quality Mode" — the Broadcom vendor command (`_BCM_WriteLinkQualityMode`) that
/// makes the controller schedule our packets at 80–90 per second instead of 8–10.
///
/// Measured on 2026-11-06 with the FreeBuds 5, four times out of four, link already `active`:
///
///     Link Quality Mode OFF → flood 679 B:  55, 59 kbps
///     Link Quality Mode ON  → flood 679 B: 436, 435 kbps
///
/// Sniff mode is not the variable: the link was `newMode 0 (active)` in every one of those runs.
///
/// How it works: `com.apple.BTAudioHALPlugin.xpc` — bluetoothd's audio channel — is not
/// entitlement-gated, and `BTAudioMsgIdStartAudio` on it produces
/// `Received system 'audio started' notification from HAL on a2dpHandle N`, which is what makes
/// `Server.Audio` start its own stream, enable the link quality mode and take the link out of
/// sniff. Repeating the message every couple of seconds keeps that belief alive.
///
/// Two rules, both learned the hard way:
/// - `kBTAudioMsgArgs` must always be present. Without it bluetoothd does `CFRelease(NULL)` in
///   `_xpc_connection_call_event_handler` and dies (four crash reports, 2026-11-06).
/// - The UID must be the one bluetoothd already knows: `40:DC:A5:0E:14:48-tacl`, colon form plus
///   the transport suffix. The dashed CoreAudio spellings get `No device found for uid`.
public final class AudioStreamKeeper: @unchecked Sendable {
    /// `BTAudioMsgIdStartAudio`, read off bluetoothd's own log one message number at a time.
    private static let startAudio: Int64 = 5

    private let probe: XPCProbe
    private let uid: String
    private let address: String
    private let deviceUUID: String
    private let period: TimeInterval
    private let log: (String) -> Void
    private var task: Task<Void, Never>?
    /// Set once bluetoothd is seen holding the audio device again.
    private var confirmed = false
    private var attempts = 0

    /// `deviceUUID` is bluetoothd's own `CBDevice` UUID for the headphones, the one it prints in
    /// its log (`CBDevice 4379D275-…`). Without it the audio channel answers
    /// `No device found for uid …` and nothing happens; with it the message reaches the device
    /// and `Server.Audio` starts its stream. See `CBDeviceUUID`.
    public init(
        address: String, deviceUUID: String, period: TimeInterval = 2,
        uidSuffix: String = "tacl",
        log: @escaping (String) -> Void
    ) {
        self.address = address
        self.deviceUUID = deviceUUID
        self.uid = "\(address)-\(uidSuffix)"
        self.period = period
        self.log = log
        self.probe = XPCProbe(service: "com.apple.BTAudioHALPlugin.xpc")
    }

    /// Says "audio started" once and keeps saying it until `stop()`.
    ///
    /// Repeating is the mechanism, not a workaround: the takeover makes bluetoothd unpublish its
    /// audio device for the headphones (`Closing media channel` → `Erased … -tacl`), and it
    /// republishes it about 14 s later. Until it does, every message is answered
    /// `No device found for uid` and does nothing — so the only way to be sure the link quality
    /// mode is on is to keep asking and to *notice when the answer changes*.
    public func start() {
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.sendStartAudio()
                // Re-check on every attempt, not once.
                //
                // Confirming only once meant that when bluetoothd erased the device again —
                // which it does whenever the media channel is reopened, and it happened seven
                // times in one 45 s session — the keeper kept sending into nothing and the link
                // fell back to `at most 3 packet(s) per drain` for the ~14 s it takes bluetoothd
                // to republish. That window is heard as crackle, and it is the reason the link
                // looked unstable even after the LQM was "on".
                self.attempts += 1
                let registered = self.deviceIsRegistered()
                if registered != self.confirmed {
                    self.confirmed = registered
                    if registered {
                        self.log("link quality mode on: bluetoothd has the audio device again "
                                 + "after \(self.attempts) attempt(s)")
                    } else {
                        self.log("link quality mode lost: bluetoothd erased the audio device, "
                                 + "asking again until it comes back")
                    }
                }
                try? await Task.sleep(for: .seconds(self.period))
            }
        }
    }

    /// Whether bluetoothd currently has an audio device for these headphones. Read from its own
    /// log, which is the only place that says so: the device is created and destroyed there.
    private func deviceIsRegistered() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            // Five minutes, not thirty seconds: the device is registered once when the
            // headphones connect, and that line can be long past by the time we start. A short
            // window found nothing and the keeper never confirmed — while the link quality mode
            // was in fact on, which is worse than not reporting at all.
            "show", "--last", "5m", "--predicate", "process == \"bluetoothd\"",
            "--style", "compact",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return Self.hasRegisteredDevice(text, uid: uid)
    }

    /// The rule, exposed for the self-test: the last thing bluetoothd said about our uid decides.
    /// `Register audio device …-tacl` means it is there; `Erased 1 audio device …-tacl` means it
    /// is not. Later lines win, because the device can come and go.
    ///
    /// Matched on the address, not on `uid`: the suffix is not guaranteed to be `-tacl` for every
    /// pair of headphones, and a device that reports a different one would otherwise never be
    /// seen as registered.
    public static func hasRegisteredDevice(_ log: String, uid: String) -> Bool {
        // The address is the part before the transport suffix: `40:DC:A5:0E:14:48-tacl`. Split
        // on the suffix separator, not on `-`, because the address is full of hyphens in the
        // dashed CoreAudio spelling and splitting on those would cut it in half.
        let address = uid.components(separatedBy: "-t").first ?? uid
        var registered = false
        for line in log.split(separator: "\n") where line.contains(address) {
            if line.contains("Register audio device") { registered = true }
            if line.contains("Erased") && line.contains("audio device") { registered = false }
        }
        return registered
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }

    private func sendStartAudio() {
        probe.sendRaw([
            "kBTAudioMsgId": Self.startAudio,
            "kBTAudioMsgDeviceUid": uid,
            "kBTAudioMsgDeviceUUID": deviceUUID,
            // Never omit this: bluetoothd releases it without a nil check.
            "kBTAudioMsgArgs": [
                "kBTAudioMsgArgDeviceType": Int64(1),
                "kBTAudioMsgArgDeviceProperties": [
                    "kBTAudioMsgPropertyDeviceUID": uid,
                    "kBTAudioMsgPropertyDeviceAddress": address,
                    "kBTAudioMsgPropertyDeviceUUID": deviceUUID,
                ],
            ],
        ])
    }
}
