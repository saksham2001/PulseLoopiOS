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
}
