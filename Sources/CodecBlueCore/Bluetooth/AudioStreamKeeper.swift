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
    /// The pace while bluetoothd does *not* have the audio device.
    ///
    /// The window worth hitting is 660 ms wide (measured 2026-11-08: `Register audio device` at
    /// 18:06:02.105, `Erased` at 18:06:02.765), so a one-second period misses it every time. Ten
    /// messages a second are ten small XPC dictionaries: cheaper than one `log show`, and the only
    /// way to be inside the window when it opens.
    private let fastPeriod: TimeInterval = 0.1
    /// How many fast attempts are left in the current burst. Guarded by `stateLock`.
    private var fastAttemptsLeft = 0
    /// The length of a burst: 30 attempts at 0.1 s is three seconds of looking, which covers the
    /// 660 ms window several times over and then stops filling bluetoothd's log.
    private static let fastBurst = 30
    private let log: (String) -> Void
    private var task: Task<Void, Never>?
    /// Set once bluetoothd is seen holding the audio device again.
    ///
    /// Guarded by a lock because it is written on the watcher's task and read from the status of a
    /// running stream, which is another thread. It is also the single most important fact about a
    /// stream — the link quality mode is the difference between 50 kbps and 500 — and until now it
    /// existed only as a line in a log nobody reads while listening.
    private var confirmed = false
    private let stateLock = NSLock()
    private var attempts = 0
    /// How many slow turns in a row have found bluetoothd without the audio device.
    ///
    /// It exists because of a measured waste: bluetoothd erases its audio device when the media
    /// channel is reopened and — with the stream running fine at 336 kbps and 62 packets/s — never
    /// republishes it. The keeper went on asking once a second into nothing: **290 identical
    /// `No device found for uid` errors in five minutes** (measured 2026-11-08), each one a
    /// wake-up and a line in a log that has to stay readable. The answer cannot change while the
    /// stream owns the link, so the asking slows down instead of stopping: if the device does come
    /// back, a message every half minute still finds it.
    private var idleTurns = 0

    /// Whether bluetoothd is believed to have the audio device, and so whether the link quality
    /// mode is on. `nil` until the first check has run: "not known yet" is a third state, and
    /// reporting it as "off" would be a lie in the first seconds of every stream.
    public var isConfirmed: Bool? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return checked ? confirmed : nil
    }

    /// Whether the watcher has looked at least once.
    private var checked = false

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
            // The first attempt is the one that matters: it is what turns the link quality mode
            // on before the takeover. Everything after it is the *confirmation*, and the
            // confirmation is not on the path that makes the audio work.
            //
            // Measured 2026-11-08: `deviceIsRegistered()` shells out to `log show`, which costs
            // 1.1 s on this Mac whatever the window (`--last 30s` and `--last 30m` are the same
            // 1.1 s: the price is the process and the archive, not the lines). With the check on
            // every attempt the keeper loop ran at 1.9 s instead of the 1 s it asks for, and each
            // turn spent most of its life blocked in a pipe, while the audio thread was the one
            // that needed the CPU. So the check runs on its own task, at its own slower pace, and
            // the sending never waits for it.
            self.sendStartAudio()
            self.noteAttempt()
            // The first burst: the takeover is about to erase bluetoothd's device, and the window
            // in which it comes back is 660 ms wide. Looking fast from here covers it.
            self.restartBurst()
            Task.detached(priority: .background) { [weak self] in self?.watchRegistration() }
            while !Task.isCancelled {
                // Fast until bluetoothd has the device, slow once it does. This is the fix for the
                // crackle that started every stream, and the numbers are why.
                //
                // Measured 2026-11-08 from bluetoothd's own log: after the takeover erases the
                // audio device, it republishes it at 18:06:02.105 and erases it again at
                // 18:06:02.765 — **660 ms** — because the media channel is reopened in between.
                // The keeper asked once a second, so it could miss that window every single time,
                // and it did: `at most 2 packet(s) per drain` (LQM off, ~50 kbps), 29% of the
                // audio dropped, heard as "molto a scatti".
                //
                // A message is an XPC dictionary, not a `log show`: asking ten times a second
                // costs nothing measurable, and it is the only way to hit a 660 ms window. Once
                // the device is confirmed the pace drops back to `period`, because then the work
                // is done and the only job left is to notice if it goes away.
                // Fast while there is a chance, then slow.
                //
                // Two bounds, because "not confirmed" is not the same as "worth asking": after
                // bluetoothd has erased its device the answer is `No device found for uid` for as
                // long as the erase lasts, and asking ten times a second for minutes fills
                // bluetoothd's log with 283 identical errors per 30 s (measured 2026-11-08) and
                // costs a wake-up each time for an answer already known. So the fast pace is spent
                // in a bounded burst around the moments that matter — the start of the stream and
                // each `askAgainNow` — and then the keeper falls back to `period`.
                let waiting = self.shouldAskFast()
                try? await Task.sleep(for: .seconds(waiting ? self.fastPeriod : self.slowPeriod()))
                guard !Task.isCancelled else { break }
                self.sendStartAudio()
                self.noteAttempt()
            }
        }
    }

    /// Sends the first message again, right now, and says so.
    ///
    /// The keeper is started *before* the takeover, because that is the only moment when
    /// bluetoothd still has the audio device published and `StartAudio` is accepted. But the
    /// takeover then makes bluetoothd unpublish it (`Closing media channel` → `Erased … -tacl`),
    /// and from that instant every message is answered `No device found for uid` until bluetoothd
    /// republishes — measured 2026-11-08: the device was back 14 s later, and the link ran at
    /// `at most 3 packet(s) per drain` (LQM off, ~50 kbps) for all 14.
    ///
    /// The window that matters is the one *before* the erase, and it is milliseconds wide: the
    /// first message goes out ~2 s before the takeover even starts, and the next one waits a full
    /// period. So the caller asks for one more the moment the media channel is open, when the
    /// device may still be there. It costs one message and can save the first quarter of a minute.
    public func askAgainNow(because reason: String) {
        guard task != nil else { return }
        sendStartAudio()
        noteAttempt()
        // A new burst: this is a moment when the device may be back, so it is worth looking fast.
        restartBurst()
        log("link quality mode: asked again \(reason)")
    }

    /// Counts one "audio started" sent, under the lock the status reads.
    private func noteAttempt() {
        stateLock.lock()
        attempts += 1
        stateLock.unlock()
    }

    /// Starts a burst of fast attempts. Synchronous on purpose: `NSLock` may not be taken from an
    /// `async` context, and the loop that needs it is one.
    private func restartBurst() {
        stateLock.lock()
        fastAttemptsLeft = Self.fastBurst
        // A burst is a moment when the device may be back, so the slow pace starts over too: a
        // stream that has been idle for ten minutes and then asks again should look properly.
        idleTurns = 0
        stateLock.unlock()
    }

    /// The pace to use when not in a burst: `period`, doubling each time bluetoothd is found
    /// without the audio device, up to half a minute.
    ///
    /// The doubling is bounded at both ends on purpose. Below, `period` is what the confirmation
    /// needs; above, thirty seconds is still fast enough to catch a device that comes back, and
    /// slow enough that a stream which owns the link for an hour costs 120 messages instead of
    /// 3600. Synchronous for the same reason as `restartBurst`.
    private func slowPeriod() -> TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !confirmed else { return period }
        return min(period * pow(2, Double(idleTurns)), 30)
    }

    /// Whether the next attempt should come fast, and spends one from the burst. Synchronous for
    /// the same reason as `restartBurst`.
    private func shouldAskFast() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !(checked && confirmed), fastAttemptsLeft > 0 else { return false }
        fastAttemptsLeft -= 1
        return true
    }

    /// Watches bluetoothd's log for the audio device, at the pace the log can afford.
    ///
    /// Repeating the message is the mechanism, not a workaround: the takeover makes bluetoothd
    /// unpublish its audio device for the headphones (`Closing media channel` → `Erased … -tacl`),
    /// and it republishes it about 14 s later. Until it does, every message is answered
    /// `No device found for uid` and does nothing — so the only way to be sure the link quality
    /// mode is on is to keep asking and to *notice when the answer changes*.
    ///
    /// Re-checking on every attempt was the previous version, and it made the keeper slower than
    /// the thing it was watching. It also confirmed only once, so when bluetoothd erased the
    /// device again — which it does whenever the media channel is reopened, and it happened seven
    /// times in one 45 s session — the keeper kept sending into nothing and the link fell back to
    /// `at most 3 packet(s) per drain` for the ~14 s it takes bluetoothd to republish.
    private func watchRegistration() {
        while !Task.isCancelled {
            let registered = self.deviceIsRegistered()
            stateLock.lock()
            let changed = registered != confirmed
            confirmed = registered
            checked = true
            let count = attempts
            idleTurns = registered ? 0 : idleTurns + 1
            stateLock.unlock()
            if changed {
                if registered {
                    self.log(
                        "link quality mode on: bluetoothd has the audio device again "
                            + "after \(count) attempt(s)")
                } else {
                    // Not "lost": bluetoothd erases its *audio device* whenever the media channel
                    // is reopened, and with the stream running it may never republish it — while
                    // the link quality mode, which is a setting on the ACL connection, stays on.
                    // Measured 2026-11-08: erased at 19:18:10 and never back, with the stream at
                    // 336 kbps and 62 packets/s and no stall at all. Saying "lost" there accused
                    // the link of a fault it did not have, which is the same mistake the
                    // `link_quality` field made before it was read from the socket.
                    self.log(
                        "link quality mode: bluetoothd erased its audio device (it does that "
                            + "when the media channel is reopened); still asking, slowly, in case "
                            + "it comes back")
                }
            }
            // A registration is a rare event and the log is read from an archive: two seconds is
            // already finer than the 14 s it takes bluetoothd to republish.
            Thread.sleep(forTimeInterval: max(2, self.period))
        }
    }

    /// Whether bluetoothd currently has an audio device for these headphones. Read from its own
    /// log, which is the only place that says so: the device is created and destroyed there.
    private func deviceIsRegistered() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            // Two minutes, not thirty seconds: the device is registered once when the headphones
            // connect, and that line can be long past by the time we start. A short window found
            // nothing and the keeper never confirmed — while the link quality mode was in fact
            // on, which is worse than not reporting at all. Five minutes was the previous value
            // and costs the same as thirty seconds; two is enough for a device that has just been
            // connected and cheaper to read.
            "show", "--last", "2m", "--predicate", "process == \"bluetoothd\"",
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
