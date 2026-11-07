import Foundation

/// Configures an LDAC stream on grabbed headphones and plays PCM to it.
public final class A2DPStreamer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let remoteSEID: UInt8
        public let sampleRate: Int
        public let quality: LDACEncoder.Quality
        public let mtu: Int
        public let delayReporting: Bool
    }

    public enum StreamError: Error, CustomStringConvertible {
        case noLDAC([String]), unsupportedRate(Int, [Int])
        public var description: String {
            switch self {
            case let .noLDAC(codecs):
                "the headphones offer no LDAC endpoint (they offer: \(codecs.joined(separator: ", "))). "
                + "LDAC has to be enabled in the headphones' own app, and not every pair supports it: "
                + "if these do not, this program cannot drive them — SBC and AAC are not implemented."
            case let .unsupportedRate(rate, rates): "the headphones do not take \(rate) Hz in LDAC (they take \(rates))"
            }
        }
    }

    public static let localSEID: UInt8 = 1

    private let takeover: HeadsetTakeover
    private let signaling: SignalingChannel
    private let log: @Sendable (String) -> Void
    private var media: MediaChannel?
    private let state = StreamState()
    public private(set) var configuration: Configuration?
    public var avrcp: AVCTPHolder?
    public var handsFree: HandsFreeHolder?

    /// How much audio may wait for the socket before the oldest is dropped.
    public var queueDuration: TimeInterval = 0.15
    /// The queue grows to this when the link stalls, and comes back down when it does not. The
    /// gap between the two is the whole point: low delay when the link is good, protection when
    /// it is not. See `PacketQueue.noteStall`.
    public var queueCeiling: TimeInterval = 0.4
    /// How far ahead of real time the encoder may run. The stream keeps this much audio in hand,
    /// which is what absorbs a stall in the link — and what is heard as delay.
    public var leadTime: TimeInterval = 0.04
    /// How much slower than real time to consume, as a fraction (0 = normal, 0.01 = 1% slower).
    ///
    /// This is how the cushion is rebuilt after it has been drained — by a device change, by the
    /// writer stopping for a while. Consuming at 99% instead of 100% refills a 250 ms cushion in
    /// about 25 s, and the 1% is spread over every sample so it is inaudible: no sample is ever
    /// dropped or repeated, the stream simply runs a shade slow until the cushion is back.
    ///
    /// Not a hard gate. Gating reads on a depth threshold deadlocks, because the reader waits
    /// for the writer to fill the cushion while the writer is what the reader is consuming —
    /// measured twice on 2026-11-06, the ring froze at 2848 frames against a 2880 threshold.
    public var paceSlowdown: (() -> Double)?

    /// Clock drift between the Mac and the headphones, in parts per million, applied by
    /// resampling the stream rather than by reading the ring more slowly.
    ///
    /// The symptom it exists for: watch a video and after a few minutes the sound is behind the
    /// picture, and stays further behind. Measured 2026-11-06 that our own buffers are *not*
    /// growing — cumulative delivery sat at 100.01% of real time, the ring held 1984 frames for
    /// 200 s, and the packet queue returned to 0 ms every few seconds. So the growing delay is
    /// in the headphones' own buffer: their crystal runs at a slightly different frequency from
    /// the Mac's, and if we deliver exactly real time while they play a shade slower, the
    /// difference accumulates on their side and is never given back.
    ///
    /// They never send a delay report (`delayReport` never arrives on these headphones), so
    /// there is no feedback to close the loop with: the correction has to be a standing bias.
    /// The direction is known from the symptom — audio falling behind means they are slower than
    /// us, so we must deliver *less* than real time.
    ///
    /// Why resampling and not a slower clock: the first attempt moved the clock anchor, which
    /// made us read fewer frames than the driver wrote and simply moved the growing delay into
    /// our own ring (measured: 2048 → 2750 frames, still climbing). Reading must stay at real
    /// time; only what we *deliver* may be shorter.
    public var driftPPM: Double = 0

    /// Called for every button on the headphones, by name ("play", "volume_up", ...).
    ///
    /// Until now the buttons were only logged, so the headphones' volume keys did nothing: the
    /// listener reported "non riesco ad aumentare e abbassare il volume tramite le cuffie".
    /// Called for every button; returns true when the press was acted on.
    public var onKey: (@Sendable (String) -> Bool)?

    /// The absolute volume the headphones asked for, 0…1, from SET ABSOLUTE VOLUME.
    public var onAbsoluteVolume: (@Sendable (Float) -> Void)?

    /// Sets the headphones' own attenuation, 0…1. Called when the Mac's slider moves.
    ///
    /// The headsets' volume keys do not reach us: measured 2026-11-06, pressing them produces no
    /// AVRCP frame at all — they move their own DSP. What they do send is a steady GET
    /// CAPABILITIES asking whether we support absolute volume. So the volume is ours to push
    /// down the link, and until now we never did: the slider moved the gain in our own mixer and
    /// the headphones stayed at whatever they were set to. That is the reported "mi aspettavo
    /// agisse direttamente sul volume del Mac" — the two were independent.
    public func setHeadphoneVolume(_ value: Float) {
        avrcp?.setAbsoluteVolume(value)
    }

    /// How much extra to read from the source, as a fraction of a block, to drain a backlog.
    ///
    /// The driver writes at the Mac's clock whether or not the link is keeping up, so a stall of
    /// `bluetoothd` (100–300 ms, several times a minute) leaves the ring holding that much extra
    /// audio — and nothing ever takes it back, because reading exactly real time preserves
    /// whatever surplus is already there. Measured 2026-11-06: one stall took the ring from 1984
    /// frames (41 ms) to 13 504 (281 ms), and it stayed at ~11 800 for the next two minutes. That
    /// is the reported "after a while the audio is behind the video".
    ///
    /// The surplus has to be *removed*, and the only way to remove audio without a gap is to play
    /// it slightly fast. So: read a little more than a block from the source and compress it back
    /// to exactly one block. The ring drains by the extra, the link still carries exactly real
    /// time, and the pitch rises by the same fraction — 1% is 0.17 of a semitone, which is not
    /// audible on speech or music.
    ///
    /// Reading more and *delivering* more would not work: that just moves the surplus into the
    /// headphones' buffer, which is the same delay one device further along.
    public var drainBoost: (() -> Double)?
    /// Called when the cushion changes, so the ring can hold exactly as much as the queue is
    /// allowed. The two are one number: the ring is where the audio waits, the queue is where it
    /// is committed, and a ring deeper than the queue just adds delay the queue never uses.
    public var cushionChanged: ((TimeInterval) -> Void)?
    /// When set, the quality level follows the link instead of staying where it started.
    public var adaptBitrate = false
    /// Applied to every frame just before encoding. The system volume lives here rather than in
    /// the driver because the driver is at the start of the chain: a change there has to travel
    /// through the ring and the queue before it is heard.
    ///
    /// It is applied *before* the codec, which is not free: attenuating and then encoding makes
    /// the codec work on a smaller signal than it was designed for. The alternative — attenuating
    /// after the codec — is not available, because the samples go straight into the A2DP packets.
    /// So the volume is a compromise: correct, but slightly rough at very low levels.
    public var gain: (() -> Float)?
    /// L2CAP MTU to use for media packets. The link offers 895, but a 895-byte PDU needs
    /// 3-DH5 on the air; 679 (the headphones' own A2DP MTU) also fits 2-DH5. `nil` uses the
    /// link's MTU.
    public var mediaMTU: Int? = 679
    /// Hold the hands-free channel while streaming (default). Turning it off is a
    /// diagnostic: an open HFP link may make the headphones keep the link in a low-power
    /// mode, which would cap the media throughput.
    public var holdHandsFree = true
    /// Hold AVRCP while streaming (default). Also the channel used to time the link.
    public var holdAVRCP = true
    /// Packets allowed to wait in the media socket at once (`SO_SNDBUF` in MTUs). 1 is the
    /// safe default: bluetoothd turns each read into one L2CAP SDU, so two packets in the
    /// buffer can be read, and sent, as one. More than 1 is a diagnostic: if throughput
    /// scales with it, the link is limited by per-packet latency, not by bandwidth.
    public var sendBufferPackets = 1
    /// `kCBL2CAPChannelPriority` for the media channel. 0 leaves bluetoothd's default; a
    /// higher value may make it ask the controller for a better link policy, which is what
    /// decides how much the link can actually carry.
    public var mediaPriority: Int64 = 0
    /// How often the streaming report is printed.
    public var reportInterval: TimeInterval = 2
    /// The first windows are shorter: at the start the adapter has to find out what the link
    /// carries, and a four-second wait means four seconds of audio thrown away if the starting
    /// level is too high. Half a second is enough to see the queue fill up.
    public var firstReportInterval: TimeInterval = 0.5
    /// How many short windows to use before settling on `reportInterval`.
    public var firstReports = 3
    /// Delay the headphones report (AVDTP delay reporting), for the latency figure.
    private var reportedDelay: TimeInterval = 0

    public init(takeover: HeadsetTakeover, signaling: SignalingChannel, log: @escaping @Sendable (String) -> Void) {
        self.takeover = takeover
        self.signaling = signaling
        self.log = log
        signaling.onCommand = { [weak self] message in self?.handleHeadphoneCommand(message) }
    }

    // MARK: - Setup

    /// - Parameter sampleRate: the rate to ask for, or nil to take the best the headphones offer.
    ///   A rate they do not support is not an error: the next one they do support is used, and
    ///   the log says so. See `StreamError.unsupportedRate` for the case where they offer none.
    public func setUp(sampleRate: Int?, quality: LDACEncoder.Quality) async throws -> Configuration {
        // Hold AVRCP before the media channel: some headphones refuse it afterwards (Bathys,
        // per Blue Bloom), and holding it keeps macOS from reconnecting its profiles.
        if holdAVRCP {
        do {
            let channel = try await takeover.openChannel(psm: AVCTPHolder.psm, label: "avrcp", timeout: 3)
            let holder = AVCTPHolder(socket: ChannelSocket(channel: channel, label: "avrcp"))
            // Byte-level tracing of the control channel, off unless asked for. It was on while
            // the AVRCP frames were being got right, and it is the only reason the malformed
            // frames were ever found — but it writes a line every two seconds forever, which
            // buries everything else in the log. `CODECBLUE_AVRCP_TRACE=1` brings it back.
            if ProcessInfo.processInfo.environment["CODECBLUE_AVRCP_TRACE"] == "1" {
                holder.onRaw = { [log] bytes in
                    let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    log("AVRCP \(bytes.first == 0xFF ? "out" : "in"): \(hex)")
                }
            }
            holder.registerVolumeNotifications()
            holder.onAbsoluteVolume = { [log, weak self] value in
                log(String(format: "headphone volume: absolute %.0f%%", value * 100))
                self?.onAbsoluteVolume?(value)
            }
            holder.onKey = { [log, weak self] key in
                log("headphone button: \(key)")
                return self?.onKey?(key) ?? false
            }
            avrcp = holder
            log("AVRCP channel held")
        } catch {
            log("AVRCP channel not available (\(error)); continuing")
        }
        }

        // Hold hands-free too, so macOS cannot publish a call device whose use would open a
        // SCO link and starve the stream.
        if holdHandsFree,
           let channel = takeover.record?.services.first(where: { $0.uuid16 == HandsFreeHolder.handsFreeServiceUUID })?.rfcomm,
           channel > 0 {
            do {
                let opened = try await takeover.openRFCOMM(channel: channel, label: "hfp", timeout: 5)
                let holder = HandsFreeHolder(socket: ChannelSocket(channel: opened, label: "hfp"))
                holder.onLog = log
                holder.onBattery = { [log] level in log("headphone battery: \(level)%") }
                handsFree = holder
                log("hands-free channel \(channel) held")
            } catch {
                log("hands-free channel \(channel) not available (\(error))")
            }
        }

        let endpoints = AVDTP.parseDiscover(try await signaling.command(.discover).payload)
        var offered: [String] = []
        var ldac: (seid: UInt8, rates: [Int], delay: Bool)?
        for endpoint in endpoints where endpoint.isSink && endpoint.mediaType == 0 {
            guard let reply = try? await signaling.command(.getCapabilities, Data([endpoint.seid << 2])) else { continue }
            let caps = AVDTP.parseCapabilities(reply.payload)
            guard let codec = caps.codec else { continue }
            offered.append(codec.name)
            if codec.name == "LDAC", codec.information.count >= 8 {
                ldac = (endpoint.seid, LDAC.rates(fromBits: codec.information[codec.information.startIndex + 6]),
                        caps.categories.contains(0x08))
            }
        }
        guard let ldac else { throw StreamError.noLDAC(offered) }
        // The rate the caller asked for is a preference, not a requirement: a device that only
        // takes 44.1 kHz is still a device we can drive. Falling back here is what makes this
        // work with headphones other than the ones it was developed on.
        let requested = sampleRate
        guard let chosen = requested.map({ ldac.rates.contains($0) ? $0 : nil })
                ?? ldac.rates.first,
              let info = LDAC.configuration(rate: chosen)
        else {
            throw StreamError.unsupportedRate(requested ?? 0, ldac.rates)
        }
        if let requested, requested != chosen {
            log("the headphones do not take \(requested) Hz in LDAC: using \(chosen) Hz instead "
                + "(they offer \(ldac.rates))")
        }
        let rate = chosen

        var payload = Data([ldac.seid << 2, Self.localSEID << 2, 0x01, 0x00, 0x07, UInt8(2 + info.count), 0x00, 0xFF])
        payload.append(info)
        if ldac.delay { payload.append(contentsOf: [0x08, 0x00]) }
        _ = try await signaling.command(.setConfiguration, payload)
        log("configured LDAC \(rate) Hz stereo on SEID \(ldac.seid)\(ldac.delay ? " (delay reporting)" : "")")

        _ = try await signaling.command(.open, Data([ldac.seid << 2]))
        let channel = try await takeover.openChannel(psm: AVDTP.psm, label: "media", priority: mediaPriority, timeout: 10)
        media = MediaChannel(channel: channel, mtu: mediaMTU, sendBufferPackets: sendBufferPackets)
        let buffers = media!.socketBuffers
        log("media channel open (link MTU \(channel.outMTU), using \(media!.mtu), \(media!.socketTypeName), "
            + "socket send buffer \(buffers.send), low water \(buffers.lowWater))")
        _ = try await signaling.command(.start, Data([ldac.seid << 2]))
        log("stream started")

        let configuration = Configuration(
            remoteSEID: ldac.seid, sampleRate: rate, quality: quality,
            mtu: media?.mtu ?? Int(channel.outMTU), delayReporting: ldac.delay
        )
        self.configuration = configuration
        return configuration
    }

    // MARK: - Streaming

    /// Plays interleaved stereo Float32 PCM in real time. Returns when it has all been sent,
    /// the headphones end the stream, or `stop()` is called.
    /// Plays audio that arrives from somewhere else — the virtual device's ring — instead of a
    /// file. `pull` is asked for `frames` stereo frames and returns what it has; an empty array
    /// means "nothing yet", which is silence, not the end of the stream.
    public func play(pulling pull: @escaping (Int) -> [Float]) throws {
        try playLoop(feed: { frames in
            let pulled = pull(frames)
            // An empty read is not silence to be sent: it means the writer has not produced this
            // audio yet. Padding it with zeros puts a gap in the stream — a click — and it is
            // what makes the cushion useless, because the cushion can only absorb a stall if the
            // audio is *held back*, not replaced. Returning nothing makes the loop wait for the
            // writer instead, which is exactly the behaviour a cushion needs.
            return pulled
        }, endless: true)
    }

    public func play(_ samples: [Float]) throws {
        // The feed is asked for `frames` at a time and must advance: an earlier version returned
        // `samples[0..<min(frames*2, count)]` every time, which both replayed the first block
        // forever and made the length probe (`feed(0).count`) zero — so `play` of a file sent
        // nothing at all and returned in 3 ms.
        var position = 0
        try playLoop(feed: { frames in
            let wanted = min(frames * 2, samples.count - position)
            guard wanted > 0 else { return [] }
            let chunk = Array(samples[position..<(position + wanted)])
            position += wanted
            return chunk
        }, endless: false, totalFrames: samples.count / 2)
    }

    private func playLoop(feed: (Int) -> [Float], endless: Bool, totalFrames: Int? = nil) throws {
        guard let configuration, let media else { return }
        // libldac sizes its output for the whole A2DP packet: RTP header + LDAC media header +
        // frames. Pass it the media MTU, not the payload room, or every packet it produces is
        // larger than the socket buffer and the socket reports full on every write.
        let encoder = try LDACEncoder(sampleRate: configuration.sampleRate, quality: configuration.quality,
                                      mtu: min(configuration.mtu, 1024))
        let rate = configuration.sampleRate
        let block = LDACEncoder.framesPerCall
        // Consecutive windows with no stall at all, needed before the queue narrows again.
        var cleanWindows = 0
        var queue = PacketQueue(sampleRate: rate, floorDuration: queueDuration,
                                ceilingDuration: max(queueCeiling, queueDuration))
        var meter = LinkMeter()
        var stats = StreamStatistics()
        // `--quality` is the ceiling: asking for MQ means "MQ is as good as I want", so the
        // adapter starts there and only probes upwards if the link has been clean for a while.
        // Starting at the ceiling is what removes the opening glitch: HQ on a link that carries
        // 500 kbps throws away half the audio for the first windows, and that is audible.
        var adapter = BitrateAdapter(ceiling: configuration.quality)
        if adaptBitrate, encoder.quality != configuration.quality {
            encoder.quality = configuration.quality
        }

        // A file has an end; the virtual device does not. `total` is only meaningful for a file.
        let total = endless ? Int.max : (totalFrames ?? feed(0).count / 2)
        var position = 0
        var sequence: UInt16 = 0
        var timestamp: UInt32 = 0
        var scratch = [Float](repeating: 0, count: block * 2)
        // Drift correction, by resampling.
        //
        // `driftPPM` shortens what we deliver without changing what we read: 100 ppm at 48 kHz is
        // 4.8 frames per second, which over ten minutes is 60 ms of delay the headphones would
        // otherwise accumulate and never give back. Reading must stay at real time — a first
        // attempt that slowed the clock instead simply moved the growing delay into our own ring
        // (measured 2048 → 2750 frames, still climbing).
        //
        let driftResampler = Resampler(ratio: 1 - driftPPM / 1_000_000)
        var driftFifo: [Float] = []
        driftFifo.reserveCapacity(block * 8)

        var start = DispatchTime.now().uptimeNanoseconds
        var lastReport = start
        var reportsSoFar = 0
        var lastProgress = start
        // The last sample of the previous block, held across an underrun instead of jumping to
        // zero. Declared here so the inner loop can reach it without allocating.
        // The last sample of each channel, held separately. A single `lastSample` was wrong in
        // two ways: it held the *right* channel (the last element of an interleaved block) and
        // then wrote it into both channels, so every underrun put the right channel's value into
        // the left one as well. That is heard as noise on the right — the channel whose value is
        // being smeared across the stereo field — and it is a DC plateau, so also a click.
        var lastLeft: Float = 0
        var lastRight: Float = 0
        // A read that came back short means the writer had not produced that audio yet, and the
        // block was padded by holding the last sample. That is a plateau in the waveform: it is
        // heard as distortion, and it is invisible in every other number in the report.
        var shortReads = 0
        var shortFrames = 0
        /// Set when the clock has been reset for an idle source, cleared when audio arrives.
        var resetWhileIdle = false
        avrcp?.measureRoundTrip()  // first sample: the link's latency, sniff or active
        // How far the encoder may run ahead of the clock. This — not the queue's budget — is
        // what actually decides how much audio is in hand: the queue stayed at 0–16 ms even with
        // a 250 ms budget, because the producer was only ever 40 ms ahead of real time. A queue
        // cannot hold what was never produced.
        //
        // So the cushion has to be built here, and it costs exactly its own length in delay.
        // 40 ms was enough for a link that never stalled; this one stops draining for up to
        // 300 ms, so the cushion must be at least that.
        let lead = leadTime

        // Cumulative check: how much audio we have actually put on the link versus how much
        // real time has passed. If the first grows faster than the second, the headphones are
        // being fed more audio than they play, and their buffer grows without bound — heard as
        // "after a while the audio is behind the video", which no per-window number shows
        // because every window looks healthy on its own.
        /// Fractional frames owed to the drain servo, carried between blocks.
        var drainCarry = 0.0
        var sentFramesTotal = 0
        let streamAnchor = DispatchTime.now().uptimeNanoseconds
        var lastLoop = DispatchTime.now().uptimeNanoseconds
        // A fade-out, not a cut.
        //
        // Stopping mid-waveform leaves a step from wherever the signal happened to be to zero,
        // and a step is a click — reported as "un piccolo fruscio sulla destra" when pausing.
        // The fill already holds the last sample, which is a plateau: better than a jump to zero
        // but still an edge. So when the stream is asked to stop, a short ramp is emitted before
        // the loop ends, long enough (5 ms) to be inaudible as a tone and short enough not to
        // delay the hand-back.
        var fadeRemaining = 0
        let fadeFrames = Int(0.005 * Double(rate))
        var fadeFrom: (Float, Float) = (0, 0)

        while !state.stopped || fadeRemaining > 0 {
            if state.stopped, fadeRemaining == 0, !queue.isEmpty || position > 0 {
                // Begin the fade from the last sample we produced.
                fadeFrom = (lastLeft, lastRight)
                fadeRemaining = fadeFrames
            }
            if fadeRemaining > 0 {
                // Emit the ramp as audio, through the same path as everything else: it has to be
                // encoded and queued like any other sound, or it is not a fade at all.
                // The gain is computed per *frame* across the whole fade, not per block: the
                // first version restarted the ramp inside each block and never reached zero,
                // which the self-test caught (it ended at 0.185, not 0).
                let done = fadeFrames - fadeRemaining
                var ramp = [Float](repeating: 0, count: block * 2)
                for i in 0..<block {
                    let position = done + i
                    let g = position >= fadeFrames
                        ? 0
                        : 1 - Float(position) / Float(fadeFrames)
                    ramp[i * 2] = fadeFrom.0 * g
                    ramp[i * 2 + 1] = fadeFrom.1 * g
                }
                fadeRemaining = max(0, fadeRemaining - block)
                if let output = try? ramp.withUnsafeBufferPointer({ try encoder.encode($0) }) {
                    let payload = Data([MediaPacket.ldacHeader(frameCount: output.frameCount)])
                        + output.payload
                    let packetFrames = output.frameCount * encoder.framesPerLDACFrame
                    queue.append(MediaPacket.rtp(sequence: sequence, timestamp: timestamp, ssrc: 1,
                                                 payload: payload),
                                 frames: packetFrames)
                    sentFramesTotal += packetFrames
                    sequence &+= 1
                    timestamp &+= UInt32(packetFrames)
                }
                if fadeRemaining == 0 { break }
                continue
            }
            let now = DispatchTime.now().uptimeNanoseconds
            // Consume a shade slower than real time when the cushion needs rebuilding. `start`
            // is what `due` is measured from, so nudging it forward by a fraction of the time
            // that passed makes the stream run slow without dropping or repeating a sample.
            if let slowdown = paceSlowdown?(), slowdown > 0 {
                let elapsed = now &- lastLoop
                start &+= UInt64(Double(elapsed) * min(slowdown, 0.05))
            }
            lastLoop = now
            if state.suspended {
                // The clock must not run while the stream is paused. `start` is what `due` is
                // measured from, so leaving it alone means that when the headphones say "start"
                // again the encoder believes a whole pause's worth of audio is due at once: it
                // floods the queue, the queue overflows, and the audio is heard fast-forwarded
                // and distorted. Measured 2026-11-06 after a pause: 406–452 kbps out of a
                // 330 kbps codec, `link took 121% of real time`, 280 short reads per window.
                //
                // Moving the anchor forward by the time spent paused makes the stream resume
                // where it stopped instead of trying to catch up.
                let paused = DispatchTime.now().uptimeNanoseconds
                usleep(5000)
                let resumed = DispatchTime.now().uptimeNanoseconds
                start &+= resumed &- paused
                lastReport &+= resumed &- paused
                lastProgress = resumed
                continue
            }

            // A resume invalidates whatever is queued: it is audio from before the pause, and
            // playing it is the fast-forward the listener hears. Drop it and refill from live.
            if state.flushQueue {
                state.flushQueue = false
                queue.removeAll()
                stats = StreamStatistics()
                log("queue flushed after the pause")
            }

            // Send first: a packet left in the queue while the socket is writable is a packet
            // the link was ready to carry. With a queue of 150-300 ms this is the difference
            // between "we offered audio" and "we offered audio only when the encoder happened
            // to be ahead".
            sending: while let entry = queue.first {
                switch media.send(entry.packet) {
                case .sent:
                    _ = queue.popFirst()
                    stats.record(packet: entry.packet.count, frames: entry.frames)
                    meter.accepted(frames: entry.frames)
                    meter.drained(at: now)
                case .full:
                    meter.stalled(at: now)
                    break sending
                case .closed:
                    // The headphones close the media channel when nothing has been sent for a
                    // while — their own power saving. Returning here ended the whole stream and
                    // handed the headphones back, so the next thing the listener heard was
                    // macOS's own output, or nothing at all: "ho fatto partire un video ma non
                    // sento nulla".
                    //
                    // Reopen instead. The stream is still configured; only the transport went
                    // away, and it comes back with one more channel.
                    log("media channel closed by the headphones: reopening")
                    guard reopenMediaChannel() else {
                        log("could not reopen the media channel: stopping")
                        return
                    }
                    continue
                }
            }

            // Encode what is due by now, as long as the queue has room for it.
            var due = min(Int((Double(now - start) / 1e9 + lead) * Double(rate)), total)
            // A pause in the *app* is not an AVDTP suspend: the headphones never say anything, so
            // `state.suspended` stays false and the anchor keeps running while the driver stops
            // writing. On resume the encoder then believes the whole pause is due at once.
            //
            // The source itself is the only witness: if nothing has arrived for longer than the
            // cushion, the stream was not flowing, and the clock must not be charged for it.
            // Measured 2026-11-06: 2–3 s of pause recovered fine by luck; 10 s produced
            // fast-forward, distortion and 280 short reads per window.
            if !resetWhileIdle, due - position > queue.maxFrames * 2 {
                let behind = Double(due - position) / Double(rate)
                // Re-anchor the clock at `now` and put the read position back to zero, because
                // `position` is measured *against* `start`: they are one pair and cannot be
                // moved independently.
                //
                // Two failed attempts, both recorded because each looked right:
                // - moving `start` forward by `due - position` put it ahead of `now`, so
                //   `now - start` underflowed a UInt64 and the process died with "arithmetic
                //   overflow" (crash 2026-11-06 19:30);
                // - jumping `position` to live while re-anchoring `start = now` left `position`
                //   far ahead of a `due` that had just restarted from zero, so nothing was ever
                //   due again: the ring filled to 48000 and the stream went silent (19:35).
                position = 0
                start = now
                lastReport = now
                queue.removeAll()
                stats = StreamStatistics()
                // Once per idle stretch: without this the condition is still true on the next
                // iteration (position cannot advance while the ring is empty) and the log filled
                // with one reset every half second.
                resetWhileIdle = true
                log(String(format: "source was idle for %.1f s: the clock is reset, not caught up",
                           behind))
            }
            // Two different reasons can put the encoder behind the clock, and they need opposite
            // answers:
            //
            // - the *link* is slow, so the queue is full and cannot take more: skip the audio
            //   that is already stale rather than send it late. A growing delay is worse than a
            //   gap for live audio, and this is what the report counts as dropped.
            // - the *source* is slow, so there is simply nothing to read yet: wait. Skipping here
            //   throws away audio that was never late, and it is what made the report read
            //   "dropped 100%" while the ring was fine.
            //
            // The queue being full is what tells them apart.
            if !queue.hasRoom, due - position > queue.maxFrames {
                let skip = min(due - position - block, total - position)
                position += skip
                stats.record(droppedFrames: skip)
            }
            while queue.hasRoom, position < due {
                let count = min(block, total - position)
                // Read a little extra when the source is holding a backlog, and compress it back
                // to one block below. See `drainBoost`.
                // The fraction has to be accumulated, not truncated: at 0.36% of a 128-frame
                // block the extra is 0.46 frames, and `Int(...)` made that 0 — the servo was
                // running and doing nothing. Measured 2026-11-06: the ring sat at 3400 frames
                // against a 2880 target for two minutes with the boost computed every block.
                let boost = max(0, min(0.05, drainBoost?() ?? 0))
                drainCarry += Double(count) * boost
                let extra = Int(drainCarry)
                drainCarry -= Double(extra)
                let chunk = feed(count + extra)
                // Nothing to send yet: the writer is behind. Wait for it rather than inventing
                // audio — the queue is the cushion, and a cushion that gets filled with silence
                // is not a cushion. Break out of the encode loop; the send loop above keeps
                // draining what is already queued, so the link stays fed.
                if chunk.isEmpty {
                    usleep(2000)
                    break
                }
                // Audio is arriving again: the idle stretch is over.
                resetWhileIdle = false
                let level = gain?() ?? 1
                // A short chunk is not the same as silence: the ring returns fewer frames than
                // asked when the writer has not caught up, and the rest must be *repeated*, not
                // zeroed. Zeroing mid-block puts a step in the waveform at every underrun, which
                // is heard as a click — and it is exactly what "gracchia" was.
                if chunk.count < count * 2 {
                    shortReads += 1
                    shortFrames += count - chunk.count / 2
                }
                // Compress the extra frames back into exactly one block. The read was
                // `count + extra` frames; the block must be `count`, or the link would carry more
                // than real time and the surplus would simply change address.
                let readFrames = chunk.count / 2
                let compressing = readFrames > count
                for i in 0..<(block * 2) {
                    if compressing, i / 2 < count {
                        // Linear interpolation across the whole read, so the block is exactly
                        // `count` frames of the `readFrames` that came in.
                        let p = Double(i / 2) * Double(readFrames) / Double(count)
                        let index = min(Int(p), readFrames - 1)
                        let next = min(index + 1, readFrames - 1)
                        let f = Float(p - Double(index))
                        let a = chunk[index * 2 + (i % 2)]
                        let b = chunk[next * 2 + (i % 2)]
                        scratch[i] = (a + (b - a) * f) * level
                    } else if i < chunk.count {
                        scratch[i] = chunk[i] * level
                    } else {
                        // Hold each channel at its own last value: a plateau per channel is a
                        // far smaller step than a channel swap.
                        scratch[i] = (i % 2 == 0 ? lastLeft : lastRight) * level
                    }
                }
                if chunk.count >= 2 {
                    lastLeft = chunk[chunk.count - 2]
                    lastRight = chunk[chunk.count - 1]
                }
                position += count
                // Shorten what we deliver, without changing what we read.
                //
                // The headphones consume frames from their own buffer at the rate of their own
                // crystal. Delivering 48 000 frames per second to a device that plays 47 995 is a
                // buffer that grows by 4.8 frames a second and never gives them back: that is the
                // sound falling behind the picture. So the *frame rate* has to drop, not the
                // pitch — which is why this is a resampler and not a frame dropped here and
                // there. Dropping a frame was tried and measured: it changes what the 128 frames
                // contain, not how many arrive, so the buffer grew exactly as before.
                //
                // The fifo is what lets a block that resamples to 127.987 frames still be encoded
                // in whole blocks of 128: the fraction waits for the next block, and once every
                // ~78 blocks there is one frame too few to encode, so that iteration emits
                // nothing. That is the rate reduction, and it is 0.01%.
                // One ratio does both jobs: the standing bias for the headphones' crystal, and
                // the servo that pulls the ring back to its target after a stall.
                let ratio = 1 - driftPPM / 1_000_000
                if abs(ratio - 1) > 1e-9 {
                    driftResampler.ratio = ratio
                    driftFifo.append(contentsOf: driftResampler.process(scratch))
                    guard driftFifo.count >= block * 2 else { continue }
                    for i in 0..<(block * 2) { scratch[i] = driftFifo[i] }
                    driftFifo.removeFirst(block * 2)
                }
                guard let output = try scratch.withUnsafeBufferPointer({ try encoder.encode($0) }) else { continue }
                let payload = Data([MediaPacket.ldacHeader(frameCount: output.frameCount)]) + output.payload
                let packetFrames = output.frameCount * encoder.framesPerLDACFrame
                queue.append(MediaPacket.rtp(sequence: sequence, timestamp: timestamp, ssrc: 1, payload: payload),
                             frames: packetFrames)
                sentFramesTotal += packetFrames
                sequence &+= 1
                timestamp &+= UInt32(packetFrames)
            }

            stats.record(droppedFrames: queue.takeDroppedFrames())

            let interval = reportsSoFar < firstReports ? firstReportInterval : reportInterval
            if now &- lastReport >= UInt64(interval * 1e9) {
                let window = max(Double(now - lastReport) / 1e9, 0.001)
                let dropped = stats.droppedFraction(sampleRate: encoder.sampleRate, window: window)
                let fill = queue.queuedDuration / max(queueDuration, 0.001)
                // The queue's own adaptation, *before* the report: report() resets the stall
                // counter, so asking afterwards always said "no stalls" and the queue never
                // widened. That is why a 135 ms stall kept overflowing a 60 ms budget.
                // A stall only justifies more room if it was long enough to overflow the
                // current budget: a 2 ms refusal is absorbed by any queue and widening for it
                // just adds delay. And narrowing needs several clean windows in a row, or the
                // queue flaps between two sizes on a link that is merely uneven — which is
                // exactly what the first version did.
                let stallSeconds = meter.stallSeconds
                let longest = meter.longestStall
                // Widen only when the stall *outlasted* the cushion: a 46 ms refusal is
                // absorbed by an 80 ms cushion and needs no more room. The earlier rule was
                // "half the cushion", which widened for stalls the cushion already covered —
                // measured 2026-11-06, a 46 ms stall pushed 80 ms to 160, then 81 ms pushed it
                // to 320, and since the link stalls in every window it never came back down.
                // Latency stayed at 320 ms for a link whose worst stall was 104 ms.
                let needsRoom = longest >= queue.maxDuration * 0.9
                // Measured against a fixed anchor, not against `start`: the pace bias moves
                // `start` forward on purpose, so using it here would make the bias hide itself
                // (it read 100.01% while actually delivering 99.99%).
                let elapsedSinceStart = Double(now - streamAnchor) / 1e9
                let drift = elapsedSinceStart > 1
                    ? Double(sentFramesTotal) / (elapsedSinceStart * Double(encoder.sampleRate))
                    : nil
                report(stats: &stats, meter: &meter, queue: queue, encoder: encoder,
                       now: now, lastReport: lastReport,
                       shortReadsInWindow: shortReads, shortFramesInWindow: shortFrames,
                       driftFraction: drift)
                shortReads = 0
                shortFrames = 0
                if needsRoom {
                    cleanWindows = 0
                    if queue.noteStall() {
                        log(String(format: "cushion: widened to %.0f ms (a %.0f ms stall)",
                                   queue.maxDuration * 1000, longest * 1000))
                        cushionChanged?(queue.maxDuration)
                    }
                } else if stallSeconds > 0 {
                    cleanWindows = 0
                } else {
                    cleanWindows += 1
                    if cleanWindows >= 5, queue.relax() {
                        cleanWindows = 0
                        log(String(format: "cushion: back to %.0f ms after %d clean windows",
                                   queue.maxDuration * 1000, 5))
                        cushionChanged?(queue.maxDuration)
                    }
                }
                if adaptBitrate {
                    switch adapter.decide(current: encoder.quality, dropped: dropped, queueFill: fill) {
                    case .hold:
                        break
                    case let .down(quality):
                        encoder.quality = quality
                        log(String(format: "bitrate: down to LDAC %@ (%.0f%% dropped, queue %.0f%%)",
                                   quality.name, dropped * 100, fill * 100))
                    case let .up(quality):
                        encoder.quality = quality
                        log("bitrate: up to LDAC \(quality.name) (the link has been clean)")
                    }
                }
                reportsSoFar += 1
                lastReport = now
            }
            // End of the audio. The queue can still hold packets the socket has not taken, and
            // the loop must not exit while it does, or the tail is cut. But it must exit: a
            // queue that never empties (the socket refusing the last packets) used to keep the
            // process alive forever, spinning after the music had stopped.
            if position >= total {
                if queue.isEmpty { break }
                if now &- lastProgress >= UInt64(2e9) {
                    log("the socket stopped taking the last packets: dropping \(queue.count) and stopping")
                    queue.removeAll()
                    break
                }
            } else {
                lastProgress = now
            }
            usleep(2000)
        }
    }

    /// What the report shows, and why each number is there:
    ///
    /// * `accepted` is what the socket took (audio time, as a fraction of the window). This is
    ///   the link's real capacity as far as we can see it: 1.0 means the link keeps up.
    /// * `dropped` is the audio that had to be thrown away to keep the delay bounded.
    /// * `full` is how often and how long the socket refused a packet: a link that stalls and
    ///   then catches up looks different from one that is uniformly slow.
    private func report(stats: inout StreamStatistics, meter: inout LinkMeter, queue: PacketQueue,
                        encoder: LDACEncoder, now: UInt64, lastReport: UInt64,
                        shortReadsInWindow: Int = 0, shortFramesInWindow: Int = 0,
                        driftFraction: Double? = nil) {
        let window = max(Double(now - lastReport) / 1e9, 0.001)
        let accepted = meter.takeFraction(sampleRate: encoder.sampleRate, window: window)
        var line = String(
            format: "streaming: %.0f kbps out, %.0f packets/s, link took %.0f%% of real time (codec %@ %d kbps)",
            stats.sentKbps(window: window), stats.packetsPerSecond(window: window),
            accepted * 100, encoder.quality.name, encoder.bitrateKbps
        )
        line += String(format: ", queue %.0f ms", queue.queuedDuration * 1000)
        if stats.droppedFrames > 0 {
            line += String(format: ", dropped %.0f%%", stats.droppedFraction(sampleRate: encoder.sampleRate, window: window) * 100)
        }
        if meter.stalls > 0 {
            line += String(format: ", socket full %d times (%.0f ms, longest %.0f ms), at most %d packet(s) per drain",
                           meter.stalls, meter.stallSeconds * 1000, meter.longestStall * 1000, meter.longestBurst)
        }
        if let rtt = avrcp?.roundTrip {
            line += String(format: ", AVRCP round trip %.0f ms", rtt * 1000)
            avrcp?.measureRoundTrip()
        }
        if reportedDelay > 0 { line += String(format: ", headphones' delay %.0f ms", reportedDelay * 1000) }
        // Cumulative drift: audio sent against real time since the stream started. Above 100%
        // the headphones are being fed faster than they play, so their buffer grows and the
        // sound falls further behind the picture — the one failure a per-window report cannot
        // show, because each window is internally consistent.
        if let drift = driftFraction {
            line += String(format: ", sent %.2f%% of real time since start", drift * 100)
        }
        if shortReadsInWindow > 0 {
            line += String(format: ", %d short read(s) (%d frames held: the writer is behind)",
                           shortReadsInWindow, shortFramesInWindow)
        }
        log(line)
        if stats.linkIsTheBottleneck {
            log("the link takes less audio than the codec produces: this is the Bluetooth link, not the encoder.")
        }
        let systemDevices = SystemHeadphoneAudio.devices(address: takeover.address)
        if !systemDevices.isEmpty { log("macOS audio devices for the headphones: \(systemDevices)") }
        stats = StreamStatistics()
        meter.resetStalls()
    }

    /// Diagnostic: offers `packetsPerSecond` packets of a fixed size, evenly spaced, and reports
    /// how many the socket took. This separates "the link cannot carry it" (refusals at a rate
    /// the link should manage) from "we offered it in bursts" (refusals clustered, then idle).
    public func pace(seconds: TimeInterval, packetSize: Int, packetsPerSecond: Double) {
        guard let media else { return }
        let size = min(max(64, packetSize), media.mtu)
        let payload = Data([MediaPacket.ldacHeader(frameCount: 3)]) + Data(repeating: 0xAA, count: size - 13)
        let interval = 1.0 / packetsPerSecond
        let start = DispatchTime.now().uptimeNanoseconds
        var sequence: UInt16 = 0
        var sent = 0, refused = 0, bytes = 0
        var lastReport = start, lastSent = 0, lastRefused = 0
        log(String(format: "pace: %d-byte packets at %.0f/s (%.0f kbps offered) for %.0f s",
                   size, packetsPerSecond, Double(size) * packetsPerSecond * 8 / 1000, seconds))
        var due = start
        while !state.stopped, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 < seconds {
            let now = DispatchTime.now().uptimeNanoseconds
            if now < due { usleep(200); continue }
            due = due &+ UInt64(interval * 1e9)
            let packet = MediaPacket.rtp(sequence: sequence, timestamp: UInt32(sequence) * 384, ssrc: 1, payload: payload)
            switch media.send(packet) {
            case .sent:
                sequence &+= 1
                sent += 1
                bytes += packet.count
            case .full:
                refused += 1
            case .closed:
                log("pace: media channel closed by the headphones")
                return
            }
            if Double(now - lastReport) / 1e9 >= 1 {
                let window = Double(now - lastReport) / 1e9
                log(String(format: "pace: took %.0f/s, refused %.0f/s (%.0f kbps out)",
                           Double(sent - lastSent) / window, Double(refused - lastRefused) / window,
                           Double(bytes) * 8 / Double(now - start) / 1e6))
                lastReport = now
                lastSent = sent
                lastRefused = refused
            }
        }
        let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        log(String(format: "pace: offered %.0f/s, took %.0f/s, refused %.0f/s = %.0f kbps",
                   packetsPerSecond, Double(sent) / total, Double(refused) / total,
                   Double(bytes) * 8 / total / 1000))
    }

    public func flood(seconds: TimeInterval, packetSize: Int) {
        guard let media else { return }
        // No LDAC here, so no libldac minimum: any size the media MTU allows.
        let size = min(max(64, packetSize), media.mtu)
        let payload = Data([MediaPacket.ldacHeader(frameCount: 3)]) + Data(repeating: 0xAA, count: size - 13)
        let start = DispatchTime.now().uptimeNanoseconds
        var sequence: UInt16 = 0
        var sent = 0
        var refused = 0
        var bytes = 0
        var lastReport = start
        var lastSent = 0
        var lastBytes = 0
        log("flood: \(size)-byte packets for \(Int(seconds)) s, as fast as the socket takes them")
        while !state.stopped, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 < seconds {
            let packet = MediaPacket.rtp(sequence: sequence, timestamp: UInt32(sequence) * 384, ssrc: 1, payload: payload)
            switch media.send(packet) {
            case .sent:
                sequence &+= 1
                sent += 1
                bytes += packet.count
            case .full:
                refused += 1
                usleep(500)
            case .closed:
                log("flood: media channel closed by the headphones")
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if Double(now - lastReport) / 1e9 >= 1 {
                let window = Double(now - lastReport) / 1e9
                let perSecond = Double(sent - lastSent) / window
                // Per window, not cumulative: the cumulative figure hides a link that has
                // stalled, and dividing nanoseconds by 1e6 printed a flat 0.
                let kbps = Double(bytes - lastBytes) * 8 / window / 1000
                log(String(format: "flood: %.0f packets/s, %.0f kbps, %d refused so far", perSecond,
                           kbps, refused))
                lastReport = now
                lastSent = sent
                lastBytes = bytes
            }
        }
        let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        log(String(format: "flood: %d packets in %.1f s = %.0f packets/s, %.0f kbps, %d refused",
                   sent, total, Double(sent) / total, Double(bytes) * 8 / total / 1000, refused))
    }

    public func stop() { state.stopped = true }

    /// Closes the stream politely (CLOSE, else ABORT) and the media channel.
    public func tearDown() async {
        state.stopped = true
        if let seid = configuration?.remoteSEID {
            do {
                _ = try await signaling.command(.close, Data([seid << 2]), timeout: 2)
            } catch {
                _ = try? await signaling.command(.abort, Data([seid << 2]), timeout: 2)
            }
        }
        media?.close()
        media = nil
        avrcp?.close()
        avrcp = nil
        handsFree?.close()
        handsFree = nil
    }

    // MARK: - Commands from the headphones

    /// Reopens the media channel after the headphones closed it, keeping the configuration.
    /// Returns false if the link is gone for good.
    private func reopenMediaChannel() -> Bool {
        media?.close()
        media = nil
        // Give the headphones a moment: they close the channel as part of going idle, and
        // reopening immediately is refused.
        usleep(300_000)
        guard let seid = configuration?.remoteSEID else { return false }
        // The loop that calls this is synchronous (it is the real-time send path), so the async
        // reopen is awaited through a semaphore. `ReopenResult` carries the outcome out of the
        // task: a captured `var` would be a data race, which is what the compiler refused.
        let semaphore = DispatchSemaphore(value: 0)
        let result = ReopenResult()
        let takeover = self.takeover
        let signaling = self.signaling
        let mtu = mediaMTU
        let packets = sendBufferPackets
        let log = self.log
        Task.detached {
            do {
                let channel = try await takeover.openChannel(psm: AVDTP.psm, label: "media",
                                                             priority: 63, timeout: 10)
                await MainActor.run {
                    result.channel = MediaChannel(channel: channel, mtu: mtu,
                                                  sendBufferPackets: packets)
                }
                _ = try await signaling.command(.start, Data([seid << 2]))
                result.opened = true
            } catch {
                log("reopening the media channel failed: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        media = result.channel
        return result.opened
    }

    private func handleHeadphoneCommand(_ message: AVDTP.Message) {
        switch message.signal {
        case .delayReport:
            let p = [UInt8](message.payload)
            if p.count >= 3 {
                reportedDelay = Double(UInt16(p[1]) << 8 | UInt16(p[2])) / 10 / 1000
                log(String(format: "headphones report a delay of %.1f ms", reportedDelay * 1000))
            }
            signaling.reply(to: message, accept: true)
        case .suspend:
            state.suspended = true
            log("headphones suspended the stream")
            signaling.reply(to: message, accept: true)
        case .start:
            state.suspended = false
            // The audio sitting in the queue is from before the pause: playing it after the
            // resume is the "fast-forward" the listener hears. Throw it away and let the queue
            // refill from the live source.
            state.flushQueue = true
            log("headphones restarted the stream")
            signaling.reply(to: message, accept: true)
        case .close, .abort:
            log("headphones closed the stream")
            state.stopped = true
            signaling.reply(to: message, accept: true)
        case .discover:
            // Our single source endpoint: SEID 1, in use, audio source.
            signaling.reply(to: message, accept: true, payload: Data([Self.localSEID << 2 | 0x02, 0x00]))
        default:
            signaling.reply(to: message, accept: false, payload: Data([0x13]))  // not supported
        }
    }
}

/// Flags shared between the streaming thread and signaling callbacks.
private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var _stopped = false
    private var _suspended = false
    /// Set when the stream resumes: the queued audio predates the pause and must not be played.
    private var _flushQueue = false
    var stopped: Bool {
        get { lock.withLock { _stopped } }
        set { lock.withLock { _stopped = newValue } }
    }

    var flushQueue: Bool {
        get { lock.withLock { _flushQueue } }
        set { lock.withLock { _flushQueue = newValue } }
    }

    var suspended: Bool {
        get { lock.withLock { _suspended } }
        set { lock.withLock { _suspended = newValue } }
    }
}

/// The outcome of reopening the media channel, carried out of the async task that does it.
/// A captured `var` would be a data race, which is what the compiler refused.
final class ReopenResult: @unchecked Sendable {
    var opened = false
    var channel: MediaChannel?
}
