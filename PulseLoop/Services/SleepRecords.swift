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
    /// Minutes the wearer added over time the ring missed; part of `asleepMinutes`.
    var addedMinutes: Int { SleepRecords.addedMinutes(blocks) }

    private var measured: [SleepStageBlock] { blocks.filter { $0.stage != .added } }
    /// Where the ring's own recording starts and ends inside this run, without the added minutes —
    /// the bounds an extension is measured from. The run's own when nothing is measured.
    var measuredStartAt: Date { measured.map(\.startAt).min() ?? startAt }
    var measuredEndAt: Date { measured.map(\.endAt).max() ?? endAt }
}

/// Pure helpers over a session's stage blocks: splitting them into ring records and counting the
/// waking between records. Shared by the Day view, `SleepService.summary` and the record editor so
/// the Awake figure and the RECORDS card can never disagree about the same gap (Android #81).
enum SleepRecords {
    /// Minutes asleep across `blocks`: every stage except awake.
    static func asleepMinutes(_ blocks: [SleepStageBlock]) -> Int {
        max(0, blocks.filter { $0.stage != .awake }.reduce(0) { $0 + $1.durationMinutes })
    }

    /// Minutes the wearer added over time the ring missed (Android #106). Inside `asleepMinutes`,
    /// outside everything that judges stages: subtract them wherever a stage share or score is taken.
    static func addedMinutes(_ blocks: [SleepStageBlock]) -> Int {
        blocks.filter { $0.stage == .added }.reduce(0) { $0 + $1.durationMinutes }
    }

    /// The asleep minutes the ring itself measured: `asleepMinutes` less `addedMinutes`.
    static func measuredAsleepMinutes(_ blocks: [SleepStageBlock]) -> Int {
        max(0, asleepMinutes(blocks) - addedMinutes(blocks))
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

    /// The waking between two consecutive records of one session, in minutes. The one rule the
    /// Awake figure, the RECORDS card's "Awake Xm between" line and the hypnogram's gap blocks all
    /// read, so they can't disagree about the same gap (Android #81/#111).
    ///
    /// **Any gap is a waking, and counts at least one minute.** A reporter checked every
    /// between-record gap on their ring over six weeks: the shortest (52 s, 88 s) were get-ups they
    /// had logged, and none was a reopen without waking. The ring opens a record on a whole minute,
    /// so how short a gap looks depends on where in the minute the last one ended.
    ///
    /// **Rounded, ties down, not truncated:** a record's stored end is its start plus whole minutes,
    /// up to 30 s either side of the ring's own, so a 2m07 waking can be stored as 1m46. Records that
    /// touch exactly (a Jring's back-to-back packets) count nothing.
    static func betweenRecordAwakeMinutes(_ earlier: SleepRecordRun, _ later: SleepRecordRun) -> Int {
        let gap = later.startAt.timeIntervalSince(earlier.endAt)
        guard gap > 0 else { return 0 }
        return max(1, Int(((gap - 30) / 60).rounded(.up)))
    }

    /// The blocks to draw on the hypnogram: the session's own, plus an awake block over each gap
    /// between records that `betweenRecordAwakeMinutes` counts (Android #111). Without it the chart
    /// draws two records back to back while the Awake and RECORDS cards count the minutes between.
    /// Display only — never feed these back into `awakeMinutes`, which counts the gaps itself.
    static func hypnogramBlocks(_ blocks: [SleepStageBlock]) -> [SleepStageBlock] {
        let runs = runs(blocks)
        guard runs.count > 1 else { return blocks }
        let gaps: [SleepStageBlock] = zip(runs, runs.dropFirst()).compactMap { earlier, later in
            guard betweenRecordAwakeMinutes(earlier, later) > 0 else { return nil }
            let fromMinute = earlier.blocks.map { $0.startMinute + $0.durationMinutes }.max() ?? 0
            let untilMinute = later.blocks.map(\.startMinute).min() ?? fromMinute
            guard untilMinute > fromMinute else { return nil }
            return SleepStageBlock(sessionId: earlier.blocks[0].sessionId, startAt: earlier.endAt, startMinute: fromMinute,
                                   durationMinutes: untilMinute - fromMinute, stage: .awake)
        }
        return blocks + gaps
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
