// codecblue: command-line companion of the CodecBlue app.
//
//   codecblue version            Show component versions.
//   codecblue lookup ADDRESS     What bluetoothd knows about the headphones (read-only).
//   codecblue probe ADDRESS      Take the headphones over briefly, list the codecs they
//                                declare, then hand them back to macOS.
//   codecblue link ADDRESS       Time the link with the headphones idle (sniff or active?).
//   codecblue release ADDRESS    Recovery: drop the headphones' link and let macOS reconnect
//                                them normally.
//   codecblue play ADDRESS [FILE.wav] [--quality HQ|SQ|LQ|0-4] [--queue-ms 150]
//                                [--media-priority 0]
//                                Stream a WAV file (or a test tone) in LDAC, then hand the
//                                headphones back. Ctrl-C stops early and hands them back too.
//                                --queue-ms bounds how much audio may wait for the link;
//                                --media-priority is passed to bluetoothd for the media channel;
//                                --media-mtu sets the L2CAP MTU used for media packets (679 by
//                                default, so the controller can use 2-DH5; 0 = the link's MTU);
//                                --sndbuf-packets how many packets may wait in the socket (1,
//                                the safe default: bluetoothd turns each read into one SDU);
//                                --no-hfp / --no-avrcp leave those channels to nobody, to see
//                                whether holding them costs the media link throughput;
//                                --low-latency asks bluetoothd to keep the link out of sniff.
//                                --keep-link-quality asks it to keep the link in A2DP Link
//                                Quality Mode, which is what actually raises the throughput.
//                                --adapt lets the quality follow the link instead of staying
//                                where it started.
import CodecBlueCore
import Foundation

let start = Date()

/// Stops the stream when this process is asked to stop, politely, whichever way it is asked.
///
/// Two signals mean the same thing and arrive from different places:
///
///   SIGINT   Ctrl-C in a terminal.
///   SIGTERM  `launchctl unload`, a logout, a reboot, `kill`. This is the one that matters and the
///            one that was missing: the agent is owned by launchd, so *every* ordinary way of
///            stopping it — the menu's Stop, a reboot, `launchctl unload` — arrives as SIGTERM.
///            Unhandled, the process dies where it stands and the headphones stay taken: macOS
///            never gets them back, and the only cure is putting them in the case for a few
///            seconds. Measured 2026-11-09: a stream stopped from the menu left the FreeBuds
///            unreachable until they were re-cradled.
///
/// The handler only *asks* the stream to stop. The teardown that hands the headphones back is the
/// normal path at the end of `play`/`playSystem`, which is already written and already tested —
/// doing the hand-back inside a signal handler would mean doing async work in a context where the
/// runtime is going away underneath it.
///
/// A second signal is ignored rather than acted on: the first one started a teardown that takes a
/// few seconds (the link has to drop and macOS has to reconnect), and a user pressing Ctrl-C twice
/// means "hurry up", not "abandon the hand-back".
final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false
    private var handler: (@Sendable () -> Void)?
    private var sources: [DispatchSourceSignal] = []

    /// Starts listening on both signals, once for the life of the process.
    ///
    /// Separated from `route` because a process can outlive a stream: `system` hands the
    /// headphones back for the duration of a phone call and starts again afterwards, and a Ctrl-C
    /// pressed during that gap used to be swallowed — the session's `StopRequest` was the only
    /// listener and it had just been deallocated. Measured 2026-11-09: `kill -INT` during a call
    /// did nothing at all and the process kept streaming after it.
    func listen() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [weak self] in self?.request(reason: signalNumber) }
            source.resume()
            // Held, or the source is deallocated and the signal goes back to killing the process.
            sources.append(source)
        }
    }

    /// Sends the next stop to this closure. Replaces any previous one: there is one stream at a
    /// time, and the newest one is the one worth stopping.
    ///
    /// If a stop was already asked for, the closure is called at once. Without this the request
    /// fell into the gap between the signal and the session that was about to start: `request`
    /// had already run, so it reported "already stopping" and never called the *new* handler, and
    /// the session started anyway. Measured 2026-11-09, twice.
    func route(to onStop: @escaping @Sendable () -> Void) {
        let alreadyAsked = lock.withLock { () -> Bool in
            handler = onStop
            return asked
        }
        if alreadyAsked { onStop() }
    }

    /// Whether a stop has already been asked for. A session that starts after the user pressed
    /// Ctrl-C must not start at all.
    var wasAsked: Bool { lock.withLock { asked } }

    private func request(reason: Int32) {
        lock.lock()
        let alreadyAsked = asked
        asked = true
        let handler = self.handler
        lock.unlock()
        guard !alreadyAsked else {
            log("already stopping: the headphones are being handed back, this takes a few seconds")
            return
        }
        log(reason == SIGTERM ? "asked to stop (SIGTERM): stopping" : "interrupted: stopping")
        handler?()
    }
}

@Sendable func log(_ message: String) {
    let t = Date().timeIntervalSince(start)
    FileHandle.standardError.write(Data(String(format: "[%7.3f] %@\n", t, message).utf8))
}

func usage() -> Never {
    FileHandle.standardError.write(
        Data(
            """
            usage: codecblue version
                   codecblue lookup XX:XX:XX:XX:XX:XX
                   codecblue probe  XX:XX:XX:XX:XX:XX
                   codecblue play   XX:XX:XX:XX:XX:XX [FILE.wav] [--quality HQ|SQ|LQ|0-4] [--queue-ms N]
                                    [--media-priority N] [--media-mtu N|0] [--sndbuf-packets N]
                                    [--no-hfp] [--no-avrcp] [--low-latency] [--keep-link-quality] [--adapt] [--gain X]
                   codecblue system  XX:XX:XX:XX:XX:XX [--quality HQ|SQ|LQ|0-4] [--queue-ms N]
                                    (plays the CodecBlue virtual device)
                   codecblue rate    44100|48000|88200|96000  (the virtual device's rate)
                   codecblue devices                      (the headphones macOS knows about)
                   codecblue status                       (ask a running stream what it is doing)
                   codecblue quality HQ|SQ|LQ|0-4         (the ceiling, while it plays)
                   codecblue adapt   on|off               (let it choose the level itself)
                   codecblue cushion 40                   (the cushion, in ms — this is the latency)
                   codecblue levels                       (the whole ladder, and what fits here)
                   codecblue compare                      (this link against the Mac's own AAC)
                   codecblue link    XX:XX:XX:XX:XX:XX
                   codecblue tone    FILE.wav [SECONDS] [--sweep]  (a constant sine, or a sweep)
                   codecblue flood   XX:XX:XX:XX:XX:XX [SECONDS] [BYTES] [--keep-link-quality]
                   codecblue pace    XX:XX:XX:XX:XX:XX [SEC] [BYTES] [PKT/S] (diagnostic: paced rate)
                   codecblue handlers device|general  (which handler answers each known message)
                   codecblue agent   install|remove|status [ADDR] [options]
                   codecblue audioprobe ADDR   (sends one known message; needs CODECBLUE_AUDIO_CHANNEL=yes)
                   codecblue start  [ADDR] [options]      (stream now, and at login — no menu bar)
                   codecblue login  on|off|status         (whether the stream starts at login)
                   codecblue stop                         (stop the stream and the agent)
                   codecblue release XX:XX:XX:XX:XX:XX

            """.utf8))
    exit(2)
}

func lookup(_ address: String) async throws {
    let session = ClassicXPCSession(label: "lookup")
    try await session.start()
    defer { session.invalidate() }
    let record = try await session.lookup(address: address)
    print(record)
    print(
        "link: \(record.isLinkUp ? "up" : "down"), macOS audio device: \(SystemHeadphoneAudio.hasDevice(address: address) ? "yes" : "no")"
    )
}

func probe(_ address: String) async throws {
    let takeover = HeadsetTakeover(address: address, log: log)
    do {
        let signaling = try await takeover.grabSignaling()
        let discover = try await signaling.command(.discover)
        let endpoints = AVDTP.parseDiscover(discover.payload)
        print("\(endpoints.count) stream endpoint(s):")
        for endpoint in endpoints {
            var line = "  SEID \(endpoint.seid) \(endpoint.isSink ? "sink" : "source")"
            line += endpoint.mediaType == 0 ? " audio" : " media \(endpoint.mediaType)"
            if endpoint.inUse { line += " (in use)" }
            if let caps = try? await signaling.command(.getCapabilities, Data([endpoint.seid << 2]))
            {
                let parsed = AVDTP.parseCapabilities(caps.payload)
                line += ": " + (parsed.codec?.description ?? "no codec capability")
            } else {
                line += ": capabilities unavailable"
            }
            print(line)
        }
    } catch {
        log("probe failed: \(error)")
        await takeover.handBack()
        throw error
    }
    log("handing the headphones back to macOS")
    await takeover.handBack()
}

/// Measures the link with the headphones idle: the AVRCP round trip tells whether the
/// controller keeps the link active (a few ms) or lets it go to sniff (tens of ms or more).
func link(_ address: String) async throws {
    let takeover = HeadsetTakeover(address: address, log: log)
    do {
        let signaling = try await takeover.grabSignaling()
        // AVDTP first: DISCOVER is harmless and answered by the same ACL link, so its round
        // trip separates "the link is slow" from "the headphones answer AVRCP slowly".
        var avdtp: [Double] = []
        for _ in 0..<10 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try await signaling.command(.discover, timeout: 3)
            avdtp.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
        }
        let avdtpSorted = avdtp.sorted()
        log(
            String(
                format: "AVDTP round trip: min %.1f ms, median %.1f ms, max %.1f ms",
                avdtpSorted[0] * 1000, avdtpSorted[avdtpSorted.count / 2] * 1000,
                avdtpSorted[avdtpSorted.count - 1] * 1000))
        // One round trip per packet is what the media channel gets: with a link that answers
        // in ~100 ms, a 679-byte packet per round trip is ~54 kbps. That is the ceiling we
        // measure, and it comes from the link's latency, not from the codec or the bandwidth.
        let median = avdtpSorted[avdtpSorted.count / 2]
        log(
            String(
                format: "one packet per round trip would be %.0f kbps (679 bytes / %.0f ms)",
                679.0 * 8 / median / 1000, median * 1000))

        let channel = try await takeover.openChannel(
            psm: AVCTPHolder.psm, label: "avrcp", timeout: 3)
        let holder = AVCTPHolder(socket: ChannelSocket(channel: channel, label: "avrcp"))
        log("AVRCP held; measuring the idle link for 3 s")
        var samples: [Double] = []
        for _ in 0..<12 {
            holder.measureRoundTrip()
            try await Task.sleep(for: .milliseconds(250))
            if let rtt = holder.roundTrip { samples.append(rtt) }
        }
        holder.close()
        guard !samples.isEmpty else {
            log("the headphones did not answer AVRCP")
            await takeover.handBack()
            return
        }
        let sorted = samples.sorted()
        log(
            String(
                format: "idle round trip: min %.0f ms, median %.0f ms, max %.0f ms (%d samples)",
                sorted[0] * 1000, sorted[sorted.count / 2] * 1000, sorted[sorted.count - 1] * 1000,
                sorted.count))
    } catch {
        log("link failed: \(error)")
        await takeover.handBack()
        throw error
    }
    log("handing the headphones back to macOS")
    await takeover.handBack()
}

func play(_ address: String, _ options: [String]) async throws {
    var rung = 0
    var file: String?
    var queueDuration = 0.15
    var mediaPriority: Int64 = 0
    var mediaMTU: Int? = 679
    var sendBufferPackets = 1
    var lowLatency = false
    var keepLinkQuality = false
    var adaptBitrate = false
    var gain: Float = 1
    var holdHandsFree = true
    var holdAVRCP = true
    var rest = options[...]
    while let option = rest.popFirst() {
        switch option {
        case "--quality":
            guard let value = rest.popFirst(), let parsed = LDACEncoder.rung(from: value)
            else { usage() }
            rung = parsed
        case "--queue-ms":
            guard let value = rest.popFirst(), let ms = Double(value), ms >= 20, ms <= 2000 else {
                usage()
            }
            queueDuration = ms / 1000
        case "--media-priority":
            guard let value = rest.popFirst(), let priority = Int64(value), priority >= 0 else {
                usage()
            }
            mediaPriority = priority
        case "--sndbuf-packets":
            guard let value = rest.popFirst(), let packets = Int(value), (1...16).contains(packets)
            else { usage() }
            sendBufferPackets = packets
        case "--low-latency":
            lowLatency = true
        case "--keep-link-quality":
            keepLinkQuality = true
        case "--adapt":
            adaptBitrate = true
        case "--gain":
            guard let value = rest.popFirst(), let g = Double(value), g > 0, g <= 4 else { usage() }
            gain = Float(g)
        case "--no-hfp":
            holdHandsFree = false
        case "--no-avrcp":
            holdAVRCP = false
        case "--media-mtu":
            guard let value = rest.popFirst(), let mtu = Int(value),
                mtu == 0 || (LDACEncoder.minimumMTU...2000).contains(mtu)
            else { usage() }
            mediaMTU = mtu == 0 ? nil : mtu
        default:
            file = option
        }
    }
    var audio = try file.map { try WAVFile(contentsOf: URL(fileURLWithPath: $0)) } ?? WAVFile.sine()
    if gain != 1 {
        // A pure tone at full scale is painfully loud and there is no volume control anywhere
        // in the path: the PCM goes from the file to the encoder untouched.
        audio = audio.scaled(by: gain)
        log(String(format: "gain: %.2fx", gain))
    }
    log(
        String(format: "%@: %.1f s at %d Hz", file ?? "test tone", audio.duration, audio.sampleRate)
    )
    let mtuText = mediaMTU.map { "\($0)" } ?? "link"
    log(
        "media: MTU \(mtuText), \(sendBufferPackets) packet(s) in the socket, priority \(mediaPriority), queue \(Int(queueDuration * 1000)) ms"
    )

    var keeper: AudioStreamKeeper?
    if keepLinkQuality {
        // Must happen before the takeover: once we own the media channel bluetoothd unpublishes
        // the audio device and answers our messages with "No device found for uid".
        //
        // Two ways of asking, and the second is the true one: `findRegistered` reads the UUID off
        // the audio device bluetoothd says it has registered *for this address*, while
        // `find` takes the last `CBDevice` line with A2DP in it, which may belong to another pair
        // of headphones entirely. The first is kept as a fallback because the registration line
        // only exists once bluetoothd has published a device, and a pair that has just connected
        // may not have one yet.
        if let uuid = CBDeviceUUID.resolve(for: address).best {
            keeper = AudioStreamKeeper(address: address, deviceUUID: uuid, period: 1, log: log)
            keeper?.start()
            log("asking bluetoothd for A2DP Link Quality Mode before taking the link (\(uuid))")
            try await Task.sleep(for: .seconds(3))
        } else {
            log("cannot find bluetoothd's UUID for this device: link quality mode stays off")
        }
    }
    let takeover = HeadsetTakeover(address: address, log: log)
    takeover.lowLatency = lowLatency
    let streamerBox = StreamerBox()
    // Ctrl-C, or SIGTERM from launchd: stop streaming; the normal path below then hands the
    // headphones back.
    // Held for the life of the function: it owns the signal sources, and a source that is
    // deallocated takes the handler with it.
    let stopRequest = StopRequest()
    stopRequest.listen()
    stopRequest.route {
        streamerBox.streamer?.stop()
        streamerBox.interrupted = true
    }

    do {
        let signaling = try await takeover.grabSignaling()
        if lowLatency, !takeover.requestHighPriority() {
            log(
                "this macOS release does not expose the ACL-priority request; the link may stay in sniff"
            )
        }
        let streamer = A2DPStreamer(takeover: takeover, signaling: signaling, log: log)
        streamer.queueDuration = queueDuration
        streamer.mediaPriority = mediaPriority
        streamer.mediaMTU = mediaMTU
        streamer.sendBufferPackets = sendBufferPackets
        streamer.adaptBitrate = adaptBitrate
        streamer.holdHandsFree = holdHandsFree
        streamer.holdAVRCP = holdAVRCP
        streamerBox.streamer = streamer
        if !streamerBox.interrupted {
            let configuration = try await streamer.setUp(sampleRate: audio.sampleRate, rung: rung)
            log("playing in LDAC \(configuration.rungName)")
            let samples = audio.samples
            try await Task.detached(priority: .high) { try streamer.play(samples) }.value
        }
        await streamer.tearDown()
    } catch {
        log("play failed: \(error)")
        await streamerBox.streamer?.tearDown()
        await takeover.handBack()
        throw error
    }
    keeper?.stop()
    log("handing the headphones back to macOS")
    await takeover.handBack()
    exit(0)  // the signal source for Ctrl-C would keep the process alive
}

/// The message numbers this program has seen bluetoothd answer, taken from the log of a working
/// call and from the strings in its binary. Nothing outside this list may be sent.
///
/// This list is the whole point. Two probes that could send *any* number (`xpcscan`,
/// `generalscan`) crashed bluetoothd five times out of five on 2026-11-06 — four `EXC_BREAKPOINT`
/// from `CFRelease(NULL)` and one ObjC exception in `CFBooleanGetValue` — because a message
/// bluetoothd does not expect, with an argument shape it does not expect, is not a question it
/// answers: it is a case it does not handle. The rule, written in the notes and now enforced
/// here: **a probe that talks to a system process must not be able to send arbitrary messages.**
///
/// Read enums from the log of a working call; never guess them against a live daemon.
/// Asks bluetoothd to name the handlers for the messages we already know it accepts.
///
/// This replaces `xpcscan`/`generalscan`, which sent every number in a range. It can only send
/// numbers from `KnownMessage`, so it cannot reach a case bluetoothd does not handle. It is kept
/// because the mapping from number to handler is genuinely useful documentation, and because
/// having the safe version in the code is what stops someone writing the unsafe one again.
func handlers(_ table: String) async throws {
    let isGeneral = table == "general"
    let known = isGeneral ? KnownMessage.general : KnownMessage.device
    let session = ClassicXPCSession(
        label: "handlers",
        service: isGeneral ? XPCProtocol.generalServiceName : nil)
    try await session.start()
    defer { session.invalidate() }
    log("asking about \(known.count) known message(s) on the \(table) service")
    for (id, name) in known.sorted(by: { $0.key < $1.key }) {
        // A device UUID that matches nothing: bluetoothd drops the message before touching any
        // real device, which is the safest shape available for a device-level message.
        session.probe(id, device: UUID())
        print(String(format: "%4lld  %@", id, name))
        try await Task.sleep(for: .milliseconds(120))
    }
    log("done; bluetoothd's log names the handler it actually reached for each")
}

/// Diagnostic: floods the media channel with packets as fast as bluetoothd takes them, at a
/// fixed size, to see whether the ceiling is per packet or in bytes.
func pace(_ address: String, seconds: Double, packetSize: Int, rate: Double) async throws {
    let takeover = HeadsetTakeover(address: address, log: log)
    let box = StreamerBox()
    let signaling = try await takeover.grabSignaling()
    let streamer = A2DPStreamer(takeover: takeover, signaling: signaling, log: log)
    box.streamer = streamer
    _ = try await streamer.setUp(sampleRate: 48000, rung: 4)
    streamer.pace(seconds: seconds, packetSize: packetSize, packetsPerSecond: rate)
    await streamer.tearDown()
    log("handing the headphones back to macOS")
    await takeover.handBack()
}

func flood(
    _ address: String, seconds: Double, packetSize: Int, keepLinkQuality: Bool = false,
    uidSuffix: String = "tacl"
) async throws {
    // The link quality mode is a controller setting on the ACL connection, and our takeover
    // keeps that connection: so it is worth turning it on *before* taking the link, while
    // bluetoothd still has the audio device published. Once we own the media channel
    // bluetoothd unpublishes the device and refuses our messages with "No device found".
    var keeper: AudioStreamKeeper?
    if keepLinkQuality, let uuid = CBDeviceUUID.resolve(for: address).best {
        keeper = AudioStreamKeeper(
            address: address, deviceUUID: uuid, period: 1,
            uidSuffix: uidSuffix, log: log)
        keeper?.start()
        log(
            "asking bluetoothd for A2DP Link Quality Mode before taking the link (\(uuid), uid -\(uidSuffix))"
        )
        try await Task.sleep(for: .seconds(3))
    } else if keepLinkQuality {
        log("cannot find bluetoothd's UUID for this device: link quality mode stays off")
    }
    defer { keeper?.stop() }
    let takeover = HeadsetTakeover(address: address, log: log)
    let box = StreamerBox()
    let signaling = try await takeover.grabSignaling()
    let streamer = A2DPStreamer(takeover: takeover, signaling: signaling, log: log)
    box.streamer = streamer
    _ = try await streamer.setUp(sampleRate: 48000, rung: 4)
    streamer.flood(seconds: seconds, packetSize: packetSize)
    await streamer.tearDown()
    log("handing the headphones back to macOS")
    await takeover.handBack()
}

/// Plays what the virtual device receives: reads the shared ring the driver fills and streams it
/// to the headphones. This is the whole point of the driver — any app that selects "CodecBlue"
/// as its output ends up here.
/// One streaming session: take the headphones, play until something stops it, hand them back.
///
/// Returns true when the reason it stopped was a phone call — the caller then waits for the call
/// to finish and starts another session. Everything else (Ctrl-C, `codecblue stop`, a dead link)
/// ends the process.
func playSystemOnce(
    _ address: String, options: [String], monitor: CallMonitor?, stopRequest: StopRequest
) async throws -> Bool {
    // Be the system output for the duration of the session, and give it back afterwards.
    //
    // Around the session rather than inside it, so that the restore happens on every way out —
    // including the early returns — without repeating it at each one. And per session rather than
    // per process: during a call the headphones are macOS's, so macOS should have the output too.
    // Tell the driver that someone can feed it, so it stops hiding the device — *before* asking to
    // be the output, because a hidden device is not eligible as the default and the driver only
    // notices the flag on its own half-second poll. Order is the whole fix here; measured
    // 2026-11-09, the other order set the output on a device the system was about to hide.
    //
    // Best effort: without the ring there is no stream anyway, and `playSystemSession` says so.
    let ringForFeeding = try? SharedRing()
    ringForFeeding?.feeding = true
    defer { ringForFeeding?.feeding = false }
    let previousOutput = DefaultOutput.takeOver()
    if let previousOutput {
        log("system output: CodecBlue (was \(previousOutput.name))")
    } else {
        log(
            "system output: not changed — either CodecBlue is not installed or it already was the "
                + "output. If apps play and you hear nothing, select CodecBlue as the output.")
    }
    let interruptedByCall = try await playSystemSession(
        address, options: options, monitor: monitor, stopRequest: stopRequest)
    switch await DefaultOutput.giveBack(previousOutput) {
    case .restored(let name):
        DefaultOutput.forget()
        log("system output: back to \(name)")
    case .leftAlone(let name):
        DefaultOutput.forget()
        log("system output: left on \(name) — you chose it")
    case .gone(let name):
        log("system output: \(name) did not come back; leaving CodecBlue selected")
    case .nothingToDo:
        DefaultOutput.forget()
    }
    return interruptedByCall
}

/// One streaming session, without touching the system output: see `playSystemOnce`.
func playSystemSession(
    _ address: String, options: [String], monitor: CallMonitor?, stopRequest: StopRequest
) async throws -> Bool {
    var rung = 4
    var keepLinkQuality = true
    var adapt = true
    // The cushion is learned, not chosen: PacketQueue.noteStall/relax start it at 80 ms — where a
    // good link stays — and widen it only if a stall proves it needs the room. A fixed 250 ms was
    // the worst case paid all the time; this pays it only when the link asks.
    var queueDuration = 0.06
    // The socket buffer is one MTU by default, so a packet waits for bluetoothd to drain it
    // before the next can be handed over. Measured stalls of 100-300 ms mean bluetoothd goes
    // quiet for that long; with one packet of room nothing can be buffered meanwhile.
    var sendBufferPackets = 1
    // Clock drift between the Mac and the headphones, corrected by resampling. See
    // A2DPStreamer.driftPPM: without it the sound drifts behind the picture by about 60 ms every
    // ten minutes, because the two crystals differ and the headphones never report their delay.
    // The sign is known from the symptom (audio falling behind = they are slower than us), so
    // the default is a fixed 100 ppm rather than something to be discovered at run time.
    // Default 0: the measured cause of "the sound falls behind the video" was the ring holding
    // a backlog after a stall (1984 → 13 504 frames, never coming back), which `drainBoost`
    // fixes. A standing bias on top of that would slowly empty the headphones' buffer for no
    // measured reason. The option stays for the case where the ring is proven healthy and the
    // delay still grows.
    var driftPPM = 0.0
    // How the headphones go back to macOS when the stream ends.
    var handBackStyle: HeadsetTakeover.HandBackStyle = .reconnect
    var handBackWait = 3.0
    var rest = options[...]
    while let option = rest.popFirst() {
        switch option {
        case "--quality":
            guard let value = rest.popFirst(), let parsed = LDACEncoder.rung(from: value)
            else { usage() }
            rung = parsed
        case "--queue-ms":
            guard let value = rest.popFirst(), let ms = Double(value), ms >= 20, ms <= 2000 else {
                usage()
            }
            queueDuration = ms / 1000
        case "--sndbuf-packets":
            guard let value = rest.popFirst(), let packets = Int(value), packets >= 1, packets <= 64
            else { usage() }
            sendBufferPackets = packets
        case "--keep-link-quality": keepLinkQuality = true
        case "--no-keep-link-quality": keepLinkQuality = false
        case "--adapt": adapt = true
        case "--no-adapt": adapt = false
        case "--drift-ppm":
            guard let value = rest.popFirst(), let ppm = Double(value), abs(ppm) <= 2000 else {
                usage()
            }
            driftPPM = ppm
        case "--hand-back":
            guard let value = rest.popFirst(),
                let parsed = HeadsetTakeover.HandBackStyle.named(value)
            else { usage() }
            handBackStyle = parsed
        case "--hand-back-wait":
            guard let value = rest.popFirst(), let seconds = Double(value), seconds > 0,
                seconds <= 30
            else { usage() }
            handBackWait = seconds
        case "--no-call-monitor":
            // Handled by the caller, which decides whether to create the monitor at all. Accepted
            // here so that the option is not a usage error when the session is started directly.
            break
        default: usage()
        }
    }
    // Ask for the Bluetooth permission from *this* process, before touching bluetoothd.
    //
    // `codecblue` uses bluetoothd's classic XPC channel, and that channel needs
    // `kTCCServiceBluetoothAlways` — but nothing in it ever asks for it. Only CoreBluetooth asks.
    // So the permission went to whatever launched us: from a terminal macOS asked on behalf of the
    // terminal and everything worked; from launchd nobody asked, bluetoothd found no approval and
    // answered "state updated: Unsupported", which reads as "this Mac has no Bluetooth". Measured
    // 2026-11-08: same binary, same arguments, `status: 2` / "On" from a terminal and `status: 1` /
    // "Unsupported" under launchd, four times each way.
    //
    // Creating a CBCentralManager here is the asking. It is not used for anything else.
    BluetoothAuthorization.request(log: log)

    let ring: SharedRing
    do {
        ring = try SharedRing()
    } catch {
        log("\(error)")
        log("install the driver first: scripts/build-driver.sh --install")
        return false
    }
    log(
        "ring: \(ring.sampleRate) Hz, \(ring.channelCount) channels, \(ring.available) frames waiting"
    )
    // Say it out loud when the device is selected but nothing is writing into it. Otherwise every
    // app plays into silence and nothing explains why — which cost real time once already.
    if ring.available == 0 {
        log(
            "the ring is empty: if apps are playing and you hear nothing, the device is selected "
                + "but nothing is feeding it. Check that this process is running "
                + "(`codecblue agent status`), then play something.")
    }
    // Be the system output, and remember what was there.
    //
    // The device is published by a HAL plug-in, so it is in the list whether or not anything feeds
    // it — and choosing it used to be a manual step (`scripts/setoutput.swift CodecBlue`) whose
    // failure mode is silence. Starting the stream is the moment the listener has said "use these
    // headphones", so it is the moment to become the output.
    // The volume's *curve* lives in the headphones now (see §13.44 of the notes); what is applied
    // in this process is the mute, as zeros. `SystemVolume` is still read here because it is the
    // only place that knows the slider position and whether the device is muted.
    let volume = SystemVolume()
    if let volume {
        // Say where the volume actually goes, because this line used to lie.
        //
        // It read `slider 33% -> gain 3.1% (applied before the encoder)`, and that is not what
        // happens: since §13.44 the curve lives in the headphones and the only thing multiplied
        // here is the mute (1 or 0). A log that claims an attenuation the code does not perform is
        // how the double-attenuation bug of §13.43 stayed invisible for an evening — the number
        // looked plausible in both the broken and the fixed version.
        log(
            String(
                format:
                    "volume: slider %.0f%% goes to the headphones; here only the mute is applied%@",
                volume.reported * 100, volume.isMuted ? " (muted: zeros)" : ""))
        // And what the headphones were actually told. It must be the slider: anything else is the
        // two-attenuations bug coming back.
        if let pushed = volume.lastPushed {
            log(String(format: "volume: the headphones are at %.0f%%", pushed * 100))
        }
    } else {
        log("volume: the CodecBlue device is not the system output, so there is no volume to read")
    }

    var keeper: AudioStreamKeeper?
    if keepLinkQuality {
        if let uuid = CBDeviceUUID.resolve(for: address).best {
            keeper = AudioStreamKeeper(address: address, deviceUUID: uuid, period: 1, log: log)
            keeper?.start()
            log("asking bluetoothd for A2DP Link Quality Mode before taking the link (\(uuid))")
            try await Task.sleep(for: .seconds(3))
        } else {
            // Say it, and say what it costs. Without the link quality mode the link carries ~50
            // kbps instead of ~500, and the listener hears crackle for a reason that is nowhere in
            // the audio path. This used to be a silent skip.
            log(
                "cannot find bluetoothd's UUID for this device: link quality mode stays off, "
                    + "so the link will carry ~50 kbps instead of ~500")
        }
    }
    defer { keeper?.stop() }

    let takeover = HeadsetTakeover(address: address, log: log)
    takeover.inPlaceWait = handBackWait
    let box = StreamerBox()
    stopRequest.route {
        box.streamer?.stop()
        box.interrupted = true
    }
    // A stop asked *before* this session existed still applies.
    //
    // Measured 2026-11-09: Ctrl-C during the gap of a phone call was routed to the session that
    // had just ended, and the next session started anyway — the process then streamed for another
    // six seconds after being told to stop, which is the worst possible moment to ignore it. The
    // signal and the session start are two threads; the check has to be on this side of the race.
    if stopRequest.wasAsked { box.interrupted = true }
    // A call takes the stream down the same way Ctrl-C does, but the process stays alive: the
    // headphones go back to macOS for the duration and are taken again afterwards.
    monitor?.onChange = { active in
        guard active else { return }
        box.callInterrupted = true
        box.streamer?.stop()
    }

    // The keeper needs the UUID, and the UUID is only in bluetoothd's log — which is written when
    // the headphones connect. `play` (and the agent) start with the headphones *off*, ask macOS to
    // connect them, and only then does that line exist: measured 2026-11-08, the lookup at t=3.9 s
    // found nothing, the whole stream ran at `at most 2 packet(s) per drain`, and the log said so
    // only once, at startup. So the lookup is repeated after the takeover, when the device is
    // certainly there, and the keeper starts then if it could not start before.
    func startKeeperIfPossible(because reason: String) {
        guard keepLinkQuality else { return }
        if let keeper {
            // Already running: ask again now rather than do nothing. This is the call that lands
            // in the window, and the window is what matters.
            keeper.askAgainNow(because: reason)
            return
        }
        guard let uuid = CBDeviceUUID.resolve(for: address).best else {
            log("link quality mode: still no UUID for this device (\(reason))")
            return
        }
        keeper = AudioStreamKeeper(address: address, deviceUUID: uuid, period: 1, log: log)
        keeper?.start()
        log("asking bluetoothd for A2DP Link Quality Mode (\(reason), \(uuid))")
    }

    // The window, hooked where it actually opens.
    //
    // `grabSignaling` waits for macOS to publish the headphones' audio device and *then* forces a
    // disconnect and takes the link. The moment it publishes is the only moment bluetoothd has a
    // `-tacl` device for `StartAudio` to land on, and it lasts until the takeover closes the media
    // channel — measured 2026-11-08: 721 ms. Asking from anywhere else is asking at the wrong
    // time, which is what "gracchia tanto" was: 65% of the audio dropped, LQM off.
    // A box, not a capture: the closure is `@Sendable` and the function is a local one, and the
    // keeper it needs may not exist yet — its UUID only appears in bluetoothd's log once the
    // device is published, which is the very moment this fires.
    let keeperBox = KeeperBox()
    keeperBox.set { reason in startKeeperIfPossible(because: reason) }
    takeover.onSystemConnected = { [keeperBox] in
        keeperBox.ask(because: "macOS has just published the audio device")
    }
    let signaling = try await takeover.grabSignaling()
    startKeeperIfPossible(because: "the headphones are connected now")
    let streamer = A2DPStreamer(takeover: takeover, signaling: signaling, log: log)
    streamer.queueDuration = queueDuration
    streamer.queueCeiling = queueDuration + 0.25
    streamer.driftPPM = driftPPM
    // The headphones' own volume buttons. They arrive as AVRCP PASS THROUGH, and until now they
    // were only written to the log — so pressing them did nothing, which is what the listener
    // reported. Three notches per press: one is too little to feel, and the headphones send one
    // event per press, not per repeat.
    // `let say = log` does not compile: Darwin's `log` (the maths one) is in scope too, so the
    // bare name is ambiguous. Naming the type resolves it.
    let say: @Sendable (String) -> Void = { message in log(message) }
    // The transport buttons need Accessibility permission to post a media key, and that
    // permission is granted to a *program*: asking from here would name the terminal. So the
    // asking is done by `codecblue-keys`, a separate binary that does nothing else — see
    // Sources/codecblue-keys/main.swift. If it was not built, the buttons stay unimplemented
    // rather than silently accepted.
    let mediaKeys = MediaKeyHelper(log: say)
    if mediaKeys == nil {
        say(
            "media keys: codecblue-keys not found next to this binary, so the headphones' "
                + "play/pause/next will be refused instead of accepted")
    }
    // A way to steer the stream while it runs. Without it the only way to change the quality is
    // to stop, edit the command line and start again — several seconds of silence, which defeats
    // the purpose of a setting you want to try while listening.
    let control = ControlServer { command in
        switch command.name {
        case "status":
            var lines = streamer.status?().map { "\($0.key)=\($0.value)" }.sorted() ?? []
            lines.append("end")
            return lines
        case "quality":
            // A name or a rung: `HQ` / `SQ` / `LQ` for the three Sony named, `0`…`4` for any rung
            // on the ladder. The two in the middle have no name and are the point of the whole
            // exercise — 492 kbps is what a 530 kbps link wants, and neither HQ nor SQ is it.
            guard let text = command.argument, let rung = LDACEncoder.rung(from: text)
            else { return ["error=quality must be HQ, SQ, LQ or a rung 0…4"] }
            // The rung is a ceiling, not an instruction to sit there: see `requestedRung`. The
            // listener asked for HQ because they want the best this link can do, not because they
            // want 45% of the audio thrown away when it cannot do it.
            streamer.requestedRung = rung
            let name = LDACEncoder.name(
                rung: rung,
                sampleRate: streamer.currentSampleRate ?? 48000)
            return ["ok quality=\(name)", "ceiling=\(name)", "rung=\(rung)"]
        case "levels":
            // What the ladder means on this link. The nominal bitrates are the codec's; the
            // verdict is the link's, measured. See `QualityLevels`.
            let status = streamer.status?() ?? [:]
            let capacity = Double(status["link_kbps"] ?? "") ?? 0
            let rate = Int(status["sample_rate"] ?? "") ?? 48000
            return QualityLevels.describe(capacityKbps: capacity, sampleRate: rate)
                .map { QualityLevels.label($0, capacityKbps: capacity) }
        case "cushion":
            // The cushion is the latency. Changing it while the audio plays is the only way to
            // answer "is 40 ms enough on this link?", which is a question only the listener can
            // answer.
            guard let text = command.argument, let milliseconds = Double(text),
                (10...500).contains(milliseconds)
            else { return ["error=cushion must be 10…500 (milliseconds)"] }
            streamer.requestedCushion = milliseconds / 1000
            return ["ok cushion=\(Int(milliseconds))ms"]
        case "adapt":
            switch command.argument?.lowercased() {
            case "on":
                streamer.adaptBitrate = true
                return ["ok adapt=on"]
            case "off":
                streamer.adaptBitrate = false
                return ["ok adapt=off"]
            default:
                return ["error=adapt must be on or off"]
            }
        case "quit":
            streamer.stop()
            return ["ok quitting"]
        default:
            return ["error=unknown command \(command.name)"]
        }
    }
    // What `codecblue status` reports. Read from the same places the log reads, so the two can
    // never disagree about what the stream is doing.
    streamer.status = { [ring, volume] in
        var out: [String: String] = [:]
        out["ring_frames"] = String(ring.available)
        out["ring_ms"] = String(
            format: "%.0f", Double(ring.available) / Double(ring.sampleRate) * 1000)
        // The rung that is playing, by the name Sony gave it where there is one and by its
        // bitrate where there is not: "492" is a real answer and neither HQ nor SQ.
        let rate = streamer.currentSampleRate ?? 48000
        out["quality"] =
            streamer.currentRung.map {
                LDACEncoder.name(rung: $0, sampleRate: rate)
            } ?? "unknown"
        out["quality_rung"] = streamer.currentRung.map(String.init) ?? "unknown"
        out["quality_kbps"] = streamer.currentBitrateKbps.map(String.init) ?? "unknown"
        out["sample_rate"] = String(streamer.currentSampleRate ?? 48000)
        out["adapt"] = streamer.adaptBitrate ? "on" : "off"
        out["battery"] = streamer.batteryPercent.map(String.init) ?? "unknown"
        out["volume"] = volume.map { String(format: "%.0f", $0.reported * 100) } ?? "unknown"
        out["skips"] = String(ring.skips)
        // The latency the listener actually gets: the cushion (audio held between driver and
        // socket) plus the queue in flight. Reporting only the cushion would understate it by the
        // packets already committed, which is where the extra milliseconds hide.
        out["cushion_ms"] = String(format: "%.0f", streamer.currentCushion * 1000)
        // The volume as the two places that matter see it: the slider the system shows, and what
        // the headphones were last told. When these disagree the listener hears one of them and
        // moves the other, which is the whole class of bug this area keeps producing.
        out["slider"] = String(format: "%.0f", (volume?.reported ?? 1) * 100)
        out["muted"] = (volume?.isMuted ?? false) ? "yes" : "no"
        // The link quality mode: the difference between 50 kbps and 500, and until now the only
        // place it was visible was a log line at startup that nothing updates. The rule is in
        // `LinkQuality`, where the reasoning and the measurements live.
        out["link_stalls"] = String(streamer.currentStalls)
        // What the link carries, which is what decides whether a level is usable at all: HQ asks
        // 990 and this machine carries ~530, so HQ here means "half the audio thrown away".
        // What the link has *demonstrably* carried, and whether that was ever the level asked for.
        //
        // `link_kbps` used to be `currentCarriedKbps`, which is 0 until audio is thrown away — so
        // on every healthy stream the menu had nothing to compare against and showed "High · up to
        // 990 kbps" with no contradiction. Reported 2026-11-09 as "why do I still see high at 990
        // kbps?".
        //
        // It is a floor, not a capacity, and the menu says so: `link_floor` is what has been
        // carried, `link_ceiling` is what a window that dropped audio measured. When the ceiling
        // is known it wins, because it is the only one of the two that is an actual limit.
        out["link_kbps"] = String(
            format: "%.0f",
            streamer.currentCarriedKbps > 0
                ? streamer.currentCarriedKbps : streamer.currentFloorKbps)
        out["link_ceiling"] = String(format: "%.0f", streamer.currentCarriedKbps)
        out["link_floor"] = String(format: "%.0f", streamer.currentFloorKbps)
        out["link_occupancy"] = String(format: "%.0f", streamer.currentOccupancy * 100)
        // The burst only means something when the socket refused something: with no refusal it is
        // just "every packet in the window", which was 499 on this Mac and says nothing about the
        // link. So it is reported only when there was a stall to end it.
        out["packets_per_drain"] = streamer.currentStalls > 0 ? String(streamer.currentBurst) : "-"
        out["link_quality"] =
            LinkQuality.judge(
                stalls: streamer.currentStalls,
                burst: streamer.currentBurst,
                sentPackets: streamer.currentBurst > 0
            ).rawValue
        out["latency_ms"] = String(
            format: "%.0f",
            (streamer.currentCushion + Double(ring.available) / Double(ring.sampleRate)) * 1000)
        return out
    }
    if control.start() {
        say("control channel: \(ControlServer.defaultPath) (try `codecblue status`)")
    } else {
        say(
            "control channel: could not create \(ControlServer.defaultPath); "
                + "the stream works but cannot be steered")
    }
    defer { control.stop() }
    streamer.onKey = { [volume, say, mediaKeys] key in
        switch key {
        case "volume_up", "volume_down":
            guard let volume else { return false }
            let delta: Float = key == "volume_up" ? 1.0 / 16 : -1.0 / 16
            if let position = volume.step(by: delta) {
                say(
                    String(
                        format: "headphone volume button: slider %.0f%% -> gain %.1f%%",
                        position * 100, volume.gain * 100))
                return true
            }
            say("headphone volume button: the device refused the change")
            return false
        case "play", "pause", "stop":
            // A single button on the headphones means ONE thing: toggle.
            //
            // This is the correction of a correction, and the log is what settled it. The
            // headphones send exactly one PASS THROUGH per gesture — measured five times across
            // five sessions, always `0x46` (PAUSE), never a pair — and their one physical button
            // is a play/pause toggle. So `pause` is not an instruction, it is the name of the
            // button.
            //
            // Sending an explicit PAUSE for it worked exactly once: the first gesture paused the
            // player, the second gesture asked an already-paused player to pause, and nothing
            // happened — "la prima volta il doppio clic ha messo pausa, ora non funziona più".
            // A toggle cannot get stuck that way, because it does not depend on what the player
            // already thinks it is doing.
            guard let mediaKeys else {
                say("headphone button \(key): no media key helper, so nothing was sent")
                return false
            }
            mediaKeys.send("toggle")
            say("headphone button \(key): toggled play/pause")
            return true
        case "next", "previous":
            guard let mediaKeys else {
                say("headphone button \(key): no media key helper, so nothing was sent")
                return false
            }
            mediaKeys.send(key)
            say("headphone button \(key): forwarded to the system")
            return true
        default:
            say("headphone button \(key): not handled")
            return false
        }
    }
    // The Mac's slider must reach the headphones, not just our own mixer. Measured 2026-11-06:
    // the slider changed the gain we apply and the headphones kept their own attenuation, so the
    // two volumes were independent — moving the slider did not move what the headphones do.
    // ONE attenuation, not two — and it lives at the headphones.
    //
    // Measured 2026-11-07: the slider was applied in two places at once — this process multiplied
    // the samples by the decibel curve, *and* the same slider position went down the link as SET
    // ABSOLUTE VOLUME. At 56% the samples were already at -28 dB and the headphones attenuated
    // again on top: about -34 dB, the reported "sono costretto ad arrivare a metà".
    //
    // The first attempt at a fix held the headphones at full scale and kept the whole curve here.
    // That was wrong for a reason the log made obvious within a minute: pushing 1.0 makes the
    // headphones *report* 100%, the report is indistinguishable from a finger on their own volume
    // key, and the slider jumped to 100% on its own. A control that writes itself is worse than a
    // quiet one.
    //
    // So the attenuation goes where macOS itself puts it for these headphones: down the link. The
    // slider moves, the headphones follow, and this process multiplies by nothing. That is also
    // what makes the headphones' own keys and the Mac's slider one control instead of two.
    volume?.onChange = { [weak volume, weak streamer] position in
        // Remember what we sent before sending it: the headphones report it back as a volume
        // notification, and that report is indistinguishable from their own volume key.
        volume?.notePushed(position)
        streamer?.setHeadphoneVolume(position)
    }
    // The push at start-up cannot happen here: `setUp` is what opens the AVRCP channel, and it
    // runs further down. Sending now would be a message to nobody — measured 2026-11-06, the
    // log showed no outgoing frame at all until the channel existed. So it is sent right after
    // `setUp`, below.
    streamer.onAbsoluteVolume = { [volume, say] value in
        // `setFromHeadphones`, not `set`: the headphones report back every value we push, and
        // acting on that echo is what pinned the slider at 100% — measured 2026-11-08, the log
        // showed `absolute 100%` then `slider 100%` and the slider could not be moved again.
        guard let volume, let position = volume.setFromHeadphones(value) else { return }
        say(
            String(
                format: "headphone volume: slider %.0f%% -> gain %.1f%%",
                position * 100, volume.gain * 100))
        // No push back. `set(position:)` has already updated our copy of the slider, so the
        // refresh that follows sees no change and does not echo the value to the headphones —
        // which is what stopped the earlier version from chasing its own tail.
    }
    // The lead stays small on purpose, and this is measured, not assumed: setting it to the
    // cushion depth (250 ms) made the encoder demand audio the writer had not produced yet, so
    // the ring went to 0 frames waiting and every read came back short — the fill ran constantly
    // and the result was worse, not better. The source is live: the encoder cannot run ahead of
    // it. The cushion has to be audio that already exists, which means it belongs in the ring.
    // 15 ms, not 40: the lead only has to cover the encoder's own lookahead (LDAC frames are
    // ~10 ms) and give it something to send at the start. It is pure latency — measured
    // 2026-11-06, the listener reported the total as "more than 80 ms", and the lead was 40 of
    // it while the cushion was 81.
    streamer.leadTime = 0.015
    // Rebuild the cushion when it has drained, by running a shade slow until it is back.
    // See A2DPStreamer.paceSlowdown: 1% is inaudible and refills 250 ms in about 25 s.
    // ONE cushion, not two.
    //
    // Audio is held twice on its way out: in the ring (not yet encoded) and in the packet queue
    // (encoded, not yet sent). Both are the *same* audio at different stages, so their delays
    // add. Measured 2026-11-06 while a video played: ring 240 ms and queue 240 ms — 495 ms of
    // latency in total, which is why the listener said "more than what you say" while the code
    // was confidently reporting 60 ms.
    //
    // So the ring is only the writer's jitter buffer: enough that a read never comes back short,
    // never more. The cushion proper — the thing that absorbs a stall in the link — is the
    // packet queue, because that is where audio waits *after* being encoded, which is where a
    // stall actually happens.
    //
    // `staleAfterFrames` is a safety net only: it exists so the ring cannot wrap its fixed
    // buffer, and it must not be tied to the queue's budget — doing that threw away the cushion
    // the widening had just created (86 skips in one run, heard as clicks).
    // The two delays ADD, so the budget has to be split between them, not given to both.
    //
    // Measured 2026-11-06 during a video: ring 257 ms and queue 256 ms — 513 ms of latency,
    // while the code reported the queue's 256 ms as if it were the whole story. They are the
    // same audio at two stages, and when the link stalls the queue fills first, the encoder
    // stops, and the ring fills behind it. So: whatever the queue is holding, the ring may hold
    // only the remainder of the budget.
    //
    // `staleAfterFrames` is where that is enforced — the reader jumps forward rather than let
    // the total exceed the budget. That is a real discard, and it is the correct one: audio that
    // would arrive later than the budget is worth less than audio that arrives on time.
    let budget: TimeInterval = 0.25
    let cushionSeconds = CushionClock(queueDuration)
    // The ring is a live device: the driver writes at the Mac's clock whether or not the link is
    // keeping up, so every stall of `bluetoothd` leaves the ring holding that much extra audio.
    // Nothing used to take it back — reading at exactly real time preserves whatever surplus is
    // already there — so one 130 ms stall added 250 ms of delay for the rest of the session.
    // Measured 2026-11-06: 1984 frames (41 ms) → 13 504 (281 ms) at t=81 s, still 11 800 at
    // t=213 s. That is the reported "after a while the audio is behind the video".
    //
    // The servo drains the surplus by reading a little more than a block and compressing it back
    // to exactly one block, so the link still carries real time and only the pitch moves. Capped
    // at 1.5%: 0.26 of a semitone, not audible on speech, and it clears 250 ms in about 15 s.
    // The ring's target is the *remainder* of the budget, not the queue's cushion.
    //
    // Measured 2026-11-07, on a long video: the queue sat at its 240 ms ceiling and the ring
    // settled at 10 000–12 300 frames — another 210–255 ms. The two delays add, so the listener
    // was hearing about half a second while every number in the report looked like it was inside
    // its budget. Both were: the bug is that the ring was told to hold `cushionSeconds.value`,
    // which is the queue's own depth. Two stages, one budget, counted twice.
    //
    // So the ring chases whatever is left: budget minus what the queue is holding. When the link
    // is healthy the queue holds 60 ms and the ring gets 190; when the link stalls and the queue
    // widens to 240, the ring is told to empty itself down to 10 ms, which is right — the audio in
    // the ring is the audio that has not been encoded yet, and it is the one that can still be
    // thrown away cheaply.
    // The ring's target is its own small jitter buffer — NOT the queue's cushion.
    //
    // Measured 2026-11-07, on a long video: the queue sat at its 240 ms ceiling while the ring
    // settled at 10 000–12 300 frames, another 210–255 ms. The two delays add, so the listener was
    // hearing about half a second while every number in the report sat inside its own budget. Both
    // were — the ring had been told to hold `cushionSeconds.value`, which is the *queue's* depth.
    // One budget counted at two stages.
    //
    // The ring is not a cushion for the link: a stall in the link fills the queue, the encoder
    // stops, and the ring fills behind it as a *consequence*. Draining the ring to the queue's
    // depth therefore keeps a second copy of the delay that the queue is already holding. Its job
    // is only to be deep enough that a read never comes back short.
    //
    // So it chases `ringTarget`, which is defined below as 40 ms and is the writer's jitter, not
    // the link's. Total latency is then cushion + ring + packets in flight, and each number means
    // one thing.
    // The throttle holds the *ring* at a small depth — the writer's jitter, not the link's
    // cushion. The link's cushion is the packet queue, which has its own adaptation.
    // The ring's floor: enough that a read never comes back short, never more. It is a jitter
    // buffer for the writer, not a cushion for the link — the link's cushion is the queue.
    let ringTarget = 0.04
    streamer.drainBoost = {
        let depth = ring.available
        let target = Int(ringTarget * Double(ring.sampleRate))
        guard target > 0, depth > target else { return 0 }
        let excess = Double(depth - target) / Double(target)
        return min(0.015, excess * 0.02)
    }
    streamer.cushionChanged = { queueDepth in
        cushionSeconds.value = queueDepth
        let room = max(0.03, budget - queueDepth)
        ring.staleAfterFrames = Int(room * Double(ring.sampleRate))
    }
    ring.staleAfterFrames = Int((budget - queueDuration) * Double(ring.sampleRate))
    // Clock drift between the Mac and the headphones lives in `A2DPStreamer.driftCorrection`,
    // because it has to be applied by resampling and not by reading the ring more slowly: the
    // first attempt moved the clock anchor, which made us read fewer frames than the driver
    // wrote and simply moved the growing delay into our own ring (measured: 2048 → 2750 frames).
    streamer.paceSlowdown = {
        let depth = ring.available
        let target = Int(ringTarget * Double(ring.sampleRate))
        // Target the *full* cushion, not half of it. With the threshold at half, the throttle
        // switched off as soon as the depth reached 40 ms of an 80 ms target, so the cushion
        // settled at half the intended size — measured 2026-11-06: 1024–2688 frames oscillating
        // around 1920, which is 40 ms, not 80. The latency was half of what was asked for and
        // the cushion half of what it needed to be.
        //
        // Slowing never stops consumption, so engaging at the target cannot deadlock: it only
        // makes the stream run 0.5–2% slow until the depth is back.
        guard depth < target else { return 0 }
        let shortfall = Double(target - depth) / Double(target)
        return min(0.02, 0.005 + shortfall * 0.015)
    }
    streamer.adaptBitrate = adapt
    streamer.sendBufferPackets = sendBufferPackets
    // The gain is the mute, and nothing else.
    //
    // The volume curve belongs to the headphones now (see `volume?.onChange`), so multiplying here
    // as well would be the two-attenuations bug again. The mute is different: it must be
    // instantaneous and it must work even if the link is busy, so it is applied here as a zero.
    streamer.gain = { [weak volume] in
        guard let volume else { return 1 }
        return volume.isMuted ? 0 : 1
    }
    box.streamer = streamer
    // A stop asked for before this streamer existed could not reach it: `route` had no streamer to
    // stop, so it only set the flag. Carry the flag across, or the handshake runs to completion
    // and announces a stream that is about to be torn down.
    if box.interrupted { streamer.stop() }
    // nil = take whatever the headphones offer; the device's own rate is only a preference.
    // Ask for the device's own rate. It is what the audio already is, so asking for it means no
    // resampling at all; asking for 48 when the device runs at 44.1 would convert every sample
    // for no reason. `setUp` treats it as a preference, so a device that cannot take this rate
    // still gets the best it offers.
    let configuration: A2DPStreamer.Configuration
    do {
        configuration = try await streamer.setUp(sampleRate: ring.sampleRate, rung: rung)
    } catch A2DPStreamer.StreamError.stopped {
        // Asked to stop before the handshake began: not a failure, just an early exit.
        log("stopped before the stream started: not taking the headphones")
        await takeover.handBack(handBackStyle)
        return false
    }
    // A stop that arrived during the handshake: everything below assumes a live stream. Check
    // here, once, rather than in each of the places that would otherwise have to know.
    if box.interrupted {
        log("stopped during the handshake: not starting the stream")
        await streamer.tearDown()
        log("handing the headphones back to macOS")
        await takeover.handBack(handBackStyle)
        return false
    }
    // Now the AVRCP channel exists, so the headphones can be told the volume the Mac is at.
    // Without this the two volumes are independent: the slider moves our gain and the headphones
    // keep their own attenuation, which is exactly what was reported.
    if let volume {
        // Tell the headphones where the slider is, so the two agree from the first second. This
        // is the same push `onChange` does; doing it here as well costs one frame and removes the
        // window where the headphones are at whatever the last session left them.
        streamer.setHeadphoneVolume(volume.reported)
        log(
            String(
                format: "headphones told to play at %.0f%% (the Mac's slider)",
                volume.reported * 100))
    }
    // The device runs at 48 kHz and the headphones may take 44.1: convert rather than refuse.
    let resampler = Resampler(from: ring.sampleRate, to: configuration.sampleRate)
    // Skipped source audio is audio nobody will hear: discard it from the ring too, or the ring
    // grows by exactly what was skipped and the stream falls behind by that much.
    // The conversion factor is captured as a number, not as the resampler: the resampler belongs
    // to the audio thread and is not Sendable.
    let skipScale =
        resampler.isIdentity
        ? 1.0
        : Double(ring.sampleRate) / Double(configuration.sampleRate)
    streamer.onSkip = { frames in
        ring.discard(Int((Double(frames) * skipScale).rounded()))
    }
    // Ask for the link quality mode again the instant the stream starts: see `onStreamStarted`.
    // Without it the first ~14 s of every stream run at ~50 kbps, which is heard as crackle, and
    // the cause is invisible from here — it is bluetoothd having erased its own audio device.
    // The keeper may have been created after `setUp` (its UUID only exists once the headphones are
    // connected), so the closure captures the variable, not the value: `keeper` is a `var` in this
    // scope and by the time the stream starts it may hold an instance that did not exist here.
    streamer.onStreamStarted = { [keeper] in
        keeper?.askAgainNow(because: "once the stream started")
    }

    if box.interrupted {
        // The handshake took seconds and a stop arrived in the middle of it: tear down now rather
        // than start streaming into a process that is on its way out.
        log("stopped during the handshake: not starting the stream")
        await streamer.tearDown()
        log("handing the headphones back to macOS")
        await takeover.handBack(handBackStyle)
        return false
    }
    if !resampler.isIdentity {
        log("resampling \(ring.sampleRate) Hz -> \(configuration.sampleRate) Hz for the encoder")
    }
    log("playing the system output in LDAC \(configuration.rungName)")
    // The ring is live: there is no end, only the next buffer. The streamer pulls from a closure
    // so that it can keep its own pacing and queue accounting.
    // Report the ring's own health: a skip is an audible click, so it must be visible.
    let monitor = Task.detached(priority: .utility) {
        var lastSkips = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            // Re-assert the claim, every window.
            //
            // The field holds one pid and this process is not the only one that wants to feed:
            // `codecblue system` run by hand while the agent is streaming takes it, and when that
            // run ends the field goes to 0 — the agent is still streaming and the driver is told
            // nobody is. Measured 2026-11-09: the device vanished from the output list, macOS fell
            // back to the headphones, and `status` said `link_quality unknown` with a battery
            // percentage, which reads as healthy. `feeding` refuses to steal a live claim, so a
            // stream that has lost the field says so and takes it back.
            if !ring.feeding {
                ring.feeding = true
                if !ring.feeding {
                    log(
                        "ring: another process is feeding this ring; the device will hide "
                            + "and the system output will fall back")
                }
            }
            let now = ring.skips
            // Report every window, not only the ones with a skip: "0 skips, 9 ms waiting" is the
            // evidence that the clicks are not the ring's fault, and silence proves nothing.
            let gain = volume?.gain ?? 1
            log(
                String(
                    format:
                        "ring: %d skip(s) in the last 2 s (%d total), %d frames waiting, gain %.1f%%",
                    now - lastSkips, now, ring.available, gain * 100))
            lastSkips = now
        }
    }
    defer { monitor.cancel() }

    try await Task.detached(priority: .high) {
        var loggedCatchUp = false
        try streamer.play(pulling: { frames in
            // Self-correcting catch-up, rather than one jump at a chosen moment.
            //
            // A single `jumpToLive()` before the loop is not enough: the driver resets the ring
            // in `StartIO` (`write = 0; read = 0`) and that can happen after the jump, and the
            // driver also keeps writing during the seconds the handshake takes. Measured
            // 2026-11-06: the depth sat at 46 000 of 48 000 frames — 960 ms of latency — for a
            // whole session, because the reader was permanently a ring behind.
            //
            // So: if the depth is far above the budget, it is not a cushion, it is a backlog.
            // Jump to the newest audio and say so once.
            let target = Int(cushionSeconds.value * Double(ring.sampleRate))
            // The jump is the emergency brake, not the normal correction: it throws away every
            // queued frame at once, which is a hole in the sound. The drain servo handles a
            // normal stall smoothly by playing a fraction of a percent fast, so this only fires
            // when the ring holds several times the cushion — the case where waiting would mean
            // seconds of delay. Measured 2026-11-06: at `target * 2` (120 ms) every ordinary
            // 130 ms stall tripped it.
            if ring.available > target * 6 {
                let was = ring.available
                ring.jumpToLive()
                if !loggedCatchUp {
                    loggedCatchUp = true
                    log("ring: jumped from \(was) frames to live (the driver had run ahead)")
                }
            }
            // `frames` are frames at the *encoder's* rate: convert the count back to the device's
            // rate, read that many, then resample up (or down) to what the encoder wants.
            let deviceFrames =
                resampler.isIdentity
                ? frames
                : Int(
                    (Double(frames) * Double(ring.sampleRate) / Double(configuration.sampleRate))
                        .rounded())
            var buffer = [Float](repeating: 0, count: deviceFrames * 2)
            let got = ring.read(into: &buffer, count: deviceFrames)
            guard got > 0 else { return [] }
            return resampler.process(Array(buffer[0..<(got * 2)]))
        })
    }.value
    await streamer.tearDown()
    log("handing the headphones back to macOS")
    await takeover.handBack(handBackStyle)
    return box.callInterrupted
}

/// The system output, played for as long as the user wants it — across calls.
///
/// A call is not the end of the session, it is an interruption of it: the headphones belong to
/// macOS while someone is talking into them, and they come back when the call is over. That is
/// the whole reason this wrapper exists rather than a single pass.
func playSystem(_ address: String, options: [String]) async throws {
    let stopRequest = StopRequest()
    stopRequest.listen()
    let monitorWanted = !options.contains("--no-call-monitor")
    var monitor: CallMonitor?
    if monitorWanted {
        monitor = CallMonitor(log: log)
        monitor?.start()
    }
    defer { monitor?.stop() }
    while true {
        let interruptedByCall = try await playSystemOnce(
            address, options: options, monitor: monitor, stopRequest: stopRequest)
        guard interruptedByCall else { break }
        // A Ctrl-C during the call's gap stops the process, not just the session: there is nothing
        // left to come back to.
        guard !stopRequest.wasAsked else { break }
        // The headphones are macOS's now: wait for the call to end, then take them back.
        log("the headphones are macOS's for the call; waiting for it to end")
        while monitor?.isCallActive == true {
            try? await Task.sleep(for: .seconds(1))
        }
        log("taking the headphones back")
    }
    exit(0)
}

/// Writes the test tone as a WAV file, to play it through macOS's own A2DP and compare the
/// two streams on the same link.
func tone(_ path: String, seconds: Double, sweep: Bool = false) throws {
    // A constant sine, not an arpeggio: see WAVFile.sine. The old file changed note every 0.5 s
    // and jumped phase at each change, so it crackled on its own and made every link look bad.
    let audio =
        sweep
        ? WAVFile.sweep(sampleRate: 48000, seconds: seconds)
        : WAVFile.sine(sampleRate: 48000, seconds: seconds)
    try audio.write(to: URL(fileURLWithPath: path))
    log(
        String(
            format: "wrote %@: %.1f s at %d Hz, %@", path, audio.duration, audio.sampleRate,
            sweep ? "sweep 100 Hz to 8 kHz" : "constant 440 Hz, no transients"))
}

/// Diagnostic: the audio channel of bluetoothd (`com.apple.BTAudioHALPlugin.xpc`), which is how
/// the link quality mode gets turned on. Kept because the message numbers and the two traps
/// below are worth having in the code, not because it is safe to run.
///
/// It has crashed bluetoothd five times out of five on 2026-11-06, in two different ways:
///
/// * a message without `kBTAudioMsgArgs` → `CFRelease(NULL)` in the XPC event handler
///   (`EXC_BREAKPOINT`, four crash reports);
/// * a message with `kBTAudioMsgDeviceUUID` set to a real `CBDevice` UUID but a property
///   dictionary of the wrong shape → an Objective-C exception inside `CFBooleanGetValue`
///   (`EXC_CRASH`, one crash report).
///
/// So it is not a probe: it is a way to kill the system Bluetooth daemon. It refuses to run
/// without `CODECBLUE_AUDIO_CHANNEL=yes`, and the only thing it does now is send the one message
/// that is known to work — `BTAudioMsgIdStartAudio` — because that is what `AudioStreamKeeper`
/// uses in production. Everything else was removed rather than left one keystroke away.
func audioprobe(_ address: String) async throws {
    guard ProcessInfo.processInfo.environment["CODECBLUE_AUDIO_CHANNEL"] == "yes" else {
        log("refusing: every sweep of this channel has crashed bluetoothd (5 for 5 on 2026-11-06).")
        log("set CODECBLUE_AUDIO_CHANNEL=yes only if you accept losing Bluetooth for a few seconds")
        log(
            "what you probably want is `codecblue play --keep-link-quality`, which is the safe path"
        )
        return
    }
    guard let uuid = CBDeviceUUID.resolve(for: address).best else {
        log("cannot find bluetoothd's UUID for this device")
        return
    }
    let keeper = AudioStreamKeeper(address: address, deviceUUID: uuid, period: 1, log: log)
    keeper.start()
    log("sending BTAudioMsgIdStartAudio for 5 s; watch bluetoothd's Server.Audio log")
    try await Task.sleep(for: .seconds(5))
    keeper.stop()
}

func release(_ address: String) async throws {
    let session = ClassicXPCSession(label: "release")
    try await session.start()
    defer { session.invalidate() }
    let record = try await session.lookup(address: address)
    if record.isLinkUp {
        log("dropping the link")
        session.cancelConnection(record.uuid, force: true)
        for _ in 0..<50 {
            guard (try? await session.lookup(address: address).isLinkUp) == true else { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(1))
    }
    log("asking macOS to connect the headphones")
    session.connect(record.uuid)
    for _ in 0..<80 {
        if SystemHeadphoneAudio.hasDevice(address: address) {
            log("macOS has the headphones again")
            return
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    log(
        "macOS has not published the headphones' audio yet; if it does not, put them in the case for a few seconds"
    )
}

final class StreamerBox: @unchecked Sendable {
    var streamer: A2DPStreamer?
    var interrupted = false
    /// Set when a phone call is what stopped the stream, so the caller knows to start again.
    var callInterrupted = false
}

/// Carries the "ask for the link quality mode now" action into a `@Sendable` callback.
///
/// The action is a local function in `playSystem` and the callback is `@Sendable`, so the function
/// cannot be captured directly. It is also not known when the callback is installed: the keeper
/// needs bluetoothd's UUID, and that line only exists once the audio device is published — which
/// is the very moment the callback fires. So the box is filled before the takeover starts and read
/// when the moment comes.
final class KeeperBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: ((String) -> Void)?

    func set(_ action: @escaping (String) -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func ask(because reason: String) {
        lock.lock()
        let action = self.action
        lock.unlock()
        action?(reason)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first, arguments.count) {
    case ("version", _):
        // The version is the one baked in at build time (see `Version`), so a bug report can say
        // which release it came from without the reporter having to know anything about git.
        print("CodecBlue \(Version.describe)")
        print("libldac \(LDAC.libraryVersion)")
        print("bluetoothd XPC table: \(XPCProtocol.current.name)")
    case (nil, _):
        // No arguments means the user wants to know what to type. Printing just the version
        // made `codecblue` look like a program with one command.
        usage()
    case ("lookup", 2): try await lookup(arguments[1])
    case ("probe", 2): try await probe(arguments[1])
    case ("release", 2): try await release(arguments[1])
    case ("link", 2): try await link(arguments[1])
    case ("audioprobe", 2): try await audioprobe(arguments[1])
    case ("tone", 2...4):
        // `tone FILE [SECONDS] [--sweep]`
        let sweep = arguments.contains("--sweep")
        let seconds =
            arguments.count > 2 && !arguments[2].hasPrefix("--")
            ? Double(arguments[2]) ?? 30 : 30
        try tone(arguments[1], seconds: seconds, sweep: sweep)
    case ("pace", 3...5):
        let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 5 : 5
        let size = arguments.count > 3 ? Int(arguments[3]) ?? 679 : 679
        let rate = arguments.count > 4 ? Double(arguments[4]) ?? 43 : 43
        try await pace(arguments[1], seconds: seconds, packetSize: size, rate: rate)
    case ("flood", 2...6):
        let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 5 : 5
        let size = arguments.count > 3 ? Int(arguments[3]) ?? 679 : 679
        let keep = arguments.count > 4 && arguments[4] == "--keep-link-quality"
        let suffix = arguments.count > 5 ? arguments[5] : "tacl"
        try await flood(
            arguments[1], seconds: seconds, packetSize: size, keepLinkQuality: keep,
            uidSuffix: suffix)
    case ("rate", 2):
        // Choose the rate the virtual device runs at. It is stored in the ring's header, and the
        // driver reads it when coreaudiod loads it — so this writes the choice and says what to
        // do next, rather than pretending a running device can change rate underneath its
        // clients.
        let wanted = Int(arguments[1]) ?? 0
        guard [44100, 48000, 88200, 96000].contains(wanted) else {
            log("usage: codecblue rate 44100|48000|88200|96000")
            exit(2)
        }
        guard let ring = try? SharedRing() else {
            log("could not open the ring at /tmp/codecblue-ring — is the driver installed?")
            exit(1)
        }
        ring.setSampleRate(wanted)
        log("the device will run at \(wanted) Hz after coreaudiod reloads the driver")
        log("to apply it:  sudo killall coreaudiod")
        log("note: the stream must also ask for \(wanted) Hz, or it will resample.")
    case ("abr", 1):
        // Does this libldac build support ABR? The header reserves EQMID 0x7F for it, and the
        // answer decides whether a bitrate slider is even possible: LDAC has three fixed levels
        // (330 / 660 / 990 kbps at 48 kHz) and no continuous rate, so anything between them must
        // come from ABR.
        print("ABR available: \(LDACEncoder.supportsABR ? "yes" : "no")")
        // Every EQMID libldac accepts, and what it actually produces. The header documents three
        // levels; the ABR table in the source names five (990 / 660 / 492 / 396 / 330 at 96 kHz),
        // so the question is what this build does at 48 kHz.
        for level in LDACEncoder.Level.allCases {
            for rate in [44100, 48000] {
                if let e = try? LDACEncoder(sampleRate: rate, level: level, mtu: 679) {
                    print("  \(level.name) at \(rate) Hz: \(e.bitrateKbps) kbps")
                } else {
                    print("  \(level.name) at \(rate) Hz: refused")
                }
            }
        }
    case ("devices", 1):
        // What the menu bar app lists. Also useful on its own: it is the only place that shows
        // which of the paired headphones are actually on.
        let devices = BluetoothHeadphone.audioDevices()
        if devices.isEmpty {
            print("no headphones known to macOS (pair them in System Settings first)")
            exit(0)
        }
        for device in devices {
            print(
                "\(device.isConnected ? "connected" : "off      ")  \(device.name)  \(device.address)"
            )
        }
    case ("status", 1):
        // Talk to a running stream. No stream is not an error: it is the normal state.
        guard let lines = ControlClient.send("status") else {
            print("no stream is running (nothing at \(ControlServer.defaultPath))")
            exit(0)
        }
        // A value that means "nothing to say yet" is spelled out.
        //
        // Reported 2026-11-09: "codecblue on the command line also gives me link quality unknown".
        // It was right — `unknown` means nothing has been sent in the window, which is the normal
        // state of a stream nobody is playing into — and it read as a fault, because a bare
        // `unknown` next to `link_kbps 525` looks like a contradiction rather than an explanation.
        // The stream cannot know the link's quality without pushing audio through it, and saying so
        // is cheaper than making the reader work it out.
        let explanations = [
            "link_quality":
                "unknown (nothing sent yet: the link is not exercised until audio flows)",
            "quality_kbps": "unknown (nothing sent yet)",
        ]
        for line in lines where line != "end" {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let shown =
                    explanations[parts[0]].flatMap { parts[1] == "unknown" ? $0 : nil }
                    ?? parts[1]
                print("\(parts[0].padding(toLength: 14, withPad: " ", startingAt: 0)) \(shown)")
            } else {
                print(line)
            }
        }
    case ("quality", 2):
        guard let lines = ControlClient.send("quality \(arguments[1])") else {
            print("no stream is running (nothing at \(ControlServer.defaultPath))")
            exit(1)
        }
        print(lines.joined(separator: "\n"))
    case ("levels", 1...):
        // The whole ladder, in kbps and in a verdict. Five rungs, not three: the two in the middle
        // have no name and are exactly what a link that carries ~530 kbps needs. Without a stream
        // there is no measured capacity, and then only the nominal bitrates are printed: a guess
        // here would be worse than an answer that says what it knows.
        //
        // An optional capacity argument answers "what would this look like on a 530 kbps link?"
        // without starting a stream — the question the menu is trying to answer, and the one that
        // is impossible to check by eye.
        let status = ControlClient.send("status") ?? []
        func value(_ key: String) -> String? {
            status.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let given = arguments.count > 1 ? Double(arguments[1]) : nil
        let capacity = given ?? Double(value("link_kbps") ?? "") ?? 0
        let rate = Int(value("sample_rate") ?? "") ?? 48000
        if given == nil, capacity <= 0 {
            print("no stream running: the names only, because a bitrate here would be a claim")
            print("about a link that does not exist yet.")
            print("(give a capacity to see the verdict: codecblue levels 530)")
        }
        for level in QualityLevels.describe(capacityKbps: capacity, sampleRate: rate) {
            print(
                (level.chosen ? "✓ " : "  ") + QualityLevels.label(level, capacityKbps: capacity)
                    + "  (rung \(level.rung))")
        }
    case ("compare", 1):
        // The question this answers is "how does this compare with the Mac's own AAC?". It cannot
        // be answered by listening, because the two paths are not in the room at the same time, and
        // it cannot be answered by copying a bitrate out of a datasheet. bluetoothd prints what it
        // configured and what the link did, once a second, while *it* streams — so that is read,
        // and the comparison is made in the only unit both paths share: kbit/s asked of the link.
        guard let text = BluetoothLog.text(window: "12h"),
            let session = AACSession.parse(text)
        else {
            print(
                "no AAC session in the last 12 hours: play something through the Mac's own "
                    + "Bluetooth output first, and this will read what macOS asked of the link")
            exit(0)
        }
        for line in session.describe() { print(line) }
        let status = ControlClient.send("status") ?? []
        func value(_ key: String) -> String? {
            status.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let rate = Int(value("sample_rate") ?? "") ?? 48000
        let ladder = LDACEncoder.ladder(sampleRate: rate)
        let floor = ladder.last ?? 330
        print("")
        print(session.comparison(floorKbps: floor))
        if let carried = Double(value("link_kbps") ?? ""), carried > 0 {
            print(
                String(
                    format: "this link has carried %.0f kbps: AAC's %.0f fits with room, "
                        + "LDAC's floor of %d %@", carried, session.kbps, floor,
                    carried >= Double(floor) ? "fits too" : "does not"))
        }
        print("")
        print("The rest of the difference is not a bitrate:")
        print("  · macOS owns the ACL link: it keeps the Link Quality Mode on and takes the link")
        print("    out of sniff itself. This program rents the same link by taking it over, so it")
        print("    gets the same radio and has to ask for both by hand.")
        print("  · macOS has adjustBitRateForMac: when the link complains it lowers the AAC")
        print("    bitrate. libldac's public API stops at 330 kbps, so below that there is nothing")
        print("    to lower — the audio is dropped instead.")
        print("  · AAC is VBR: its frames shrink when the signal is simple. LDAC's frame length is")
        print("    fixed by the packet type, so its bitrate does not follow the music.")
    case ("cushion", 2):
        guard let lines = ControlClient.send("cushion \(arguments[1])") else {
            print("no stream is running (nothing at \(ControlServer.defaultPath))")
            exit(1)
        }
        print(lines.joined(separator: "\n"))
    case ("adapt", 2):
        guard let lines = ControlClient.send("adapt \(arguments[1])") else {
            print("no stream is running (nothing at \(ControlServer.defaultPath))")
            exit(1)
        }
        print(lines.joined(separator: "\n"))
    case ("handlers", 2):
        try await handlers(arguments[1])
    case ("stop", 1):
        // One command that stops the stream *and* the agent that would restart it.
        //
        // Both are needed and neither is obvious. `quit` down the control socket stops the stream
        // and hands the headphones back, but launchd's KeepAlive starts it again five seconds
        // later — right for a crash, wrong for a deliberate stop. Unloading the agent kills the
        // process with SIGTERM, which stops it politely (see `StopRequest`).
        //
        // The order is unload *first*, and it was the other way round until 2026-11-09, when it
        // failed in a way that looked like success: `stop` printed "agent: unloaded (it will not
        // restart until it is loaded again)" and `launchctl list` still had `com.codecblue.system`
        // with a fresh pid. The quit emptied the socket, KeepAlive restarted the agent at the same
        // second the unload ran, and the restart won the race. The stream was still running, the
        // headphones were still taken, and the only evidence was a pid that changed.
        //
        // Unloading first removes the thing that would restart it, so there is no race to lose.
        let socket = ControlServer.defaultPath
        let plist = LaunchAgent.plistURL
        let installed = FileManager.default.fileExists(atPath: plist.path)
        if installed {
            try? LaunchAgent.unload()
        }
        // Then ask politely, in case the process survived the unload (it can, for the length of a
        // teardown: SIGTERM is handled, not obeyed instantly).
        if FileManager.default.fileExists(atPath: socket) {
            if let reply = ControlClient.send("quit") {
                log("stream: \(reply.first ?? "ok")")
            } else {
                log("stream: the socket is there but nothing answered")
            }
        } else {
            log("stream: nothing running")
        }
        // Wait for the result instead of guessing how long a teardown takes: the headphones are
        // back when macOS lists their audio device again and CodecBlue is no longer the output.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let stillLoaded = installed && LaunchAgent.isLoaded()
            let ours = SystemVolume.findDevice(named: "CodecBlue") != nil
            let output = DefaultOutput.current()
            let outputIsOurs = output.map { $0.name == "CodecBlue" } ?? false
            if !stillLoaded && !ours && !outputIsOurs { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        if installed && LaunchAgent.isLoaded() {
            log(
                "agent: still loaded — launchctl refused the unload; try `launchctl bootout gui/$(id -u) \(plist.path)`"
            )
        } else if installed {
            log("agent: unloaded (it will not restart until it is loaded again)")
            log("to start it again: codecblue start")
        } else {
            log("agent: not installed")
        }
        // After a crash the record on disk is the only thing that knows what the output was
        // before. `stop` is where a person looks when the Mac has gone silent, so it gives it back.
        switch DefaultOutput.recoverIfOrphaned() {
        case .restored(let name):
            log("system output: back to \(name) (it had been left on CodecBlue)")
        case .gone(let name): log("system output: \(name) is not here; leaving CodecBlue selected")
        case .leftAlone, .nothingToDo: break
        }
        if let output = DefaultOutput.current() {
            log("system output: \(output.name)")
        }
        if SystemVolume.findDevice(named: "CodecBlue") != nil {
            log(
                "the CodecBlue device is still listed; if no stream is running, the driver hides it "
                    + "within half a second — if it stays, the headphones may still be taken")
        }
    case ("agent", 2...):
        // `agent install <address> [options]`, `agent remove`, `agent status`
        let action = arguments[1]
        let address = arguments.count > 2 && !arguments[2].hasPrefix("--") ? arguments[2] : nil
        let extra = address == nil ? [] : Array(arguments.dropFirst(3))
        try agent(action, address: address, extra: extra)
    case ("play", 2...): try await play(arguments[1], Array(arguments.dropFirst(2)))
    case ("system", 2...):
        try await playSystem(arguments[1], options: Array(arguments.dropFirst(2)))
    case ("start", 1...):
        try await start(Array(arguments.dropFirst(1)))
    case ("login", 2):
        try login(arguments[1])
    default: usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

/// Starts the stream the way the menu bar app does, without the menu bar app.
///
/// The icon is a remote control, not a requirement: everything it does is one of three things —
/// write a LaunchAgent, load it, or send a line down a socket — and all three are available here.
/// This exists because "I would rather not install a toolbar" is a reasonable position, and until
/// now the answer was a four-step ritual: find the address with `devices`, write a plist with
/// `agent install`, load it with `launchctl`, then remember `stop` unloads it again.
///
/// The address is optional when there is exactly one pair of headphones connected, which is the
/// common case and the one where typing a MAC address adds nothing.
func start(_ arguments: [String]) async throws {
    var address: String?
    var options: [String] = []
    var rest = arguments[...]
    while let argument = rest.popFirst() {
        if argument.hasPrefix("--") {
            options.append(argument)
            // Options that take a value: the value is not an address and must not be read as one.
            if ["--quality", "--queue-ms", "--media-mtu", "--media-priority", "--sndbuf-packets"]
                .contains(argument), let value = rest.popFirst()
            {
                options.append(value)
            }
        } else if address == nil {
            address = argument
        } else {
            options.append(argument)
        }
    }

    let chosen: String
    if let address {
        chosen = address
    } else {
        let connected = BluetoothHeadphone.audioDevices().filter(\.isConnected)
        switch connected.count {
        case 1:
            chosen = connected[0].address
            log("using \(connected[0].name) (\(chosen))")
        case 0:
            log("no headphones are connected. Turn them on, or name one: codecblue start <address>")
            log(
                "(paired: \(BluetoothHeadphone.audioDevices().map(\.name).joined(separator: ", ")))"
            )
            exit(1)
        default:
            // More than one: guessing would take the wrong pair, and taking headphones away from
            // macOS is not something to do by accident.
            log("more than one pair is connected; say which:")
            for device in connected {
                log("  codecblue start \(device.address)   (\(device.name))")
            }
            exit(1)
        }
    }

    // The same two steps the menu does, in the same order: write the plist, then load it.
    try LaunchAgent.install(address: chosen, arguments: options)
    try LaunchAgent.load()
    log("streaming to \(chosen)\(options.isEmpty ? "" : " " + options.joined(separator: " "))")
    log("it also starts at login from now on: launchd loads \(LaunchAgent.plistURL.path)")
    log("log: \(LaunchAgent.logPath)")
    log("to stop it and give the headphones back: codecblue stop")
}

/// Whether the stream starts at login, without the menu bar app.
///
/// `on` is the same thing `start` does — a plist in `~/Library/LaunchAgents` is loaded by launchd
/// at every login — so it exists mainly to turn it *off* without stopping the stream now, and to
/// answer the question. Removing the plist is what stops it coming back; unloading alone does not,
/// because launchd reads the file again at the next login.
func login(_ action: String) throws {
    let plist = LaunchAgent.plistURL
    switch action {
    case "on":
        guard FileManager.default.fileExists(atPath: plist.path) else {
            log(
                "nothing to start at login yet: run `codecblue start` first, which writes \(plist.path)"
            )
            exit(1)
        }
        try LaunchAgent.load()
        log("the stream starts at login (from \(plist.path))")
    case "off":
        try? LaunchAgent.unload()
        if FileManager.default.fileExists(atPath: plist.path) {
            try FileManager.default.removeItem(at: plist)
            log("removed \(plist.path): the stream will not start at login any more")
        } else {
            log("it was not going to start at login (no \(plist.path))")
        }
        log("the stream itself is still running; `codecblue stop` stops it now")
    case "status":
        let installed = FileManager.default.fileExists(atPath: plist.path)
        log("starts at login: \(installed ? "yes" : "no")")
        log("plist: \(installed ? plist.path : "not installed")")
        log("loaded now: \(LaunchAgent.isLoaded() ? "yes" : "no")")
    default:
        log("usage: codecblue login on|off|status")
        exit(2)
    }
}

/// Installs, removes or inspects the LaunchAgent that keeps `codecblue system` running.
///
/// It is a separate verb rather than something that happens on first run, because a LaunchAgent
/// outlives the terminal: it starts at login, it survives a crash, and the only way to know what
/// it is doing is to look at its log. Installing one silently would be rude and hard to undo.
func agent(_ action: String, address: String?, extra: [String]) throws {
    let plist = LaunchAgent.plistURL
    switch action {
    case "install":
        guard let address else {
            log("usage: codecblue agent install <address> [--quality LQ]")
            exit(2)
        }
        // The absolute path of this binary: launchd has no PATH and no working directory.
        // `.build/debug/codecblue`, not `.build/out/Products/Debug/codecblue`.
        //
        // `Bundle.main.executableURL` and `CommandLine.arguments[0]` both point at SwiftPM's
        // internal product directory, which `swift package clean` deletes: the agent would then
        // fail at login with nothing in its log but "no such file". `.build/debug` is the stable
        // symlink SwiftPM maintains, and it is what the `codecblue` launcher execs.
        // `.build/debug/codecblue`, not `.build/out/Products/Debug/codecblue`.
        //
        // `Bundle.main.executableURL` and `CommandLine.arguments[0]` both point at SwiftPM's
        // internal product directory, which `swift package clean` deletes: the agent would then
        // fail at login with nothing in its log but "no such file". `.build/debug` is the stable
        // symlink SwiftPM maintains, and it is what the `codecblue` launcher execs.
        let invoked = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let repo = invoked.deletingLastPathComponent()  // .build/out/Products/Debug
            .deletingLastPathComponent()  // .build/out/Products
            .deletingLastPathComponent()  // .build/out
            .deletingLastPathComponent()  // .build
            .deletingLastPathComponent()  // the repository
        let stable = repo.appendingPathComponent(".build/debug/codecblue")
        let executable =
            FileManager.default.isExecutableFile(atPath: stable.path)
            ? stable.path
            : invoked.path
        guard executable.hasPrefix("/") else {
            log("cannot install: the path to this binary is not absolute (\(executable))")
            exit(1)
        }
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LaunchAgent.plist(executable: executable, address: address, arguments: extra)
            .write(to: plist, atomically: true, encoding: .utf8)
        log("wrote \(plist.path)")
        log("it runs: \(executable) system \(address) \(extra.joined(separator: " "))")
        log("log: \(LaunchAgent.logPath)")
        log(
            "to load it now: launchctl unload \(plist.path) 2>/dev/null; launchctl load \(plist.path)"
        )
    case "remove":
        // Unload before deleting, and say what actually happened.
        //
        // Deleting the plist alone leaves the agent loaded and running: launchd already read the
        // file and does not care that it is gone. Measured 2026-11-09, the same mistake as `stop`
        // had — the command said "removed" and the stream kept playing.
        if FileManager.default.fileExists(atPath: plist.path) {
            try? LaunchAgent.unload()
            try FileManager.default.removeItem(at: plist)
            log("removed \(plist.path)")
        } else {
            try? LaunchAgent.unload()
            log("nothing to remove at \(plist.path)")
        }
        if LaunchAgent.isLoaded() {
            log(
                "it is still loaded — launchctl refused the unload; try `launchctl bootout gui/$(id -u) \(plist.path)`"
            )
        } else {
            log("and it is no longer loaded: nothing will start it again at login")
        }
    case "status":
        let installed = FileManager.default.fileExists(atPath: plist.path)
        log("plist: \(installed ? plist.path : "not installed")")
        let running = LaunchAgent.isRingMoving()
        log(
            "the audio device is \(running ? "being fed" : "NOT being fed") "
                + "(ring \(running ? "moving" : "idle") at /tmp/codecblue-ring)")
        if let text = try? String(contentsOfFile: LaunchAgent.logPath, encoding: .utf8) {
            let tail = text.split(separator: "\n").suffix(5).joined(separator: "\n")
            log("last lines of \(LaunchAgent.logPath):\n\(tail)")
        } else {
            log("no log at \(LaunchAgent.logPath) (never started?)")
        }
    default:
        log("usage: codecblue agent install|remove|status [address]")
        exit(2)
    }
}
