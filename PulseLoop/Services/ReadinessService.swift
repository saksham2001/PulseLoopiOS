import Foundation
import SwiftData

/// Assembles readiness inputs from the store, scores them, and persists the result.
///
/// The storage half of the readiness feature — `ReadinessScore` holds the (pure) maths. Shaped
/// after `RestingHRBaselineService`: a throttled `refreshIfStale` entry point, a bounded fetch, and
/// writes only when something actually changed.
///
/// The window that matters here is **the night**, not the calendar day. Daytime HRV and heart rate
/// reflect what you were doing, not how you recovered, so every overnight signal is read from the
/// sleep session's own span and daytime samples are excluded outright.
enum ReadinessService {
    /// Readiness changes when a night's data lands, not continuously. Three hours is frequent
    /// enough to pick up a morning sync and cheap enough to call on every foreground.
    static let refreshInterval: TimeInterval = 3 * 3600
    static let baselineWindowDays = 30
    static let loadBaselineDays = 7
    /// 30 days of continuous overnight sampling is a few thousand rows; cap defensively, matching
    /// `RestingHRBaselineService.fetchLimit`.
    static let fetchLimit = 5000
    /// Below this many usable days the trailing-load mean is noise, so load is left unscored.
    static let minLoadBaselineDays = 4

    /// Fallback overnight window when no sleep session was decoded: 22:00 the previous evening
    /// through 08:00. Deliberately generous — a ring that captured HRV and HR overnight but failed
    /// the sleep decode should still produce a score.
    static let fallbackWindowStartHour = -2
    static let fallbackWindowEndHour = 8

    // MARK: - Entry points

    /// Recompute today's readiness if the stored row is stale or was written by an older algorithm.
    /// Cheap to call on every launch and foreground.
    @MainActor
    static func refreshIfStale(context: ModelContext, now: Date = Date()) {
        guard ReadinessPrefsStore.shared.prefs.masterEnabled else { return }
        let today = Calendar.current.startOfDay(for: now)
        if let existing = ReadinessRepository.row(on: today, context: context),
           existing.algorithmVersion == ReadinessScore.algorithmVersion,
           now.timeIntervalSince(existing.computedAt) < refreshInterval {
            return
        }
        refresh(day: today, context: context, now: now)
    }

    /// Compute and upsert the row for `day`.
    ///
    /// Deletes any existing row when the outcome becomes unavailable, so a night whose sleep session
    /// was corrected or deleted doesn't strand yesterday's score on screen.
    @MainActor
    @discardableResult
    static func refresh(day: Date, context: ModelContext, now: Date = Date()) -> ReadinessOutcome {
        let startOfDay = Calendar.current.startOfDay(for: day)
        let outcome = ReadinessScore.evaluate(inputs(for: startOfDay, context: context))
        let existing = ReadinessRepository.row(on: startOfDay, context: context)

        switch outcome {
        case .unavailable:
            if let existing {
                context.delete(existing)
                try? context.save()
            }
        case .scored(let result):
            let json = encodeContributors(result.contributors)
            if let existing {
                existing.score = result.score
                existing.bandRaw = result.band.rawValue
                existing.availablePoints = result.availablePoints
                existing.contributorsJSON = json
                existing.algorithmVersion = ReadinessScore.algorithmVersion
                existing.computedAt = now
                existing.updatedAt = now
            } else {
                context.insert(
                    ReadinessDaily(
                        date: startOfDay,
                        score: result.score,
                        band: result.band,
                        availablePoints: result.availablePoints,
                        contributorsJSON: json,
                        computedAt: now
                    )
                )
            }
            try? context.save()
        }
        return outcome
    }

    /// Fill in history. Idempotent: days already scored at the current algorithm version are
    /// skipped, so this is safe to call after an import or a demo reseed.
    @MainActor
    static func backfill(days: Int = 30, context: ModelContext, now: Date = Date()) {
        guard ReadinessPrefsStore.shared.prefs.masterEnabled else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        for offset in 0..<max(0, days) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            if let existing = ReadinessRepository.row(on: day, context: context),
               existing.algorithmVersion == ReadinessScore.algorithmVersion {
                continue
            }
            refresh(day: day, context: context, now: now)
        }
    }

    // MARK: - Input assembly

    /// Gather one morning's signals and the baselines to judge them against. The only
    /// storage-touching part of readiness; everything downstream is pure.
    @MainActor
    static func inputs(for day: Date, context: ModelContext) -> ReadinessInputs {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: day)
        let window = overnightWindow(for: startOfDay, context: context)

        // Baselines end where the scored night begins, so a night can actually deviate from its own
        // baseline rather than being averaged into it.
        let baselineStart = window.start.addingTimeInterval(-Double(baselineWindowDays) * 86_400)

        func overnightValues(_ kind: MeasurementKind) -> [Double] {
            MetricsRepository
                .measurements(kind: kind, start: window.start, end: window.end,
                              limit: fetchLimit, context: context)
                .map(\.value)
                .filter { $0 > 0 }
        }

        func baselineSamples(_ kind: MeasurementKind) -> BaselineStats? {
            let rows = MetricsRepository.measurements(
                kind: kind, start: baselineStart, end: window.start,
                limit: fetchLimit, context: context
            )
            // Only overnight readings belong in an overnight baseline; a 3pm HRV reading describes
            // a different physiological state entirely.
            let nightly = rows
                .filter { isOvernight($0.timestamp, calendar: calendar) }
                .map { MetricSample(timestamp: $0.timestamp, value: $0.value) }
            return BaselineStats.compute(nightly)
        }

        let hrvValues = overnightValues(.hrv)
        let hrValues = overnightValues(.heartRate)
        let tempValues = overnightValues(.temperature)

        var inputs = ReadinessInputs()

        if !hrvValues.isEmpty {
            inputs.hrv = mean(hrvValues)
            inputs.hrvBaseline = baselineSamples(.hrv)
        }

        if !hrValues.isEmpty {
            // The night's floor, not its average — the same statistic (p10) the learned baseline it
            // is compared against uses, so the two are like for like.
            inputs.restingHeartRate = percentile(hrValues.sorted(), 0.10)
            inputs.restingHeartRateBaseline = ProfileRepository.profile(context: context)?.hrRestingBaseline
        }

        if !tempValues.isEmpty {
            inputs.skinTemperature = mean(tempValues)
            inputs.skinTemperatureBaseline = baselineSamples(.temperature)
        }

        if let sleep = SleepService.sleepForDate(startOfDay, context: context), sleep.session.totalMinutes > 0 {
            inputs.sleepScore = SleepScore.calculate(sleep).score
        }

        if let priorDay = calendar.date(byAdding: .day, value: -1, to: startOfDay) {
            inputs.priorDayLoadMinutes = loadMinutes(on: priorDay, context: context)
            inputs.loadBaselineMinutes = loadBaseline(before: priorDay, context: context)
        }

        return inputs
    }

    // MARK: - Overnight window

    /// The span to read overnight signals from. Prefers the night's own sleep session — which
    /// `SleepService.sleepForDate` already resolves to the day's *longest* session, i.e. the night
    /// rather than a nap — and falls back to a fixed 22:00–08:00 window when sleep wasn't decoded.
    @MainActor
    static func overnightWindow(for day: Date, context: ModelContext) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: day)
        if let sleep = SleepService.sleepForDate(startOfDay, context: context),
           sleep.session.endAt > sleep.session.startAt {
            return (sleep.session.startAt, sleep.session.endAt)
        }
        let start = calendar.date(byAdding: .hour, value: fallbackWindowStartHour, to: startOfDay) ?? startOfDay
        let end = calendar.date(byAdding: .hour, value: fallbackWindowEndHour, to: startOfDay) ?? startOfDay
        return (start, end)
    }

    /// Whether a timestamp falls in the overnight band used for baselines (22:00–08:00 local).
    private static func isOvernight(_ date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 8
    }

    // MARK: - Training load

    /// Yesterday's load in minutes: `max` of the day's active minutes and its recorded workout
    /// time, never the sum — a tracked run usually also generates active minutes, and adding them
    /// would double-count the same hour of effort.
    @MainActor
    static func loadMinutes(on day: Date, context: ModelContext) -> Double? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: day)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return nil }

        let daily = MetricsRepository.activity(on: startOfDay, context: context)
        let activeMinutes = daily.map { Double(max(0, $0.activeMinutes)) }

        let sessions = ActivityRepository.sessions(context: context).filter { session in
            guard session.status == .finished, let ended = session.endedAt else { return false }
            return ended >= startOfDay && ended < endOfDay
        }
        let workoutMinutes: Double? = sessions.isEmpty ? nil : sessions.reduce(0.0) { total, session in
            guard let ended = session.endedAt else { return total }
            let elapsed = ended.timeIntervalSince(session.startedAt) - session.totalPauseSeconds
            return total + max(0, elapsed) / 60
        }

        switch (activeMinutes, workoutMinutes) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let w?): return w
        case (let a?, let w?): return max(a, w)
        }
    }

    /// Trailing mean daily load over the `loadBaselineDays` before `day`, excluding `day` itself.
    /// Returns nil below `minLoadBaselineDays` of usable history — a ratio against one or two days
    /// would swing wildly for no real reason.
    @MainActor
    static func loadBaseline(before day: Date, context: ModelContext) -> Double? {
        let calendar = Calendar.current
        var values: [Double] = []
        for offset in 1...loadBaselineDays {
            guard let past = calendar.date(byAdding: .day, value: -offset, to: day) else { continue }
            if let minutes = loadMinutes(on: past, context: context) {
                values.append(minutes)
            }
        }
        guard values.count >= minLoadBaselineDays else { return nil }
        let average = mean(values)
        return average > 0 ? average : nil
    }

    // MARK: - Helpers

    private static func encodeContributors(_ contributors: [ReadinessContributor]) -> String {
        let records = contributors.map(ReadinessContributorRecord.init)
        guard let data = try? JSONEncoder().encode(records),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Interpolated percentile — same formula as `BaselineStats.compute` and
    /// `RestingHRBaselineService`, so every resting-HR number in the app is derived identically.
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = fraction * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
