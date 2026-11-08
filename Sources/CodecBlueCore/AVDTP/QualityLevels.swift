import Foundation

/// The LDAC ladder, described in terms of *this* link rather than in the abstract.
///
/// The nominal bitrates are not a property of a name alone — they depend on the sample rate — and
/// they are not a promise about the machine: HQ is 990 kbps by definition, and a link that carries
/// 530 kbps will throw away half the audio to honour it. Measured 2026-11-08 on the FreeBuds 5:
/// HQ dropped 41–48%, SQ 24–36%, LQ 0%.
///
/// There are five rungs, not three. `ldacBT_ex.h` documents EQMID 0…4 and only three of them have
/// a name from Sony; the two in the middle (492 and 396 kbps at 48 kHz) are what Sony's own ABR
/// controller walks through, and they are exactly what a 530 kbps link needs. So this type lists
/// the ladder the encoder actually has, and marks the rung it would pick.
public enum QualityLevels {
    /// One rung, as it stands on a link that carries `capacityKbps`.
    public struct Level: Sendable, Equatable {
        /// 0 (990 kbps) … 4 (330 kbps).
        public let rung: Int
        /// What the codec produces at this rate, from the encoder, not from a table.
        public let nominalKbps: Int
        /// Whether the rung fits with headroom. Same rule as `BitrateAdapter.fitRung`, so the menu
        /// cannot disagree with what the stream will do.
        public let fits: Bool
        /// The rung the stream would settle on, given the measured capacity.
        public let chosen: Bool

        /// "HQ" / "SQ" / "LQ" where Sony named the rung, and the bitrate where it did not.
        public var name: String {
            LDACEncoder.name(rung: rung)
        }
        /// "High" / "Standard" / "Low", or the bitrate for the unnamed rungs.
        public var longName: String {
            switch rung {
            case 0: return "High"
            case 1: return "Standard"
            case 4: return "Low"
            default: return "\(nominalKbps) kbps"
            }
        }
    }

    /// The whole ladder, highest first, judged against a measured capacity.
    ///
    /// - Parameter capacityKbps: what the link carried. Zero or negative means "not measured
    ///   yet", and then nothing is claimed to fit: a menu that guesses is worse than one that
    ///   says it does not know.
    public static func describe(capacityKbps: Double, sampleRate: Int = 48000) -> [Level] {
        let ladder = LDACEncoder.ladder(sampleRate: sampleRate)
        let pick =
            capacityKbps > 0
            ? BitrateAdapter.fitRung(
                capacityKbps: capacityKbps,
                sampleRate: sampleRate) : -1
        return ladder.enumerated().map { rung, kbps in
            Level(
                rung: rung, nominalKbps: kbps,
                fits: capacityKbps > 0 && Double(kbps) <= capacityKbps * 0.85,
                chosen: rung == pick)
        }
    }

    /// The line a log or the command line should show:
    /// `HQ 990 kbps — too much for this link (530)`.
    public static func label(_ level: Level, capacityKbps: Double) -> String {
        // An unnamed rung has no word to put before its bitrate, and `492 492 kbps` reads as a
        // typo. The number is the name.
        let head =
            level.rung == 2 || level.rung == 3
            ? "\(level.nominalKbps) kbps"
            : "\(level.name) \(level.nominalKbps) kbps"
        guard capacityKbps > 0 else { return head }
        let carried = String(format: "%.0f", capacityKbps)
        if level.fits { return "\(head) — fits (\(carried) available)" }
        if nothingFits(capacityKbps: capacityKbps) && level.rung == 4 {
            return "\(head) — the lowest there is (\(carried) available)"
        }
        return "\(head) — too much for this link (\(carried))"
    }

    /// Whether the link is slower than the bottom rung, which is a different situation from
    /// "this rung is too much": there is nothing lower to go to, and saying "too much for this
    /// link" about the last rung on the ladder accuses a level of a fault it cannot fix.
    public static func nothingFits(capacityKbps: Double, sampleRate: Int = 48000) -> Bool {
        guard capacityKbps > 0 else { return false }
        let ladder = LDACEncoder.ladder(sampleRate: sampleRate)
        guard let floor = ladder.last else { return false }
        return Double(floor) > capacityKbps * 0.85
    }

    /// What a ceiling of this rung would actually produce on this link, in kbit/s.
    ///
    /// This is the answer to "make the three levels dynamic": a level chosen by hand is a ceiling,
    /// and what the listener gets is the highest rung at or below it that the link carries. So
    /// asking for High on a link that carries 530 kbps gives 396 — not 990, which would throw away
    /// half the audio, and not 330, which would leave a third of the link unused.
    ///
    /// Returned here rather than left to the stream because the menu has to say it *before* the
    /// choice is made: a menu that lists 990 kbps next to a link that carries 530 is asking the
    /// listener to work out the consequence themselves.
    public static func wouldUse(
        _ level: Level, capacityKbps: Double,
        sampleRate: Int = 48000
    ) -> Int? {
        guard capacityKbps > 0 else { return nil }
        let ladder = LDACEncoder.ladder(sampleRate: sampleRate)
        let fitted = BitrateAdapter.fitRung(capacityKbps: capacityKbps, sampleRate: sampleRate)
        // The ceiling caps the climb, so the answer is the higher of the two rungs: the one that
        // fits and the one asked for, whichever is lower down the ladder (a larger number).
        let rung = max(fitted, level.rung)
        return rung < ladder.count ? ladder[rung] : nil
    }

    /// The shorter line a *menu* should show, because a menu item is a label and not a sentence.
    ///
    /// The named rungs are spelled out — "High", not "HQ" — because a menu item has room for a
    /// word and a word needs no legend. The unnamed ones have no word, so they show the bitrate,
    /// which is the only thing that distinguishes them. The tick says which one the stream would
    /// pick here, so the menu answers "what will I get?" and not just "what exists?".
    public static func menuLabel(_ level: Level, capacityKbps: Double) -> String {
        // An unnamed rung has no word, so its bitrate *is* its name: printing it twice would read
        // as a mistake, and the number is the only thing there is to say.
        var text =
            level.rung == 2 || level.rung == 3
            ? "\(level.nominalKbps) kbps"
            : "\(level.longName) · \(level.nominalKbps) kbps"
        if level.chosen { text = "✓ " + text }
        if capacityKbps > 0 && !level.fits && nothingFits(capacityKbps: capacityKbps)
            && level.rung == 4
        {
            text += " · the lowest there is"
        } else if capacityKbps > 0 && !level.fits {
            // The nominal bitrate is not what the listener will hear, so the label says what they
            // will: the rung this ceiling settles on here. "990 kbps · too much for this link" is
            // true and useless; "990 kbps · here 396" is the same fact and answers the question.
            if let actual = wouldUse(level, capacityKbps: capacityKbps) {
                text += " · here \(actual) kbps"
            } else {
                text += " · too much for this link"
            }
        }
        return text
    }

    /// The word for a rung, for anywhere a listener reads it.
    ///
    /// "Low", not "Mobile": Sony's word for the bottom rung is Mobile Quality, which names the use
    /// case rather than the thing, and in a list it sorts wrongly and reads ambiguously. The three
    /// words now match the three codes — High/HQ, Standard/SQ, Low/LQ — so the menu and the
    /// command line say the same thing in two lengths.
    public static func longName(_ quality: LDACEncoder.Quality) -> String {
        quality.longName
    }
}
