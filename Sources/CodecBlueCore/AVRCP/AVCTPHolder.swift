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
    /// Called for every button. Returns true when the press was acted on: the reply to the
    /// headphones depends on it, so a button that is not handled is refused rather than accepted.
    public var onKey: (@Sendable (String) -> Bool)?
    /// The volume the headphones asked for, 0…1, when they send SET ABSOLUTE VOLUME.
    public var onAbsoluteVolume: (@Sendable (Float) -> Void)?
    /// Every AVRCP frame that arrives, before parsing. Diagnostic, and the only way to see what
    /// the headphones actually send when a button seems to do nothing.
    public var onRaw: (@Sendable ([UInt8]) -> Void)?
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

    /// Tells the headphones what volume to play at, 0…127.
    ///
    /// This is the missing half of the volume keys. Measured 2026-11-06: the headphones never
    /// send PASS THROUGH or SET ABSOLUTE VOLUME when their keys are pressed — they move their own
    /// DSP and say nothing. What they *do* send is a steady stream of GET CAPABILITIES (the
    /// `10 11 0E 01 48 00 00 19 58 10 00 00 01 03` frames), which is the AVRCP 1.3 "absolute
    /// volume" handshake: the device asks whether the controller can set its volume.
    ///
    /// So the direction is the opposite of what I assumed: the volume is ours to *push*, not
    /// theirs to report. `SET ABSOLUTE VOLUME` (opcode 0x50) with the value in the operand is
    /// what makes the headphones' own attenuation follow the Mac's slider.
    public func setAbsoluteVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        let operand = UInt8((clamped * 127).rounded())
        let label: UInt8 = lock.withLock {
            nextLabel = (nextLabel &+ 1) & 0x0F
            return nextLabel
        }
        // AVRCP 1.4 carries absolute volume as a *vendor dependent* PDU (0x50 inside the
        // company block), not as a bare AV/C opcode. These headphones speak vendor dependent for
        // everything else they send, and the bare form was answered REJECTED — measured
        // 2026-11-06, `FF 20 11 0E 00 48 50 26` came back as ctype 0x0A.
        // SET ABSOLUTE VOLUME is PDU 0x50 followed by exactly one operand byte. There was an
        // extra 0x00 in between — a reserved byte that this PDU does not have — and the
        // headphones answered REJECTED to every attempt, which is why the slider and the
        // headphones stayed independent.
        // Every vendor dependent PDU carries a two-byte parameter length after a reserved byte.
        // Without it the headphones read the volume as the length and answered REJECTED — the
        // frame was `50 26`, and the correct one is `50 00 00 01 26`.
        var packet: [UInt8] = [
            0x00, 0x11, 0x0E, 0x00, 0x48, 0x00, 0x00, 0x19, 0x58,
            0x50, 0x00, 0x00, 0x01, operand,
        ]
        packet[0] = (label << 4) & 0xF0
        onRaw?([0xFF] + packet)  // 0xFF marks an outgoing frame in the log
        socket.send(Data(packet))
    }

    /// Asks the headphones to tell us when their own volume changes.
    ///
    /// This is the other half of the puzzle. The headphones' volume keys move their own DSP and
    /// send no PASS THROUGH, so the only way to learn that a key was pressed is to subscribe:
    /// AVRCP 1.4 REGISTER NOTIFICATION, event 0x0D (VOLUME CHANGED). The headphone then answers
    /// with the new value, and again after every change, because a notification has to be
    /// re-registered each time.
    public func registerVolumeNotifications() {
        lock.withLock { volumeRegistered = true }
        sendNotificationRegistration(event: 0x0D)
    }

    /// True while a volume registration is outstanding.
    private var volumeRegistered = false

    private func sendNotificationRegistration(event: UInt8) {
        let label: UInt8 = lock.withLock {
            nextLabel = (nextLabel &+ 1) & 0x0F
            return nextLabel
        }
        // AVCTP: single packet, command, label. AV/C: VENDOR DEPENDENT (0x00), BT SIG company
        // (0x001958), PDU 0x31 REGISTER NOTIFICATION, reserved, event, playback interval 0.
        // REGISTER NOTIFICATION: PDU 0x31, reserved, two-byte parameter length (event + interval
        // = 5), then the event id and a four-byte playback interval. The first version omitted
        // the length field, so the headphones read the event id as a length and never answered.
        var packet: [UInt8] = [
            0x00, 0x11, 0x0E, 0x00, 0x48, 0x00, 0x00, 0x19, 0x58,
            0x31, 0x00, 0x00, 0x05, event, 0x00, 0x00, 0x00, 0x00,
        ]
        packet[0] = (label << 4) & 0xF0
        onRaw?([0xFF] + packet)
        socket.send(Data(packet))
    }

    /// Asks the headphones what they support; the answer times the round trip.
    public func measureRoundTrip() {
        let label: UInt8 = lock.withLock {
            nextLabel = (nextLabel &+ 1) & 0x0F
            return nextLabel
        }
        // AVCTP: header, profile ID. AV/C: ctype, subunit, opcode, operands.
        //
        // The frame used to be `00 11 0E 10 00 10 00 00 00 00`, which is malformed: byte 3 is
        // the ctype and 0x10 is not a value it can take, and the subunit (0x48, PANEL) was
        // missing entirely, so every operand after it was one byte early. The headphones
        // answered 0x0A REJECTED to everything we sent, which is why the volume never moved:
        // the round-trip measurement was measuring a rejection.
        // Copied byte for byte from what the headphones themselves send us every two seconds
        // (`10 11 0E 01 48 00 00 19 58 10 00 00 01 03`). The previous frame was a guess at the
        // AV/C layout and was answered REJECTED every time, which also made the round-trip
        // measurement meaningless — it was timing a rejection.
        let frame: [UInt8] = [
            0x00, 0x11, 0x0E, 0x00, 0x48, 0x00, 0x00, 0x19, 0x58,
            0x10, 0x00, 0x00, 0x01, 0x03,
        ]
        var packet = frame
        packet[0] = (label << 4) & 0xF0
        lock.withLock { sentAt[label] = DispatchTime.now().uptimeNanoseconds }
        onRaw?([0xFF] + packet)
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
        case getCapabilities(UInt8)
        case unsupported
    }

    public static func interpret(_ b: [UInt8]) -> Command {
        // AVCTP: header, profile ID (big endian), then the AV/C frame: 00 00 00 opcode operands.
        guard b.count >= 7 else { return .unsupported }
        switch b[5] {
        case 0x00 where b.count >= 14 && b[9] == 0x10:
            // GET CAPABILITIES. The headphones ask this every two seconds, forever, and until
            // now the answer was NOT IMPLEMENTED — so they never learned that we support
            // absolute volume, and never sent a volume event. Answering it is the precondition
            // for the whole volume story.
            //
            // Layout, read off the frame they send (`10 11 0E 01 48 00 00 19 58 10 00 00 01 03`):
            // PDU 0x10, reserved, two-byte length, then the capability id. The id is at byte 13,
            // not byte 10 — the first version read the reserved byte and answered an empty list.
            return .getCapabilities(b[13])
        case 0x7C:  // PASS THROUGH
            // The high bit of the operand is the press/release flag: a release must not fire the
            // key twice, and headphones send both.
            guard b[6] & 0x80 == 0 else { return .unsupported }
            let names: [UInt8: String] = [
                0x44: "play", 0x46: "pause", 0x45: "stop", 0x4B: "next",
                0x4C: "previous", 0x41: "volume_up", 0x42: "volume_down",
            ]
            guard let name = names[b[6] & 0x7F] else { return .unsupported }
            return .key(name)
        case 0x50:
            // SET ABSOLUTE VOLUME: 0…127, top bit reserved.
            return .absoluteVolume(Float(b[6] & 0x7F) / 127)
        default:
            return .unsupported
        }
    }

    /// The capability lists we answer GET CAPABILITIES with.
    ///
    /// Only what is true. Claiming a capability we do not implement would make the headphones
    /// send us events we then ignore, which is worse than silence: the user presses a key, the
    /// headphone reports it, and nothing happens.
    nonisolated static func capabilities(category: UInt8) -> [UInt8] {
        switch category {
        case 0x02:  // COMPANY ID: the Bluetooth SIG, which is what makes vendor dependent work
            return [0x02, 0x00, 0x19, 0x58]
        case 0x03:  // EVENTS SUPPORTED: capability id, count, then the events
            return [0x03, 0x01, 0x0D]
        default:  // anything else: an empty list, which is a valid answer
            return [category, 0x00]
        }
    }

    /// Bytes of a frame that arrived incomplete. AVCTP runs over a stream socket, so a read can
    /// carry half a frame or three frames at once.
    private var pending: [UInt8] = []

    /// The length of the frame at the start of `b`, or nil when it cannot be known yet.
    ///
    /// AVCTP over a stream socket has no message boundaries, so the frames have to be cut out by
    /// their own length field. Measured 2026-11-06: the headphones sent GET CAPABILITIES and the
    /// volume notification in a *single* read —
    /// `10 11 0E 01 48 00 00 19 58 10 00 00 01 03 12 11 0E 0F 48 00 00 19 58 31 00 00 02 0D 17`
    /// — and the parser looked only at the first frame, so the notification was never seen. Every
    /// volume event was being swallowed by the frame in front of it.
    ///
    /// Layout for a vendor dependent frame (opcode 0x00): 3 AVCTP header, ctype, subunit, opcode,
    /// 3 company id, PDU, reserved, two-byte payload length, payload.
    static func frameLength(_ b: [UInt8]) -> Int? {
        guard b.count >= 13 else { return b.count >= 3 ? nil : b.count }
        guard b[5] == 0x00 else { return b.count }  // not vendor dependent: take what came
        let payload = Int(b[11]) << 8 | Int(b[12])
        let total = 13 + payload
        return total <= b.count ? total : nil
    }

    private func receive(_ data: Data) {
        pending.append(contentsOf: data)
        while !pending.isEmpty {
            guard let length = Self.frameLength(pending), length > 0 else { return }
            let frame = Array(pending[0..<length])
            pending.removeFirst(length)
            handle(frame)
        }
    }

    private func handle(_ b: [UInt8]) {
        // Log every frame, before any guard drops it. The headphones' volume keys move their own
        // DSP and tell us nothing, and the only way to tell that apart from "we are dropping the
        // frame" is to see the bytes that actually arrived.
        onRaw?(b)
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
            // A VOLUME CHANGED notification, either INTERIM (the value now) or CHANGED (the value
            // after the headphones' own keys moved it). Both carry the value in the last byte.
            //
            // This is the only way to hear the headphones' volume keys: measured 2026-11-06,
            // they send no PASS THROUGH at all — they move their own DSP and report it here.
            // The frame is 15 bytes, not 17: `12 11 0E 0F 48 00 00 19 58 31 00 00 02 0D 17`.
            // A first version required 17 and read byte 16, so it silently ignored every
            // notification — the guard was the bug, not the parsing.
            if b.count >= 15, b[9] == 0x31, b[13] == 0x0D {
                // Only CHANGED is a real change. INTERIM (0x0F) is the value the headphones
                // report when a registration is accepted, and it repeats the same number we
                // already have — measured 2026-11-06, every press produced a CHANGED followed by
                // an INTERIM with the same value, so the slider moved twice per press and the
                // volume ended up at double the step.
                //
                // It matters because the Mac's slider is the *source of truth* for the gain, and
                // writing it from an INTERIM echo makes the two chase each other.
                let value = Float(b[14] & 0x7F) / 127
                if b[3] == 0x0F {
                    // The registration was accepted: remember the value, do not act on it.
                    lock.withLock { volumeRegistered = true }
                    return
                }
                onAbsoluteVolume?(value)
                // Only CHANGED (0x0D) consumes a registration, so only CHANGED needs a new one.
                //
                // The ctype is byte 3 of the AV/C frame, not anything in the AVCTP header: the
                // header holds the transaction label, the packet type, C/R and IPID, and nothing
                // else. Reading `header >> 2 & 0x03` gave 0 for every frame, so this never ran.
                //
                // And it is 0x0D, not 0x0C: 0x0C is STABLE. Comparing against 0x0C meant the
                // headphones reported the volume once per session and then went quiet.
                lock.withLock { volumeRegistered = false }
                registerVolumeNotifications()
            }
            return
        }
        let packetType = (header >> 2) & 0x03
        guard isCommand, packetType == 0 else { return }
        let pid = UInt16(b[1]) << 8 | UInt16(b[2])
        // A response echoes the request with the C/R bit set and its own ctype. The old code
        // copied the whole request and only flipped the header, so the ctype stayed 0x00
        // (CONTROL) in a frame that claimed to be a response — the headphones read it as
        // malformed and the reply was ignored.
        var response = b
        response[0] = header | 0x02  // response, same transaction label
        if pid != Self.avrcpProfileID {
            response[0] |= 0x01  // IPID: invalid profile
            socket.send(Data(response[0..<3]))
            return
        }
        // The answer is built from scratch: AVCTP header, profile ID, then an AV/C RESPONSE with
        // the same opcode, subunit and operands. Copying the request and patching bytes is what
        // produced a response whose ctype was still CONTROL.
        var reply: [UInt8] = [header | 0x02, b[1], b[2], 0x09, b[4], b[5]]
        reply.append(contentsOf: b[6..<min(b.count, 9)])
        switch Self.interpret(b) {
        case .key(let name):
            // ACCEPTED only if something will actually happen. Answering ACCEPTED and then
            // dropping the key is the worst possible reply: the headphones believe it was
            // handled and never retry, and the listener hears nothing with no explanation.
            // Measured 2026-11-06: every transport key was answered ACCEPTED and discarded.
            let handled = onKey?(name) ?? false
            reply[3] = handled ? 0x09 : 0x08  // ACCEPTED, or NOT IMPLEMENTED
        case .absoluteVolume(let value):
            onAbsoluteVolume?(value)
            reply[3] = 0x09  // ACCEPTED
        case .getCapabilities(let category):
            reply[3] = 0x09  // ACCEPTED, then the list
            // The headphones ask this every two seconds, which is proof the channel is up. The
            // registration sent at start-up races with the channel opening and is sometimes
            // lost — measured 2026-11-06: sent at t=8.477 in the same instant as "channel held",
            // and no answer ever came. Registering here, on their own request, cannot race.
            if !lock.withLock({ volumeRegistered }) { registerVolumeNotifications() }
            let list = Self.capabilities(category: category)
            reply.append(contentsOf: [0x00, UInt8(list.count >> 8), UInt8(list.count & 0xFF)])
            reply.append(contentsOf: list)
        case .unsupported:
            reply[3] = 0x08  // NOT IMPLEMENTED
        }
        onRaw?([0xFE] + reply)  // 0xFE marks a reply in the log
        socket.send(Data(reply))
    }
}
