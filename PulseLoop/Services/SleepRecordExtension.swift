import Foundation

/// Why an edit bound stops where it does — what the edit sheet names when a pick goes past it.
enum RecordEditLimit: Equatable {
    /// The previous record of the same night ends here.
    case previousRecord
    /// The next record of the same night starts here.
    case nextRecord
    /// `maxOutwardExtensionMinutes` past the ring's own bounds, before the night's first record or
    /// after its last.
    case outwardCap
    /// The waking day's 7 PM turnover: further would move the record into another night.
    case nightBoundary
    /// The record must keep at least one minute the ring measured.
    case ringMinutes
}

/// How far one record's bounds may move. The start may go back to the previous record's end (no
/// cap: that is the gap the ring missed) or, for the night's first record, two hours before the
/// ring's own start; the end likewise forward. Never across the 7 PM turnover. Shortening is
/// limited only by keeping one measured minute.
struct RecordEditLimits: Equatable {
    let gridOrigin: Date
    let earliestStart: Date
    let earliestStartLimit: RecordEditLimit
    let latestEnd: Date
    let latestEndLimit: RecordEditLimit
    /// The ring's own measured span inside the record, which a shortening must keep a minute of.
    let measuredStart: Date
    let measuredEnd: Date
}

/// A picked bound after the limits: `at` is what to use; `limit` is set when the pick went past one.
struct ClampedEditPick: Equatable {
    let at: Date
    let limit: RecordEditLimit?
}

/// Editing a ring sleep record's bounds, including **extending** it over time the ring missed
/// (Android #82/#92 and #106/#130). Pure: the edit path (`SleepRecordEditor.edit`) and the import
/// (`persistSleepTimeline`, which re-applies a stored edit on every re-sync of the night) both map
/// a record through `editedBlocks`, so a re-sync writes back exactly the blocks the edit did.
///
/// Minutes an extension adds are `.added` blocks — asleep but unstaged: in time asleep, out of the
/// stage breakdown and the score, drawn as their own hatched band on the hypnogram. They carry the
/// record's `recordStartAt`, so they belong to that record, and a gap they cover stops counting as
/// a between-record waking with no further change.
enum SleepRecordExtension {
    /// How far a record may be extended beyond the ring's own bounds where no neighbour limits it.
    static let maxOutwardExtensionMinutes = 120

    // MARK: Grid

    /// The first point on the record's minute grid at or after `t`. A record's stages sit on a grid
    /// anchored at its declared start, and block starts are the identity tombstones and the import's
    /// de-duplication key on, so an edit snaps to that grid rather than to wall-clock minutes.
    static func gridCeil(_ t: Date, origin: Date) -> Date {
        origin.addingTimeInterval((minutes(from: origin, to: t)).rounded(.up) * 60)
    }

    /// The last point on the record's minute grid at or before `t`. See `gridCeil`.
    static func gridFloor(_ t: Date, origin: Date) -> Date {
        origin.addingTimeInterval((minutes(from: origin, to: t)).rounded(.down) * 60)
    }

    /// Minutes from `a` to `b`, with sub-millisecond float noise removed so exact grid points stay
    /// exact under rounding.
    private static func minutes(from a: Date, to b: Date) -> Double {
        (b.timeIntervalSince(a) * 1000).rounded() / 60_000
    }

    // MARK: The shared function

    /// One record's blocks after an edit to `editStart`...`editEnd`.
    ///
    /// `blocks` are the record's blocks: the import passes the ring's freshly built ones, the edit
    /// path the stored ones. Any `.added` block among them is ignored — a previous extension is
    /// re-derived from the new bounds, never kept — so editing back inside the ring's bounds
    /// removes the added minutes and re-applying an edit to its own output is a no-op.
    ///
    /// The bounds snap inwards onto the grid anchored at `gridOrigin`: the start up, the end down,
    /// so the result never reaches past a limit the caller clamped to. Measured blocks are trimmed
    /// to the bounds; time outside the ring's measured span becomes one `.added` block per side.
    ///
    /// Nil when the bounds keep none of the ring's own minutes: a record made only of added time has
    /// nothing to anchor it, so the edit is refused rather than inventing a night. The returned
    /// blocks are new and unattached (placeholder session); the caller inserts and re-keys them.
    static func editedBlocks(_ blocks: [SleepStageBlock], gridOrigin: Date,
                             editStart: Date, editEnd: Date) -> [SleepStageBlock]? {
        let measured = blocks.filter { $0.stage != .added }.sorted { $0.startAt < $1.startAt }
        guard let template = measured.first else { return nil }
        let start = gridCeil(editStart, origin: gridOrigin)
        let end = gridFloor(editEnd, origin: gridOrigin)
        guard start < end else { return nil }
        let placeholder = UUID()

        func block(_ from: Date, _ until: Date, _ stage: SleepStage) -> SleepStageBlock? {
            let count = Int(minutes(from: from, to: until).rounded(.down))
            guard count > 0 else { return nil }
            return SleepStageBlock(sessionId: placeholder, startAt: from, startMinute: 0,
                                   durationMinutes: count, stage: stage, recordStartAt: template.recordStartAt)
        }

        let kept = measured.compactMap { b in block(max(b.startAt, start), min(b.endAt, end), b.stage) }
        guard !kept.isEmpty else { return nil }

        let measuredStart = template.startAt
        let measuredEnd = measured.map(\.endAt).max() ?? measuredStart
        let before = start < measuredStart ? block(start, measuredStart, .added) : nil
        let after = end > measuredEnd ? block(measuredEnd, end, .added) : nil
        return [before].compactMap { $0 } + kept + [after].compactMap { $0 }
    }

    /// What is left of another record's `.added` block once a ring-measured span `start`...`end`
    /// claims the time it covers: the parts outside it, snapped inwards to that record's own grid
    /// so a later re-import of its edit reproduces the same block starts. New, unattached blocks on
    /// the same session.
    static func addedRemainder(of block: SleepStageBlock, outside start: Date, _ end: Date) -> [SleepStageBlock] {
        let origin = block.recordStartAt ?? block.startAt
        func piece(_ from: Date, _ until: Date) -> SleepStageBlock? {
            let count = Int(minutes(from: from, to: until).rounded(.down))
            guard count > 0 else { return nil }
            return SleepStageBlock(sessionId: block.sessionId, startAt: from, startMinute: 0, durationMinutes: count,
                                   stage: .added, recordStartAt: block.recordStartAt)
        }
        let head = piece(block.startAt, min(block.endAt, gridFloor(start, origin: origin)))
        let tail = piece(max(block.startAt, gridCeil(end, origin: origin)), block.endAt)
        return [head, tail].compactMap { $0 }
    }

    // MARK: Limits

    static func limits(run: SleepRecordRun, previous: SleepRecordRun?, next: SleepRecordRun?,
                       wakingDay: Date, calendar: Calendar = .current) -> RecordEditLimits {
        let origin = run.recordStartAt
        let cap = Double(maxOutwardExtensionMinutes) * 60
        let night = nightWindow(wakingDay: wakingDay, calendar: calendar)

        let startCandidates: [(Date, RecordEditLimit)] = [
            previous.map { (gridCeil($0.endAt, origin: origin), .previousRecord) }
                ?? (gridCeil(run.measuredStartAt.addingTimeInterval(-cap), origin: origin), .outwardCap),
            (gridCeil(night.start, origin: origin), .nightBoundary),
        ]
        let endCandidates: [(Date, RecordEditLimit)] = [
            next.map { (gridFloor($0.startAt, origin: origin), .nextRecord) }
                ?? (gridFloor(run.measuredEndAt.addingTimeInterval(cap), origin: origin), .outwardCap),
            (gridFloor(night.end, origin: origin), .nightBoundary),
        ]
        // `max`/`min` keep the first of equal candidates, so a tie names the neighbour or the cap.
        let earliest = startCandidates.dropFirst().reduce(startCandidates[0]) { $1.0 > $0.0 ? $1 : $0 }
        let latest = endCandidates.dropFirst().reduce(endCandidates[0]) { $1.0 < $0.0 ? $1 : $0 }
        // A limit never cuts into the record as it already stands (overlapping legacy rows).
        return RecordEditLimits(
            gridOrigin: origin,
            earliestStart: min(earliest.0, run.startAt),
            earliestStartLimit: earliest.1,
            latestEnd: max(latest.0, run.endAt),
            latestEndLimit: latest.1,
            measuredStart: run.measuredStartAt,
            measuredEnd: run.measuredEndAt
        )
    }

    /// A start picked in the sheet (a whole minute) placed on the record's grid and held inside
    /// `limits`. The grid point inside the picked minute is the one the button then shows, so
    /// picking the minute already displayed is never a change and never a message.
    static func clampStartPick(_ picked: Date, limits: RecordEditLimits) -> ClampedEditPick {
        let at = gridCeil(wholeMinute(picked), origin: limits.gridOrigin)
        let lastStart = gridFloor(limits.measuredEnd.addingTimeInterval(-60), origin: limits.gridOrigin)
        if at < limits.earliestStart { return ClampedEditPick(at: limits.earliestStart, limit: limits.earliestStartLimit) }
        if at > lastStart { return ClampedEditPick(at: lastStart, limit: .ringMinutes) }
        return ClampedEditPick(at: at, limit: nil)
    }

    /// The end-side twin of `clampStartPick`.
    static func clampEndPick(_ picked: Date, limits: RecordEditLimits) -> ClampedEditPick {
        let at = gridCeil(wholeMinute(picked), origin: limits.gridOrigin)
        let firstEnd = gridCeil(limits.measuredStart.addingTimeInterval(60), origin: limits.gridOrigin)
        if at > limits.latestEnd { return ClampedEditPick(at: limits.latestEnd, limit: limits.latestEndLimit) }
        if at < firstEnd { return ClampedEditPick(at: firstEnd, limit: .ringMinutes) }
        return ClampedEditPick(at: at, limit: nil)
    }

    private static func wholeMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// The span of waking day `wakingDay` (local midnight): 7 PM the evening before to 7 PM on the
    /// day — `Calendar.wakingDay(forSleepStart:)`'s turnover, so a record edited inside it keeps
    /// its date.
    static func nightWindow(wakingDay: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let day = calendar.startOfDay(for: wakingDay)
        let hour = Calendar.sleepEveningBoundaryHour
        let end = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        let eve = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: eve) ?? eve
        return (start, end)
    }

    /// Hold edit bounds clear of every block that isn't this record's — the import's guard, and the
    /// edit path's against records in *other* sessions of the day, which the sheet doesn't see. The
    /// ring's measurement always beats an extension.
    static func clampToNeighbours(editStart: Date, editEnd: Date, measuredStart: Date, measuredEnd: Date,
                                  others: [SleepStageBlock], night: (start: Date, end: Date)) -> (start: Date, end: Date) {
        let before = others.map(\.endAt).filter { $0 <= measuredStart }.max()
        let after = others.map(\.startAt).filter { $0 >= measuredEnd }.min()
        let lo = max(before ?? .distantPast, night.start)
        let hi = min(after ?? .distantFuture, night.end)
        return (max(editStart, min(lo, measuredStart)), min(editEnd, max(hi, measuredEnd)))
    }

    // MARK: The sheet

    /// The instant for a picked `hour`:`minute` near a record spanning `recordStart`...`recordEnd`:
    /// of the candidate dates around the record, the one inside or closest to it, ties broken by
    /// closeness to `target` (the bound being edited). So 11:30 PM picked for a record that starts
    /// 12:51 AM lands the evening before, and a morning time for an evening start lands next day.
    static func resolveAdjustedTime(target: Date, recordStart: Date, recordEnd: Date, hour: Int, minute: Int,
                                    calendar: Calendar = .current) -> Date {
        let startDay = calendar.startOfDay(for: recordStart)
        let endDay = calendar.startOfDay(for: recordEnd)
        let days = [calendar.date(byAdding: .day, value: -1, to: startDay), startDay, endDay,
                    calendar.date(byAdding: .day, value: 1, to: endDay)].compactMap { $0 }
        let candidates = days.compactMap { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: $0) }
        func distance(_ c: Date) -> TimeInterval {
            c < recordStart ? recordStart.timeIntervalSince(c) : (c > recordEnd ? c.timeIntervalSince(recordEnd) : 0)
        }
        return candidates.min {
            let (a, b) = (distance($0), distance($1))
            return a != b ? a < b : abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target))
        } ?? target
    }

    /// The sheet's line for a pick that ran past `limit`, naming it. `at` is where it was held.
    static func limitMessage(_ limit: RecordEditLimit, isStart: Bool, at: Date, limits: RecordEditLimits) -> String {
        let time = SleepFormat.clockTime(at)
        switch limit {
        case .previousRecord: return "The previous record ends at \(time)."
        case .nextRecord: return "The next record starts at \(time)."
        case .outwardCap:
            return "A record can be extended by up to \(maxOutwardExtensionMinutes / 60) hours, so "
                + (isStart ? "it can start at \(time) at the earliest." : "it can end at \(time) at the latest.")
        case .nightBoundary:
            return "\(isStart ? "Starting" : "Ending") past \(time) would move it into another night."
        case .ringMinutes:
            return "Keep at least a minute of what the ring recorded "
                + "(\(SleepFormat.clockTime(limits.measuredStart)) – \(SleepFormat.clockTime(limits.measuredEnd)))."
        }
    }
}
