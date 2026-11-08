import Foundation

/// Chooses the LDAC bitrate from what the link is actually doing, on the five rungs libldac has.
///
/// The rungs, at 48 kHz, measured from the encoder itself (`LDACEncoder.ladder`):
///
///     rung 0   990 kbps   Sony's "HQ"
///     rung 1   660 kbps   Sony's "SQ"
///     rung 2   492 kbps   undocumented, named "Q0" in `ldacBT_ex.h`
///     rung 3   396 kbps   undocumented, "Q1"
///     rung 4   330 kbps   Sony's "MQ"
///
/// The two in the middle are the whole reason this type works on numbers and not on names. With
/// three fixed levels, a link that carries ~500 kbps has to choose between 660 (24–36% of the
/// audio thrown away) and 330 (half the bitrate left on the table). With five rungs it can sit at
/// 492, which is what the link actually carries. Measured 2026-11-08 on the FreeBuds 5: the link
/// carried 530–560 kbps and every one of the three fixed levels was wrong.
///
/// Hysteresis, both ways:
/// * step down as soon as a window drops audio or the queue sits at its ceiling — a glitch is
///   audible now, and waiting to confirm it costs another second of it;
/// * step up only after `upAfter` consecutive clean windows, and only after `upDwell` at the
///   current rung, because a link that has just recovered is the one most likely to fall back.
public struct BitrateAdapter {
    public enum Decision: Equatable {
        case hold
        case down(Int)
        case up(Int)
    }

    /// Dropped audio above this fraction of the window means the rung is too high.
    public let dropLimit: Double
    /// A queue at or above this fraction of its budget means the rung is too high, even if
    /// nothing has been dropped yet: the drop is about to happen.
    public let queueLimit: Double
    /// Clean windows needed before trying a higher rung.
    public let upAfter: Int

    private var cleanWindows = 0
    private var lastChange = Date.distantPast
    /// A rung that has already failed once is not tried again for a while, and the wait grows each
    /// time it fails: without this the adapter climbs back into a rung it knows is too high, every
    /// `minimumInterval`, and the listener hears the same glitch on a loop.
    private var failures: [Int: Int] = [:]
    private var blockedUntil: [Int: Date] = [:]
    public let backoff: TimeInterval

    /// The highest rung this adapter may climb to.
    ///
    /// It is a `var` because the listener can change it while the audio plays, and because the
    /// distinction it encodes is the one that made "HQ" unlistenable: a rung chosen by hand is a
    /// *ceiling*, not an instruction to sit there. HQ needs 990 kbps and this link carries ~530,
    /// so forcing HQ forces 45% of the audio to be thrown away. Asking for HQ must mean "as good
    /// as this link allows, up to HQ".
    public var ceilingRung: Int

    /// How long to stay clean at a rung before spending a probe on the one above. Probing up is
    /// the only way to find out whether a rung works, and a failed probe is audible, so it is
    /// worth a long clean stretch first.
    public let upDwell: TimeInterval
    /// Do not change more often than this: each change resizes libldac's frames, and a rung that
    /// flips every window sounds worse than a steady lower one.
    public let minimumInterval: TimeInterval

    public init(dropLimit: Double = 0.02, queueLimit: Double = 0.75, upAfter: Int = 3,
                minimumInterval: TimeInterval = 4, backoff: TimeInterval = 30,
                ceilingRung: Int = 0, upDwell: TimeInterval = 20) {
        self.dropLimit = dropLimit
        self.queueLimit = queueLimit
        self.upAfter = upAfter
        self.minimumInterval = minimumInterval
        self.backoff = backoff
        self.ceilingRung = ceilingRung
        self.upDwell = upDwell
    }

    /// Feeds one report window and says what to do.
    /// - Parameters:
    ///   - current: the rung the encoder is on, 0 (990 kbps) to 4 (330 kbps).
    ///   - dropped: fraction of the window's audio thrown away, 0…1.
    ///   - queueFill: queue duration as a fraction of its budget, 0…1.
    ///   - now: the window's timestamp, for the minimum interval.
    public mutating func decide(current: Int, dropped: Double, queueFill: Double,
                                now: Date = Date()) -> Decision {
        if dropped > dropLimit || queueFill >= queueLimit {
            cleanWindows = 0
            guard now.timeIntervalSince(lastChange) >= minimumInterval else { return .hold }
            guard current < 4 else { return .hold }
            // The rung we are leaving has just proved too high: remember it, with a wait that
            // doubles each time.
            let count = (failures[current] ?? 0) + 1
            failures[current] = count
            blockedUntil[current] = now.addingTimeInterval(backoff * pow(2, Double(count - 1)))
            lastChange = now
            return .down(current + 1)
        }
        cleanWindows += 1
        guard cleanWindows >= upAfter,
              now.timeIntervalSince(lastChange) >= minimumInterval,
              now.timeIntervalSince(lastChange) >= upDwell
        else { return .hold }
        let higher = current - 1
        guard higher >= 0, higher >= ceilingRung else {
            // Already at the top and it is clean: nothing to do, and do not let the counter grow
            // forever.
            cleanWindows = upAfter
            return .hold
        }
        // Do not climb into a rung that recently failed: that is the whole point of the backoff.
        if let blocked = blockedUntil[higher], now < blocked { return .hold }
        cleanWindows = 0
        lastChange = now
        return .up(higher)
    }

    /// The highest rung whose bitrate fits in what the link has been *measured* to carry.
    ///
    /// This is the rule that makes a hand-picked level usable, and it exists because of a measured
    /// failure: choosing HQ on this Mac produced 45% dropped audio and was described as
    /// "inascoltabile". HQ needs 990 kbps; the link carries ~530. No amount of waiting fixes that
    /// — the rung is simply above the ceiling.
    ///
    /// The step-by-step `decide` above cannot fix it either: it walks down one rung per
    /// `minimumInterval`, so 990 → 330 is sixteen seconds of audible garbage, and it stops at 660
    /// because 660 "only" drops 24%, which is still unlistenable.
    ///
    /// So when a window has dropped audio, the throughput it achieved *is* the link's capacity,
    /// and the rung is chosen from that number directly. The 0.85 factor is headroom: a rung that
    /// exactly fills the link leaves nothing for the AVRCP round trips and the retries, and a link
    /// at 100% utilisation is the one that starts stalling.
    ///
    /// - Parameter capacityKbps: what the link actually carried while audio was being dropped.
    public static func fitRung(capacityKbps: Double, sampleRate: Int = 48000) -> Int {
        let budget = capacityKbps * 0.85
        let ladder = LDACEncoder.ladder(sampleRate: sampleRate)
        guard !ladder.isEmpty else { return 4 }
        for (rung, kbps) in ladder.enumerated() where Double(kbps) <= budget {
            return rung
        }
        // Nothing fits, so the link is slower than even the bottom rung needs: the bottom is still
        // the right answer, because the alternative is silence.
        return ladder.count - 1
    }

    /// Records that a rung has proved too high, without changing the current one.
    ///
    /// The settle rule in the stream jumps straight to the rung the link can carry, which is not a
    /// step the adapter took — so the adapter has to be told, or it climbs back into the rung that
    /// just failed as soon as the link has been clean for `upDwell`. Measured 2026-11-08: without
    /// this, choosing HQ on a 550 kbps link settled on 330 and then walked back up to 660, dropped
    /// 12%, settled again, and repeated for as long as the stream ran.
    public mutating func noteTooHigh(_ rung: Int, now: Date = Date()) {
        let count = (failures[rung] ?? 0) + 1
        failures[rung] = count
        blockedUntil[rung] = now.addingTimeInterval(backoff * pow(2, Double(count - 1)))
        // A change just happened, so the dwell starts now. Without this, `lastChange` was still
        // the distant past and the adapter climbed again six seconds after settling — measured
        // 2026-11-08: HQ settled at 30.7 s, and "up to SQ" came at 36.7 s, which is an audible
        // probe of a rung this link cannot carry.
        lastChange = now
        cleanWindows = 0
    }
}
