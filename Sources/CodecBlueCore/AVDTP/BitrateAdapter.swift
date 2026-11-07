import Foundation

/// Chooses the LDAC quality level from what the link is actually doing, instead of guessing it
/// before the first packet.
///
/// The numbers that matter, measured on the FreeBuds 5 with the link quality mode on
/// (see `notes/findings/2026-11-05-play-ldac-queue.md` §13):
///
///     HQ 990 kbps → the channel takes ~500: half the audio is thrown away
///     SQ 660 kbps → in between, untested at length
///     MQ 330 kbps → the channel takes all of it: queue empty, nothing dropped
///
/// So the useful rule is not "pick the best quality" but "pick the highest one the link carries",
/// and the link's verdict is already in the stream's own statistics: dropped frames and queue
/// depth. This type only decides when to change, and refuses to oscillate.
///
/// Hysteresis, both ways:
/// * step down as soon as a window drops audio or the queue sits at its ceiling — a glitch is
///   audible now, and waiting to confirm it costs another second of it;
/// * step up only after `upAfter` consecutive clean windows, because a link that has just
///   recovered is the one most likely to fall back.
public struct BitrateAdapter {
    public enum Decision: Equatable {
        case hold
        case down(LDACEncoder.Quality)
        case up(LDACEncoder.Quality)
    }

    /// Dropped audio above this fraction of the window means the level is too high.
    public let dropLimit: Double
    /// A queue at or above this fraction of its budget means the level is too high, even if
    /// nothing has been dropped yet: the drop is about to happen.
    public let queueLimit: Double
    /// Clean windows needed before trying a higher level.
    public let upAfter: Int

    private var cleanWindows = 0
    private var lastChange = Date.distantPast
    /// A level that has already failed once is not tried again for a while, and the wait grows
    /// each time it fails: without this the adapter climbs back into a level it knows is too
    /// high, every `minimumInterval`, and the listener hears the same glitch on a loop.
    private var failures: [LDACEncoder.Quality: Int] = [:]
    private var blockedUntil: [LDACEncoder.Quality: Date] = [:]
    public let backoff: TimeInterval
    /// The highest level this adapter may climb to. `--quality` sets it: asking for MQ means
    /// "MQ is as good as I want", not "start at MQ and go up".
    public let ceiling: LDACEncoder.Quality
    /// How long to stay clean at a level before spending a probe on the one above. Probing up
    /// is the only way to find out whether a level works, and a failed probe is audible, so it
    /// is worth a long clean stretch first.
    public let upDwell: TimeInterval
    /// Do not change more often than this: each change resizes libldac's frames, and a level
    /// that flips every window sounds worse than a steady lower one.
    public let minimumInterval: TimeInterval

    public init(dropLimit: Double = 0.02, queueLimit: Double = 0.75, upAfter: Int = 3,
                minimumInterval: TimeInterval = 4, backoff: TimeInterval = 30,
                ceiling: LDACEncoder.Quality = .high, upDwell: TimeInterval = 20) {
        self.dropLimit = dropLimit
        self.queueLimit = queueLimit
        self.upAfter = upAfter
        self.minimumInterval = minimumInterval
        self.backoff = backoff
        self.ceiling = ceiling
        self.upDwell = upDwell
    }

    /// Feeds one report window and says what to do.
    /// - Parameters:
    ///   - dropped: fraction of the window's audio thrown away, 0…1.
    ///   - queueFill: queue duration as a fraction of its budget, 0…1.
    ///   - now: the window's timestamp, for the minimum interval.
    public mutating func decide(current: LDACEncoder.Quality, dropped: Double, queueFill: Double,
                                now: Date = Date()) -> Decision {
        if dropped > dropLimit || queueFill >= queueLimit {
            cleanWindows = 0
            guard now.timeIntervalSince(lastChange) >= minimumInterval else { return .hold }
            guard let lower = Self.lower(current) else { return .hold }
            // The level we are leaving has just proved too high: remember it, with a wait that
            // doubles each time.
            let count = (failures[current] ?? 0) + 1
            failures[current] = count
            blockedUntil[current] = now.addingTimeInterval(backoff * pow(2, Double(count - 1)))
            lastChange = now
            return .down(lower)
        }
        cleanWindows += 1
        guard cleanWindows >= upAfter,
              now.timeIntervalSince(lastChange) >= minimumInterval,
              now.timeIntervalSince(lastChange) >= upDwell
        else { return .hold }
        guard let higher = Self.higher(current), higher.rawValue >= ceiling.rawValue else {
            // Already at the top and it is clean: nothing to do, and do not let the counter
            // grow forever.
            cleanWindows = upAfter
            return .hold
        }
        // Do not climb into a level that recently failed: that is the whole point of the backoff.
        if let blocked = blockedUntil[higher], now < blocked { return .hold }
        cleanWindows = 0
        lastChange = now
        return .up(higher)
    }

    /// The next level down, or nil at the bottom. `Quality.rawValue` grows as quality falls.
    public static func lower(_ quality: LDACEncoder.Quality) -> LDACEncoder.Quality? {
        LDACEncoder.Quality(rawValue: quality.rawValue + 1)
    }

    /// The next level up, or nil at the top.
    public static func higher(_ quality: LDACEncoder.Quality) -> LDACEncoder.Quality? {
        quality.rawValue > 0 ? LDACEncoder.Quality(rawValue: quality.rawValue - 1) : nil
    }
}
