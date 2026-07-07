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

struct SleepScoreResult {
    let score: Int
    let label: SleepQualityLabel
    let deepPct: Int
    let lightPct: Int
    /// nil when there is no usable awake signal.
    let awakePct: Int?
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

    private static func awakeScore(_ awakePct: Double?, points: Double) -> Double {
        guard let awakePct, awakePct.isFinite else { return points * 0.55 }
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

    static func calculate(_ sleep: SleepSummary) -> SleepScoreResult {
        let total = sleep.session.totalMinutes > 0 ? Double(sleep.session.totalMinutes) : 0
        let deep = Double(max(0, sleep.deepMinutes))
        let light = Double(max(0, sleep.lightMinutes))
        let awake = Double(max(0, sleep.awakeMinutes))
        let coveredStageMin = sleep.blocks.reduce(0.0) { sum, block in
            switch block.stage {
            case .deep, .light, .awake: return sum + Double(max(0, block.durationMinutes))
            default: return sum
            }
        }
        let hasAwakeSignal =
            sleep.blocks.contains { $0.stage == .awake } ||
            awake > 0 ||
            (total > 0 && coveredStageMin >= total * 0.95)

        let totalHours = total / 60
        let deepPct = total > 0 ? (deep / total) * 100 : 0
        let lightPct = total > 0 ? (light / total) * 100 : 0
        let awakePct: Double? = (total > 0 && hasAwakeSignal) ? (awake / total) * 100 : nil

        let duration = bandScore(totalHours, idealLow: 7.5, idealHigh: 8.5, softLow: 6, softHigh: 9.5, hardLow: 3, hardHigh: 12, points: 35)
        let deepScore = bandScore(deepPct, idealLow: 13, idealHigh: 23, softLow: 5, softHigh: 35, hardLow: 0, hardHigh: 45, points: 30)
        let lightScore = bandScore(lightPct, idealLow: 50, idealHigh: 60, softLow: 35, softHigh: 75, hardLow: 20, hardHigh: 90, points: 20)
        let awakeSub = awakeScore(awakePct, points: 15)
        let score = Int(clamp((duration + deepScore + lightScore + awakeSub).rounded(), 0, 100))

        return SleepScoreResult(
            score: score,
            label: qualityLabel(score),
            deepPct: Int(deepPct.rounded()),
            lightPct: Int(lightPct.rounded()),
            awakePct: awakePct.map { Int($0.rounded()) }
        )
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

    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
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

    static func averageDuration(_ valid: [SleepSummary]) -> Int? {
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0) { $0 + $1.session.totalMinutes } / valid.count
    }

    static func averageScore(_ valid: [SleepSummary]) -> Int? {
        guard !valid.isEmpty else { return nil }
        let total = valid.reduce(0) { $0 + SleepScore.calculate($1).score }
        return Int((Double(total) / Double(valid.count)).rounded())
    }

    static func averageStages(_ valid: [SleepSummary]) -> (deep: Int, light: Int, awake: Int)? {
        guard !valid.isEmpty else { return nil }
        let deep = valid.reduce(0) { $0 + $1.deepMinutes } / valid.count
        let light = valid.reduce(0) { $0 + $1.lightMinutes } / valid.count
        let awake = valid.reduce(0) { $0 + $1.awakeMinutes } / valid.count
        return (deep, light, awake)
    }

    /// Population standard deviation of nightly durations (minutes).
    private static func durationConsistency(_ valid: [SleepSummary]) -> Double? {
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

    static let dayNoDataCoach = SleepCoach(
        headline: "No sleep tracked last night",
        body: "I don't see sleep data for last night. Wear your ring overnight and sync in the morning so I can compare your sleep against your baseline.",
        chips: []
    )

    static func aggregateCoach(range: SleepRangeKey, sessions: [SleepSummary], expectedNights: Int, goalMin: Int?) -> SleepCoach {
        let valid = validSessions(sessions)
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
        let valid = validSessions(sessions)
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
