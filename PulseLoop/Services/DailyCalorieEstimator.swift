import Foundation
import SwiftData

// MARK: - Inputs (value types, SwiftData-free)

/// One intraday step bucket (ring history quarter-hour sample).
struct DayStepBucket: Equatable {
    var start: Date
    var durationSeconds: Double
    var steps: Int

    init(start: Date, durationSeconds: Double = 900, steps: Int) {
        self.start = start
        self.durationSeconds = durationSeconds
        self.steps = steps
    }
}

/// A finished workout's time window and its (engine-estimated or coach-provided) gross calories.
struct DayWorkoutWindow: Equatable {
    var start: Date
    var end: Date
    var calories: Double?
}

/// Everything the pure daily model needs for one calendar day.
struct DayEstimateInputs {
    var dayStart: Date
    var dayTotalSteps: Int
    var buckets: [DayStepBucket]
    var workouts: [DayWorkoutWindow]
    /// All HR samples inside the day (any source — workout-window samples are excluded internally).
    var hrSamples: [(timestamp: Date, bpm: Double)]
    var profile: MetricsProfileValues
}

// MARK: - Pure math

/// Daily active-energy model for wearables that don't report calories. Each interval of the day is
/// attributed to exactly one estimator — workout window > HR-above-FLEX segment > step bucket — and
/// every term is net of resting energy, so adding the Mifflin-St Jeor BMR baseline at read time
/// never double-counts. Mirrors the market approach (Whoop: BMR + Keytel; Fitbit/Oura: BMR + motion).
enum DailyCalorieMath {
    static let defaultHeightCm = 170.0
    static let defaultAge = 35
    /// HR-based estimation only above this fraction of HRmax (220 − age): the Keytel model is only
    /// valid in moderate-to-vigorous exercise, and below the FLEX threshold stress/caffeine HR would
    /// inflate the estimate (Spurr's Flex-HR method).
    static let flexHRFraction = 0.6
    /// An all-day HR sample covers at most this long (ring log interval is 5–60 min; beyond 10 min
    /// we'd be extrapolating one elevated reading over a stretch it may not represent).
    static let hrSampleMaxCoverageSeconds: TimeInterval = 600
    /// Assumed actual stepping cadence inside sparse buckets (intermittent walking) — ~100 steps/min
    /// is the validated moderate-walking cadence, so `steps / 100` recovers true walking minutes.
    static let intermittentCadenceSpm = 100.0
    /// Bucket-mean cadence at or above this is a continuous brisk walk for the whole bucket.
    static let briskCadenceSpm = 100.0
    /// Bucket-mean cadence at or above this is sustained running for the whole bucket.
    static let runCadenceSpm = 130.0

    /// Mifflin-St Jeor basal metabolic rate, kcal/day. Missing fields fall back to population
    /// defaults; an unspecified sex uses the mean of the male/female constants.
    static func mifflinBMR(profile: MetricsProfileValues) -> Double {
        let weight = profile.weightKg ?? WorkoutMetricsEngine.defaultWeightKg
        let height = profile.heightCm ?? defaultHeightCm
        let age = Double(profile.age ?? defaultAge)
        let sexConstant: Double
        switch profile.sex?.lowercased() {
        case "male": sexConstant = 5
        case "female": sexConstant = -161
        default: sexConstant = -78
        }
        return max(0, 10 * weight + 6.25 * height - 5 * age + sexConstant)
    }

    /// Net active calories for the day (excludes the BMR baseline — add that at read time).
    static func estimateNetActive(_ inputs: DayEstimateInputs) -> Double {
        let dayStart = inputs.dayStart
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let weight = inputs.profile.weightKg ?? WorkoutMetricsEngine.defaultWeightKg
        let bmrPerMin = mifflinBMR(profile: inputs.profile) / 1440

        // 1. Workouts — reuse the session's stored calories (Keytel-or-MET from
        // WorkoutMetricsEngine, or coach-provided), prorated across midnight and netted of the
        // resting energy the BMR baseline already covers for those minutes.
        var covered: [(start: Date, end: Date)] = []
        var workoutKcal = 0.0
        for workout in inputs.workouts {
            let clippedStart = max(workout.start, dayStart)
            let clippedEnd = min(workout.end, dayEnd)
            guard clippedEnd > clippedStart else { continue }
            let totalSeconds = workout.end.timeIntervalSince(workout.start)
            let clippedSeconds = clippedEnd.timeIntervalSince(clippedStart)
            let fraction = totalSeconds > 0 ? clippedSeconds / totalSeconds : 0
            workoutKcal += max(0, (workout.calories ?? 0) * fraction - bmrPerMin * clippedSeconds / 60)
            covered.append((clippedStart, clippedEnd))
        }

        // 2. All-day HR above the FLEX threshold, outside workout windows — Keytel per-minute rate
        // (net of resting) over each sample's coverage interval. Catches unlogged exertion. Requires
        // the same profile completeness the workout Keytel path does; otherwise HR contributes
        // nothing and steps/workouts carry the estimate.
        if let sex = inputs.profile.sex?.lowercased(), sex == "male" || sex == "female",
           let age = inputs.profile.age, let profileWeight = inputs.profile.weightKg {
            let flexHR = flexHRFraction * (220 - Double(age))
            let samples = inputs.hrSamples
                .filter { $0.bpm > 0 && $0.timestamp >= dayStart && $0.timestamp < dayEnd }
                .sorted { $0.timestamp < $1.timestamp }
            for (index, sample) in samples.enumerated() where sample.bpm >= flexHR {
                let nextTimestamp = index + 1 < samples.count ? samples[index + 1].timestamp : dayEnd
                let coverage = min(max(0, nextTimestamp.timeIntervalSince(sample.timestamp)), hrSampleMaxCoverageSeconds)
                let segment = (start: sample.timestamp, end: sample.timestamp.addingTimeInterval(coverage))
                let minutes = max(0, coverage - overlapSeconds(segment, covered)) / 60
                guard minutes > 0 else { continue }
                let rate = WorkoutMetricsEngine.keytelRate(hr: sample.bpm, male: sex == "male", age: Double(age), weightKg: profileWeight)
                workoutKcal += max(0, rate - bmrPerMin) * minutes
                covered.append(segment)
            }
        }

        // 3. Step buckets — cadence-tiered walking/running METs, net of 1 MET, scaled by the
        // fraction of the bucket not already attributed to a workout or HR segment.
        var stepKcal = 0.0
        var bucketSteps = 0
        for bucket in inputs.buckets {
            bucketSteps += bucket.steps
            guard bucket.steps > 0, bucket.durationSeconds > 0 else { continue }
            let bucketEnd = bucket.start.addingTimeInterval(bucket.durationSeconds)
            let keepFraction = 1 - overlapSeconds((bucket.start, bucketEnd), covered) / bucket.durationSeconds
            guard keepFraction > 0 else { continue }
            let durationMinutes = bucket.durationSeconds / 60
            let cadence = Double(bucket.steps) / durationMinutes
            let met: Double
            let activeMinutes: Double
            if cadence >= runCadenceSpm {
                met = 8.3
                activeMinutes = durationMinutes
            } else if cadence >= briskCadenceSpm {
                met = 3.5
                activeMinutes = durationMinutes
            } else {
                met = intermittentWalkMET(heightCm: inputs.profile.heightCm)
                activeMinutes = Double(bucket.steps) / intermittentCadenceSpm
            }
            stepKcal += max(0, met - 1) * weight * (activeMinutes * keepFraction) / 60
        }

        // 4. Residual steps the buckets don't represent — live-only days, or today's live cumulative
        // counter running ahead of the bucket log — credited at the intermittent-walking rate. When
        // there are no buckets at all, deduct an allowance for steps taken inside already-covered
        // windows (a run workout's steps are in the day total but its energy is already counted).
        var residual = Double(max(0, inputs.dayTotalSteps - bucketSteps))
        if inputs.buckets.isEmpty {
            let coveredMinutes = mergedDurationSeconds(covered) / 60
            residual = max(0, residual - coveredMinutes * intermittentCadenceSpm)
        }
        let residualMET = intermittentWalkMET(heightCm: inputs.profile.heightCm)
        stepKcal += max(0, residualMET - 1) * weight * (residual / intermittentCadenceSpm) / 60

        return max(0, workoutKcal + stepKcal)
    }

    /// Walking MET for intermittent stepping at ~100 steps/min, refined by stride length from
    /// height when available (stride ≈ 0.414 × height → speed → Compendium walking MET tier).
    static func intermittentWalkMET(heightCm: Double?) -> Double {
        guard let heightCm, heightCm > 0 else { return 3.0 }
        let strideMeters = 0.414 * heightCm / 100
        let speedMps = strideMeters * intermittentCadenceSpm / 60
        if speedMps < 1.0 { return 2.8 }   // < 3.6 km/h easy
        if speedMps < 1.35 { return 3.5 }  // ~4.8 km/h moderate
        if speedMps < 1.65 { return 4.3 }  // ~5.6 km/h brisk
        return 5.0                          // ≥ 6 km/h very brisk
    }

    // MARK: interval helpers

    private static func overlapSeconds(_ interval: (start: Date, end: Date), _ windows: [(start: Date, end: Date)]) -> TimeInterval {
        mergedDurationSeconds(windows.compactMap { window in
            let start = max(interval.start, window.start)
            let end = min(interval.end, window.end)
            return end > start ? (start, end) : nil
        })
    }

    private static func mergedDurationSeconds(_ windows: [(start: Date, end: Date)]) -> TimeInterval {
        let sorted = windows.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var currentEnd = Date.distantPast
        for window in sorted {
            let start = max(window.start, currentEnd)
            if window.end > start {
                total += window.end.timeIntervalSince(start)
                currentEnd = window.end
            }
        }
        return total
    }
}

// MARK: - Orchestrator

/// Recomputes a day's `ActivityDaily.estimatedActiveCalories` from persisted buckets, workouts, and
/// HR samples. Always from-scratch, so re-syncs, edits, and repeated calls converge (idempotent).
/// The estimate is stored for every recomputed day regardless of source; device-vs-estimate
/// selection happens at read time (`ActivityDaily.effectiveCalories`), so device data always wins.
@MainActor
enum DailyCalorieEstimator {
    /// Days touched during a sync burst, recomputed once when the sync completes.
    private(set) static var dirtyDays: Set<Date> = []
    /// Per-day throttle for the live-update hook (cumulative packets can stream every second).
    private static var lastLiveRecomputeAt: [Date: Date] = [:]
    static let liveThrottleSeconds: TimeInterval = 60

    static func markDirty(_ day: Date) {
        dirtyDays.insert(Calendar.current.startOfDay(for: day))
    }

    /// Recompute every dirty day. Called from the event bus on sync completion — the subsequent
    /// batched save persists the writes and fires the coalesced change signal.
    static func flushDirty(context: ModelContext) {
        guard !dirtyDays.isEmpty else { return }
        let days = dirtyDays
        dirtyDays.removeAll(keepingCapacity: true)
        for day in days { recompute(day: day, context: context) }
    }

    /// Live-packet hook: keep today's estimate tracking the step ratchet without recomputing on
    /// every packet.
    static func recomputeThrottled(day: Date, context: ModelContext) {
        let dayStart = Calendar.current.startOfDay(for: day)
        if let last = lastLiveRecomputeAt[dayStart], Date().timeIntervalSince(last) < liveThrottleSeconds { return }
        lastLiveRecomputeAt[dayStart] = Date()
        recompute(day: dayStart, context: context)
    }

    /// Recompute the day(s) a workout touches — both sides of midnight for a crossing session.
    static func recompute(around session: ActivitySession, context: ModelContext) {
        recompute(day: session.startedAt, context: context)
        if let ended = session.endedAt, !Calendar.current.isDate(ended, inSameDayAs: session.startedAt) {
            recompute(day: ended, context: context)
        }
    }

    /// Recompute one day's estimate. No `ActivityDaily` row → no-op (a day with no synced or
    /// logged activity has nothing to estimate against). Does not save — callers batch the save.
    static func recompute(day: Date, context: ModelContext) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let row = MetricsRepository.activity(on: dayStart, context: context),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return }

        let buckets = ((try? context.fetch(FetchDescriptor<ActivityBucketSample>(
            predicate: #Predicate { $0.date == dayStart }
        ))) ?? []).map { DayStepBucket(start: $0.timestamp, steps: $0.steps) }

        let workouts = ActivityRepository.sessions(context: context).compactMap { session -> DayWorkoutWindow? in
            guard session.status == .finished, let ended = session.endedAt,
                  session.startedAt < dayEnd, ended > dayStart
            else { return nil }
            return DayWorkoutWindow(start: session.startedAt, end: ended, calories: session.calories)
        }

        let hrSamples = MetricsRepository.measurements(kind: .heartRate, start: dayStart, end: dayEnd, limit: 10_000, context: context)
            .map { (timestamp: $0.timestamp, bpm: $0.value) }

        let profile = MetricsProfileValues(profile: ProfileRepository.profile(context: context))
        row.estimatedActiveCalories = DailyCalorieMath.estimateNetActive(DayEstimateInputs(
            dayStart: dayStart,
            dayTotalSteps: row.steps,
            buckets: buckets,
            workouts: workouts,
            hrSamples: hrSamples,
            profile: profile
        ))
        row.updatedAt = Date()
    }

    /// Recompute the trailing week — after a profile change (weight/height/age shift every term) or
    /// as a one-shot launch backfill (`onlyMissing`) so pre-upgrade days gain an estimate.
    static func recomputeRecentDays(_ days: Int = 7, onlyMissing: Bool = false, context: ModelContext) {
        let calendar = Calendar.current
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: Date())) else { continue }
            if onlyMissing, MetricsRepository.activity(on: day, context: context)?.estimatedActiveCalories != nil { continue }
            recompute(day: day, context: context)
        }
        try? context.save()
    }
}

// MARK: - Read-time selection

extension ActivityDaily {
    /// Calories the device itself reported, or nil when it gave none — ring-history days never
    /// carry device calories (the ring's history calorie field is unverified and dropped at
    /// ingest), and a stored 0 means "no data", not "zero burn".
    @MainActor
    var deviceReportedCalories: Double? {
        source == ActivityService.ringHistorySource || calories <= 0 ? nil : calories
    }

    /// The calorie figure to display: the device's own value when it reported one, else the
    /// estimated TOTAL burn — Mifflin-St Jeor BMR accrued over the day's elapsed minutes (so
    /// today's number grows from midnight, market-style) plus the stored net active estimate.
    @MainActor
    func effectiveCalories(profile: MetricsProfileValues, now: Date = Date()) -> Double? {
        if let device = deviceReportedCalories { return device }
        guard let active = estimatedActiveCalories else { return nil }
        let calendar = Calendar.current
        let elapsedMinutes: Double
        if calendar.isDate(date, inSameDayAs: now) {
            elapsedMinutes = min(1440, max(0, now.timeIntervalSince(calendar.startOfDay(for: now)) / 60))
        } else {
            elapsedMinutes = date < now ? 1440 : 0
        }
        return DailyCalorieMath.mifflinBMR(profile: profile) / 1440 * elapsedMinutes + active
    }

    /// The active-energy portion (device value or net estimate) — what the calorie goal ring
    /// measures, keeping `UserGoal.calories` an active-energy goal even when the displayed number
    /// is an estimated total.
    @MainActor
    var effectiveActiveCalories: Double? {
        deviceReportedCalories ?? estimatedActiveCalories
    }
}
