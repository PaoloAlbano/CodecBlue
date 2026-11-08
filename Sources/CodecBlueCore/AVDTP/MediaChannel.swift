import Foundation

/// The AVDTP media (transport) channel: one RTP packet per write.
///
/// bluetoothd turns each read of our stream socket into one L2CAP SDU. If two packets were in
/// the socket buffer at once they could be read, and sent, as one. So the send buffer and its
/// low-water mark are set to exactly one MTU: the socket reports writable only when a whole
/// packet fits and the previous one has been taken (technique from Blue Bloom, MIT).
///
/// The media channel is opened with a *small* MTU on purpose (the headphones' own A2DP MTU,
/// 679, not the link's 895): bluetoothd passes each packet on as one L2CAP PDU, and a PDU of
/// 895 bytes needs 3-DH5 on the air. With 679 bluetoothd can use 2-DH5 as well, which is the
/// packet type the A2DP profile was designed around.
public final class MediaChannel: @unchecked Sendable {
    public let mtu: Int
    private var fd: Int32

    /// - Parameters:
    ///   - mtu: largest packet to write (default: the link's MTU).
    ///   - sendBufferPackets: how many packets may wait in the socket at once. 1 keeps the
    ///     one-packet-per-write discipline above; more lets several packets be in flight, at
    ///     the risk that bluetoothd reads two of them as one SDU (see `--sndbuf-packets`).
    public init(channel: OpenedChannel, mtu: Int? = nil, sendBufferPackets: Int = 1) {
        fd = channel.fd
        self.mtu = min(mtu ?? Int(channel.outMTU), Int(channel.outMTU))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var size = Int32(self.mtu)
        setsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &size, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Int32(self.mtu * max(1, sendBufferPackets))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
    }

    /// `SOCK_STREAM`, `SOCK_SEQPACKET` or something else: bluetoothd hands out different kinds
    /// of socket for different channels, and the kind decides whether one write is one SDU.
    public var socketType: Int32 {
        var type: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size)
        return type
    }

    public var socketTypeName: String {
        switch socketType {
        case SOCK_STREAM: return "SOCK_STREAM"
        case SOCK_DGRAM: return "SOCK_DGRAM"
        case SOCK_SEQPACKET: return "SOCK_SEQPACKET"
        default: return "type \(socketType)"
        }
    }

    /// What the socket actually got: the kernel adjusts `SO_SNDBUF` and may ignore
    /// `SO_SNDLOWAT`, and that decides how many packets can wait at once.
    public var socketBuffers: (send: Int, lowWater: Int) {
        var send: Int32 = 0
        var low: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send, &size)
        size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &low, &size)
        return (Int(send), Int(low))
    }

    deinit { close() }

    public enum SendResult { case sent, full, closed }

    /// Writes one packet if the socket can take all of it now.
    public func send(_ packet: Data) -> SendResult {
        guard fd >= 0 else { return .closed }
        var offset = 0
        while offset < packet.count {
            let n = packet.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress! + offset, packet.count - offset, 0)
            }
            if n > 0 {
                offset += n
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                if offset == 0 { return .full }
                // A partial write (should not happen with the low-water mark): finish this
                // packet before anything else, so packets never interleave.
                usleep(200)
            } else {
                close()
                return .closed
            }
        }
        return .sent
    }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}
