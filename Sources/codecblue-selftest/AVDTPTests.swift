import Foundation

@testable import CodecBlueCore

func avdtpTests() {
    test("encodes a single-packet command") {
        let message = AVDTP.Message(
            label: 3, type: .command, signal: .getCapabilities, payload: Data([0x04]))
        check(message.bytes == Data([0x30, 0x02, 0x04]))
    }

    test("parses a DISCOVER reply") {
        let endpoints = AVDTP.parseDiscover(Data([0x04, 0x08, 0x8E, 0x08]))
        check(
            endpoints == [
                AVDTP.Endpoint(seid: 1, inUse: false, mediaType: 0, isSink: true),
                AVDTP.Endpoint(seid: 35, inUse: true, mediaType: 0, isSink: true),
            ], "\(endpoints)")
    }

    test("recognises an LDAC capability") {
        let caps = Data([
            0x01, 0x00, 0x07, 0x0A, 0x00, 0xFF, 0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00, 0x34, 0x01,
        ])
        let parsed = AVDTP.parseCapabilities(caps)
        check(parsed.categories == [1, 7])
        check(parsed.codec?.name == "LDAC", parsed.codec?.name ?? "nil")
        check(parsed.codec?.information.suffix(2) == Data([0x34, 0x01]))
    }

    test("recognises SBC and AAC") {
        check(
            AVDTP.parseCapabilities(Data([0x07, 0x06, 0x00, 0x00, 0xFF, 0xFF, 0x02, 0x35])).codec?
                .name == "SBC")
        check(
            AVDTP.parseCapabilities(
                Data([0x07, 0x08, 0x00, 0x02, 0x80, 0x01, 0x8C, 0x83, 0x82, 0x70])
            ).codec?.name == "AAC")
    }

    test("framer splits fixed-size messages that arrive in one read") {
        var framer = AVDTPFramer()
        let messages = framer.feed(Data([0x12, 0x06, 0x20, 0x07, 0x04]))
        check(messages.count == 2, "\(messages)")
        guard messages.count == 2 else { return }
        check(
            messages[0].signal == .open && messages[0].type == .accept
                && messages[0].payload.isEmpty)
        check(
            messages[1].signal == .start && messages[1].type == .command
                && messages[1].payload == Data([0x04]))
    }

    test("framer reassembles fragmented messages") {
        var framer = AVDTPFramer()
        check(framer.feed(Data([0x56, 0x02, 0x02, 0x01, 0x00])).isEmpty)
        let messages = framer.feed(Data([0x5E, 0x07, 0x02, 0x00, 0x00]))
        check(messages.count == 1)
        guard let m = messages.first else { return }
        check(m.label == 5 && m.signal == .getCapabilities)
        check(m.payload == Data([0x01, 0x00, 0x07, 0x02, 0x00, 0x00]), "\(m.payload as NSData)")
    }

    test("libldac links") {
        check(LDAC.libraryVersion == "2.0.2", LDAC.libraryVersion)
    }
}

func ldacTests() {
    test("LDAC configuration bytes") {
        check(
            LDAC.configuration(rate: 48000)
                == Data([0x2D, 0x01, 0x00, 0x00, 0xAA, 0x00, 0x10, 0x01]))
        check(LDAC.rates(fromBits: 0x34) == [44100, 48000, 96000])
    }

    test("LDAC encoder produces HQ packets that fit the MTU") {
        let tone = WAVFile.sine(sampleRate: 48000, seconds: 1)
        let encoder = try LDACEncoder(sampleRate: 48000, quality: .high, mtu: 895)
        var bytes = 0
        var packets = 0
        var frames = 0
        var block = [Float](repeating: 0, count: 256)
        var i = 0
        while i + 256 <= tone.samples.count {
            for j in 0..<256 { block[j] = tone.samples[i + j] }
            i += 256
            if let out = try block.withUnsafeBufferPointer({ try encoder.encode($0) }) {
                check(out.payload.count + 13 <= 895, "packet \(out.payload.count + 13) > MTU")
                bytes += out.payload.count
                packets += 1
                frames += out.frameCount
            }
        }
        let kbps = Double(bytes) * 8 / 1000
        check(packets > 50, "\(packets) packets")
        check(kbps > 900 && kbps < 1010, "\(kbps) kbps")
        check(frames * 128 <= 48000 && frames * 128 > 47000, "\(frames) frames")
    }
}

func socketTests() {
    test("a socket can reply from its own read callback (no deadlock)") {
        var fds: [Int32] = [0, 0]
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let socket = ChannelSocket(
            channel: OpenedChannel(fd: fds[0], cid: 0, outMTU: 672), label: "test")
        socket.onData = { data in socket.send(Data([0xAA]) + data) }  // echo from the callback
        socket.start()
        _ = Darwin.write(fds[1], [UInt8(1), 2, 3], 3)
        var reply = [UInt8](repeating: 0, count: 8)
        var got = 0
        let deadline = Date().addingTimeInterval(2)
        _ = fcntl(fds[1], F_SETFL, O_NONBLOCK)
        while got < 4 && Date() < deadline {
            let n = reply.withUnsafeMutableBytes {
                Darwin.read(fds[1], $0.baseAddress! + got, 8 - got)
            }
            if n > 0 { got += n } else { usleep(1000) }
        }
        check(Array(reply[0..<got]) == [0xAA, 1, 2, 3], "\(reply[0..<got])")
        socket.close()
        Darwin.close(fds[1])
    }
}
