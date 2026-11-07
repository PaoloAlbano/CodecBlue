import CLDAC
import Foundation

/// LDAC encoder (AOSP libldac). Takes interleaved stereo Float32 PCM in blocks of 128
/// frames and returns LDAC transport frames ready for an RTP packet.
public final class LDACEncoder {
    public enum Quality: Int32, Sendable, CaseIterable {
        case high = 0  // HQ: 990 kbps (48/96 kHz), 909 kbps (44.1/88.2 kHz)
        case standard = 1  // SQ: 660 / 606 kbps
        case mobile = 2  // MQ: 330 / 303 kbps

        public var name: String { ["HQ", "SQ", "MQ"][Int(rawValue)] }
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
        case hq = 0        // EQMID 0
        case sq = 1        // EQMID 1
        case mq = 2        // EQMID 2
        case middle = 3    // EQMID 3 — undocumented in the header, 492 kbps at 96 kHz
        case low = 4       // EQMID 4 — undocumented in the header, 396 kbps at 96 kHz

        public var name: String {
            switch self {
            case .hq: return "HQ"
            case .sq: return "SQ"
            case .middle: return "SQ-"
            case .mq: return "MQ"
            case .low: return "MQ-"
            }
        }

        /// The documented three, for the menu. The extra two are reachable but not advertised
        /// until they are measured on real headphones.
        public static var documented: [Level] { [.hq, .sq, .mq] }
    }

    /// Initialises with a raw EQMID, for the levels `Quality` does not name.
    public convenience init(sampleRate: Int, level: Level, mtu: Int,
                            channelMode: UInt8 = 0x01) throws {
        try self.init(sampleRate: sampleRate, eqmid: level.rawValue, mtu: mtu,
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

    public enum EncoderError: Error { case unavailable, initFailed(Int32), encodeFailed(Int32) }

    /// - Parameters:
    ///   - mtu: the **media channel MTU** (RTP header included). libldac subtracts its own
    ///     18-byte transport header from it, so the payload it returns plus the 12-byte RTP
    ///     header and the 1-byte LDAC media header fits the MTU exactly.
    ///   - channelMode: A2DP LDAC channel-mode bit (0x01 stereo, 0x02 dual, 0x04 mono).
    /// libldac refuses (and, below 679, overruns its own buffer) any MTU under 679: that is
    /// `LDACBT_MTU_REQUIRED`, the 2-DH5 payload size. A smaller `--media-mtu` is clamped.
    public static let minimumMTU = 679

    public convenience init(sampleRate: Int, quality: Quality, mtu: Int,
                            channelMode: UInt8 = 0x01) throws {
        try self.init(sampleRate: sampleRate, eqmid: quality.rawValue, mtu: mtu,
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
        let status = ldacBT_init_handle_encode(handle, 679, 0x7F, LDAC_CCI_STEREO,
                                               LDACBT_SMPL_FMT_F32, 48000)
        return status == 0
    }

    /// Current bitrate in kbps (libldac moves between quality levels gradually).
    public var bitrateKbps: Int { Int(ldacBT_get_bitrate(handle)) }

    public var quality: Quality {
        get { Quality(rawValue: ldacBT_get_eqmid(handle)) ?? .high }
        set { _ = ldacBT_set_eqmid(handle, newValue.rawValue) }
    }

    /// Encodes exactly `framesPerCall` stereo frames (pass nil to flush at the end).
    public func encode(_ pcm: UnsafeBufferPointer<Float>?) throws -> Output? {
        var used: Int32 = 0
        var written: Int32 = 0
        var frames: Int32 = 0
        let status: Int32 = stream.withUnsafeMutableBufferPointer { out in
            if let pcm {
                return ldacBT_encode(handle, UnsafeMutableRawPointer(mutating: pcm.baseAddress), &used,
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
        [(0x20, 44100), (0x10, 48000), (0x08, 88200), (0x04, 96000)].filter { bits & $0.0 != 0 }.map(\.1)
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
