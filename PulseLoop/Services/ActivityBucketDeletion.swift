import Foundation
import SwiftData

/// Deleting an individual activity bucket (Android #71 / issue #70).
///
/// The sibling of `MeasurementDeletionService`, for the same reason: a ring logs activity in
/// intraday blocks, so a day's steps are the sum of a couple of dozen rows rather than one figure,
/// and a block inflated by carrying the ring rather than wearing it (a rough car journey) is
/// otherwise stuck in the day's total for good.
///
/// Three rules make it stick, all here rather than in a caller:
///  * **Tombstone it.** Buckets upsert by start time, so the next sync of the day writes the bucket
///    straight back. The persistence gates (`ActivityService.applyActivityBucket`,
///    `RWfitActivityPersistence`) check the tombstone first.
///  * **Restate the day without the ratchet.** Today's total is normally ratcheted against the live
///    cumulative counter, which legitimately leads the bucket log. A deletion is the one case where
///    the total must fall — ratcheting would keep the deleted block's steps in the headline.
///  * **Remember what it took.** The ring's live counter still includes the deleted block and keeps
///    re-sending it (seconds later, and on every reconnect). `ActivityDaily.deletedSteps` /
///    `deletedDistanceMeters` carry the deficit so every later live reading is corrected by it.
///
/// Calories are dropped rather than corrected: a bucket carries no calorie figure to subtract, and
/// the ring's own daily figure demonstrably counts the deleted block. Clearing it makes the read path
/// fall through to the on-device estimate, recomputed here from the buckets that remain.
@MainActor
enum ActivityBucketDeletion {

    /// One intraday bucket as the RECORDS list shows it.
    struct Record: Identifiable, Equatable {
        var id: Int { startEpoch }
        let startEpoch: Int
        let timestamp: Date
        let steps: Int
        let distanceMeters: Double
    }

    /// The buckets behind `day`'s total, newest first.
    static func records(on day: Date, context: ModelContext) -> [Record] {
        let dayStart = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<ActivityBucketSample>(
            predicate: #Predicate { $0.date == dayStart },
            sortBy: [SortDescriptor(\.startEpoch, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map {
            Record(startEpoch: $0.startEpoch, timestamp: $0.timestamp, steps: $0.steps, distanceMeters: $0.distanceMeters)
        }
    }

    /// The day's step total now, and what it becomes once `record` is deleted — what the confirmation
    /// tells the user before they commit.
    static func stepsAfterDeleting(_ record: Record, context: ModelContext) -> (before: Int, after: Int) {
        let day = Calendar.current.startOfDay(for: record.timestamp)
        let all = records(on: day, context: context)
        let before = MetricsRepository.activity(on: day, context: context)?.steps ?? all.reduce(0) { $0 + $1.steps }
        let after = all.filter { $0.startEpoch != record.startEpoch }.reduce(0) { $0 + $1.steps }
        return (before, after)
    }

    /// Delete the bucket starting at `startEpoch`, tombstone it and restate its day. Saves and signals
    /// observers. Returns true when a bucket was removed.
    @discardableResult
    static func delete(startEpoch: Int, context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<ActivityBucketSample>(predicate: #Predicate { $0.startEpoch == startEpoch })
        descriptor.fetchLimit = 1
        guard let bucket = try? context.fetch(descriptor).first else { return false }
        let day = bucket.date
        let removedSteps = bucket.steps
        let removedDistance = bucket.distanceMeters

        MeasurementDeletionService.recordTombstone(
            key: MeasurementDeletionService.activityKey(startEpoch: startEpoch),
            kindRaw: MeasurementDeletionService.activityKindRaw,
            timestamp: bucket.timestamp, context: context
        )
        context.delete(bucket)
        // Persist the delete so the restate fetch below can't still see the bucket.
        try? context.save()

        let remaining = (try? context.fetch(FetchDescriptor<ActivityBucketSample>(
            predicate: #Predicate { $0.date == day }
        ))) ?? []
        let row: ActivityDaily
        if let existing = MetricsRepository.activity(on: day, context: context) {
            row = existing
        } else {
            row = ActivityDaily(date: day, source: ActivityService.ringHistorySource)
            context.insert(row)
        }
        // Deliberately unconditional — see the type note on the ratchet. A day whose every bucket is
        // gone keeps its row at zero, so it reads "synced, nothing recorded".
        row.steps = remaining.reduce(0) { $0 + $1.steps }
        let remainingDistance = remaining.reduce(0.0) { $0 + $1.distanceMeters }
        // A bucket stream with no distance channel (jring `0x10`) never carried the day's distance —
        // that came from the live counter — so there is nothing to restate it from.
        if remainingDistance > 0 || removedDistance > 0 { row.distanceMeters = remainingDistance }
        row.deletedSteps += removedSteps
        row.deletedDistanceMeters += removedDistance
        row.calories = 0
        row.updatedAt = Date()
        DailyCalorieEstimator.recompute(day: day, context: context)
        try? context.save()
        PulseDataChange.shared.notify()
        return true
    }

    /// What a day's stored total becomes when the ring pushes a live cumulative `ring` reading for it.
    /// The stored value still wins where it leads (the counter's normal climb is unchanged on a day
    /// with nothing deleted); otherwise the ring's figure is reduced by what the user deleted.
    static func ratchet(stored: Int, ring: Int, deleted: Int) -> Int {
        max(stored, max(0, ring - deleted))
    }

    static func ratchet(stored: Double, ring: Double, deleted: Double) -> Double {
        max(stored, max(0, ring - deleted))
    }
}
