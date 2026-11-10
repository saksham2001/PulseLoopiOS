import Foundation
import SwiftData

/// The tombstones the sleep import consults, read once per timeline packet (Android #78/#80).
/// A re-sent record reproduces its declared start and its blocks' starts exactly, so those are the
/// keys: a deleted record is dropped whole, and any block of a deleted night that re-sends is
/// skipped even when the record's own start was only a guess (nights stored before stamping).
///
/// It also carries the bounds of every edited record, which the import re-applies (Android #92/#130).
struct SleepRecordTombstones {
    private let deletedRecords: Set<Int64>
    private let deletedBlocks: Set<Int64>
    private let editedBounds: [Int64: (start: Date, end: Date)]

    init(_ edits: [SleepRecordEdit]) {
        var records = Set<Int64>(), blocks = Set<Int64>(), bounds: [Int64: (start: Date, end: Date)] = [:]
        for edit in edits {
            switch edit.kind {
            case .recordDeleted: records.insert(SleepRecords.key(edit.recordStartAt))
            case .blockDeleted: blocks.insert(SleepRecords.key(edit.recordStartAt))
            case .edited:
                if let start = edit.newStartAt, let end = edit.newEndAt {
                    bounds[SleepRecords.key(edit.recordStartAt)] = (start, end)
                }
            case nil: break
            }
        }
        deletedRecords = records
        deletedBlocks = blocks
        editedBounds = bounds
    }

    func isRecordDeleted(_ recordStart: Date) -> Bool { deletedRecords.contains(SleepRecords.key(recordStart)) }
    func isBlockDeleted(_ blockStart: Date) -> Bool { deletedBlocks.contains(SleepRecords.key(blockStart)) }
    /// The bounds the wearer gave record `recordStart`, if they edited it.
    func editedBounds(_ recordStart: Date) -> (start: Date, end: Date)? { editedBounds[SleepRecords.key(recordStart)] }
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
        let edits = (try? context.fetch(FetchDescriptor<SleepRecordEdit>())) ?? []
        // The record goes whole, so an edit of it has nothing left to re-apply.
        forgetEdit(of: run.recordStartAt, in: edits, context: context)
        var known = Set(edits.filter { $0.kind != .edited }
            .map { "\($0.kindRaw):\(SleepRecords.key($0.recordStartAt))" })
        func remember(_ kind: SleepRecordEditKind, _ at: Date) {
            // One tombstone per key, so deleting the same record twice never grows the table.
            guard known.insert("\(kind.rawValue):\(SleepRecords.key(at))").inserted else { return }
            context.insert(SleepRecordEdit(wakingDay: day, recordStartAt: at, kind: kind))
        }
        remember(.recordDeleted, run.recordStartAt)
        for block in run.blocks { remember(.blockDeleted, block.startAt) }

        restate(day: day, removing: run.blocks, context: context)
        return true
    }

    /// Move the bounds of record `recordStartAt` in session `sessionId` to `newStart`...`newEnd` —
    /// shorter, longer, or one side each (Android #92/#130). Stages outside the new range drop from
    /// the night; time inside it the ring didn't measure becomes `.added` minutes. The bounds are
    /// held to `SleepRecordExtension.limits` (the sheet's limits) and clear of records in the day's
    /// other sessions, which the sheet doesn't see. The edit is remembered so every re-sync of the
    /// record re-applies it. False when nothing changed or no ring-measured minute would remain.
    @discardableResult
    static func edit(sessionId: UUID, recordStartAt: Date, newStart: Date, newEnd: Date,
                     context: ModelContext, calendar: Calendar = .current) -> Bool {
        guard newStart < newEnd, let session = session(sessionId, context: context) else { return false }
        let blocks = SleepRepository.blocks(sessionId: sessionId, context: context)
        let runs = SleepRecords.runs(blocks)
        guard let index = runs.firstIndex(where: {
            SleepRecords.key($0.recordStartAt) == SleepRecords.key(recordStartAt)
        }) else { return false }
        let run = runs[index]
        let day = session.date

        let limits = SleepRecordExtension.limits(run: run, previous: index > 0 ? runs[index - 1] : nil,
                                                 next: index + 1 < runs.count ? runs[index + 1] : nil,
                                                 wakingDay: day, calendar: calendar)
        let otherSessionIds = Set(((try? context.fetch(FetchDescriptor<SleepSession>())) ?? [])
            .filter { calendar.isDate($0.date, inSameDayAs: day) && $0.id != sessionId }.map(\.id))
        let others = ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [])
            .filter { otherSessionIds.contains($0.sessionId) }
        let bounds = SleepRecordExtension.clampToNeighbours(
            editStart: max(newStart, limits.earliestStart), editEnd: min(newEnd, limits.latestEnd),
            measuredStart: limits.measuredStart, measuredEnd: limits.measuredEnd,
            others: others, night: SleepRecordExtension.nightWindow(wakingDay: day, calendar: calendar))
        guard let edited = SleepRecordExtension.editedBlocks(run.blocks, gridOrigin: run.recordStartAt,
                                                             editStart: bounds.start, editEnd: bounds.end)
        else { return false }
        let shape = { (b: [SleepStageBlock]) in b.map { "\(SleepRecords.key($0.startAt)):\($0.durationMinutes):\($0.stageRaw)" } }
        guard shape(edited) != shape(run.blocks.sorted { $0.startAt < $1.startAt }) else { return false }

        let edits = (try? context.fetch(FetchDescriptor<SleepRecordEdit>())) ?? []
        forgetEdit(of: run.recordStartAt, in: edits, context: context)
        context.insert(SleepRecordEdit(wakingDay: day, recordStartAt: run.recordStartAt, kind: .edited,
                                       newStartAt: bounds.start, newEndAt: bounds.end))

        for block in edited { block.sessionId = sessionId }
        restate(day: day, removing: run.blocks, adding: edited, context: context)
        return true
    }

    private static func forgetEdit(of recordStart: Date, in edits: [SleepRecordEdit], context: ModelContext) {
        for edit in edits where edit.kind == .edited && SleepRecords.key(edit.recordStartAt) == SleepRecords.key(recordStart) {
            context.delete(edit)
        }
    }

    /// Replace `removing` with `adding` and re-derive waking day `day` from the result, then stamp
    /// the surviving rows as changed (a deleted middle record leaves the bounds where they were,
    /// which reconcile alone would treat as no change) and recompute any stored score. Saves and
    /// signals the UI.
    static func restate(day: Date, removing: [SleepStageBlock], adding: [SleepStageBlock] = [], context: ModelContext) {
        let calendar = Calendar.current
        let daySessions = ((try? context.fetch(FetchDescriptor<SleepSession>())) ?? [])
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
        let ids = Set(daySessions.map(\.id))
        let stored = ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? []).filter { ids.contains($0.sessionId) }
        // Segment with the sync's own bridge, plus every gap the stored nights already hold: a gap a
        // quiet-hours window bridged when the night was written stays bridged whatever the schedule
        // says today, or this restate would split a night no re-sync can merge back.
        let bridge = SleepGapBridge.fromSettings()
            .keepingGaps(of: Array(Dictionary(grouping: stored, by: \.sessionId).values))

        let removed = Set(removing.map(\.id))
        for block in removing { context.delete(block) }
        for block in adding { context.insert(block) }
        // `adding` is passed on explicitly: a fetch need not see blocks inserted since the last save.
        let dayBlocks = stored.filter { !removed.contains($0.id) } + adding
        SleepService.reconcileWakingDay(dateKey: day, context: context,
                                        daySessions: daySessions, dayBlocks: dayBlocks, bridge: bridge)
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
