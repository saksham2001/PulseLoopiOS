import Foundation
import SwiftData

/// Deleting individual readings (Android #62 / issue #60).
///
/// A reading can be wrong in ways nothing downstream can detect — a ring worn loosely, a measurement
/// started by mistake, a value taken mid-movement — and without a delete it stays in every average
/// computed over it. Deletion only: a recorded health value may be removed, never edited into a
/// different number.
///
/// Two rules make a delete stick, and both live here so no caller has to remember them:
///  * **Tombstone it.** Ring history is replayed with deterministic timestamps on every re-sync, so a
///    `MeasurementDeletion` row keyed by kind + instant is checked by the persistence gate before a
///    sample is written (`EventPersistenceSubscriber`).
///  * **Delete a blood-pressure reading as a pair.** One reading is two rows (systolic + diastolic)
///    sharing an instant; removing one half would chart a systolic with no diastolic.
@MainActor
enum MeasurementDeletionService {

    /// The tombstone key for a vital reading. Whole seconds: history timestamps are whole seconds,
    /// and a sub-second difference can never be a different reading of the same kind.
    static func key(kind: MeasurementKind, timestamp: Date) -> String {
        "\(kind.rawValue):\(Int(timestamp.timeIntervalSince1970.rounded(.down)))"
    }

    /// Whether the user deleted the reading of `kind` at `timestamp`. Indexed point lookup on the
    /// unique key — cheap enough for the persistence gate's per-sample check.
    static func isDeleted(kind: MeasurementKind, timestamp: Date, context: ModelContext) -> Bool {
        isTombstoned(key(kind: kind, timestamp: timestamp), context: context)
    }

    /// The `kindRaw` an activity-bucket tombstone carries (issue #70).
    static let activityKindRaw = "activity_bucket"

    /// The tombstone key for the activity bucket starting at `startEpoch`.
    static func activityKey(startEpoch: Int) -> String { "activity:\(startEpoch)" }

    static func isActivityBucketDeleted(startEpoch: Int, context: ModelContext) -> Bool {
        isTombstoned(activityKey(startEpoch: startEpoch), context: context)
    }

    static func isTombstoned(_ key: String, context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<MeasurementDeletion>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Record a tombstone unless one already exists (re-deleting the same instant is a no-op).
    static func recordTombstone(key: String, kindRaw: String, timestamp: Date, context: ModelContext) {
        guard !isTombstoned(key, context: context) else { return }
        context.insert(MeasurementDeletion(key: key, kindRaw: kindRaw, timestamp: timestamp))
    }

    /// The rows one displayed reading is made of: both halves for blood pressure, the row itself for
    /// everything else.
    static func rowsForReading(_ row: Measurement, context: ModelContext) -> [Measurement] {
        guard row.kind == .bloodPressureSystolic || row.kind == .bloodPressureDiastolic else { return [row] }
        let instant = row.timestamp
        let sys = MeasurementKind.bloodPressureSystolic.rawValue
        let dia = MeasurementKind.bloodPressureDiastolic.rawValue
        let pair = (try? context.fetch(FetchDescriptor<Measurement>(predicate: #Predicate {
            ($0.kindRaw == sys || $0.kindRaw == dia) && $0.timestamp == instant
        }))) ?? []
        return pair.isEmpty ? [row] : pair
    }

    /// Delete `rows`, tombstone each, remove them from Apple Health if PulseLoop exported them, and
    /// signal observers. Saves immediately: a delete that lost its tombstone would come back on the
    /// next sync. Returns the number of rows removed.
    @discardableResult
    static func delete(_ rows: [Measurement], context: ModelContext) -> Int {
        guard !rows.isEmpty else { return 0 }
        var exported: [(MeasurementKind, Date)] = []
        for row in rows {
            recordTombstone(key: key(kind: row.kind, timestamp: row.timestamp), kindRaw: row.kindRaw,
                            timestamp: row.timestamp, context: context)
            if row.sourceRaw != MeasurementSource.mock.rawValue { exported.append((row.kind, row.timestamp)) }
            context.delete(row)
        }
        try? context.save()
        // One removal per reading: a BP pair is one correlation in Health.
        var seenBP: Set<Int> = []
        for (kind, timestamp) in exported {
            if kind == .bloodPressureSystolic || kind == .bloodPressureDiastolic {
                guard seenBP.insert(Int(timestamp.timeIntervalSince1970 * 1000)).inserted else { continue }
            }
            HealthSyncService.shared.deleteExportedVital(kind: kind, timestamp: timestamp)
        }
        PulseDataChange.shared.notify()
        return rows.count
    }

    /// Delete one displayed reading — the row plus, for blood pressure, its partner half.
    @discardableResult
    static func deleteReading(_ row: Measurement, context: ModelContext) -> Int {
        delete(rowsForReading(row, context: context), context: context)
    }
}
