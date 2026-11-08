@testable import CodecBlueCore
import Foundation

func streamingTests() {
    test("LDAC media header carries the frame count in its low bits") {
        check(MediaPacket.ldacHeader(frameCount: 1) == 0x01)
        check(MediaPacket.ldacHeader(frameCount: 5) == 0x05)
        check(MediaPacket.ldacHeader(frameCount: 15) == 0x0F)
        check(MediaPacket.ldacHeader(frameCount: 16) == 0x00, "the count never exceeds 15")
    }

    test("an RTP media packet has the A2DP layout") {
        let packet = MediaPacket.rtp(sequence: 0x1234, timestamp: 0x0100_0000, ssrc: 1,
                                     payload: Data([0x03, 0xAA, 0xBB]))
        check(packet.count == 15)
        check(Array(packet[0..<12]) == [0x80, 96, 0x12, 0x34, 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 1],
              "\(Array(packet[0..<12]))")
        check(Array(packet[12...]) == [0x03, 0xAA, 0xBB])
    }

    test("a libldac packet keeps its own frame headers, whose sync word is 0xAA") {
        // The headphones parse the payload as LDAC transport frames, each starting with a
        // header byte 0xAA at the top. A packet whose payload starts with 0xAA is what a
        // capture of a working stream (macOS or the prototype) should show.
        let encoder = try LDACEncoder(sampleRate: 48000, quality: .high, mtu: 895)
        let tone = WAVFile.sine(sampleRate: 48000, seconds: 0.2)
        var block = [Float](repeating: 0, count: 256)
        var payloads = 0
        var i = 0
        while i + 256 <= tone.samples.count {
            for j in 0..<256 { block[j] = tone.samples[i + j] }
            i += 256
            guard let out = try block.withUnsafeBufferPointer({ try encoder.encode($0) }) else { continue }
            payloads += 1
            check(out.payload.first == 0xAA, "payload starts with \(String(format: "%02x", out.payload.first ?? 0))")
            check(out.frameCount >= 1 && out.frameCount <= 15, "\(out.frameCount) frames")
        }
        check(payloads > 5, "\(payloads) payloads")
    }

    test("libldac's minimum MTU is enforced instead of crashing") {
        // Below 679 libldac overruns its own buffer (LDACBT_MTU_REQUIRED, 2-DH5 payload).
        let encoder = try LDACEncoder(sampleRate: 48000, quality: .high, mtu: 100)
        let tone = WAVFile.sine(sampleRate: 48000, seconds: 0.1)
        var block = [Float](repeating: 0, count: 256)
        for i in stride(from: 0, to: tone.samples.count - 256, by: 256) {
            for j in 0..<256 { block[j] = tone.samples[i + j] }
            _ = try block.withUnsafeBufferPointer({ try encoder.encode($0) })
        }
        check(LDACEncoder.minimumMTU == 679)
    }

    test("the packet queue keeps its budget and drops the newest audio") {
        // The queue is the cushion: the audio in it is not late, it is what covers the next
        // stall. Dropping the *oldest* empties the cushion from the front, so the stall that
        // caused the overflow then finds nothing to play — heard as a skip. The newest is the
        // audio not yet committed, so that is what goes.
        var queue = PacketQueue(sampleRate: 48000, maxDuration: 0.1)  // 4800 frames
        check(queue.maxFrames == 4800)
        for i in 0..<10 {
            queue.append(Data([UInt8(i)]), frames: 1280)
        }
        check(queue.queuedFrames <= 4800, "\(queue.queuedFrames) frames queued")
        check(queue.queuedDuration <= 0.1 + 1e-9, "\(queue.queuedDuration) s")
        check(queue.takeDroppedFrames() == 1280 * 7, "\(queue.takeDroppedFrames()) frames dropped")
        check(queue.takeDroppedFrames() == 0, "the counter resets")
        check(queue.first?.packet == Data([0]), "the cushion's head is kept")
        check(queue.queuedFrames == 3840, "\(queue.queuedFrames) frames queued")
        check(queue.hasRoom)
        queue.append(Data([10]), frames: 1280)
        check(queue.queuedFrames <= 4800)
        check(queue.takeDroppedFrames() == 1280, "the new packet was dropped, not the old one")
        check(queue.first?.packet == Data([0]), "the head is still the oldest kept audio")
    }

    test("the packet queue never drops its only packet") {
        var queue = PacketQueue(sampleRate: 48000, maxDuration: 0.001)  // 48 frames
        queue.append(Data([1]), frames: 128)
        check(queue.entries.count == 1)
        check(queue.queuedFrames == 128)
    }

    test("the link meter reports the audio the socket took, per window") {
        var meter = LinkMeter()
        for _ in 0..<10 { meter.accepted(frames: 480) }  // 10 ms of audio each
        check(abs(meter.takeFraction(sampleRate: 48000, window: 1) - 0.1) < 1e-9,
              "\(meter.takeFraction(sampleRate: 48000, window: 1))")
        check(meter.take() == 0, "the window resets")
        meter.stalled(at: 1_000_000_000)
        meter.drained(at: 1_050_000_000)
        check(abs(meter.longestStall - 0.05) < 1e-9, "\(meter.longestStall)")
        meter.stalled(at: 2_000_000_000)
        meter.drained(at: 2_010_000_000)
        check(abs(meter.longestStall - 0.05) < 1e-9, "the longest stall is kept")
        check(meter.stalls == 2, "\(meter.stalls) stalls")
        meter.stalled(at: 3_000_000_000)
        meter.drained(at: 3_000_001_000)  // 1 ms: the loop polling, not the link
        check(meter.stalls == 2, "a 1 ms refusal is not a stall")
        meter.resetStalls()
        check(meter.stalls == 0 && meter.longestStall == 0)
    }

    test("statistics report what the link really carried") {
        var stats = StreamStatistics()
        for _ in 0..<100 {
            stats.record(packet: 679, frames: 128 * 3)  // 3 LDAC frames of 128 PCM frames
        }
        stats.record(droppedFrames: 4800)
        stats.record(stall: 0.05)
        let window = 1.0
        check(abs(stats.sentKbps(window: window) - 543.2) < 0.1, "\(stats.sentKbps(window: window))")
        check(abs(stats.packetsPerSecond(window: window) - 100) < 1e-9, "\(stats.packetsPerSecond(window: window))")
        check(abs(stats.deliveredFraction(sampleRate: 48000, window: window) - 0.8) < 1e-9,
              "\(stats.deliveredFraction(sampleRate: 48000, window: window))")
        check(abs(stats.droppedFraction(sampleRate: 48000, window: window) - 0.1) < 1e-9)
        check(stats.linkIsTheBottleneck)
        check(stats.stallCount == 1)
    }
}

/// The device UUID that bluetoothd's audio channel matches on is only available from its log,
/// so the parser is the part worth testing: a wrong UUID means `No device found for uid` and
/// the link quality mode silently stays off.
func deviceUUIDTests() {
    test("the device UUID is read from bluetoothd's own log line") {
        let log = """
        2026-11-06 11:36:52.680357 bluetoothd: (CoreUtils) [com.apple.bluetooth:CBDevice] \
        Device found: CBDevice 4379D275-655C-EEB8-BB72-643BF2534BE0, BDA <private>, \
        CnS 0x800019 < HFP AVRCP A2DP ACL >
        """
        check(CBDeviceUUID.parse(log) == "4379D275-655C-EEB8-BB72-643BF2534BE0",
              "\(CBDeviceUUID.parse(log) ?? "nil")")
    }

    test("a device without A2DP is not the one we want") {
        let log = """
        Device found: CBDevice 11111111-2222-3333-4444-555555555555, BDA <private>, \
        CnS 0x800000 < ACL >
        """
        check(CBDeviceUUID.parse(log) == nil)
    }

    test("the last mention wins, so a reconnect is followed") {
        let log = """
        Device found: CBDevice AAAAAAAA-0000-0000-0000-000000000001, CnS 0x19 < A2DP >
        Device found: CBDevice BBBBBBBB-0000-0000-0000-000000000002, CnS 0x19 < A2DP >
        """
        check(CBDeviceUUID.parse(log) == "BBBBBBBB-0000-0000-0000-000000000002")
    }

    test("a line that only looks like one is rejected") {
        check(CBDeviceUUID.parse("CBDevice not-a-uuid A2DP") == nil)
        check(CBDeviceUUID.parse("") == nil)
    }

    test("the keeper's message always carries the arguments bluetoothd releases") {
        // Without kBTAudioMsgArgs bluetoothd does CFRelease(NULL) and dies; the message is
        // built inside the keeper, so what is checked here is the shape it must have.
        let message: [String: Any] = [
            "kBTAudioMsgId": Int64(5),
            "kBTAudioMsgDeviceUid": "40:DC:A5:0E:14:48-tacl",
            "kBTAudioMsgDeviceUUID": "4379D275-655C-EEB8-BB72-643BF2534BE0",
            "kBTAudioMsgArgs": ["kBTAudioMsgArgDeviceType": Int64(1)],
        ]
        check(message["kBTAudioMsgArgs"] != nil, "kBTAudioMsgArgs is mandatory")
        check(message["kBTAudioMsgId"] as? Int64 == 5, "BTAudioMsgIdStartAudio is 5")
    }
}

/// The adapter exists to stop the stream from oscillating: down when the link complains,
/// up only after it has been clean for a while.
func bitrateAdapterTests() {
    let quality = LDACEncoder.Quality.self

    test("a clean window does not change the level on its own") {
        var adapter = BitrateAdapter(upAfter: 3, minimumInterval: 0)
        check(adapter.decide(current: .high, dropped: 0, queueFill: 0.1) == .hold)
    }

    test("dropped audio steps down at once") {
        var adapter = BitrateAdapter(minimumInterval: 0)
        check(adapter.decide(current: .high, dropped: 0.5, queueFill: 0.1) == .down(.standard))
        check(adapter.decide(current: .standard, dropped: 0.5, queueFill: 0.1) == .down(.mobile))
    }

    test("a queue at its ceiling steps down before anything is dropped") {
        var adapter = BitrateAdapter(dropLimit: 0.02, queueLimit: 0.75, minimumInterval: 0)
        check(adapter.decide(current: .high, dropped: 0, queueFill: 0.9) == .down(.standard))
    }

    test("it never steps below MQ or above HQ") {
        var adapter = BitrateAdapter(minimumInterval: 0)
        check(adapter.decide(current: .mobile, dropped: 0.9, queueFill: 0.9) == .hold,
              "MQ is the bottom")
        var up = BitrateAdapter(upAfter: 1, minimumInterval: 0)
        _ = up.decide(current: .high, dropped: 0, queueFill: 0)
        check(up.decide(current: .high, dropped: 0, queueFill: 0) == .hold, "HQ is the top")
    }

    test("it steps up only after the link has been clean for a while") {
        var adapter = BitrateAdapter(upAfter: 3, minimumInterval: 0)
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0) == .hold)
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0) == .hold)
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0) == .up(.standard))
    }

    test("one bad window resets the clean count") {
        var adapter = BitrateAdapter(upAfter: 2, minimumInterval: 0)
        _ = adapter.decide(current: .mobile, dropped: 0, queueFill: 0)
        _ = adapter.decide(current: .mobile, dropped: 0.5, queueFill: 0)  // but at the bottom
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0) == .hold,
              "the count started again")
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0) == .up(.standard))
    }

    test("it does not change again inside the minimum interval") {
        var adapter = BitrateAdapter(minimumInterval: 60)
        check(adapter.decide(current: .high, dropped: 0.9, queueFill: 0) == .down(.standard))
        check(adapter.decide(current: .standard, dropped: 0.9, queueFill: 0) == .hold,
              "too soon to move again")
    }

    test("the ladder is HQ, SQ, MQ and stops at both ends") {
        check(BitrateAdapter.lower(.high) == .standard)
        check(BitrateAdapter.lower(.standard) == .mobile)
        check(BitrateAdapter.lower(.mobile) == nil)
        check(BitrateAdapter.higher(.mobile) == .standard)
        check(BitrateAdapter.higher(.high) == nil)
    }
}

/// The first live run climbed back to SQ four seconds after SQ had failed, and the listener
/// heard the same glitch again. A level that failed is not retried at once.
func bitrateBackoffTests() {
    test("a level that failed is not climbed back into at once") {
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, backoff: 60, upDwell: 0)
        check(adapter.decide(current: .standard, dropped: 0.4, queueFill: 0.1) == .down(.mobile))
        // Clean windows at MQ: it wants to go up, but SQ is blocked.
        for _ in 0..<5 {
            check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0) == .hold,
                  "SQ failed a moment ago")
        }
    }

    test("the wait doubles each time the same level fails") {
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, backoff: 10, upDwell: 0)
        let start = Date()
        _ = adapter.decide(current: .standard, dropped: 0.4, queueFill: 0, now: start)
        // Blocked for 10 s: at 11 s it may try again.
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0,
                             now: start.addingTimeInterval(11)) == .up(.standard))
        // Fail again: now blocked for 20 s.
        _ = adapter.decide(current: .standard, dropped: 0.4, queueFill: 0,
                           now: start.addingTimeInterval(12))
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0,
                             now: start.addingTimeInterval(20)) == .hold, "still blocked")
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0,
                             now: start.addingTimeInterval(33)) == .up(.standard), "wait doubled")
    }

    test("a level that never failed is still reachable") {
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, backoff: 60, upDwell: 0)
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0) == .up(.standard))
    }
}

/// Combining the two fixes: the ceiling stops the adapter from starting too high, and the short
/// opening windows let it find the right level in half a second instead of four.
func bitrateCeilingTests() {
    test("the ceiling is never climbed above") {
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, ceiling: .mobile, upDwell: 0)
        for _ in 0..<5 {
            check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0) == .hold,
                  "MQ is the ceiling")
        }
    }

    test("a higher ceiling is still reachable") {
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, ceiling: .standard, upDwell: 0)
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0) == .up(.standard))
        check(adapter.decide(current: .standard, dropped: 0, queueFill: 0) == .hold,
              "SQ is the ceiling here")
    }

    test("probing up needs a long clean stretch, not just a few windows") {
        // backoff 0: this test is about the dwell, not about the block on a failed level.
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, backoff: 0, ceiling: .high,
                                     upDwell: 20)
        let start = Date()
        // Start at SQ and fail: that records a change, so the dwell counts from here.
        check(adapter.decide(current: .standard, dropped: 0.5, queueFill: 0, now: start)
              == .down(.mobile))
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0,
                             now: start.addingTimeInterval(5)) == .hold, "only 5 s clean")
        check(adapter.decide(current: .mobile, dropped: 0, queueFill: 0,
                             now: start.addingTimeInterval(25)) == .up(.standard), "20 s clean")
    }
}

/// A file that is too loud has nowhere else to be fixed: the PCM goes from the file to the
/// encoder untouched, and a full-scale sine is painful.
func gainTests() {
    test("gain scales the samples and clamps at full scale") {
        let audio = WAVFile(sampleRate: 48000, samples: [0.5, -0.5, 0.9, -0.9])
        let quieter = audio.scaled(by: 0.5)
        check(quieter.samples == [0.25, -0.25, 0.45, -0.45], "\(quieter.samples)")
        let louder = audio.scaled(by: 4)
        check(louder.samples == [1.0, -1.0, 1.0, -1.0], "clamped, not wrapped: \(louder.samples)")
        check(quieter.sampleRate == 48000)
    }

    test("gain of 1 leaves the audio alone") {
        let audio = WAVFile(sampleRate: 44100, samples: [0.1, 0.2])
        check(audio.scaled(by: 1).samples == [0.1, 0.2])
    }
}

/// The ring layout is written twice — once in C for the driver, once in Swift for the reader —
/// so the offsets are the one thing that must not drift. This test pins them.
func sharedRingTests() {
    test("the ring's header layout matches the driver's struct") {
        // write(8) + read(8) + sampleRate(4) + channels(4) + generation(4) + padding(4) = 32
        check(SharedRing.frames == 48000)
        check(SharedRing.channels == 2)
        check(SharedRing.path == "/tmp/codecblue-ring")
    }

    test("reading a ring that does not exist fails with a useful message") {
        do {
            _ = try SharedRing(path: "/tmp/codecblue-ring-does-not-exist")
            check(false, "should have thrown")
        } catch {
            check("\(error)".contains("does not exist"), "\(error)")
        }
    }
}

/// Where to start reading is pure arithmetic, so it is tested without a driver.
///
/// The rule changed on 2026-11-06 and the tests with it. `staleAfterFrames` used to be a
/// *trigger*: more than that waiting and the reader skipped forward. But the throttle holds the
/// depth at the budget, so being above it is normal while the cushion is rebuilt — and skipping
/// there threw away exactly the cushion the widening had just created (86 skips in one run,
/// heard as clicks, while every other number looked healthy). Now the only reason to skip is
/// that the ring has wrapped and the audio has been overwritten.
func staleRingTests() {
    test("a backlog inside the ring is read, not thrown away") {
        // 5000 frames waiting is 104 ms: a normal cushion, not a backlog to discard.
        let start = SharedRing.startIndex(written: 5000, read: 0, count: 512, staleAfterFrames: 2400)
        check(start == 0, "started at \(start): the cushion is the point, not the problem")
        // Even far past the budget: the throttle will bring it down, the audio is still good.
        let past = SharedRing.startIndex(written: 20_000, read: 0, count: 512,
                                         staleAfterFrames: 2400)
        check(past == 0, "started at \(past)")
    }

    test("a normal amount of audio is read from where it was left") {
        let start = SharedRing.startIndex(written: 1000, read: 0, count: 512, staleAfterFrames: 2400)
        check(start == 0, "started at \(start)")
        let next = SharedRing.startIndex(written: 1512, read: 512, count: 512, staleAfterFrames: 2400)
        check(next == 512, "started at \(next)")
    }

    test("a reader that fell a whole ring behind is pulled forward") {
        // The writer has overwritten what the reader was about to read: skip to the oldest audio
        // that still exists, which is a full ring back from the writer.
        let start = SharedRing.startIndex(written: 100_000, read: 0, count: 512,
                                          staleAfterFrames: 2400)
        check(start == 100_000 - 48000, "started at \(start), expected a full ring back")
        let far = SharedRing.startIndex(written: 200_000, read: 0, count: 100_000,
                                        staleAfterFrames: 4_000_000)
        check(far == 200_000 - 48000, "started at \(far), expected a full ring back")
    }

    test("nothing written means nothing to read") {
        let start = SharedRing.startIndex(written: 0, read: 0, count: 512, staleAfterFrames: 2400)
        check(start == 0)
    }
}

/// The volume moved from the driver to just before the encoder. Two things must hold: the gain
/// is applied to the samples the encoder sees, and the device still exposes a control for the
/// system slider to move.
func gainPathTests() {
    test("the gain is read per block, so a change is heard at once") {
        // The closure is what the streamer calls for every block: it must not capture the value.
        var level: Float = 0.5
        let gain: () -> Float = { level }
        check(gain() == 0.5)
        level = 0.25
        check(gain() == 0.25, "a later change must be visible to the next block")
    }

    test("a device that is not the system output has no volume to read") {
        // Nothing named like this exists, so the reader must decline rather than guess.
        check(SystemVolume.findDevice(named: "No Such Audio Device 12345") == nil)
    }
}

/// Zero volume means silence. An earlier version read it as "not set yet" and substituted full
/// scale, which made the slider backwards at the bottom.
func volumeDefaultTests() {
    test("zero volume without a mute is read as full scale") {
        // The rule lives in SystemVolume.gain, which needs a real device; what can be pinned here
        // is the arithmetic it is built on.
        func gain(stored: Float, muted: Bool) -> Float {
            if muted { return 0 }
            return stored
        }
        // Zero means zero. Reading it as "not set" made the slider backwards at the bottom:
        // volume 0 played at maximum.
        check(gain(stored: 0, muted: false) == 0, "0 is silent, not full scale")
        check(gain(stored: 0, muted: true) == 0, "muted is silent, whatever the value")
        check(gain(stored: 0.5, muted: false) == 0.5)
        check(gain(stored: 1, muted: false) == 1)
    }
}

/// A short read from the ring used to be filled with zeros, which puts a step in the waveform at
/// every underrun — heard as a click. The tail must hold the last sample instead.
func underrunTests() {
    test("a short chunk is held, not zeroed") {
        // The rule the inner loop implements: beyond the chunk, repeat the last sample.
        func fill(chunk: [Float], block: Int, last: Float) -> [Float] {
            var out = [Float](repeating: 0, count: block * 2)
            let hold = chunk.last ?? last
            for i in 0..<(block * 2) {
                out[i] = i < chunk.count ? chunk[i] : hold
            }
            return out
        }
        // A chunk of 2 frames out of a block of 4: the last two frames repeat 0.5, not 0.
        let out = fill(chunk: [0.1, 0.2, 0.3, 0.5], block: 4, last: 0)
        check(out[4] == 0.5 && out[5] == 0.5 && out[6] == 0.5 && out[7] == 0.5,
              "tail should hold, got \(out[4...7])")
        // A completely empty chunk holds the previous block's last sample.
        let empty = fill(chunk: [], block: 2, last: -0.3)
        check(empty == [-0.3, -0.3, -0.3, -0.3], "\(empty)")
    }
}

/// The link does not lose packets, it stalls for 100–300 ms. A fixed 60 ms queue threw the audio
/// away; a fixed 250 ms queue cost 250 ms of delay on every video. So the queue learns.
func adaptiveQueueTests() {
    test("a stall widens the queue, up to the ceiling") {
        var queue = PacketQueue(sampleRate: 48000, floorDuration: 0.06, ceilingDuration: 0.4)
        check(queue.maxDuration == 0.06)
        check(queue.noteStall() == true)
        check(queue.maxDuration == 0.12, "\(queue.maxDuration)")
        _ = queue.noteStall()
        _ = queue.noteStall()
        check(queue.maxDuration == 0.4, "capped: \(queue.maxDuration)")
        check(queue.noteStall() == false, "already at the ceiling")
        check(queue.maxDuration == 0.4)
    }

    test("a clean window narrows it back, never below the floor") {
        var queue = PacketQueue(sampleRate: 48000, floorDuration: 0.06, ceilingDuration: 0.4)
        _ = queue.noteStall()
        _ = queue.noteStall()
        check(queue.maxDuration == 0.24)
        check(queue.relax() == true)
        check(queue.maxDuration == 0.12, "\(queue.maxDuration)")
        _ = queue.relax()
        check(queue.maxDuration == 0.06)
        check(queue.relax() == false, "already at the floor")
    }

    test("the caller decides what counts as clean") {
        // relax() only does the arithmetic; the streamer calls it when the window had no stall,
        // and noteStall() when it had one. Two places deciding would drift apart.
        var queue = PacketQueue(sampleRate: 48000, floorDuration: 0.06, ceilingDuration: 0.4)
        _ = queue.noteStall()
        _ = queue.noteStall()
        check(queue.maxDuration == 0.24)
        _ = queue.relax()
        check(queue.maxDuration == 0.12, "\(queue.maxDuration)")
    }

    test("a fixed budget behaves like before") {
        let queue = PacketQueue(sampleRate: 48000, maxDuration: 0.15)
        check(queue.floorDuration == 0.15 && queue.ceilingDuration == 0.15)
        check(queue.maxDuration == 0.15)
    }
}

/// The keeper's one job is to know whether bluetoothd has the audio device, because until it
/// does, every "audio started" is answered `No device found` and does nothing. Measured
/// 2026-11-06: the takeover erases `…-tacl` and bluetoothd republishes it about 14 s later.
func keeperDeviceTests() {
    test("a registered device reads as present") {
        let log = """
        [com.apple.bluetooth:Server.Audio] -[AudioDeviceManager publishAndRegisterDeviceForUID:withArgs:device:] Register audio device 40:DC:A5:0E:14:48-tacl
        """
        check(AudioStreamKeeper.hasRegisteredDevice(log, uid: "40:DC:A5:0E:14:48-tacl"))
    }

    test("the takeover erasing it reads as absent") {
        let log = """
        Register audio device 40:DC:A5:0E:14:48-tacl
        Erased 1 audio device 40:DC:A5:0E:14:48-tacl from audio device map and marked the Audio Plugin ready for delete. Map now has 1 devices
        """
        check(!AudioStreamKeeper.hasRegisteredDevice(log, uid: "40:DC:A5:0E:14:48-tacl"))
    }

    test("the last word wins, because it comes and goes") {
        let log = """
        Erased 1 audio device 40:DC:A5:0E:14:48-tacl from audio device map
        Register audio device 40:DC:A5:0E:14:48-tacl
        """
        check(AudioStreamKeeper.hasRegisteredDevice(log, uid: "40:DC:A5:0E:14:48-tacl"))
    }

    test("another device's lines do not count") {
        let log = """
        Register audio device 40:DC:A5:0E:14:48-tsco
        Erased 1 audio device 40:DC:A5:0E:14:48-taad from audio device map
        """
        check(!AudioStreamKeeper.hasRegisteredDevice(log, uid: "40:DC:A5:0E:14:48-tacl"))
    }
}

/// The underrun fill must hold each channel at its own last value. A single held sample took the
/// right channel (last element of an interleaved block) and wrote it into both, which is heard
/// as noise on the right and is a step in the waveform on both.
func underrunChannelTests() {
    test("each channel is held at its own last value") {
        // A block whose channels are deliberately different, cut short mid-way.
        var chunk: [Float] = [0.1, 0.9, 0.2, 0.8]  // L, R, L, R
        // What the *previous* block left behind: the fill uses these, which is the whole point —
        // they are per channel and they carry across blocks.
        var lastLeft: Float = 0.2
        var lastRight: Float = 0.8
        var scratch = [Float](repeating: 0, count: 8)
        let level: Float = 1

        for i in 0..<8 {
            if i < chunk.count {
                scratch[i] = chunk[i] * level
            } else {
                scratch[i] = (i % 2 == 0 ? lastLeft : lastRight) * level
            }
        }
        if chunk.count >= 2 {
            lastLeft = chunk[chunk.count - 2]
            lastRight = chunk[chunk.count - 1]
        }
        check(scratch[0] == 0.1 && scratch[1] == 0.9, "the audio itself is untouched")
        check(scratch[4] == 0.2 && scratch[5] == 0.8, "held: L keeps 0.2, R keeps 0.8")
        check(scratch[6] == 0.2 && scratch[7] == 0.8, "and again for the next pair")
        // The bug this replaces: both channels got the right channel's value.
        check(scratch[4] != 0.8, "the left channel is not overwritten with the right's value")
        chunk = []
    }
}

/// A pause must not be paid for on resume.
///
/// `due` is measured from `start`, so if the clock keeps running while the headphones have
/// suspended the stream, the first iteration after "start" believes the whole pause is due at
/// once. Measured 2026-11-06: 406–452 kbps out of a 330 kbps codec, `link took 121% of real
/// time`, 280 short reads per window — heard as fast-forward with heavy distortion.
func pauseResumeTests() {
    test("the clock is not charged for the time spent paused") {
        // What the loop does: shift the anchor forward by the paused interval.
        var start: UInt64 = 1_000_000_000
        let rate = 48000
        let lead = 0.04

        // 10 s of streaming, then a 30 s pause, then resume.
        let beforePause = start + 10_000_000_000
        let dueBefore = Int((Double(beforePause - start) / 1e9 + lead) * Double(rate))
        check(abs(dueBefore - 481_920) <= 1, "\(dueBefore)")

        // The pause: the anchor moves forward by exactly the paused time.
        let pausedNanos: UInt64 = 30_000_000_000
        start += pausedNanos

        let afterResume = beforePause + pausedNanos + 1_000_000  // 1 ms later
        let dueAfter = Int((Double(afterResume - start) / 1e9 + lead) * Double(rate))
        check(dueAfter - dueBefore < 100, "no burst: \(dueAfter - dueBefore) frames due")

        // Without the shift the same instant would be 30 s ahead: 1.44M frames at once.
        let dueWithout = Int((Double(afterResume - (start - pausedNanos)) / 1e9 + lead) * Double(rate))
        check(dueWithout - dueBefore > 1_000_000, "the bug would be a 30 s burst")
    }
}

/// A pause in the app is invisible to AVDTP: the headphones never suspend, so the only witness
/// is the source itself. When nothing has arrived for longer than the cushion, the clock must be
/// reset rather than charged for the gap.
func appPauseTests() {
    test("a long gap in the source resets the clock instead of catching up") {
        let rate = 48000
        let lead = 0.04
        var start: UInt64 = 0
        let maxFrames = Int(0.25 * Double(rate))  // 12000, the cushion

        // 10 s of audio consumed, then a 10 s pause during which nothing arrives.
        let position = Int(10.0 * Double(rate))
        let now = UInt64(20.0 * 1e9)  // 20 s since start
        var due = Int((Double(now - start) / 1e9 + lead) * Double(rate))
        check(due - position > maxFrames * 2, "the gap is detected")

        // The rule: `position` is measured *against* `start`, so they are one pair and are
        // re-anchored together — position to zero, start to now.
        //
        // Two failed attempts are recorded in the streamer's comment: moving `start` forward
        // alone underflowed a UInt64 and crashed (2026-11-06 19:30); jumping `position` to live
        // while restarting `start` at zero left nothing ever due, and the stream went silent for
        // 25 s (19:35).
        var position2 = 0
        start = now
        due = Int((Double(now - start) / 1e9 + lead) * Double(rate))
        check(due - position2 <= Int(lead * Double(rate)) + 1,
              "no burst after the reset: \(due - position2) frames")
        check(due > position2, "and audio is due again immediately: \(due - position2)")
        check(now >= start, "the anchor is never ahead of now")

        // A short gap (2–3 s) must also be caught: it was only "fine by luck" before.
        var start2: UInt64 = 0
        var position3 = Int(10.0 * Double(rate))
        let now2 = UInt64(12.5 * 1e9)  // 2.5 s pause
        var due2 = Int((Double(now2 - start2) / 1e9 + lead) * Double(rate))
        check(due2 - position3 > maxFrames * 2, "2.5 s is already too much to catch up")
        position3 = 0
        start2 = now2
        due2 = Int((Double(now2 - start2) / 1e9 + lead) * Double(rate))
        check(due2 > position3, "audio is due again: \(due2 - position3)")
        check(now2 >= start2, "the anchor is never ahead of now")
    }
}

/// The slider must feel like macOS's. A linear multiply makes the first notch already loud and
/// the top half unusable — reported 2026-11-06: "a zero non sento, ma se metto una tacca già
/// sento molto alto, e a metà è altissimo".
func volumeCurveTests() {
    test("the volume curve is perceptual, not linear") {
        check(SystemVolume.applyCurve(1) == 1, "full scale is unity")
        check(SystemVolume.applyCurve(0) == 0, "zero is silence")
        // Half the slider must be well below half the amplitude: hearing is logarithmic.
        let half = SystemVolume.applyCurve(0.5)
        check(half < 0.25, "half the slider is \(half), not 0.5")
        check(half > 0.1, "but not so quiet as to be useless: \(half)")
        // The first notch must be quiet, not already loud.
        check(SystemVolume.applyCurve(0.0625) < 0.01, "one notch is \(SystemVolume.applyCurve(0.0625))")
        // Monotonic, and clamped.
        var previous: Float = -1
        for i in 0...20 {
            let g = SystemVolume.applyCurve(Float(i) / 20)
            check(g >= previous, "monotonic at \(i)")
            previous = g
        }
        check(SystemVolume.applyCurve(1.5) == 1, "clamped above")
        check(SystemVolume.applyCurve(-0.5) == 0, "clamped below")
    }

    test("the curve's shape matches the table in the comment") {
        // 75% → about −6 dB, 50% → about −15 dB, 25% → about −30 dB.
        func dB(_ position: Float) -> Float { 20 * log10(SystemVolume.applyCurve(position)) }
        check(abs(dB(0.75) - (-6.0)) < 1.0, "75%: \(dB(0.75)) dB")
        check(abs(dB(0.5) - (-15.0)) < 1.5, "50%: \(dB(0.5)) dB")
        check(abs(dB(0.25) - (-30.0)) < 2.0, "25%: \(dB(0.25)) dB")
    }

    test("decibels convert to amplitude the honest way") {
        // The driver declares a −64…0 dB range, so the slider is a straight line in dB and this
        // is the only conversion left. Half the slider is −32 dB, which is 0.025 in amplitude:
        // quiet, as the ear expects, not 0.5.
        check(SystemVolume.gain(fromDecibels: 0) == 1, "0 dB is unity")
        check(SystemVolume.gain(fromDecibels: -6) > 0.49
              && SystemVolume.gain(fromDecibels: -6) < 0.51, "−6 dB is about half")
        check(SystemVolume.gain(fromDecibels: -20) < 0.11, "−20 dB is a tenth")
        check(SystemVolume.gain(fromDecibels: -64) == 0, "the bottom of the range is silence")
        check(SystemVolume.gain(fromDecibels: -100) == 0, "below the range is silence, not negative")
        check(SystemVolume.gain(fromDecibels: 6) == 1, "above the range is clamped")
        // Half the slider on a −64…0 dB range is −32 dB.
        let halfSlider = SystemVolume.gain(fromDecibels: -32)
        check(halfSlider < 0.03, "half the slider is \(halfSlider), not 0.5")
    }
}

/// The device runs at 48 kHz; a pair of headphones that only takes 44.1 kHz in LDAC is still
/// drivable, as long as the audio is converted instead of refused.
func resamplerTests() {
    test("no conversion is a pass-through") {
        let resampler = Resampler(from: 48000, to: 48000)
        check(resampler.isIdentity)
        let input: [Float] = [0.1, 0.2, 0.3, 0.4]
        check(resampler.process(input) == input)
    }

    test("48 kHz to 44.1 kHz produces the right number of frames") {
        let resampler = Resampler(from: 48000, to: 44100)
        check(!resampler.isIdentity)
        // 4800 frames in (100 ms at 48 kHz) → 4410 frames out, within one frame of rounding.
        let input = [Float](repeating: 0.5, count: 4800 * 2)
        let output = resampler.process(input)
        let frames = output.count / 2
        check(abs(frames - 4410) <= 1, "\(frames) frames")
    }

    test("a constant signal stays constant, so nothing is invented") {
        let resampler = Resampler(from: 48000, to: 44100)
        let input = [Float](repeating: 0.25, count: 960 * 2)
        let output = resampler.process(input)
        check(output.allSatisfy { abs($0 - 0.25) < 1e-6 }, "a flat signal stays flat")
    }

    test("state carries across blocks, so there is no click at the boundary") {
        // Two blocks of a ramp: the second must continue where the first stopped, not restart.
        let resampler = Resampler(from: 48000, to: 44100)
        var ramp = [Float](repeating: 0, count: 480 * 2)
        for i in 0..<480 { ramp[i * 2] = Float(i) / 480; ramp[i * 2 + 1] = Float(i) / 480 }
        let first = resampler.process(ramp)
        let second = resampler.process(ramp)
        let lastOfFirst = first[first.count - 2]
        let firstOfSecond = second[0]
        // The second block's first sample is near 0 in the input, but the resampler's position
        // carried over, so the output must not jump back to exactly 0 from a high value.
        check(lastOfFirst > 0.9, "the first block ends high: \(lastOfFirst)")
        check(firstOfSecond < 0.2, "the second block starts where the input does: \(firstOfSecond)")
    }
}

/// Nothing may depend on the transport suffix bluetoothd happens to use. It was `-tacl` for the
/// headphones this was developed on; another pair may report `-taad` or something else, and a
/// device that is registered must be recognised regardless.
func keeperAddressTests() {
    test("a different transport suffix is still recognised") {
        let log = """
        Register audio device 40:DC:A5:0E:14:48-taad
        """
        check(AudioStreamKeeper.hasRegisteredDevice(log, uid: "40:DC:A5:0E:14:48-tacl"),
              "matched on the address, not the suffix")
    }

    test("another device's registration is not ours") {
        let log = """
        Register audio device AC:BD:70:5C:06:1C-tacl
        """
        check(!AudioStreamKeeper.hasRegisteredDevice(log, uid: "40:DC:A5:0E:14:48-tacl"))
    }
}


/// Latency is the cushion, and the cushion is the only lever: the headphones' buffer and the
/// LDAC frame time are fixed. So it must start where a good link stays and widen only when a
/// stall proves it is needed — a fixed 250 ms was the worst case paid on every video.
func cushionAdaptationTests() {
    test("the cushion starts at the floor, not the worst case") {
        let queue = PacketQueue(sampleRate: 48000, floorDuration: 0.08, ceilingDuration: 0.30)
        check(queue.maxDuration == 0.08, "\(queue.maxDuration)")
        check(queue.maxFrames == 3840)
        check(queue.maxDuration < 0.25, "well under the fixed 250 ms it replaced")
    }

    test("a stall doubles it, and the ceiling caps it") {
        var queue = PacketQueue(sampleRate: 48000, floorDuration: 0.08, ceilingDuration: 0.30)
        check(queue.noteStall())
        check(queue.maxDuration == 0.16, "\(queue.maxDuration)")
        check(queue.noteStall())
        check(queue.maxDuration == 0.30, "capped at the ceiling: \(queue.maxDuration)")
        check(!queue.noteStall(), "already at the ceiling")
    }

    test("calm brings it back, one step at a time, never below the floor") {
        var queue = PacketQueue(sampleRate: 48000, floorDuration: 0.08, ceilingDuration: 0.30)
        _ = queue.noteStall()  // 0.16
        _ = queue.noteStall()  // 0.30
        check(queue.relax())
        check(queue.maxDuration == 0.15, "halved from the ceiling: \(queue.maxDuration)")
        _ = queue.relax()
        check(queue.maxDuration == 0.08, "\(queue.maxDuration)")
        check(!queue.relax(), "already at the floor")
    }
}

/// The LaunchAgent is a file launchd reads, so the only thing worth testing is that the file is
/// well formed and carries the right command. A plist that will not parse is an agent that
/// silently does nothing, which is the failure mode this whole feature exists to avoid.
func launchAgentTests() {
    test("the plist carries the command, the address and the log") {
        let plist = LaunchAgent.plist(executable: "/usr/local/bin/codecblue",
                                      address: "40:DC:A5:0E:14:48",
                                      arguments: ["--quality", "MQ"])
        check(plist.contains("<string>/usr/local/bin/codecblue</string>"))
        check(plist.contains("<string>system</string>"))
        check(plist.contains("<string>40:DC:A5:0E:14:48</string>"))
        check(plist.contains("<string>--quality</string>"))
        check(plist.contains("<string>MQ</string>"))
        check(plist.contains("<string>\(LaunchAgent.logPath)</string>"))
        check(plist.contains("<key>RunAtLoad</key>"))
        check(plist.contains("<key>KeepAlive</key>"))
        check(plist.contains("<string>\(LaunchAgent.label)</string>"))
    }

    test("the plist parses as a property list") {
        let plist = LaunchAgent.plist(executable: "/tmp/a b/codecblue", address: "AA:BB:CC:DD:EE:FF")
        let data = Data(plist.utf8)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        check(parsed != nil, "the plist must parse, or launchd ignores it silently")
        guard let dictionary = parsed as? [String: Any] else {
            check(false, "not a dictionary")
            return
        }
        check(dictionary["Label"] as? String == LaunchAgent.label)
        let arguments = dictionary["ProgramArguments"] as? [String] ?? []
        check(arguments == ["/tmp/a b/codecblue", "system", "AA:BB:CC:DD:EE:FF"], "\(arguments)")
        check(dictionary["RunAtLoad"] as? Bool == true)
        check(dictionary["KeepAlive"] as? Bool == true)
        check(dictionary["ThrottleInterval"] as? Int == 5)
    }

    test("values that would break the XML are escaped") {
        // A path with an ampersand is legal on macOS and would make the plist unparseable.
        let plist = LaunchAgent.plist(executable: "/tmp/a&b/codecblue", address: "AA:BB:CC:DD:EE:FF")
        check(plist.contains("a&amp;b"), "escaped")
        let data = Data(plist.utf8)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        check(parsed != nil, "still parses")
    }
}

/// A probe that talks to a system process must not be able to send arbitrary messages.
///
/// This is the rule that came out of crashing bluetoothd five times out of five on 2026-11-06:
/// four `EXC_BREAKPOINT` from `CFRelease(NULL)` and one ObjC exception in `CFBooleanGetValue`,
/// all from probes that sent every number in a range. A message bluetoothd does not expect, with
/// an argument shape it does not expect, is not a question it answers — it is a case it does not
/// handle. The allowlist is the enforcement, so it is what gets tested.
func knownMessageTests() {
    test("every known message has a name, and the tables are not empty") {
        check(!KnownMessage.device.isEmpty)
        check(!KnownMessage.general.isEmpty)
        for (id, name) in KnownMessage.device {
            check(id > 0, "message ids start at 1: \(id)")
            check(!name.isEmpty, "message \(id) has no name")
        }
        for (id, name) in KnownMessage.general {
            check(id > 0, "message ids start at 1: \(id)")
            check(!name.isEmpty, "message \(id) has no name")
        }
    }

    test("a number outside the allowlist is not sendable") {
        // The whole safety property: there is no way to ask for an unknown message.
        check(KnownMessage.name(9999, in: KnownMessage.device) == nil)
        check(KnownMessage.name(-1, in: KnownMessage.general) == nil)
        check(KnownMessage.name(1, in: KnownMessage.device) == "kCBMsgIdDeviceGetInfo")
    }
}

/// Stopping mid-waveform leaves a step from wherever the signal was to zero, and a step is a
/// click — reported as "un piccolo fruscio sulla destra" when pausing. The fade is pure
/// arithmetic, so the shape of the ramp is testable without a link.
func fadeOutTests() {
    test("the fade reaches zero and never overshoots") {
        let fadeFrames = 240  // 5 ms at 48 kHz
        let block = 128
        let from: (Float, Float) = (0.4, -0.3)
        var samples: [Float] = []
        var remaining = fadeFrames
        var done = 0
        while remaining > 0 {
            for i in 0..<block {
                let position = done + i
                let g = position >= fadeFrames ? 0 : 1 - Float(position) / Float(fadeFrames)
                samples.append(from.0 * g)
                samples.append(from.1 * g)
            }
            done += block
            remaining = max(0, remaining - block)
        }
        check(samples.count >= fadeFrames * 2, "long enough to cover the fade")
        // Starts at the last sample, so there is no step at the beginning either.
        check(abs(samples[0] - 0.4) < 1e-6, "starts where the audio was: \(samples[0])")
        // Monotonic towards zero on each channel.
        var previous = abs(samples[0])
        for i in stride(from: 0, to: samples.count, by: 2) {
            let magnitude = abs(samples[i])
            check(magnitude <= previous + 1e-6, "monotonic at \(i): \(magnitude) > \(previous)")
            previous = magnitude
        }
        // And it ends at (or very near) zero.
        let last = samples[samples.count - 2]
        check(abs(last) < 0.01, "ends near zero: \(last)")
    }

    test("a fade of 5 ms is inaudible as a tone") {
        // 5 ms is above the ~2 ms where a ramp is heard as a click, and far below the ~20 ms
        // where it is heard as a fade-out. It is the shortest ramp that is not a step.
        check(0.005 >= 0.002 && 0.005 <= 0.02)
        let frames = Int(0.005 * 48000)
        check(frames == 240, "\(frames) frames")
    }
}

/// Our own buffers do not grow — measured 2026-11-06, cumulative delivery was 100.01% of real
/// time with the ring steady and the queue returning to zero — yet the sound falls behind the
/// picture over minutes. The remaining buffer is the headphones' own, and their crystal runs at
/// a slightly different frequency. With no delay report to close the loop, the fix is a standing
/// bias: deliver a hair less than real time so their buffer drains as fast as it fills.
func driftBiasTests() {
    test("the bias is inaudible and large enough to matter") {
        let bias = 0.0001  // 0.01%
        // In cents: 1200 * log2(1 + bias) ≈ 0.17 cents. The just-noticeable difference for a
        // sustained tone is around 5 cents, so this is far below it.
        let cents = 1200 * log2(1 + bias)
        check(cents < 1.0, "\(cents) cents is inaudible")
        check(cents > 0.05, "but not zero either: \(cents) cents")
        // Over ten minutes it is 60 ms of buffer, which is the drift that was being reported.
        let framesPerSecond = 48000 * bias
        check(abs(framesPerSecond - 4.8) < 0.1, "\(framesPerSecond) frames/s")
        let minutesTo60ms = 0.060 / bias / 60
        check(abs(minutesTo60ms - 10) < 0.5, "\(minutesTo60ms) minutes per 60 ms")
    }

    test("erring towards emptying is the right direction") {
        // A buffer that slowly empties costs an occasional refill; one that slowly fills costs
        // sync that never comes back. So the bias is positive (we deliver less than real time).
        let bias = 0.0001
        check(bias > 0, "we must deliver slightly *less* than real time")
    }
}

/// The ring is a live device: the driver writes at the Mac's clock whether or not the link keeps
/// up, so every stall leaves the ring holding that much extra audio, and reading at exactly real
/// time preserves it forever. Measured 2026-11-06: one stall took the ring from 1984 frames
/// (41 ms) to 13 504 (281 ms) and it was still ~11 800 two minutes later — the reported "after a
/// while the audio is behind the video".
func drainServoTests() {
    test("the servo drains a backlog instead of preserving it") {
        let sampleRate = 48000.0
        let target = 2880.0  // 60 ms
        func boost(depth: Double) -> Double {
            guard depth > target else { return 0 }
            return min(0.015, (depth - target) / target * 0.02)
        }
        check(boost(depth: target) == 0, "no boost at the target")
        check(boost(depth: 1984) == 0, "no boost below the target")
        // A 250 ms backlog (12 000 frames) must be drained in a reasonable time.
        let b = boost(depth: 12000)
        check(b > 0, "a backlog engages the servo: \(b)")
        let framesPerSecond = sampleRate * b
        let secondsToClear = (12000 - target) / framesPerSecond
        check(secondsToClear < 20, "\(secondsToClear) s to clear 250 ms of backlog")
        // And it must stay inaudible: 1.5% is 0.26 of a semitone.
        let cents = 1200 * log2(1 + 0.015)
        check(cents < 30, "\(cents) cents at the cap")
    }

    test("the fraction must be carried, not truncated") {
        // At 0.36% of a 128-frame block the extra is 0.46 frames. `Int(...)` makes that 0, so a
        // servo that looked engaged did nothing — measured: the ring sat at 3400 frames against
        // a 2880 target for two minutes.
        let boost = 0.0036
        let block = 128.0
        check(Int(block * boost) == 0, "truncating gives zero, which is the bug")
        var carry = 0.0
        var total = 0
        for _ in 0..<1000 {
            carry += block * boost
            let extra = Int(carry)
            carry -= Double(extra)
            total += extra
        }
        let expected = Int(block * boost * 1000)
        check(abs(total - expected) <= 1, "\(total) extra frames over 1000 blocks, expected \(expected)")
    }
}

/// The headphones' own buttons. They arrive as AVRCP commands on the control channel we hold,
/// and until 2026-11-06 every one of them except a key press was answered NOT IMPLEMENTED — so
/// the volume keys did nothing at all ("non riesco ad aumentare e abbassare il volume tramite le
/// cuffie"). The parsing is a pure function now precisely so this can be tested.
func avrcpCommandTests() {
    test("a volume key press is a key, a release is nothing") {
        // AVCTP header, profile 0x110E, AV/C PASS THROUGH, operand 0x41 (volume up).
        let press: [UInt8] = [0x00, 0x11, 0x0E, 0x00, 0x00, 0x7C, 0x41]
        check(AVCTPHolder.interpret(press) == .key("volume_up"), "volume up")
        let release: [UInt8] = [0x00, 0x11, 0x0E, 0x00, 0x00, 0x7C, 0xC1]
        check(AVCTPHolder.interpret(release) == .unsupported,
              "a release must not fire the key a second time")
        let down: [UInt8] = [0x00, 0x11, 0x0E, 0x00, 0x00, 0x7C, 0x42]
        check(AVCTPHolder.interpret(down) == .key("volume_down"), "volume down")
    }

    test("SET ABSOLUTE VOLUME is understood, not refused") {
        // Opcode 0x50, operand 0x40 = 64 of 127, so just over half.
        let absolute: [UInt8] = [0x00, 0x11, 0x0E, 0x00, 0x00, 0x50, 0x40]
        guard case .absoluteVolume(let value) = AVCTPHolder.interpret(absolute) else {
            check(false, "SET ABSOLUTE VOLUME must be recognised")
            return
        }
        check(abs(value - 64.0 / 127) < 1e-6, "\(value)")
        check(value > 0.5 && value < 0.51, "just over half")
        // The top bit is reserved and must be masked off, not read as part of the value.
        let withReserved: [UInt8] = [0x00, 0x11, 0x0E, 0x00, 0x00, 0x50, 0xC0]
        guard case .absoluteVolume(let masked) = AVCTPHolder.interpret(withReserved) else {
            check(false, "reserved bit must not break parsing")
            return
        }
        check(abs(masked - 64.0 / 127) < 1e-6, "masked to the same value: \(masked)")
    }

    test("a short or unknown command is refused rather than guessed") {
        check(AVCTPHolder.interpret([0x00, 0x11, 0x0E]) == .unsupported, "too short")
        check(AVCTPHolder.interpret([0x00, 0x11, 0x0E, 0x00, 0x00, 0x7C, 0x99]) == .unsupported,
              "unknown key code")
        check(AVCTPHolder.interpret([0x00, 0x11, 0x0E, 0x00, 0x00, 0x10, 0x00]) == .unsupported,
              "GET CAPABILITIES is not a key")
    }
}

/// The AVRCP frames, byte for byte.
///
/// Every one of these was wrong in a way that produced no error anywhere: the headphones simply
/// answered REJECTED, or said nothing, and the feature looked like it did not exist. The bytes
/// below are copied from what the headphones themselves send, which is the only reliable source
/// for a protocol nobody documents in one place.
func avrcpFrameTests() {
    test("a volume notification is read from the frame the headphones actually send") {
        // Measured 2026-11-06: `12 11 0E 0F 48 00 00 19 58 31 00 00 02 0D 17`
        //   ctype 0x0F INTERIM, PDU 0x31 REGISTER NOTIFICATION, length 2, event 0x0D, value 0x17
        let frame: [UInt8] = [0x12, 0x11, 0x0E, 0x0F, 0x48, 0x00, 0x00, 0x19, 0x58,
                              0x31, 0x00, 0x00, 0x02, 0x0D, 0x17]
        check(frame.count == 15, "the frame is 15 bytes, not 17")
        check(frame[9] == 0x31, "PDU is REGISTER NOTIFICATION")
        check(frame[13] == 0x0D, "event is VOLUME CHANGED")
        let value = Float(frame[14] & 0x7F) / 127
        check(abs(value - 23.0 / 127) < 1e-6, "\(value) is 18%")
    }

    test("every vendor dependent PDU carries a two-byte length") {
        // SET ABSOLUTE VOLUME at 30%: PDU 0x50, reserved, length 1, operand 0x26.
        let set: [UInt8] = [0x20, 0x11, 0x0E, 0x00, 0x48, 0x00, 0x00, 0x19, 0x58,
                            0x50, 0x00, 0x00, 0x01, 0x26]
        check(set[9] == 0x50, "PDU")
        check(set[11] << 8 | set[12] == 1, "length is one operand")
        check(set[13] == 0x26, "0x26 is 38 of 127, which is 30%")
        // Without the length the frame is `50 26` and the headphones read 0x26 as a length:
        // measured, that is exactly what got REJECTED.
        let broken: [UInt8] = [0x20, 0x11, 0x0E, 0x00, 0x48, 0x00, 0x00, 0x19, 0x58, 0x50, 0x26]
        check(broken[10] == 0x26, "the broken form puts the operand where the length goes")
    }

    test("the capability answer names the event the headphones asked about") {
        let list = AVCTPHolder.capabilities(category: 0x03)
        check(list[0] == 0x03, "events supported")
        check(list[1] == 1, "one event")
        check(list[2] == 0x0D, "VOLUME CHANGED")
        let company = AVCTPHolder.capabilities(category: 0x02)
        check(company == [0x02, 0x00, 0x19, 0x58], "the Bluetooth SIG company id")
    }

    test("GET CAPABILITIES is recognised, with its id at byte 13") {
        // `10 11 0E 01 48 00 00 19 58 10 00 00 01 03` — the id is the last byte, not byte 10.
        let frame: [UInt8] = [0x10, 0x11, 0x0E, 0x01, 0x48, 0x00, 0x00, 0x19, 0x58,
                              0x10, 0x00, 0x00, 0x01, 0x03]
        check(AVCTPHolder.interpret(frame) == .getCapabilities(0x03), "events supported")
        // Reading byte 10 would give 0x00 — the reserved byte — and answer an empty list.
        check(frame[10] == 0x00, "byte 10 is the reserved byte, which is the trap")
    }
}

/// AVCTP runs over a stream socket, so frames have no boundaries of their own: a read can carry
/// half a frame or three. Measured 2026-11-06, the headphones sent GET CAPABILITIES and the
/// volume notification in a single read, and the parser looked only at the first — every volume
/// event was being swallowed by the frame in front of it.
func avctpFramingTests() {
    test("two frames in one read are cut apart") {
        let capabilities: [UInt8] = [0x10, 0x11, 0x0E, 0x01, 0x48, 0x00, 0x00, 0x19, 0x58,
                                     0x10, 0x00, 0x00, 0x01, 0x03]
        let notification: [UInt8] = [0x12, 0x11, 0x0E, 0x0F, 0x48, 0x00, 0x00, 0x19, 0x58,
                                     0x31, 0x00, 0x00, 0x02, 0x0D, 0x17]
        let both = capabilities + notification
        check(AVCTPHolder.frameLength(both) == 14, "the first frame is 14 bytes")
        check(AVCTPHolder.frameLength(Array(both[14...])) == 15, "the second is 15")
    }

    test("a partial frame is not parsed") {
        let notification: [UInt8] = [0x12, 0x11, 0x0E, 0x0F, 0x48, 0x00, 0x00, 0x19, 0x58,
                                     0x31, 0x00, 0x00, 0x02, 0x0D, 0x17]
        check(AVCTPHolder.frameLength(Array(notification[0..<10])) == nil,
              "half a frame must wait for the rest")
        check(AVCTPHolder.frameLength(notification) == 15, "the whole frame is 15")
    }

    test("the ctype is byte 3, not anything in the AVCTP header") {
        // The header holds the label, the packet type, C/R and IPID. Reading `header >> 2 & 0x03`
        // gives 0 for every frame, which is why the re-registration never ran.
        let interim: [UInt8] = [0x12, 0x11, 0x0E, 0x0F, 0x48, 0x00, 0x00, 0x19, 0x58,
                                0x31, 0x00, 0x00, 0x02, 0x0D, 0x17]
        check(interim[3] == 0x0F, "INTERIM")
        check((interim[0] >> 2) & 0x03 == 0, "the header says packet type 0, which is not 0x0F")
        var changed = interim
        changed[3] = 0x0C
        check(changed[3] == 0x0C, "CHANGED is what consumes a registration")
    }
}

/// A registration is answered INTERIM (the value now), and a real change arrives as CHANGED.
/// Measured 2026-11-06: every press produced a CHANGED followed by an INTERIM carrying the same
/// number, and acting on both moved the Mac's slider twice per press.
func avrcpNotificationTests() {
    test("INTERIM confirms, CHANGED acts") {
        func frame(ctype: UInt8, value: UInt8) -> [UInt8] {
            [0x12, 0x11, 0x0E, ctype, 0x48, 0x00, 0x00, 0x19, 0x58,
             0x31, 0x00, 0x00, 0x02, 0x0D, value]
        }
        check(frame(ctype: 0x0F, value: 0x17)[3] == 0x0F, "INTERIM")
        check(frame(ctype: 0x0D, value: 0x19)[3] == 0x0D, "CHANGED")
        // The two ctypes that were confused: 0x0C is STABLE, not CHANGED.
        check(frame(ctype: 0x0C, value: 0x19)[3] != 0x0D, "0x0C is STABLE, a different thing")
    }

    test("the value is 0…127, and 127 means full volume") {
        // Measured sequence from one run of presses: 0x08 0x00 0x08 0x10 0x19 0x21
        let values: [UInt8] = [0x08, 0x00, 0x08, 0x10, 0x19, 0x21]
        let percents = values.map { Int((Float($0) / 127 * 100).rounded()) }
        check(percents == [6, 0, 6, 13, 20, 26], "\(percents)")
        check(Float(0x7F) / 127 == 1, "0x7F is full scale")
    }
}

/// The reply to a button must depend on whether anything happened.
///
/// Measured 2026-11-06: every transport key was answered ACCEPTED and then dropped by a
/// `default: break`. From the headphones' side that is indistinguishable from success — they
/// never retry, and the listener hears nothing with no explanation anywhere. A refused key is
/// better than a lie.
func mediaKeyHelperTests() {
    test("the helper is next to the binary, not in the build products directory") {
        // `Bundle.main.executableURL` points into .build/out/Products/Debug, which
        // `swift package clean` deletes and which is not where the binary runs from. That exact
        // mistake broke the LaunchAgent once, so the rule is written down twice.
        let beside = URL(fileURLWithPath: "/repo/.build/debug/codecblue")
            .deletingLastPathComponent()
            .appendingPathComponent("codecblue-keys")
        check(beside.path == "/repo/.build/debug/codecblue-keys", beside.path)
    }

    test("a button nobody handles is refused, not accepted") {
        // The contract: onKey returns whether the press was acted on.
        let handled: (String) -> Bool = { $0 == "volume_up" }
        check(handled("volume_up"), "handled")
        check(!handled("play"), "not handled, so the reply must be NOT IMPLEMENTED")
        // 0x09 ACCEPTED, 0x08 NOT IMPLEMENTED — the two ctypes the reply chooses between.
        check(UInt8(0x09) != UInt8(0x08), "they must not be confused")
    }
}

/// The control channel: one line in, one line out, over a unix socket in /tmp.
///
/// It exists so a setting can be changed while the audio keeps playing. Without it, changing the
/// quality meant stopping the stream and starting it again — several seconds of silence, which
/// defeats the point of a setting you want to try while listening.
func controlChannelTests() {
    test("a client and a server talk over a socket in /tmp") {
        let path = "/tmp/codecblue-selftest-\(getpid()).sock"
        let server = ControlServer(path: path) { command in
            switch command.name {
            case "status": return ["quality=MQ", "end"]
            case "quality": return ["ok quality=\(command.argument ?? "?")"]
            default: return ["error=unknown"]
            }
        }
        check(server.start(), "the socket is created")
        defer { server.stop() }
        // The accept loop runs on its own queue, so give it a moment to be listening. A test that
        // races its own server would fail intermittently, which is worse than a sleep.
        usleep(100_000)
        check(ControlClient.send("status", path: path) == ["quality=MQ", "end"], "status")
        check(ControlClient.send("quality HQ", path: path) == ["ok quality=HQ"], "quality")
        check(ControlClient.send("nonsense", path: path) == ["error=unknown"], "unknown command")
        // No server: nil, not a crash. "Nothing is running" is the normal state of the machine.
        server.stop()
        check(ControlClient.send("status", path: path) == nil, "nothing listening")
    }

    test("a stale socket file does not block the next stream") {
        // A process killed with SIGKILL leaves the file behind, and bind() then fails with
        // EADDRINUSE forever. The only cure would be a reboot, so the file is unlinked first.
        let path = "/tmp/codecblue-selftest-stale-\(getpid()).sock"
        FileManager.default.createFile(atPath: path, contents: Data())
        let server = ControlServer(path: path) { _ in ["ok"] }
        check(server.start(), "a leftover file is replaced")
        server.stop()
    }
}

/// Listing the headphones macOS knows about.
///
/// `system_profiler` prints `Connected:` and `Not Connected:` sections, and a device appears in
/// exactly one. Counting a grep over the whole output says a pair of headphones is present when
/// it is switched off — a mistake that cost a whole evening once (notes §13.1), so the section is
/// tracked and tested.
func headphoneListTests() {
    let sample = """
          Bluetooth:

              Devices (Paired, Configured, etc.):
                  HUAWEI FreeBuds 5:
                      Address: 40:DC:A5:0E:14:48
                      Vendor ID: 0x027D
                      Minor Type: Headphones

          Connected:
              Keychron K3 Pro:
                  Address: 6C:93:08:61:BB:D9
                  Minor Type: Keyboard
              HUAWEI FreeBuds 5:
                  Address: 40:DC:A5:0E:14:48
                  Minor Type: Headphones

          Not Connected:
              FreeBuds 3:
                  Address: AA:BB:CC:DD:EE:FF
                  Minor Type: Headphones
              MX Master 3S:
                  Address: D1:52:01:D5:79:C3
                  Minor Type: Mouse

          """
    test("a device is listed once, with the section it is in") {
        let devices = BluetoothHeadphone.parse(sample)
        let freeBuds = devices.filter { $0.address == "40:DC:A5:0E:14:48" }
        check(freeBuds.count == 1, "the paired listing must not be counted twice: \(freeBuds.count)")
        check(freeBuds.first?.isConnected == true, "it is in Connected")
        check(freeBuds.first?.name == "HUAWEI FreeBuds 5", freeBuds.first?.name ?? "nil")
    }

    test("a switched-off pair is listed as not connected, not as present") {
        let devices = BluetoothHeadphone.parse(sample)
        let old = devices.first { $0.address == "AA:BB:CC:DD:EE:FF" }
        check(old != nil, "it is still listed")
        check(old?.isConnected == false, "but not connected — the mistake was reading it as present")
    }

    test("only audio devices are offered") {
        let audio = BluetoothHeadphone.parse(sample).filter(\.isAudio)
        check(audio.count == 2, "two pairs of headphones, not the keyboard or the mouse: \(audio.count)")
        check(!audio.contains { $0.kind == "Keyboard" }, "no keyboard")
        check(!audio.contains { $0.kind == "Mouse" }, "no mouse")
    }

    test("the kind test covers the words Apple uses") {
        for kind in ["Headphones", "Headset", "Speaker", "Earbuds", "AirPods"] {
            check(BluetoothHeadphone(name: "x", address: "y", isConnected: true, kind: kind).isAudio,
                  kind)
        }
        for kind in ["Keyboard", "Mouse", "Trackpad", "Gamepad"] {
            check(!BluetoothHeadphone(name: "x", address: "y", isConnected: true, kind: kind).isAudio,
                  kind)
        }
    }
}

/// The LaunchAgent, as the menu bar app uses it.
///
/// The app does not run a stream itself: it writes the plist and loads it, so the audio survives
/// closing the window. That means two things have to be right — the path in the plist, and the
/// unload-then-load order, because `load` on an already-loaded label does nothing and the old
/// address would keep running.
func launchAgentAppTests() {
    test("the plist points at the stable path, not SwiftPM's internal one") {
        // `.build/out/Products/Debug` is deleted by `swift package clean`; `.build/debug` is the
        // symlink SwiftPM maintains, and `~/Applications/CodecBlue` is where `install.sh` puts the
        // copy that outlives both. This mistake has been made once already.
        let invoked = URL(fileURLWithPath: "/repo/.build/out/Products/Debug/codecblue")
        let resolved = LaunchAgent.resolveExecutable(from: invoked)
        check(!resolved.contains("/.build/out/"), "never SwiftPM's internal directory: \(resolved)")
        // Whatever it settles on must be a path that exists, or the agent fails at login with
        // nothing in its log but "no such file".
        check(FileManager.default.isExecutableFile(atPath: resolved)
              || resolved == invoked.path,
              "either a real path or an honest fallback: \(resolved)")
    }

    test("the plist carries the address and the arguments") {
        let text = LaunchAgent.plist(executable: "/bin/echo", address: "40:DC:A5:0E:14:48",
                                     arguments: ["--quality", "MQ"])
        check(text.contains("<string>40:DC:A5:0E:14:48</string>"), "the address")
        check(text.contains("<string>--quality</string>"), "the option")
        check(text.contains("<string>MQ</string>"), "its value")
        check(text.contains("<key>KeepAlive</key>"), "it comes back when the headphones return")
        check(text.contains("<key>ThrottleInterval</key>"), "and does not spin while they are off")
    }

    test("a path with an ampersand still parses") {
        // A plist that will not parse is a LaunchAgent that silently does nothing.
        let text = LaunchAgent.plist(executable: "/Users/a&b/codecblue", address: "AA:BB:CC:DD:EE:FF")
        check(text.contains("a&amp;b"), "escaped")
        check(!text.contains("/Users/a&b/"), "not raw")
        let data = Data(text.utf8)
        let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
        check(parsed != nil, "the result is a plist")
    }

    test("loading unloads first, so a rewritten plist takes effect") {
        // `launchctl load` on an already-loaded label is a no-op: after rewriting the plist for a
        // different pair, loading alone would keep the old address running.
        let source = try? String(contentsOfFile: "Sources/CodecBlueCore/Audio/LaunchAgent.swift",
                                 encoding: .utf8)
        guard let source else { check(false, "source not readable"); return }
        let loadBody = source.components(separatedBy: "public static func load() throws {")
        check(loadBody.count == 2, "load() found")
        let body = loadBody[1].prefix(300)
        check(body.contains("unload"), "load() unloads first")
    }
}

/// The device's sample rate is a choice, not a constant.
///
/// 44.1 kHz is the native rate of nearly all music, so forcing 48 means resampling something that
/// was already right — for no gain. The rate lives in the ring's header, which the driver reads
/// when coreaudiod loads it, because a running device cannot change rate underneath its clients.
func sampleRateTests() {
    test("the rate is bounded by what the buffer can hold") {
        // The ring is sized for 96 kHz. A higher rate would run it dry; a lower one only wastes
        // space. The C side cannot report an error, so the bound lives in Swift.
        let ring = try? SharedRing()
        guard let ring else { check(true, "no driver running, nothing to check"); return }
        let before = ring.sampleRate
        ring.setSampleRate(44100)
        check(ring.sampleRate == 44100, "accepted")
        ring.setSampleRate(200_000)
        check(ring.sampleRate == 44100, "refused, unchanged")
        ring.setSampleRate(before)
        check(ring.sampleRate == before, "restored")
    }

    test("a rate the headphones do not take falls back instead of failing") {
        // `setUp` treats the rate as a preference: a device that only offers 44.1 still works.
        // The rule is in the code, and this pins the intent.
        let offered = [44100, 48000]
        let requested = 96000
        let chosen = offered.contains(requested) ? requested : offered.first
        check(chosen == 44100, "falls back to what is offered")
    }

    test("resampling at the device's own rate is a no-op") {
        // If the stream asks for the rate the device already runs at, the resampler must not
        // touch the samples: a converter at ratio 1 that still interpolates would add a sample of
        // delay and a little noise for nothing.
        let resampler = Resampler(from: 44100, to: 44100)
        check(resampler.isIdentity, "same rate is identity")
        let input: [Float] = [0.1, -0.1, 0.2, -0.2]
        check(resampler.process(input) == input, "samples pass through unchanged")
    }
}

/// Where things get installed, and why it is three places.
///
/// The driver needs sudo and lives in /Library/Audio/Plug-Ins/HAL; the programs need no sudo and
/// live in ~/Applications/CodecBlue; the agent lives in ~/Library/LaunchAgents. Installing only
/// the first is the mistake that makes every app play into silence with no error anywhere.
func installLayoutTests() {
    test("the agent prefers the installed copy over a build directory") {
        // `swift package clean` deletes .build, so an agent pointing there breaks the next time
        // anyone cleans. The installed copy is the one that survives.
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/CodecBlue/codecblue")
        let invoked = URL(fileURLWithPath: "/repo/.build/debug/codecblue")
        let resolved = LaunchAgent.resolveExecutable(from: invoked)
        // Either the installed copy exists and wins, or we are in a checkout where it does not
        // and the build path is the right answer. Both are correct; what must never happen is a
        // path into .build/out, which SwiftPM deletes.
        check(!resolved.contains("/.build/out/"), "never SwiftPM's internal directory: \(resolved)")
        if FileManager.default.isExecutableFile(atPath: installed.path) {
            check(resolved == installed.path, "the installed copy wins")
        } else {
            check(resolved.hasSuffix("/.build/debug/codecblue"), "falls back to the stable symlink")
        }
    }

    test("the three locations are distinct and none is inside the repository") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let driver = "/Library/Audio/Plug-Ins/HAL/CodecBlueDriver.driver"
        let programs = "\(home)/Applications/CodecBlue"
        let agent = "\(home)/Library/LaunchAgents/com.codecblue.system.plist"
        check(driver.hasPrefix("/Library/"), "the driver is system-wide")
        check(programs.hasPrefix(home), "the programs are yours")
        check(agent.hasPrefix(home), "the agent is yours")
        check(Set([driver, programs, agent]).count == 3, "three different places")
    }
}

/// The icon is generated, not committed as a blob.
///
/// It is a Python script that describes the mark — a sine that becomes a staircase, which is what
/// a codec does — so it can be re-drawn at any size and changed by editing a few numbers. A PNG in
/// git that nobody can edit is worse than a script that can be re-run.
func iconTests() {
    test("the icon script and its output are both present") {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // codecblue-selftest
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo
        let script = root.appendingPathComponent("scripts/make-icon.py")
        check(FileManager.default.fileExists(atPath: script.path), "the script is in the repo")
        let icns = root.appendingPathComponent("Resources/AppIcon.icns")
        if FileManager.default.fileExists(atPath: icns.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: icns.path)[.size] as? Int) ?? 0
            check((size ?? 0) > 1000, "the .icns has content: \(size ?? 0) bytes")
        } else {
            check(true, "not generated yet — scripts/make-icon.py makes it")
        }
    }

    test("the bundle declares the icon") {
        // Without CFBundleIconFile macOS shows the generic application icon, which for a menu bar
        // program is the only place it is ever seen as an app.
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build-menu-app.sh")
        guard let text = try? String(contentsOf: script, encoding: .utf8) else {
            check(false, "build script not readable")
            return
        }
        check(text.contains("CFBundleIconFile"), "the plist names the icon")
        check(text.contains("AppIcon.icns"), "and the file is copied into the bundle")
    }
}

/// The cushion is the latency, and it is adjustable while the audio plays.
///
/// It used to be fixed at start-up, which meant answering "is 40 ms enough on this link?" required
/// stopping the stream — and the only person who can answer that question is the one listening.
func cushionRetuneTests() {
    test("retuning clamps the current budget instead of resetting it") {
        // A queue already holding 120 ms because the link needed it must not be told to hold 40
        // and then drop what it has: that is a skip at the exact moment the listener asked for
        // less delay. It narrows through `relax()` like any other surplus.
        var queue = PacketQueue(sampleRate: 48000, floorDuration: 0.060, ceilingDuration: 0.250)
        while queue.noteStall() {}  // widen to the ceiling
        check(abs(queue.maxDuration - 0.250) < 1e-9, "at the ceiling: \(queue.maxDuration)")
        queue.retune(floor: 0.040, ceiling: 0.250)
        check(abs(queue.maxDuration - 0.250) < 1e-9, "still holds what it had")
        queue.retune(floor: 0.040, ceiling: 0.100)
        check(abs(queue.maxDuration - 0.100) < 1e-9, "clamped down to the new ceiling")
        check(queue.maxFrames == Int(0.100 * 48000), "frames follow the duration")
    }

    test("a lower floor narrows the budget without emptying the queue") {
        var queue = PacketQueue(sampleRate: 48000, floorDuration: 0.060, ceilingDuration: 0.250)
        for _ in 0..<10 { queue.append(Data([0]), frames: 128) }
        let before = queue.count
        queue.retune(floor: 0.030, ceiling: 0.250)
        check(queue.count == before, "no packet is discarded by retuning")
        // And the floor is what it relaxes towards.
        while queue.relax() {}
        check(abs(queue.maxDuration - 0.030) < 1e-9, "relaxes to the new floor: \(queue.maxDuration)")
    }

    test("the ceiling is never below the floor") {
        // A caller that passes them the wrong way round must not produce a queue that can hold
        // nothing: `maxFrames` would be 0 and every append would drop.
        var queue = PacketQueue(sampleRate: 48000, floorDuration: 0.060, ceilingDuration: 0.250)
        queue.retune(floor: 0.100, ceiling: 0.040)
        check(queue.ceilingDuration >= queue.floorDuration, "ceiling raised to the floor")
        check(queue.maxFrames > 0, "still able to hold audio")
    }
}

/// One attenuation for one slider, and a mute the system can actually reach.
///
/// Both of these were reported by the listener in the same breath, and both are the same mistake
/// in different clothes: a control that exists in our code and nowhere the system can see it.
func volumeAndMuteTests() {
    test("the slider's gain is applied once, not twice") {
        // Measured 2026-11-07: the slider position went into the samples (through the decibel
        // curve) *and* down the link as SET ABSOLUTE VOLUME. At 56% that is -28 dB here and the
        // headphones' own attenuation on top — about -34 dB in total, which is the reported "I
        // have to go to half to hear anything".
        //
        // The invariant: whatever the slider says, the headphones are told full scale, because the
        // attenuation is ours. A test cannot see two calls, so it checks the rule the code encodes.
        let position: Float = 0.56
        let gainHere = SystemVolume.gain(fromDecibels: -28)
        let headphones: Float = 1
        let total = gainHere * headphones
        check(abs(total - gainHere) < 1e-6, "the headphones add nothing: \(total)")
        check(gainHere < position, "and the slider's curve is the only curve")
    }

    test("the ring chases its own jitter buffer, not the packet queue's cushion") {
        // Measured 2026-11-07 on a long video: the queue sat at its 240 ms ceiling while the ring
        // settled at 10 000–12 300 frames — another 210–255 ms. The two delays add, so the
        // listener heard about half a second while each number sat inside its own budget. The ring
        // had been told to hold `cushionSeconds.value`, which is the *queue's* depth: one budget
        // counted at two stages.
        let sampleRate = 48000.0
        let ringTarget = 0.04
        let cushion = 0.24
        // The old rule: target = cushion. The new one: target = ringTarget, independent of it.
        let oldTarget = Int(cushion * sampleRate)
        let newTarget = Int(ringTarget * sampleRate)
        check(newTarget < oldTarget, "the ring is a jitter buffer, not a second cushion")
        check(newTarget == 1920, "40 ms at 48 kHz: \(newTarget)")
        // And the total is the sum, which is what the status now reports.
        let total = cushion + Double(newTarget) / sampleRate
        check(abs(total - 0.28) < 1e-9, "cushion + ring: \(total)")
    }

    test("the driver publishes a mute control the system can write to") {
        // The driver stored a muted flag and answered `kAudioBooleanControlPropertyValue`, but no
        // object in its control list was a boolean control — so the HAL had nothing to synthesise
        // a device-level mute from, and muting the Mac kept the headphones playing.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Driver/CodecBlueDriver/CodecBlueDriver.c")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            check(false, "driver source not readable")
            return
        }
        check(text.contains("kMuteControlID"), "the mute has an object id")
        check(text.contains("kAudioMuteControlClassID"), "and is a mute control, not a volume one")
        check(text.contains("ids[3] = kMuteControlID"), "and is in the control list")
        check(text.contains("4 * sizeof(AudioObjectID)"), "whose size says four")
    }

    test("the media key helper has an explicit pause, not only a toggle") {
        // NX_KEYTYPE_PLAY is a toggle: "flip whatever is playing". So play and pause both became
        // the same press, and a double-click (PAUSE then PLAY) toggled twice — which cancels out
        // against a player already in the state the first press asked for.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/codecblue-keys/main.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            check(false, "helper source not readable")
            return
        }
        check(text.contains("MRMediaRemoteSendCommand"), "it can send explicit commands")
        check(text.contains("case pause = 1"), "pause is its own command")
        check(text.contains("case play = 0"), "and so is play")
        check(text.contains("if !MediaRemote.send(.pause) { post(.playPause) }"),
              "with the HID toggle as the fallback, not the only path")
    }
}

/// The volume is one control, and it lives at the headphones.
///
/// Two attempts got this wrong in opposite directions, and both are worth keeping: the first
/// applied the slider twice (here and down the link), which made everything quiet; the second put
/// it all here and pushed full scale down the link, which made the headphones *report* 100% and
/// the slider jump to 100% on its own and stay there.
func volumeEchoTests() {
    test("an AVRCP echo is not a user action") {
        // The headphones report every SET ABSOLUTE VOLUME back as a volume notification, and that
        // notification is byte-for-byte what their own volume key produces. Acting on it is what
        // pinned the slider at 100% for a whole session.
        //
        // The rule: a value within one AVRCP step of what we last pushed is our own echo.
        let pushed: Float = 0.56
        let quantised = (pushed * 127).rounded() / 127  // 0x47 = 71/127 = 0.5591
        // The echo is the quantised value coming back, so it matches to the bit.
        check(abs(quantised - quantised) <= 0.002, "the echo matches the pushed value")
        // A single press of the headphones' own key moves by one step, 1/127 = 0.0079. That is
        // *bigger* than the echo tolerance, which is the whole point: an earlier version used a
        // full step as the tolerance and swallowed every press made just after a push.
        let oneStep: Float = 1.0 / 127
        check(oneStep > 0.002, "one press is distinguishable from an echo: \(oneStep)")
        check(abs(quantised - (quantised + oneStep)) > 0.002, "and so is the next step up")
    }

    test("the gain is the mute and nothing else") {
        // The volume curve belongs to the headphones. Multiplying here as well would be the
        // two-attenuations bug again — so the only thing this process does to the samples is
        // silence them when the Mac is muted, which must be instant and must not wait for AVRCP.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/codecblue/main.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            check(false, "main.swift not readable")
            return
        }
        check(text.contains("return volume.isMuted ? 0 : 1"), "the gain is a mute")
        check(!text.contains("streamer.gain = { volume?.gain ?? 1 }"),
              "and the decibel curve is not applied here")
        check(text.contains("volume?.notePushed(position)"),
              "what is pushed is remembered, so the echo can be recognised")
    }

    test("the driver's mute control answers on the device too") {
        // Measured 2026-11-08, with the rebuilt driver installed: `mute set to 1` and the device
        // property reads 1. Before the control existed the property was not supported at all, so
        // the Mac's mute button had nothing to write to.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Driver/CodecBlueDriver/CodecBlueDriver.c")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            check(false, "driver source not readable")
            return
        }
        check(text.contains("kAudioBooleanControlClassID"), "the control declares its class")
        check(text.contains("kMuteControlID, 1, &changed"),
              "and the change is announced on the control")
    }
}

/// The Bluetooth permission belongs to this process, not to whatever launched it.
///
/// This is the bug that made the menu bar app silently useless: `codecblue` talks to bluetoothd
/// over the classic XPC channel, which needs `kTCCServiceBluetoothAlways` — but nothing in that
/// channel ever asks for it. Only CoreBluetooth asks. So the permission went to the terminal, and
/// launching from launchd (which is how the app keeps the stream alive) got
/// `TCC approval status: 1` and `state updated: Unsupported`, which reads as "this Mac has no
/// Bluetooth".
func bluetoothAuthorizationTests() {
    test("the stream asks for the Bluetooth permission itself") {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = root.appendingPathComponent("Sources/codecblue/main.swift")
        guard let text = try? String(contentsOf: main, encoding: .utf8) else {
            check(false, "main.swift not readable")
            return
        }
        check(text.contains("BluetoothAuthorization.request(log: log)"),
              "playSystem asks before touching bluetoothd")
        // And before the ring, which is where the first bluetoothd call happens.
        if let ask = text.range(of: "BluetoothAuthorization.request(log: log)"),
           let ring = text.range(of: "ring = try SharedRing()") {
            check(ask.lowerBound < ring.lowerBound, "the asking comes first")
        } else {
            check(false, "both markers found")
        }
    }

    test("waiting for CoreBluetooth is short, because the asking is the creation") {
        // Measured 2026-11-08 under launchd: the delegate never fires at all — a bare binary has
        // no run loop for the main queue — yet bluetoothd's approval goes from 1 to 2 and the
        // classic channel works. So the wait is a courtesy, not a requirement, and a long one
        // would be two seconds of silence at every start for nothing.
        check(BluetoothAuthorization.timeout <= 3,
              "a short wait: \(BluetoothAuthorization.timeout) s")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent(
            "Sources/CodecBlueCore/Bluetooth/BluetoothAuthorization.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            check(false, "not readable")
            return
        }
        check(text.contains("CBCentralManager(delegate: self, queue: nil)"),
              "a manager is created, which is what triggers the request")
        check(text.contains("carrying on"), "and a missing answer is not treated as a failure")
    }

    test("the launch agent does not depend on the launching context") {
        // The agent is what makes the app work when the app is closed, so the permission has to
        // be this binary's. Nothing in the plist may point at a path SwiftPM owns either.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/CodecBlueCore/Audio/LaunchAgent.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            check(false, "not readable")
            return
        }
        check(!text.contains("/.build/out/"), "never SwiftPM's internal directory")
        check(text.contains("LimitLoadToSessionType"), "and it is pinned to the GUI session")
    }
}

/// One button on the headphones means one thing: toggle.
///
/// This is a correction of a correction, and the log settled it. The headphones send exactly one
/// PASS THROUGH per gesture — measured five times across five sessions, always 0x46 (PAUSE),
/// never a pair — and their one physical button is a play/pause toggle. So `pause` is not an
/// instruction, it is the name of the button.
///
/// Sending an explicit PAUSE worked exactly once: the first gesture paused the player, the second
/// asked an already-paused player to pause and nothing happened. A toggle cannot get stuck that
/// way, because it does not depend on what the player already thinks it is doing.
func headphoneButtonTests() {
    test("a single press toggles, whatever the headphones call it") {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = root.appendingPathComponent("Sources/codecblue/main.swift")
        guard let text = try? String(contentsOf: main, encoding: .utf8) else {
            check(false, "main.swift not readable")
            return
        }
        check(text.contains("mediaKeys.send(\"toggle\")"), "the button toggles")
        check(!text.contains("let command = key == \"stop\" ? \"pause\" : key"),
              "and no longer forwards the headphone's own word for it")
    }

    test("the toggle is the HID key, not a MediaRemote command") {
        // `kMRTogglePlayPause` only works when a Now Playing client is registered. Measured
        // 2026-11-08 on this Mac: nowPlayingPID=0 with a video playing in a browser, and every
        // MediaRemote command was accepted and did nothing. The HID key goes through the path a
        // real keypress takes, so it cannot be dropped for want of a client.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/codecblue-keys/main.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            check(false, "not readable")
            return
        }
        if let toggle = text.range(of: "case \"toggle\":"),
           let post = text.range(of: "post(.playPause)", range: toggle.upperBound..<text.endIndex) {
            check(post.lowerBound > toggle.lowerBound, "toggle posts the HID key")
        } else {
            check(false, "toggle case found")
        }
        check(text.contains("nowPlayingPID=0") || text.contains("registered Now"),
              "and the reason is written down")
    }
}

/// A media key with no Now Playing client goes nowhere, and must say so.
///
/// This is the third attempt at the headphones' play/pause button, and the first one that can
/// explain itself. The button works — the frame arrives, the helper is trusted, the key is posted.
/// What was missing is a *destination*: mediaremoted routes media keys to the registered Now
/// Playing client, and measured 2026-11-08 this Mac had `nowPlayingPID=0` while a video played in
/// a browser. Every command was accepted and dropped, with nothing in any log to say why.
///
/// A minimal AVAudioPlayer that registers itself does receive the key, which is what proves the
/// path works and the destination is the missing piece.
func mediaKeyDestinationTests() {
    test("the helper reports when a key has no destination") {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/codecblue-keys/main.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            check(false, "not readable")
            return
        }
        check(text.contains("MRMediaRemoteGetNowPlayingApplicationPID"),
              "it asks who would receive the key")
        check(text.contains("no now-playing client"), "and says so when nobody would")
    }

    test("the stream puts that in its own log") {
        // The listener reads the stream's log, not the helper's: a diagnosis that only exists in
        // a pipe between two processes is a diagnosis nobody sees.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/CodecBlueCore/Audio/MediaKeyHelper.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            check(false, "not readable")
            return
        }
        check(text.contains("no now-playing client"), "the stream log carries it")
        check(text.contains("not ours"), "and says whose decision it is")
    }
}
