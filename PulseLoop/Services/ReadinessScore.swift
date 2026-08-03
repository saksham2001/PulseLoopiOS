import Foundation

/// Daily readiness scoring — how recovered the user is this morning, on 0–100.
///
/// Pure and storage-free, in the same spirit as `SleepInsights.swift`: this file consumes a
/// plain-value `ReadinessInputs` and never touches SwiftData. `ReadinessService` owns the fetching.
///
/// Three rules govern everything here, and every one of them exists because the alternative
/// silently invents data:
///
/// 1. **A missing signal is excluded from the denominator, never scored as zero.** A night where
///    the ring dropped its temperature reading is a night scored out of 90 points, not a night
///    that lost 10. Mirrors the doctrine at the top of `SleepInsights.swift`.
/// 2. **A baseline that isn't established yet counts as missing, not as "at baseline".** Scoring a
///    deviation against three days of data would read as authoritative while being noise.
/// 3. **Every contributor carries its own explanation.** The project's stated principle is
///    documented metrics and no black boxes, so a score is never surfaced without the ability to
///    say which signal dragged it down and by how much.
///
/// Contributor weights, band knots, and the reasoning behind them are documented in
/// `docs/project/readiness.md`. Changing any of them requires bumping `algorithmVersion`, which
/// invalidates stored rows rather than silently reinterpreting old scores under new weights.

// MARK: - Inputs

/// One morning's raw signals plus the personal baselines to judge them against. Every field is
/// optional: callers pass what the ring actually captured, and scoring adapts.
struct ReadinessInputs: Equatable {
    /// Mean HRV across the overnight window, in ms.
    var hrv: Double?
    /// 30-day baseline of overnight HRV, excluding the night being scored.
    var hrvBaseline: BaselineStats?

    /// 10th percentile of heart rate across the overnight window, in bpm.
    var restingHeartRate: Double?
    /// The learned resting-HR baseline (`UserProfile.hrRestingBaseline`), in bpm.
    var restingHeartRateBaseline: Double?

    /// `SleepScore.calculate(_:).score` for last night, 0–100. Scored absolutely — `SleepScore`
    /// already encodes population-normal ranges, so a second personal baseline would double-count.
    var sleepScore: Int?

    /// Mean skin temperature across the overnight window, in °C.
    var skinTemperature: Double?
    /// 30-day baseline of overnight skin temperature, excluding the night being scored.
    var skinTemperatureBaseline: BaselineStats?

    /// Yesterday's training load in minutes.
    var priorDayLoadMinutes: Double?
    /// Trailing 7-day mean load in minutes, excluding yesterday.
    var loadBaselineMinutes: Double?

    init(
        hrv: Double? = nil,
        hrvBaseline: BaselineStats? = nil,
        restingHeartRate: Double? = nil,
        restingHeartRateBaseline: Double? = nil,
        sleepScore: Int? = nil,
        skinTemperature: Double? = nil,
        skinTemperatureBaseline: BaselineStats? = nil,
        priorDayLoadMinutes: Double? = nil,
        loadBaselineMinutes: Double? = nil
    ) {
        self.hrv = hrv
        self.hrvBaseline = hrvBaseline
        self.restingHeartRate = restingHeartRate
        self.restingHeartRateBaseline = restingHeartRateBaseline
        self.sleepScore = sleepScore
        self.skinTemperature = skinTemperature
        self.skinTemperatureBaseline = skinTemperatureBaseline
        self.priorDayLoadMinutes = priorDayLoadMinutes
        self.loadBaselineMinutes = loadBaselineMinutes
    }
}

// MARK: - Output

/// One scored signal, carrying both its arithmetic and its explanation.
struct ReadinessContributor: Equatable {
    enum Kind: String, CaseIterable {
        case hrv
        case restingHeartRate
        case sleep
        case skinTemperature
        case trainingLoad

        var title: String {
            switch self {
            case .hrv: return "HRV"
            case .restingHeartRate: return "Resting HR"
            case .sleep: return "Sleep"
            case .skinTemperature: return "Skin temperature"
            case .trainingLoad: return "Training load"
            }
        }

        /// Points this signal is worth when present. Documented in `docs/project/readiness.md`.
        var maxPoints: Double {
            switch self {
            case .hrv: return 30
            case .restingHeartRate: return 25
            case .sleep: return 30
            case .skinTemperature: return 10
            case .trainingLoad: return 5
            }
        }
    }

    let kind: Kind
    let earned: Double
    let maxPoints: Double
    /// The measured value, in the contributor's own unit (ms, bpm, 0–100, °C, ratio).
    let value: Double
    /// The personal baseline it was judged against. nil for `sleep`, which is absolute.
    let baseline: Double?
    /// Signed deviation from baseline, in the contributor's reporting unit (% for HRV, bpm for
    /// resting HR, °C for temperature, a ratio for load). nil for `sleep`.
    let deviation: Double?
    /// Plain-language explanation, e.g. "HRV 12% below your baseline". Never mentions a value that
    /// wasn't measured.
    let detail: String

    /// Points this signal cost. Sorting by this surfaces what actually held the score back.
    var drag: Double { maxPoints - earned }
}

enum ReadinessBand: String, CaseIterable {
    case primed = "Primed"
    case ready = "Ready"
    case moderate = "Moderate"
    case restNeeded = "Rest needed"
}

/// Why a morning couldn't be scored. The distinction matters to the UI: "we're still learning your
/// baseline, day 6 of 14" is a useful empty state, "wear your ring overnight" is a call to action,
/// and conflating them produces a tile that looks broken.
enum ReadinessUnavailableReason: String {
    /// Nothing usable was captured overnight.
    case noSignals
    /// Signals arrived, but the personal baselines they'd be judged against aren't established yet.
    case baselineLearning
    /// Baselines are fine; too little of the night was captured to be worth a number.
    case insufficientCoverage
}

struct ReadinessResult: Equatable {
    let score: Int
    let band: ReadinessBand
    /// Scored contributors, biggest drag first.
    let contributors: [ReadinessContributor]
    /// What couldn't be scored, in canonical order.
    let missing: [ReadinessContributor.Kind]
    /// Points actually available this morning — the denominator the score was taken over.
    let availablePoints: Double

    /// How much of the full 100-point picture this score is based on. Surfaced so a 78 from a
    /// partial night is never presented as equivalent to a 78 from a complete one.
    var coverage: Double { availablePoints / 100 }
}

enum ReadinessOutcome: Equatable {
    case scored(ReadinessResult)
    case unavailable(ReadinessUnavailableReason)
}

// MARK: - Scoring

enum ReadinessScore {
    /// Bumping this invalidates stored `ReadinessDaily` rows so they recompute, rather than letting
    /// old scores be reinterpreted under new weights. Changing weights or knots REQUIRES a bump,
    /// and an update to `docs/project/readiness.md`.
    static let algorithmVersion = 1

    /// Below this many available points a score would be more suggestion than measurement.
    static let minAvailablePoints: Double = 50

    /// Where the "soft" knot sits as a fraction of a contributor's points. Deliberately harsher
    /// than `SleepScore.bandScore`'s 0.65: a recovery score that never drops below 65 tells you
    /// nothing on the days you most need it to.
    static let softFraction: Double = 0.55

    static func band(_ score: Int) -> ReadinessBand {
        if score >= 85 { return .primed }
        if score >= 70 { return .ready }
        if score >= 55 { return .moderate }
        return .restNeeded
    }

    static func evaluate(_ inputs: ReadinessInputs) -> ReadinessOutcome {
        var contributors: [ReadinessContributor] = []
        var missing: [ReadinessContributor.Kind] = []
        /// Did any signal arrive but get dropped purely because its baseline wasn't ready? That is
        /// "still learning", which is a different — and recoverable — story from "no data".
        var awaitingBaseline = false
        /// Did anything usable arrive at all? Distinguishes "ring not worn" from "ring worn, thin night".
        var sawAnySignal = false

        func admit(_ contributor: ReadinessContributor?, kind: ReadinessContributor.Kind) {
            if let contributor {
                contributors.append(contributor)
            } else {
                missing.append(kind)
            }
        }

        // HRV — relative to the user's own 30-day median, in percent.
        if let value = inputs.hrv, value.isFinite, value > 0 {
            sawAnySignal = true
            if let baseline = usableBaseline(inputs.hrvBaseline) {
                let deviation = ((value - baseline) / baseline) * 100
                admit(
                    ReadinessContributor(
                        kind: .hrv,
                        earned: lowerIsWorse(deviation, ideal: 0, soft: -15, hard: -40,
                                             points: ReadinessContributor.Kind.hrv.maxPoints),
                        maxPoints: ReadinessContributor.Kind.hrv.maxPoints,
                        value: value,
                        baseline: baseline,
                        deviation: deviation,
                        detail: relativeDetail("HRV", deviation, unit: .percent)
                    ),
                    kind: .hrv
                )
            } else {
                awaitingBaseline = true
                missing.append(.hrv)
            }
        } else {
            missing.append(.hrv)
        }

        // Resting HR — bpm above the learned baseline. Below baseline is never penalized.
        if let value = inputs.restingHeartRate, value.isFinite, value > 0 {
            sawAnySignal = true
            if let baseline = inputs.restingHeartRateBaseline, baseline.isFinite, baseline > 0 {
                let deviation = value - baseline
                admit(
                    ReadinessContributor(
                        kind: .restingHeartRate,
                        earned: higherIsWorse(deviation, ideal: 0, soft: 5, hard: 12,
                                              points: ReadinessContributor.Kind.restingHeartRate.maxPoints),
                        maxPoints: ReadinessContributor.Kind.restingHeartRate.maxPoints,
                        value: value,
                        baseline: baseline,
                        deviation: deviation,
                        detail: relativeDetail("Resting HR", deviation, unit: .bpm)
                    ),
                    kind: .restingHeartRate
                )
            } else {
                awaitingBaseline = true
                missing.append(.restingHeartRate)
            }
        } else {
            missing.append(.restingHeartRate)
        }

        // Sleep — absolute, since `SleepScore` already encodes population-normal ranges.
        if let sleepScore = inputs.sleepScore, sleepScore > 0 {
            sawAnySignal = true
            let value = Double(sleepScore)
            contributors.append(
                ReadinessContributor(
                    kind: .sleep,
                    earned: lowerIsWorse(value, ideal: 88, soft: 65, hard: 30,
                                         points: ReadinessContributor.Kind.sleep.maxPoints),
                    maxPoints: ReadinessContributor.Kind.sleep.maxPoints,
                    value: value,
                    baseline: nil,
                    deviation: nil,
                    detail: "Sleep score \(sleepScore)"
                )
            )
        } else {
            missing.append(.sleep)
        }

        // Skin temperature — symmetric: a deviation in either direction is a signal.
        if let value = inputs.skinTemperature, value.isFinite, value > 0 {
            sawAnySignal = true
            if let baseline = usableBaseline(inputs.skinTemperatureBaseline) {
                let deviation = value - baseline
                admit(
                    ReadinessContributor(
                        kind: .skinTemperature,
                        earned: higherIsWorse(abs(deviation), ideal: 0.2, soft: 0.6, hard: 1.2,
                                              points: ReadinessContributor.Kind.skinTemperature.maxPoints),
                        maxPoints: ReadinessContributor.Kind.skinTemperature.maxPoints,
                        value: value,
                        baseline: baseline,
                        deviation: deviation,
                        detail: relativeDetail("Skin temperature", deviation, unit: .celsius)
                    ),
                    kind: .skinTemperature
                )
            } else {
                awaitingBaseline = true
                missing.append(.skinTemperature)
            }
        } else {
            missing.append(.skinTemperature)
        }

        // Training load — yesterday's minutes as a ratio of the trailing week.
        if let value = inputs.priorDayLoadMinutes, value.isFinite, value >= 0 {
            sawAnySignal = true
            if let baseline = inputs.loadBaselineMinutes, baseline.isFinite, baseline > 0 {
                let ratio = value / baseline
                admit(
                    ReadinessContributor(
                        kind: .trainingLoad,
                        earned: higherIsWorse(ratio, ideal: 1.2, soft: 1.8, hard: 3.0,
                                              points: ReadinessContributor.Kind.trainingLoad.maxPoints),
                        maxPoints: ReadinessContributor.Kind.trainingLoad.maxPoints,
                        value: value,
                        baseline: baseline,
                        deviation: ratio,
                        detail: loadDetail(ratio)
                    ),
                    kind: .trainingLoad
                )
            } else {
                awaitingBaseline = true
                missing.append(.trainingLoad)
            }
        } else {
            missing.append(.trainingLoad)
        }

        guard sawAnySignal else { return .unavailable(.noSignals) }

        let available = contributors.reduce(0) { $0 + $1.maxPoints }
        // HRV and sleep are the two signals that actually describe recovery. Resting HR and
        // temperature qualify them; load and temperature alone would be a fitness score, not a
        // readiness one.
        let hasCoreSignal = contributors.contains { $0.kind == .hrv || $0.kind == .sleep }

        guard available >= minAvailablePoints, hasCoreSignal else {
            return .unavailable(awaitingBaseline ? .baselineLearning : .insufficientCoverage)
        }

        let earned = contributors.reduce(0) { $0 + $1.earned }
        let score = Int(clamp(((earned / available) * 100).rounded(), 0, 100))

        // Biggest drag first, falling back to declaration order so equal drags stay deterministic.
        let ordering = Dictionary(
            uniqueKeysWithValues: ReadinessContributor.Kind.allCases.enumerated().map { ($1, $0) }
        )
        let ranked = contributors.sorted {
            $0.drag == $1.drag
                ? (ordering[$0.kind] ?? 0) < (ordering[$1.kind] ?? 0)
                : $0.drag > $1.drag
        }

        return .scored(
            ReadinessResult(
                score: score,
                band: band(score),
                contributors: ranked,
                missing: ReadinessContributor.Kind.allCases.filter { missing.contains($0) },
                availablePoints: available
            )
        )
    }

    // MARK: - Band shaping

    /// Full points at or above `ideal`, `softFraction` of them at `soft`, zero at or below `hard`,
    /// linear between the knots. Requires `ideal > soft > hard`.
    ///
    /// Deliberately not a reuse of `SleepScore.bandScore`, which is two-sided and absolute — every
    /// readiness contributor except sleep is a one-sided deviation from a personal baseline.
    private static func lowerIsWorse(
        _ value: Double, ideal: Double, soft: Double, hard: Double,
        points: Double, softFraction: Double = ReadinessScore.softFraction
    ) -> Double {
        guard value.isFinite, ideal > soft, soft > hard else { return 0 }
        if value >= ideal { return points }
        if value <= hard { return 0 }
        let softPoints = points * softFraction
        if value >= soft {
            // Between soft and ideal: softPoints → points.
            return softPoints + (points - softPoints) * ((value - soft) / (ideal - soft))
        }
        // Between hard and soft: 0 → softPoints.
        return softPoints * ((value - hard) / (soft - hard))
    }

    /// Mirror of `lowerIsWorse` for signals where a rise is the bad direction. Requires
    /// `ideal < soft < hard`. Implemented by negation so the two curves cannot drift apart.
    private static func higherIsWorse(
        _ value: Double, ideal: Double, soft: Double, hard: Double,
        points: Double, softFraction: Double = ReadinessScore.softFraction
    ) -> Double {
        lowerIsWorse(-value, ideal: -ideal, soft: -soft, hard: -hard,
                     points: points, softFraction: softFraction)
    }

    // MARK: - Helpers

    /// A baseline is usable only once `BaselineStats` considers it established (roughly a week of
    /// wear, ≥20 samples) and its median is a positive number we can divide by.
    private static func usableBaseline(_ stats: BaselineStats?) -> Double? {
        guard let stats, stats.isEstablished else { return nil }
        let median = stats.median
        guard median.isFinite, median > 0 else { return nil }
        return median
    }

    private enum DeviationUnit {
        case percent, bpm, celsius

        /// Deviations smaller than this read as "at baseline" rather than as a rounded-to-zero
        /// delta — "HRV 0% below your baseline" is noise dressed up as a finding.
        var epsilon: Double {
            switch self {
            case .percent: return 0.5
            case .bpm: return 0.5
            case .celsius: return 0.05
            }
        }

        func format(_ magnitude: Double) -> String {
            switch self {
            case .percent: return "\(Int(magnitude.rounded()))%"
            case .bpm: return "\(Int(magnitude.rounded())) bpm"
            case .celsius: return String(format: "%.1f °C", magnitude)
            }
        }
    }

    private static func relativeDetail(_ label: String, _ deviation: Double, unit: DeviationUnit) -> String {
        guard deviation.isFinite, abs(deviation) >= unit.epsilon else {
            return "\(label) at your baseline"
        }
        let direction = deviation < 0 ? "below" : "above"
        return "\(label) \(unit.format(abs(deviation))) \(direction) your baseline"
    }

    private static func loadDetail(_ ratio: Double) -> String {
        guard ratio.isFinite else { return "Training load unknown" }
        if ratio <= 1.2 { return "Yesterday's load in your usual range" }
        return String(format: "Yesterday's load %.1f× your usual", ratio)
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, value))
    }
}
