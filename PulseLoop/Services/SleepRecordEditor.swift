import Foundation
import SwiftData

/// The tombstones the sleep import consults, read once per timeline packet (Android #78/#80).
/// A re-sent record reproduces its declared start and its blocks' starts exactly, so those are the
/// keys: a deleted record is dropped whole, and any block of a deleted night that re-sends is
/// skipped even when the record's own start was only a guess (nights stored before stamping).
struct SleepRecordTombstones {
    private let deletedRecords: Set<Int64>
    private let deletedBlocks: Set<Int64>

    init(_ edits: [SleepRecordEdit]) {
        var records = Set<Int64>(), blocks = Set<Int64>()
        for edit in edits {
            switch edit.kind {
            case .recordDeleted: records.insert(SleepRecords.key(edit.recordStartAt))
            case .blockDeleted: blocks.insert(SleepRecords.key(edit.recordStartAt))
            case nil: break
            }
        }
        deletedRecords = records
        deletedBlocks = blocks
    }

    func isRecordDeleted(_ recordStart: Date) -> Bool { deletedRecords.contains(SleepRecords.key(recordStart)) }
    func isBlockDeleted(_ blockStart: Date) -> Bool { deletedBlocks.contains(SleepRecords.key(blockStart)) }
}

/// The wearer's edits to one ring sleep record of a stored night (Android `SleepRecordDeletion`).
///
/// Three rules, all of which live here rather than in a caller:
///  - **Remember the record, not the row.** The import re-derives the waking day from the stages
///    the ring re-sends, so deleting stored blocks alone would last one sync. A `SleepRecordEdit`
///    tombstone is written first and `persistSleepTimeline` consults it.
///  - **Re-derive, never hand-patch.** The day is re-segmented and every session's bounds recomputed
///    by `SleepService.reconcileWakingDay`, the same function the next sync runs, so what the UI
///    shows after an edit is what that sync agrees with. Nothing left means the row goes.
///  - **The merge reseals itself.** Records are recovered from block stamps on every read, so the
///    RECORDS card shows the shorter list with no "these were one record" state to maintain.
@MainActor
enum SleepRecordEditor {
    /// Delete the ring record `recordStartAt` from session `sessionId`, remember it, and restate the
    /// day from what remains. Returns true when a record was removed.
    @discardableResult
    static func delete(sessionId: UUID, recordStartAt: Date, context: ModelContext) -> Bool {
        guard let session = session(sessionId, context: context) else { return false }
        let blocks = SleepRepository.blocks(sessionId: sessionId, context: context)
        guard let run = SleepRecords.runs(blocks).first(where: {
            SleepRecords.key($0.recordStartAt) == SleepRecords.key(recordStartAt)
        }) else { return false }

        let day = session.date
        var known = Set(((try? context.fetch(FetchDescriptor<SleepRecordEdit>())) ?? [])
            .map { "\($0.kindRaw):\(SleepRecords.key($0.recordStartAt))" })
        func remember(_ kind: SleepRecordEditKind, _ at: Date) {
            // One tombstone per key, so deleting the same record twice never grows the table.
            guard known.insert("\(kind.rawValue):\(SleepRecords.key(at))").inserted else { return }
            context.insert(SleepRecordEdit(wakingDay: day, recordStartAt: at, kind: kind))
        }
        remember(.recordDeleted, run.recordStartAt)
        for block in run.blocks { remember(.blockDeleted, block.startAt) }

        let removed = Set(run.blocks.map(\.id))
        for block in run.blocks { context.delete(block) }
        restate(day: day, removing: removed, context: context)
        return true
    }

    /// Re-derive waking day `day` from its blocks less `removing`, then stamp the surviving rows as
    /// changed (a deleted middle record leaves the bounds where they were, which reconcile alone
    /// would treat as no change) and recompute any stored score. Saves and signals the UI.
    static func restate(day: Date, removing: Set<UUID>, context: ModelContext) {
        let calendar = Calendar.current
        let daySessions = ((try? context.fetch(FetchDescriptor<SleepSession>())) ?? [])
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
        let ids = Set(daySessions.map(\.id))
        let dayBlocks = ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [])
            .filter { ids.contains($0.sessionId) && !removing.contains($0.id) }
        SleepService.reconcileWakingDay(dateKey: day, context: context,
                                        daySessions: daySessions, dayBlocks: dayBlocks)
        try? context.save()

        let now = Date()
        let survivors = ((try? context.fetch(FetchDescriptor<SleepSession>())) ?? [])
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
        for row in survivors {
            row.updatedAt = now
            row.syncedAt = now
            if row.score != nil {
                row.score = SleepScore.calculate(SleepService.summary(for: row, context: context)).score
            }
            context.insert(DerivedUpdateRow(kind: "sleep_record_edit", entityType: "sleep_session", entityId: row.id.uuidString))
        }
        try? context.save()
        PulseDataChange.shared.notify()
    }

    private static func session(_ id: UUID, context: ModelContext) -> SleepSession? {
        try? context.fetch(FetchDescriptor<SleepSession>(predicate: #Predicate { $0.id == id })).first
    }
}
