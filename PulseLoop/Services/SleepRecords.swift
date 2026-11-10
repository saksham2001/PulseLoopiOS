import Foundation

/// One ring sleep record inside a stored session (Android #68).
///
/// A ring closes a record when the wearer gets up and opens a new one when they settle, so one
/// night can arrive as two or three records minutes apart. The night is merged into one stored
/// session (that is the night), but the individual records are real information the merge hides —
/// the Sleep day view lists them in its RECORDS card and lets the wearer delete one.
struct SleepRecordRun {
    let startAt: Date
    let endAt: Date
    /// The run's blocks, sorted by `startAt`.
    let blocks: [SleepStageBlock]

    /// The record's declared start: the stamp its blocks carry, else (a night stored before records
    /// were stamped) the run's own first minute. This is the identity delete and edit key on.
    var recordStartAt: Date { blocks.first { $0.recordStartAt != nil }?.recordStartAt ?? startAt }
    var asleepMinutes: Int { SleepRecords.asleepMinutes(blocks) }
}

/// Pure helpers over a session's stage blocks: splitting them into ring records and counting the
/// waking between records. Shared by the Day view, `SleepService.summary` and the record editor so
/// the Awake figure and the RECORDS card can never disagree about the same gap (Android #81).
enum SleepRecords {
    /// Minutes asleep across `blocks`: every stage except awake.
    static func asleepMinutes(_ blocks: [SleepStageBlock]) -> Int {
        max(0, blocks.filter { $0.stage != .awake }.reduce(0) { $0 + $1.durationMinutes })
    }

    /// Split `blocks` into the ring records they came from.
    ///
    /// The boundary is read, not inferred: each block carries its record's declared start
    /// (`recordStartAt`), so records are grouped by that. The gap between records is no substitute
    /// — some firmware reopens a record a single minute after closing one, which is the same width
    /// as the minute-grid seam inside one record. `minGapMinutes` is only the fallback for nights
    /// stored before the stamp existed (all-or-nothing: a part-stamped night has no consistent
    /// boundary to read). One run for an unsplit night; empty in, empty out.
    static func runs(_ blocks: [SleepStageBlock], minGapMinutes: Int = 2) -> [SleepRecordRun] {
        let ordered = blocks.sorted { $0.startAt < $1.startAt }
        guard let first = ordered.first else { return [] }

        func run(_ group: [SleepStageBlock]) -> SleepRecordRun {
            SleepRecordRun(startAt: group[0].startAt, endAt: group.map(\.endAt).max() ?? group[0].startAt, blocks: group)
        }

        if ordered.allSatisfy({ $0.recordStartAt != nil }) {
            let grouped = Dictionary(grouping: ordered) { key($0.recordStartAt!) }
            return grouped.keys.sorted().map { run(grouped[$0]!) }
        }

        var runs: [SleepRecordRun] = []
        var current = [first]
        var currentEnd = first.endAt
        for block in ordered.dropFirst() {
            if block.startAt.timeIntervalSince(currentEnd) >= Double(minGapMinutes) * 60 {
                runs.append(run(current))
                current = [block]
            } else {
                current.append(block)
            }
            currentEnd = max(currentEnd, block.endAt)
        }
        runs.append(run(current))
        return runs
    }

    /// The waking between two consecutive records of one session, in minutes — 0 for the one-minute
    /// reopen seam. The one rule the Awake figure and the RECORDS card's "Awake Xm between" line
    /// both read (Android #81).
    static func betweenRecordAwakeMinutes(_ earlier: SleepRecordRun, _ later: SleepRecordRun) -> Int {
        let gapMinutes = Int(later.startAt.timeIntervalSince(earlier.endAt) / 60)
        return gapMinutes >= 2 ? gapMinutes : 0
    }

    /// Awake minutes for a session: the stages the ring marked awake plus the gaps between its
    /// records. A ring reports a brief night-waking either as an awake stage or by closing the record
    /// and opening a new one; both are real not-asleep minutes.
    static func awakeMinutes(_ blocks: [SleepStageBlock]) -> Int {
        let staged = blocks.filter { $0.stage == .awake }.reduce(0) { $0 + $1.durationMinutes }
        let runs = runs(blocks)
        let between = zip(runs, runs.dropFirst()).reduce(0) { $0 + betweenRecordAwakeMinutes($1.0, $1.1) }
        return staged + between
    }

    /// One ring record's per-minute stages run-length encoded into blocks, each stamped with the
    /// record's declared start. Unattached (placeholder `sessionId`): the caller decides which to
    /// insert and re-keys them to the session they land in.
    static func stageBlocks(start: Date, stages: [SleepStage], recordStartAt: Date? = nil) -> [SleepStageBlock] {
        let placeholder = UUID()
        var blocks: [SleepStageBlock] = []
        var offset = 0
        while offset < stages.count {
            let stage = stages[offset]
            var duration = 1
            while offset + duration < stages.count, stages[offset + duration] == stage { duration += 1 }
            blocks.append(SleepStageBlock(sessionId: placeholder, startAt: start.addingTimeInterval(Double(offset) * 60),
                                          startMinute: offset, durationMinutes: duration, stage: stage,
                                          recordStartAt: recordStartAt ?? start))
            offset += duration
        }
        return blocks
    }

    /// Whole-second identity for an instant, so a record or block re-sent by the ring matches its
    /// stored twin regardless of how the store round-trips the `Date`.
    static func key(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded()) }
}
