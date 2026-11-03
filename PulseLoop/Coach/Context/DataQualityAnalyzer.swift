import Foundation

/// Builds the first-class data-quality warnings that ride in the context packet,
/// keeping the spirit of the web app's warnings so the coach never over-claims.
enum DataQualityAnalyzer {
    /// The caveat for a night whose ring reported **no** REM stage — jring's `0x11` timeline is
    /// light/deep/awake only.
    static let sleepDecoderNoteWithoutREM =
        "Sleep stage decoding is experimental — this ring reports light/deep/awake only, with no REM; "
        + "awake time may read as zero."

    /// The caveat for a night that **does** carry REM (Colmi big-data stage `0x04`, YCBT tag `3`).
    /// Still hedged — the staging is the ring firmware's, not a validated sleep-lab classifier — but it
    /// no longer denies data the app actually has.
    static let sleepDecoderNoteWithREM =
        "Sleep stages come from the ring's own firmware, not a validated classifier — treat the split as "
        + "approximate; awake time may read as zero."

    /// Picks the caveat that matches what this night actually contains.
    ///
    /// Keyed off the night's own stage blocks rather than the connected ring's capabilities: stored
    /// nights outlive the ring that recorded them, so a user who switches rings must not have older
    /// REM data disclaimed away (or newer REM data denied) by whatever happens to be paired today.
    static func sleepDecoderNote(hasREM: Bool) -> String {
        hasREM ? sleepDecoderNoteWithREM : sleepDecoderNoteWithoutREM
    }

    struct Inputs {
        var profileCompleteness: String       // empty | partial | complete
        var daysAvailable: Int
        var hasSleep: Bool
        /// Whether the night behind `hasSleep` carried a REM stage. Ignored when `hasSleep` is false.
        var sleepHasREM: Bool = false
        var lastSyncAt: Date?
        var isDemo: Bool
    }

    static func warnings(_ input: Inputs, now: Date = Date()) -> [String] {
        var out: [String] = []

        if input.isDemo {
            out.append("This is demo/sample data, not live readings from the ring.")
        }

        if input.profileCompleteness != "complete" {
            out.append(
                "User profile is incomplete (missing age/height/weight). "
                + "Don't compute personalized HR zones, BMI, or weight targets."
            )
        }

        if input.daysAvailable <= 3 {
            out.append(
                "Only \(input.daysAvailable) day(s) of activity data available — "
                + "trends are limited; avoid strong week-over-week claims."
            )
        }

        if input.hasSleep {
            out.append(sleepDecoderNote(hasREM: input.sleepHasREM))
        }

        if !input.isDemo {
            if let last = input.lastSyncAt {
                let hours = Int(now.timeIntervalSince(last) / 3600)
                if hours >= 12 {
                    out.append("Ring hasn't synced in ~\(hours)h — today's data may be stale.")
                }
            } else {
                out.append("No recent ring sync recorded — data may be incomplete.")
            }
        }

        out.append("Ring HR and SpO₂ are wellness signals, not medical-grade measurements; do not diagnose.")
        return out
    }
}
