import Foundation

/// What macOS's own A2DP path asks of the link, read from bluetoothd's log.
///
/// The question this answers is the one that comes up as soon as CodecBlue works: *why does the
/// Mac's own audio hold up further from the machine than this does?* The answer is in the numbers
/// bluetoothd prints when it streams, and they are worth reading rather than guessing:
///
///     A2DP configured at 44.1 KHz. Codec: AAC-LC, VBR max: 230 kbps.
///         1 frames * (12+668) bytes = 680 per RTP (max=879) every 23.22 ms
///
/// 680 bytes every 23.22 ms is **43 packets/s = 234 kbps**, and that is the whole story of the
/// distance: AAC asks for 234 kbps and LDAC's floor, through the public API, is 330. When the link
/// shrinks — distance, a wall, a body in the way — the first thing to go is the bitrate the link
/// can carry, and the path that needs less survives longer. It is not that AAC is better; it is
/// that it asks for a third less.
///
/// The second half of the answer is not in these numbers and is worth stating plainly: this path
/// is *macOS's* — bluetoothd owns the ACL link, keeps the Link Quality Mode on, takes the link out
/// of sniff, and has `adjustBitRateForMac` to lower the AAC bitrate when the link complains. We
/// rent the same link through a takeover, so we get the same radio but none of that machinery. See
/// §16 of `notes/findings/2026-11-05-play-ldac-queue.md`.
public struct AACSession: Sendable, Equatable {
    /// The rate macOS configured, in Hz (44100 or 48000).
    public let sampleRate: Int
    /// Bytes per RTP packet, the whole packet including the 12-byte RTP header.
    public let packetBytes: Int
    /// The interval between packets, in milliseconds, as bluetoothd prints it.
    public let intervalMilliseconds: Double
    /// What that works out to, in kbit/s. Derived, not copied: the log gives bytes and an interval.
    public var kbps: Double { Double(packetBytes) * 8 / intervalMilliseconds }
    /// The last retransmission rate bluetoothd reported for the link, 0…1.
    public let reTx: Double
    /// The last RSSI it reported, in dBm, if it reported one.
    public let rssi: Int?
    /// How many times `adjustBitRateForMac` fired: macOS lowering its own bitrate because the link
    /// could not carry it. This is the machinery we do not have below 330 kbps.
    public let bitrateAdjustments: Int
    /// How many `LinkQualityReport` lines there were, which is how much the numbers above rest on.
    public let reports: Int

    /// The line a person reads: one sentence per fact, no table.
    public func describe() -> [String] {
        var lines = [String(format: "macOS asked for AAC at %d Hz: %d bytes every %.2f ms = %.0f kbps",
                            sampleRate, packetBytes, intervalMilliseconds, kbps)]
        if reports > 0 {
            lines.append(String(format: "the link, over %d report(s): %.1f%% retransmitted%@",
                                reports, reTx * 100,
                                rssi.map { ", RSSI \($0) dBm" } ?? ""))
        } else {
            lines.append("the link: no report in the window, so nothing is claimed about it")
        }
        if bitrateAdjustments > 0 {
            lines.append("macOS lowered its own bitrate \(bitrateAdjustments) time(s) when the link "
                         + "complained: that is the machinery LDAC has nothing equivalent to")
        }
        return lines
    }

    /// The comparison that matters, in one sentence.
    ///
    /// `floorKbps` is the lowest bitrate this program can ask for: 330 at 48 kHz, 303 at 44.1, and
    /// it is a floor of libldac's public API and not of the format — see §16.
    public func comparison(floorKbps: Int) -> String {
        let ratio = Double(floorKbps) / kbps
        return String(format: "AAC asks %.0f kbps, LDAC cannot ask less than %d: %.1f× the bitrate, "
                      + "so the link has to be %.1f× better before this path is as steady",
                      kbps, floorKbps, ratio, ratio)
    }

    /// The rule, exposed for the self-test: the log lines are the only input.
    ///
    /// The last session in the window wins, because a log holds every session of the last few
    /// hours and the interesting one is the most recent. `ReTx` and `RSSI` come from the last
    /// `LinkQualityReport`, which bluetoothd prints once a second while *it* streams — never while
    /// we do, which is why this cannot be read for our own stream.
    public static func parse(_ text: String) -> AACSession? {
        var sampleRate: Int?
        var packetBytes: Int?
        var interval: Double?
        var reTx = 0.0
        var rssi: Int?
        var reports = 0
        var adjustments = 0
        for line in text.split(separator: "\n") {
            if line.contains("A2DP configured at"), line.contains("Codec: AAC") {
                // The rate is printed in kHz, as "44.1 KHz" or "48 KHz": a decimal and a unit, so
                // it is read as a number and scaled, not matched against a list of the two rates
                // that happen to exist today.
                sampleRate = number(after: "A2DP configured at ", in: line, before: " KHz")
                    .map { Int(($0 * 1000).rounded()) }
                packetBytes = number(after: "= ", in: line, before: " per RTP").map { Int($0) }
                interval = number(after: "every ", in: line, before: " ms")
                // A new configuration is a new session: the link numbers from the previous one do
                // not describe this one, and mixing them is how a report ends up describing two
                // different streams at once.
                reTx = 0
                rssi = nil
                reports = 0
                adjustments = 0
            }
            if line.contains("adjustBitRateForMac") { adjustments += 1 }
            if line.contains("LinkQualityReport") {
                reports += 1
                if let value = number(after: "ReTx = ", in: line, before: "%") { reTx = value / 100 }
                if let value = number(after: "RSSI = ", in: line) { rssi = Int(value) }
            }
        }
        guard let sampleRate, let packetBytes, let interval, interval > 0 else { return nil }
        return AACSession(sampleRate: sampleRate, packetBytes: packetBytes,
                          intervalMilliseconds: interval, reTx: reTx, rssi: rssi,
                          bitrateAdjustments: adjustments, reports: reports)
    }

    /// The first number in a line, optionally between two markers.
    ///
    /// Written by hand rather than with a regex because the log is full of numbers that are not the
    /// one wanted (`Handle = 29`, `max=879`, `(12+668)`) and the marker is what makes it findable.
    static func number(after marker: String, in line: Substring,
                       before stop: String? = nil) -> Double? {
        guard let start = line.range(of: marker) else { return nil }
        var rest = line[start.upperBound...]
        if let stop, let end = rest.range(of: stop) { rest = rest[..<end.lowerBound] }
        var digits = ""
        for character in rest {
            if character.isNumber || character == "." || character == "-" {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }
}
