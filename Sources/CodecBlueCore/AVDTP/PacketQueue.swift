import Foundation

/// The media packets waiting for the socket, bounded by a time budget.
///
/// bluetoothd takes packets from the media socket at whatever rate the link allows, which can
/// be far below the codec's bitrate. An unbounded queue turns that shortfall into growing
/// delay: on FreeBuds 5 with LDAC HQ the queue reached 3.5 s after 20 s of streaming
/// (2026-11-05), while roughly 50 kbps left the Mac. Dropping the oldest audio instead keeps
/// the delay at the budget, and the drop rate becomes the measurement of how much the link can
/// really carry.
struct PacketQueue {
    struct Entry {
        let packet: Data
        /// PCM frames per channel the packet carries.
        let frames: Int
    }

    private(set) var entries: [Entry] = []
    /// Longest audio the queue may hold when the link is behaving.
    let floorDuration: TimeInterval
    /// Longest audio the queue may hold at all: reached only after a stall proves the link needs
    /// the room.
    let ceilingDuration: TimeInterval
    /// What the queue is allowed right now, between the two.
    private(set) var maxDuration: TimeInterval
    /// Frames per channel the queue may hold right now.
    private(set) var maxFrames: Int
    private let sampleRate: Int
    private var dropped = 0

    /// A queue whose budget grows when the link proves it needs more room.
    ///
    /// Measured on 2026-11-06: the link does not lose packets, it *stalls* — it stops accepting
    /// for 100–300 ms and then resumes. With a 60 ms budget those stalls exceeded the buffer and
    /// the PCM was thrown away, which is heard as crackle; with 250 ms they were absorbed and
    /// nothing was heard. But 250 ms is also 250 ms of delay, and delay is what the listener
    /// notices on a video.
    ///
    /// So: start at the floor, and pay for the delay only where it is needed. Each stall doubles
    /// the budget up to the ceiling; a long clean stretch brings it back down slowly, one step at
    /// a time, so it does not oscillate.
    init(sampleRate: Int, floorDuration: TimeInterval, ceilingDuration: TimeInterval) {
        self.sampleRate = sampleRate
        self.floorDuration = floorDuration
        self.ceilingDuration = ceilingDuration
        self.maxDuration = floorDuration
        self.maxFrames = max(1, Int(floorDuration * Double(sampleRate)))
    }

    init(sampleRate: Int, maxDuration: TimeInterval) {
        self.init(sampleRate: sampleRate, floorDuration: maxDuration, ceilingDuration: maxDuration)
    }

    /// Records that the link refused to take packets, and widens the budget if it can.
    /// Returns true when the budget changed, so the caller can say so.
    mutating func noteStall() -> Bool {
        let next = min(maxDuration * 2, ceilingDuration)
        guard next > maxDuration else { return false }
        maxDuration = next
        maxFrames = max(1, Int(next * Double(sampleRate)))
        return true
    }

    /// Called after a clean window: narrows the budget back towards the floor, one step at a time.
    /// Returns true when it changed.
    ///
    /// The caller decides when a window counts as clean — it has the stall count — so this only
    /// does the arithmetic. Keeping the decision in one place is what stops the two from
    /// disagreeing about what "clean" means.
    mutating func relax() -> Bool {
        guard maxDuration > floorDuration else { return false }
        // Halve, but never below the floor: the same step size the widening used, so a link that
        // alternates between good and bad settles instead of jumping.
        let next = max(maxDuration / 2, floorDuration)
        maxDuration = next
        maxFrames = max(1, Int(next * Double(sampleRate)))
        return true
    }

    var queuedFrames: Int { entries.reduce(0) { $0 + $1.frames } }
    var queuedDuration: TimeInterval { Double(queuedFrames) / Double(maxFrames) * maxDuration }
    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    var first: Entry? { entries.first }
    /// Room for at least one more packet of the usual size.
    var hasRoom: Bool { queuedFrames < maxFrames }

    /// Appends a packet, dropping the oldest audio if the budget would be exceeded.
    mutating func append(_ packet: Data, frames: Int) {
        entries.append(Entry(packet: packet, frames: frames))
        while queuedFrames > maxFrames, entries.count > 1 {
            // Drop the *newest* audio, not the oldest.
            //
            // Removing the oldest is what a jitter buffer does for a stream that is already
            // late: it keeps the freshest audio. But here the queue is the cushion, and the
            // audio in it is not late — it is exactly the audio that will cover the next stall.
            // Throwing away its head empties the cushion from the front, so the very stall that
            // made it overflow then finds nothing to play: heard as a skip.
            //
            // Dropping the newest instead keeps the cushion intact and loses only the tail,
            // which is the audio we had not committed to yet.
            dropped += entries.removeLast().frames
        }
    }

    mutating func popFirst() -> Entry? {
        entries.isEmpty ? nil : entries.removeFirst()
    }

    /// Frames dropped since the last call, for the periodic report.
    mutating func takeDroppedFrames() -> Int {
        defer { dropped = 0 }
        return dropped
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

/// The link's side of the stream: how much audio the socket has actually taken, measured.
///
/// The interesting number is not how fast we can write, but how fast bluetoothd drains the
/// socket. `take` returns the audio that left the socket since the last call. `stalls` counts
/// how often the socket refused a packet and for how long: a link that freezes and then
/// catches up (sniff, a slow profile round) looks different from one that is uniformly slow.
struct LinkMeter {
    /// PCM frames per channel handed to the socket.
    private(set) var acceptedFrames = 0
    private var reportedFrames = 0
    /// Longest the socket stayed full in one go, in seconds.
    private(set) var longestStall: TimeInterval = 0
    private(set) var stalls = 0
    private(set) var stallSeconds: TimeInterval = 0
    private var stallStarted: UInt64?
    /// Packets accepted in a row without the socket refusing one: how much bluetoothd takes
    /// per wake-up. 1 means it reads one packet at a time, however much is in the buffer.
    private(set) var burst = 0
    private(set) var longestBurst = 0

    mutating func accepted(frames: Int) {
        acceptedFrames += frames
        burst += 1
        longestBurst = max(longestBurst, burst)
    }

    mutating func stalled(at now: UInt64) {
        burst = 0
        if stallStarted == nil { stallStarted = now }
    }

    mutating func drained(at now: UInt64) {
        guard let start = stallStarted else { return }
        let seconds = Double(now &- start) / 1e9
        stallStarted = nil
        // A refusal that lasted under 2 ms is the loop polling, not the link.
        guard seconds >= 0.002 else { return }
        stalls += 1
        stallSeconds += seconds
        longestStall = max(longestStall, seconds)
    }

    /// Frames accepted since the last call.
    mutating func take() -> Int {
        defer { reportedFrames = acceptedFrames }
        return acceptedFrames - reportedFrames
    }

    /// Audio time the socket took since the last call, as a fraction of the window.
    mutating func takeFraction(sampleRate: Int, window: TimeInterval) -> Double {
        guard window > 0, sampleRate > 0 else { return 0 }
        return Double(take()) / Double(sampleRate) / window
    }

    /// Forgets the window's stall figures (they are counters, not rates).
    mutating func resetStalls() {
        stalls = 0
        stallSeconds = 0
        longestStall = 0
        longestBurst = 0
    }
}
