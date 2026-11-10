import Foundation
import SwiftData

/// Splits a waking-day's sleep into distinct sessions — the main night vs. daytime
/// naps — so each can surface as its own carousel page (issue #59). Pure and
/// testable; the SwiftData-facing reconciliation lives in `SleepService`.
enum SleepSegmentation {
    /// A run of >= this many minutes with no recorded sleep data marks a boundary
    /// between two sessions. The ring writes a contiguous per-minute block for each
    /// timeline packet, so short mid-night awakenings stay in one session while a nap
    /// hours after the night (a genuine gap in the blocks) splits into its own.
    static let sessionGapMinutes = 60

    /// Group blocks into chronological sessions, splitting wherever the gap from one
    /// block's end to the next block's start is >= `sessionGapMinutes`, unless `bridge` says the
    /// wearer's quiet-hours window spans it (Android #105). Input need not be sorted. Returns
    /// time-ordered groups; empty in -> empty out.
    ///
    /// Every writer of sessions — the sync's reconcile and the record editor's restate — must pass
    /// the same bridge, or an edit would split a night the next sync merges back.
    static func segment(_ blocks: [SleepStageBlock], bridge: SleepGapBridge = .none) -> [[SleepStageBlock]] {
        let sorted = blocks.sorted { $0.startAt < $1.startAt }
        guard let firstBlock = sorted.first else { return [] }
        let gapSeconds = Double(sessionGapMinutes) * 60
        var groups: [[SleepStageBlock]] = []
        var current: [SleepStageBlock] = [firstBlock]
        var prevEnd = firstBlock.startAt.addingTimeInterval(Double(firstBlock.durationMinutes) * 60)
        for block in sorted.dropFirst() {
            if block.startAt.timeIntervalSince(prevEnd) >= gapSeconds, !bridge.bridges(prevEnd, block.startAt) {
                groups.append(current)
                current = [block]
            } else {
                current.append(block)
            }
            // `max` guards against nested/overlapping blocks pulling the running end backwards.
            let end = block.startAt.addingTimeInterval(Double(block.durationMinutes) * 60)
            prevEnd = max(prevEnd, end)
        }
        groups.append(current)
        return groups
    }
}

/// Whether a gap of `SleepSegmentation.sessionGapMinutes` or more between two runs of sleep is still
/// one night (Android #105, `SleepGapBridge`).
///
/// The hour-gap rule keeps a nap apart from the night, but it also split a night whose wearer lay
/// awake for 72 minutes between two ring records, both inside their quiet hours. The wearer's own
/// window is better evidence than the gap's length, so a gap wholly inside it is bridged: the two
/// parts stay one session and the gap reads as "Awake Xm between" records.
struct SleepGapBridge {
    let bridges: (_ gapStart: Date, _ gapEnd: Date) -> Bool

    static let none = SleepGapBridge { _, _ in false }

    /// The bridge for the stored quiet-hours schedule. Reads it once.
    static func fromSettings(calendar: Calendar = .current) -> SleepGapBridge {
        forSchedule(SleepQuietHours.load(), calendar: calendar)
    }

    /// Bridges a gap whose every minute lies inside the clock window — only while the schedule is on.
    /// A window whose start equals its end means "trimming off", not "asleep all day": bridging under
    /// it would merge an afternoon nap into the night, so it bridges nothing. Nor does a gap of a day
    /// or more.
    static func forSchedule(_ quiet: SleepQuietHours, calendar: Calendar = .current) -> SleepGapBridge {
        let (start, end) = (quiet.startMinutes, quiet.endMinutes)
        guard quiet.enabled, start != end, !(start == 0 && end >= 24 * 60) else { return .none }
        func covered(_ date: Date) -> Bool {
            SleepQuietHours.covers(start: start, end: end, minuteOfDay: SleepQuietHours.minuteOfDay(date, calendar: calendar))
        }
        return SleepGapBridge { gapStart, gapEnd in
            guard gapEnd > gapStart, gapEnd.timeIntervalSince(gapStart) < 24 * 3600 else { return false }
            var t = gapStart
            while t < gapEnd {
                if !covered(t) { return false }
                t = t.addingTimeInterval(60)
            }
            return covered(gapEnd.addingTimeInterval(-0.001))
        }
    }

    /// This bridge, plus every gap a stored session already holds open. A session holds an hour-plus
    /// gap only because a bridge allowed it when the night was written, so re-segmenting after a
    /// delete or edit must keep it whole even if the schedule changed since (no re-sync can re-merge
    /// a night the ring no longer has). `sessions` are the stored sessions' blocks, one group each:
    /// a gap is kept when it lies inside one session's span and none of its blocks overlaps it — so
    /// a gap a deleted record leaves behind is judged afresh, and the gap to a separate nap isn't kept.
    func keepingGaps(of sessions: [[SleepStageBlock]]) -> SleepGapBridge {
        // Snapshot the intervals now: the caller may delete some of these blocks before segmenting.
        let spans: [(start: Date, end: Date, blocks: [(start: Date, end: Date)])] = sessions.compactMap { blocks in
            guard let start = blocks.map(\.startAt).min(), let end = blocks.map(\.endAt).max() else { return nil }
            return (start, end, blocks.map { ($0.startAt, $0.endAt) })
        }
        return SleepGapBridge { gapStart, gapEnd in
            bridges(gapStart, gapEnd) || spans.contains { span in
                span.start <= gapStart && gapEnd <= span.end
                    && !span.blocks.contains { $0.start < gapEnd && $0.end > gapStart }
            }
        }
    }
}

@MainActor
extension SleepService {
    /// Re-derive one waking day's sessions from its raw stage blocks: split by
    /// `SleepSegmentation`, then reconcile the SwiftData rows — match each segment to the
    /// existing row whose prior time-range overlaps it (so identity is stable even when a
    /// nap syncs before the night it precedes), insert rows for unmatched segments, delete
    /// leftover empty rows, re-point every block to its segment, and recompute bounds. A
    /// change signal (`DerivedUpdateRow` + `syncedAt` bump) is emitted only when a row's
    /// bounds actually moved or one of its blocks was re-pointed/re-based, so re-syncing an
    /// unchanged day is a true no-op. Idempotent. Does not save; the caller owns the
    /// transaction boundary.
    ///
    /// `daySessions`/`dayBlocks` let a caller inject the day's already-in-memory rows and
    /// blocks to skip the full-table fetches. `persistSleepTimeline` passes them on the sync
    /// hot path (it holds the objects already, including its just-inserted blocks — which a
    /// predicated re-fetch couldn't see before the coalesced `save()`); the migration passes
    /// per-day slices of a single up-front fetch. When omitted, both are fetched here.
    ///
    /// `bridge` decides which hour-plus gaps still belong to one night; it defaults to the stored
    /// quiet-hours schedule (`SleepGapBridge.fromSettings`).
    static func reconcileWakingDay(dateKey: Date, context: ModelContext,
                                   daySessions injectedSessions: [SleepSession]? = nil,
                                   dayBlocks injectedBlocks: [SleepStageBlock]? = nil,
                                   bridge: SleepGapBridge? = nil) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: dateKey)
        let now = Date()

        let daySessions = injectedSessions ?? ((try? context.fetch(FetchDescriptor<SleepSession>())) ?? [])
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
        guard !daySessions.isEmpty else { return }

        let dayBlocks: [SleepStageBlock]
        if let injectedBlocks {
            dayBlocks = injectedBlocks
        } else {
            let daySessionIds = Set(daySessions.map { $0.id })
            dayBlocks = ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [])
                .filter { daySessionIds.contains($0.sessionId) }
        }

        let rawSegments = SleepSegmentation.segment(dayBlocks, bridge: bridge ?? .fromSettings())

        // No blocks left on this day — drop the empty rows entirely.
        guard !rawSegments.isEmpty else {
            for row in daySessions { context.delete(row) }
            return
        }

        // Snapshot each row's PRIOR bounds before any mutation, for identity matching (#9)
        // and bounds-based change detection (#8). Block-set changes are detected per block
        // in the assignment loop below rather than from a snapshot, because a caller may hand
        // us blocks it just inserted — they'd already look "owned" in a snapshot.
        struct Prior { let start: Date; let end: Date }
        var prior: [UUID: Prior] = [:]
        for row in daySessions { prior[row.id] = Prior(start: row.startAt, end: row.endAt) }

        struct Segment { let blocks: [SleepStageBlock]; let start: Date; let end: Date }
        let segments: [Segment] = rawSegments.compactMap { seg in
            let sorted = seg.sorted { $0.startAt < $1.startAt }
            guard let start = sorted.first?.startAt else { return nil }
            let end = sorted.map { $0.startAt.addingTimeInterval(Double($0.durationMinutes) * 60) }.max() ?? start
            return Segment(blocks: sorted, start: start, end: end)
        }

        func overlap(_ a0: Date, _ a1: Date, _ b0: Date, _ b1: Date) -> TimeInterval {
            max(0, min(a1, b1).timeIntervalSince(max(a0, b0)))
        }

        // Greedily match each segment to the best-overlapping unused row; a row also matches when it
        // contains the segment's start (covers a freshly-created zero-length container row).
        var available = daySessions
        var matched: [(segment: Segment, row: SleepSession?)] = []
        for segment in segments {
            let best = available.enumerated().max { l, r in
                overlap(segment.start, segment.end, prior[l.element.id]!.start, prior[l.element.id]!.end)
                    < overlap(segment.start, segment.end, prior[r.element.id]!.start, prior[r.element.id]!.end)
            }
            if let best, let p = prior[best.element.id],
               overlap(segment.start, segment.end, p.start, p.end) > 0 || (segment.start...segment.end).contains(p.start) {
                available.remove(at: best.offset)
                matched.append((segment, best.element))
            } else {
                matched.append((segment, nil))
            }
        }

        for (segment, existing) in matched {
            let row: SleepSession
            var changed: Bool
            if let existing {
                row = existing; changed = false
            } else {
                row = SleepSession(date: day, startAt: segment.start, endAt: segment.end, totalMinutes: 0, syncedAt: now)
                context.insert(row); changed = true
            }

            for block in segment.blocks {
                let newMinute = max(0, Int(block.startAt.timeIntervalSince(segment.start) / 60))
                // A re-pointed block (moved between sessions) or a re-based one (its minute
                // offset shifted) means this row's contents changed — including brand-new
                // blocks, which `persistSleepTimeline` inserts with `startMinute == 0`.
                if block.sessionId != row.id || block.startMinute != newMinute { changed = true }
                block.sessionId = row.id
                block.startMinute = newMinute
            }
            if let p = prior[row.id], p.start != segment.start || p.end != segment.end { changed = true }

            row.date = day
            row.startAt = segment.start
            row.endAt = segment.end
            row.totalMinutes = max(0, Int(segment.end.timeIntervalSince(segment.start) / 60))
            if changed {
                row.syncedAt = now
                row.updatedAt = now
                context.insert(DerivedUpdateRow(kind: "sleep_timeline", entityType: "sleep_session", entityId: row.id.uuidString))
            }
        }

        // Rows not matched to any segment had all their blocks re-pointed away — delete them.
        for row in available { context.delete(row) }
    }

    /// One-time re-segmentation of existing sleep sessions that were persisted before
    /// per-session splitting: an afternoon nap used to merge into that morning's night
    /// (one row spanning ~16 h with a broken hypnogram). Re-derives each waking day into
    /// distinct sessions. Idempotent + `UserDefaults`-gated so it runs once, off the
    /// render path. Mirrors `migrateSplitSleepSessionsIfNeeded`.
    static func migrateSleepSessionSegmentsIfNeeded(context: ModelContext) {
        let key = "sleepSessionSegment.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let calendar = Calendar.current
        // Fetch every session and block once, then reconcile each day off in-memory slices —
        // waking days are disjoint, so a day's reconcile never touches another's rows, keeping
        // the up-front snapshot valid across the loop (vs. a full-table scan per day).
        let sessions = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let blocksBySession = Dictionary(grouping: (try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [],
                                         by: { $0.sessionId })
        let sessionsByDay = Dictionary(grouping: sessions, by: { calendar.startOfDay(for: $0.date) })
        for (day, daySessions) in sessionsByDay {
            let dayBlocks = daySessions.flatMap { blocksBySession[$0.id] ?? [] }
            reconcileWakingDay(dateKey: day, context: context, daySessions: daySessions, dayBlocks: dayBlocks)
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }
}
