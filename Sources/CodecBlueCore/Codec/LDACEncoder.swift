import CLDAC
import Foundation

/// LDAC encoder (AOSP libldac). Takes interleaved stereo Float32 PCM in blocks of 128
/// frames and returns LDAC transport frames ready for an RTP packet.
public final class LDACEncoder {
    public enum Quality: Int32, Sendable, CaseIterable {
        case high = 0  // HQ: 990 kbps (48/96 kHz), 909 kbps (44.1/88.2 kHz)
        case standard = 1  // SQ: 660 / 606 kbps
        case mobile = 2  // LQ: 330 / 303 kbps

        /// The three-letter code shown to the listener.
        ///
        /// Sony calls the bottom level **MQ**, for "Mobile Quality", and it is a bad label in a
        /// list: M sorts before S, so MQ appears *below* SQ and reads like a third position rather
        /// than the bottom of one — the listener has to be told what the letters mean before the
        /// menu makes sense. **LQ** says what it is, and it sorts where it belongs. The name in
        /// the code stays `mobile`, because that is the level's identity and renaming it would
        /// churn every call site for a display decision.
        public var name: String { ["HQ", "SQ", "LQ"][Int(rawValue)] }

        /// The word for a level, for anywhere a listener reads it in full.
        public var longName: String {
            switch self {
            case .high: return "High"
            case .standard: return "Standard"
            case .mobile: return "Low"
            }
        }

        /// Parses a level from what a person typed or a plist holds.
        ///
        /// `MQ` is accepted forever, and not out of politeness: the LaunchAgent's plist is written
        /// with a level in it, and a plist written before this rename says `MQ`. Refusing it would
        /// turn a running stream into a usage error at the next login — the kind of breakage that
        /// looks like the program forgot how to start.
        public static func parse(_ text: String) -> Quality? {
            switch text.uppercased() {
            case "HQ", "HIGH": return .high
            case "SQ", "STANDARD": return .standard
            case "LQ", "MQ", "LOW", "MOBILE": return .mobile
            default: return nil
            }
        }
    }

    /// Every EQMID this build of libldac accepts, including the two the header does not document.
    ///
    /// The header names three (HQ/SQ/MQ). The ABR table in Sony's source names five, and the two
    /// extra ones are real levels with real bitrates — 492 and 396 kbps at 96 kHz — which is what
    /// makes a bitrate choice finer than three steps possible without ABR.
    ///
    /// Whether a given build honours them is a separate question, so `LDACEncoder.levels()`
    /// asks rather than assumes; this enum is only the list of values to ask about.
    public enum Level: Int32, Sendable, CaseIterable {
        case hq = 0  // EQMID 0
        case sq = 1  // EQMID 1
        case mq = 2  // EQMID 2
        case middle = 3  // EQMID 3 — undocumented in the header, 492 kbps at 96 kHz
        case low = 4  // EQMID 4 — undocumented in the header, 396 kbps at 96 kHz

        public var name: String {
            switch self {
            case .hq: return "HQ"
            case .sq: return "SQ"
            case .middle: return "SQ-"
            case .mq: return "LQ"
            case .low: return "LQ-"
            }
        }

        /// The documented three, for the menu. The extra two are reachable but not advertised
        /// until they are measured on real headphones.
        public static var documented: [Level] { [.hq, .sq, .mq] }
    }

    /// Initialises with a raw EQMID, for the levels `Quality` does not name.
    public convenience init(
        sampleRate: Int, level: Level, mtu: Int,
        channelMode: UInt8 = 0x01
    ) throws {
        try self.init(
            sampleRate: sampleRate, eqmid: level.rawValue, mtu: mtu,
            channelMode: channelMode)
    }

    public struct Output {
        public let payload: Data  // LDAC frames
        public let frameCount: Int
    }

    public static let framesPerCall = 128  // per channel, fixed by libldac
    public let sampleRate: Int
    /// PCM frames one LDAC frame represents: 128 at 44.1/48 kHz, 256 at 88.2/96 kHz.
    public let framesPerLDACFrame: Int

    private let handle: HANDLE_LDAC_BT
    private var stream = [UInt8](repeating: 0, count: 1024)  // LDACBT_MAX_NBYTES

    public enum EncoderError: Error {
        case unavailable
        case initFailed(Int32)
        case encodeFailed(Int32)
    }

    /// - Parameters:
    ///   - mtu: the **media channel MTU** (RTP header included). libldac subtracts its own
    ///     18-byte transport header from it, so the payload it returns plus the 12-byte RTP
    ///     header and the 1-byte LDAC media header fits the MTU exactly.
    ///   - channelMode: A2DP LDAC channel-mode bit (0x01 stereo, 0x02 dual, 0x04 mono).
    /// libldac refuses (and, below 679, overruns its own buffer) any MTU under 679: that is
    /// `LDACBT_MTU_REQUIRED`, the 2-DH5 payload size. A smaller `--media-mtu` is clamped.
    public static let minimumMTU = 679

    public convenience init(
        sampleRate: Int, quality: Quality, mtu: Int,
        channelMode: UInt8 = 0x01
    ) throws {
        try self.init(
            sampleRate: sampleRate, eqmid: quality.rawValue, mtu: mtu,
            channelMode: channelMode)
    }

    public init(sampleRate: Int, eqmid: Int32, mtu: Int, channelMode: UInt8 = 0x01) throws {
        guard let handle = ldacBT_get_handle() else { throw EncoderError.unavailable }
        self.handle = handle
        self.sampleRate = sampleRate
        framesPerLDACFrame = sampleRate > 48000 ? 256 : 128
        let status = ldacBT_init_handle_encode(
            handle, Int32(max(mtu, Self.minimumMTU)), eqmid, Int32(channelMode),
            LDACBT_SMPL_FMT_F32, Int32(sampleRate)
        )
        guard status == 0 else {
            let code = ldacBT_get_error_code(handle)
            // Do NOT free here. `handle` is already assigned to a stored property, so a throwing
            // designated initialiser still runs `deinit`, which closes and frees it. Freeing in
            // both places is a double free — measured 2026-11-07: it segfaulted the process the
            // first time an unsupported EQMID was tried.
            throw EncoderError.initFailed(code)
        }
    }

    deinit {
        ldacBT_close_handle(handle)
        ldacBT_free_handle(handle)
    }

    /// Whether this build of libldac accepts ABR (EQMID 0x7F).
    ///
    /// LDAC has three fixed rates per sample rate — 330 / 660 / 990 kbps at 48 kHz — and no
    /// continuous bitrate. Anything in between has to come from ABR, where the encoder picks the
    /// level itself from what the link is doing. The header reserves 0x7F for it; whether the
    /// library honours it is a separate question, so it is asked rather than assumed.
    public static var supportsABR: Bool {
        guard let handle = ldacBT_get_handle() else { return false }
        // close before free: `ldacBT_free_handle` on a handle that was never closed segfaults.
        // Measured 2026-11-07 — the first version of this function crashed the process, which is
        // how the rule got written down.
        defer {
            ldacBT_close_handle(handle)
            ldacBT_free_handle(handle)
        }
        let status = ldacBT_init_handle_encode(
            handle, 679, 0x7F, LDAC_CCI_STEREO,
            LDACBT_SMPL_FMT_F32, 48000)
        return status == 0
    }

    /// Current bitrate in kbps (libldac moves between quality levels gradually).
    public var bitrateKbps: Int { Int(ldacBT_get_bitrate(handle)) }

    /// One step down the five-rung ladder, and one step up.
    ///
    /// libldac has **five** EQMIDs, not three: 990 / 660 / 492 / 396 / 330 kbps at 48 kHz. The two
    /// in the middle are undocumented (`ldacBT_ex.h`: "for internal use only") and are exactly what
    /// Sony's own ABR controller walks through — see `aEqmidToAbrQualityModeID` in
    /// `ldacBT_abr.c`, which sorts them as 0, 1, 2, 3, 4 in bitrate order. They are the reason a
    /// level can be *between* HQ and SQ instead of 330 kbps away from it, which is the whole
    /// difference between three fixed steps and a rate that follows the link.
    ///
    /// `ldacBT_alter_eqmid_priority` refuses to go below LQ and above HQ, so the ends are safe:
    /// stepping down from the floor returns -1 and changes nothing.
    @discardableResult
    public func stepDown() -> Bool {
        ldacBT_alter_eqmid_priority(handle, LDACBT_EQMID_INC_CONNECTION) == 0
    }

    @discardableResult
    public func stepUp() -> Bool {
        ldacBT_alter_eqmid_priority(handle, LDACBT_EQMID_INC_QUALITY) == 0
    }

    /// The rung a name or a number refers to, from what a person typed or a plist holds.
    ///
    /// Two spellings, because there are two things to say. `HQ` / `SQ` / `LQ` (and `MQ`, forever)
    /// name the three rungs Sony named; `0`…`4` name any rung on the ladder, including the two in
    /// the middle that have no name and are the reason a rate can follow the link instead of
    /// jumping 330 kbps at a time. `--quality 2` is a legitimate request: it is 492 kbps.
    public static func rung(from text: String) -> Int? {
        if let number = Int(text) { return (0...4).contains(number) ? number : nil }
        guard let quality = Quality.parse(text) else { return nil }
        switch quality {
        case .high: return 0
        case .standard: return 1
        case .mobile: return 4
        }
    }

    /// The EQMID behind a rung. The two orders are not the same, and that is the trap.
    ///
    /// The ladder is in bitrate order — 990, 660, 492, 396, 330 — while the EQMIDs are in Sony's
    /// own order, where the bottom level is 2 and the two undocumented ones are 3 and 4:
    ///
    ///     rung 0 → EQMID 0 (990)    rung 3 → EQMID 4 (396)
    ///     rung 1 → EQMID 1 (660)    rung 4 → EQMID 2 (330, "MQ")
    ///     rung 2 → EQMID 3 (492)
    ///
    /// Using `Quality(rawValue: rung)` instead reads rung 2 as "MQ" and rung 4 as nothing, which
    /// is how a menu came to offer 330 kbps twice and 492 not at all.
    public static func eqmid(forRung rung: Int) -> Int32? {
        switch min(4, max(0, rung)) {
        case 0: return 0
        case 1: return 1
        case 2: return 3
        case 3: return 4
        default: return 2
        }
    }

    /// What to call a rung. The three Sony named get their code; the two it did not get their
    /// bitrate, because that is the only thing that distinguishes them and it is the thing that
    /// matters when the question is "does this fit my link?".
    public static func name(rung: Int, sampleRate: Int = 48000) -> String {
        switch rung {
        case 0: return "HQ"
        case 1: return "SQ"
        case 4: return "LQ"
        default:
            let ladder = ladder(sampleRate: sampleRate)
            return rung < ladder.count ? "\(ladder[rung])" : "?\(rung)"
        }
    }

    /// The five rungs, highest first, as bitrates at the rate in use. Read from the encoder rather
    /// than from a table, so a rate change cannot make the ladder lie.
    ///
    /// Each step is followed by one encoded frame, and that is not padding: `ldacBT_get_bitrate`
    /// returns the bitrate of the *last frame encoded*, and `stepDown` only moves the target. A
    /// ladder read without encoding reports 990 five times — measured 2026-11-08, which is how this
    /// comment got written.
    public static func ladder(sampleRate: Int) -> [Int] {
        // `deinit` closes and frees the handle; there is nothing to release by hand.
        guard let probe = try? LDACEncoder(sampleRate: sampleRate, level: .hq, mtu: 679) else {
            return []
        }
        let silence = [Float](repeating: 0, count: framesPerCall * 2)
        // Eight frames, not one: the frame length moves in steps (`ldacBT_encode`, "update
        // frame_length if needed"), so a single frame reports a value in transit — measured
        // 2026-11-08: one frame per step gave 990, 495, 492, 396, 315, where 495 and 315 are
        // half-way houses between two rungs.
        func settle() -> Int? {
            for _ in 0..<8 { silence.withUnsafeBufferPointer { _ = try? probe.encode($0) } }
            return probe.bitrateKbps
        }
        var out = [settle() ?? probe.bitrateKbps]
        for _ in 0..<4 {
            guard probe.stepDown() else { break }
            out.append(settle() ?? probe.bitrateKbps)
        }
        return out
    }

    /// What a rung is worth at this rate, without encoding anything.
    ///
    /// `bitrateKbps` cannot answer this: `ldacBT_get_bitrate` reports the last frame encoded, so
    /// immediately after `move(toRung:)` it still reports the rung we just left. Measured
    /// 2026-11-09, in the log of a real stream:
    ///
    ///     quality: LDAC HQ does not fit this link (611 kbps carried, 20% dropped): settled on 990
    ///
    /// — a sentence that says the level did not fit and then names the level that did not fit.
    /// The same stale number appeared in `bitrate: down to …` and `bitrate: up to …`.
    ///
    /// Cached because `ladder` builds a probe encoder and encodes forty frames: fine once, wrong
    /// on a path that runs every time the adapter moves.
    public static func nominalKbps(rung: Int, sampleRate: Int = 48000) -> Int? {
        let ladder = cachedLadder(sampleRate: sampleRate)
        return rung >= 0 && rung < ladder.count ? ladder[rung] : nil
    }

    /// Guarded by a lock rather than an actor: the callers are synchronous, and an actor would
    /// make every log line at a rung change into an await.
    private static let ladderCache = LadderCache()

    final class LadderCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: [Int]] = [:]

        func value(for sampleRate: Int, build: () -> [Int]) -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            if let hit = values[sampleRate] { return hit }
            let fresh = build()
            values[sampleRate] = fresh
            return fresh
        }
    }

    static func cachedLadder(sampleRate: Int) -> [Int] {
        ladderCache.value(for: sampleRate) { ladder(sampleRate: sampleRate) }
    }

    public var quality: Quality {
        get { Quality(rawValue: ldacBT_get_eqmid(handle)) ?? .high }
        set { _ = ldacBT_set_eqmid(handle, newValue.rawValue) }
    }

    /// The rung the encoder is on, 0 (990 kbps) to 4 (330 kbps).
    ///
    /// It is not `quality`: two of the five rungs have no `Quality` case, because Sony only named
    /// three of them. Reading the ladder as a number is what makes "the best this link carries"
    /// expressible — 492 kbps is a real answer and neither "HQ" nor "SQ".
    public var rung: Int {
        let eqmid = ldacBT_get_eqmid(handle)
        switch Quality(rawValue: eqmid) {
        case .high: return 0
        case .standard: return 1
        case .mobile: return 4
        case nil: return eqmid == 3 ? 2 : 3
        }
    }

    /// Moves to a rung, by stepping: `ldacBT_set_eqmid` refuses the two undocumented values, and
    /// stepping is also how the encoder keeps its frame length consistent with the packet type.
    ///
    /// The `switch` above is exhaustive on purpose, and it is not a lookup table: `Quality` has
    /// three cases and the ladder has five rungs, so the two unnamed ones are identified by their
    /// EQMID — 3 and 4 — which is exactly how `ldacBT_ex.h` defines them.
    public func move(toRung target: Int) {
        let target = min(4, max(0, target))
        // A bounded number of steps: the ladder has five rungs, so four moves is the longest
        // possible journey and a loop that cannot spin.
        for _ in 0..<4 {
            let now = rung
            if now == target { return }
            if now < target {
                guard stepDown() else { return }
            } else {
                guard stepUp() else { return }
            }
        }
    }

    /// Encodes exactly `framesPerCall` stereo frames (pass nil to flush at the end).
    public func encode(_ pcm: UnsafeBufferPointer<Float>?) throws -> Output? {
        var used: Int32 = 0
        var written: Int32 = 0
        var frames: Int32 = 0
        let status: Int32 = stream.withUnsafeMutableBufferPointer { out in
            if let pcm {
                return ldacBT_encode(
                    handle, UnsafeMutableRawPointer(mutating: pcm.baseAddress), &used,
                    out.baseAddress, &written, &frames)
            }
            return ldacBT_encode(handle, nil, &used, out.baseAddress, &written, &frames)
        }
        guard status == 0 else { throw EncoderError.encodeFailed(ldacBT_get_error_code(handle)) }
        guard written > 0 else { return nil }
        return Output(payload: Data(stream[0..<Int(written)]), frameCount: Int(frames))
    }
}

extension LDAC {
    /// LDAC codec-information bytes (after vendor and codec IDs): sampling frequency, channel mode.
    public static func frequencyBit(_ rate: Int) -> UInt8? {
        [44100: 0x20, 48000: 0x10, 88200: 0x08, 96000: 0x04][rate]
    }

    public static func rates(fromBits bits: UInt8) -> [Int] {
        [(0x20, 44100), (0x10, 48000), (0x08, 88200), (0x04, 96000)].filter { bits & $0.0 != 0 }
            .map(\.1)
    }

    /// Codec information for SET_CONFIGURATION: one rate, stereo.
    public static func configuration(rate: Int) -> Data? {
        guard let bit = frequencyBit(rate) else { return nil }
        var data = Data()
        withUnsafeBytes(of: vendorID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: codecID.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [bit, 0x01])
        return data
    }
}
