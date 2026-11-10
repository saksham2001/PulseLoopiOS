import Foundation

/// Pure buffer→events decoders for the YCBT health-history record types. Layouts and strides are
/// specified in `docs/YCBT-Protocol.md` §4.4, from `DataUnpack.unpackHealthData`.
///
/// **These run over the fully reassembled transfer buffer, never over a single frame.** The ring
/// concatenates fixed-size records and then chops the stream at frame boundaries wherever they happen
/// to fall, so a record routinely straddles two data frames. Slicing per-frame silently drops the
/// straddling record and misaligns everything after it — `DataUnpack.unpackHealthData` is likewise
/// handed one buffer, not one frame.
///
/// **Layering:** a decoder here only drops the ring's *"no sample"* fillers (a zero value in a slot the
/// firmware never leaves blank when it has a reading). Plausibility ranges live in exactly one place,
/// `RingEventBridge` — duplicating them here would let the two drift apart.
///
/// Timestamps go through `YCBTBytes`: 2000-epoch
/// seconds in the device's local wall clock.
enum YCBTHealthRecords {
    /// Decode a completed transfer. The stride each buffer is sliced at comes from the same
    /// `YCBTHistoryType` table the transfer machine drives the queue from, so the two cannot disagree.
    static func decode(_ buffer: [UInt8], type: YCBTHistoryType) -> [RingDecodedEvent] {
        switch type {
        case .sport: return sport(buffer)
        case .sleep: return sleep(buffer)
        case .heart: return heartRate(buffer)
        case .blood: return bloodPressure(buffer)
        case .all: return combinedVitals(buffer)
        case .spo2: return spo2(buffer)
        case .temperature: return temperature(buffer)
        case .comprehensive: return comprehensive(buffer)
        case .bodyData: return bodyData(buffer)
        default: return []   // a type outside the catalog (a family added a decoder-less key)
        }
    }

    // MARK: - Sport (query 0x02, 14-byte records)

    /// `[start:u32][end:u32][steps:u16@8][distanceMeters:u16@10][calories:u16@12]` (`DataUnpack` case 2).
    ///
    /// These are **interval** buckets (each covers start→end), not a running total, so they ride
    /// `.activityBucket`: upsert by start epoch, day total = sum of distinct buckets — idempotent across
    /// re-syncs, whether the ring replays its log (a sync whose erase was skipped) or not.
    ///
    /// A re-reported bucket **replaces** the stored one, which is exactly what SmartHealth does: its
    /// `step_data` table has a unique `(start_timestamp, device_mac_address)` index and `StepDao` writes
    /// with `INSERT OR REPLACE` (`AppDatabase_Impl.java:133`, `StepDao_Impl.java:29`), and it erases the
    /// sport log after every sync (`DataSyncUtils.java:255-256`). The vendor's whole step history therefore
    /// rests on the firmware never re-reporting an erased bucket's start with a smaller count — if it did,
    /// SmartHealth's own totals would drop on every sync. We match it rather than diverge (a per-bucket
    /// `max` would also change the Colmi path, which shares `applyActivityBucket`), and today's visible
    /// total is floored regardless, by `applyActivityBucket`'s same-day `max` and by the cumulative
    /// counter below. (Unverified on hardware: whether an *open* bucket is stored before it closes.)
    ///
    /// The All record's step field is the opposite (a cumulative daily counter → `.activityUpdate`, a
    /// per-day `max` ratchet); the queue asks for sport *before* all, so the cumulative counter always
    /// has the last word on a day's total.
    ///
    /// Calories are deliberately dropped: `.activityBucket` has no calorie channel (the ring's estimate
    /// is unverified, and the live status stream already feeds the day's calorie ratchet).
    static func sport(_ buffer: [UInt8]) -> [RingDecodedEvent] {
        records(in: buffer, size: 14).compactMap { r in
            let steps = YCBTBytes.u16(r, 8)
            let distance = YCBTBytes.u16(r, 10)
            guard steps > 0 || distance > 0 else { return nil }
            return .activityBucket(timestamp: YCBTBytes.date(YCBTBytes.u32(r, 0)),
                                   steps: steps, distanceMeters: Double(distance))
        }
    }

    // MARK: - Heart rate (query 0x06, 6-byte records)

    /// `[ts:u32][mode:1][hr:1]` (`DataUnpack` case 6). `hr == 0` is an unworn sample, not a reading.
    static func heartRate(_ buffer: [UInt8]) -> [RingDecodedEvent] {
        records(in: buffer, size: 6).compactMap { r in
            let hr = r[5]
            guard hr > 0 else { return nil }
            return .historyMeasurement(kind: .heartRate, value: Double(hr),
                                       timestamp: YCBTBytes.date(YCBTBytes.u32(r, 0)))
        }
    }

    // MARK: - Blood pressure (query 0x08, 8-byte records)

    /// `[ts:u32][isInflated@4][systolic@5][diastolic@6][heartRate@7]` (`DataUnpack` case 8).
    ///
    /// Emitted as two `.historyMeasurement`s rather than a `.bloodPressureSample`: history rows **upsert**
    /// on (kind, timestamp) while live samples **append**, and the ring replays its whole log on any sync
    /// whose Health-Delete was skipped (no durable commit, no bitmap yet, an unanswered delete). A
    /// `.bloodPressureSample` here would therefore duplicate every stored reading on each such replay.
    /// Live/spot BP keeps `.bloodPressureSample`.
    ///
    /// `isInflated` flags the ring's own cuff-style sweep; it doesn't gate validity, so it isn't read.
    static func bloodPressure(_ buffer: [UInt8]) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        for r in records(in: buffer, size: 8) {
            let ts = YCBTBytes.date(YCBTBytes.u32(r, 0))
            events.append(contentsOf: bloodPressureEvents(systolic: r[5], diastolic: r[6], timestamp: ts))
            if r[7] > 0 {
                events.append(.historyMeasurement(kind: .heartRate, value: Double(r[7]), timestamp: ts))
            }
        }
        return events
    }

    // MARK: - Combined vitals (query 0x09, 20-byte records)

    /// The ring's per-interval "All" record (`DataUnpack` case 9):
    /// `[ts:u32][steps:u16@4][hr@6][sys@7][dia@8][spo2@9][resp@10][hrv@11][cvrr@12][tempInt@13]`
    /// `[tempFrac@14][bodyFatInt@15][bodyFatFrac@16][bloodSugar@17]`.
    ///
    /// HR at @6 is deliberately not emitted: the paired heart-rate history carries the same samples at
    /// the same epochs. Body fat at @15–16 has no `MeasurementKind` and is skipped. cvrr @12 likewise.
    ///
    /// Steps are a **cumulative daily counter** (rises through the day, resets at midnight), so they go
    /// out as an `.activityUpdate` — a per-day `max()` ratchet — not an additive bucket. Distance and
    /// calories are zeroed so that `max()` leaves any live-status values intact.
    static func combinedVitals(_ buffer: [UInt8]) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        for r in records(in: buffer, size: 20) {
            let ts = YCBTBytes.date(YCBTBytes.u32(r, 0))
            // Steps (`u16` @4) are deliberately **not** emitted. The field is the ring's *cumulative*
            // day counter as of this record, and `.activityUpdate` is a per-day max ratchet — so the
            // oldest record in a dump that spans midnight sets today's total to yesterday's count and
            // nothing can lower it again for the rest of the day. Activity has two sources that don't
            // have this problem: the `05 02` sport buckets (additive intervals) and the `06 00` live
            // status (the counter, always current).
            events.append(contentsOf: bloodPressureEvents(systolic: r[7], diastolic: r[8], timestamp: ts))
            if r[9] > 0 {
                events.append(.historyMeasurement(kind: .spo2, value: Double(r[9]), timestamp: ts))
            }
            if r[10] > 0 {
                events.append(.historyMeasurement(kind: .respiratoryRate, value: Double(r[10]), timestamp: ts))
            }
            if r[11] > 0 {
                events.append(.historyMeasurement(kind: .hrv, value: Double(r[11]), timestamp: ts))
            }
            events.append(contentsOf: temperatureEvents(integer: r[13], fraction: r[14], timestamp: ts))
            if r[17] > 0 {
                events.append(.historyMeasurement(kind: .bloodSugar,
                                                  value: bloodSugarMgdl(tenthsOfMmol: Int(r[17])), timestamp: ts))
            }
        }
        return events
    }

    // MARK: - SpO₂ (query 0x1A, 6-byte records)

    /// `[ts:u32][type@4][value@5]` (`DataUnpack` case 26). `type` distinguishes the ring's automatic
    /// all-day sampling from a user-triggered spot reading; PulseLoop stores both the same way.
    static func spo2(_ buffer: [UInt8]) -> [RingDecodedEvent] {
        records(in: buffer, size: 6).compactMap { r in
            guard r[5] > 0 else { return nil }
            return .historyMeasurement(kind: .spo2, value: Double(r[5]),
                                       timestamp: YCBTBytes.date(YCBTBytes.u32(r, 0)))
        }
    }

    // MARK: - Temperature (query 0x1E, 7-byte records)

    /// `[ts:u32][type@4][int@5][frac@6]` (`DataUnpack` case 30 — which advances **7** bytes per record
    /// even though its bounds check only demands 5). The value is `int` and `frac` *string-concatenated*
    /// (see `composite`), so it is °C.
    static func temperature(_ buffer: [UInt8]) -> [RingDecodedEvent] {
        records(in: buffer, size: 7).flatMap { r in
            temperatureEvents(integer: r[5], fraction: r[6], timestamp: YCBTBytes.date(YCBTBytes.u32(r, 0)))
        }
    }

    // MARK: - Comprehensive (query 0x2F, 44-byte records)

    /// The ring's "lab panel" sweep (`DataUnpack` case 47). Only blood sugar is decoded —
    /// `[ts:u32][bloodSugarModel@4][int@5][frac@6]`. Uric acid (@7–9), ketones (@10–12) and the four
    /// lipid fractions that follow have no `MeasurementKind`, so they are left on the floor rather than
    /// force-fitted into one.
    static func comprehensive(_ buffer: [UInt8]) -> [RingDecodedEvent] {
        records(in: buffer, size: 44).compactMap { r in
            let tenths = Int(r[5]) * 10 + Int(r[6])
            guard tenths > 0 else { return nil }
            return .historyMeasurement(kind: .bloodSugar, value: bloodSugarMgdl(tenthsOfMmol: tenths),
                                       timestamp: YCBTBytes.date(YCBTBytes.u32(r, 0)))
        }
    }

    // MARK: - Body data (query 0x33, 28-byte records)

    /// `[ts:u32][loadIdx i/f@4-5][hrv i/f@6-7][pressure i/f@8-9][body i/f@10-11][sympathetic i/f@12-13]`
    /// `[sdnn:u16@14][vo2max@16][pnn50@17][rmssd:u16@18][lf:u16@20][hf:u16@22][lfHf@24]`
    /// (`DataUnpack` case 51).
    ///
    /// The SDK's `pressure` is the **stress** score and `body` the **fatigue** score (that is how the
    /// SmartHealth UI labels `BodyData.getPressureValue()` / `getBodyStateValue()`). This record is the
    /// proof that the ring *stores* stress rather than the app deriving it — the old TK5 capability note
    /// said the opposite. Load index, sympathetic tone, SDNN, pNN50, RMSSD and LF/HF have no
    /// `MeasurementKind`; they are left on the floor rather than force-fitted into one.
    ///
    /// Those two scores go through `score` (digit-concatenated, the app's 1…100 scale) while HRV goes
    /// through `composite` (milliseconds) — see both doc comments for why the same byte pair is read two
    /// different ways.
    ///
    /// The fields from @16 on are read only when the record carries them, mirroring the SDK's
    /// `length >= cursor + 25` gate for the rumoured short-prefix firmware. (In the Java that branch is
    /// dead — its loop guard already demands 28 bytes — but the guard costs nothing and a firmware that
    /// really did ship a short record must not fabricate a VO₂max out of the next record's bytes.)
    static func bodyData(_ buffer: [UInt8]) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        for r in records(in: buffer, size: 28) {
            let ts = YCBTBytes.date(YCBTBytes.u32(r, 0))
            if r[6] > 0 {
                events.append(.historyMeasurement(kind: .hrv, value: composite(r[6], r[7]), timestamp: ts))
            }
            if r[8] > 0 {
                events.append(.historyMeasurement(kind: .stress, value: score(r[8], r[9]), timestamp: ts))
            }
            if r[10] > 0 {
                events.append(.historyMeasurement(kind: .fatigue, value: score(r[10], r[11]), timestamp: ts))
            }
            if r.count > 16, r[16] > 0 {
                events.append(.historyMeasurement(kind: .vo2max, value: Double(r[16]), timestamp: ts))
            }
        }
        return events
    }

    // MARK: - Sleep (query 0x04, variable-length sessions)

    /// Sleep is the one variable-length type. The buffer holds **back-to-back sessions**, each a
    /// 20-byte header followed by 8-byte stage segments (`DataUnpack` case 4):
    ///
    ///   header:  `[flags:2][recordLen:u16@2][start:u32@4][end:u32@8][counts/totals@12…19]`
    ///            `recordLen` = the whole session's byte count *including* this header.
    ///   segment: `[tag:1][segStart:u32 LE][len:u24 LE]` — the duration is **three** bytes, so a long
    ///            segment (>18h) can't be truncated by a u16 read.
    ///
    /// Stage classification is `tag & 0x0F` (the app's own `sleepTimeSummary`): 1 deep, 2 light, 3 REM,
    /// 4 awake, 5 nap — the high nibble is a flag mask, so exact-matching the whole tag byte
    /// (`0xF1…0xF4`) is wrong. **An unknown tag must be skipped, never terminal**: breaking out of the
    /// loop on one lets a single nap segment (`0xF5`) truncate the rest of the night.
    ///
    /// Segments are also **deduplicated by start time within the session**, exactly as the SDK does
    /// (`DataUnpack` case 4 keeps a list of the starts it has already taken and skips a repeat). Some
    /// firmware repeats a segment inside one session; because the timeline is laid out *positionally*
    /// from the session start, a repeat would both inflate that stage's minutes and shift every later
    /// block by its duration — and the shifted copies re-insert as new blocks on the next re-sync.
    ///
    /// Each session's timeline is placed against the header's own `start`/`end` (`placeStages`), so a
    /// record ends where the ring says it ended rather than where its rounded segments add up to.
    static func sleep(_ buffer: [UInt8]) -> [RingDecodedEvent] {
        let headerLength = 20
        let segmentLength = 8

        var events: [RingDecodedEvent] = []
        var cursor = 0
        while cursor + headerLength <= buffer.count {
            let recordLength = YCBTBytes.u16(buffer, cursor + 2)
            // The vendor reads the session's own bounds out of the header (`DataUnpack`'s
            // `startTime` at +4, `endTime` at +8) rather than inferring them from the segments.
            let headerStart = YCBTBytes.u32(buffer, cursor + 4)
            let headerEnd = YCBTBytes.u32(buffer, cursor + 8)
            let segmentsStart = cursor + headerLength
            // Trust the record length, but never past the bytes we actually hold (a truncated transfer
            // must not walk off the end — the SDK's own loop has no such guard).
            let declared = max(0, recordLength - headerLength) / segmentLength
            let available = (buffer.count - segmentsStart) / segmentLength
            let segmentCount = min(declared, available)

            var segments: [SleepSegment] = []
            var seenStarts: Set<Int> = []
            for index in 0..<segmentCount {
                let offset = segmentsStart + index * segmentLength
                guard let stage = sleepStage(buffer[offset]) else { continue }   // e.g. padding — skip, don't stop
                let segmentStart = YCBTBytes.u32(buffer, offset + 1)
                let segmentSeconds = YCBTBytes.u24(buffer, offset + 5)
                // A zero-length segment claims no minute, so it must not take the start time's place
                // in the de-duplication and shadow a real segment sharing it — the minutes that one
                // claimed would then read as wake.
                guard segmentSeconds > 0 else { continue }
                guard seenStarts.insert(segmentStart).inserted else { continue } // firmware repeat — count once
                segments.append(SleepSegment(stage: stage, startSeconds: segmentStart, seconds: segmentSeconds))
            }

            let stages = placeStages(segments, headerStart: headerStart, headerEnd: headerEnd)
            if let first = segments.first, !stages.isEmpty {
                let start = usableHeaderBounds(headerStart, headerEnd) ? headerStart : first.startSeconds
                events.append(.sleepTimeline(timestamp: YCBTBytes.date(start), stages: stages))
            }
            // Advance exactly as the SDK does — to the end of the segments we consumed. A bogus
            // `recordLen` therefore still moves the cursor by at least the header, so we can't spin.
            cursor = segmentsStart + segmentCount * segmentLength
        }
        return events
    }

    /// One session's stage segment, kept with its own start.
    private struct SleepSegment {
        let stage: SleepStage
        let startSeconds: Int
        let seconds: Int
    }

    /// A hole between segments shorter than this much real time is a seam, not a waking.
    static let sleepSeamSeconds = 60

    private static func usableHeaderBounds(_ start: Int, _ end: Int) -> Bool {
        start > 0 && end > start && (end - start) / 60 <= maxSleepSessionMinutes
    }

    /// A session's minute-by-minute stage timeline.
    ///
    /// Each segment is placed at its own start for its own length, and the run spans exactly the
    /// header's `start`...`end`. Concatenating rounded segment minutes instead drifts from the
    /// declared end (470 against 474 on the captured night), which can make one record of a split
    /// night appear to abut the next. A minute no segment claims reads as awake — the ring reports
    /// wake as its own segment type, so an unclaimed minute is one it did not call sleep.
    ///
    /// **A hole under a minute of real time is closed** (Android #111): the ring leaves a one-second
    /// seam between segments, and rounding each side to the minute grid independently can strand a
    /// whole AWAKE minute in it (a segment ending at minute 315.48 rounds to 315, the next starting at
    /// 315.5 rounds to 316). So each segment runs on to the next one's start — the first from the
    /// record's start, the last to its end — across any such hole. Holes of a minute or more stay awake.
    ///
    /// The timeline is expanded positionally — one entry per minute — so a bogus duration doesn't
    /// just mis-size one stage, it allocates: the u24 field reaches 194 days. No real session exceeds
    /// a day, so both paths cap there. A session with unusable header bounds (synthetic, truncated)
    /// keeps the concatenation, since there is nothing better to place against.
    private static func placeStages(_ segments: [SleepSegment], headerStart: Int, headerEnd: Int) -> [SleepStage] {
        guard !segments.isEmpty else { return [] }
        guard usableHeaderBounds(headerStart, headerEnd) else {
            var stages: [SleepStage] = []
            for segment in segments {
                let remaining = maxSleepSessionMinutes - stages.count
                if remaining <= 0 { break }
                let minutes = Int((Double(segment.seconds) / 60.0).rounded())
                stages.append(contentsOf: Array(repeating: segment.stage, count: min(max(1, minutes), remaining)))
            }
            return stages
        }
        let total = min(max(1, Int((Double(headerEnd - headerStart) / 60.0).rounded())), maxSleepSessionMinutes)
        var timeline = Array(repeating: SleepStage.awake, count: total)
        let ordered = segments.sorted { $0.startSeconds < $1.startSeconds }
        for (index, segment) in ordered.enumerated() {
            var start = segment.startSeconds
            if index == 0, (0..<sleepSeamSeconds).contains(start - headerStart) { start = headerStart }
            var end = segment.startSeconds + segment.seconds
            // The next segment to start at or after this one's end: one nested inside this segment
            // must not hide the seam to the one that really follows it.
            let next = ordered.first { $0.startSeconds >= end }?.startSeconds ?? headerEnd
            if (0..<sleepSeamSeconds).contains(next - end) { end = next }
            let from = Int((Double(start - headerStart) / 60.0).rounded())
            let until = Int((Double(end - headerStart) / 60.0).rounded())
            let lower = max(0, from), upper = min(total, until)
            if lower < upper { for minute in lower..<upper { timeline[minute] = segment.stage } }
        }
        return timeline
    }

    /// `tag & 0x0F` → shared stage. 5 = nap/daytime sleep, which the app counts separately and PulseLoop
    /// has no bucket for, so it lands in `.unknown` rather than inflating a night's light-sleep total.
    private static func sleepStage(_ tag: UInt8) -> SleepStage? {
        switch tag & 0x0f {
        case 1: return .deep
        case 2: return .light
        case 3: return .rem
        case 4: return .awake
        case 5: return .unknown
        default: return nil
        }
    }

    // MARK: - Shared field decoding

    /// Systolic/diastolic as two upserting history rows. Both bytes are zero on a record the ring never
    /// ran a BP sweep for; the plausible *range* is the bridge's business, not ours.
    private static func bloodPressureEvents(systolic: UInt8, diastolic: UInt8, timestamp: Date) -> [RingDecodedEvent] {
        guard systolic > 0, diastolic > 0 else { return [] }
        return [
            .historyMeasurement(kind: .bloodPressureSystolic, value: Double(systolic), timestamp: timestamp),
            .historyMeasurement(kind: .bloodPressureDiastolic, value: Double(diastolic), timestamp: timestamp),
        ]
    }

    /// The ring's "no temperature sample" fraction marker. SmartHealth's own chart drops on it
    /// **independently of the integer part** (`TemperatureActivity`: `int <= 42 && int >= 33 && frac != 15`),
    /// so it is a sentinel, not a fraction that happens to be 15.
    /// Ceiling on one decoded sleep session, in minutes. See the sleep segment loop.
    static let maxSleepSessionMinutes = 24 * 60

    private static let temperatureFiller: UInt8 = 15

    /// Temperature from an int/fraction pair, shared by the dedicated record and the All record.
    ///
    /// Two fillers, not one. The captured All records carry `int = 0, frac = 15`, but a record stamped
    /// `int = 36, frac = 15` is the *same* "never measured" marker with a stale integer left behind —
    /// and 36.15 °C sails straight through the bridge's 30…45 °C gate, so it would be upserted on this
    /// and every future sync (the ring replays its whole log). Both halves of SmartHealth's own filter
    /// therefore belong here; the plausibility *range* still lives only in the bridge.
    private static func temperatureEvents(integer: UInt8, fraction: UInt8, timestamp: Date) -> [RingDecodedEvent] {
        guard integer > 0, fraction != temperatureFiller else { return [] }
        return [.historyMeasurement(kind: .temperature, value: composite(integer, fraction), timestamp: timestamp)]
    }

    /// The SDK never adds an integer and its fraction *numerically* — it **string-concatenates** them
    /// (`Float.parseFloat(int + "." + frac)`: `DataUnpack` case 30, and `BodyData.calculateCompositeValue`
    /// for hrv/temperature). The fraction's scale is therefore implied by its digit count: 5 → `.5`,
    /// 50 → `.5`, 25 → `.25`. Reproducing that exactly is the only way to land on the number SmartHealth
    /// shows for the same bytes.
    static func composite(_ integer: UInt8, _ fraction: UInt8) -> Double {
        Double("\(integer).\(fraction)") ?? Double(integer)
    }

    /// Stress / fatigue are the one pair that is **not** the decimal composite. The ring scores them
    /// 0–10 with one decimal, and SmartHealth displays that ×10 on a 1…100 scale: its history list reads
    /// `BodyData.getCompositePressure()` = `Integer.parseInt(int + "" + frac)` and its live screen reads
    /// `(int)(Float.parseFloat(int + "." + frac) * 10)` (`PressureMeasureActivity:66`) — both filtered to
    /// `TransUtils.PRESSURE_VISIBLE_MIN/MAX` = 1…100. So bytes `(5, 3)` are the **53** the app puts on
    /// screen, not 5.3. Decoding them as a composite would file every score 10× low *inside* PulseLoop's
    /// own 1…100 stress/fatigue scale (the one jring already reports on), where no range gate can catch it.
    ///
    /// HRV in the same record is deliberately *not* one of these: it is milliseconds — the All record
    /// carries the same quantity as one whole byte and the app's own HRV range is 1…180 — so it keeps the
    /// decimal composite (`45, 6` → 45.6 ms, not 456).
    static func score(_ integer: UInt8, _ fraction: UInt8) -> Double {
        Double("\(integer)\(fraction)") ?? Double(integer)
    }

    /// mg/dL per mmol/L — the standard glucose molar-mass factor.
    static let mgdlPerMmol = 18.016

    /// Blood sugar arrives as **tenths of a mmol/L**, not whole mmol/L. SmartHealth stores the
    /// comprehensive record as `integer * 10 + fraction` and the All record's single byte into the *same*
    /// column (`HealthMetric.bloodSugarLevel`), then filters that column to 11…333 —
    /// `TransUtils.BLOOD_SUGAR_VISIBLE_MIN/MAX`, whose float twins are 1.1 and 33.3 mmol/L. So a raw 55
    /// is 5.5 mmol/L ≈ 99 mg/dL, which is exactly the magnitude a fasting reading should have.
    ///
    /// PulseLoop persists `.bloodSugar` in mg/dL (jring's 0x24 packet does), hence the conversion.
    /// **UNVERIFIED on hardware:** no captured record carried a non-zero value, so the on-device
    /// checkpoint must cross-check one reading against the SmartHealth app before this scale is trusted.
    static func bloodSugarMgdl(tenthsOfMmol raw: Int) -> Double {
        Double(raw) / 10.0 * mgdlPerMmol
    }

    // MARK: - Helpers

    /// Slice the reassembled buffer into fixed-size records, dropping a short trailing remainder
    /// (the SDK's loop guard is likewise `cursor + stride <= length`).
    private static func records(in buffer: [UInt8], size: Int) -> [[UInt8]] {
        guard size > 0 else { return [] }
        var out: [[UInt8]] = []
        var i = 0
        while i + size <= buffer.count {
            out.append(Array(buffer[i..<(i + size)]))
            i += size
        }
        return out
    }
}
