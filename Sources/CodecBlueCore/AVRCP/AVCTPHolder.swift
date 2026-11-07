import Foundation

/// Holds the headphones' AVRCP control channel (AVCTP, PSM 0x17).
///
/// While we hold it, macOS cannot connect AVRCP, and so it does not start reconnecting the
/// headphones' other profiles (observed by Blue Bloom). For now every command is answered
/// NOT IMPLEMENTED except key presses, which are reported and accepted; volume and
/// metadata come with the AVRCP phase.
public final class AVCTPHolder: @unchecked Sendable {
    public static let psm: UInt16 = 0x17
    static let avrcpProfileID: UInt16 = 0x110E

    public let socket: ChannelSocket
    /// Key name ("play", "pause", "next", ...) on press.
    public var onKey: (@Sendable (String) -> Void)?
    /// The volume the headphones asked for, 0…1, when they send SET ABSOLUTE VOLUME.
    public var onAbsoluteVolume: (@Sendable (Float) -> Void)?
    /// Round-trip time of the last GET CAPABILITIES we asked for, in seconds. A link in sniff
    /// mode answers in tens of milliseconds; an active one in a few. This is the cheapest way
    /// to tell whether the controller put the link to sleep under us.
    public private(set) var roundTrip: TimeInterval?
    private var sentAt: [UInt8: UInt64] = [:]
    private let lock = NSLock()
    private var nextLabel: UInt8 = 0

    public init(socket: ChannelSocket) {
        self.socket = socket
        socket.onData = { [weak self] data in self?.receive(data) }
        socket.start()
    }

    public func close() { socket.close() }

    /// Asks the headphones what they support; the answer times the round trip.
    public func measureRoundTrip() {
        let label: UInt8 = lock.withLock {
            nextLabel = (nextLabel &+ 1) & 0x0F
            return nextLabel
        }
        // AVCTP: single packet, command, label. AV/C: GET CAPABILITIES, company ID 0 (all).
        let frame: [UInt8] = [0x00, 0x11, 0x0E, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00]
        var packet = frame
        packet[0] = (label << 4) & 0xF0
        lock.withLock { sentAt[label] = DispatchTime.now().uptimeNanoseconds }
        socket.send(Data(packet))
    }

    /// What a command means, decided by a pure function so it can be tested without a socket.
    ///
    /// It is pure because the alternative was a rule that lived only inside `receive`, where the
    /// self-test could not see it: `SET ABSOLUTE VOLUME` was answered NOT IMPLEMENTED for weeks
    /// and the headphones' volume keys did nothing, which is not a thing any test would have
    /// caught while the parsing was unreachable.
    public enum Command: Equatable, Sendable {
        case key(String)
        case absoluteVolume(Float)
        case unsupported
    }

    public static func interpret(_ b: [UInt8]) -> Command {
        // AVCTP: header, profile ID (big endian), then the AV/C frame: 00 00 00 opcode operands.
        guard b.count >= 7 else { return .unsupported }
        switch b[5] {
        case 0x7C:  // PASS THROUGH
            // The high bit of the operand is the press/release flag: a release must not fire the
            // key twice, and headphones send both.
            guard b[6] & 0x80 == 0 else { return .unsupported }
            let names: [UInt8: String] = [0x44: "play", 0x46: "pause", 0x45: "stop", 0x4B: "next",
                                          0x4C: "previous", 0x41: "volume_up", 0x42: "volume_down"]
            guard let name = names[b[6] & 0x7F] else { return .unsupported }
            return .key(name)
        case 0x50:
            // SET ABSOLUTE VOLUME: 0…127, top bit reserved.
            return .absoluteVolume(Float(b[6] & 0x7F) / 127)
        default:
            return .unsupported
        }
    }

    private func receive(_ data: Data) {
        let b = [UInt8](data)
        // AVCTP single packet: header, profile ID (big endian), AV/C frame.
        guard b.count >= 6 else { return }
        let header = b[0]
        let isCommand = header & 0x02 == 0
        if !isCommand {
            let label = header >> 4
            let start = lock.withLock { sentAt.removeValue(forKey: label) }
            if let start {
                roundTrip = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
            }
            return
        }
        let packetType = (header >> 2) & 0x03
        guard isCommand, packetType == 0 else { return }
        let pid = UInt16(b[1]) << 8 | UInt16(b[2])
        var response = b
        response[0] = header | 0x02  // response, same transaction label
        if pid != Self.avrcpProfileID {
            response[0] |= 0x01  // IPID: invalid profile
            socket.send(Data(response[0..<3]))
            return
        }
        switch Self.interpret(b) {
        case .key(let name):
            onKey?(name)
            response[3] = 0x09  // ACCEPTED
        case .absoluteVolume(let value):
            onAbsoluteVolume?(value)
            response[3] = 0x09  // ACCEPTED
        case .unsupported:
            response[3] = 0x08  // NOT IMPLEMENTED
        }
        socket.send(Data(response))
    }
}
