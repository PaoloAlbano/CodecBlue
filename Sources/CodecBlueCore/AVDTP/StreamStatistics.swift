import Foundation

/// Counters for one report window: what the link carried, and what had to be thrown away.
struct StreamStatistics {
    private(set) var sentBytes = 0
    private(set) var sentPackets = 0
    private(set) var sentFrames = 0
    private(set) var droppedFrames = 0
    private(set) var stallCount = 0
    private(set) var stallSeconds: TimeInterval = 0

    /// Link throughput in kbit/s over the window.
    func sentKbps(window: TimeInterval) -> Double {
        window > 0 ? Double(sentBytes) * 8 / window / 1000 : 0
    }

    /// Packets per second over the window.
    func packetsPerSecond(window: TimeInterval) -> Double {
        window > 0 ? Double(sentPackets) / window : 0
    }

    /// Audio time actually delivered, as a fraction of the window (1 = real time).
    func deliveredFraction(sampleRate: Int, window: TimeInterval) -> Double {
        guard window > 0, sampleRate > 0 else { return 0 }
        return Double(sentFrames) / Double(sampleRate) / window
    }

    /// Audio time that had to be dropped, as a fraction of the window.
    func droppedFraction(sampleRate: Int, window: TimeInterval) -> Double {
        guard window > 0, sampleRate > 0 else { return 0 }
        return Double(droppedFrames) / Double(sampleRate) / window
    }

    mutating func record(packet: Int, frames: Int) {
        sentBytes += packet
        sentPackets += 1
        sentFrames += frames
    }

    mutating func record(droppedFrames: Int) { self.droppedFrames += droppedFrames }

    mutating func record(stall seconds: TimeInterval) {
        stallCount += 1
        stallSeconds += seconds
    }

    /// True when audio had to be dropped, i.e. the link, not the audio, is the limit.
    var linkIsTheBottleneck: Bool { droppedFrames > 0 }
}
