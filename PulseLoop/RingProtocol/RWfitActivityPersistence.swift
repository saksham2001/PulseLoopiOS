import Foundation
import SwiftData

/// A history transaction's activity snapshot. Reads throw; mutations never save internally.
/// The caller commits all buckets and derived daily totals together before consuming ring history.
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
            row.steps = max(row.steps, steps)
            row.distanceMeters = max(row.distanceMeters, distanceMeters)
            row.calories = max(row.calories, calories)
            row.source = "live"
            recordChange(row)
            return true
        case let .activityBucket(timestamp, steps, distanceMeters):
            let epoch = Int(timestamp.timeIntervalSince1970)
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
