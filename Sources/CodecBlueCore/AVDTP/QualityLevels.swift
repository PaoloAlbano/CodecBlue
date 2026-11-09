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
    /// The three levels the menu offers: HQ, SQ and LQ, and nothing else.
    ///
    /// Asked 2026-11-09: "we said we would leave only HQ, SQ, LQ, and when the stream starts the
    /// kbps would appear beside them — why haven't you done it yet?" Because the two unnamed rungs
    /// were still in the list, each needing a sentence to explain where it sat, and a menu of five
    /// where two need explaining is a menu of three plus an argument.
    ///
    /// The unnamed rungs are not a loss. They exist so the adapter can land between SQ and LQ when
    /// a link carries ~450 kbps, and that is a decision the stream makes for itself — it is not a
    /// preference anyone expresses by hand. Choosing "HQ" on such a link still ends up on 492.
    public static func menuLevels(capacityKbps: Double, sampleRate: Int = 48000) -> [Level] {
        describe(capacityKbps: capacityKbps, sampleRate: sampleRate)
            .filter { $0.rung == 0 || $0.rung == 1 || $0.rung == 4 }
    }

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

    /// The line a log or the command line should show: `HQ 396 kbps — capped by this link (530)`.
    ///
    /// Same rule as `menuLabel`: the number is what the listener gets, not what the rung asks for.
    /// A line that says "HQ 990 kbps — too much for this link" is asking the reader to do the
    /// division that the code has already done.
    public static func label(_ level: Level, capacityKbps: Double) -> String {
        let effective = wouldUse(level, capacityKbps: capacityKbps)
        let number = effective ?? level.nominalKbps
        // An unnamed rung has no word to put before its bitrate, and `492 492 kbps` reads as a
        // typo. The number is the name.
        let named = level.rung != 2 && level.rung != 3
        let head = named ? "\(level.name) \(number) kbps" : "\(number) kbps"
        // Same rule as the menu: no measurement, no bitrate next to a name — but the unnamed rungs
        // keep their number, because it is their name and not a claim about the link.
        guard capacityKbps > 0 else { return named ? level.name : head }
        let carried = String(format: "%.0f", capacityKbps)
        if let effective, effective != level.nominalKbps {
            return "\(head) — capped by this link (\(carried) available)"
        }
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
    public static func menuLabel(
        _ level: Level, capacityKbps: Double, streaming: Bool = false, playingKbps: Int? = nil
    ) -> String {
        // The number shown is what the listener will *get*, not what the rung asks for.
        //
        // Reported 2026-11-09: "instead of showing HQ 990 kbps — too much for this link, if you
        // know the max is 336 show HQ with 336 and don't show me the 990 one". That is the right
        // rule and the earlier version had it backwards: it printed the codec's request and then
        // appended a verdict, which made every line read as a promise followed by an apology.
        //
        // A level is a ceiling, so what it produces here is `wouldUse` — the highest rung at or
        // below it that this link carries. When nothing has been measured there is no "here", and
        // the label falls back to the codec's own number, labelled as such.
        let effective = wouldUse(level, capacityKbps: capacityKbps)
        let number = effective ?? level.nominalKbps

        // Before a measurement, the named rungs show only their name.
        //
        // Asked 2026-11-09: "show just HQ without kbps, and when streaming starts we can update the
        // menu to show the value". Right, and for a reason worth writing down: a bitrate next to a
        // name is a claim about this link, and before a stream there is no link to make it about.
        // "HQ · 990 kbps" was read as a promise precisely because it sat where a measurement goes.
        // A name alone promises nothing.
        //
        // The numbers appear when there is something to say with them: a stream running, or a
        // measurement. Asked 2026-11-09: "show just HQ without kbps, and when streaming starts we
        // can update the menu to show the value". A name alone claims nothing about this link; a
        // name with a bitrate is a claim, and it is only worth making once a link exists.
        //
        // The unnamed rungs are the exception, and it took a report to see it: "in the quality list
        // I see two 'between Standard and Low' that do not make much sense to see". Two identical
        // lines, because rungs 2 and 3 sit in the same place. For a rung with no name the bitrate
        // is not a claim about the link — it *is* the name, and hiding it leaves nothing.
        // `playingKbps` wins when it is there: it is the one number that is a measurement rather
        // than a table lookup, and it is what the listener is actually hearing.
        let showNumbers = capacityKbps > 0 || streaming
        var text: String
        switch level.rung {
        case 2, 3:
            // The two unnamed rungs are not offered any more, so this is only reached by the
            // command line. Their number is their whole name; the position was noise.
            text = "\(number) kbps"
        default:
            if let playingKbps {
                text = "\(level.longName) · \(playingKbps) kbps"
            } else {
                text = showNumbers ? "\(level.longName) · \(number) kbps" : level.longName
            }
        }
        if capacityKbps > 0, effective != nil, effective != level.nominalKbps {
            // Said once, at the end, and only when the two differ: "High · 330 kbps" on its own
            // would look like a typo to anyone who knows HQ is 990.
            text += " · capped by this link"
        }
        if capacityKbps <= 0 { return text }
        if level.chosen { text = "✓ " + text }
        if nothingFits(capacityKbps: capacityKbps) && level.rung == 4 {
            text += " · the lowest there is"
        }
        return text
    }
}
