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
    /// The `log stream` process, kept so `stop()` can end it instead of leaving it running.
    private var follower: Process?
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
            // Measured 2026-11-08 and again 2026-11-09: asking the archive costs 0.8–1.1 s on this
            // Mac whatever the window (`--last 30s` and `--last 30m` are the same price: it is the
            // process and the archive, not the lines). With the check on every attempt the keeper
            // loop ran at 1.9 s instead of the 1 s it asks for, and each turn spent most of its
            // life blocked in a pipe while the audio thread was the one that needed the CPU. So the
            // check runs on its own task and the sending never waits for it — and since 2026-11-09
            // it does not poll at all: it follows the log. See `watchRegistration`.
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

    /// Watches bluetoothd's log for the audio device, by *following* it instead of re-reading it.
    ///
    /// The previous version ran `log show --last 2m` every two seconds. Two things were wrong with
    /// that, and the second one is the bug this replaces:
    ///
    /// * It cost 0.8 s of a shell-out per call (measured 2026-11-09, five runs, 0.79–0.86 s), on a
    ///   two-second period: **40% of a core for the whole life of every stream**, spent in a pipe
    ///   while the audio thread needed the CPU. The first version of this comment already knew
    ///   that and moved the check off the sending path; it did not ask whether the check needed to
    ///   exist at all.
    /// * A two-minute sliding window forgets. bluetoothd registers the audio device once, when the
    ///   headphones connect, and then says nothing for as long as the stream runs. Two minutes
    ///   later the window is empty, `hasRegisteredDevice` finds no line and returns false, and the
    ///   keeper concludes the device is gone — while nothing has happened. Measured 2026-11-09:
    ///   the 2-minute window contained **zero** `Register`/`Erased` lines, the 60-minute window
    ///   contained 48. So the answer flipped from true to false purely with the passage of time,
    ///   which is why the link quality mode looked like it kept being lost.
    ///
    /// `log stream` is the right instrument: it delivers the lines as they are written, so there is
    /// no window to slide and no polling to pay for. The state is seeded once from the archive
    /// (one `log show`, once per stream) and then updated by events.
    private func watchRegistration() {
        // Seed from the archive: the registration may be hours old, and the stream would otherwise
        // start out not knowing. One call, once, off the audio path.
        let seeded = Self.hasRegisteredDevice(archiveLog(), uid: uid)
        stateLock.lock()
        confirmed = seeded
        checked = true
        if !seeded { idleTurns += 1 }
        stateLock.unlock()
        if seeded { log("link quality mode: bluetoothd already has the audio device") }

        // Then follow. A stream that dies is restarted: it is the only source of truth about a
        // device bluetoothd creates and destroys, and a silent watcher would be worse than a slow
        // one.
        while !Task.isCancelled {
            followLog()
            guard !Task.isCancelled else { break }
            log("link quality mode: the log follower stopped; restarting it")
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// Runs `log stream` and updates the state from each line, until cancelled or the process dies.
    private func followLog() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--predicate", "process == \"bluetoothd\"", "--style", "compact",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        follower = process
        defer {
            process.terminate()
            follower = nil
        }
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while !Task.isCancelled {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            // Whole lines only: a chunk can end in the middle of one, and half a line that happens
            // to contain "Erased" would be read as an erase.
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                apply(line)
            }
        }
    }

    /// Applies one log line to the state, and reports a change.
    private func apply(_ line: String) {
        stateLock.lock()
        var registered = confirmed
        stateLock.unlock()
        let before = registered
        Self.apply(line, uid: uid, to: &registered)
        guard registered != before else { return }
        stateLock.lock()
        confirmed = registered
        checked = true
        let count = attempts
        idleTurns = registered ? 0 : idleTurns + 1
        stateLock.unlock()
        if registered {
            log(
                "link quality mode on: bluetoothd has the audio device again "
                    + "after \(count) attempt(s)")
        } else {
            // Not "lost": bluetoothd erases its *audio device* whenever the media channel is
            // reopened, and with the stream running it may never republish it — while the link
            // quality mode, which is a setting on the ACL connection, stays on. Measured
            // 2026-11-08: erased at 19:18:10 and never back, with the stream at 336 kbps and 62
            // packets/s and no stall at all. Saying "lost" there accused the link of a fault it
            // did not have, which is the same mistake the `link_quality` field made before it was
            // read from the socket.
            log(
                "link quality mode: bluetoothd erased its audio device (it does that when the "
                    + "media channel is reopened); still asking, slowly, in case it comes back")
        }
    }

    /// One `log show` over a window wide enough to contain a registration that happened hours ago.
    ///
    /// Thirty minutes, not two: the device is registered once when the headphones connect and the
    /// keeper can start long after that. The cost is paid once per stream, not once per two
    /// seconds, which is what makes a wide window affordable.
    private func archiveLog() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "30m", "--predicate", "process == \"bluetoothd\"",
            "--style", "compact",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The rule, exposed for the self-test: the last thing bluetoothd said about our uid decides.
    /// `Register audio device …-tacl` means it is there; `Erased 1 audio device …-tacl` means it
    /// is not. Later lines win, because the device can come and go.
    ///
    /// Matched on the address, not on `uid`: the suffix is not guaranteed to be `-tacl` for every
    /// pair of headphones, and a device that reports a different one would otherwise never be
    /// seen as registered.
    public static func hasRegisteredDevice(_ log: String, uid: String) -> Bool {
        var registered = false
        for line in log.split(separator: "\n") {
            apply(String(line), uid: uid, to: &registered)
        }
        return registered
    }

    /// The same rule, one line at a time, so that a *followed* log and a *re-read* one cannot
    /// disagree. The follower needs it per line; the seed needs it over a whole archive.
    ///
    /// Matched on the address, not on `uid`: the suffix is not guaranteed to be `-tacl` for every
    /// pair of headphones, and a device that reports a different one would otherwise never be seen
    /// as registered. The address is the part before the transport suffix, split on `-t` and not
    /// on `-`, because the address is full of hyphens in the dashed CoreAudio spelling.
    public static func apply(_ line: String, uid: String, to registered: inout Bool) {
        let address = uid.components(separatedBy: "-t").first ?? uid
        guard line.contains(address) else { return }
        if line.contains("Register audio device") { registered = true }
        if line.contains("Erased") && line.contains("audio device") { registered = false }
    }

    public func stop() {
        task?.cancel()
        task = nil
        // The follower is a child process reading a pipe: cancelling the task does not end it, and
        // a `log stream` left behind would keep a core busy for as long as the Mac is on.
        follower?.terminate()
        follower = nil
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
