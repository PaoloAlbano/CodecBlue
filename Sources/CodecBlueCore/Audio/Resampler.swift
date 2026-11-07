import Foundation

/// Converts interleaved stereo Float32 from the device's rate to the rate the headphones take.
///
/// It exists because the two are not always the same. The virtual device runs at 48 kHz — that is
/// what every app writes into it — but a pair of headphones that only accepts 44.1 kHz in LDAC is
/// still a pair of headphones we can drive. Refusing to stream to it because of the rate would be
/// a limitation of this program, not of the hardware.
///
/// Linear interpolation, deliberately: it is the cheapest thing that is not audibly wrong at
/// these ratios (48 → 44.1 is a 0.88 factor, and the error is a fraction of a dB in the audible
/// band). A windowed-sinc would be better and is not needed to prove the point; if it ever is,
/// this is the only file to change.
///
/// State is kept across calls, because the stream arrives in blocks: a resampler that restarted
/// at every block would click at every block boundary.
public final class Resampler {
    /// Settable, because it is also used as a rate servo: the stream holds a buffer that must be
    /// kept at a size, and the only way to change that size without dropping or repeating audio
    /// is to run the sample rate a fraction of a percent fast or slow.
    public var ratio: Double
    private var position: Double = 0
    /// The last input frame of the previous block, needed to interpolate the first output frame.
    private var lastLeft: Float = 0
    private var lastRight: Float = 0
    private var primed = false

    /// - Parameters:
    ///   - from: the rate of the input, in Hz.
    ///   - to: the rate of the output, in Hz.
    public init(from: Int, to: Int) {
        ratio = Double(to) / Double(from)
    }

    /// A ratio given directly, for corrections too small to express as two integer rates: a
    /// drift of 0.01% at 48 kHz is 47995.2 Hz, and rounding that to 47995 changes the correction
    /// by 4%, which is the difference between cancelling the drift and half-cancelling it.
    public init(ratio: Double) {
        self.ratio = ratio
    }

    /// True when no conversion is needed, so the caller can skip the whole thing.
    public var isIdentity: Bool { abs(ratio - 1) < 1e-9 }

    /// Resamples one block of interleaved stereo. Returns the same kind of array it was given.
    public func process(_ input: [Float]) -> [Float] {
        guard !isIdentity else { return input }
        let inputFrames = input.count / 2
        guard inputFrames > 0 else { return [] }
        if !primed {
            lastLeft = input[0]
            lastRight = input[1]
            primed = true
        }
        // One extra frame of room: the last output frame can fall between the last two inputs.
        let outputFrames = Int(Double(inputFrames) * ratio) + 1
        var output = [Float](repeating: 0, count: outputFrames * 2)
        var written = 0
        while position < Double(inputFrames) {
            let index = Int(position)
            let fraction = Float(position - Double(index))
            let (left0, right0) = frame(input, at: index)
            let (left1, right1) = frame(input, at: index + 1)
            output[written * 2] = left0 + (left1 - left0) * fraction
            output[written * 2 + 1] = right0 + (right1 - right0) * fraction
            written += 1
            position += 1 / ratio
        }
        // Carry the fractional position and the last frame into the next block.
        position -= Double(inputFrames)
        lastLeft = input[(inputFrames - 1) * 2]
        lastRight = input[(inputFrames - 1) * 2 + 1]
        return Array(output[0..<(written * 2)])
    }

    /// Frame `index` of this block.
    ///
    /// `index == -1` reaches back into the *previous* block, which is what makes the join
    /// seamless. `index >= count` must hold at the *current* block's last frame, not the
    /// previous one: an earlier version returned the previous block's value for both edges, so
    /// the interpolation at the end of every block collapsed toward stale audio — a click at
    /// every block boundary, and the self-test caught it.
    private func frame(_ input: [Float], at index: Int) -> (Float, Float) {
        let frames = input.count / 2
        if index < 0 { return (lastLeft, lastRight) }
        if index >= frames {
            return (input[(frames - 1) * 2], input[(frames - 1) * 2 + 1])
        }
        return (input[index * 2], input[index * 2 + 1])
    }
}
