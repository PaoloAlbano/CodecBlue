import Foundation

/// Holds the headphones' hands-free (HFP) RFCOMM channel while streaming, acting as a
/// minimal audio gateway: it completes the service level connection and refuses calls.
///
/// Why: if macOS gets HFP, coreaudiod publishes the headphones' call device and may make it
/// the default input or output. As soon as anything uses it, a SCO link opens and takes
/// radio airtime permanently, starving A2DP (observed by Blue Bloom: aptX dropped to
/// 200-280 kbps). During calls CodecBlue releases the headphones to macOS instead.
public final class HandsFreeHolder: @unchecked Sendable {
    public static let handsFreeServiceUUID: UInt16 = 0x111E

    public let socket: ChannelSocket
    /// Battery level 0...100 reported by the headphones (Apple or HF-indicator style).
    public var onBattery: (@Sendable (Int) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?
    public private(set) var serviceLevelConnected = false

    private var buffer = ""

    public init(socket: ChannelSocket) {
        self.socket = socket
        socket.onData = { [weak self] data in self?.receive(data) }
        socket.start()
    }

    public func close() { socket.close() }

    private func receive(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        while let end = buffer.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            let line = String(buffer[..<end]).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...end)
            if !line.isEmpty { handle(line) }
        }
    }

    private func respond(_ lines: String...) {
        var text = ""
        for line in lines { text += "\r\n\(line)\r\n" }
        socket.send(Data(text.utf8))
    }

    private func handle(_ command: String) {
        let upper = command.uppercased()
        switch true {
        case upper.hasPrefix("AT+BRSF"):
            // No optional features: no codec negotiation, no three-way calling, no HF
            // indicators. That keeps the service level connection to the bare minimum.
            respond("+BRSF: 0", "OK")
        case upper == "AT+CIND=?":
            respond(
                #"+CIND: ("service",(0,1)),("call",(0,1)),("callsetup",(0-3)),("callheld",(0-2)),("signal",(0-5)),("roam",(0,1)),("battchg",(0-5))"#,
                "OK")
        case upper == "AT+CIND?":
            respond("+CIND: 1,0,0,0,5,0,5", "OK")
        case upper.hasPrefix("AT+CMER"):
            serviceLevelConnected = true
            onLog?("hands-free channel held (service level connection up)")
            respond("OK")
        case upper == "AT+CHLD=?":
            respond("+CHLD: (0,1,2,3)", "OK")
        case upper.hasPrefix("AT+XAPL"):
            respond("+XAPL=iPhone,7", "OK")
        case upper.hasPrefix("AT+IPHONEACCEV"):
            // AT+IPHONEACCEV=n,key,value,...: key 1 = battery 0-9
            let fields =
                command.split(separator: "=").last?.split(separator: ",").map(String.init) ?? []
            var i = 1
            while i + 1 < fields.count {
                if fields[i] == "1", let level = Int(fields[i + 1]) {
                    onBattery?(min(100, (level + 1) * 10))
                }
                i += 2
            }
            respond("OK")
        case upper.hasPrefix("AT+BIEV"):
            // AT+BIEV=2,<0-100>: HF indicator 2 = battery
            let fields = command.split(separator: "=").last?.split(separator: ",") ?? []
            if fields.count == 2, fields[0] == "2", let level = Int(fields[1]) { onBattery?(level) }
            respond("OK")
        case upper.hasPrefix("AT+COPS?"):
            respond(#"+COPS: 0,0,"""#, "OK")
        case upper.hasPrefix("ATA"), upper.hasPrefix("ATD"), upper.hasPrefix("AT+BLDN"),
            upper.hasPrefix("AT+CHUP"),
            upper.hasPrefix("AT+BVRA"), upper.hasPrefix("AT+BCC"):
            respond("ERROR")  // no calls through us: during calls macOS gets the headphones
        default:
            respond("OK")  // NREC, VGS, VGM, CLIP, CCWA, CMEE, BIA, ... harmless
        }
    }
}
