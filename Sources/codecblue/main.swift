// codecblue: command-line companion of the CodecBlue app.
//
//   codecblue version            Show component versions.
//   codecblue lookup ADDRESS     What bluetoothd knows about the headphones (read-only).
//   codecblue probe ADDRESS      Take the headphones over briefly, list the codecs they
//                                declare, then hand them back to macOS.
//   codecblue link ADDRESS       Time the link with the headphones idle (sniff or active?).
//   codecblue release ADDRESS    Recovery: drop the headphones' link and let macOS reconnect
//                                them normally.
//   codecblue play ADDRESS [FILE.wav] [--quality HQ|SQ|MQ] [--queue-ms 150]
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

@Sendable func log(_ message: String) {
    let t = Date().timeIntervalSince(start)
    FileHandle.standardError.write(Data(String(format: "[%7.3f] %@\n", t, message).utf8))
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: codecblue version
           codecblue lookup XX:XX:XX:XX:XX:XX
           codecblue probe  XX:XX:XX:XX:XX:XX
           codecblue play   XX:XX:XX:XX:XX:XX [FILE.wav] [--quality HQ|SQ|MQ] [--queue-ms N]
                            [--media-priority N] [--media-mtu N|0] [--sndbuf-packets N]
                            [--no-hfp] [--no-avrcp] [--low-latency] [--keep-link-quality] [--adapt] [--gain X]
           codecblue system  XX:XX:XX:XX:XX:XX [--quality HQ|SQ|MQ] [--queue-ms N]
                            (plays the CodecBlue virtual device)
           codecblue link    XX:XX:XX:XX:XX:XX
           codecblue tone    FILE.wav [SECONDS] [--sweep]  (a constant sine, or a sweep)
           codecblue flood   XX:XX:XX:XX:XX:XX [SECONDS] [BYTES] [--keep-link-quality]
           codecblue pace    XX:XX:XX:XX:XX:XX [SEC] [BYTES] [PKT/S] (diagnostic: paced rate)
           codecblue handlers device|general  (which handler answers each known message)
           codecblue agent   install|remove|status [ADDR] [options]
           codecblue audioprobe ADDR   (sends one known message; needs CODECBLUE_AUDIO_CHANNEL=yes)
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
    print("link: \(record.isLinkUp ? "up" : "down"), macOS audio device: \(SystemHeadphoneAudio.hasDevice(address: address) ? "yes" : "no")")
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
            if let caps = try? await signaling.command(.getCapabilities, Data([endpoint.seid << 2])) {
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
        log(String(format: "AVDTP round trip: min %.1f ms, median %.1f ms, max %.1f ms",
                   avdtpSorted[0] * 1000, avdtpSorted[avdtpSorted.count / 2] * 1000,
                   avdtpSorted[avdtpSorted.count - 1] * 1000))
        // One round trip per packet is what the media channel gets: with a link that answers
        // in ~100 ms, a 679-byte packet per round trip is ~54 kbps. That is the ceiling we
        // measure, and it comes from the link's latency, not from the codec or the bandwidth.
        let median = avdtpSorted[avdtpSorted.count / 2]
        log(String(format: "one packet per round trip would be %.0f kbps (679 bytes / %.0f ms)",
                   679.0 * 8 / median / 1000, median * 1000))

        let channel = try await takeover.openChannel(psm: AVCTPHolder.psm, label: "avrcp", timeout: 3)
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
        log(String(format: "idle round trip: min %.0f ms, median %.0f ms, max %.0f ms (%d samples)",
                   sorted[0] * 1000, sorted[sorted.count / 2] * 1000, sorted[sorted.count - 1] * 1000, sorted.count))
    } catch {
        log("link failed: \(error)")
        await takeover.handBack()
        throw error
    }
    log("handing the headphones back to macOS")
    await takeover.handBack()
}

func play(_ address: String, _ options: [String]) async throws {
    var quality = LDACEncoder.Quality.high
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
            guard let value = rest.popFirst(),
                  let q = LDACEncoder.Quality.allCases.first(where: { $0.name == value.uppercased() })
            else { usage() }
            quality = q
        case "--queue-ms":
            guard let value = rest.popFirst(), let ms = Double(value), ms >= 20, ms <= 2000 else { usage() }
            queueDuration = ms / 1000
        case "--media-priority":
            guard let value = rest.popFirst(), let priority = Int64(value), priority >= 0 else { usage() }
            mediaPriority = priority
        case "--sndbuf-packets":
            guard let value = rest.popFirst(), let packets = Int(value), (1...16).contains(packets) else { usage() }
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
            guard let value = rest.popFirst(), let mtu = Int(value), mtu == 0 || (LDACEncoder.minimumMTU...2000).contains(mtu)
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
    log(String(format: "%@: %.1f s at %d Hz", file ?? "test tone", audio.duration, audio.sampleRate))
    let mtuText = mediaMTU.map { "\($0)" } ?? "link"
    log("media: MTU \(mtuText), \(sendBufferPackets) packet(s) in the socket, priority \(mediaPriority), queue \(Int(queueDuration * 1000)) ms")

    var keeper: AudioStreamKeeper?
    if keepLinkQuality {
        // Must happen before the takeover: once we own the media channel bluetoothd unpublishes
        // the audio device and answers our messages with "No device found for uid".
        if let uuid = CBDeviceUUID.find(for: address) {
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
    // Ctrl-C: stop streaming; the normal path below then hands the headphones back.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler {
        log("interrupted: stopping")
        streamerBox.streamer?.stop()
        streamerBox.interrupted = true
    }
    interrupt.resume()

    do {
        let signaling = try await takeover.grabSignaling()
        if lowLatency, !takeover.requestHighPriority() {
            log("this macOS release does not expose the ACL-priority request; the link may stay in sniff")
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
            let configuration = try await streamer.setUp(sampleRate: audio.sampleRate, quality: quality)
            log("playing in LDAC \(configuration.quality.name)")
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
    let session = ClassicXPCSession(label: "handlers",
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
    _ = try await streamer.setUp(sampleRate: 48000, quality: .mobile)
    streamer.pace(seconds: seconds, packetSize: packetSize, packetsPerSecond: rate)
    await streamer.tearDown()
    log("handing the headphones back to macOS")
    await takeover.handBack()
}

func flood(_ address: String, seconds: Double, packetSize: Int, keepLinkQuality: Bool = false,
           uidSuffix: String = "tacl") async throws {
    // The link quality mode is a controller setting on the ACL connection, and our takeover
    // keeps that connection: so it is worth turning it on *before* taking the link, while
    // bluetoothd still has the audio device published. Once we own the media channel
    // bluetoothd unpublishes the device and refuses our messages with "No device found".
    var keeper: AudioStreamKeeper?
    if keepLinkQuality, let uuid = CBDeviceUUID.find(for: address) {
        keeper = AudioStreamKeeper(address: address, deviceUUID: uuid, period: 1,
                                   uidSuffix: uidSuffix, log: log)
        keeper?.start()
        log("asking bluetoothd for A2DP Link Quality Mode before taking the link (\(uuid), uid -\(uidSuffix))")
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
    _ = try await streamer.setUp(sampleRate: 48000, quality: .mobile)
    streamer.flood(seconds: seconds, packetSize: packetSize)
    await streamer.tearDown()
    log("handing the headphones back to macOS")
    await takeover.handBack()
}

/// Plays what the virtual device receives: reads the shared ring the driver fills and streams it
/// to the headphones. This is the whole point of the driver — any app that selects "CodecBlue"
/// as its output ends up here.
func playSystem(_ address: String, options: [String]) async throws {
    var quality = LDACEncoder.Quality.mobile
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
    var rest = options[...]
    while let option = rest.popFirst() {
        switch option {
        case "--quality":
            guard let value = rest.popFirst(),
                  let q = LDACEncoder.Quality.allCases.first(where: { $0.name == value.uppercased() })
            else { usage() }
            quality = q
        case "--queue-ms":
            guard let value = rest.popFirst(), let ms = Double(value), ms >= 20, ms <= 2000 else { usage() }
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
            guard let value = rest.popFirst(), let ppm = Double(value), abs(ppm) <= 2000 else { usage() }
            driftPPM = ppm
        default: usage()
        }
    }
    let ring: SharedRing
    do {
        ring = try SharedRing()
    } catch {
        log("\(error)")
        log("install the driver first: scripts/build-driver.sh --install")
        return
    }
    log("ring: \(ring.sampleRate) Hz, \(ring.channelCount) channels, \(ring.available) frames waiting")
    // Say it out loud when the device is selected but nothing is writing into it. Otherwise every
    // app plays into silence and nothing explains why — which cost real time once already.
    if ring.available == 0 {
        log("the ring is empty: if apps are playing and you hear nothing, the device is selected "
            + "but nothing is feeding it. Check that this process is running "
            + "(`codecblue agent status`), then play something.")
    }
    // The volume is applied here, not in the driver: see SystemVolume.
    let volume = SystemVolume()
    if let volume {
        // Report both numbers: the slider position and the gain it becomes. They differ by the
        // perceptual curve, and seeing both is how a wrong curve would be noticed.
        log(String(format: "volume: slider %.0f%% -> gain %.1f%%%@ (applied before the encoder)",
                   volume.reported * 100, volume.gain * 100,
                   volume.isMuted ? " — muted" : ""))
    } else {
        log("volume: the CodecBlue device is not the system output, so there is no volume to read")
    }

    var keeper: AudioStreamKeeper?
    if keepLinkQuality, let uuid = CBDeviceUUID.find(for: address) {
        keeper = AudioStreamKeeper(address: address, deviceUUID: uuid, period: 1, log: log)
        keeper?.start()
        log("asking bluetoothd for A2DP Link Quality Mode before taking the link (\(uuid))")
        try await Task.sleep(for: .seconds(3))
    }
    defer { keeper?.stop() }

    let takeover = HeadsetTakeover(address: address, log: log)
    let box = StreamerBox()
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler {
        log("interrupted: stopping")
        box.streamer?.stop()
        box.interrupted = true
    }
    interrupt.resume()

    let signaling = try await takeover.grabSignaling()
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
        say("media keys: codecblue-keys not found next to this binary, so the headphones' "
            + "play/pause/next will be refused instead of accepted")
    }
    streamer.onKey = { [volume, say, mediaKeys] key in
        switch key {
        case "volume_up", "volume_down":
            guard let volume else { return false }
            let delta: Float = key == "volume_up" ? 1.0 / 16 : -1.0 / 16
            if let position = volume.step(by: delta) {
                say(String(format: "headphone volume button: slider %.0f%% -> gain %.1f%%",
                           position * 100, volume.gain * 100))
                return true
            }
            say("headphone volume button: the device refused the change")
            return false
        case "play", "pause", "next", "previous", "stop":
            // `stop` has no media key of its own: pause is the closest thing the system has, and
            // pretending otherwise would need a second event nobody asked for.
            let command = key == "stop" ? "pause" : key
            guard let mediaKeys else {
                say("headphone button \(key): no media key helper, so nothing was sent")
                return false
            }
            mediaKeys.send(command)
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
    volume?.onChange = { [weak streamer] position in
        streamer?.setHeadphoneVolume(position)
    }
    // The push at start-up cannot happen here: `setUp` is what opens the AVRCP channel, and it
    // runs further down. Sending now would be a message to nobody — measured 2026-11-06, the
    // log showed no outgoing frame at all until the channel existed. So it is sent right after
    // `setUp`, below.
    streamer.onAbsoluteVolume = { [volume, say] value in
        guard let volume, let position = volume.set(position: value) else { return }
        say(String(format: "headphone volume: slider %.0f%% -> gain %.1f%%",
                   position * 100, volume.gain * 100))
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
    streamer.drainBoost = {
        let depth = ring.available
        let target = Int(cushionSeconds.value * Double(ring.sampleRate))
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
    // The throttle holds the *ring* at a small depth — the writer's jitter, not the link's
    // cushion. The link's cushion is the packet queue, which has its own adaptation.
    let ringTarget = 0.04
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
    streamer.gain = { volume?.gain ?? 1 }
    box.streamer = streamer
    // nil = take whatever the headphones offer; the device's own rate is only a preference.
    let configuration = try await streamer.setUp(sampleRate: ring.sampleRate, quality: quality)
    // Now the AVRCP channel exists, so the headphones can be told the volume the Mac is at.
    // Without this the two volumes are independent: the slider moves our gain and the headphones
    // keep their own attenuation, which is exactly what was reported.
    if let volume {
        streamer.setHeadphoneVolume(volume.reported)
        log(String(format: "headphones told to play at %.0f%% (the Mac's slider)", volume.reported * 100))
    }
    // The device runs at 48 kHz and the headphones may take 44.1: convert rather than refuse.
    let resampler = Resampler(from: ring.sampleRate, to: configuration.sampleRate)
    if !resampler.isIdentity {
        log("resampling \(ring.sampleRate) Hz -> \(configuration.sampleRate) Hz for the encoder")
    }
    log("playing the system output in LDAC \(configuration.quality.name)")
    // The ring is live: there is no end, only the next buffer. The streamer pulls from a closure
    // so that it can keep its own pacing and queue accounting.
    // Report the ring's own health: a skip is an audible click, so it must be visible.
    let monitor = Task.detached(priority: .utility) {
        var lastSkips = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let now = ring.skips
            // Report every window, not only the ones with a skip: "0 skips, 9 ms waiting" is the
            // evidence that the clicks are not the ring's fault, and silence proves nothing.
            let gain = volume?.gain ?? 1
            log(String(format: "ring: %d skip(s) in the last 2 s (%d total), %d frames waiting, gain %.1f%%",
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
            let deviceFrames = resampler.isIdentity
                ? frames
                : Int((Double(frames) * Double(ring.sampleRate) / Double(configuration.sampleRate)).rounded())
            var buffer = [Float](repeating: 0, count: deviceFrames * 2)
            let got = ring.read(into: &buffer, count: deviceFrames)
            guard got > 0 else { return [] }
            return resampler.process(Array(buffer[0..<(got * 2)]))
        })
    }.value
    await streamer.tearDown()
    log("handing the headphones back to macOS")
    await takeover.handBack()
    exit(0)
}

/// Writes the test tone as a WAV file, to play it through macOS's own A2DP and compare the
/// two streams on the same link.
func tone(_ path: String, seconds: Double, sweep: Bool = false) throws {
    // A constant sine, not an arpeggio: see WAVFile.sine. The old file changed note every 0.5 s
    // and jumped phase at each change, so it crackled on its own and made every link look bad.
    let audio = sweep
        ? WAVFile.sweep(sampleRate: 48000, seconds: seconds)
        : WAVFile.sine(sampleRate: 48000, seconds: seconds)
    try audio.write(to: URL(fileURLWithPath: path))
    log(String(format: "wrote %@: %.1f s at %d Hz, %@", path, audio.duration, audio.sampleRate,
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
        log("what you probably want is `codecblue play --keep-link-quality`, which is the safe path")
        return
    }
    guard let uuid = CBDeviceUUID.find(for: address) else {
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
    log("macOS has not published the headphones' audio yet; if it does not, put them in the case for a few seconds")
}

final class StreamerBox: @unchecked Sendable {
    var streamer: A2DPStreamer?
    var interrupted = false
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first, arguments.count) {
    case ("version", _):
        print("CodecBlue (development)")
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
        let seconds = arguments.count > 2 && !arguments[2].hasPrefix("--")
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
        try await flood(arguments[1], seconds: seconds, packetSize: size, keepLinkQuality: keep,
                        uidSuffix: suffix)
    case ("handlers", 2):
        try await handlers(arguments[1])
    case ("agent", 2...):
        // `agent install <address> [options]`, `agent remove`, `agent status`
        let action = arguments[1]
        let address = arguments.count > 2 && !arguments[2].hasPrefix("--") ? arguments[2] : nil
        let extra = address == nil ? [] : Array(arguments.dropFirst(3))
        try agent(action, address: address, extra: extra)
    case ("play", 2...): try await play(arguments[1], Array(arguments.dropFirst(2)))
    case ("system", 2...): try await playSystem(arguments[1], options: Array(arguments.dropFirst(2)))
    default: usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
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
            log("usage: codecblue agent install <address> [--quality MQ]")
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
        let repo = invoked.deletingLastPathComponent()          // .build/out/Products/Debug
            .deletingLastPathComponent()                        // .build/out/Products
            .deletingLastPathComponent()                        // .build/out
            .deletingLastPathComponent()                        // .build
            .deletingLastPathComponent()                        // the repository
        let stable = repo.appendingPathComponent(".build/debug/codecblue")
        let executable = FileManager.default.isExecutableFile(atPath: stable.path)
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
        log("to load it now: launchctl unload \(plist.path) 2>/dev/null; launchctl load \(plist.path)")
    case "remove":
        if FileManager.default.fileExists(atPath: plist.path) {
            try FileManager.default.removeItem(at: plist)
            log("removed \(plist.path)")
        } else {
            log("nothing to remove at \(plist.path)")
        }
        log("to unload it: launchctl unload \(plist.path) 2>/dev/null")
    case "status":
        let installed = FileManager.default.fileExists(atPath: plist.path)
        log("plist: \(installed ? plist.path : "not installed")")
        let running = LaunchAgent.isRingMoving()
        log("the audio device is \(running ? "being fed" : "NOT being fed") "
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
