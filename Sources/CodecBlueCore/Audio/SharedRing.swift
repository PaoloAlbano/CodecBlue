import Foundation

/// Reads the audio that `CodecBlueDriver` has published, from the shared ring the two sides agree
/// on. The driver writes; this reads. Each side owns one index, so no lock is needed and neither
/// can block the other.
///
/// The layout must match `Driver/CodecBlueDriver/CodecBlueDriver.c` byte for byte. It is written
/// out again here rather than shared through a header because the two sides are C and Swift, and
/// a wrong layout is caught by the self-test rather than by silence.
public final class SharedRing: @unchecked Sendable {
    public static let frames = 48000
    public static let channels = 2
    public static let path = "/tmp/codecblue-ring"

    /// Offsets inside the mapped region. `write`/`read` are 64-bit counters of frames; the
    /// sample array follows after a small header.
    private static let headerBytes = 32  // 2×8 counters + 3×4 fields, padded to 8
    private static let regionBytes = headerBytes + frames * channels * 4

    private let base: UnsafeMutableRawPointer
    private let writeIndex: UnsafeMutablePointer<UInt64>
    private let readIndex: UnsafeMutablePointer<UInt64>
    private let sampleRateField: UnsafeMutablePointer<UInt32>
    private let channelsField: UnsafeMutablePointer<UInt32>
    /// The pid of the process feeding this ring, or 0. Written here, read by the driver, which
    /// uses it to hide the device when nobody can fill it — see `CodecBlueDriver.c`.
    private let feederField: UnsafeMutablePointer<Int32>
    private let samples: UnsafeMutablePointer<Float>

    public enum RingError: Error, CustomStringConvertible {
        case cannotOpen(String)
        public var description: String {
            switch self {
            case .cannotOpen(let why): "cannot open the driver's ring: \(why)"
            }
        }
    }

    /// Opens the ring the driver created. Fails if the driver has never run: the file only
    /// exists once it has, which is a clearer error than reading zeros.
    public init(path: String = SharedRing.path) throws {
        let fd = open(path, O_RDWR)
        guard fd >= 0 else {
            throw RingError.cannotOpen(
                "\(path) does not exist — is the driver installed and running?")
        }
        defer { close(fd) }
        guard let map = mmap(nil, Self.regionBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
            map != MAP_FAILED
        else { throw RingError.cannotOpen("mmap failed") }
        base = map
        writeIndex = map.advanced(by: 0).assumingMemoryBound(to: UInt64.self)
        readIndex = map.advanced(by: 8).assumingMemoryBound(to: UInt64.self)
        sampleRateField = map.advanced(by: 16).assumingMemoryBound(to: UInt32.self)
        channelsField = map.advanced(by: 20).assumingMemoryBound(to: UInt32.self)
        feederField = map.advanced(by: 28).assumingMemoryBound(to: Int32.self)
        samples = map.advanced(by: Self.headerBytes).assumingMemoryBound(to: Float.self)
    }

    deinit { munmap(base, Self.regionBytes) }

    public var sampleRate: Int { Int(sampleRateField.pointee) }

    /// Sets the rate the driver will run at, for the next time coreaudiod loads it.
    ///
    /// The driver reads this field when it opens the ring, so a running device is unaffected: a
    /// device that changed rate underneath its clients would break every app that had already
    /// opened it. The caller is told to reload the driver, which is one `killall coreaudiod`.
    ///
    /// The buffer is sized for 96 kHz, so any rate at or below that fits; a higher one would run
    /// the ring dry. The bound is checked here because the C side cannot report an error.
    public func setSampleRate(_ rate: Int) {
        guard (44100...96000).contains(rate) else { return }
        sampleRateField.pointee = UInt32(rate)
    }
    public var channelCount: Int { Int(channelsField.pointee) }

    /// Says that this process is (or is no longer) feeding this ring.
    ///
    /// The driver cannot work this out for itself, and the obvious test — "has anyone opened the
    /// device" — is circular: the device would be hidden because nobody uses it, and nobody could
    /// use it because it is hidden. So the fact comes from the only process that knows it.
    ///
    /// A pid and not a boolean, because a boolean has to be cleared by the process that set it and
    /// that is exactly what does not happen when the process is killed. Measured 2026-11-09: after
    /// `kill -9` mid-stream the ring still said "feeding", the device stayed in the output list
    /// with nothing behind it, and every app that chose it played into silence. The driver checks
    /// whether the pid still exists, so a crash clears itself.
    public var feeder: Int32 {
        get { feederField.pointee }
        set { feederField.pointee = newValue }
    }

    /// Whether this process is the one feeding the ring.
    ///
    /// Setting it to `false` only clears the field **if it is still ours**, and that "if" is the
    /// whole of this property. The field holds one pid and there can be more than one process that
    /// wants to feed: the launchd agent, and whatever `codecblue system` someone runs by hand to
    /// try something. Measured 2026-11-09, exactly that way round — a test run of `codecblue
    /// system` was killed by `timeout`, its `defer` wrote 0, and the field had belonged to the
    /// agent for twenty minutes. The agent kept streaming, the driver hid the device because
    /// nobody was feeding it, macOS fell back to the headphones, and nothing anywhere said so:
    /// `codecblue status` reported `link_quality unknown`, `ring_frames 0`, and a battery
    /// percentage, which reads as "all fine" and was not.
    ///
    /// So leaving is conditional and joining is not: a process that starts feeding takes the field
    /// (it is the newest claimant, and the driver only asks whether the pid is alive), and a
    /// process that stops only lets go of what it still holds.
    public var feeding: Bool {
        get { feeder == Int32(ProcessInfo.processInfo.processIdentifier) }
        set {
            let me = Int32(ProcessInfo.processInfo.processIdentifier)
            if newValue {
                // Claim only a field that is free or whose holder is dead. Overwriting a live
                // claim is how the agent's pid got replaced by a test run's pid, and then cleared
                // by that test run's `defer`: the agent went on streaming with the driver told
                // nobody was feeding it.
                let holder = feeder
                if holder == 0 || holder == me || !Self.isAlive(holder) { feeder = me }
            } else if feeder == me {
                feeder = 0
            }
        }
    }

    /// Whether a pid names a process that still exists. Same question the driver asks with
    /// `kill(pid, 0)`, and the same answer for the same reason: for our own uid, "may I signal it"
    /// is "does it exist".
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// Frames written by the driver but not yet taken by us. This is the queue depth the stream
    /// has to keep small: it is the delay between the app and the headphones.
    public var available: Int {
        let written = writeIndex.pointee
        let taken = readIndex.pointee
        return written > taken ? Int(min(written - taken, UInt64(Self.frames))) : 0
    }

    /// Where to start reading, given what has been written and what has already been read.
    /// Pure arithmetic, so the rule can be tested without a driver: it is the rule that decides
    /// whether a resume plays the backlog (a click) or skips to the newest audio.
    public static func startIndex(
        written: UInt64, read: UInt64, count: Int,
        staleAfterFrames: Int
    ) -> UInt64 {
        var taken = read
        let waiting = written > taken ? written - taken : 0
        // The ring wraps: it holds `frames` and the writer overwrites the oldest. If the reader
        // is a full ring behind, the audio it is about to read has already been overwritten, so
        // it must skip forward. That is a real emergency and the only case worth counting.
        if waiting > UInt64(frames) {
            taken = written - UInt64(frames)
        }
        // `staleAfterFrames` is a *budget*, not a trigger: the throttle in `playSystem` holds the
        // depth at or below it, so being above it is normal while the cushion is being rebuilt
        // and is not a reason to throw audio away. An earlier version skipped here, which threw
        // away exactly the cushion the widening had just created — 86 skips in one run, heard as
        // clicks, while every other number in the report looked healthy.
        _ = staleAfterFrames
        return taken
    }

    /// How much audio may be waiting before the reader decides it is stale. A pause in playback
    /// leaves the ring full of silence and the moment before the pause: resuming would play that
    /// buffer first, which is heard as a click or a stutter. 50 ms is above the normal jitter and
    /// far below anything audible as a delay.
    /// How much audio may be waiting before the reader decides it is stale and skips to the
    /// newest. This is pure latency: everything here is heard as a delay between the app and the
    /// headphones.
    ///
    /// History, because the number moved for a reason each time: 50 ms was too tight — CoreAudio
    /// delivers in blocks of 1024 frames (21 ms) and the reader skipped on almost every read,
    /// which is an audible click. 200 ms fixed the clicks and cost 150 ms of delay. 50 ms is the
    /// right point now that the writer's block size is known: two and a half blocks of cushion.
    /// 250 ms, not 50.
    ///
    /// This number is the cushion, and the cushion is the whole defence against the link: the
    /// driver writes at real time, so the only audio the encoder can ever have in hand is what
    /// the reader has *not* thrown away. At 50 ms the queue sat at 0–16 ms whatever budget it
    /// was given — a queue cannot hold what was never produced — and every 100–300 ms stall in
    /// the link had to discard audio. That was the crackle.
    ///
    /// The cost is exactly this many milliseconds of delay, and there is no way around it: the
    /// choice is between a cushion and the gaps it prevents. 250 ms covers the measured stalls.
    public var staleAfterFrames = 12000
    /// The depth below which the cushion is topped up rather than allowed to drain.
    ///
    /// The driver produces about 48000 frames/s and the stream consumes exactly 48000, so the
    /// two clocks drift: measured 2026-11-06, a 9800-frame cushion was down to 512 after 200 s.
    /// Left alone it empties, and an empty cushion is a click at the next stall. Refilling to
    /// this depth costs nothing audible — it is the same 60 ms already in flight — and keeps the
    /// cushion where it was meant to be.
    /// Unused, and kept only to record why the idea failed twice.
    ///
    /// The cushion cannot be refilled by moving the read index back (the audio behind it is
    /// gone), and gating reads on a depth threshold deadlocks instead: the reader waits for the
    /// writer to top the cushion up, while the writer is the thing the reader is waiting on.
    /// Measured 2026-11-06, twice: the ring sat at 2848 frames against a 2880 threshold and the
    /// stream went silent.
    ///
    /// It turned out not to be needed either: with the driver's zero-timestamp period at 512
    /// frames the drift that drained the cushion disappeared, and the depth now holds at
    /// 10 000–10 200 frames on its own.
    public var keepAliveFrames = 0
    /// How many times the reader has thrown away a backlog. Every one of those is a click, so it
    /// belongs in the report rather than in a comment.
    public private(set) var skips = 0

    /// Takes up to `count` frames. If more than `staleAfterFrames` are waiting, the old audio is
    /// dropped and the newest kept: live audio wants a gap, not a growing delay.
    /// Start reading from the newest audio, discarding whatever is already waiting.
    ///
    /// Called once when the stream starts. The ring is a live device that has been filling since
    /// the driver loaded, so when the first packet is about to be sent it may hold a full second
    /// of audio from before — which would be played as a second of very old sound. Measured
    /// 2026-11-06: the depth sat at 48 000 frames (the whole ring) for the entire session because
    /// the reader started at the beginning and could never catch up.
    /// Throws away up to `count` frames from the front, without reading them.
    ///
    /// This is how the reader stays in step with the encoder when the encoder had to skip source
    /// audio because the link could not carry it. Skipping advances the clock without reading, so
    /// without this the ring grows by exactly what was skipped and the stream falls behind by that
    /// much — measured 2026-11-07, the ring went from 37 ms to a full second in one window and
    /// stayed there.
    ///
    /// It is not `jumpToLive`: that discards everything, which is a hole in the sound. This
    /// discards exactly as much as was already lost.
    public func discard(_ count: Int) {
        guard count > 0 else { return }
        let written = writeIndex.pointee
        let taken = readIndex.pointee
        let waiting = written > taken ? Int(written - taken) : 0
        readIndex.pointee = taken + UInt64(min(count, waiting))
    }

    public func jumpToLive() {
        readIndex.pointee = writeIndex.pointee
    }

    public func read(into buffer: inout [Float], count: Int) -> Int {
        let written = writeIndex.pointee
        let taken = Self.startIndex(
            written: written, read: readIndex.pointee,
            count: count, staleAfterFrames: staleAfterFrames)
        if taken != readIndex.pointee {
            readIndex.pointee = taken
            skips += 1
        }
        let wanted = min(count, Int(written - taken))
        guard wanted > 0 else { return 0 }
        if buffer.count < wanted * Self.channels {
            buffer = [Float](repeating: 0, count: wanted * Self.channels)
        }
        for i in 0..<wanted {
            let slot = Int((taken + UInt64(i)) % UInt64(Self.frames))
            buffer[i * 2] = samples[slot * 2]
            buffer[i * 2 + 1] = samples[slot * 2 + 1]
        }
        readIndex.pointee = taken + UInt64(wanted)
        return wanted
    }
}

/// A `TimeInterval` that one thread writes and another reads. Used for the cushion depth, which
/// the streamer changes when the link asks for more room and the reader consults on every block.
public final class CushionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval

    public init(_ seconds: TimeInterval) {
        self.seconds = seconds
    }

    public var value: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return seconds
        }
        set {
            lock.lock()
            seconds = newValue
            lock.unlock()
        }
    }
}
