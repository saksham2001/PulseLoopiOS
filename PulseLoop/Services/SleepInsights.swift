import Foundation

/// Range-aware sleep scoring + interpretation, ported 1:1 from the web app's
/// `frontend/src/lib/sleepScore.ts` and `frontend/src/lib/sleep.ts`.
///
/// All logic is pure and data-honest: missing nights are never treated as zero,
/// averages are taken over valid nights only, and nothing falls back to a stale
/// prior night.

// MARK: - Sleep score

enum SleepQualityLabel: String {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case needsWork = "Needs work"
}

/// One scored signal within a night's sleep score, in the shape `ReadinessContributor` uses: what it
/// earned, what it could have earned, and a sentence explaining the number.
struct SleepContributor: Equatable {
    enum Kind: String, CaseIterable {
        case duration
        case deep
        case rem
        case restfulness
        case timing

        var title: String {
            switch self {
            case .duration: return "Duration"
            case .deep: return "Deep sleep"
            case .rem: return "REM sleep"
            case .restfulness: return "Restfulness"
            case .timing: return "Bedtime consistency"
            }
        }

        var maxPoints: Double {
            switch self {
            case .duration: return 30
            case .deep: return 25
            case .rem: return 20
            case .restfulness: return 15
            case .timing: return 10
            }
        }
    }

    let kind: Kind
    let earned: Double
    let maxPoints: Double
    let detail: String
}

struct SleepScoreResult {
    let score: Int
    let label: SleepQualityLabel
    let deepPct: Int
    let lightPct: Int
    /// nil when there is no usable awake signal.
    let awakePct: Int?
    /// nil on a night whose ring reported no REM stage at all — distinct from `0`, which would claim
    /// the user slept no REM.
    let remPct: Int?
    /// Total sleep time: time in bed minus the minutes tagged awake.
    let asleepMinutes: Int
    /// The scored signals, in display order. Only those the night actually had.
    let contributors: [SleepContributor]
    /// Fraction of the full 100-point picture this score was based on. A 78 from a partial night is
    /// never silently presented as equivalent to a 78 from a complete one.
    let coverage: Double
    let algorithmVersion: Int
}

/// The user's own recent bedtime, for the consistency contributor.
///
/// A separate type so `SleepScore.calculate` stays a pure function: the caller resolves the history,
/// the scorer just reads it.
struct BedtimeBaseline: Equatable {
    /// Median minutes-past-midnight of recent bedtimes, on a −12…+12 h axis centred on midnight so
    /// a 23:40 and a 00:20 bedtime average to midnight rather than to noon.
    let medianMinutesFromMidnight: Double
    let nights: Int

    /// Enough history to call a bedtime "usual". Matches the 7-night floor `BaselineStats` uses.
    static let minNights = 7
    var isEstablished: Bool { nights >= Self.minNights }

    /// Minutes past midnight on the wrapped axis: 23:00 → −60, 01:00 → +60.
    static func minutesFromMidnight(_ date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let raw = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        return raw > 12 * 60 ? raw - 24 * 60 : raw
    }

    /// Builds from prior nights' start times. Returns nil when there are none.
    static func compute(bedtimes: [Date], calendar: Calendar = .current) -> BedtimeBaseline? {
        guard !bedtimes.isEmpty else { return nil }
        let values = bedtimes.map { minutesFromMidnight($0, calendar: calendar) }.sorted()
        let mid = values.count / 2
        let median = values.count.isMultiple(of: 2)
            ? (values[mid - 1] + values[mid]) / 2
            : values[mid]
        return BedtimeBaseline(medianMinutesFromMidnight: median, nights: values.count)
    }
}

enum SleepScore {
    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, value))
    }

    private static func bandScore(
        _ value: Double,
        idealLow: Double, idealHigh: Double,
        softLow: Double, softHigh: Double,
        hardLow: Double, hardHigh: Double,
        points: Double
    ) -> Double {
        guard value.isFinite else { return 0 }
        if value >= idealLow && value <= idealHigh { return points }
        if value < idealLow && value >= softLow {
            return points * (0.65 + 0.35 * ((value - softLow) / (idealLow - softLow)))
        }
        if value > idealHigh && value <= softHigh {
            return points * (0.65 + 0.35 * ((softHigh - value) / (softHigh - idealHigh)))
        }
        if value < softLow {
            return points * 0.65 * clamp((value - hardLow) / (softLow - hardLow), 0, 1)
        }
        return points * 0.65 * clamp((hardHigh - value) / (hardHigh - softHigh), 0, 1)
    }

    /// Awake share → points. Non-optional now: a night with no usable wake signal drops the
    /// contributor entirely rather than scoring it at a fraction, so there is no absent case here.
    static func awakeScore(_ awakePct: Double, points: Double) -> Double {
        guard awakePct.isFinite else { return 0 }
        if awakePct <= 10 { return points }
        if awakePct <= 20 { return points * (1 - 0.65 * ((awakePct - 10) / 10)) }
        return points * 0.35 * clamp((35 - awakePct) / 15, 0, 1)
    }

    static func qualityLabel(_ score: Int) -> SleepQualityLabel {
        if score >= 85 { return .excellent }
        if score >= 70 { return .good }
        if score >= 55 { return .fair }
        return .needsWork
    }

    /// Bumped whenever a threshold or weight changes, so a stored score is never reinterpreted under
    /// a different algorithm than the one that produced it.
    static let algorithmVersion = 2

    /// A score is only produced when at least this many points were available.
    static let minAvailablePoints: Double = 50

    /// Scores a night out of 100 across five contributors — duration (30), deep % (25), REM % (20),
    /// restfulness (15) and bedtime consistency (10).
    ///
    /// **Missing signals leave the denominator, they are never scored as zero.** A jring reports no
    /// REM stage at all, so its nights are scored out of 80 rather than penalised 20; the same
    /// applies to bedtime consistency until a week of history exists. `coverage` reports what
    /// fraction of the full picture the number rests on. This is the rule readiness already follows,
    /// and it is what makes one score comparable across a jring and a Colmi.
    ///
    /// Two deliberate departures from v1:
    ///
    /// - **Duration is now total sleep time, not time in bed.** `SleepSession.totalMinutes` is the
    ///   wall-clock span (`SleepSegmentation` sets it from `end − start`), so v1 credited a night
    ///   with 8 h in bed and 90 min awake as 8 h of sleep. Awake minutes now come off the top.
    /// - **Light % is reported but no longer scored.** Once deep and REM are both scored, light is
    ///   their residual — scoring it too would count the same night twice, and its v1 band (ideal
    ///   50–60 %) was calibrated for a no-REM decoder that lumped REM into light.
    ///
    /// Sleep *efficiency* is deliberately absent for the same reason: with `totalMinutes` being time
    /// in bed, efficiency is exactly `1 − awake %`, so it would restate restfulness rather than add
    /// a signal.
    static func calculate(_ sleep: SleepSummary, bedtimeBaseline: BedtimeBaseline? = nil) -> SleepScoreResult {
        let timeInBed = sleep.session.totalMinutes > 0 ? Double(sleep.session.totalMinutes) : 0
        let deep = Double(max(0, sleep.deepMinutes))
        let light = Double(max(0, sleep.lightMinutes))
        let awake = Double(max(0, sleep.awakeMinutes))
        let rem = Double(max(0, sleep.remMinutes))

        // "Did the timeline account for essentially the whole night?" REM belongs in this sum: on a
        // REM-capable ring (Colmi big-data stage `0x04`, YCBT tag `3`) it is typically 20–25 % of the
        // night, so omitting it made a fully-described night look 75 % covered and cost it its awake
        // reading. jring rings, whose `0x11` timeline has no REM stage, are unaffected.
        let coveredStageMin = sleep.blocks.reduce(0.0) { sum, block in
            switch block.stage {
            case .deep, .light, .awake, .rem: return sum + Double(max(0, block.durationMinutes))
            case .unknown: return sum
            }
        }
        let hasAwakeSignal =
            sleep.blocks.contains { $0.stage == .awake } ||
            awake > 0 ||
            (timeInBed > 0 && coveredStageMin >= timeInBed * 0.95)

        // Total sleep time. Without an awake signal the best available answer is the whole span —
        // stated here rather than left implicit, because it makes duration read slightly generous on
        // a ring that can't see wake.
        let asleep = hasAwakeSignal ? max(0, timeInBed - awake) : timeInBed
        let deepPct = timeInBed > 0 ? (deep / timeInBed) * 100 : 0
        let lightPct = timeInBed > 0 ? (light / timeInBed) * 100 : 0
        let awakePct: Double? = (timeInBed > 0 && hasAwakeSignal) ? (awake / timeInBed) * 100 : nil
        let remPct: Double? = (timeInBed > 0 && sleep.hasRemSignal) ? (rem / timeInBed) * 100 : nil

        var contributors: [SleepContributor] = []

        // Duration — 7–9 h ideal, the adult range every major guideline agrees on.
        contributors.append(SleepContributor(
            kind: .duration,
            earned: bandScore(asleep / 60, idealLow: 7, idealHigh: 9, softLow: 6, softHigh: 9.5,
                              hardLow: 4, hardHigh: 12, points: SleepContributor.Kind.duration.maxPoints),
            maxPoints: SleepContributor.Kind.duration.maxPoints,
            detail: "\(SleepFormat.duration(Int(asleep.rounded()))) asleep"
        ))

        // Deep — 13–23 % of the night, carried over from v1 unchanged.
        if timeInBed > 0 {
            contributors.append(SleepContributor(
                kind: .deep,
                earned: bandScore(deepPct, idealLow: 13, idealHigh: 23, softLow: 5, softHigh: 35,
                                  hardLow: 0, hardHigh: 45, points: SleepContributor.Kind.deep.maxPoints),
                maxPoints: SleepContributor.Kind.deep.maxPoints,
                detail: "\(Int(deepPct.rounded()))% of the night"
            ))
        }

        // REM — 20–25 % is the usual adult share. Absent entirely on a ring with no REM stage.
        if let remPct {
            contributors.append(SleepContributor(
                kind: .rem,
                earned: bandScore(remPct, idealLow: 20, idealHigh: 25, softLow: 15, softHigh: 30,
                                  hardLow: 5, hardHigh: 40, points: SleepContributor.Kind.rem.maxPoints),
                maxPoints: SleepContributor.Kind.rem.maxPoints,
                detail: "\(Int(remPct.rounded()))% of the night"
            ))
        }

        // Restfulness — how much of the night was spent awake. Withheld, not guessed, when the ring
        // gave no usable wake signal (v1 scored it at 55 % of the points in that case, which quietly
        // penalised every jring night).
        if let awakePct {
            contributors.append(SleepContributor(
                kind: .restfulness,
                earned: awakeScore(awakePct, points: SleepContributor.Kind.restfulness.maxPoints),
                maxPoints: SleepContributor.Kind.restfulness.maxPoints,
                detail: "\(Int(awakePct.rounded()))% awake"
            ))
        }

        // Bedtime consistency — how far this night's bedtime sat from the user's own recent median.
        if let baseline = bedtimeBaseline, baseline.isEstablished {
            let drift = abs(BedtimeBaseline.minutesFromMidnight(sleep.session.startAt) - baseline.medianMinutesFromMidnight)
            contributors.append(SleepContributor(
                kind: .timing,
                earned: timingScore(driftMinutes: drift, points: SleepContributor.Kind.timing.maxPoints),
                maxPoints: SleepContributor.Kind.timing.maxPoints,
                detail: drift < 15
                    ? "In line with your usual bedtime"
                    : "\(Int(drift.rounded())) min from your usual bedtime"
            ))
        }

        let available = contributors.reduce(0) { $0 + $1.maxPoints }
        let earned = contributors.reduce(0) { $0 + $1.earned }
        // Below the floor there isn't enough of a night to describe; score 0 rather than inflate a
        // fragment into a full-looking number.
        let score = available >= minAvailablePoints
            ? Int(clamp((earned / available * 100).rounded(), 0, 100))
            : 0

        return SleepScoreResult(
            score: score,
            label: qualityLabel(score),
            deepPct: Int(deepPct.rounded()),
            lightPct: Int(lightPct.rounded()),
            awakePct: awakePct.map { Int($0.rounded()) },
            remPct: remPct.map { Int($0.rounded()) },
            asleepMinutes: Int(asleep.rounded()),
            contributors: contributors,
            coverage: available / 100,
            algorithmVersion: algorithmVersion
        )
    }

    /// Bedtime drift → points. Full marks within 30 minutes of your usual, 55 % at an hour, nothing
    /// at two hours or more.
    ///
    /// The 30-minute knot is where circadian-regularity research stops calling a schedule regular;
    /// the two-hour floor is roughly a timezone, by which point the night is a different night.
    static func timingScore(driftMinutes: Double, points: Double) -> Double {
        guard driftMinutes.isFinite else { return 0 }
        if driftMinutes <= 30 { return points }
        if driftMinutes <= 60 {
            return points * (1 - 0.45 * ((driftMinutes - 30) / 30))
        }
        return points * 0.55 * clamp((120 - driftMinutes) / 60, 0, 1)
    }
}

// MARK: - Formatting

enum SleepFormat {
    static func duration(_ minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return "—" }
        let h = minutes / 60
        let m = minutes % 60
        if h <= 0 { return "\(m)m" }
        return "\(h)h \(String(format: "%02d", m))m"
    }

    private static let clockTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static func clockTime(_ date: Date) -> String {
        clockTimeFormatter.string(from: date)
    }
}

// MARK: - Coach interpretation

struct SleepCoach {
    let headline: String
    let body: String
    let chips: [String]
}

struct SleepNoDataState {
    let label: String
    let value: String
    let support: String
}

enum SleepInsights {
    static let rangeHeroLabel: [SleepRangeKey: String] = [
        .day: "Last Sleep",
        .week: "AVG Weekly Sleep",
        .month: "AVG Monthly Sleep",
        .year: "AVG Yearly Sleep"
    ]

    private static let minAggNights = 2

    static func validSessions(_ sessions: [SleepSummary]) -> [SleepSummary] {
        sessions.filter { $0.session.totalMinutes > 0 }
    }

    /// Collapse each calendar (waking) day's sessions into ONE combined `SleepSummary` so
    /// that a main night plus daytime naps count as a single tracked day for aggregate math.
    ///
    /// Pure and deterministic. Days with exactly one session pass through unchanged. For days
    /// with multiple sessions, stage minutes are summed, blocks are concatenated (sorted by
    /// `startAt`), and a combined detached `SleepSession` carries the day's start-of-day date,
    /// earliest `startAt`, latest `endAt`, the SUM of `totalMinutes` (total time asleep across
    /// the day, not the wall-clock span), and a duration-weighted average of non-nil scores.
    /// The result is sorted by session date.
    static func collapseByDay(_ sessions: [SleepSummary]) -> [SleepSummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.session.date) }

        var collapsed: [SleepSummary] = []
        collapsed.reserveCapacity(grouped.count)

        for (day, daySessions) in grouped {
            guard daySessions.count > 1 else {
                if let only = daySessions.first { collapsed.append(only) }
                continue
            }

            let lightMinutes = daySessions.reduce(0) { $0 + $1.lightMinutes }
            let deepMinutes = daySessions.reduce(0) { $0 + $1.deepMinutes }
            let awakeMinutes = daySessions.reduce(0) { $0 + $1.awakeMinutes }
            let remMinutes = daySessions.reduce(0) { $0 + $1.remMinutes }
            let blocks = daySessions.flatMap { $0.blocks }.sorted { $0.startAt < $1.startAt }

            let totalMinutes = daySessions.reduce(0) { $0 + $1.session.totalMinutes }
            let startAt = daySessions.map { $0.session.startAt }.min() ?? day
            let endAt = daySessions.map { $0.session.endAt }.max() ?? day

            let scored = daySessions.compactMap { s -> (score: Int, weight: Int)? in
                guard let score = s.session.score else { return nil }
                return (score, max(0, s.session.totalMinutes))
            }
            let combinedScore: Int?
            let totalWeight = scored.reduce(0) { $0 + $1.weight }
            if scored.isEmpty {
                combinedScore = nil
            } else if totalWeight > 0 {
                let weightedSum = scored.reduce(0.0) { $0 + Double($1.score) * Double($1.weight) }
                combinedScore = Int((weightedSum / Double(totalWeight)).rounded())
            } else {
                // All contributing sessions have zero duration; fall back to a plain average.
                let plainSum = scored.reduce(0) { $0 + $1.score }
                combinedScore = Int((Double(plainSum) / Double(scored.count)).rounded())
            }

            let combinedSession = SleepSession(
                date: day,
                startAt: startAt,
                endAt: endAt,
                totalMinutes: totalMinutes,
                score: combinedScore
            )

            collapsed.append(SleepSummary(
                session: combinedSession,
                lightMinutes: lightMinutes,
                deepMinutes: deepMinutes,
                awakeMinutes: awakeMinutes,
                remMinutes: remMinutes,
                blocks: blocks
            ))
        }

        return collapsed.sorted { $0.session.date < $1.session.date }
    }

    /// The user's usual bedtime as of a given night, from the nights *before* it.
    ///
    /// Days are collapsed first so each contributes one bedtime: a collapsed day's `startAt` is the
    /// earliest of its sessions, which is the night itself — an afternoon nap starts later in the
    /// same waking day and so never displaces it.
    ///
    /// Strictly prior nights only. Including the night being scored would drag the median toward it
    /// and quietly forgive exactly the drift the contributor exists to notice.
    static func bedtimeBaseline(
        for night: SleepSummary, among sessions: [SleepSummary], window: Int = 14
    ) -> BedtimeBaseline? {
        let prior = collapseByDay(sessions)
            .filter { $0.session.date < night.session.date }
            .sorted { $0.session.date > $1.session.date }
            .prefix(window)
        return BedtimeBaseline.compute(bedtimes: prior.map { $0.session.startAt })
    }

    static func averageDuration(_ valid: [SleepSummary]) -> Int? {
        let valid = collapseByDay(valid)
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0) { $0 + $1.session.totalMinutes } / valid.count
    }

    static func averageScore(_ valid: [SleepSummary]) -> Int? {
        let valid = collapseByDay(valid)
        guard !valid.isEmpty else { return nil }
        let total = valid.reduce(0) { $0 + SleepScore.calculate($1).score }
        return Int((Double(total) / Double(valid.count)).rounded())
    }

    /// Mean minutes per stage across the valid nights of a range.
    ///
    /// A struct rather than a tuple because adding REM makes it four members, which trips
    /// SwiftLint's `large_tuple` — the same refactor the rest of this codebase already made.
    struct AverageStages: Equatable {
        let deep: Int
        let light: Int
        let awake: Int
        /// nil when **no** night in the range carried a REM stage, so the caller can omit the field
        /// rather than report an average of zero the ring never measured. Nights that do report REM
        /// are averaged over the whole range, matching how the other three stages are treated.
        let rem: Int?
    }

    static func averageStages(_ valid: [SleepSummary]) -> AverageStages? {
        let valid = collapseByDay(valid)
        guard !valid.isEmpty else { return nil }
        let deep = valid.reduce(0) { $0 + $1.deepMinutes } / valid.count
        let light = valid.reduce(0) { $0 + $1.lightMinutes } / valid.count
        let awake = valid.reduce(0) { $0 + $1.awakeMinutes } / valid.count
        let rem = valid.contains { $0.hasRemSignal }
            ? valid.reduce(0) { $0 + $1.remMinutes } / valid.count
            : nil
        return AverageStages(deep: deep, light: light, awake: awake, rem: rem)
    }

    /// Population standard deviation of nightly durations (minutes).
    private static func durationConsistency(_ valid: [SleepSummary]) -> Double? {
        // Collapse naps into their day first so the variance is computed over the same
        // per-day population that `averageDuration` produces the mean from (a nap counted
        // as its own point against the collapsed mean spuriously inflated the SD).
        let valid = collapseByDay(valid)
        guard valid.count >= 2, let avg = averageDuration(valid) else { return nil }
        let variance = valid.reduce(0.0) { $0 + pow(Double($1.session.totalMinutes - avg), 2) } / Double(valid.count)
        return sqrt(variance)
    }

    private static func nightsTrackedChip(_ valid: Int, _ expected: Int) -> String {
        "\(valid) of \(expected) tracked"
    }

    private static func goalDeltaChip(_ avgMin: Int, _ goalMin: Int?) -> String? {
        guard let goalMin else { return nil }
        let delta = avgMin - goalMin
        if abs(delta) <= 20 { return "On target" }
        return delta < 0 ? "Below goal" : "Above goal"
    }

    private static func consistencyChip(_ valid: [SleepSummary]) -> String? {
        guard let sd = durationConsistency(valid) else { return nil }
        if sd <= 40 { return "Consistent" }
        if sd >= 80 { return "Variable nights" }
        return nil
    }

    /// Day view with a real session.
    static func dayCoach(_ sleep: SleepSummary, score: Int, awakePct: Int?, deepPct: Int, activitySteps: Int?) -> SleepCoach {
        var chips: [String] = []
        if sleep.session.totalMinutes >= 420 && sleep.session.totalMinutes <= 540 { chips.append("Good duration") }
        if deepPct >= 13 && deepPct <= 23 { chips.append("Deep sleep balanced") }
        else if deepPct > 23 { chips.append("Deep sleep strong") }
        if let awakePct, awakePct <= 10 { chips.append("Awake time low") }

        if score >= 85 {
            let body = (activitySteps ?? 0) > 5000
                ? "Looks like a strong night after a more active day. Your duration was solid and deep sleep made up a healthy part of the night, which kept the score high."
                : "Your sleep duration and stage balance were strong. Deep sleep looked supportive, which helped keep the overall score high."
            return SleepCoach(headline: "Strong recovery signal", body: body, chips: Array((chips.isEmpty ? ["Excellent"] : chips).prefix(3)))
        }
        if let awakePct, awakePct > 15 {
            return SleepCoach(
                headline: "Good sleep, with some restlessness",
                body: "You slept long enough, but awake time was a bit elevated. If this repeats, look at late caffeine, alcohol, temperature, or stress near bedtime.",
                chips: Array((["Awake time elevated"] + chips).prefix(3))
            )
        }
        if sleep.session.totalMinutes < 390 {
            return SleepCoach(
                headline: "Duration held the score back",
                body: "The stage mix was useful, but total sleep time was short for a full recovery window. A slightly earlier wind-down would likely improve tomorrow's score.",
                chips: Array((["Short duration"] + chips).prefix(3))
            )
        }
        return SleepCoach(
            headline: "Solid night overall",
            body: "Your sleep was in a workable range, with the score shaped mostly by duration and stage balance. Deep and light sleep were readable enough to give a useful recovery snapshot.",
            chips: Array((chips.isEmpty ? ["Good"] : chips).prefix(3))
        )
    }

    static func aggregateCoach(range: SleepRangeKey, sessions: [SleepSummary], expectedNights: Int, goalMin: Int?) -> SleepCoach {
        // Collapse naps into their day so "N nights tracked" counts distinct nights, matching the
        // collapsed average this copy sits next to (a night + 2 naps is 1 night, not 3).
        let valid = collapseByDay(validSessions(sessions))
        let avgMin = averageDuration(valid)
        let periodWord = range == .week ? "week" : range == .month ? "month" : "year"

        if valid.count < minAggNights {
            let nightWord = valid.count == 1 ? "night" : "nights"
            return SleepCoach(
                headline: "Not enough \(periodWord) data yet",
                body: "I only have \(valid.count) tracked \(nightWord) for this \(periodWord). Wear the ring overnight for a few more nights and I'll build a reliable \(periodWord)ly picture.",
                chips: [nightsTrackedChip(valid.count, expectedNights)]
            )
        }

        var chips = [nightsTrackedChip(valid.count, expectedNights)]
        if let avgMin, let goalChip = goalDeltaChip(avgMin, goalMin) { chips.append(goalChip) }
        if let consist = consistencyChip(valid) { chips.append(consist) }
        chips = Array(chips.prefix(3))

        let avgText = SleepFormat.duration(avgMin)
        let coveragePhrase = "\(valid.count) of \(expectedNights) nights tracked"

        switch range {
        case .week:
            let incomplete = valid.count < expectedNights
            let missing = expectedNights - valid.count
            let missingWord = missing == 1 ? "night" : "nights"
            let body = incomplete
                ? "You averaged \(avgText) across \(valid.count) tracked nights this week. That's a useful read, but \(missing) missing \(missingWord) mean the trend is still incomplete."
                : "You averaged \(avgText) across the full week. Your nights were tracked consistently, so this is a dependable picture of where your sleep sits right now."
            return SleepCoach(headline: "Your week at a glance", body: body, chips: chips)
        case .month:
            let sparse = Double(valid.count) < Double(expectedNights) * 0.5
            let body = sparse
                ? "Your monthly average is \(avgText), but coverage is low (\(coveragePhrase)), so I'd treat that number cautiously. More nights tracked will sharpen the trend."
                : "Your monthly average is \(avgText) across \(coveragePhrase). The biggest lever is consistency — a few short nights move this number more than any single great one."
            return SleepCoach(headline: "Your month in sleep", body: body, chips: chips)
        default:
            return SleepCoach(
                headline: "Your long-term sleep trend",
                // swiftlint:disable:next line_length
                body: "Across the year your tracked average is \(avgText) over \(valid.count) nights. The long-term trend is still forming — as more months fill in, I'll be able to compare seasonal changes and consistency.",
                chips: chips
            )
        }
    }

    static func noDataState(_ range: SleepRangeKey) -> SleepNoDataState {
        switch range {
        case .day:
            return SleepNoDataState(label: "Last Sleep", value: "No sleep captured last night", support: "Wear your ring overnight so PulseLoop can track your next night.")
        case .week:
            return SleepNoDataState(label: "Weekly Sleep", value: "Not enough weekly data", support: "Wear your ring overnight for a few nights to build a weekly view.")
        case .month:
            return SleepNoDataState(label: "Monthly Sleep", value: "Not enough monthly data", support: "Track more nights this month to see a monthly average.")
        case .year:
            return SleepNoDataState(label: "Yearly Sleep", value: "Not enough yearly data", support: "Long-term insights appear as more nights are tracked.")
        }
    }
}

// MARK: - Histogram bar builders (night axis / month buckets)

extension SleepInsights {
    /// One bar per expected night between `start` and `end` (inclusive), each
    /// carrying its session's duration/score or nil for an untracked night.
    static func buildNightAxis(start: Date, end: Date, sessions: [SleepSummary], range: SleepRangeKey) -> [SleepBar] {
        let calendar = Calendar.current
        // Collapse each waking day's sessions (main night + naps) into one before mapping, so a
        // day is represented by its combined summary rather than an arbitrary first session.
        let sessions = collapseByDay(sessions)
        let byDate: [Date: SleepSummary] = Dictionary(
            sessions.map { (calendar.startOfDay(for: $0.session.date), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var bars: [SleepBar] = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        let weekday = DateFormatter()
        weekday.dateFormat = "EEEEE" // narrow weekday letter
        while cursor <= last {
            let session = byDate[cursor]
            let present = (session?.session.totalMinutes ?? 0) > 0
            let label = range == .week
                ? weekday.string(from: cursor)
                : "\(calendar.component(.day, from: cursor))"
            bars.append(SleepBar(
                label: label,
                durationMin: present ? session?.session.totalMinutes : nil,
                score: present ? session.map { SleepScore.calculate($0).score } : nil,
                present: present
            ))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? last.addingTimeInterval(86_400)
        }
        return bars
    }

    /// Twelve trailing monthly buckets ending at `end`, each averaged over its valid nights.
    static func buildMonthBuckets(end: Date, sessions: [SleepSummary]) -> [SleepBar] {
        var calendar = Calendar.current
        calendar.timeZone = .current
        // Collapse naps into their waking day before bucketing so each day counts once per month.
        let valid = collapseByDay(validSessions(sessions))
        var byMonth: [String: [SleepSummary]] = [:]
        for session in valid {
            let comps = calendar.dateComponents([.year, .month], from: session.session.date)
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
            byMonth[key, default: []].append(session)
        }
        let monthAbbrev = DateFormatter()
        monthAbbrev.dateFormat = "MMM"
        var bars: [SleepBar] = []
        for i in stride(from: 11, through: 0, by: -1) {
            guard let monthDate = calendar.date(byAdding: .month, value: -i, to: end) else { continue }
            let comps = calendar.dateComponents([.year, .month], from: monthDate)
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
            let monthSessions = byMonth[key] ?? []
            let avg = averageDuration(monthSessions)
            bars.append(SleepBar(
                label: monthAbbrev.string(from: monthDate),
                durationMin: avg,
                score: averageScore(monthSessions),
                present: !monthSessions.isEmpty
            ))
        }
        return bars
    }
}
