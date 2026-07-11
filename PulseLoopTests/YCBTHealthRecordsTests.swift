import XCTest
@testable import PulseLoop

/// Record decoders, run over a *reassembled transfer buffer* (never a single frame). Buffers here are
/// the payload bytes of the SmartHealth capture's own history frames, so the offsets are checked
/// against real hardware output; the sleep fixture is one full night.
final class YCBTHealthRecordsTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let n = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<n], radix: 16)!)
            i = n
        }
        return out
    }

    // MARK: Heart rate (6-byte records)

    func testHeartRateRecordsDecodeEveryRecord() {
        let events = YCBTHealthRecords.heartRate(capturedHeartRecords)
        XCTAssertEqual(values(.heartRate, in: events), [71, 66, 63, 62, 66, 60, 65, 58])
        XCTAssertEqual(timestamps(in: events).first, YCBTBytes.date(836_694_044))
    }

    /// `hr == 0` is an unworn sample, not a reading of zero.
    func testHeartRateDropsZeroSamples() {
        let buffer = bytes("1cf0de310000" + "1afede310042")
        XCTAssertEqual(YCBTHealthRecords.heartRate(buffer).count, 1)
    }

    // MARK: Combined vitals (20-byte "All" records)

    func testCombinedVitalsDecodesStepsBPSpo2AndHRV() {
        let events = YCBTHealthRecords.combinedVitals(capturedAllRecords)

        XCTAssertEqual(values(.spo2, in: events), [98, 97, 97, 96, 97, 96, 97, 95])
        XCTAssertEqual(values(.hrv, in: events), [52, 43, 177, 95, 33, 33, 61, 128])

        // BP at offsets 7/8 — the last record (06:00) reads 106/70, verified against the app. History BP
        // rides `.historyMeasurement` (upsert on (kind, timestamp)), *not* `.bloodPressureSample`: the
        // ring replays its whole log on every sync, so appending samples would duplicate every row.
        XCTAssertEqual(values(.bloodPressureSystolic, in: events), [115, 112, 112, 109, 111, 111, 110, 106])
        XCTAssertEqual(values(.bloodPressureDiastolic, in: events).last, 70)
        XCTAssertFalse(events.contains { if case .bloodPressureSample = $0 { return true } else { return false } })

        // Steps are the ring's cumulative daily counter, so they ride `.activityUpdate` (per-day max),
        // not an additive bucket. First record = the 23:00 daily total.
        let steps = events.compactMap { event -> Int? in
            if case let .activityUpdate(_, value, _, _) = event { return value } else { return nil }
        }
        XCTAssertEqual(steps.max(), 3336)
    }

    /// Respiratory rate (@10) was decoded but silently dropped before A3.
    func testCombinedVitalsDecodesRespiratoryRate() {
        let events = YCBTHealthRecords.combinedVitals(capturedAllRecords)
        XCTAssertEqual(values(.respiratoryRate, in: events), [14, 13, 13, 12, 13, 12, 13, 12])
        XCTAssertEqual(MeasurementKind.respiratoryRate.unit, "brpm")
    }

    /// Every record in the capture carries `tempInt = 0, tempFrac = 15` and `bloodSugar = 0` — the ring's
    /// "never measured" fillers (SmartHealth's own chart drops exactly `frac == 15`). Neither may become
    /// a 0.15 °C reading or a 0 mg/dL one.
    func testCombinedVitalsSkipsUnmeasuredTemperatureAndBloodSugar() {
        let events = YCBTHealthRecords.combinedVitals(capturedAllRecords)
        XCTAssertEqual(values(.temperature, in: events), [])
        XCTAssertEqual(values(.bloodSugar, in: events), [])
    }

    /// A record that *does* carry them: temp `36 . 6` and blood sugar raw 55 = 5.5 mmol/L → 99.09 mg/dL.
    func testCombinedVitalsDecodesTemperatureAndBloodSugarWhenPresent() {
        let events = YCBTHealthRecords.combinedVitals(bytes("1cf0de31721046764f610f3a0324061504370000"))
        XCTAssertEqual(values(.temperature, in: events).first ?? 0, 36.6, accuracy: 0.001)
        XCTAssertEqual(values(.bloodSugar, in: events).first ?? 0, 99.088, accuracy: 0.001)
        XCTAssertEqual(MeasurementKind.bloodSugar.unit, "mg/dL")
    }

    /// An unworn record (SpO₂ out of range, HRV 0, BP 0) still carries the day's step count — and
    /// nothing else.
    func testUnwornCombinedVitalsRecordYieldsStepsOnly() {
        let events = YCBTHealthRecords.combinedVitals(bytes("1cf0de31080d4700000000000000000000000000"))
        XCTAssertEqual(events.count, 1)
        guard case .activityUpdate = events.first else {
            return XCTFail("expected a lone activityUpdate, got \(events)")
        }
    }

    /// Records are sliced from the whole buffer, so a trailing partial record is dropped rather than
    /// misaligning the ones before it.
    func testPartialTrailingRecordIsDropped() {
        let events = YCBTHealthRecords.heartRate(bytes("1cf0de310047" + "1afede3100"))
        XCTAssertEqual(events.count, 1)
    }

    // MARK: Sleep (variable-length sessions)

    func testSleepDecodesAFullNightMatchingTheApp() {
        // One 420-byte session from the capture; stage totals verified against the app's on-screen
        // breakdown (deep 93 / light 249 / rem 130 min — the deltas below are per-segment rounding).
        guard case let .sleepTimeline(_, stages) = YCBTHealthRecords.sleep(capturedNight).first else {
            return XCTFail("expected a sleepTimeline")
        }
        XCTAssertEqual(Double(stages.filter { $0 == .deep }.count), 93, accuracy: 3)
        XCTAssertEqual(Double(stages.filter { $0 == .light }.count), 249, accuracy: 3)
        XCTAssertEqual(Double(stages.filter { $0 == .rem }.count), 130, accuracy: 3)
        XCTAssertFalse(stages.contains(.awake))
    }

    /// The buffer can hold several nights back to back — each session's 20-byte header carries its own
    /// length at [2..3], so the decoder walks them rather than assuming one.
    func testMultipleSessionsInOneBuffer() {
        let timelines = YCBTHealthRecords.sleep(capturedNight + capturedNight).filter { event in
            if case .sleepTimeline = event { return true } else { return false }
        }
        XCTAssertEqual(timelines.count, 2)
    }

    /// Stage tags are classified by `tag & 0x0F`, and an unrecognised tag is *skipped*, never terminal.
    /// The old decoder exact-matched `0xF1…0xF4` and `break`ed on anything else, so one `0xF5` nap
    /// segment truncated the rest of the night.
    func testNapSegmentDoesNotTruncateTheNight() {
        let session = sleepSession(segments: [
            (0xf2, 60 * 60),      // light, 1h
            (0xf5, 20 * 60),      // nap → .unknown, must not end the list
            (0xf1, 30 * 60),      // deep, 30m — only reachable if the nap didn't break the loop
        ])
        guard case let .sleepTimeline(_, stages) = YCBTHealthRecords.sleep(session).first else {
            return XCTFail("expected a sleepTimeline")
        }
        XCTAssertEqual(stages.filter { $0 == .light }.count, 60)
        XCTAssertEqual(stages.filter { $0 == .unknown }.count, 20)
        XCTAssertEqual(stages.filter { $0 == .deep }.count, 30, "the segment after the nap must survive")
    }

    /// Segment durations are **u24**, not u16 — a 20-hour segment (72 000 s) truncates to 6 464 s when
    /// read as two bytes.
    func testSegmentDurationIsU24() {
        let session = sleepSession(segments: [(0xf2, 72_000)])
        guard case let .sleepTimeline(_, stages) = YCBTHealthRecords.sleep(session).first else {
            return XCTFail("expected a sleepTimeline")
        }
        XCTAssertEqual(stages.count, 1200)   // 72 000 s / 60
    }

    /// Some firmware repeats a segment inside one session; the SDK skips a start time it has already
    /// taken (`DataUnpack` case 4 keeps a list of them). Without that guard the repeat is counted twice —
    /// and because the timeline is laid out positionally, it also shifts every later stage by its own
    /// duration, so the whole night after it lands in the wrong place.
    func testRepeatedSegmentIsCountedOnce() {
        var session = sleepSession(segments: [(0xf2, 30 * 60), (0xf1, 30 * 60), (0xf3, 30 * 60)])
        // Re-send the deep segment verbatim (same start, same length) as a fourth segment.
        let deep = Array(session[(20 + 8)..<(20 + 16)])
        session[2] = UInt8(20 + 4 * 8)   // recordLen now claims four segments
        session.append(contentsOf: deep)

        guard case let .sleepTimeline(_, stages) = YCBTHealthRecords.sleep(session).first else {
            return XCTFail("expected a sleepTimeline")
        }
        XCTAssertEqual(stages.filter { $0 == .deep }.count, 30, "the repeat must not double the stage")
        XCTAssertEqual(stages.count, 90, "…and must not push the rest of the night 30 min late")
    }

    /// A truncated transfer (the header promises more segments than the buffer holds) must not read off
    /// the end — the SDK's own loop has no such guard.
    func testTruncatedSessionIsClamped() {
        var session = sleepSession(segments: [(0xf2, 600), (0xf1, 600)])
        session.removeLast(8)   // drop the second segment but leave the header's length claiming it
        guard case let .sleepTimeline(_, stages) = YCBTHealthRecords.sleep(session).first else {
            return XCTFail("expected a sleepTimeline")
        }
        XCTAssertEqual(stages.count, 10)
    }

    // MARK: SpO₂ (query 0x1A, 6-byte records)

    func testSpo2RecordsDecode() {
        // 97 %, an unmeasured record (0), 95 %.
        let events = YCBTHealthRecords.spo2(bytes("1cf0de3100611afede310100260cdf31005f"))
        XCTAssertEqual(values(.spo2, in: events), [97, 95])
        XCTAssertEqual(timestamps(in: events).first, YCBTBytes.date(836_694_044))
    }

    // MARK: Blood pressure (query 0x08, 8-byte records)

    /// `[ts][isInflated@4][sys@5][dia@6][hr@7]`. Two upserting history rows, plus the HR the sweep
    /// measured alongside them — and *not* a `.bloodPressureSample` (that would append a duplicate row
    /// on every re-sync, since the ring never forgets a record).
    func testBloodPressureRecordsDecode() {
        let events = YCBTHealthRecords.bloodPressure(bytes("1cf0de3101764f401afede3100000000"))
        XCTAssertEqual(values(.bloodPressureSystolic, in: events), [118])
        XCTAssertEqual(values(.bloodPressureDiastolic, in: events), [79])
        XCTAssertEqual(values(.heartRate, in: events), [64])
        XCTAssertFalse(events.contains { if case .bloodPressureSample = $0 { return true } else { return false } })
        XCTAssertEqual(timestamps(in: events).first, YCBTBytes.date(836_694_044))
    }

    // MARK: Body data (query 0x33, 28-byte records)

    /// hrv `(62, 5)` = 62.5 ms, stress (the SDK's "pressure") `(5, 3)` = **53**, fatigue (its "body")
    /// `(4, 2)` = **42**, VO₂max `42`.
    ///
    /// The two int/frac pairs are read on *different scales* on purpose. HRV is milliseconds, so it is
    /// the SDK's string-concatenated composite (`Float.parseFloat("62.5")`). Stress and fatigue are
    /// 0–10 scores that SmartHealth renders ×10 on a 1…100 scale — `getCompositePressure()` is
    /// `Integer.parseInt("5" + "3")` and the live screen does `(int)(parseFloat("5.3") * 10)` — so 5.3
    /// would be the app's 53, ten times low, inside PulseLoop's own 1…100 stress scale.
    func testBodyDataDecodesHrvInMsAndStressFatigueOnTheAppsHundredScale() {
        let events = YCBTHealthRecords.bodyData(capturedBodyRecord)
        XCTAssertEqual(values(.hrv, in: events).first ?? 0, 62.5, accuracy: 0.001)
        XCTAssertEqual(values(.stress, in: events).first ?? 0, 53, accuracy: 0.001)
        XCTAssertEqual(values(.fatigue, in: events).first ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(values(.vo2max, in: events).first ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(MeasurementKind.vo2max.unit, "mL/kg/min")
        XCTAssertEqual(timestamps(in: events).first, YCBTBytes.date(836_694_044))
    }

    /// The scale, at the seam where it is easy to get wrong: a whole-number score has fraction 0, and
    /// `(7, 0)` is 70 — not 7, and not 7.0. `RingEventBridge.stressRange` (1…100) can't catch a 10×
    /// error, so this is the only place it is pinned.
    func testStressScoreIsDigitConcatenatedNotADecimalComposite() {
        XCTAssertEqual(YCBTHealthRecords.score(5, 3), 53, accuracy: 0.001)
        XCTAssertEqual(YCBTHealthRecords.score(7, 0), 70, accuracy: 0.001)
        XCTAssertEqual(YCBTHealthRecords.score(10, 0), 100, accuracy: 0.001)
        XCTAssertEqual(YCBTHealthRecords.composite(5, 3), 5.3, accuracy: 0.001, "hrv/temperature keep the composite")
    }

    /// A record too short to hold the fields from @16 on (old firmware is rumoured to send a ~17-byte
    /// prefix; a truncated transfer produces the same shape) must not read into the next record's bytes —
    /// or off the end of the buffer. The stride slicer drops the partial; the full record before it lands.
    func testShortBodyDataRecordIsDroppedNotMisread() {
        let events = YCBTHealthRecords.bodyData(capturedBodyRecord + Array(capturedBodyRecord.prefix(17)))
        XCTAssertEqual(values(.hrv, in: events).count, 1)
        XCTAssertEqual(values(.vo2max, in: events), [42])
    }

    // MARK: Sport (query 0x02, 14-byte records)

    /// `[start][end][steps@8][distance@10][calories@12]` → an *additive* bucket (unlike the All record's
    /// cumulative step counter). Calories are dropped — `.activityBucket` has no calorie channel.
    func testSportRecordsDecodeToActivityBuckets() {
        let events = YCBTHealthRecords.sport(bytes("1cf0de31a0f3de318002e00119001afede319e01df31000000000000"))
        XCTAssertEqual(events.count, 1, "the all-zero record is not a bucket")
        guard case let .activityBucket(timestamp, steps, distance) = events.first else {
            return XCTFail("expected an activityBucket, got \(events)")
        }
        XCTAssertEqual(timestamp, YCBTBytes.date(836_694_044), "the bucket is stamped with the record's start")
        XCTAssertEqual(steps, 640)
        XCTAssertEqual(distance, 480)
    }

    // MARK: Temperature (query 0x1E, 7-byte records)

    /// `Float.parseFloat(int + "." + frac)` in the SDK, so the fraction's scale follows its digit count:
    /// `5` → `36.5`, `25` → `36.25`. The third record is the `int = 0` no-sample filler.
    func testTemperatureRecordsDecodeWithStringConcatFraction() {
        let events = YCBTHealthRecords.temperature(bytes("1cf0de310024051afede31002419260cdf3100000f"))
        let temps = values(.temperature, in: events)
        XCTAssertEqual(temps.count, 2)
        XCTAssertEqual(temps[0], 36.5, accuracy: 0.001)
        XCTAssertEqual(temps[1], 36.25, accuracy: 0.001)
        XCTAssertEqual(MeasurementKind.temperature.unit, "°C")
        XCTAssertEqual(timestamps(in: events).first, YCBTBytes.date(836_694_044))
    }

    /// `frac == 15` is the ring's "no sample" marker **whatever the integer is** — SmartHealth's chart
    /// drops on the fraction alone. A record left with a stale integer (`36, 15`) would otherwise decode
    /// to a 36.15 °C reading that the bridge's 30…45 °C gate happily passes, and the ring replays its
    /// whole log on every sync, so it would be re-upserted forever. Both records here are fillers.
    func testTemperatureFillerFractionIsDroppedEvenWithANonZeroInteger() {
        let events = YCBTHealthRecords.temperature(bytes("1cf0de3100240f" + "1afede3100000f"))
        XCTAssertEqual(values(.temperature, in: events), [])
    }

    // MARK: Comprehensive (query 0x2F, 44-byte records)

    /// Blood sugar at @5–6 is `int * 10 + frac` **tenths of a mmol/L** (SmartHealth files it in the same
    /// column it filters to 11…333, i.e. 1.1…33.3 mmol/L). 5.5 mmol/L × 18.016 = 99.09 mg/dL, the unit
    /// PulseLoop stores. The second record is unmeasured.
    func testComprehensiveDecodesBloodSugarAsMgdl() {
        let events = YCBTHealthRecords.comprehensive(bytes(
            "1cf0de3101050500000000000000000000000000000000000000000000000000000000000000000000000000" +
            "1afede31010000000000000000000000000000000000000000000000000000000000000000000000000000000000"))
        let sugar = values(.bloodSugar, in: events)
        XCTAssertEqual(sugar.count, 1)
        XCTAssertEqual(sugar[0], 99.088, accuracy: 0.001)
        XCTAssertEqual(timestamps(in: events).first, YCBTBytes.date(836_694_044))
    }

    // MARK: Type table → decoder wiring

    /// `decode(_:type:)` is what the transfer machine actually calls; every catalog type must reach a
    /// decoder (a type wired to no decoder would ACK and silently discard a whole transfer).
    func testEveryCatalogTypeDecodesThroughTheTypeTable() {
        let spo2 = bytes("1cf0de3100611afede310100260cdf31005f")
        let blood = bytes("1cf0de3101764f401afede3100000000")
        let sport = bytes("1cf0de31a0f3de318002e00119001afede319e01df31000000000000")
        let temperature = bytes("1cf0de310024051afede31002419260cdf3100000f")

        XCTAssertEqual(YCBTHealthRecords.decode(spo2, type: .spo2).count, 2)
        XCTAssertEqual(YCBTHealthRecords.decode(blood, type: .blood).count, 3)         // sys + dia + hr
        XCTAssertEqual(YCBTHealthRecords.decode(sport, type: .sport).count, 1)
        XCTAssertEqual(YCBTHealthRecords.decode(temperature, type: .temperature).count, 2)
        // hrv + stress + fatigue + vo2max
        XCTAssertEqual(YCBTHealthRecords.decode(capturedBodyRecord, type: .bodyData).count, 4)
        // 8 records × (steps + systolic + diastolic + spo2 + respiratory rate + hrv); temp and blood
        // sugar are the unmeasured fillers in this capture.
        XCTAssertEqual(YCBTHealthRecords.decode(capturedAllRecords, type: .all).count, 8 * 6)
        XCTAssertFalse(YCBTHealthRecords.decode(capturedNight, type: .sleep).isEmpty)
        XCTAssertFalse(YCBTHealthRecords.decode(capturedHeartRecords, type: .heart).isEmpty)
    }

    // MARK: Fixtures

    /// Values of one kind, in record order.
    private func values(_ kind: MeasurementKind, in events: [RingDecodedEvent]) -> [Double] {
        events.compactMap { event in
            if case let .historyMeasurement(eventKind, value, _) = event, eventKind == kind { return value }
            return nil
        }
    }

    /// Timestamps of the history measurements, in record order — proves the epoch is read from bytes 0–3.
    private func timestamps(in events: [RingDecodedEvent]) -> [Date] {
        events.compactMap { event in
            if case let .historyMeasurement(_, _, timestamp) = event { return timestamp }
            return nil
        }
    }

    /// One 28-byte body-data record: `[ts][load 3.2][hrv 62.5][stress 5,3][fatigue 4,2][symp 5.5]`
    /// `[sdnn 48][vo2max 42][pnn50 12][rmssd 55][lf 1200][hf 900][lfHf 1.3]`.
    private lazy var capturedBodyRecord: [UInt8] = bytes("1cf0de3103023e0505030402050530002a0c3700b00484030d000000")

    /// Eight hourly overnight 6-byte heart records from the capture, matched to its wall clock.
    private lazy var capturedHeartRecords: [UInt8] = bytes(
        "1cf0de3100471afede310042260cdf31003f3b1adf31003e4328df3100425136df31003c6444df3100419852df31003a")

    /// Eight 20-byte "All" records from the capture (23:00–06:00).
    private lazy var capturedAllRecords: [UInt8] = bytes(
        "1cf0de31080d47734c620e3404000f00000033de1afede31000042704a610d2b02000f000000d24b260cdf3100003f70" +
        "49610db106000f000000ce273b1adf3100003e6d49600c5f02000f00000077a54328df310000426f49610d2105000f00" +
        "0000474b5136df3100003c6f47600c2104000f00000024f66444df310000416e49610d3d05000f00000015769852df31" +
        "00003a6a465f0c8002000f000000d89d")

    /// Build one sleep session: a 20-byte header (`recordLen` at [2..3]) + 8-byte
    /// `[tag][segStart:u32][len:u24]` segments, one hour apart.
    private func sleepSession(segments: [(tag: UInt8, seconds: Int)]) -> [UInt8] {
        let recordLength = 20 + segments.count * 8
        var out: [UInt8] = [0xaf, 0xfa, UInt8(recordLength & 0xff), UInt8(recordLength >> 8)]
        out.append(contentsOf: [UInt8](repeating: 0, count: 16))   // start/end/counts — unused by the decoder
        for (index, segment) in segments.enumerated() {
            let start = 0x31def01c + index * 3600
            out.append(segment.tag)
            out.append(contentsOf: [UInt8(start & 0xff), UInt8((start >> 8) & 0xff),
                                    UInt8((start >> 16) & 0xff), UInt8((start >> 24) & 0xff)])
            out.append(contentsOf: [UInt8(segment.seconds & 0xff), UInt8((segment.seconds >> 8) & 0xff),
                                    UInt8((segment.seconds >> 16) & 0xff)])
        }
        return out
    }

    private lazy var capturedNight: [UInt8] = bytes(
        "affaa4019fe9de31bd58df31ffff971efb15733af29fe9de313c0500f1dceede312d0100f30af0de31d90100f2e4f1de31c9" +
        "0400f1aef6de31320100f3e1f7de31c10100f2a3f9de31b50400f159fede319b0100f3f5ffde31b00100f2a501df31660200" +
        "f10b04df313d0500f34809df31ae0800f2f611df31cc0100f1c213df31170200f3d915df317d0100f25617df31ef0000f345" +
        "18df31060100f24b19df31670200f1b21bdf31910000f2431cdf31030000f3461cdf314c0000f2921cdf31f70100f3891edf" +
        "31720200f2fb20df31e00000f3db21df31590100f23423df310e0100f34224df31d30100f21526df317a0000f38f26df31c1" +
        "0000f25027df31be0400f10f2cdf312f0100f33f2ddf31aa0100f2ea2edf317a0500f16534df316b0100f3d135df319e0000" +
        "f17036df319e0100f20e38df31450500f1543ddf318b0100f3e03edf31de0100f2bf40df31000500f1c045df315e0100f31f" +
        "47df31730100f29348df31a00000f13449df319c0000f2d049df316d0500f13e4fdf31410100f38050df31d80100f25952df" +
        "31050100f15f53df311e0100f27d54df31400400")
}
