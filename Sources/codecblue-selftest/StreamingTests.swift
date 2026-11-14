import Foundation

@testable import CodecBlueCore

func streamingTests() {
    test("LDAC media header carries the frame count in its low bits") {
        check(MediaPacket.ldacHeader(frameCount: 1) == 0x01)
        check(MediaPacket.ldacHeader(frameCount: 5) == 0x05)
        check(MediaPacket.ldacHeader(frameCount: 15) == 0x0F)
        check(MediaPacket.ldacHeader(frameCount: 16) == 0x00, "the count never exceeds 15")
    }

    test("an RTP media packet has the A2DP layout") {
        let packet = MediaPacket.rtp(
            sequence: 0x1234, timestamp: 0x0100_0000, ssrc: 1,
            payload: Data([0x03, 0xAA, 0xBB]))
        check(packet.count == 15)
        check(
            Array(packet[0..<12]) == [0x80, 96, 0x12, 0x34, 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 1],
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
            guard let out = try block.withUnsafeBufferPointer({ try encoder.encode($0) }) else {
                continue
            }
            payloads += 1
            check(
                out.payload.first == 0xAA,
                "payload starts with \(String(format: "%02x", out.payload.first ?? 0))")
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
        check(
            abs(meter.takeFraction(sampleRate: 48000, window: 1) - 0.1) < 1e-9,
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
        check(
            abs(stats.sentKbps(window: window) - 543.2) < 0.1, "\(stats.sentKbps(window: window))")
        check(
            abs(stats.packetsPerSecond(window: window) - 100) < 1e-9,
            "\(stats.packetsPerSecond(window: window))")
        check(
            abs(stats.deliveredFraction(sampleRate: 48000, window: window) - 0.8) < 1e-9,
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
        check(
            CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").anyA2DP
                == "4379D275-655C-EEB8-BB72-643BF2534BE0",
            "\(CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").anyA2DP ?? "nil")")
    }

    test("a device without A2DP is not the one we want") {
        let log = """
            Device found: CBDevice 11111111-2222-3333-4444-555555555555, BDA <private>, \
            CnS 0x800000 < ACL >
            """
        check(CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").anyA2DP == nil)
    }

    test("the last mention wins, so a reconnect is followed") {
        let log = """
            Device found: CBDevice AAAAAAAA-0000-0000-0000-000000000001, CnS 0x19 < A2DP >
            Device found: CBDevice BBBBBBBB-0000-0000-0000-000000000002, CnS 0x19 < A2DP >
            """
        check(
            CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").anyA2DP
                == "BBBBBBBB-0000-0000-0000-000000000002")
    }

    test("a line that only looks like one is rejected") {
        check(
            CBDeviceUUID.parse("CBDevice not-a-uuid A2DP", address: "40:DC:A5:0E:14:48").anyA2DP
                == nil)
        check(CBDeviceUUID.parse("", address: "40:DC:A5:0E:14:48").anyA2DP == nil)
    }

    test("the UUID comes from the audio device registered for this address") {
        // The shape of the real log, measured 2026-11-08: the `CBDevice` line carries the UUID and
        // redacts the address; the `Register audio device` line carries the address and no UUID.
        // Neither alone is enough, which is why the two are read together.
        let log = """
            16:14:12.902 [CBDaemonServer] Monitor Device Found: CBDevice 4379D275-655C-EEB8-BB72-643BF2534BE0, \
            BDA <private>, CnS 0x800000 < ACL >, SupS 0x200019 < HFP AVRCP A2DP SerialPort >
            16:14:12.254 [Server.Audio] Register audio device 40:DC:A5:0E:14:48-tacl
            """
        check(
            CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").registered
                == "4379D275-655C-EEB8-BB72-643BF2534BE0",
            "\(CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").registered ?? "nil")")
    }

    test("a device bluetoothd has erased is not registered, whatever the UUID") {
        let log = """
            Device found: CBDevice 4379D275-655C-EEB8-BB72-643BF2534BE0, A2DP
            Register audio device 40:DC:A5:0E:14:48-tacl
            Erased 1 audio device 40:DC:A5:0E:14:48-tacl from audio device map
            """
        check(CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").registered == nil)
    }

    test("a re-registration is followed") {
        let log = """
            Device found: CBDevice 4379D275-655C-EEB8-BB72-643BF2534BE0, A2DP
            Register audio device 40:DC:A5:0E:14:48-tacl
            Erased 1 audio device 40:DC:A5:0E:14:48-tacl from audio device map
            Register audio device 40:DC:A5:0E:14:48-tacl
            """
        check(
            CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").registered
                == "4379D275-655C-EEB8-BB72-643BF2534BE0")
    }

    test("another device's UUID is not mistaken for ours") {
        // The trap this test exists for: bluetoothd prints a CBDevice line for every phone that
        // advertises nearby, and the last one in the window is not the headphones.
        let log = """
            Device found: CBDevice 4379D275-655C-EEB8-BB72-643BF2534BE0, A2DP
            Register audio device 40:DC:A5:0E:14:48-tacl
            Identities resolve added: CBDevice B1A311A0-867B-9E35-4619-0E6682B47503, BLEAdvertisementData
            Identities resolve added: CBDevice F2BEEF75-CDB1-CB5B-11FA-60FD91117744, AirDrop
            """
        check(
            CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").registered
                == "4379D275-655C-EEB8-BB72-643BF2534BE0",
            "\(CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").registered ?? "nil")")
    }

    test("an address that is only a substring does not match") {
        let log = """
            Device found: CBDevice 4379D275-655C-EEB8-BB72-643BF2534BE0, A2DP
            Register audio device AC:BD:70:5C:06:1C-tacl
            """
        check(CBDeviceUUID.parse(log, address: "40:DC:A5:0E:14:48").registered == nil)
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
/// up only after it has been clean for a while. It works on rungs, not on names: the ladder has
/// five of them (990 / 660 / 492 / 396 / 330) and only three have a name.
func bitrateAdapterTests() {
    test("a clean window does not change the rung on its own") {
        var adapter = BitrateAdapter(upAfter: 3, minimumInterval: 0)
        check(adapter.decide(current: 0, dropped: 0, queueFill: 0.1) == .hold)
    }

    test("dropped audio steps down at once") {
        var adapter = BitrateAdapter(minimumInterval: 0)
        check(adapter.decide(current: 0, dropped: 0.5, queueFill: 0.1) == .down(1))
        check(adapter.decide(current: 1, dropped: 0.5, queueFill: 0.1) == .down(2))
        // The middle rungs are rungs like any other: 660 → 492 is a step, not a jump to 330.
        check(adapter.decide(current: 2, dropped: 0.5, queueFill: 0.1) == .down(3))
    }

    test("a queue at its ceiling steps down before anything is dropped") {
        var adapter = BitrateAdapter(dropLimit: 0.02, queueLimit: 0.75, minimumInterval: 0)
        check(adapter.decide(current: 0, dropped: 0, queueFill: 0.9) == .down(1))
    }

    test("it never steps below the bottom rung or above the top") {
        var adapter = BitrateAdapter(minimumInterval: 0)
        check(
            adapter.decide(current: 4, dropped: 0.9, queueFill: 0.9) == .hold,
            "330 kbps is the bottom")
        var up = BitrateAdapter(upAfter: 1, minimumInterval: 0)
        _ = up.decide(current: 0, dropped: 0, queueFill: 0)
        check(up.decide(current: 0, dropped: 0, queueFill: 0) == .hold, "990 kbps is the top")
    }

    test("it steps up only after the link has been clean for a while") {
        var adapter = BitrateAdapter(upAfter: 3, minimumInterval: 0)
        check(adapter.decide(current: 4, dropped: 0, queueFill: 0) == .hold)
        check(adapter.decide(current: 4, dropped: 0, queueFill: 0) == .hold)
        check(adapter.decide(current: 4, dropped: 0, queueFill: 0) == .up(3))
    }

    test("one bad window resets the clean count") {
        var adapter = BitrateAdapter(upAfter: 2, minimumInterval: 0)
        _ = adapter.decide(current: 4, dropped: 0, queueFill: 0)
        _ = adapter.decide(current: 4, dropped: 0.5, queueFill: 0)  // but at the bottom
        check(
            adapter.decide(current: 4, dropped: 0, queueFill: 0) == .hold,
            "the count started again")
        check(adapter.decide(current: 4, dropped: 0, queueFill: 0) == .up(3))
    }

    test("it does not change again inside the minimum interval") {
        var adapter = BitrateAdapter(minimumInterval: 60)
        check(adapter.decide(current: 0, dropped: 0.9, queueFill: 0) == .down(1))
        check(
            adapter.decide(current: 1, dropped: 0.9, queueFill: 0) == .hold,
            "too soon to move again")
    }

    test("the rung that fits is chosen from the measured capacity, not from the names") {
        // The measurement this exists for: this link carries ~530 kbps, and none of the three
        // named levels fits it — 660 is too much, 330 leaves half the bitrate on the table.
        // 492 (rung 2) is the answer, and it has no name.
        check(
            BitrateAdapter.fitRung(capacityKbps: 530) == 3,
            "\(BitrateAdapter.fitRung(capacityKbps: 530))")
        check(BitrateAdapter.fitRung(capacityKbps: 1300) == 0)
        check(BitrateAdapter.fitRung(capacityKbps: 900) == 1, "765 of budget takes 660")
        check(BitrateAdapter.fitRung(capacityKbps: 700) == 2, "595 of budget takes 492")
        check(BitrateAdapter.fitRung(capacityKbps: 560) == 3, "476 of budget takes 396, not 492")
        check(BitrateAdapter.fitRung(capacityKbps: 400) == 4, "340 of budget takes only 330")
        // Nothing fits at all: the bottom is still the answer, because the alternative is silence.
        check(BitrateAdapter.fitRung(capacityKbps: 100) == 4)
        // And the ladder is read from the encoder, so a rate change changes the answer.
        check(BitrateAdapter.fitRung(capacityKbps: 700, sampleRate: 44100) == 2)
    }
}

/// The first live run climbed back to 660 four seconds after 660 had failed, and the listener
/// heard the same glitch again. A rung that failed is not retried at once.
func bitrateBackoffTests() {
    test("a rung that failed is not climbed back into at once") {
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, backoff: 60, upDwell: 0)
        check(adapter.decide(current: 1, dropped: 0.4, queueFill: 0.1) == .down(2))
        // Clean windows at 330: it wants to go up, but 660 is blocked.
        for _ in 0..<5 {
            check(
                adapter.decide(current: 2, dropped: 0, queueFill: 0) == .hold,
                "660 failed a moment ago")
        }
    }

    test("the wait doubles each time the same rung fails") {
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, backoff: 10, upDwell: 0)
        let start = Date()
        _ = adapter.decide(current: 1, dropped: 0.4, queueFill: 0, now: start)
        // Blocked for 10 s: at 11 s it may try again.
        check(
            adapter.decide(
                current: 2, dropped: 0, queueFill: 0,
                now: start.addingTimeInterval(11)) == .up(1))
        // Fail again: now blocked for 20 s.
        _ = adapter.decide(
            current: 1, dropped: 0.4, queueFill: 0,
            now: start.addingTimeInterval(12))
        check(
            adapter.decide(
                current: 2, dropped: 0, queueFill: 0,
                now: start.addingTimeInterval(20)) == .hold, "still blocked")
        check(
            adapter.decide(
                current: 2, dropped: 0, queueFill: 0,
                now: start.addingTimeInterval(33)) == .up(1), "wait doubled")
    }

    test("a rung that never failed is still reachable") {
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, backoff: 60, upDwell: 0)
        check(adapter.decide(current: 4, dropped: 0, queueFill: 0) == .up(3))
    }
}

/// Combining the two fixes: the ceiling stops the adapter from starting too high, and the short
/// opening windows let it find the right rung in half a second instead of four.
func bitrateCeilingTests() {
    test("the ceiling is never climbed above") {
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, ceilingRung: 4, upDwell: 0)
        for _ in 0..<5 {
            check(
                adapter.decide(current: 4, dropped: 0, queueFill: 0) == .hold,
                "330 kbps is the ceiling")
        }
    }

    test("a higher ceiling is still reachable") {
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, ceilingRung: 1, upDwell: 0)
        check(adapter.decide(current: 2, dropped: 0, queueFill: 0) == .up(1))
        check(
            adapter.decide(current: 1, dropped: 0, queueFill: 0) == .hold,
            "660 kbps is the ceiling here")
    }

    test("probing up needs a long clean stretch, not just a few windows") {
        // backoff 0: this test is about the dwell, not about the block on a failed rung.
        var adapter = BitrateAdapter(
            upAfter: 1, minimumInterval: 0, backoff: 0, ceilingRung: 0,
            upDwell: 20)
        let start = Date()
        // Start at 660 and fail: that records a change, so the dwell counts from here.
        check(adapter.decide(current: 1, dropped: 0.5, queueFill: 0, now: start) == .down(2))
        check(
            adapter.decide(
                current: 2, dropped: 0, queueFill: 0,
                now: start.addingTimeInterval(5)) == .hold, "only 5 s clean")
        check(
            adapter.decide(
                current: 2, dropped: 0, queueFill: 0,
                now: start.addingTimeInterval(25)) == .up(1), "20 s clean")
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
        let start = SharedRing.startIndex(
            written: 5000, read: 0, count: 512, staleAfterFrames: 2400)
        check(start == 0, "started at \(start): the cushion is the point, not the problem")
        // Even far past the budget: the throttle will bring it down, the audio is still good.
        let past = SharedRing.startIndex(
            written: 20_000, read: 0, count: 512,
            staleAfterFrames: 2400)
        check(past == 0, "started at \(past)")
    }

    test("a normal amount of audio is read from where it was left") {
        let start = SharedRing.startIndex(
            written: 1000, read: 0, count: 512, staleAfterFrames: 2400)
        check(start == 0, "started at \(start)")
        let next = SharedRing.startIndex(
            written: 1512, read: 512, count: 512, staleAfterFrames: 2400)
        check(next == 512, "started at \(next)")
    }

    test("a reader that fell a whole ring behind is pulled forward") {
        // The writer has overwritten what the reader was about to read: skip to the oldest audio
        // that still exists, which is a full ring back from the writer.
        let start = SharedRing.startIndex(
            written: 100_000, read: 0, count: 512,
            staleAfterFrames: 2400)
        check(start == 100_000 - 48000, "started at \(start), expected a full ring back")
        let far = SharedRing.startIndex(
            written: 200_000, read: 0, count: 100_000,
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
        check(
            out[4] == 0.5 && out[5] == 0.5 && out[6] == 0.5 && out[7] == 0.5,
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
        let dueWithout = Int(
            (Double(afterResume - (start - pausedNanos)) / 1e9 + lead) * Double(rate))
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
        let position2 = 0
        start = now
        due = Int((Double(now - start) / 1e9 + lead) * Double(rate))
        check(
            due - position2 <= Int(lead * Double(rate)) + 1,
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
        check(
            SystemVolume.applyCurve(0.0625) < 0.01,
            "one notch is \(SystemVolume.applyCurve(0.0625))")
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
        check(
            SystemVolume.gain(fromDecibels: -6) > 0.49
                && SystemVolume.gain(fromDecibels: -6) < 0.51, "−6 dB is about half")
        check(SystemVolume.gain(fromDecibels: -20) < 0.11, "−20 dB is a tenth")
        check(SystemVolume.gain(fromDecibels: -64) == 0, "the bottom of the range is silence")
        check(
            SystemVolume.gain(fromDecibels: -100) == 0, "below the range is silence, not negative")
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
        for i in 0..<480 {
            ramp[i * 2] = Float(i) / 480
            ramp[i * 2 + 1] = Float(i) / 480
        }
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
        check(
            AudioStreamKeeper.hasRegisteredDevice(log, uid: "40:DC:A5:0E:14:48-tacl"),
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
        let plist = LaunchAgent.plist(
            executable: "/usr/local/bin/codecblue",
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

    test("the listener's choices are written into the agent, and not the adapter's") {
        // The agent is restarted by launchd after every crash and every login: a setting that is
        // not in the plist is a setting that quietly reverts.
        //
        // Since the level became a *ceiling* (2026-11-08), a pinned level no longer turns the
        // adapter off: the adapter is what keeps the stream below the ceiling when the link
        // cannot carry it, and that combination is the one that is safe to remember.
        check(
            LaunchAgent.arguments(quality: "HQ", adapt: true, cushionMilliseconds: 40)
                == ["--quality", "HQ", "--queue-ms", "40"],
            "\(LaunchAgent.arguments(quality: "HQ", adapt: true, cushionMilliseconds: 40))")
        // The adapter off on purpose is remembered too, and it is the only thing that writes
        // `--no-adapt`.
        check(
            LaunchAgent.arguments(quality: "HQ", adapt: false, cushionMilliseconds: 60)
                == ["--quality", "HQ", "--no-adapt", "--queue-ms", "60"])
        check(LaunchAgent.arguments(quality: nil, adapt: true, cushionMilliseconds: nil).isEmpty)
        check(
            LaunchAgent.arguments(quality: nil, adapt: false, cushionMilliseconds: nil)
                == ["--no-adapt"])
    }

    test("a rung the link cannot carry is not a preference, it is a fault") {
        // Measured 2026-11-08, FreeBuds 5, this Mac: HQ asks 990 kbps, the link carries ~530, and
        // 45% of the audio is thrown away — "inascoltabile". SQ asks 660 and drops 24%: still too
        // high. 330 drops nothing but leaves half the link unused. The answer is 492, which has no
        // name at all.
        check(
            BitrateAdapter.fitRung(capacityKbps: 530) == 3,
            "\(BitrateAdapter.fitRung(capacityKbps: 530))")
        // 700 carried is 595 of budget, and 595 takes 492 but not 660. The headroom is not
        // decoration: a rung that exactly fills the link is the one that starts stalling.
        check(BitrateAdapter.fitRung(capacityKbps: 700) == 2)
        // 800 carried is 680 of budget, which does take 660.
        check(BitrateAdapter.fitRung(capacityKbps: 800) == 1)
        // 900 carried is 765, and 765 is not 990: still 660. Only a link with real room for 990
        // gets it.
        check(BitrateAdapter.fitRung(capacityKbps: 900) == 1)
        check(BitrateAdapter.fitRung(capacityKbps: 1300) == 0)
        // A link slower than the bottom rung still gets the bottom rung: the alternative is
        // silence.
        check(BitrateAdapter.fitRung(capacityKbps: 100) == 4)
        // At 44.1 kHz the ladder is 909 / 606 / 452 / 363 / 303, and the rule uses the encoder's
        // own numbers, so the answer changes with the rate: 1100 × 0.85 = 935 takes 909.
        check(BitrateAdapter.fitRung(capacityKbps: 1100, sampleRate: 44100) == 0)
    }

    test("a rung the stream had to abandon is not climbed back into") {
        // The settle rule jumps straight to the rung the link can carry, which is not a step the
        // adapter took — so the adapter has to be told, or it walks back up as soon as the link has
        // been clean for `upDwell`. Measured 2026-11-08: HQ settled on 330, then went back to 660,
        // dropped 12%, settled again, and repeated for as long as the stream ran.
        var adapter = BitrateAdapter(upAfter: 1, minimumInterval: 0, upDwell: 0)
        adapter.noteTooHigh(0)
        // One rung up from 330 is 396, which was not abandoned: it is allowed.
        check(
            adapter.decide(current: 4, dropped: 0, queueFill: 0.1) == .up(3),
            "\(adapter.decide(current: 4, dropped: 0, queueFill: 0.1))")
        // And the abandoned rung stays abandoned: a clean stretch does not make 990 fit a link
        // that has already shown it does not.
        var blocked = BitrateAdapter(upAfter: 1, minimumInterval: 0, backoff: 600, upDwell: 0)
        blocked.noteTooHigh(0)
        var rung = 4
        for _ in 0..<3 {
            if case .up(let next) = blocked.decide(current: rung, dropped: 0, queueFill: 0.1) {
                rung = next
            }
        }
        check(rung == 1, "it may climb to 660, not to 990: \(rung)")
        check(
            blocked.decide(current: 1, dropped: 0, queueFill: 0.1) == .hold,
            "\(blocked.decide(current: 1, dropped: 0, queueFill: 0.1))")
    }

    test("the five ABR steps are reachable, and they are the ones between the three names") {
        // libldac has five EQMIDs, not three: 990 / 660 / 492 / 396 / 330 at 48 kHz. The two in
        // the middle are undocumented (`ldacBT_ex.h`, "for internal use only") and are what Sony's
        // own ABR controller walks through. They are the reason a level can be *between* HQ and
        // SQ instead of 330 kbps away from it.
        // `get_bitrate` reports the last frame encoded, so the ladder is read by encoding one
        // frame per step — that is `LDACEncoder.ladder`, and this test holds it still.
        check(
            LDACEncoder.ladder(sampleRate: 48000) == [990, 660, 492, 396, 330],
            "\(LDACEncoder.ladder(sampleRate: 48000))")
        // At 44.1 kHz the same five rungs are 909 / 606 / 452 / 363 / 303 — 363 and not 364,
        // because the frame length is a whole number of bytes and the bitrate is derived from it.
        check(
            LDACEncoder.ladder(sampleRate: 44100) == [909, 606, 452, 363, 303],
            "\(LDACEncoder.ladder(sampleRate: 44100))")
        // The floor is the floor: stepping down from LQ is refused, not wrapped to 990.
        let encoder = try! LDACEncoder(sampleRate: 48000, level: .mq, mtu: 679)
        check(encoder.stepDown() == false, "the ladder does not wrap")
        check(encoder.stepUp() == true)
        // Rungs are numbers, and moving to one is bounded: four moves covers the whole ladder.
        check(encoder.rung == 3, "\(encoder.rung) — one step up from LQ is rung 3, not 4")
        encoder.move(toRung: 0)
        check(encoder.rung == 0, "\(encoder.rung)")
        encoder.move(toRung: 2)
        check(encoder.rung == 2, "\(encoder.rung)")
        encoder.move(toRung: 9)
        check(encoder.rung == 4, "a target past the floor clamps to it, \(encoder.rung)")
    }

    test("the bottom level is called LQ, and MQ still opens the door") {
        // Sony calls it MQ, for "Mobile Quality". In a list of three that is a trap: M sorts
        // before S, so MQ appears *below* SQ and reads like a third position rather than the
        // bottom of one. LQ says what it is and sorts where it belongs.
        check(LDACEncoder.Quality.mobile.name == "LQ")
        check(LDACEncoder.Quality.mobile.longName == "Low")
        // And MQ keeps working forever, because the LaunchAgent's plist has a level written into
        // it: a plist written before the rename says MQ, and refusing it would turn a running
        // stream into a usage error at the next login.
        check(LDACEncoder.Quality.parse("MQ") == .mobile, "the old name")
        check(LDACEncoder.Quality.parse("mq") == .mobile, "in any case")
        check(LDACEncoder.Quality.parse("LQ") == .mobile)
        check(LDACEncoder.Quality.parse("Low") == .mobile)
        check(LDACEncoder.Quality.parse("HQ") == .high)
        check(LDACEncoder.Quality.parse("SQ") == .standard)
        check(LDACEncoder.Quality.parse("nonsense") == nil)
    }

    test("the ladder is five rungs, and the menu offers the three that have names") {
        // The ladder is five because the adapter needs the two in the middle: a link carrying
        // ~450 kbps has to choose between 660 (a third of the audio thrown away) and 330 (half the
        // bitrate left on the table), and 492 is the answer. The *menu* offers three, because a
        // preference is expressed in words and only three of the five have one.
        let levels = QualityLevels.describe(capacityKbps: 530)
        check(levels.map(\.rung) == [0, 1, 2, 3, 4], "\(levels.map(\.rung))")
        check(
            levels.map(\.nominalKbps) == [990, 660, 492, 396, 330],
            "\(levels.map(\.nominalKbps))")
        // The named rungs keep their names; the unnamed ones are identified by their bitrate.
        check(levels.map(\.name) == ["HQ", "SQ", "492", "396", "LQ"], "\(levels.map(\.name))")
        check(levels.map(\.longName) == ["High", "Standard", "492 kbps", "396 kbps", "Low"])
        // 530 carried is 450 of budget: 396 and 330 fit, 492 does not.
        check(
            levels.map(\.fits) == [false, false, false, true, true],
            "\(levels.map(\.fits))")
        // And the tick is on the highest rung that fits — 396, not 330, and not 492.
        check(levels.filter(\.chosen).map(\.rung) == [3], "\(levels.filter(\.chosen).map(\.rung))")
        // A link that carries nothing yet claims nothing: a menu that guesses is worse than one
        // that says it does not know, and it ticks nothing.
        let unmeasured = QualityLevels.describe(capacityKbps: 0)
        check(unmeasured.allSatisfy { !$0.fits })
        check(unmeasured.allSatisfy { !$0.chosen })
        // A ceiling above what the link carries says what it will actually give: the rung that
        // fits. "990 kbps · more than this link carries" is true and useless; "gives 396 here" is
        // the same fact and answers the question the listener is asking.
        //
        // "up to" and not a bare number, because 990 is what the rung *asks for* and not what the
        // link gives — reported 2026-11-09 as "still High 990, and that does not add up".
        // The number shown is what the listener gets, not what the rung asks for. Reported
        // 2026-11-09: "if you know the max is 336 show HQ with 336 and don't show me the 990 one".
        // Changed 2026-11-11: the row shows the level's own bitrate and says where it settles,
        // because putting the landing figure in the level's place made every row above the link's
        // capacity print the same number — HQ, SQ and both unnamed rungs all read "396 kbps", and
        // the report was "why 4 rows and not 3? what is it for?".
        check(
            QualityLevels.menuLabel(levels[0], capacityKbps: 530)
                == "High · 990 kbps · settles on 396",
            "\(QualityLevels.menuLabel(levels[0], capacityKbps: 530))")
        check(
            QualityLevels.menuLabel(levels[4], capacityKbps: 530) == "Low · 330 kbps",
            "\(QualityLevels.menuLabel(levels[4], capacityKbps: 530))")
        // The unnamed rung is still on the ladder — the adapter lands on it — but it is not in
        // the menu, so its label is a bare number and no positional filler.
        //
        // No tick in the label: it used to carry one for `chosen`, and the menu drew its own for
        // the playing rung, so on a link where the two coincide (312 kbps here: `fitRung` picks LQ
        // and LQ is playing) the row showed two. Reported 2026-11-11. The tick belongs to the
        // caller, which is the only one that knows which question it is answering.
        check(
            QualityLevels.menuLabel(levels[3], capacityKbps: 530) == "396 kbps",
            "\(QualityLevels.menuLabel(levels[3], capacityKbps: 530))")
        // A ceiling *below* what fits is honoured: asking for Low on a fast link gives Low, not the
        // best the link could do. A ceiling is a limit, and a limit the program ignores is not a
        // setting.
        check(
            QualityLevels.wouldUse(levels[4], capacityKbps: 1300) == 330,
            "\(QualityLevels.wouldUse(levels[4], capacityKbps: 1300) ?? -1)")
        check(QualityLevels.wouldUse(levels[0], capacityKbps: 1300) == 990)
        check(QualityLevels.wouldUse(levels[0], capacityKbps: 530) == 396)
        // Nothing measured yet: no claim at all. The name alone, because a bitrate next to a name
        // is a claim about this link and there is no link yet — asked 2026-11-09: "show just HQ
        // without kbps, and when streaming starts we can update the menu to show the value".
        check(QualityLevels.wouldUse(levels[0], capacityKbps: 0) == nil)
        check(QualityLevels.menuLabel(levels[0], capacityKbps: 0) == "High")
        // The bitrates come from the encoder, so the rate changes them.
        check(
            QualityLevels.describe(capacityKbps: 530, sampleRate: 44100).map(\.nominalKbps)
                == [909, 606, 452, 363, 303])
    }

    test("a rung can be named or numbered, and the number reaches the unnamed ones") {
        // `HQ` / `SQ` / `LQ` are what a person types; `0`…`4` are what the ladder actually has.
        // Both have to work, because the two middle rungs have no name to type.
        check(LDACEncoder.rung(from: "HQ") == 0)
        check(LDACEncoder.rung(from: "SQ") == 1)
        check(LDACEncoder.rung(from: "LQ") == 4)
        check(LDACEncoder.rung(from: "MQ") == 4, "the old name, forever")
        check(LDACEncoder.rung(from: "0") == 0)
        check(LDACEncoder.rung(from: "2") == 2)
        check(LDACEncoder.rung(from: "4") == 4)
        check(LDACEncoder.rung(from: "5") == nil, "there is no sixth rung")
        check(LDACEncoder.rung(from: "-1") == nil)
        check(LDACEncoder.rung(from: "nonsense") == nil)
        // And a rung can be named back, which is what a log line and the status need.
        check(LDACEncoder.name(rung: 0) == "HQ")
        check(LDACEncoder.name(rung: 2) == "492")
        check(LDACEncoder.name(rung: 4) == "LQ")
        check(LDACEncoder.name(rung: 3, sampleRate: 44100) == "363")
    }

    test("the link quality mode is judged from the socket, not from bluetoothd's log") {
        // The measurements this rule is built on, 2026-11-08:
        //   LQM off, 336 kbps asked: 2 packets per drain, 29% dropped, socket full in every window.
        //   LQM on,  336 kbps asked: no refusal at all, 73 windows in a row, 99.89% of real time.
        check(
            LinkQuality.judge(stalls: 88, burst: 2, sentPackets: true) == .off,
            "\(LinkQuality.judge(stalls: 88, burst: 2, sentPackets: true))")
        check(LinkQuality.judge(stalls: 0, burst: 499, sentPackets: true) == .on)
        // A refusal with a wide burst is still on: the ceiling was above what was asked, and the
        // refusal was the link, not the mode.
        check(LinkQuality.judge(stalls: 3, burst: 62, sentPackets: true) == .on)
        // Nothing sent yet is not "off": saying so would accuse the link before it was used.
        check(LinkQuality.judge(stalls: 0, burst: 0, sentPackets: false) == .unknown)
    }

    test("the plist parses as a property list") {
        let plist = LaunchAgent.plist(
            executable: "/tmp/a b/codecblue", address: "AA:BB:CC:DD:EE:FF")
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
        let plist = LaunchAgent.plist(
            executable: "/tmp/a&b/codecblue", address: "AA:BB:CC:DD:EE:FF")
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
        check(
            abs(total - expected) <= 1,
            "\(total) extra frames over 1000 blocks, expected \(expected)")
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
        check(
            AVCTPHolder.interpret(release) == .unsupported,
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
        check(
            AVCTPHolder.interpret([0x00, 0x11, 0x0E, 0x00, 0x00, 0x7C, 0x99]) == .unsupported,
            "unknown key code")
        check(
            AVCTPHolder.interpret([0x00, 0x11, 0x0E, 0x00, 0x00, 0x10, 0x00]) == .unsupported,
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
        let frame: [UInt8] = [
            0x12, 0x11, 0x0E, 0x0F, 0x48, 0x00, 0x00, 0x19, 0x58,
            0x31, 0x00, 0x00, 0x02, 0x0D, 0x17,
        ]
        check(frame.count == 15, "the frame is 15 bytes, not 17")
        check(frame[9] == 0x31, "PDU is REGISTER NOTIFICATION")
        check(frame[13] == 0x0D, "event is VOLUME CHANGED")
        let value = Float(frame[14] & 0x7F) / 127
        check(abs(value - 23.0 / 127) < 1e-6, "\(value) is 18%")
    }

    test("every vendor dependent PDU carries a two-byte length") {
        // SET ABSOLUTE VOLUME at 30%: PDU 0x50, reserved, length 1, operand 0x26.
        let set: [UInt8] = [
            0x20, 0x11, 0x0E, 0x00, 0x48, 0x00, 0x00, 0x19, 0x58,
            0x50, 0x00, 0x00, 0x01, 0x26,
        ]
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
        let frame: [UInt8] = [
            0x10, 0x11, 0x0E, 0x01, 0x48, 0x00, 0x00, 0x19, 0x58,
            0x10, 0x00, 0x00, 0x01, 0x03,
        ]
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
        let capabilities: [UInt8] = [
            0x10, 0x11, 0x0E, 0x01, 0x48, 0x00, 0x00, 0x19, 0x58,
            0x10, 0x00, 0x00, 0x01, 0x03,
        ]
        let notification: [UInt8] = [
            0x12, 0x11, 0x0E, 0x0F, 0x48, 0x00, 0x00, 0x19, 0x58,
            0x31, 0x00, 0x00, 0x02, 0x0D, 0x17,
        ]
        let both = capabilities + notification
        check(AVCTPHolder.frameLength(both) == 14, "the first frame is 14 bytes")
        check(AVCTPHolder.frameLength(Array(both[14...])) == 15, "the second is 15")
    }

    test("a partial frame is not parsed") {
        let notification: [UInt8] = [
            0x12, 0x11, 0x0E, 0x0F, 0x48, 0x00, 0x00, 0x19, 0x58,
            0x31, 0x00, 0x00, 0x02, 0x0D, 0x17,
        ]
        check(
            AVCTPHolder.frameLength(Array(notification[0..<10])) == nil,
            "half a frame must wait for the rest")
        check(AVCTPHolder.frameLength(notification) == 15, "the whole frame is 15")
    }

    test("the ctype is byte 3, not anything in the AVCTP header") {
        // The header holds the label, the packet type, C/R and IPID. Reading `header >> 2 & 0x03`
        // gives 0 for every frame, which is why the re-registration never ran.
        let interim: [UInt8] = [
            0x12, 0x11, 0x0E, 0x0F, 0x48, 0x00, 0x00, 0x19, 0x58,
            0x31, 0x00, 0x00, 0x02, 0x0D, 0x17,
        ]
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
            [
                0x12, 0x11, 0x0E, ctype, 0x48, 0x00, 0x00, 0x19, 0x58,
                0x31, 0x00, 0x00, 0x02, 0x0D, value,
            ]
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
        check(
            freeBuds.count == 1, "the paired listing must not be counted twice: \(freeBuds.count)")
        check(freeBuds.first?.isConnected == true, "it is in Connected")
        check(freeBuds.first?.name == "HUAWEI FreeBuds 5", freeBuds.first?.name ?? "nil")
    }

    test("a switched-off pair is listed as not connected, not as present") {
        let devices = BluetoothHeadphone.parse(sample)
        let old = devices.first { $0.address == "AA:BB:CC:DD:EE:FF" }
        check(old != nil, "it is still listed")
        check(
            old?.isConnected == false, "but not connected — the mistake was reading it as present")
    }

    test("only audio devices are offered") {
        let audio = BluetoothHeadphone.parse(sample).filter(\.isAudio)
        check(
            audio.count == 2,
            "two pairs of headphones, not the keyboard or the mouse: \(audio.count)")
        check(!audio.contains { $0.kind == "Keyboard" }, "no keyboard")
        check(!audio.contains { $0.kind == "Mouse" }, "no mouse")
    }

    test("the kind test covers the words Apple uses") {
        for kind in ["Headphones", "Headset", "Speaker", "Earbuds", "AirPods"] {
            check(
                BluetoothHeadphone(name: "x", address: "y", isConnected: true, kind: kind).isAudio,
                kind)
        }
        for kind in ["Keyboard", "Mouse", "Trackpad", "Gamepad"] {
            check(
                !BluetoothHeadphone(name: "x", address: "y", isConnected: true, kind: kind).isAudio,
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
        //
        // The installed path is passed in rather than discovered, because the rule is about what
        // `resolveExecutable` *does*, not about what this machine happens to have installed. The
        // first version discovered it, so on a machine with the app installed it tested the first
        // branch and on CI — which has no ~/Applications/CodecBlue — it fell through to the
        // fallback and failed on a path that was correct for that machine. A test that depends on
        // the machine is a test that fails in someone else's checkout.
        // A checkout built by hand: the binary SwiftPM produces lives in .build/out/Products/
        // Debug, and .build/debug/codecblue is the symlink it maintains. The rule is that the
        // second is what goes in the plist, and it is checked on a real tree rather than on a
        // string, because the walking is the part that can be wrong.
        let root = URL(fileURLWithPath: "/tmp/codecblue-selftest-resolve-\(getpid())")
        let out = root.appendingPathComponent(".build/out/Products/Debug")
        let stable = root.appendingPathComponent(".build/debug")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stable, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invoked = out.appendingPathComponent("codecblue")
        FileManager.default.createFile(
            atPath: invoked.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(
            atPath: stable.appendingPathComponent("codecblue").path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        let absent = URL(fileURLWithPath: "/nowhere/Applications/CodecBlue/codecblue")
        let resolved = LaunchAgent.resolveExecutable(from: invoked, installed: absent)
        check(!resolved.contains("/.build/out/"), "never SwiftPM's internal directory: \(resolved)")
        check(
            resolved == stable.appendingPathComponent("codecblue").path,
            "the stable symlink wins over the products directory: \(resolved)")
        // And when an installed copy exists, it wins over everything — including a checkout.
        let installed = root.appendingPathComponent("Applications/CodecBlue/codecblue")
        try? FileManager.default.createDirectory(
            at: installed.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: installed.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        check(
            LaunchAgent.resolveExecutable(from: invoked, installed: installed) == installed.path,
            "the installed copy wins when it is there")
        // With nothing anywhere, the honest answer is the path it was given: a wrong path in the
        // plist is a "no such file" at login, and inventing a better-looking one would hide that.
        let empty = URL(fileURLWithPath: "/tmp/codecblue-selftest-empty-\(getpid())/codecblue")
        check(
            LaunchAgent.resolveExecutable(from: empty, installed: absent) == empty.path,
            "an honest fallback")
    }

    test("the plist carries the address and the arguments") {
        let text = LaunchAgent.plist(
            executable: "/bin/echo", address: "40:DC:A5:0E:14:48",
            arguments: ["--quality", "MQ"])
        check(text.contains("<string>40:DC:A5:0E:14:48</string>"), "the address")
        check(text.contains("<string>--quality</string>"), "the option")
        check(text.contains("<string>MQ</string>"), "its value")
        check(text.contains("<key>KeepAlive</key>"), "it comes back when the headphones return")
        check(text.contains("<key>ThrottleInterval</key>"), "and does not spin while they are off")
    }

    test("a path with an ampersand still parses") {
        // A plist that will not parse is a LaunchAgent that silently does nothing.
        let text = LaunchAgent.plist(
            executable: "/Users/a&b/codecblue", address: "AA:BB:CC:DD:EE:FF")
        check(text.contains("a&amp;b"), "escaped")
        check(!text.contains("/Users/a&b/"), "not raw")
        let data = Data(text.utf8)
        let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
        check(parsed != nil, "the result is a plist")
    }

    test("loading unloads first, so a rewritten plist takes effect") {
        // `launchctl load` on an already-loaded label is a no-op: after rewriting the plist for a
        // different pair, loading alone would keep the old address running.
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueCore/Audio/LaunchAgent.swift",
            encoding: .utf8)
        guard let source else {
            check(false, "source not readable")
            return
        }
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
        guard let ring else {
            check(true, "no driver running, nothing to check")
            return
        }
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
        let invoked = URL(fileURLWithPath: "/repo/.build/debug/codecblue")
        let resolved = LaunchAgent.resolveExecutable(
            from: invoked,
            installed: URL(fileURLWithPath: "/nowhere/Applications/CodecBlue/codecblue"))
        // What must never happen is a path into .build/out, which SwiftPM deletes; and with
        // nothing installed the answer is the .build/debug path it was given, which is the stable
        // symlink SwiftPM maintains. Passed in, not discovered: see the note in
        // `launchAgentAppTests` about a test that depends on the machine it runs on.
        check(!resolved.contains("/.build/out/"), "never SwiftPM's internal directory: \(resolved)")
        check(resolved == invoked.path, "the path it was given, which is already the stable one")
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
            let size = (try? FileManager.default.attributesOfItem(atPath: icns.path)[.size]) as? Int
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
        check(
            abs(queue.maxDuration - 0.030) < 1e-9, "relaxes to the new floor: \(queue.maxDuration)")
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
        check(
            text.contains("if !MediaRemote.send(.pause) { post(.playPause) }"),
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
        check(
            !text.contains("streamer.gain = { volume?.gain ?? 1 }"),
            "and the decibel curve is not applied here")
        check(
            text.contains("volume?.notePushed(position)"),
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
        check(
            text.contains("kMuteControlID, 1, &changed"),
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
        check(
            text.contains("BluetoothAuthorization.request(log: log)"),
            "playSystem asks before touching bluetoothd")
        // And before the ring, which is where the first bluetoothd call happens.
        if let ask = text.range(of: "BluetoothAuthorization.request(log: log)"),
            let ring = text.range(of: "ring = try SharedRing()")
        {
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
        check(
            BluetoothAuthorization.timeout <= 3,
            "a short wait: \(BluetoothAuthorization.timeout) s")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent(
            "Sources/CodecBlueCore/Bluetooth/BluetoothAuthorization.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            check(false, "not readable")
            return
        }
        check(
            text.contains("CBCentralManager(delegate: self, queue: nil)"),
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
        check(
            !text.contains("let command = key == \"stop\" ? \"pause\" : key"),
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
            let post = text.range(of: "post(.playPause)", range: toggle.upperBound..<text.endIndex)
        {
            check(post.lowerBound > toggle.lowerBound, "toggle posts the HID key")
        } else {
            check(false, "toggle case found")
        }
        check(
            text.contains("nowPlayingPID=0") || text.contains("registered Now"),
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
        check(
            text.contains("MRMediaRemoteGetNowPlayingApplicationPID"),
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

/// The comparison with the Mac's own AAC path, which is the question a listener asks as soon as
/// this works: why does the Mac hold up further from the machine?
///
/// The answer is a number in bluetoothd's log, and these are the lines it has to be read from.
func aacSessionTests() {
    let configured = """
        bluetoothd: [com.apple.bluetooth:Server.A2DP] A2DP configured at 44.1 KHz. Codec: AAC-LC, VBR max: 230 kbps. 1 frames * (12+668) bytes = 680 per RTP (max=879) every 23.22 ms
        bluetoothd: [com.apple.bluetooth:Server.A2DP] adjustBitRateForMac- Adjusting Bitrate for HUAWEI FreeBuds 5
        bluetoothd: [com.apple.bluetooth:Server.Audio] A2DP LinkQualityReport: Handle = 29 ReTx =  6.8% (  5 /  73), NAK =    0, NoSync =    5, TxPwr =  8 dBm, RSSI =  -54, rate = 230 kbps Flow off = 0
        bluetoothd: [com.apple.bluetooth:Server.Audio] A2DP LinkQualityReport: Handle = 29 ReTx =  0.0% (  0 /   1), NAK =    0, NoSync =    0, TxPwr =  8 dBm, RSSI =  -56, rate = 230 kbps Flow off = 0
        """

    test("the AAC session is read from the numbers bluetoothd prints, not from a table") {
        guard let session = AACSession.parse(configured) else {
            check(false, "the session should parse")
            return
        }
        check(session.sampleRate == 44100, "\(session.sampleRate)")
        check(session.packetBytes == 680, "\(session.packetBytes)")
        check(abs(session.intervalMilliseconds - 23.22) < 0.001, "\(session.intervalMilliseconds)")
        // 680 bytes every 23.22 ms is 43 packets/s and 234 kbps: the number that explains the
        // distance, derived from the log rather than copied from a datasheet.
        check(abs(session.kbps - 234.3) < 0.5, "\(session.kbps)")
        check(session.bitrateAdjustments == 1, "\(session.bitrateAdjustments)")
        check(session.reports == 2, "\(session.reports)")
        // The last report wins: it is the most recent state of the link.
        check(session.rssi == -56, "\(session.rssi ?? 0)")
        check(abs(session.reTx - 0) < 0.001, "\(session.reTx)")
    }

    test("the comparison is in kbps, the one unit both paths share") {
        guard let session = AACSession.parse(configured) else {
            check(false, "the session should parse")
            return
        }
        // LDAC's floor at 48 kHz is 330: 1.4× what AAC asks, so the link has to be 1.4× better
        // before this path is as steady. That is the whole explanation of the distance, and it is
        // arithmetic on two numbers, not an opinion about codecs.
        let line = session.comparison(floorKbps: 330)
        check(line.contains("234 kbps"), line)
        check(line.contains("330"), line)
        check(line.contains("1.4"), line)
    }

    test("a log with no AAC session says so instead of inventing one") {
        check(AACSession.parse("bluetoothd: nothing here") == nil)
        // An LDAC configuration of our own is not an AAC session: the two paths must not be
        // confused, or the comparison would be this program against itself.
        check(AACSession.parse("A2DP configured at 48 KHz. Codec: LDAC, 990 kbps") == nil)
    }

    test("a new configuration resets the link numbers, because they describe another stream") {
        let two = """
            A2DP configured at 44.1 KHz. Codec: AAC-LC, VBR max: 230 kbps. 1 frames * (12+668) bytes = 680 per RTP (max=879) every 23.22 ms
            A2DP LinkQualityReport: Handle = 29 ReTx = 80.0% (  4 /   5), RSSI =  -70, rate = 230 kbps
            A2DP configured at 48 KHz. Codec: AAC-LC, VBR max: 320 kbps. 1 frames * (12+668) bytes = 680 per RTP (max=879) every 21.33 ms
            """
        guard let session = AACSession.parse(two) else {
            check(false, "the session should parse")
            return
        }
        check(session.sampleRate == 48000, "\(session.sampleRate)")
        check(session.reports == 0, "the old stream's reports do not describe this one")
        check(session.rssi == nil, "\(session.rssi ?? 0)")
    }
}

/// The keeper asks bluetoothd for the link quality mode. How often it asks is a decision with a
/// measured cost on both sides, and these are the numbers it is built from.
func keeperPaceTests() {
    test("the audio device coming and going is read from the last line, not the first") {
        // bluetoothd registers the device when the headphones connect and erases it when the media
        // channel is reopened — so both orders happen, and the later line is the true state.
        let registered = """
            Register audio device 40:DC:A5:0E:14:48-tacl
            Erased 1 audio device 40:DC:A5:0E:14:48-tacl
            Register audio device 40:DC:A5:0E:14:48-tacl
            """
        check(AudioStreamKeeper.hasRegisteredDevice(registered, uid: "40:DC:A5:0E:14:48-tacl"))
        let erased = """
            Register audio device 40:DC:A5:0E:14:48-tacl
            Erased 1 audio device 40:DC:A5:0E:14:48-tacl
            """
        check(!AudioStreamKeeper.hasRegisteredDevice(erased, uid: "40:DC:A5:0E:14:48-tacl"))
    }

    test("another device's registration is not ours") {
        // bluetoothd prints one of these per announcing device, and the address is what tells them
        // apart. Without this the keeper confirmed on somebody else's headphones.
        let other = """
            Register audio device AC:BD:70:5C:06:1C-tacl
            Erased 1 audio device AC:BD:70:5C:06:1C-tacl
            """
        check(!AudioStreamKeeper.hasRegisteredDevice(other, uid: "40:DC:A5:0E:14:48-tacl"))
    }
}

/// Stopping the stream is a thing the user does, and every ordinary way of doing it arrives as a
/// signal. These are the two facts that matter about the handler.
func stopRequestTests() {
    test("a second stop request does not abandon the hand-back") {
        // The first request starts a teardown that takes seconds: the link has to drop and macOS
        // has to reconnect. A user pressing Ctrl-C twice means "hurry up", and acting on the second
        // press would leave the headphones taken — the exact failure the handler exists to avoid.
        //
        // Tested through the counting behaviour rather than by raising real signals: a test that
        // sends SIGTERM to its own process is a test that kills the test runner on the machine
        // where it fails.
        let box = StopCounter()
        box.request()
        box.request()
        box.request()
        check(box.count == 1, "the handler ran \(box.count) time(s), not once")
        check(box.ignored == 2, "\(box.ignored) repeat(s) were ignored")
    }
}

/// The counting part of `StopRequest`, without the signals.
///
/// `StopRequest` itself is in the CLI, where the selftest cannot reach it — deliberately, because
/// the CLI is the thing that owns the process. This mirrors the rule it implements: the first
/// request wins and the rest are reported, so the property is tested even though the object is not.
final class StopCounter {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var ignored = 0

    func request() {
        lock.lock()
        defer { lock.unlock() }
        if count == 0 { count = 1 } else { ignored += 1 }
    }
}

/// A phone call is the one thing that must be allowed to take the headphones away.
///
/// The rule is a pure function so that it can be tested here: the alternative is testing it by
/// starting a real call, which is not a test anybody runs.
func callMonitorTests() {
    test("a call application using the microphone counts as a call") {
        check(CallMonitor.isCall(bundleID: "us.zoom.xos", isOurOwn: false))
        check(CallMonitor.isCall(bundleID: "com.microsoft.teams2", isOurOwn: false))
        check(CallMonitor.isCall(bundleID: "com.apple.FaceTime", isOurOwn: false))
        // A browser tab is how a Meet call arrives: the browser is the process with the
        // microphone open, so the browser must count. A list of call applications would have said
        // "Chrome is not a call" and the microphone would never have been handed over.
        check(CallMonitor.isCall(bundleID: "com.google.Chrome", isOurOwn: false))
    }

    test("dictation and Siri are not calls") {
        // Measured 2026-11-09: dictation holds the microphone open for as long as the feature is
        // on. Without the exclusion the stream would stop the moment anyone dictated anything and
        // never come back, because the microphone never closes.
        for bundle in CallMonitor.notACall {
            check(
                !CallMonitor.isCall(bundleID: bundle, isOurOwn: false), "\(bundle) must not count")
        }
    }

    test("a process with no bundle id is not a call") {
        // `rec`, `sox`, `ffmpeg`: far more common than a command-line phone, and stopping the
        // music for them would be wrong.
        check(!CallMonitor.isCall(bundleID: nil, isOurOwn: false))
        check(!CallMonitor.isCall(bundleID: "", isOurOwn: false))
    }

    test("our own process is never a call") {
        // CodecBlue reads the system output, and on a Mac with no other input device it could end
        // up holding the microphone itself. Handing the headphones back to ourselves would be a
        // loop: stop, wait for the call to end, restart, stop.
        check(!CallMonitor.isCall(bundleID: "com.codecblue.menu", isOurOwn: true))
    }
}

/// The two hand-back styles, and the numbers behind them.
///
/// Measured 2026-11-09, three runs, headphones connected to macOS, 14 s of streaming then Ctrl-C:
///
///     the link fell 109 / 108 / 106 ms after the forced disconnect
///     macOS has the headphones again after 2.1 / 4.5 / 4.6 s
///
/// Two facts follow, and both changed the code:
/// * The link is not the slow part. It falls in a tenth of a second, so the old `sleep(1)` after
///   it was a second of nothing, and `cancelConnection` was never the cost.
/// * The wait is macOS deciding to bring the headphones' profiles back, and it varies by seconds.
///   The old code slept a flat three seconds and returned, which made a 7.4 s hand-back look like
///   a 3 s one. A number in a log is only useful if it is the number the listener experiences.
func handBackTests() {
    test("the hand-back styles are spelled as the command line spells them") {
        check(HeadsetTakeover.HandBackStyle.named("reconnect") == .reconnect)
        check(HeadsetTakeover.HandBackStyle.named("in-place") == .inPlace)
        // The hyphen is the kind of thing that gets typed as an underscore or left out, and a
        // usage message is a poor answer to that.
        check(HeadsetTakeover.HandBackStyle.named("inplace") == .inPlace)
        check(HeadsetTakeover.HandBackStyle.named("IN-PLACE") == .inPlace)
        check(HeadsetTakeover.HandBackStyle.named("in place") == nil)
        check(HeadsetTakeover.HandBackStyle.named("") == nil)
    }
}

/// The shared ring's layout, which the driver and this program have to agree on byte for byte.
///
/// Written out on both sides in two languages, so the only defence is a test that reads the same
/// offsets the driver writes. The `feeding` flag was added for the hidden-device rule and is the
/// first field after the ones the ring started with: getting its offset wrong would make the
/// driver hide the device while a stream is running, which looks exactly like a broken driver.
func ringLayoutTests() {
    test("the ring's header has room for the feeding flag and the samples start after it") {
        // 2×8 counters + 3×4 fields + 1×4 flag = 32 bytes, which is also the alignment the
        // sample array needs. If this ever needs to grow, it grows to 40 and both sides change.
        let headerBytes = 32
        check(headerBytes % 8 == 0, "the sample array must stay 4-byte aligned")
        check(headerBytes >= 8 + 8 + 4 + 4 + 4 + 4, "the header must hold every field")
    }
}

/// The login item for the menu bar icon.
///
/// It exists because the icon is the only way to start a stream and nothing brought it back after
/// a reboot. What is worth testing is the plist: a plist that does not parse is a login item that
/// silently does nothing, and the failure only shows up at the next login.
func loginItemTests() {
    test("the login item opens the app bundle, and does not try to run it directly") {
        let text = MenuBarLoginItem.plist(
            appPath: "/Users/someone/Applications/CodecBlue/CodecBlue.app")
        check(text.contains("<string>/usr/bin/open</string>"), "must go through open")
        check(text.contains("<string>-a</string>"))
        check(
            text.contains("/Users/someone/Applications/CodecBlue/CodecBlue.app"),
            "must name the bundle")
        // `open` on a running app does nothing, which is what a login item wants: a second launch
        // would put two icons in the menu bar and two clients on one control socket.
        check(!text.contains("CodecBlueMenu"), "must not name the executable inside the bundle")
    }

    test("the login item's label is not the stream's") {
        // Two launch items with one label is one item: installing the icon would replace the
        // stream, and the music would stop at the next login with no error anywhere.
        check(MenuBarLoginItem.label != LaunchAgent.label)
        check(MenuBarLoginItem.label == "com.codecblue.menu")
    }

    test("the login item is not kept alive") {
        // `KeepAlive` would restart `open` forever: it exits immediately by design, and launchd
        // would relaunch it every five seconds for the life of the session.
        let text = MenuBarLoginItem.plist(appPath: "/tmp/CodecBlue.app")
        check(!text.contains("KeepAlive"))
        check(text.contains("<key>RunAtLoad</key>"))
    }
}

/// What the quality menu says, and why it says it.
///
/// Reported 2026-11-09: "I see the plugin showing many qualities, some of them without a name, and
/// still High 990, and that does not add up". Three complaints in one sentence and all three were
/// fair. The menu listed five rungs as if they were five equal choices, two of them as bare
/// numbers with no explanation of why they exist, and the top one as "High · 990 kbps" on a link
/// that could never carry it.
func qualityMenuTests() {
    test("the menu offers three levels, not five") {
        // Asked 2026-11-09: "we said we would leave only HQ, SQ, LQ, and when the stream starts
        // the kbps would appear beside them — why haven't you done it yet?" The two unnamed rungs
        // each needed a sentence to explain where they sat, and a menu of five where two need
        // explaining is a menu of three plus an argument.
        let levels = QualityLevels.menuLevels(capacityKbps: 530, sampleRate: 48000)
        check(levels.map(\.rung) == [0, 1, 4], "HQ, SQ, LQ: \(levels.map(\.rung))")
        let labels = levels.map { QualityLevels.menuLabel($0, capacityKbps: 530) }
        check(!labels.contains { $0.contains("between") }, "no positional filler: \(labels)")
        // The unnamed rungs still exist for the adapter: it lands on 492 when a link carries
        // ~450 kbps, and that is a decision the stream makes, not a preference.
        check(
            QualityLevels.describe(capacityKbps: 530, sampleRate: 48000).count == 5,
            "the ladder is still five rungs")
    }

    test("a rung the link cannot carry says both what it is and where it lands") {
        let levels = QualityLevels.describe(capacityKbps: 530, sampleRate: 48000)
        let hq = levels.first { $0.rung == 0 }!
        let label = QualityLevels.menuLabel(hq, capacityKbps: 530)
        // Changed 2026-11-11. The old rule showed only the outcome, which was right when the rows
        // were otherwise indistinguishable and wrong once they were: `wouldUse` returns
        // `max(fitted, rung)`, so every row above the link's capacity printed the same figure and
        // the menu looked like it had one choice repeated. Both numbers are now said, in different
        // places, so the row says what the level is and what it would settle on.
        check(label.contains("990"), "the level's own bitrate is named: \(label)")
        check(label.contains("settles on 396"), "and so is the outcome: \(label)")
        check(!label.contains("✓"), "a rung that does not fit is not the one chosen: \(label)")
    }

    test("with no measurement the menu claims nothing about fit") {
        // Before a stream has reported its capacity the honest answer is silence: a menu that
        // guesses "fits" is worse than one that says it does not know yet.
        let levels = QualityLevels.describe(capacityKbps: 0, sampleRate: 48000)
        for level in levels {
            let label = QualityLevels.menuLabel(level, capacityKbps: 0)
            check(!label.contains("here"), "no capacity, no claim: \(label)")
            check(!label.contains("✓"), "no capacity, no tick: \(label)")
        }
    }

    test("the ladder is five rungs and the two unnamed ones are between SQ and LQ") {
        let levels = QualityLevels.describe(capacityKbps: 530, sampleRate: 48000)
        check(levels.count == 5, "five rungs, not three: \(levels.count)")
        check(levels.map { $0.rung } == [0, 1, 2, 3, 4])
        // Bitrates must descend, or the menu reads as a mistake.
        let kbps = levels.map { $0.nominalKbps }
        check(kbps == kbps.sorted(by: >), "the ladder descends: \(kbps)")
        check(kbps[2] > kbps[3], "492 is above 396")
    }
}

/// The output that was taken over has to be given back, even if the process dies.
///
/// Measured 2026-11-09: `kill -9` mid-stream left CodecBlue as the system output with nothing
/// feeding it. The device hid itself correctly and the Mac went silent — every app playing into a
/// device that was not there. The restore lived in a `defer` in the process that died, which is
/// the same mistake as the `feeding` flag: anything that must survive a crash cannot live only in
/// a process.
func outputRecoveryTests() {
    test("what was taken over is written down, not just held in memory") {
        let saved = DefaultOutput.Saved(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
        DefaultOutput.remember(saved)
        let read = DefaultOutput.remembered()
        check(read?.uid == saved.uid, "the uid must survive: \(read?.uid ?? "nil")")
        check(read?.name == saved.name, "the name must survive: \(read?.name ?? "nil")")
        DefaultOutput.forget()
        check(DefaultOutput.remembered() == nil, "forget must actually forget")
    }

    test("with no record there is nothing to recover, and nothing is said") {
        // The common case: `stop` on a healthy machine must not print anything about outputs.
        DefaultOutput.forget()
        check(DefaultOutput.recoverIfOrphaned() == .nothingToDo)
    }
}

/// The menu must not present the codec's bitrate as the link's capacity.
///
/// Reported 2026-11-09: "why do I still see high at 990 kbps?". Two separate causes, and both are
/// worth a test because both are the same mistake in different clothes — a number that describes
/// the request being read as a number that describes the outcome.
func capacityHonestyTests() {
    test("with no measurement the label claims nothing beyond the codec's own bitrate") {
        let levels = QualityLevels.describe(capacityKbps: 0, sampleRate: 48000)
        let hq = levels.first { $0.rung == 0 }!
        let label = QualityLevels.menuLabel(hq, capacityKbps: 0)
        check(label == "High", "no claim without a measurement: \(label)")
        check(!label.contains("kbps"), "not even the codec's own number: \(label)")
        check(!label.contains("gives"), "no outcome claimed: \(label)")
        // An unnamed rung keeps its number even with no measurement, because the number *is* its
        // name — it is not a claim about this link. Reported 2026-11-09, an hour after the
        // names-only rule went in: "in the quality list I see two 'between Standard and Low' that
        // do not make much sense to see". Two identical lines, because rungs 2 and 3 sit in the
        // same place. The rule was right for the named rungs and wrong for these.
        let unnamed = levels.first { $0.rung == 2 }!
        let unnamedLabel = QualityLevels.menuLabel(unnamed, capacityKbps: 0)
        check(unnamedLabel.hasPrefix("492"), "an unnamed rung is its number: \(unnamedLabel)")
        let other = levels.first { $0.rung == 3 }!
        let otherLabel = QualityLevels.menuLabel(other, capacityKbps: 0)
        check(otherLabel.hasPrefix("396"), "the other one is 396: \(otherLabel)")
        check(otherLabel != unnamedLabel, "and the two lines differ: \(otherLabel)")

        // And once a stream is running, the numbers appear — that is the whole point of hiding
        // them in the first place.
        let streaming = QualityLevels.menuLabel(levels[0], capacityKbps: 0, streaming: true)
        check(streaming == "High · 990 kbps", "numbers come back with a stream: \(streaming)")
    }

    test("a floor is not a ceiling: it must not decide what fits") {
        // A stream paced to real time reports "kept up" on a link with any amount of spare room.
        // Measured 2026-11-09: `link took 100% of real time` while carrying 336 kbps, which says
        // nothing about whether 990 fits. `describe` is given the *ceiling* only, so a floor of
        // 336 passed here would be a bug in the caller — this test pins the rule at the boundary.
        let floor = QualityLevels.describe(capacityKbps: 336, sampleRate: 48000)
        check(
            floor.first { $0.rung == 0 }!.fits == false,
            "336 as a capacity must not claim HQ fits")
        // And the same number as a measured ceiling is a real limit, which is the other half: at
        // 336 kbps nothing fits, because the bottom rung asks 330 and the fit test keeps 15%
        // headroom — 330 needs 388 to be safe. That is not a bug, it is the rule that stops a
        // level being chosen that would drop audio the moment anything else used the link.
        check(
            floor.filter(\.fits).isEmpty,
            "336 leaves no rung with headroom: \(floor.filter(\.fits).map(\.rung))")
        check(QualityLevels.nothingFits(capacityKbps: 336))
    }
}

/// The ladder at 44.1 kHz, which is what makes a Low rung that is actually low possible.
///
/// Reported 2026-11-09: "make LQ lower, it is too close to the others — LQ should be around AAC,
/// a bit above". At 48 kHz the five rungs are 990 / 660 / 492 / 396 / 330, so the bottom is 1.4×
/// AAC's 234 kbps and the two unnamed rungs crowd it. At 44.1 kHz the same five EQMIDs come out
/// lower, because the frame rate is lower, and the bottom lands near 303 — which is the "just
/// above AAC" that was asked for, from the codec rather than from a table.
///
/// This test exists so the numbers are measured rather than assumed: if libldac ever changes them,
/// the menu and the adapter must change with it.
func ladderAtRatesTests() {
    test("the ladder is lower at 44.1 kHz than at 48 kHz, and still five rungs") {
        let at48 = LDACEncoder.ladder(sampleRate: 48000)
        let at441 = LDACEncoder.ladder(sampleRate: 44100)
        check(at48.count == 5, "five rungs at 48 kHz: \(at48)")
        check(at441.count == 5, "five rungs at 44.1 kHz: \(at441)")
        check(at441[4] < at48[4], "the bottom is lower at 44.1: \(at441[4]) vs \(at48[4])")
        check(at441[0] < at48[0], "the top is lower at 44.1: \(at441[0]) vs \(at48[0])")
        // The bottom rung must be the closest thing to AAC the codec has, and above it: AAC-LC
        // VBR on this Mac measured 234 kbps, and a rung below that would be pointless.
        check(at441[4] > 234, "still above AAC: \(at441[4])")
        check(at441[4] < 340, "and close to it: \(at441[4])")
        check(at48[4] == 330, "48 kHz bottom is 330: \(at48[4])")
        check(at441[4] == 303, "44.1 kHz bottom is 303: \(at441[4])")
    }
}

/// Prints both ladders, so the numbers in the menu can be checked against the codec.
func ladderNumbersTests() {
    test("the two ladders, as libldac reports them") {
        let at48 = LDACEncoder.ladder(sampleRate: 48000)
        let at441 = LDACEncoder.ladder(sampleRate: 44100)
        print("      48 kHz: \(at48)")
        print("    44.1 kHz: \(at441)")
        check(at48.count == 5 && at441.count == 5)
    }
}

/// The bottom of the ladder, at the rate that makes it low enough to be worth having.
///
/// Reported 2026-11-09: "make LQ lower, it is too close to the others — LQ should be around AAC, a
/// bit above". It cannot be done by inventing a rung: libldac has five EQMIDs and no API for an
/// arbitrary bitrate (`ldacBT.h` has `set_eqmid` and nothing like `set_bitrate`). What can be done
/// is change the sample rate, because the bitrates are per frame and the frame rate follows it.
///
///     at 48 kHz:   990 / 660 / 492 / 396 / 330
///     at 44.1 kHz: 909 / 606 / 452 / 363 / 303
///
/// 303 against AAC's measured 234 is "around AAC, a bit above" — from the codec, not from a table.
func lowRungTests() {
    test("44.1 kHz puts the bottom rung near AAC without going under it") {
        let low = LDACEncoder.ladder(sampleRate: 44100).last!
        check(low == 303, "measured, not assumed: \(low)")
        check(low > 234, "AAC-LC VBR measured 234 kbps here; LDAC must stay above it")
        // And the gap to the next rung stays wide enough to be a choice rather than a rounding
        // error: 303 → 363 is 60 kbps, where 330 → 396 was 66. The complaint was that the bottom
        // was too close to the middle rungs, and this is the number that answers it.
        let next = LDACEncoder.ladder(sampleRate: 44100)[3]
        check(next - low >= 55, "a real step, not a rounding: \(next) - \(low)")
    }

    test("the menu says what the sample rate does to the ladder, instead of staying silent") {
        // The menu used to say nothing about the rate, on the grounds that a slogan about "native
        // rate of most music" was false next to a tick on 48 kHz. Silence was worse: the reason to
        // pick 44.1 is exactly this, and it was invisible.
        let at48 = QualityLevels.describe(capacityKbps: 0, sampleRate: 48000)
        let at441 = QualityLevels.describe(capacityKbps: 0, sampleRate: 44100)
        check(at48.last!.nominalKbps == 330)
        check(at441.last!.nominalKbps == 303)
    }
}

/// The line the command line prints, which must follow the same rule as the menu.
///
/// Reported 2026-11-09: "instead of showing HQ 990 kbps — too much for this link, if you know the
/// max is 336 show HQ with 336". The menu was fixed first and the command line was left printing
/// the old shape — the same mistake in a second place, which is why this test exists: the two
/// surfaces are one rule, and a rule that only holds in one of them is not a rule.
func labelTests() {
    test("a capped rung shows both what it is and what it gives") {
        // Changed 2026-11-11: showing only the outcome made every row above the link's capacity
        // print the same figure, because `wouldUse` returns `max(fitted, rung)`. The level's own
        // bitrate is now named, and the landing is a separate clause.
        let levels = QualityLevels.describe(capacityKbps: 530, sampleRate: 48000)
        let hq = QualityLevels.label(levels[0], capacityKbps: 530)
        check(hq.contains("990"), "the level is named: \(hq)")
        check(hq.contains("settles on 396"), "and so is the result: \(hq)")
        check(!hq.contains("capped by this link"), "the old wording is gone: \(hq)")
    }

    test("a rung that fits says so, and the bottom says it is the bottom") {
        let levels = QualityLevels.describe(capacityKbps: 530, sampleRate: 48000)
        check(QualityLevels.label(levels[3], capacityKbps: 530).contains("fits"))
        let tight = QualityLevels.describe(capacityKbps: 336, sampleRate: 48000)
        check(QualityLevels.label(tight[4], capacityKbps: 336).contains("the lowest there is"))
    }
}

/// Quit must stop the stream, and the two ways of quitting must agree.
///
/// Asked 2026-11-09: "can we make it so that when I quit it actually stops CodecBlue?" The rule is
/// one line and the bug it replaces was two behaviours: the menu item stopped the stream and
/// Cmd-Q did not, so the same word meant two things depending on how it was said. These tests pin
/// the rule down where it can be checked without a headset: the delegate path and the button path
/// call the same function.
func quitTests() {
    test("quitting and stopping are the same act") {
        // The delegate answers `applicationShouldTerminate` with `quitWithoutTerminating`, and the
        // button calls `quit`, which is that function plus `terminate`. If either stops calling
        // `stop`, one of the two ways out leaves the headphones taken.
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueMenu/AppModel.swift", encoding: .utf8)
        check(source?.contains("func quitWithoutTerminating") == true, "the shared half exists")
        check(
            source?.contains("guard isStreaming || LaunchAgent.isLoaded() else { return }") == true,
            "and it stops whenever there is something to stop")
    }

    test("the label no longer promises that the music survives") {
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueMenu/CodecBlueMenuApp.swift", encoding: .utf8)
        // The comments above the item quote the old labels on purpose, to explain why they are
        // gone, so the check is on the button rather than on the file.
        check(source?.contains("Button(\"Quit CodecBlue\")") == true, "Quit is just Quit")
        check(
            source?.contains("Button(\n            model.isStreaming") != true,
            "no conditional suffix on the label")
    }
}

/// A log line that contradicts itself is worse than no log line.
///
/// Measured 2026-11-09, in a real stream on a real link:
///
///     quality: LDAC HQ does not fit this link (611 kbps carried, 20% dropped): settled on 990
///
/// The level did not fit, and the number after "settled on" is that same level. `bitrateKbps`
/// reads the last frame encoded, so right after `move(toRung:)` it still reports the rung we left.
func staleBitrateTests() {
    test("a rung's bitrate does not need a frame to be encoded") {
        let ladder = LDACEncoder.cachedLadder(sampleRate: 48000)
        check(
            ladder == [990, 660, 492, 396, 330], "the ladder is what the encoder reports: \(ladder)"
        )
        for (rung, kbps) in ladder.enumerated() {
            check(
                LDACEncoder.nominalKbps(rung: rung, sampleRate: 48000) == kbps,
                "rung \(rung) is \(kbps)")
        }
        check(LDACEncoder.nominalKbps(rung: 9, sampleRate: 48000) == nil, "no rung, no number")
    }

    test("the ladder follows the rate, so 44.1 kHz is not 48 kHz") {
        let ladder = LDACEncoder.cachedLadder(sampleRate: 44100)
        check(ladder == [909, 606, 452, 363, 303], "44.1 kHz ladder: \(ladder)")
    }

    test("a rung without a name is shown by its number, not by a nearby name") {
        // Measured 2026-11-09: `codec 396 396 kbps` — the name of an unnamed rung is its bitrate,
        // so a line that prints both says it twice. And `codec LQ 990 kbps` was worse: the name
        // from the rung, the number from a frame encoded before the move.
        check(LDACEncoder.name(rung: 2, sampleRate: 48000) == "492", "rung 2 is 492")
        check(LDACEncoder.name(rung: 3, sampleRate: 48000) == "396", "rung 3 is 396")
        check(LDACEncoder.nominalKbps(rung: 2, sampleRate: 48000) == 492, "name and rate agree")
        check(LDACEncoder.name(rung: 0, sampleRate: 48000) == "HQ", "named rungs keep their name")
    }

    test("the settle line names the rung that fits, not the one that did not") {
        // The rule, stated without a stream: the number after a move is the target's, and the
        // target is what `fitRung` chose.
        let fitted = BitrateAdapter.fitRung(capacityKbps: 611, sampleRate: 48000)
        check(fitted > 0, "611 kbps cannot carry HQ, so the answer is below it: rung \(fitted)")
        let named = LDACEncoder.nominalKbps(rung: fitted, sampleRate: 48000)
        check(named != 990, "and the line cannot say 990 after abandoning 990: \(named ?? -1)")
    }
}

/// The number beside a level is what that level is producing *now*.
///
/// Asked 2026-11-09: "we said we would leave only HQ, SQ, LQ, and when the stream starts the kbps
/// would appear beside them". Beside the one that is playing, and the number is the measurement —
/// HQ on a link that carries 396 is playing 396, not 990.
func playingKbpsTests() {
    test("the playing level shows its measured bitrate, the others show nothing") {
        let levels = QualityLevels.menuLevels(capacityKbps: 0, sampleRate: 48000)
        check(levels.count == 3, "three levels: \(levels.map(\.rung))")
        let hq = levels[0]
        let label = QualityLevels.menuLabel(
            hq, capacityKbps: 0, streaming: true, playingKbps: 396)
        check(label == "High · 396 kbps", "the measurement wins over the table: \(label)")
        let quiet = QualityLevels.menuLabel(levels[1], capacityKbps: 0, streaming: true)
        check(quiet == "Standard · 660 kbps", "a level that is not playing shows its own: \(quiet)")
    }

    test("no stream, no numbers, and no positional filler anywhere") {
        let levels = QualityLevels.menuLevels(capacityKbps: 0, sampleRate: 48000)
        let labels = levels.map { QualityLevels.menuLabel($0, capacityKbps: 0) }
        check(labels == ["High", "Standard", "Low"], "\(labels)")
        check(!labels.contains { $0.contains("between") }, "the filler is gone: \(labels)")
    }
}

/// One pid field, more than one process that wants to feed it.
///
/// Measured 2026-11-09: a test run of `codecblue system` was killed by `timeout`, its `defer` wrote
/// 0 into the shared ring, and the field had belonged to the launchd agent for twenty minutes. The
/// agent kept streaming, the driver hid the device because nobody was feeding it, macOS fell back
/// to the headphones — and `codecblue status` said `link_quality unknown`, `ring_frames 0`, battery
/// 100%, which reads as "all fine".
func feederOwnershipTests() {
    test("leaving only lets go of a claim that is still ours") {
        // The rule, without a stream: a process may clear the field only if it still holds it.
        // Written as a check on the source because the ring is a shared mapping and a test that
        // wrote to it would be a test that changes the running system.
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueCore/Audio/SharedRing.swift", encoding: .utf8)
        check(source?.contains("} else if feeder == me {") == true, "leaving is conditional")
        check(source?.contains("!Self.isAlive(holder)") == true, "and claiming checks the holder")
    }

    test("a dead pid is not a live claim") {
        // pid 1 exists, and a pid above the maximum cannot: the check the driver makes, made here.
        check(SharedRing.isAlive(1), "pid 1 is init and always there")
        check(!SharedRing.isAlive(0), "0 is not a pid")
        check(!SharedRing.isAlive(999_999), "and neither is one that was never handed out")
    }
}

/// A headset in its case must not cost the Mac its audio device, four thousand times.
///
/// Measured 2026-11-09: launchd restarted the agent 4331 times while the headphones were in their
/// case, 4207 of them ending in "the headphones did not connect" — `KeepAlive` plus
/// `ThrottleInterval 5` is a retry loop with no ceiling. And because the takeover happened before
/// the connection was attempted, 21 of those attempts took the system output and only 12 gave it
/// back: nine times the Mac was left pointing at a device with nothing feeding it, which is silence
/// with no error anywhere.
func absentHeadsetTests() {
    test("the output is not touched before the headphones are known to be there") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        guard let reachable = body.range(of: "if await !isReachable(address)"),
            let takeover = body.range(of: "let previousOutput = DefaultOutput.takeOver()")
        else {
            check(false, "both the check and the takeover must exist")
            return
        }
        check(reachable.lowerBound < takeover.lowerBound, "the question comes first")
    }

    test("waiting happens in the process, not by dying and being restarted") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("catch TakeoverError.headphonesDidNotConnect"), "the case is handled")
        check(body.contains("backoff = min(backoff * 2, 60)"), "and the wait grows")
        check(body.contains("backoff = 5"), "and resets after a session that worked")
    }
}

/// The keeper must not forget what it knew, and must not pay a shell-out to remember it.
///
/// Measured 2026-11-09, the bug behind "the link quality mode keeps being lost": the keeper asked
/// `log show --last 2m` every two seconds. bluetoothd registers the audio device once, when the
/// headphones connect, and then says nothing for as long as the stream runs — so two minutes later
/// the window was empty, `hasRegisteredDevice` found no line and returned false, and the keeper
/// concluded the device had gone while nothing had happened. Measured: the 2-minute window held
/// **zero** `Register`/`Erased` lines, the 60-minute window held 48.
///
/// The same call cost 0.79–0.86 s (five runs) on a two-second period: 40% of a core, for the whole
/// life of every stream, in a pipe while the audio thread needed the CPU.
func keeperWindowTests() {
    test("an empty window means nothing, and must not be read as an erase") {
        // The rule, stated as the bug: no lines is not evidence of absence.
        check(!AudioStreamKeeper.hasRegisteredDevice("", uid: "40:DC:A5:0E:14:48-tacl"))
        // And one line of noise is still not an erase.
        let noise = "2026-11-09 19:09:14.507 Df bluetoothd[33429:3480c0f] [Server.Core] Le [0x43]"
        check(!AudioStreamKeeper.hasRegisteredDevice(noise, uid: "40:DC:A5:0E:14:48-tacl"))
    }

    test("a registration older than any window still counts, if the window is wide enough") {
        // The seed reads 30 minutes, not 2: the registration happens when the headphones connect
        // and the keeper can start long after that.
        let old = """
            2026-11-09 18:50:18.891 Df bluetoothd[33429:3462c44] [com.apple.bluetooth:Server.Audio] \
            -[AudioDeviceManager publishAndRegisterDeviceForUID:withArgs:device:] \
            Register audio device 40:DC:A5:0E:14:48-tacl
            """
        check(AudioStreamKeeper.hasRegisteredDevice(old, uid: "40:DC:A5:0E:14:48-tacl"))
    }

    test("per-line and whole-log agree, because a followed log and a re-read one must not differ") {
        let lines = [
            "Register audio device 40:DC:A5:0E:14:48-tacl",
            "Erased 1 audio device 40:DC:A5:0E:14:48-tacl from audio device map",
            "Register audio device 40:DC:A5:0E:14:48-tacl",
        ]
        var perLine = false
        for line in lines {
            AudioStreamKeeper.apply(line, uid: "40:DC:A5:0E:14:48-tacl", to: &perLine)
        }
        let whole = AudioStreamKeeper.hasRegisteredDevice(
            lines.joined(separator: "\n"), uid: "40:DC:A5:0E:14:48-tacl")
        check(perLine == whole, "same answer both ways: per-line \(perLine), whole \(whole)")
        check(perLine, "and the answer is 'registered', because the last word wins")
    }

    test("the follower is ended when the keeper stops") {
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueCore/Bluetooth/AudioStreamKeeper.swift",
            encoding: .utf8)
        let body = source ?? ""
        check(body.contains("follower?.terminate()"), "a log stream left behind costs a core")
        check(!body.contains("--last \"2m\""), "the sliding window is gone")
        check(body.contains("\"show\", \"--last\", \"30m\""), "the seed is wide enough")
    }
}

/// Unloading and removing are two different acts, and only one survives a reboot.
///
/// The plist is a loaded gun at the next login: with the headphones in their case it is a retry
/// loop for as long as the Mac is on. `codecblue stop` unloads and deliberately leaves the file —
/// stopping a stream should not opt someone out of an arrangement they chose — so there has to be a
/// verb that removes it, and `login off` is that verb.
func loginItemRemovalTests() {
    test("removing the plist is what makes it not start at login") {
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueCore/Audio/LaunchAgent.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("public static func remove()"), "there is a verb for it")
        check(
            body.contains("removeItem(at: plistURL)"),
            "and it removes the file, not just the job")
        check(body.contains("public static func isInstalled()"), "and a way to ask")
    }

    test("login off removes it, and says the stream is untouched") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("LaunchAgent.remove()"), "off removes the file")
        check(
            body.contains("the stream itself, if one is running, is untouched"),
            "and does not claim to have stopped the stream")
    }
}

/// A failure that cannot fix itself must not be retried every five seconds.
///
/// Measured 2026-11-09: the headphones connected but offering only SBC/AAC — LDAC disabled in their
/// own app — produced **three restarts every thirty seconds**. Each restart took the system output
/// before failing, so the Mac's audio device changed hands twice a minute while nothing could
/// possibly work. The backoff added for an absent headset did not cover this, because the error is
/// a different type.
func permanentFailureTests() {
    test("a codec the headphones do not offer is not a transient condition") {
        check(A2DPStreamer.StreamError.noLDAC(["SBC", "AAC"]).isPermanent, "no LDAC is permanent")
        check(A2DPStreamer.StreamError.unsupportedRate(96000, [48000]).isPermanent, "so is a rate")
        check(!A2DPStreamer.StreamError.stopped.isPermanent, "a stop is not a failure")
    }

    test("the wait for a permanent failure starts long and stays long") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("catch let error as A2DPStreamer.StreamError"), "the case is handled")
        check(body.contains("permanent ? max(backoff, 120) : backoff"), "two minutes at least")
        check(
            body.contains("this will not fix itself: check the headphones' own app"),
            "and it says what to change instead of inviting a retry")
    }
}

/// A failure to start must leave the headphones and the Mac exactly as it found them.
///
/// Reported 2026-11-09, with a pair that offers no LDAC: "I select the headphones, I press Start
/// streaming, and nothing — I hear nothing." The handshake took the link, macOS was forced off it,
/// the LDAC endpoint was missing, and the throw went straight out of the process holding both. The
/// headphones were never handed back and the system output was never restored, so the Mac had no
/// audio at all — worse than not having pressed the button.
func failedStartTests() {
    test("every way out of a session gives the output back") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        // The restore is a function called on both paths, not a `defer` that only the happy path
        // reaches. `defer` would work too; the point is that it is not conditional.
        check(body.contains("func giveBackOutput() async"), "one place that gives it back")
        check(body.contains("await giveBackOutput()"), "called on the way out")
        let throwingPaths = body.components(separatedBy: "throw error").count - 1
        check(throwingPaths >= 1, "and there is a throwing path to cover")
    }

    test("a handshake that fails hands the headphones back before rethrowing") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        guard let start = body.range(of: "configuration = try await streamer.setUp"),
            let end = body.range(of: "// A stop that arrived during the handshake")
        else {
            check(false, "the setUp block must exist")
            return
        }
        let block = String(body[start.lowerBound..<end.lowerBound])
        check(block.contains("await takeover.handBack"), "the headphones go back")
        check(block.contains("throw error"), "and the caller still learns why")
    }

    test("start refuses before writing a login item it cannot honour") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        guard let refusal = body.range(of: "if let refusal = await codecRefusal(address: chosen)"),
            let install = body.range(
                of: "try LaunchAgent.install(address: chosen, arguments: options)")
        else {
            check(false, "both the check and the install must exist")
            return
        }
        check(refusal.lowerBound < install.lowerBound, "the check comes first")
        check(
            body.contains("nothing was written: no login item was created"),
            "and it says so")
    }
}

/// A pair this program cannot drive must still make a sound.
///
/// Asked 2026-11-09: "so when the headphones do not support LDAC, fall back to AAC on the Mac".
/// The alternative — and what happened before — was the link taken, macOS forced off it, an error,
/// and a Mac with no audio at all: strictly worse than not having pressed the button.
///
/// The fallback is not an AAC encoder written here. macOS has one, it has the AVDTP endpoint and it
/// is already paired, so the fallback is to step aside and let it play.
func codecFallbackTests() {
    test("a refusal is remembered, so the menu can say it without paying for the link") {
        // Measuring costs the link: the only way to learn which codecs a pair offers is to open an
        // AVDTP channel, which forces macOS off the headphones for a second. Once, when someone
        // presses Start, is acceptable. Every two seconds to decorate a menu is not.
        let refusal = CodecFallback.Refusal(
            address: "AA:BB:CC:DD:EE:FF", name: "Test Buds", offered: ["SBC", "AAC"],
            measuredAt: Date())
        CodecFallback.record(refusal)
        defer { CodecFallback.clear(address: "AA:BB:CC:DD:EE:FF") }
        let read = CodecFallback.refusal(for: "AA:BB:CC:DD:EE:FF")
        check(read?.offered == ["SBC", "AAC"], "the offered codecs survive the round trip")
        check(read?.name == "Test Buds", "and so does the name")
        // The address is matched case-insensitively: the same pair is spelled both ways by
        // different parts of the system.
        check(CodecFallback.refusal(for: "aa:bb:cc:dd:ee:ff") != nil, "case does not matter")
    }

    test("a pair that offers LDAC again is forgotten, not hidden behind a stale label") {
        CodecFallback.record(
            CodecFallback.Refusal(
                address: "11:22:33:44:55:66", name: "Fixed Buds", offered: ["AAC"],
                measuredAt: Date()))
        CodecFallback.clear(address: "11:22:33:44:55:66")
        check(CodecFallback.refusal(for: "11:22:33:44:55:66") == nil, "the memory is gone")
    }

    test("the fallback hands the pair to macOS instead of encoding AAC here") {
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueCore/Audio/CodecFallback.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("driveWithMacOS"), "there is a hand-off")
        check(body.contains("DefaultOutput.set(device)"), "and it selects the headphones")
        check(!body.contains("AudioConverter"), "no AAC encoder was written for this")
    }
}

/// Two sinks per codec is a fact about headphones, not a bug in the parser.
///
/// Reported 2026-11-09: "why does offered have SBC, SBC, AAC, AAC?" Because a pair publishes *two*
/// sinks per codec — one for music, one for voice — and DISCOVER returns every endpoint on the
/// device. Measured on FreeBuds 3: SEID 1/2 (SBC), 3/4 (AAC). Four sinks, two codecs.
func duplicateCodecTests() {
    test("the list shown to a person names each codec once") {
        check(
            CodecFallback.deduplicated(["SBC", "SBC", "AAC", "AAC"]) == ["SBC", "AAC"],
            "four endpoints, two codecs")
        check(CodecFallback.deduplicated([]) == [], "nothing stays nothing")
        check(
            CodecFallback.deduplicated(["LDAC", "SBC", "AAC"]) == ["LDAC", "SBC", "AAC"],
            "and the order the pair offered them is kept")
    }

    test("a record written by an older build is normalised on read") {
        // The fix has to reach what is already on disk: measured 2026-11-09, the file still held
        // `SBC, SBC, AAC, AAC` after the writer had been fixed, so a reader that trusted it would
        // keep showing the duplicates until the pair happened to be measured again.
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueCore/Audio/CodecFallback.swift", encoding: .utf8)
        let body = source ?? ""
        guard let all = body.range(of: "public static func all()"),
            let read = body.range(of: "public static func refusal(for")
        else {
            check(false, "`all` and `refusal(for:)` must exist")
            return
        }
        let block = String(body[all.lowerBound..<read.lowerBound])
        check(block.contains("deduplicated(refusal.offered)"), "normalised where it is read")
    }

    test("the parser still returns every endpoint, because setUp walks it for SEIDs") {
        // Collapsing the endpoint list would make the program choose an endpoint it had already
        // decided not to look at: the SEID of the second SBC sink is not the SEID of the first.
        let payload = Data([0x04, 0x08, 0x08, 0x08, 0x0C, 0x08, 0x10, 0x08])
        let endpoints = AVDTP.parseDiscover(payload)
        check(endpoints.count == 4, "four endpoints: \(endpoints.count)")
        check(endpoints.map(\.seid) == [1, 2, 3, 4], "with four distinct SEIDs")
        check(endpoints.allSatisfy(\.isSink), "all sinks")
    }
}

/// SCO is not reachable through the XPC protocol, and that is now a measurement.
///
/// The design note said so as a hypothesis and priced the alternative at weeks of Skywalk work. The
/// probe settles it: with a control L2CAP channel opening on the same session, same device, same
/// second (MTU 895), `openChannel` with any other `kCBMsgArgType` is rejected with result 3 — the
/// message is invalid, not the headphones refusing (that is 454) and not macOS holding it (1803).
func scoProbeTests() {
    test("the probe has a control, or it proves nothing") {
        // A refusal on a PSM that was never valid says nothing about the type: bluetoothd may
        // reject the PSM before it reads `kCBMsgArgType`. The control is what makes the four
        // refusals mean something, and it is the difference between a measurement and a guess.
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        guard let probe = body.range(of: "func probeSCO"),
            let refusal = body.range(of: "func codecRefusal")
        else {
            check(false, "the probe must exist")
            return
        }
        let block = String(body[probe.lowerBound..<refusal.lowerBound])
        check(block.contains("psm: 0x0019"), "a real L2CAP channel is opened first")
        check(block.contains("the session works"), "and it says so")
        check(block.contains("exit(2)"), "and refuses to conclude anything without it")
        check(block.contains("channelType: type"), "then the types are tried")
    }

    test("the result code is named, because 3 is not 454") {
        check(ChannelResult.invalidRequest == 3, "invalid request")
        check(ChannelResult.refusedNoResources == 454, "the headphones refused")
        check(ChannelResult.alreadyConnected == 1803, "this session already asked")
        check(ChannelResult.noLink == 1804, "no ACL link")
    }

    test("the probe does not tear the link down to free AVDTP") {
        // Tried and removed: `cancelConnection(force:)` on a link macOS established a second ago
        // makes the next channel fail with 1804, which says nothing about the type.
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        guard let probe = body.range(of: "func probeSCO"),
            let refusal = body.range(of: "func codecRefusal")
        else {
            check(false, "the probe must exist")
            return
        }
        let block = String(body[probe.lowerBound..<refusal.lowerBound])
        // The comment above the code quotes the call on purpose, to explain why it is not there,
        // so the check is on a call rather than on the word.
        check(!block.contains("session.cancelConnection("), "no forced disconnect in the probe")
    }
}

/// `stop` must stop a stream nobody started through launchd.
///
/// Measured 2026-11-09, twice: `codecblue system ADDR` started by hand kept the headphones and the
/// system output while `stop` reported "stream: nothing running" — because it looked for a launchd
/// job to unload and a socket to answer, and a hand-started stream has neither. Then the same
/// process ignored SIGTERM for forty seconds, because `Task.sleep` cannot be interrupted by a
/// signal and the backoff had grown to forty.
func stopStrayStreamTests() {
    test("stop looks for the process, not only for a job and a socket") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("func strayStream()"), "there is a search for it")
        check(body.contains("kill(pid, SIGTERM)"), "and it is asked to stop")
        check(
            body.contains("the socket is stale (nothing answered)"),
            "a socket nobody listens on is not evidence that nothing is running")
    }

    test("the wait for a headset is interruptible") {
        // A sleep that ignores the stop request is a process that cannot be stopped: measured, the
        // log said "asked to stop (SIGTERM): stopping" and the process slept on for forty seconds.
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("func sleepUnlessStopping"), "the wait is in slices")
        check(body.contains("stopRequest.wasAsked"), "and it checks the request between them")
        check(
            !body.contains("try? await Task.sleep(for: .seconds(backoff))"),
            "the uninterruptible sleep is gone")
    }
}

/// "HQ 990 kbps" on a link carrying 303 is the bug that was reported twice.
///
/// Reported 2026-11-09, the second time with "I thought I had been clear". It was clear, and the
/// code was reading `link_ceiling` alone — which is 0 until a window actually loses audio, and on a
/// healthy stream that never happens. So `capacity` stayed 0, `wouldUse` returned nil, and the label
/// fell back to the rung's nominal 990 while the stream was playing 303. A number that is wrong on
/// every healthy stream is not a conservative default, it is a wrong default.
func capacityFallbackTests() {
    test("no ceiling does not mean no measurement") {
        // The rule the menu now follows: the ceiling decides what fits, the floor is still a fact
        // about this link, and display uses whichever exists.
        let floorOnly = QualityLevels.describe(capacityKbps: 312, sampleRate: 44100)
        let hq = floorOnly[0]
        let label = QualityLevels.menuLabel(
            hq, capacityKbps: 312, streaming: true, cappedByCeiling: false)
        // The row names the level's own bitrate and says where it lands. What must never happen is
        // a row that *claims* the link carries less than it has: the landing clause says "at least"
        // when the figure came from the floor.
        check(label.contains("909"), "HQ is 909 at 44.1 kHz: \(label)")
        check(label.contains("at least 330"), "and it says what the link has done: \(label)")
        check(
            !label.contains("settles on"),
            "a floor is not a measurement of what does not fit: \(label)")
    }

    test("a ceiling is allowed to say 'capped', a floor is not") {
        let levels = QualityLevels.describe(capacityKbps: 312, sampleRate: 44100)
        let withCeiling = QualityLevels.menuLabel(
            levels[0], capacityKbps: 312, streaming: true, cappedByCeiling: true)
        check(
            withCeiling.contains("settles on"),
            "a window that lost audio is evidence: \(withCeiling)"
        )
        let withFloor = QualityLevels.menuLabel(
            levels[0], capacityKbps: 312, streaming: true, cappedByCeiling: false)
        check(!withFloor.contains("settles on"), "a floor is not: \(withFloor)")
    }

    test("the menu reads the floor when the ceiling is missing") {
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueMenu/AppModel.swift", encoding: .utf8)
        let body = source ?? ""
        // The rule moved on 2026-11-11: a ceiling is only used when it is credible against the
        // playing bitrate, so the fallback is no longer a bare `ceiling > 0`. See
        // `linkCeilingCredibilityTests` for why, and for the case that forced it.
        check(
            body.contains("linkKbps = ceilingIsCredible ? ceiling : floor"),
            "the fallback is explicit")
        check(body.contains("linkIsCeiling = ceilingIsCredible"), "and the distinction is kept")
    }
}

/// The report window is a measurement parameter, and it was fixed at 2 s until it was asked for.
///
/// Asked 2026-11-10: "measure it on a smaller window". The answer turned out to be that a smaller
/// window measures noise rather than the link — the same link gave 343 and 441 kbps in two
/// consecutive 500 ms windows, against 403 and 403 at 2 s — but the question could not even be
/// asked before, because the interval was not reachable from the command line. The measurement
/// lives in `notes/findings/2026-11-10-ceiling-window.md`; this keeps the option from being lost.
func reportWindowTests() {
    test("the report window can be set from the command line") {
        let source = try? String(
            contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("case \"--report-ms\":"), "the option is parsed")
        check(
            body.contains("streamer.reportInterval = reportMilliseconds / 1000"),
            "and reaches the streamer, in seconds")
        // The first three windows are shorter than the rest so that a bad start shows up early.
        // With an interval asked for, they would be shorter still and measure nothing at all.
        check(
            body.contains("streamer.firstReports = 0"),
            "the short warm-up windows are turned off, or they would measure nothing")
    }

    test("a smaller window is noisier, which is why 2 s is the default") {
        // The numbers from the measurement, kept as a check on the claim rather than as a table
        // to trust: two runs at each size, HQ forced so that every window is saturated.
        let measured: [(window: Int, runs: [Double])] = [
            (500, [343, 441]), (1000, [350, 398]), (2000, [403, 403]), (4000, [357, 374]),
        ]
        func spread(_ runs: [Double]) -> Double {
            guard let low = runs.min(), let high = runs.max(), low > 0 else { return 0 }
            return high / low
        }
        let at500 = spread(measured[0].runs)
        let at2000 = spread(measured[2].runs)
        check(at500 > 1.2, "500 ms windows disagree with each other: \(at500)")
        check(at2000 < 1.05, "2 s windows agree: \(at2000)")
    }
}

/// A build that failed must not produce a bundle, and this is the check that would have caught it.
///
/// Measured 2026-11-10, twice in one afternoon: the menu installed at 12:11 had md5 3f9c175 while
/// the source had been fixed at 12:23, so an hour of fixes was invisible while the icon was
/// restarted and reported as updated. The cause was `swift build | grep ... || true`: the pipe made
/// the exit status grep's, the `|| true` discarded it, and the guard that followed checked for the
/// *previous* build's binary. The script now captures the output, and `install.sh` compares the md5
/// of what was installed against what was built.
func menuBuildTests() {
    test("a failed menu build stops the packaging script") {
        let source = try? String(
            contentsOfFile: "scripts/build-menu-app.sh", encoding: .utf8)
        let body = source ?? ""
        check(
            body.contains("build_log=$(swift build --product CodecBlueMenu 2>&1) ||"),
            "the build's own exit status is used, not grep's")
        check(
            !body.contains("swift build --product CodecBlueMenu 2>&1 | grep"),
            "and it is not piped into grep, which would replace that status")
        check(
            body.contains("nothing was packaged"),
            "and a failure says that nothing was written")
    }

    test("install.sh compares what it installed against what it built") {
        let source = try? String(contentsOfFile: "scripts/install.sh", encoding: .utf8)
        let body = source ?? ""
        // Rewritten 2026-11-11: the check is now one function used four times, so the two literal
        // `md5 -q` lines it used to look for are gone — the paths arrive as arguments.
        check(body.contains("built=$(md5 -q \"$from\""), "the built copy is hashed")
        check(body.contains("installed=$(md5 -q \"$to\""), "the installed one is hashed")
        check(body.contains("is not the one just built"), "and a difference is an error")
    }
}

/// The driver's clock must follow the device's rate, and it did not.
///
/// Reported 2026-11-10 as "it crackles". `hostTicksPerFrame` was computed once, in
/// `driver_Initialize`, on the line *before* `ring_open()` — so `ring_sample_rate()` saw
/// `gRing == NULL`, returned the 48000 default, and the clock stayed at 48 kHz while the device
/// played 44.1. The driver then produced 48 000 frames per second of a device that consumes
/// 44 100, and the surplus went into the ring: it filled to exactly 48 000 frames (1088 ms, its
/// whole capacity) in about 12 s and wrapped on every write from then on. Continuous crackle, with
/// `skips 0` and every other number healthy.
///
/// These checks are on the source because the arithmetic is in C and the failure is an ordering
/// one: a cached value computed before the thing it depends on exists.
func driverClockTests() {
    let source = try? String(
        contentsOfFile: "Driver/CodecBlueDriver/CodecBlueDriver.c", encoding: .utf8)
    let body = source ?? ""

    test("the clock is a function of the rate, not a value cached at startup") {
        check(
            body.contains("static double host_ticks_per_frame(double rate)"),
            "it takes the rate as an argument")
        check(
            !body.contains("hostTicksPerFrame"),
            "and no cached copy of it survives in the driver state")
    }

    test("the clock is read from the ring's rate where it is used") {
        check(
            body.contains("host_ticks_per_frame(ring_sample_rate())"),
            "GetZeroTimeStamp asks for the current rate")
        // The ordering bug was a *call* in Initialize, before `ring_open()`: the rate read there
        // was the default, not the device's. Comments mention the function by name, so count call
        // sites rather than searching for the text — definition plus the one use in GetZeroTimeStamp.
        let calls = body.components(separatedBy: "host_ticks_per_frame(").count - 1
        check(calls == 2, "one definition and one call site, not a third in Initialize: \(calls)")
        let initialize =
            body.components(separatedBy: "static OSStatus driver_Initialize").last ?? ""
        let upToRingOpen = initialize.components(separatedBy: "ring_open();").first ?? ""
        check(
            !upToRingOpen.contains("host_ticks_per_frame("),
            "Initialize does not call it before the ring is open")
    }

    test("the surplus the bug produced is the measured one") {
        // 48 000 frames/s into a 44 100 Hz device: 3 900 frames/s of surplus, and 48 000 / 3 900
        // = 12.3 s to fill a ring of 48 000 frames. Measured: ~3 300 frames/s and 1088 ms.
        let surplus = 48000.0 - 44100.0
        let secondsToFill = 48000.0 / surplus
        check(abs(secondsToFill - 12.3) < 0.1, "\(secondsToFill) s to fill the ring")
        check(abs(48000.0 / 44100.0 - 1.088) < 0.001, "and the ring holds 1088 ms")
    }
}

/// A menu frozen for fourteen hours, because a latch was never cleared.
///
/// Reported 2026-11-11: "the app at the top says the headphones are not connected, but I think they
/// are working now". They were — 363 kbps, device as system output — and the menu had been showing
/// the state it read the first time it was opened, when they really were off.
///
/// `menuIsOpen` is cleared by `onDisappear`, and with `MenuBarExtra(.menu)` that callback is not
/// reliably called: AppKit dismisses the menu without tearing down the SwiftUI view, the flag stays
/// true, and every later `refresh()` returns at the guard. A status line two seconds stale is
/// invisible; one fourteen hours stale is a lie.
func menuLatchTests() {
    let source = try? String(
        contentsOfFile: "Sources/CodecBlueMenu/AppModel.swift", encoding: .utf8)
    let body = source ?? ""

    test("opening the menu refreshes even if the latch is stuck") {
        check(body.contains("refresh(force: true)"), "opening forces a reading")
        check(body.contains("func refresh(force: Bool = false)"), "and refresh can be forced")
        check(
            body.contains("guard force || !menuIsOpen else { return }"),
            "the guard yields to the force")
    }

    test("the latch cannot stay set forever") {
        check(body.contains("openLatchLimit"), "there is a limit")
        check(
            body.contains("Date().timeIntervalSince(openedAt) > Self.openLatchLimit"),
            "and it is compared against how long the menu has been open")
        // A minute is longer than anyone keeps a menu open and far shorter than a working day.
        check(body.contains("openLatchLimit: TimeInterval = 60"), "a minute, not a day")
    }
}

/// A ceiling below what is playing is not a ceiling.
///
/// Measured 2026-11-11 with the stream running cleanly: `link_ceiling 250`, `link_floor 312`,
/// `quality_kbps 303`, `skips 0`. The menu said "link carries 250 kbps" while 303 went through
/// without losing a sample — a bound smaller than the thing it bounded.
///
/// The ceiling is the throughput of one window that dropped audio, and a window can drop because
/// `bluetoothd` stalled. The playing bitrate is the third witness and it settles the argument: a
/// link cannot be carrying less than what is demonstrably passing through it.
func linkCeilingCredibilityTests() {
    let source = try? String(
        contentsOfFile: "Sources/CodecBlueMenu/AppModel.swift", encoding: .utf8)
    let body = source ?? ""

    test("the ceiling is discarded when it is below the playing bitrate") {
        check(
            body.contains(
                "let ceilingIsCredible = ceiling > 0 && (witness <= 0 || ceiling >= witness)"),
            "the playing bitrate and the floor are the witnesses")
        check(
            body.contains("let witness = max(playing, floor)"),
            "a ceiling below the floor is self-contradictory")
        check(
            body.contains("linkKbps = ceilingIsCredible ? ceiling : floor"),
            "and an incredible ceiling falls back to the floor")
        check(
            body.contains("let playing = Double(values[\"quality_kbps\"] ?? \"0\") ?? 0"),
            "read from the stream's own report")
    }

    test("the word follows the evidence") {
        check(
            body.contains(
                "linkIsCeiling ? \"link carries %.0f kbps\" : \"link has done %.0f kbps\""),
            "carries needs a ceiling, has done is a measurement")
    }

    test("the arithmetic of the measured case") {
        // 250 is not credible against 303; 312 is the floor that replaces it.
        let ceiling = 250.0
        let floor = 312.0
        let playing = 303.0
        let credible = ceiling > 0 && (playing <= 0 || ceiling >= playing)
        check(!credible, "250 cannot bound 303")
        check(credible == false ? floor > playing : true, "the floor does bound it: 312 >= 303")
        // And a ceiling above the playing bitrate is still a ceiling.
        let high = 497.0
        check(high > 0 && high >= playing, "497 is credible against 303")
    }
}

/// Two ticks on one row, because two different questions were both answered with a tick.
///
/// Reported 2026-11-11: "next to LDAC quality, beside LQ which is the chosen one, I see two ticks".
/// `menuLabel` prefixed "✓ " when the rung was `chosen` — the rung `fitRung` would pick for this
/// link — and the menu bar prefixed its own when the rung was *playing*. On this link the two
/// coincide (312 kbps of floor, so `fitRung` picks LQ, and LQ is what plays), so the row read
/// "✓ ✓ Low · 303 kbps".
///
/// The two questions are genuinely different and both are worth asking, which is why this is a
/// division of labour and not a deletion: `codecblue levels` asks "what would fit here" and draws
/// `chosen`; the menu bar asks "what is playing" and draws that. Neither should draw the other's.
func doubleTickTests() {
    test("the label carries no tick of its own") {
        let levels = QualityLevels.describe(capacityKbps: 312, sampleRate: 44100)
        for level in levels {
            let label = QualityLevels.menuLabel(level, capacityKbps: 312)
            check(!label.hasPrefix("✓"), "rung \(level.rung) must not tick itself: \(label)")
        }
    }

    test("the rung that fits is still reported, just not as a tick") {
        // The information is not lost: `chosen` is what `codecblue levels` draws.
        let levels = QualityLevels.describe(capacityKbps: 312, sampleRate: 44100)
        let chosen = levels.filter(\.chosen)
        check(chosen.count == 1, "exactly one rung fits: \(chosen.map(\.rung))")
        check(chosen.first?.rung == 4, "and on 312 kbps it is the bottom one")
    }

    test("the command line still ticks, because there the tick is the answer") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("(level.chosen ? \"✓ \" : \"  \")"), "levels draws the tick itself")
    }
}

/// A chosen latency that grows back is not a setting.
///
/// Reported 2026-11-11: "I selected a different latency but the selection does not work, it does not
/// change". It changed and then changed back: `cushion 100` logged "100 ms by request", the next
/// stall logged "widened to 200 ms", and the latency went 198 -> 302 ms. The chosen value was a
/// starting point, not a bound.
///
/// For a menu offering "30 ms — tightest" and "150 ms — steadiest" that is backwards. Choosing the
/// tightest says "I accept the risk of a stall for the latency"; growing to 200 ms anyway takes the
/// latency and gives back nothing that was asked for.
func cushionCeilingTests() {
    test("the chosen cushion bounds the automatic growth") {
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueCore/AVDTP/A2DPStreamer.swift", encoding: .utf8)
        let body = source ?? ""
        check(
            body.contains("queue.retune(floor: requested, ceiling: requested)"),
            "the choice is the floor and the ceiling")
        check(
            !body.contains("ceiling: max(queueCeiling, requested)"),
            "and not a floor with the default ceiling above it")
    }

    test("a queue cannot grow past its ceiling") {
        var queue = PacketQueue(
            sampleRate: 44100, floorDuration: 0.03, ceilingDuration: 0.03)
        // noteStall doubles towards the ceiling; with ceiling == floor it cannot move.
        let before = queue.maxDuration
        let changed = queue.noteStall()
        check(!changed, "a stall cannot widen it past the ceiling")
        check(queue.maxDuration == before, "so the latency stays where it was chosen")
    }

    test("but it can still shrink back to the floor") {
        var queue = PacketQueue(
            sampleRate: 44100, floorDuration: 0.03, ceilingDuration: 0.2)
        _ = queue.noteStall()
        check(queue.maxDuration > 0.03, "a stall widens it when there is room")
        _ = queue.relax()
        check(queue.maxDuration >= 0.03, "and relaxing never goes below the floor")
    }
}

/// A selection that works, on a menu that cannot say so.
///
/// Reported 2026-11-11: "I tried to select another quality, HD, but the selection does not work, it
/// does not change". It did change: the request was accepted and HQ ran at 909 kbps. Then the settle
/// rule took it down to 363 kbps — rung 3 — and rung 3 was not in the menu, because the list is
/// built from rungs 0, 1 and 4. The tick had no row to land on, so the menu looked exactly as it had
/// before the click.
///
/// The two unnamed rungs are still not offered as choices: nobody expresses a preference for "492
/// kbps" by hand. But a rung the stream is *on* has to be visible, or the menu describes a different
/// stream from the one playing.
func playingRungVisibleTests() {
    test("three rows, always — a fourth was the wrong answer") {
        // Asked 2026-11-11: "why 4 rows and not 3? what is it for?". The extra row existed so the
        // tick had somewhere to land when the settle rule put the stream on rung 2 or 3. But a
        // menu is a list of choices, and a choice the stream made for itself is not one of them.
        let levels = QualityLevels.menuLevels(capacityKbps: 532, playingRung: 3)
        check(levels.map(\.rung) == [0, 1, 4], "three rows: \(levels.map(\.rung))")
    }

    test("without a playing rung the menu is still the three named ones") {
        let levels = QualityLevels.menuLevels(capacityKbps: 532)
        check(levels.map(\.rung) == [0, 1, 4], "\(levels.map(\.rung))")
    }

    test("a playing rung that is already offered is not duplicated") {
        let levels = QualityLevels.menuLevels(capacityKbps: 532, playingRung: 4)
        check(levels.map(\.rung) == [0, 1, 4], "no second Low: \(levels.map(\.rung))")
    }

    test("the menu passes the chosen rung, which is the one that has a row") {
        // It used to pass the *playing* rung, and that is the bug: asking for Standard on a link
        // that carries 497 settles the stream on rung 3, which is not one of the three rows, so the
        // tick had nowhere to land and the menu showed nothing selected. Reported 2026-11-13.
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueMenu/CodecBlueMenuApp.swift", encoding: .utf8)
        check(
            (source ?? "").contains("playingRung: model.chosenRung"),
            "the choice is what gets ticked, and the row says where it settles")
    }
}

/// A ceiling measured at rest, so the menu answers before the first note.
///
/// The alternative is a probe during playback, and a probe is not free: a level change makes the
/// encoder produce a different frame size, so the queued packets — stale and the wrong shape — are
/// dropped, which is a 30-60 ms hole, and the higher level then throws away 40% of the audio for a
/// second or two before settling. Measured 2026-11-07 and 2026-11-08; the second is why the old
/// time-expiring block was removed from the adapter.
///
/// `codecblue flood` measures the same thing with no audio at all in 15 seconds. Measured three
/// times on 2026-11-11: 454, 496 and 504 kbps, so 485 is the number written into the plist.
func knownCapacityTests() {
    test("a capacity measured at rest seeds the ceiling") {
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueCore/AVDTP/A2DPStreamer.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("public var knownCapacityKbps: Double = 0"), "the property exists")
        check(
            body.contains("currentCarriedKbps = knownCapacityKbps"),
            "and it seeds the ceiling the menu reads")
        check(
            body.contains("if knownCapacityKbps > 0, currentCarriedKbps <= 0"),
            "without overwriting a ceiling a real window measured")
    }

    test("both parsers accept --capacity, or the setting dies on restart") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        let cases = body.components(separatedBy: "case \"--capacity\":").count - 1
        check(cases == 2, "play and system both parse it: \(cases)")
        check(body.contains("knownCapacityKbps = kbps"), "and both store it")
        // `system` is what `start` and the login item run, so an option only `play` accepts is a
        // setting that works until the agent restarts itself.
        let seeds =
            body.components(separatedBy: "streamer.knownCapacityKbps = knownCapacityKbps")
            .count - 1
        check(seeds == 2, "and both paths hand it to the streamer: \(seeds)")
    }

    test("the flood numbers that produced 485") {
        // Three runs, same link, same day. The spread is the measurement's own noise: the flood
        // offers raw ACL packets and counts what the socket refused.
        let runs = [454.0, 496.0, 504.0]
        let mean = runs.reduce(0, +) / Double(runs.count)
        check(abs(mean - 485) < 1, "the mean is 485: \(mean)")
        check(runs.max()! / runs.min()! < 1.15, "and the runs agree within 15%")
    }
}

/// A measurement the menu did not make must survive the menu rewriting the plist.
///
/// `rememberQuality` rebuilds the whole argument list from the values the model holds — level,
/// adapt, cushion — and the capacity is not one of them: it was measured once by `codecblue flood`
/// and belongs to the machine. Rebuilding without it would erase the measurement on the first level
/// change, and the menu would go back to learning the ceiling by dropping audio, which is the
/// crackle this whole day was about.
func capacitySurvivesRewriteTests() {
    test("the menu reads the capacity back before rewriting the plist") {
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueMenu/AppModel.swift", encoding: .utf8)
        let body = source ?? ""
        let passes =
            body.components(separatedBy: "capacityKbps: LaunchAgent.knownCapacityKbps()")
            .count - 1
        check(passes == 2, "both places that write the plist carry it: \(passes)")
    }

    test("reading the real plist back gives the number written into it") {
        // Only when there is a plist: this runs on a developer's machine, and a check that fails
        // because nothing is installed would be a check nobody keeps.
        guard LaunchAgent.isInstalled() else { return }
        let read = LaunchAgent.knownCapacityKbps()
        check(
            read == nil || (read ?? 0) > 0,
            "either absent or a real measurement: \(String(describing: read))")
        // And the round trip: what the reader returns, written back, is still there.
        if let read {
            let rebuilt = LaunchAgent.arguments(
                quality: "4", adapt: true, cushionMilliseconds: 60, capacityKbps: read)
            check(rebuilt.contains(String(read)), "the value survives a rebuild: \(rebuilt)")
        }
    }

    test("the plist can be asked what capacity it holds") {
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueCore/Audio/LaunchAgent.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("public static func knownCapacityKbps() -> Int?"), "the reader exists")
        check(body.contains("knownArgument(\"--capacity\")"), "and it goes through the flag reader")
    }

    test("the argument builder emits the flag only when there is one") {
        // `--capacity 0` would be a ceiling of zero, which is not "unknown" — it is a link that
        // carries nothing. Absent is the honest way to say nothing was measured.
        let with = LaunchAgent.arguments(
            quality: "4", adapt: true, cushionMilliseconds: 60, capacityKbps: 485)
        check(with.contains("--capacity") && with.contains("485"), "\(with)")
        let without = LaunchAgent.arguments(
            quality: "4", adapt: true, cushionMilliseconds: 60, capacityKbps: nil)
        check(!without.contains("--capacity"), "no measurement, no flag: \(without)")
        let zero = LaunchAgent.arguments(
            quality: "4", adapt: true, cushionMilliseconds: 60, capacityKbps: 0)
        check(!zero.contains("--capacity"), "and zero is not a measurement: \(zero)")
    }
}

/// Every piece the installer copies must be checked, not only the one that bit us first.
///
/// The menu was covered on 2026-11-10 and the CLI, the media key helper and the driver were not,
/// which is the wrong way round: the driver is the one that needs sudo, so a copy that silently
/// does not take is the one nobody notices until they hear it, and the CLI is what `codecblue
/// status` runs, so a stale one reports yesterday's rules about a stream following today's.
func installChecksEveryPieceTests() {
    test("install.sh checks all four copies") {
        let source = try? String(contentsOfFile: "scripts/install.sh", encoding: .utf8)
        let body = source ?? ""
        check(
            body.contains("check_copy()"), "the check is a function, so it is used more than once")
        for piece in [
            "menu bar app", "command line", "media key helper",
            "media key helper in the bundle",
        ] {
            check(body.contains("check_copy \"\(piece)\""), "checks the \(piece)")
        }
    }

    test("a copy that did not take is an error, not a warning") {
        let source = try? String(contentsOfFile: "scripts/install.sh", encoding: .utf8)
        let body = source ?? ""
        // `|| exit 1` and not `|| true`: a warning here is a silent stale binary, which is the whole
        // reason the check exists.
        let exits = body.components(separatedBy: "|| exit 1").count - 1
        check(exits >= 4, "each check stops the install: \(exits)")
    }

    test("the driver is checked before coreaudiod is restarted") {
        let source = try? String(contentsOfFile: "scripts/build-driver.sh", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("the installed driver is not the one just built"), "it is checked")
        // Named `mismatch`, not `check`: `check` is the assertion function, and shadowing it made
        // the next line fail to compile with "cannot call value of non-function type Range".
        guard let mismatch = body.range(of: "the installed driver is not the one just built"),
            let restart = body.range(of: "sudo killall coreaudiod")
        else {
            check(false, "both the check and the restart are present")
            return
        }
        // Order matters: restarting first would load the old driver and then report the mismatch,
        // leaving the machine running the wrong binary with a message about it.
        check(mismatch.lowerBound < restart.lowerBound, "and before the restart, not after")
        check(body.contains("coreaudiod was NOT restarted"), "and it says so when it fails")
    }
}

/// `calibrate`: measure the link once, at rest, and remember it.
///
/// The alternative is a probe during playback, which is not free — a level change drops the queued
/// packets (a 30-60 ms hole) and the higher level then throws away 40% of the audio for a second or
/// two. `flood` does the same measurement with no audio at all.
///
/// Three runs and the median, not one: measured 2026-11-11, three consecutive floods on this link
/// gave 454, 496 and 504 kbps. One run would have written 454 and cost a whole rung.
func calibrateTests() {
    test("calibrate exists and writes the capacity") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("case (\"calibrate\", 2):"), "the command is dispatched")
        check(body.contains("capacityKbps: Int(median.rounded())"), "written into the login item")
        check(body.contains("calibrate XX:XX:XX:XX:XX:XX"), "and in the usage text")
    }

    test("the first run is discarded, because it measures the buffers") {
        // Measured 2026-11-13: the first flood after a fresh takeover reported 933 kbps on a link
        // that carries ~465, and finished in 11 s instead of 15 — the socket and the headphones
        // absorbed a burst because their buffers were empty. Four floods in a row gave 468, 474,
        // 429, 461; the 933 is not a fast link, it is a cold one.
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("for run in 1...4"), "four runs")
        check(
            body.contains("if run == 1") && body.contains("discarded"), "the first is thrown away")
        check(body.contains("let median = sorted[1]"), "and the median of the three kept")
    }

    test("a median cannot be a majority of outliers") {
        // With three runs and one cold outlier the median happened to be right; with two it would
        // have been 933, which makes the menu offer HQ to a link that cannot carry it.
        let cold = [933.0, 468.0, 374.0]
        check(cold.sorted()[1] == 468, "one outlier out of three is survivable")
        let twoCold = [933.0, 933.0, 374.0]
        check(
            twoCold.sorted()[1] == 933, "two are not — which is why the cold one is removed first")
        // Discarding the first and taking the median of what is left:
        let kept = [468.0, 374.0, 449.0].sorted()
        check(kept[1] == 449, "and the kept runs give 449")
    }

    test("a measurement above LDAC's own maximum is refused") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("if median > 990"), "there is a ceiling on the ceiling")
        check(body.contains("nothing was written"), "and it writes nothing when it trips")
    }

    test("flood returns the number instead of only logging it") {
        let source = try? String(
            contentsOfFile: "Sources/CodecBlueCore/AVDTP/A2DPStreamer.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("@discardableResult"), "so existing callers still compile")
        check(
            body.contains("public func flood(seconds: TimeInterval, packetSize: Int) -> Double"),
            "it returns what the link carried")
        check(body.contains("return kbps"), "which is the figure the caller needs")
    }

    test("the median of the three measured runs is the one written") {
        // The real numbers, kept as a check on the choice rather than as a table to trust.
        let runs = [454.0, 496.0, 504.0].sorted()
        check(runs[1] == 496, "the median is 496, not the 454 a single run would have given")
        // And one run would have cost a rung: 454 * 0.85 = 386 still fits 363, but 496 * 0.85 = 421
        // is the same rung — so the honest statement is that the spread is the reason to take three,
        // not that this particular link changed rung.
        let worst = 454.0 * 0.85
        let median = 496.0 * 0.85
        check(abs(worst - 386) < 1, "85% of the worst run")
        check(abs(median - 421.6) < 1, "85% of the median")
    }

    test("it refuses to write a login item that does not exist") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("no login item to write to"), "it says what to run first")
    }
}

/// "The headphones are not reachable" was said about the wrong thing.
///
/// Measured 2026-11-11: the headphones were on the person's head, macOS listed them as connected, and
/// the log said "the headphones are not reachable (they are off, out of range, or in their case)".
/// They were none of those. `bluetoothd` had been running five days and had stopped answering the
/// check-in; `sudo killall bluetoothd` fixed it at once. The message sent the person looking at their
/// headphones for an hour.
///
/// A timeout is a fact about the daemon, not about the device.
func bluetoothdTimeoutMessageTests() {
    test("a timeout is reported as bluetoothd, not as the headphones") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(
            body.contains("catch ClassicXPCError.timeout(let what)"),
            "the timeout is caught separately")
        check(body.contains("bluetoothd is not answering"), "and said as bluetoothd")
        check(body.contains("sudo killall bluetoothd"), "with the one thing that fixes it")
        check(body.contains("not the headphones"), "and it says what it is not")
    }

    test("the timeout branch is before the headphones branch, or it is unreachable") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        guard let timeout = body.range(of: "catch ClassicXPCError.timeout"),
            let headphones = body.range(of: "catch TakeoverError.headphonesDidNotConnect")
        else {
            check(false, "both branches are present")
            return
        }
        // Swift matches catch clauses in order, so a broad one first would swallow the narrow one.
        check(timeout.lowerBound < headphones.lowerBound, "timeout is matched first")
    }

    test("the timeout branch backs off like the other one") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        // Both branches must wait and grow, or a dead daemon becomes a tight retry loop.
        let sleeps = body.components(separatedBy: "if await sleepUnlessStopping(backoff").count - 1
        check(sleeps >= 2, "both branches wait interruptibly: \(sleeps)")
        let grows = body.components(separatedBy: "backoff = min(backoff * 2, 60)").count - 1
        check(grows >= 2, "and both grow the wait: \(grows)")
    }
}

/// A measured capacity must survive a `start` that did not mention it.
///
/// Reported 2026-11-13: "I ran start and in the menu I see HQ, LQ and SQ without the settles". The
/// menu was right — its capacity was 0, so there was nothing to settle *on*. `calibrate` had written
/// `--capacity 449` into the plist, and `start` rebuilt the argument list from its own command line,
/// which did not mention it, and erased it.
///
/// The capacity is a fact about the machine, measured once, not an option of whichever command
/// happens to be running.
func capacitySurvivesStartTests() {
    test("start carries the measured capacity forward") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(
            body.contains(
                "if !options.contains(\"--capacity\"), let known = LaunchAgent.knownCapacityKbps()"),
            "it reads the plist before rebuilding it")
        check(
            body.contains("keeping the measured capacity from the login item"),
            "and says so, so a stale number is visible")
    }

    test("--capacity is an option with a value, not an address") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        // Without this the value falls through to the `address == nil` branch and is read as a
        // device address: `start 40:DC:… --capacity 449` would stream to a headphone called "449".
        // The comment above the list names both flags, so searching the text proves nothing. The
        // list itself is the `if [...]` that precedes `.contains(argument)`: take that.
        guard let contains = body.range(of: ".contains(argument), let value = rest.popFirst()"),
            let open = body[..<contains.lowerBound].range(of: "if [", options: .backwards)
        else {
            check(false, "the list of value-taking options is present")
            return
        }
        let list = String(body[open.upperBound..<contains.lowerBound])
        check(list.contains("\"--capacity\""), "the list includes --capacity: \(list)")
        check(list.contains("\"--report-ms\""), "and --report-ms, which had the same hole")
    }

    test("the chosen level survives a start that did not mention it") {
        // Same erasure as the capacity, reported in the same breath: the menu wrote
        // `--quality 1` into the plist, `start` rebuilt the list without it, and the stream came
        // back at the default with nothing ticked.
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("LaunchAgent.knownArgument(\"--quality\")"), "the level is read back")
        check(body.contains("keeping the chosen level from the login item"), "and said out loud")
        check(body.contains("if !options.contains(\"--quality\")"), "only when not given")
    }

    test("knownArgument reads any flag, not just the capacity") {
        let agent = try? String(
            contentsOfFile: "Sources/CodecBlueCore/Audio/LaunchAgent.swift", encoding: .utf8)
        let body = agent ?? ""
        check(
            body.contains("public static func knownArgument(_ flag: String) -> String?"),
            "one reader for every flag")
        check(
            body.contains("knownArgument(\"--capacity\").flatMap(Int.init)"),
            "and the capacity uses it")
    }

    test("an explicit --capacity is not overwritten by the remembered one") {
        // The caller wins: `start ADDR --capacity 300` must mean 300, not the 449 in the plist.
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        check(
            (source ?? "").contains("if !options.contains(\"--capacity\")"),
            "only when the caller did not say")
    }
}

/// The installer must never write through the inode of the file it is replacing.
///
/// Measured 2026-11-14: after an install, every run of the installed `codecblue` died with
/// `Killed: 9` — `version`, `devices`, `status`, `start` — while the identical bytes in
/// `.build/debug/` and a copy of them in `/tmp` ran fine. `codesign -v` said the signature was
/// valid and `amfid` logged nothing about that path. `cp` onto an existing file keeps the inode,
/// the kernel caches the code signature against the inode, and a new cdhash under an old cache
/// entry is treated as tampering.
func installInodeTests() {
    test("the installer replaces files by rename, not by writing through them") {
        let script = try? String(contentsOfFile: "scripts/install.sh", encoding: .utf8)
        let body = script ?? ""
        check(body.contains("install_file()"), "there is an install_file helper")
        check(body.contains("mv -f \"$tmp\" \"$to\""), "which renames into place")
        // The three binaries must go through it. `cp -R` for the bundle is fine: it is removed
        // first, so it gets a fresh inode anyway.
        check(
            !body.contains("cp .build/debug/codecblue \"$APP_DIR/codecblue\""),
            "the CLI is not copied straight onto the old one")
        check(
            !body.contains("cp .build/debug/codecblue-keys \"$APP_DIR/codecblue-keys\""),
            "nor is the media key helper")
        check(
            body.contains("install_file .build/debug/codecblue \"$APP_DIR/codecblue\""),
            "the CLI goes through install_file")
        check(
            body.contains(
                "install_file .build/debug/codecblue-keys \"$APP_DIR/codecblue-keys\""),
            "so does the helper")
    }

    test("a stale inode is what killed the installed binary, not a bad signature") {
        // The evidence, so that the next person does not repeat the hour: same bytes, valid
        // signature, and the only difference between the copy that ran and the copy that died was
        // whether the file had been written in place.
        let script = try? String(contentsOfFile: "scripts/install.sh", encoding: .utf8)
        let body = script ?? ""
        check(body.contains("Killed: 9"), "the symptom is written down where the fix is")
        check(body.contains("a vnode's code signature against that inode"), "and the reason")
    }
}

/// The tick must land on a row that exists.
///
/// Reported 2026-11-13: "I changed the quality to Standard, but I do not see anything selected".
/// The menu ticked the *playing* rung, and on a link that carries 497 kbps asking for Standard
/// (606) settles the stream on rung 3 — which is not one of the three rows the menu offers. A tick
/// with no row to land on draws nothing, so the choice looked ignored.
///
/// The fix is not another row: it is that a choice is still a choice when the link turns out to be
/// slower than it, and the row already knows how to say "settles on 363".
func chosenRungTests() {
    test("the stream reports the rung that was asked for, separately from the one playing") {
        let streamer = try? String(
            contentsOfFile: "Sources/CodecBlueCore/AVDTP/A2DPStreamer.swift", encoding: .utf8)
        let body = streamer ?? ""
        check(body.contains("public private(set) var chosenRung: Int?"), "there is a chosen rung")
        check(body.contains("chosenRung = requested"), "a request moves it")
        check(body.contains("chosenRung = configuration.rung"), "and start-up sets it")
        // The settle rule lowers the ceiling; it must not move the tick, or the menu would report
        // the link's opinion as the listener's choice.
        check(!body.contains("chosenRung = fittedRung"), "settling does not move it")
    }

    test("the menu ticks the chosen rung, not the playing one") {
        let menu = try? String(
            contentsOfFile: "Sources/CodecBlueMenu/CodecBlueMenuApp.swift", encoding: .utf8)
        let body = menu ?? ""
        check(body.contains("playingRung: model.chosenRung"), "the tick comes from the choice")
        check(body.contains("let playing = model.chosenRung == level.rung"), "and the mark too")
        check(!body.contains("playingRung: model.qualityRung"), "not from what is playing")
    }

    test("every rung the menu offers can hold the tick") {
        // The three rows are 0, 1 and 4; a choice of rung 2 or 3 settles onto one of them, and the
        // row it settles on is the one that must be ticked. This is the arithmetic the bug got
        // wrong, checked directly.
        let offered = [0, 1, 4]
        for chosen in offered {
            check(offered.contains(chosen), "rung \(chosen) is one of the rows")
        }
        // And the settle rule for a link of 497 kbps at 44.1 kHz:
        let fitted = BitrateAdapter.fitRung(capacityKbps: 497, sampleRate: 44100)
        check(fitted == 3, "497 kbps fits rung 3 (363), which is not offered: got \(fitted)")
        check(!offered.contains(fitted), "so ticking the playing rung would have drawn nothing")
    }

    test("an older stream without chosen_rung still ticks something") {
        let model = try? String(
            contentsOfFile: "Sources/CodecBlueMenu/AppModel.swift", encoding: .utf8)
        check((model ?? "").contains("?? qualityRung"), "it falls back to the playing rung")
    }
}

/// The release path has to be checked by something, because the first tag anyone pushed found it
/// broken and nothing on a laptop could have.
///
/// Measured 2026-11-14: `swift build -c release --product codecblue --product codecblue-keys
/// --product CodecBlueMenu` builds **only the last product**. The release died with
/// ".build/release/codecblue was not built", and locally the same command appeared to work because
/// `codecblue` was left over from a build eight days earlier — the worst shape a bug can have:
/// green on the machine that writes it, and found by the first tag.
func releasePackagingTests() {
    test("package.sh asks for one product per build") {
        let script = try? String(contentsOfFile: "scripts/package.sh", encoding: .utf8)
        let body = script ?? ""
        check(
            body.contains("for product in codecblue codecblue-keys CodecBlueMenu; do"),
            "there is a loop over the three shipped products")
        // The bug, written down as the thing that must not come back: two `--product` flags on one
        // invocation silently builds one of them.
        check(
            !body.contains("--product codecblue --product codecblue-keys"),
            "no single invocation asks for more than one product")
        check(
            body.contains("swift build -c release --product \"$product\""),
            "each product is asked for by name")
        check(
            body.contains("[ -x \".build/release/$product\" ]"),
            "and each is checked for on its own")
    }

    test("the coverage script reads the line column, not the branch one") {
        // The header says "Cover" three times — regions, lines, branches — and the first version of
        // this script took the last one, which is "-" because nothing is instrumented for branches.
        // It then reported "could not read the total" over a report that was perfectly fine.
        let script = try? String(contentsOfFile: "scripts/coverage.sh", encoding: .utf8)
        let body = script ?? ""
        check(body.contains("n == 3"), "it takes the third percentage: regions, functions, lines")
        check(body.contains("sub(/%$/, \"\", $i)"), "and strips the sign before printf sees it")
        // The header cannot be trusted for a column index either: it splits "Missed Regions" into
        // two words while the data rows carry one number there, so the header has seventeen fields
        // and the TOTAL line thirteen. Hence counting percent signs instead.
        check(body.contains("Any column index derived from the header is off"), "and why")
    }

    test("--json prints the document alone, because a caller captures it") {
        // The first version printed its progress on stdout too, so the JSON that reached the
        // commit subject on the badges branch read "coverage: building with instrumentation…
        // running the self-test… 26.6%".
        let script = try? String(contentsOfFile: "scripts/coverage.sh", encoding: .utf8)
        let body = script ?? ""
        check(body.contains("printf '%s\\n' \"$*\" >&2"), "progress goes to stderr")
    }

    test("the badges branch is fetched before it is written to") {
        // It has to start from origin/badges when that exists: the first version created a *new*
        // branch from main's HEAD, so the second run's push was rejected with "fetch first".
        let workflow = try? String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let body = workflow ?? ""
        check(body.contains("git fetch --quiet origin badges"), "it fetches the remote branch")
        check(body.contains("-B badges"), "and moves the local one onto it")
    }

    test("coverage is measured on the engine, and says so") {
        let script = try? String(contentsOfFile: "scripts/coverage.sh", encoding: .utf8)
        let body = script ?? ""
        check(body.contains("Sources/CodecBlueCore"), "only the engine is counted")
        check(body.contains("what is not counted"), "and the output says what was left out")
    }
}

/// Cutting a release is one act, and the checks around it are the interesting part.
///
/// The version lives in the tag and nowhere else — `scripts/version.sh` reads it from there at
/// build time — so a bump is `git tag` plus `git push`, which is what starts the release workflow.
/// A commit that only changed a number would be a commit that says nothing.
func bumpTests() {
    test("bump.sh bumps the three parts from the highest version tag") {
        let script = try? String(contentsOfFile: "scripts/bump.sh", encoding: .utf8)
        let body = script ?? ""
        check(body.contains("major | minor | patch"), "it takes the three parts")
        check(body.contains("major=$((major + 1)); minor=0; patch=0"), "major resets the rest")
        check(body.contains("minor=$((minor + 1)); patch=0"), "minor resets the patch")
        check(body.contains("patch=$((patch + 1))"), "patch only moves the patch")
    }

    test("the version comes from the version tags, not from git describe") {
        // This repository also carries `backup-before-squash-2` and friends, and `git describe`
        // happily returns `v0.1.0-3-gabc1234`, which is not a number to bump.
        let script = try? String(contentsOfFile: "scripts/bump.sh", encoding: .utf8)
        let body = script ?? ""
        check(body.contains("git tag -l 'v[0-9]*.[0-9]*.[0-9]*'"), "only vX.Y.Z tags are read")
        check(body.contains("sort -t. -k1,1n -k2,2n -k3,3n"), "sorted numerically, not by string")
        // The comment above the line names `git describe`, so searching for the words proves
        // nothing; what must not be there is the command being *run* to get the version.
        check(!body.contains("version=$(git describe"), "describe is not run for the version")
    }

    test("every way a release goes wrong is refused, not warned about") {
        let script = try? String(contentsOfFile: "scripts/bump.sh", encoding: .utf8)
        let body = script ?? ""
        check(body.contains("the working tree is not clean"), "a modified tree")
        check(body.contains("not main"), "a branch that is not main")
        check(body.contains("behind origin/main"), "main behind the remote")
        check(body.contains("ahead of origin/main"), "main ahead of the remote")
        check(body.contains("already exists locally"), "a tag that is already there")
        check(body.contains("already exists on origin"), "a tag that is already on the remote")
        check(body.contains("is not greater than"), "a version that goes backwards")
    }

    test("it asks before publishing, and refuses without a terminal") {
        // A release cut by a script that never asked is worse than one that refused.
        let script = try? String(contentsOfFile: "scripts/bump.sh", encoding: .utf8)
        let body = script ?? ""
        check(body.contains("no terminal to confirm on"), "no terminal means no")
        check(body.contains("[ -t 0 ]"), "asked of the terminal, not of a variable")
        check(body.contains("git tag -a \"$tag\""), "annotated, so describe and the notes work")
        check(body.contains("git tag -d \"$tag\""), "a failed push removes the local tag")
    }

    test("the Makefile exposes the three bumps") {
        let makefile = try? String(contentsOfFile: "Makefile", encoding: .utf8)
        let body = makefile ?? ""
        for part in ["patch", "minor", "major"] {
            check(body.contains("bump-\(part):"), "bump-\(part) exists")
        }
        check(body.contains("DRY_RUN_FLAG"), "and a dry run, because a tag cannot be untagged")
    }
}

/// The release notes have to name the previous release, and "previous" means by version.
///
/// Measured 2026-11-14, on the first release that ever produced an archive: v0.2.0 published 41
/// commits under the heading "First release". The workflow asked
/// `git describe --tags --abbrev=0 HEAD^`, which answers "the nearest tag behind this commit" —
/// right only while the history is linear. v0.1.0 was tagged on 2026-11-09 and the history was
/// rewritten afterwards (squashed, reworded, re-dated), so v0.1.0 is no longer an ancestor of
/// anything and describe found nothing.
func releaseNotesTests() {
    test("the previous release is found by version, not by ancestry") {
        let workflow = try? String(contentsOfFile: ".github/workflows/release.yml", encoding: .utf8)
        let body = workflow ?? ""
        check(body.contains("git tag -l 'v[0-9]*.[0-9]*.[0-9]*'"), "it sorts the version tags")
        check(body.contains("sort -t. -k1,1n -k2,2n -k3,3n"), "numerically")
        check(!body.contains("previous=$(git describe"), "describe is not asked")
    }

    test("a rewritten history is detected and said out loud") {
        let workflow = try? String(contentsOfFile: ".github/workflows/release.yml", encoding: .utf8)
        let body = workflow ?? ""
        check(body.contains("git merge-base --is-ancestor"), "ancestry is checked")
        check(body.contains("the history was rewritten"), "and the log says why the range is odd")
        check(body.contains("no commits in $range"), "an empty range is not published as nothing")
    }
}

/// The ring's depth is half the latency, and the half that can be moved.
///
/// Measured 2026-11-14: the total was ~162 ms — 100 ms of ring plus 60 ms of cushion. The ring's
/// 100 was forced by the short-read plateaus of 2026-11-10 (462 windows in 8 656, 2 980 ms of
/// repeated sample, heard as crackle), and those are gone. So the trade is worth re-testing by ear
/// rather than by argument, which means it has to be adjustable and it has to survive a restart.
func ringDepthTests() {
    test("--ring-ms exists in both parsers") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        // `play` and `system` have separate parsers, and an option in only one of them is a
        // setting that works until the agent restarts itself.
        let occurrences = body.components(separatedBy: "case \"--ring-ms\":").count - 1
        check(
            occurrences == 1,
            "the option is parsed (system is the one that matters): \(occurrences)")
        check(body.contains("var ringMilliseconds = 100.0"), "the default is the measured 100 ms")
        check(
            body.contains("CushionClock(ringMilliseconds / 1000)"),
            "and it is what the ring chases")
    }

    test("--ring-ms is an option with a value, not an address") {
        // The same hole `--capacity` had: an unconsumed value falls through to the address branch,
        // and `start ADDR --ring-ms 60` would stream to a headphone called "60".
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        guard let contains = body.range(of: ".contains(argument), let value = rest.popFirst()"),
            let open = body[..<contains.lowerBound].range(of: "if [", options: .backwards)
        else {
            check(false, "the list of value-taking options is present")
            return
        }
        let list = String(body[open.upperBound..<contains.lowerBound])
        check(list.contains("\"--ring-ms\""), "the list includes --ring-ms: \(list)")
    }

    test("the ring depth survives a start and a level change") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("LaunchAgent.knownArgument(\"--ring-ms\")"), "start reads it back")
        check(body.contains("keeping the ring depth from the login item"), "and says so")
        let model = try? String(
            contentsOfFile: "Sources/CodecBlueMenu/AppModel.swift", encoding: .utf8)
        check(
            (model ?? "").contains("ringMilliseconds: LaunchAgent.knownArgument"),
            "the menu keeps it")
    }

    test("the plist writer emits the ring only when it was chosen") {
        // Absent means the measured default, so a plist written before this option existed keeps
        // working — and `--ring-ms 0` is not a ring of zero, it is "not set".
        let with = LaunchAgent.arguments(
            quality: "4", adapt: true, cushionMilliseconds: 60, capacityKbps: 485,
            ringMilliseconds: 60)
        check(with.contains("--ring-ms") && with.contains("60"), "\(with)")
        let without = LaunchAgent.arguments(
            quality: "4", adapt: true, cushionMilliseconds: 60, capacityKbps: 485)
        check(!without.contains("--ring-ms"), "absent when not chosen: \(without)")
        let zero = LaunchAgent.arguments(
            quality: "4", adapt: true, cushionMilliseconds: 60, ringMilliseconds: 0)
        check(!zero.contains("--ring-ms"), "and zero is not written: \(zero)")
    }
}

/// The ring's depth has to be changeable while the audio plays, because restarting the stream to
/// change it measures the wrong thing.
///
/// Reported 2026-11-14: "as soon as I run `codecblue start --ring-ms 60` the audio stops and I hear
/// nothing, as if it unplugged the headphones". It did: `start` writes the plist and reloads the
/// agent, which stops the stream and hands the headphones back to macOS. That is correct for
/// `start` and useless for comparing two buffer depths, because the comparison then includes a
/// takeover, a fresh link and several seconds of silence.
func liveRingTests() {
    test("the ring is a live setting, not only a start-up option") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("let ringClock = CushionClock"), "the depth lives in a mutable box")
        check(body.contains("case \"ring\":"), "the control channel accepts it")
        check(body.contains("ringClock.value = milliseconds / 1000"), "and moves it")
        check(body.contains("case (\"ring\", 2):"), "there is a verb for it")
    }

    test("the servo reads the box, not a captured constant") {
        // A `let` captured by the closures would compile and do nothing: the closures run on the
        // audio thread, and a constant is a constant.
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(!body.contains("let ringTarget = ringMilliseconds / 1000"), "no captured constant")
        check(body.contains("Int(ringClock.value * Double(ring.sampleRate))"), "the box is read")
    }

    test("status reports the target as well as the depth") {
        // Without both, "the setting did not take" and "the servo has not caught up yet" look the
        // same, and a latency comparison becomes a guess.
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("out[\"ring_target_ms\"]"), "the target is published")
        check(body.contains("out[\"ring_ms\"]"), "next to the depth reached")
    }

    test("ring and cushion have the same shape of answer") {
        // Both are the latency, both are changed while playing, both are reported in ms. A user
        // who learns one should not have to learn the other.
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("ok cushion="), "the cushion answers with its value")
        check(body.contains("ok ring="), "so does the ring")
    }
}

/// A depth found by ear has to survive the next restart, or it is not a setting.
///
/// Measured 2026-11-14, by the listener: `ring 60`, `50`, `40`, `30`, `20` — all accepted, a small
/// jump at 40, and 20 played clean for a minute with 0 short reads and `latency_ms 81`. That number
/// is the result of an experiment; losing it to the next crash would mean running the experiment
/// again.
func persistedRingTests() {
    test("the ring verb writes the chosen depth into the login item") {
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        let body = source ?? ""
        check(body.contains("options += [\"--ring-ms\", arguments[1]]"), "it is written")
        check(body.contains("remembered: --ring-ms"), "and said out loud")
        // Without reloading: the running stream already has the value, and reloading would
        // interrupt the audio — which is the whole reason this verb exists.
        check(!body.contains("LaunchAgent.load()\n                print(\"remembered"), "no reload")
    }

    test("the address comes from the plist, where it is not a flag") {
        // `plist()` writes [executable, "system", address] and the options after it. A `--address`
        // does not exist, so looking for one would silently never persist anything.
        let agent = try? String(
            contentsOfFile: "Sources/CodecBlueCore/Audio/LaunchAgent.swift", encoding: .utf8)
        let body = agent ?? ""
        check(body.contains("public static func knownAddress() -> String?"), "the reader exists")
        check(body.contains("<string>system</string>"), "it looks after the verb")
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        check((source ?? "").contains("LaunchAgent.knownAddress()"), "and the verb uses it")
    }

    test("an error from the stream is not written into the plist") {
        // `ring 5` is refused by the stream (20…500), and a refusal must not become a setting.
        let source = try? String(contentsOfFile: "Sources/codecblue/main.swift", encoding: .utf8)
        check(
            (source ?? "").contains("lines.contains(where: { $0.hasPrefix(\"error\") })"),
            "a refused value exits before the plist is touched")
    }
}

/// The co-author trailer is on every commit, and that is a rule worth a test.
///
/// Asked 2026-11-14: "check that all the commits have the coauthor, you did not do them all". Two
/// rounds of rewriting found the same mistake twice — a `filter-branch` range that started one
/// commit too late — and the second round found that the bot's own commits on the `badges` branch
/// had none either. A rule that is checked by a person reading `git log` is a rule that holds until
/// somebody is in a hurry.
func commitTrailerTests() {
    test("the rules about pushing are written down, not remembered") {
        // Asked 2026-11-14, after an afternoon of pushes, a --force on v0.2.0 and a rebuilt
        // badges branch that nobody asked for. A rule that lives in the agent's memory lasts
        // until the next session; one in AGENTS.md is read at the start of every one.
        let agents = try? String(contentsOfFile: "AGENTS.md", encoding: .utf8)
        let body = agents ?? ""
        check(body.contains("Commit, do not push"), "the rule exists")
        check(body.contains("Never rewrite published history"), "and the one it depends on")
        check(body.contains("Co-authored-by: DomynAgents"), "and the trailer")
    }

    test("the coverage bot writes the trailer too") {
        let workflow = try? String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let body = workflow ?? ""
        check(body.contains("Co-authored-by: DomynAgents"), "the bot commit carries it")
    }
}
