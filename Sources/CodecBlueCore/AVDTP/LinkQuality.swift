import Foundation

/// What the link is doing, judged from what the socket did — not from bluetoothd's log.
///
/// The distinction is the whole point of this type, and it cost an evening.
///
/// bluetoothd's log has a line `Register audio device <address>-tacl`, and it is tempting to read
/// "present" as "the link quality mode is on". It is not: the takeover closes the media channel,
/// and bluetoothd erases that device **600 ms** after creating it (measured 2026-11-08, 18:18:01.660
/// → 18:18:02.270). So the log-based answer reads `off` on a link that is running at 336 kbps with
/// zero drops, and `on` in the two seconds it takes to notice. It measures the wrong thing.
///
/// What the link quality mode actually does is raise the ceiling: ~50 kbps off, ~500 on (§13.12).
/// The socket is the instrument that sees the ceiling, because it is the thing that gets refused
/// when the ceiling is reached:
///
///   * LQM off, 336 kbps requested: the socket refuses in every window, the burst is 2–3 packets,
///     and 29% of the audio is dropped. Measured.
///   * LQM on, 336 kbps requested: the socket refuses nothing at all. Measured, 73 windows in a row.
///
/// So "no stalls" is not an absence of evidence. It is the evidence: nothing was refused, therefore
/// the ceiling was above what was asked, therefore the mode is on.
public enum LinkQuality: String, Sendable, Equatable {
    case on
    case off
    /// Nothing has been sent yet, or nothing has been sent since the stream started.
    case unknown

    /// The rule, in one place, so that the self-test can hold it still.
    ///
    /// - Parameters:
    ///   - stalls: how many times the socket refused a packet in the last window.
    ///   - burst: the longest run of accepted packets in that window. Only meaningful when a stall
    ///     ended it; with no stall it is simply every packet sent, which says nothing about the
    ///     link (499 on this Mac, which is not a "packets per drain" figure at all).
    ///   - sentPackets: whether anything was sent at all in the window.
    public static func judge(stalls: Int, burst: Int, sentPackets: Bool) -> LinkQuality {
        guard sentPackets else { return .unknown }
        if stalls == 0 { return .on }
        // A refusal proves there is a ceiling; the burst says how high. Twenty is a wide margin
        // over the 2–3 that a 50 kbps ceiling allows and well under the 60–500 seen with it off
        // the way.
        return burst >= 20 ? .on : .off
    }
}
