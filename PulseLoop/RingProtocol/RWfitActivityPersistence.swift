import Foundation
import SwiftData

/// A history transaction's activity snapshot. Reads throw; mutations never save internally.
/// The caller commits all buckets and derived daily totals together before consuming ring history.
/// RWfit commits one page per transaction: buckets upsert by start epoch and day totals are
/// re-derived from every stored bucket of that day, so a day split across pages sums once.
@MainActor
final class RWfitActivityPersistence {
    nonisolated deinit {}
    private let context: ModelContext
    private var days: [ActivityDaily]
    private var buckets: [ActivityBucketSample]
    private(set) var touchedDays: Set<Date> = []

    init(context: ModelContext) throws {
        self.context = context
        days = try context.fetch(FetchDescriptor<ActivityDaily>())
        buckets = try context.fetch(FetchDescriptor<ActivityBucketSample>())
    }

    func apply(_ event: PulseEvent) -> Bool {
        switch event {
        case let .activityUpdate(timestamp, steps, distanceMeters, calories):
            let row = day(timestamp)
            // Net of any bucket the user deleted from this day (issue #70) — see `ActivityBucketDeletion`.
            row.steps = ActivityBucketDeletion.ratchet(stored: row.steps, ring: steps, deleted: row.deletedSteps)
            row.distanceMeters = ActivityBucketDeletion.ratchet(stored: row.distanceMeters, ring: distanceMeters,
                                                                deleted: row.deletedDistanceMeters)
            if row.deletedSteps == 0 && row.deletedDistanceMeters == 0 { row.calories = max(row.calories, calories) }
            row.source = "live"
            recordChange(row)
            return true
        case let .activityBucket(timestamp, steps, distanceMeters):
            let epoch = Int(timestamp.timeIntervalSince1970)
            // A bucket the user deleted stays deleted (issue #70).
            if MeasurementDeletionService.isActivityBucketDeleted(startEpoch: epoch, context: context) { return true }
            if let bucket = buckets.first(where: { $0.startEpoch == epoch }) {
                bucket.steps = steps
                bucket.distanceMeters = distanceMeters
                bucket.updatedAt = Date()
            } else {
                let bucket = ActivityBucketSample(timestamp: timestamp, steps: steps, distanceMeters: distanceMeters)
                context.insert(bucket)
                buckets.append(bucket)
            }
            let row = day(timestamp)
            let dayBuckets = buckets.filter { $0.date == row.date }
            let totalSteps = dayBuckets.reduce(0) { $0 + $1.steps }
            let totalDistance = dayBuckets.reduce(0.0) { $0 + $1.distanceMeters }
            // Today's cumulative reading can lead the ring's most recent logged bucket.
            if Calendar.current.isDateInToday(row.date), row.steps > totalSteps || row.distanceMeters > totalDistance {
                row.steps = max(row.steps, totalSteps)
                row.distanceMeters = max(row.distanceMeters, totalDistance)
            } else {
                row.steps = totalSteps
                row.distanceMeters = totalDistance
                row.source = ActivityService.ringHistorySource
            }
            recordChange(row)
            return true
        default:
            return false
        }
    }

    private func day(_ timestamp: Date) -> ActivityDaily {
        let date = Calendar.current.startOfDay(for: timestamp)
        if let row = days.first(where: { $0.date == date }) { return row }
        let row = ActivityDaily(date: date, source: ActivityService.ringHistorySource)
        context.insert(row)
        days.append(row)
        return row
    }

    private func recordChange(_ row: ActivityDaily) {
        row.syncedAt = Date()
        row.updatedAt = Date()
        touchedDays.insert(row.date)
    }
}
