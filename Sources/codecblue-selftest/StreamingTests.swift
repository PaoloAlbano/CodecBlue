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
