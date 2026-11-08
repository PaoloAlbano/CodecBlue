import Foundation

/// A WAV file decoded to interleaved stereo Float32 (16/24/32-bit integer or 32-bit float).
public struct WAVFile: Sendable {
    public let sampleRate: Int
    public let samples: [Float]  // interleaved L R
    public var frameCount: Int { samples.count / 2 }

    /// Same audio at a different level. There is no volume control anywhere between the file and
    /// the encoder, so this is where a file that is too loud gets fixed.
    public func scaled(by factor: Float) -> WAVFile {
        WAVFile(sampleRate: sampleRate, samples: samples.map { max(-1, min(1, $0 * factor)) })
    }
    public var duration: Double { Double(frameCount) / Double(sampleRate) }

    public enum WAVError: Error, CustomStringConvertible {
        case notWAV
        case unsupported(String)
        public var description: String {
            switch self {
            case .notWAV: "not a WAV file"
            case .unsupported(let what): "unsupported WAV: \(what)"
            }
        }
    }

    public init(sampleRate: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46],
            b[8..<12] == [0x57, 0x41, 0x56, 0x45]
        else { throw WAVError.notWAV }

        var i = 12
        var format = 0
        var channels = 0
        var rate = 0
        var bits = 0
        var pcm: ArraySlice<UInt8>?
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<i + 4], encoding: .ascii) ?? ""
            let size = u32(i + 4)
            let body = i + 8
            let end = min(body + size, b.count)
            if id == "fmt " && size >= 16 {
                format = u16(body)
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
                if format == 0xFFFE && size >= 26 { format = u16(body + 24) }
            } else if id == "data" {
                pcm = b[body..<end]
            }
            i = body + size + (size & 1)
        }
        guard let pcm, channels == 1 || channels == 2 else {
            throw WAVError.unsupported("\(channels) channels")
        }
        let width = bits / 8
        let frame = width * channels
        let frames = pcm.count / max(frame, 1)
        var out = [Float](repeating: 0, count: frames * 2)
        let base = pcm.startIndex
        for f in 0..<frames {
            for c in 0..<2 {
                let source = min(c, channels - 1)
                let at = base + f * frame + source * width
                let value: Float
                switch (format, bits) {
                case (1, 16):
                    value = Float(Int16(bitPattern: UInt16(b[at]) | UInt16(b[at + 1]) << 8)) / 32768
                case (1, 24):
                    let raw = Int32(b[at]) | Int32(b[at + 1]) << 8 | Int32(b[at + 2]) << 16
                    value = Float((raw << 8) >> 8) / 8_388_608
                case (1, 32):
                    let raw =
                        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(
                            b[at + 3]) << 24
                    value = Float(Int32(bitPattern: raw)) / 2_147_483_648
                case (3, 32):
                    let raw =
                        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(
                            b[at + 3]) << 24
                    value = Float(bitPattern: raw)
                default: throw WAVError.unsupported("format \(format), \(bits) bits")
                }
                out[f * 2 + c] = max(-1, min(1, value))
            }
        }
        sampleRate = rate
        samples = out
    }

    /// Writes the samples as a 16-bit PCM WAV, for playing them through something else
    /// (macOS's own A2DP, `afplay`) to compare against our stream on the same link.
    public func write(to url: URL) throws {
        var data = Data()
        let frames = frameCount
        let byteCount = frames * 4  // stereo, 16-bit
        func u32(_ value: Int) {
            withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) }
        }
        func u16(_ value: Int) {
            withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16)
        u16(1)  // PCM
        u16(2)  // stereo
        u32(sampleRate)
        u32(sampleRate * 4)
        u16(4)
        u16(16)
        data.append(contentsOf: Array("data".utf8))
        u32(byteCount)
        for i in 0..<(frames * 2) {
            let clamped = max(-1, min(1, samples[i]))
            // The negative side reaches -32768: build the value as signed, then reinterpret.
            let value = Int16(clamping: Int((clamped * 32_767).rounded()))
            withUnsafeBytes(of: UInt16(bitPattern: value).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        try data.write(to: url)
    }

    /// A pure sine, constant, both channels identical.
    ///
    /// This is the signal to test a transport with, and the previous one was not. That one was an
    /// arpeggio whose frequency changed every 0.5 s while `t` kept running, so the *phase* jumped
    /// at every note change: the envelope masked most of it, but the result is a signal full of
    /// small discontinuities — and a discontinuity is exactly what a codec and a link make worse.
    /// Testing a link with it is testing the file, not the link.
    ///
    /// A constant sine has no transients at all: if it crackles, the crackle is the transport.
    /// - Parameter amplitude: 0…1. Low on purpose: LDAC at 330 kbps is happiest with headroom,
    ///   and a quiet tone makes a click stand out against the silence between samples.
    public static func sine(
        frequency: Float = 440, sampleRate: Int = 48000,
        seconds: Double = 30, amplitude: Float = 0.15
    ) -> WAVFile {
        let frames = Int(Double(sampleRate) * seconds)
        var samples = [Float](repeating: 0, count: frames * 2)
        // The frequency is rounded to a whole number of cycles in the file, so the last sample
        // joins the first without a step: a loop of this file is seamless.
        let cycles = max(1, (frequency * Float(seconds)).rounded())
        let step = 2 * Float.pi * cycles / Float(frames)
        for i in 0..<frames {
            let value = amplitude * sin(Float(i) * step)
            samples[i * 2] = value
            samples[i * 2 + 1] = value
        }
        return WAVFile(sampleRate: sampleRate, samples: samples)
    }

    /// A slow sine sweep, 100 Hz to 8 kHz, for hearing what the codec does across the band.
    /// Each frequency is held for a moment and joined with a crossfade, so the sweep itself has
    /// no transients to blame.
    public static func sweep(
        sampleRate: Int = 48000, seconds: Double = 30,
        amplitude: Float = 0.15
    ) -> WAVFile {
        let frames = Int(Double(sampleRate) * seconds)
        var samples = [Float](repeating: 0, count: frames * 2)
        let low: Float = 100
        let high: Float = 8000
        var phase: Float = 0
        for i in 0..<frames {
            let t = Float(i) / Float(frames)
            let frequency = low * pow(high / low, t)
            phase += 2 * Float.pi * frequency / Float(sampleRate)
            if phase > 2 * Float.pi { phase -= 2 * Float.pi }
            let value = amplitude * sin(phase)
            samples[i * 2] = value
            samples[i * 2 + 1] = value
        }
        return WAVFile(sampleRate: sampleRate, samples: samples)
    }
}
