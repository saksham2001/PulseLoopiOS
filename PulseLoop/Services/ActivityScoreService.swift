import Foundation
import SwiftData

/// Reads the store and hands `ActivityScore` and `TrainingLoad` their inputs. The maths stays in
/// those two types; everything SwiftData-facing is here, mirroring how `SleepService` sits in front
/// of `SleepScore`.
@MainActor
enum ActivityScoreService {

    /// The day's movement score, or nil when the day has no activity row at all.
    static func score(on day: Date = Date(), context: ModelContext) -> ActivityScoreResult? {
        let startOfDay = Calendar.current.startOfDay(for: day)
        guard let row = MetricsRepository.activity(on: startOfDay, context: context) else { return nil }
        let goals = MetricsRepository.goals(context: context)
        let regularity = movementRegularity(on: startOfDay, context: context)

        return ActivityScore.calculate(ActivityScoreInputs(
            steps: row.steps,
            activeMinutes: row.activeMinutes,
            // Ring-history days carry no trustworthy calorie figure (`buildTodaySummary` blanks them
            // for the same reason), so the contributor drops rather than scoring a guess.
            activeEnergyKcal: row.source == ActivityService.ringHistorySource ? nil : row.calories,
            activeHours: regularity?.activeHours,
            observableHours: regularity?.observableHours,
            stepsGoal: goals?.steps ?? UserGoal.defaultSteps,
            activeMinutesGoal: goals?.activeMinutes ?? UserGoal.defaultActiveMinutes,
            energyGoal: goals?.calories ?? UserGoal.defaultCalories
        ))
    }

    /// How much of the waking day carried movement, from the ring's intraday buckets.
    ///
    /// Returns nil when the day has no buckets — a ring that reports only a daily total can't
    /// answer this, and the contributor is dropped rather than assumed.
    ///
    /// "Observable" hours are those the ring actually reported buckets for, not a flat 14: a ring
    /// taken off at lunchtime should not be scored for the afternoon it never saw.
    static func movementRegularity(
        on day: Date, context: ModelContext, calendar: Calendar = .current
    ) -> (activeHours: Int, observableHours: Int)? {
        let startOfDay = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return nil }
        let descriptor = FetchDescriptor<ActivityBucketSample>(
            predicate: #Predicate { $0.timestamp >= startOfDay && $0.timestamp < end }
        )
        let buckets = (try? context.fetch(descriptor)) ?? []
        guard !buckets.isEmpty else { return nil }

        var stepsByHour: [Int: Int] = [:]
        for bucket in buckets {
            let hour = calendar.component(.hour, from: bucket.timestamp)
            guard ActivityScore.regularityWindow.contains(hour) else { continue }
            stepsByHour[hour, default: 0] += max(0, bucket.steps)
        }
        guard !stepsByHour.isEmpty else { return nil }

        let active = stepsByHour.values.count { $0 >= ActivityScore.regularityStepFloor }
        return (activeHours: active, observableHours: stepsByHour.count)
    }

    // MARK: - Training load

    /// Daily Edwards load for the last `days` days, keyed by start-of-day.
    ///
    /// Days with no heart-rate readings are **absent from the map**, not zero — see
    /// `TrainingLoad.balance`, which excludes them from both averages so an unworn week can't read
    /// as a recovery week.
    static func dailyLoad(days: Int = 28, now: Date = Date(), context: ModelContext,
                          calendar: Calendar = .current) -> [Date: Double] {
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)
        let profile = UserPhysiologyProfile(ProfileRepository.profile(context: context))
        let hrMax = TrainingLoad.maxHeartRate(age: profile.age)

        let samples = MetricsRepository.measurements(
            kind: .heartRate, start: start, end: now, limit: 20_000, context: context
        ).map { MetricSample(timestamp: $0.timestamp, value: $0.value) }

        var byDay: [Date: [MetricSample]] = [:]
        for sample in samples {
            byDay[calendar.startOfDay(for: sample.timestamp), default: []].append(sample)
        }
        // A single reading can't bound an interval, so it yields no load and the day stays absent.
        return byDay.compactMapValues { daySamples in
            let load = TrainingLoad.load(samples: daySamples, hrMax: hrMax)
            return load > 0 ? load : nil
        }
    }

    /// This week's load against the last month's.
    static func balance(now: Date = Date(), context: ModelContext) -> TrainingLoad.Balance {
        TrainingLoad.balance(dailyLoad: dailyLoad(now: now, context: context), now: now)
    }
}

private extension Collection {
    /// `count(where:)` is only available from iOS 18.4; this keeps the deployment target honest.
    func count(_ isIncluded: (Element) -> Bool) -> Int {
        reduce(0) { isIncluded($1) ? $0 + 1 : $0 }
    }
}
