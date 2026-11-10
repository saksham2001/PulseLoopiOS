import Foundation
import SwiftData

// MARK: - One-time activity data migrations

extension ActivityService {
    /// One-time cleanup of `ActivityDaily` rows inflated by the old `+=` accumulator bug (steps that
    /// compounded into the millions across repeated syncs). Deletes ring-history daily rows so they get
    /// recomputed cleanly from buckets on the next sync. Idempotent + UserDefaults-gated so it runs once.
    static func migrateInflatedActivityIfNeeded(context: ModelContext) {
        let key = "activityBucketMigration.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for row in MetricsRepository.activityRows(context: context) where row.source == ringHistorySource {
            context.delete(row)
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    /// One-time deletion of `ActivityDaily` rows poisoned by unvalidated live updates: values beyond
    /// the daily plausibility ceilings, or rows dated in the future (garbage ring-clock timestamps
    /// that would otherwise permanently become "today"). Idempotent + UserDefaults-gated so it runs once.
    static func migrateGarbageActivityIfNeeded(context: ModelContext) {
        let key = "activityGarbageCleanup.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        for row in MetricsRepository.activityRows(context: context)
        where row.steps > RingEventBridge.maxDailySteps
            || row.distanceMeters > RingEventBridge.maxDailyDistanceMeters
            || row.calories > RingEventBridge.maxDailyCalories
            || row.date >= tomorrow {
            context.delete(row)
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    /// One-time repair of LuckRing/TK18 days inflated before its sport records were decoded as day
    /// totals (`LuckRingDecoder.decodeSport`): each running-total push was stored as an activity bucket,
    /// and a day's total is the *sum* of its buckets, so every push added the whole day again (668 real
    /// steps stored as ~9,000). The live path's max ratchet can never bring such a day back down.
    ///
    /// Only marked done once a ring has been identified: with no paired ring the family is unknown, so
    /// it waits and retries on a later launch rather than skipping a wearer who still has those days.
    static func repairLuckRingActivityIfNeeded(context: ModelContext) {
        let key = "luckRingActivityRepair.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard repairLuckRingActivity(context: context) != nil else { return }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Collapse every stored day whose buckets carry the running-total signature to its last snapshot,
    /// if the paired ring is a LuckRing. Returns the number of days fixed (0 for any other family), or
    /// nil when no ring has been identified yet. The `Device` row outlives Forget with its family intact,
    /// so a wearer who forgot the ring is still repaired.
    @discardableResult
    static func repairLuckRingActivity(context: ModelContext) -> Int? {
        guard let device = DeviceRepository.current(context: context), !device.capabilitiesRaw.isEmpty else { return nil }
        guard device.deviceType == .luckRing else { return 0 }
        let buckets = (try? context.fetch(FetchDescriptor<ActivityBucketSample>())) ?? []
        var repairedDays: [Date] = []
        for (day, dayBuckets) in Dictionary(grouping: buckets, by: \.date) {
            guard let total = luckRingRunningTotal(dayBuckets.map {
                (timestamp: $0.timestamp, steps: $0.steps, distanceMeters: $0.distanceMeters)
            }) else { continue }
            // They were never intervals, so they leave the Records list as well as the sum.
            dayBuckets.forEach(context.delete)
            if let row = MetricsRepository.activity(on: day, context: context) {
                row.steps = total.steps
                row.distanceMeters = total.distanceMeters
                row.updatedAt = Date()
            }
            repairedDays.append(day)
        }
        try? context.save()
        // Each repaired day's calorie estimate was built on the inflated steps and buckets.
        for day in repairedDays { DailyCalorieEstimator.recompute(day: day, context: context) }
        try? context.save()
        return repairedDays.count
    }

    /// The day's true total if `buckets` are LuckRing running-total snapshots — two or more, with steps
    /// and distance never falling from one to the next — else nil (leave the day alone). Interval buckets
    /// from a bucketed ring rise and fall, so they don't match.
    static func luckRingRunningTotal(
        _ buckets: [(timestamp: Date, steps: Int, distanceMeters: Double)]
    ) -> (steps: Int, distanceMeters: Double)? {
        guard buckets.count >= 2 else { return nil }
        let ordered = buckets.sorted { $0.timestamp < $1.timestamp }
        let cumulative = zip(ordered, ordered.dropFirst()).allSatisfy { a, b in
            b.steps >= a.steps && b.distanceMeters >= a.distanceMeters
        }
        guard cumulative, let last = ordered.last else { return nil }
        return (last.steps, last.distanceMeters)
    }
}
