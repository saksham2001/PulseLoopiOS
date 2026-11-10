import Foundation

/// A stress figure derived from HRV, for rings whose hardware never reports one (Android #71, #67).
///
/// Some rings advertise stress (the capability list is a static per-family constant) but never answer
/// the stress query — the R100 sent 22 requests and got 0 replies — so the card could never fill. Those
/// rings do return plenty of HRV, and stress is conventionally read from HRV, so the number is derivable.
///
/// **It is an inference, and it is labelled as one wherever it is shown** (the ESTIMATED chip on the
/// card, a disclaimer on the detail screen). And it never replaces a ring's own stress: callers derive
/// only when the store holds no stress reading at all.
///
/// The rule is relative to the person, not a population: HRV varies several-fold between people, so an
/// absolute cutoff would label whole people permanently stressed or calm. A reading is scored against
/// that user's own recent HRV — 50 at their median, moving inversely with HRV (lower than usual reads as
/// more stress), scaled by their own spread so naturally steady HRV isn't pinned to the middle.
enum DerivedStress {

    /// Fewer readings than this and the baseline isn't that person's normal, it's a coincidence.
    static let minBaselineSamples = 12

    /// The baseline is the most recent readings before the scored one, capped so a month of 5-minute
    /// HRV (thousands of readings) scores in linear-ish time rather than re-sorting all history per
    /// point. 500 readings is well over a day of all-day monitoring — still "your recent normal".
    static let maxBaselineSamples = 500

    /// How far from the median, in units of the baseline's own spread, maps to the ends of the scale.
    /// Two is the conventional "unusual for you" distance and keeps ordinary days off 0 / 100.
    private static let spreadAtFullScale = 2.0

    /// A 0–100 stress score (higher = more stress) for `hrv` against `baseline` (the user's recent
    /// HRV), or nil when the baseline is too thin to mean anything — an unearned number on a health
    /// screen reads as a measurement.
    static func score(hrv: Double, baseline: [Double]) -> Int? {
        guard hrv > 0 else { return nil }
        let usable = baseline.filter { $0 > 0 }
        guard usable.count >= minBaselineSamples, let median = median(usable), median > 0 else { return nil }
        // Median absolute deviation: a spread a few wild readings can't drag around (ring HRV history
        // has obvious outliers).
        guard let mad = Self.median(usable.map { abs($0 - median) }) else { return nil }
        // A perfectly flat baseline has no spread; fall back to a proportion of the median so the score
        // still responds rather than snapping between 0 and 100.
        let spread = mad > 0 ? mad : median * 0.1
        guard spread > 0 else { return nil }
        let deviations = (median - hrv) / spread          // positive = HRV below normal = more stress
        let scaled = 50 + 50 * (deviations / spreadAtFullScale)
        return Int(min(100, max(0, scaled)))
    }

    /// Each HRV reading scored against the (up to `maxBaselineSamples`) readings before it — what the
    /// app could have said at the time, not hindsight — paired with the index of the HRV reading it came
    /// from. The first readings score nil (too thin a baseline), so the output is shorter than the input;
    /// the index is what lets a chart place each score at its HRV reading's time.
    static func scored(_ hrv: [Double]) -> [(index: Int, score: Int)] {
        hrv.indices.compactMap { i in
            score(hrv: hrv[i], baseline: Array(hrv[max(0, i - maxBaselineSamples)..<i])).map { (index: i, score: $0) }
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
