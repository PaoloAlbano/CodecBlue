import Foundation

/// AVDTP signaling (Bluetooth A2DP transport), as far as the probe and streaming need it.
public enum AVDTP {
    public static let psm: UInt16 = 0x19

    public enum Signal: UInt8, Sendable {
        case discover = 0x01
        case getCapabilities = 0x02
        case setConfiguration = 0x03
        case getConfiguration = 0x04
        case reconfigure = 0x05
        case open = 0x06
        case start = 0x07
        case close = 0x08
        case suspend = 0x09
        case abort = 0x0A
        case securityControl = 0x0B
        case getAllCapabilities = 0x0C
        case delayReport = 0x0D
    }

    // One case per line, deliberately: these are wire values, and the whole value of writing them
    // out is that the number next to each name is visible. The formatter's `OneCasePerLine` rule
    // wants that too, and the reason it is worth obeying rather than disabling is that a protocol
    // table is the one place where a missing case is a bug nobody notices.
    public enum MessageType: UInt8, Sendable {
        case command = 0
        case generalReject = 1
        case accept = 2
        case reject = 3
    }

    enum PacketType: UInt8 {
        case single = 0
        case start = 1
        case `continue` = 2
        case end = 3
    }

    public struct Message: Sendable, Equatable {
        public var label: UInt8
        public var type: MessageType
        public var signalID: UInt8
        public var payload: Data

        public var signal: Signal? { Signal(rawValue: signalID) }

        public init(label: UInt8, type: MessageType, signal: Signal, payload: Data = Data()) {
            self.label = label & 0x0F
            self.type = type
            signalID = signal.rawValue
            self.payload = payload
        }

        init(label: UInt8, type: MessageType, signalID: UInt8, payload: Data) {
            self.label = label
            self.type = type
            self.signalID = signalID
            self.payload = payload
        }

        /// Encoded as a single packet (signaling messages we send fit in one MTU).
        public var bytes: Data {
            Data([label << 4 | PacketType.single.rawValue << 2 | type.rawValue, signalID & 0x3F])
                + payload
        }
    }

    // MARK: - Stream endpoints and capabilities

    public struct Endpoint: Sendable, Equatable {
        public let seid: UInt8
        public let inUse: Bool
        public let mediaType: UInt8  // 0 audio
        public let isSink: Bool
    }

    public static func parseDiscover(_ payload: Data) -> [Endpoint] {
        let bytes = [UInt8](payload)
        return stride(from: 0, to: bytes.count - 1, by: 2).map { i in
            Endpoint(
                seid: bytes[i] >> 2,
                inUse: bytes[i] & 0x02 != 0,
                mediaType: bytes[i + 1] >> 4,
                isSink: bytes[i + 1] & 0x08 != 0
            )
        }
    }

    /// A media codec capability (service category 7).
    public struct Codec: Sendable, Equatable, CustomStringConvertible {
        public let mediaCodecType: UInt8  // 0 SBC, 2 AAC, 0xFF vendor specific
        public let information: Data  // codec-specific bytes after the codec type

        public var vendor: (id: UInt32, codec: UInt16)? {
            guard mediaCodecType == 0xFF, information.count >= 6 else { return nil }
            let b = [UInt8](information)
            return (
                UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24,
                UInt16(b[4]) | UInt16(b[5]) << 8
            )
        }

        public var name: String {
            switch mediaCodecType {
            case 0x00: return "SBC"
            case 0x01: return "MPEG-1,2 Audio"
            case 0x02: return "AAC"
            case 0x04: return "ATRAC"
            case 0xFF:
                guard let vendor else { return "vendor (malformed)" }
                switch (vendor.id, vendor.codec) {
                case (0x0000_012D, 0x00AA): return "LDAC"
                case (0x0000_004F, 0x0001): return "aptX"
                case (0x0000_00D7, 0x0024): return "aptX HD"
                case (0x0000_000A, 0x0002): return "aptX LL"
                case (0x0000_00D7, 0x00AD): return "aptX Adaptive"
                case (0x0000_027D, _): return String(format: "Huawei 0x%04X (L2HC?)", vendor.codec)
                default:
                    return String(format: "vendor 0x%08X codec 0x%04X", vendor.id, vendor.codec)
                }
            default: return String(format: "codec type 0x%02X", mediaCodecType)
            }
        }

        public var description: String {
            "\(name) [\(information.map { String(format: "%02x", $0) }.joined(separator: " "))]"
        }
    }

    public static let mediaCodecCategory: UInt8 = 0x07

    /// Service capabilities as (category, bytes); the media codec one decoded.
    public static func parseCapabilities(_ payload: Data) -> (categories: [UInt8], codec: Codec?) {
        let b = [UInt8](payload)
        var i = 0
        var categories: [UInt8] = []
        var codec: Codec?
        while i + 1 < b.count {
            let category = b[i]
            let length = Int(b[i + 1])
            let end = min(i + 2 + length, b.count)
            categories.append(category)
            if category == mediaCodecCategory, end - (i + 2) >= 2 {
                codec = Codec(mediaCodecType: b[i + 3], information: Data(b[(i + 4)..<end]))
            }
            i = end
        }
        return (categories, codec)
    }
}

/// Reassembles AVDTP signaling messages from a SOCK_STREAM channel.
///
/// AVDTP has no length field: on a real L2CAP channel a message is one SDU. bluetoothd's
/// stream socket hands SDUs over as they arrive, so normally one read is one message. This
/// framer handles the two cases where that breaks:
/// * fragmented messages (start/continue/end packets carry the number of packets), and
/// * several messages in one read, which are split where the next header is expected, using
///   the known payload sizes of fixed-size messages.
public struct AVDTPFramer: Sendable {
    private var fragments:
        (label: UInt8, type: AVDTP.MessageType, signal: UInt8, remaining: Int, data: Data)?

    public init() {}

    public mutating func feed(_ chunk: Data) -> [AVDTP.Message] {
        var messages: [AVDTP.Message] = []
        var rest = [UInt8](chunk)
        while !rest.isEmpty {
            let header = rest[0]
            let label = header >> 4
            let packetType = AVDTP.PacketType(rawValue: (header >> 2) & 0x03)!
            let type = AVDTP.MessageType(rawValue: header & 0x03)!
            switch packetType {
            case .single:
                guard rest.count >= 2 else { return messages }
                let signal = rest[1] & 0x3F
                let length = Self.fixedPayloadLength(signal: signal, type: type) ?? (rest.count - 2)
                let end = min(2 + length, rest.count)
                messages.append(
                    AVDTP.Message(
                        label: label, type: type, signalID: signal,
                        payload: Data(rest[2..<end])))
                rest.removeFirst(end)
            case .start:
                guard rest.count >= 3 else { return messages }
                fragments = (label, type, rest[2], Int(rest[1]) - 1, Data(rest[3...]))
                rest.removeAll()
            case .continue, .end:
                guard var f = fragments else {
                    rest.removeAll()
                    break
                }
                f.data.append(contentsOf: rest[1...])
                f.remaining -= 1
                rest.removeAll()
                if packetType == .end || f.remaining <= 0 {
                    messages.append(
                        AVDTP.Message(
                            label: f.label, type: f.type, signalID: f.signal, payload: f.data))
                    fragments = nil
                } else {
                    fragments = f
                }
            }
        }
        return messages
    }

    /// Payload sizes fixed by the AVDTP specification, so a following message in the same
    /// read can be split off. nil = variable (runs to the end of the read).
    static func fixedPayloadLength(signal: UInt8, type: AVDTP.MessageType) -> Int? {
        guard let s = AVDTP.Signal(rawValue: signal) else { return nil }
        switch (s, type) {
        case (.discover, .command): return 0
        case (.getCapabilities, .command), (.getAllCapabilities, .command),
            (.getConfiguration, .command),
            (.open, .command), (.close, .command), (.abort, .command):
            return 1
        case (.setConfiguration, .accept), (.reconfigure, .accept), (.open, .accept),
            (.start, .accept),
            (.close, .accept), (.suspend, .accept), (.abort, .accept), (.delayReport, .accept):
            return 0
        case (.delayReport, .command): return 3
        case (.open, .reject), (.close, .reject), (.getCapabilities, .reject),
            (.getAllCapabilities, .reject),
            (.discover, .reject), (.getConfiguration, .reject):
            return 1
        case (.start, .reject), (.suspend, .reject), (.setConfiguration, .reject),
            (.reconfigure, .reject):
            return 2
        default: return nil
        }
    }
}
