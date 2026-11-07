import Foundation

/// One A2DP media packet: RTP header, then the codec's own media header, then the payload.
///
/// For LDAC the media header is **one byte**: the number of LDAC frames in the packet, in bits
/// 3..0 (bits 7..4 are reserved: 0). The payload is then the concatenation of that many LDAC
/// transport frames, each starting with its own header byte, whose top 8 bits are the sync word
/// 0xAA (libldac `pack_pack_frame_header_ldac`: 8 sync + 3 sampling rate + 2 channel config +
/// 9 frame length + 2 frame status).
///
/// The prototype that streamed LDAC to the FreeBuds 5 (2026-11-05) wrote the frame count alone,
/// which is what this does; the sync word in the payload is what a capture should confirm.
enum MediaPacket {
    static let rtpHeaderSize = 12
    static let payloadType: UInt8 = 96

    static func rtp(sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data) -> Data {
        var packet = Data(capacity: rtpHeaderSize + payload.count)
        packet.append(contentsOf: [0x80, payloadType])  // RTP v2, no padding/extension/CSRC
        packet.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xFF)])
        packet.append(contentsOf: [UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xFF),
                                   UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF)])
        packet.append(contentsOf: [UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xFF),
                                   UInt8((ssrc >> 8) & 0xFF), UInt8(ssrc & 0xFF)])
        packet.append(payload)
        return packet
    }

    /// The 1-byte LDAC media header.
    static func ldacHeader(frameCount: Int) -> UInt8 {
        UInt8(frameCount & 0x0F)
    }
}
