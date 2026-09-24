import XCTest
@testable import PulseLoop

/// Record layouts for both RWfit framings, with fixtures assembled from the vendor parsers'
/// byte math (`x5/b.java`, functions cited per test). **Timezone conversion is the priority**:
/// both firmwares stamp local wall-clock epochs, and every fixture asserts the exact UTC `Date`
/// that comes back out.
@MainActor
final class RWfitDecoderTests: XCTestCase {

    /// Kolkata: +05:30, no DST — the offset is deterministic year-round, and the half-hour width
    /// catches any whole-hour assumption in the conversion.
    private let timeZone = TimeZone(identifier: "Asia/Kolkata")!
    private let offset: UInt32 = 19_800

    /// 2026-08-01 00:00:00 UTC.
    private let utc = Date(timeIntervalSince1970: 1_785_542_400)

    private var decoder: RWfitDecoder {
        RWfitDecoder(clock: RWfitClock(timeZone: timeZone, now: Date(timeIntervalSince1970: 1_785_542_400)))
    }

    /// The ring-stamped legacy epoch for `utc` offset by `delta` seconds.
    private func legacyEpoch(_ delta: UInt32 = 0) -> [UInt8] {
        RWfitBytes.packU32BE(Int(1_785_542_400 + offset + delta))
    }

    /// The ring-stamped JieLi epoch (seconds since 2000-01-01, local) for `utc` + `delta`.
    private func jieliEpoch(_ delta: UInt32 = 0) -> [UInt8] {
        RWfitBytes.packU32BE(Int(1_785_542_400 - 946_684_800 + offset + delta))
    }

    private func cat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    // MARK: - Clock

    func testClockSubtractsCapturedOffsetForBothEpochs() {
        let clock = RWfitClock(timeZone: timeZone, now: utc)
        XCTAssertEqual(clock.date(fromLegacyEpoch: 1_785_542_400 + offset), utc)
        XCTAssertEqual(clock.date(fromJieliEpoch: 1_785_542_400 - 946_684_800 + offset), utc)
    }

    /// Deliberate divergence from the vendor's DST math: the captured offset is applied to *every*
    /// record uniformly (the `JringClock` contract). The vendor's legacy path adds a fixed hour
    /// whenever the zone merely *observes* DST — wrong half the year — and its JieLi path uses the
    /// offset at parse time, wrong for records that crossed a boundary. Constant-offset is the
    /// documented tradeoff; this test pins it.
    func testClockUsesCaptureTimeOffsetNotRecordTimeOffset() {
        let newYorkSummer = Date(timeIntervalSince1970: 1_785_542_400)   // EDT, UTC-4
        let clock = RWfitClock(timeZone: TimeZone(identifier: "America/New_York")!, now: newYorkSummer)
        XCTAssertEqual(clock.offsetSeconds, -14_400)
        // A record six months out still gets the captured offset — no per-record re-evaluation.
        let winterLocal = UInt32(1_800_000_000 - 14_400)
        XCTAssertEqual(clock.date(fromLegacyEpoch: winterLocal),
                       Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - Legacy history

    func testLegacyHeartRateDaySeries() {
        // `w0()` @2914: day hdr `[ts u32][count u16]`, 5-byte items `[ts u32][bpm]`.
        let payload = cat(
            legacyEpoch(), [0x00, 0x03],
            legacyEpoch(0), [72],
            legacyEpoch(300), [0],      // zero bpm = no sample; dropped
            legacyEpoch(600), [95]
        )
        let events = decoder.decodeLegacy(cmd: RWfitLegacyCommand.heartRateHistory, payload: payload)
        XCTAssertEqual(events.count, 2)
        guard case let .historyMeasurement(kind, value, timestamp) = events[0] else {
            return XCTFail("expected historyMeasurement, got \(events)")
        }
        XCTAssertEqual(kind, .heartRate)
        XCTAssertEqual(value, 72)
        XCTAssertEqual(timestamp, utc, "local wall-clock epoch converted back to UTC")
        guard case let .historyMeasurement(_, value2, timestamp2) = events[1] else { return XCTFail("unexpected event shape") }
        XCTAssertEqual(value2, 95)
        XCTAssertEqual(timestamp2, utc.addingTimeInterval(600))
    }

    func testLegacyBloodPressureSplitsIntoTwoKinds() {
        // `s0()`: 6-byte items `[ts u32][systolic][diastolic]`.
        let payload = cat(legacyEpoch(), [0x00, 0x01], legacyEpoch(60), [120, 80])
        let events = decoder.decodeLegacy(cmd: RWfitLegacyCommand.bloodPressureHistory, payload: payload)
        guard events.count == 2,
              case let .historyMeasurement(kind1, sys, ts1) = events[0],
              case let .historyMeasurement(kind2, dia, ts2) = events[1] else {
            return XCTFail("expected two split measurements, got \(events)")
        }
        XCTAssertEqual([kind1, kind2], [.bloodPressureSystolic, .bloodPressureDiastolic])
        XCTAssertEqual([sys, dia], [120, 80])
        XCTAssertEqual(ts1, ts2)
        XCTAssertEqual(ts1, utc.addingTimeInterval(60))
    }

    func testLegacyTemperatureScaling() {
        // `u0()`: `(raw + 200) / 10` °C.
        let payload = cat(legacyEpoch(), [0x00, 0x01], legacyEpoch(), [165])
        let events = decoder.decodeLegacy(cmd: RWfitLegacyCommand.temperatureHistory, payload: payload)
        guard case let .historyMeasurement(kind, value, _)? = events.first else { return XCTFail("unexpected event shape") }
        XCTAssertEqual(kind, .temperature)
        XCTAssertEqual(value, 36.5, accuracy: 0.001)
    }

    func testLegacyStepsPublishesOneDayBucketFromHeaderTotals() {
        // `C0()` @397: 15-byte hdr + 8-byte slot items. Slot wall-clock width is unproven, so the
        // decoder publishes the header totals as one bucket at the day timestamp.
        let payload = cat(
            legacyEpoch(), [0x00, 0x1e, 0x0a],       // 7690 steps (u24)
            [0x00, 0x01, 0x2c],                       // 300 kcal (u24, unused)
            [0x00, 0x14, 0x00],                       // 5120 distance (u24)
            [0x00, 0x02],                             // 2 slot items follow
            [1, 0x00, 0x64, 0, 0, 10, 0x00, 0x20],
            [2, 0x00, 0xc8, 0, 0, 20, 0x00, 0x40]
        )
        let events = decoder.decodeLegacy(cmd: RWfitLegacyCommand.stepsHistory, payload: payload)
        guard case let .activityBucket(timestamp, steps, distance)? = events.first, events.count == 1 else {
            return XCTFail("expected exactly one day bucket, got \(events)")
        }
        XCTAssertEqual(steps, 7_690)
        XCTAssertEqual(distance, 5_120)
        XCTAssertEqual(timestamp, utc)
    }

    func testLegacySleepNightExpandsToPerMinuteStages() {
        // `A0()` @180: 16-byte night hdr + 2-byte `[minutes][type]` items running from asleepTime;
        // types 0 awake / 1 light / 2 deep / 3 REM (`service/s1.java:1635`).
        let payload = cat(
            legacyEpoch(), [0x01, 0x2c],              // night ts, totalMin 300 (unused)
            legacyEpoch(0),                            // asleep epoch
            legacyEpoch(6_000),                        // awake epoch (unused)
            [0x00, 0x04],
            [30, 1], [45, 2], [10, 0], [15, 3]
        )
        let events = decoder.decodeLegacy(cmd: RWfitLegacyCommand.sleepHistory, payload: payload)
        guard case let .sleepTimeline(timestamp, stages)? = events.first else {
            return XCTFail("expected sleepTimeline, got \(events)")
        }
        XCTAssertEqual(timestamp, utc, "the timeline starts at the asleep epoch")
        XCTAssertEqual(stages.count, 100)
        XCTAssertEqual(stages[0], .light)
        XCTAssertEqual(stages[30], .deep)
        XCTAssertEqual(stages[75], .awake)
        XCTAssertEqual(stages[85], .rem)
        XCTAssertEqual(stages[99], .rem)
    }

    func testLegacyFeatureBitmapGatesCapabilities() {
        // SupportMenuBean byte 0, LSB-first: bit 3 bloodPress, bit 5 bodyTemp (`x5/b.java:1872`).
        XCTAssertEqual(RWfitDecoder.capabilities(fromLegacyFeatures: [0b0010_1000]),
                       [.bloodPressure, .temperature])
        XCTAssertEqual(RWfitDecoder.capabilities(fromLegacyFeatures: [0b0000_0111]), [],
                       "step/sleep/hr bits are baseline — they gate nothing")
    }

    func testLegacyBatteryAndBind() {
        let battery = decoder.decodeLegacy(cmd: RWfitLegacyCommand.battery, payload: [0, 1, 87])
        guard case let .battery(percent)? = battery.first else { return XCTFail("unexpected event shape") }
        XCTAssertEqual(percent, 87)

        let bind = decoder.decodeLegacy(cmd: RWfitLegacyCommand.bindStatus, payload: [1, 2, 0x50, 0x00])
        guard case let .bind(action, state)? = bind.first else { return XCTFail("unexpected event shape") }
        XCTAssertEqual(action, 1)
        XCTAssertEqual(state, 2)
    }

    // MARK: - JieLi history

    func testJieliHeartRateSeries() {
        // `V()` @1291: 6-byte items from offset 3, `[ts2000 u32][bpm][pad]`; zero bpm dropped.
        let payload = cat([0x05, 0x03, 0x10], jieliEpoch(), [64, 0], jieliEpoch(300), [0, 0])
        let events = decoder.decodeJieli(
            triple: RWfitJLTriple(cmd: 0x05, key: 0x03, keyFlag: 0x10), payload: payload
        )
        XCTAssertEqual(events.count, 1)
        guard case let .historyMeasurement(kind, value, timestamp)? = events.first else { return XCTFail("unexpected event shape") }
        XCTAssertEqual(kind, .heartRate)
        XCTAssertEqual(value, 64)
        XCTAssertEqual(timestamp, utc, "2000-epoch + local offset both unwound")
    }

    func testJieliStepsRecord() {
        // `a0()` @1549: 16-byte records; steps u24 at +5, distance u32 at +12 in decimetres.
        let payload = cat(
            [0x05, 0x02, 0x10],
            jieliEpoch(), [0x00],
            [0x00, 0x1e, 0x0a],                       // 7690 steps
            [0x00, 0x00, 0x0b, 0xb8],                 // 3000 (kcal ×10, unused)
            [0x00, 0x00, 0xc8, 0x00]                  // 51200 dm → 5120 m
        )
        let events = decoder.decodeJieli(
            triple: RWfitJLTriple(cmd: 0x05, key: 0x02, keyFlag: 0x10), payload: payload
        )
        guard case let .activityBucket(timestamp, steps, distance)? = events.first else {
            return XCTFail("expected activityBucket, got \(events)")
        }
        XCTAssertEqual(steps, 7_690)
        XCTAssertEqual(distance, 5_120, accuracy: 0.001)
        XCTAssertEqual(timestamp, utc)
    }

    func testJieliSleepEventStreamReconstruction() {
        // `Z()` @1520 + `s1.java:1004`: 7-byte `[ts2000][model][pad2]` transition stream; 0x11
        // opens (first segment counts as light), 1 deep, 4 REM, 0x22 closes; durations are the
        // deltas between consecutive records.
        let payload = cat(
            [0x05, 0x05, 0x10],
            jieliEpoch(0), [0x11, 0, 0],
            jieliEpoch(600), [1, 0, 0],
            jieliEpoch(1_800), [4, 0, 0],
            jieliEpoch(2_400), [0x22, 0, 0]
        )
        let events = decoder.decodeJieli(
            triple: RWfitJLTriple(cmd: 0x05, key: 0x05, keyFlag: 0x10), payload: payload
        )
        guard case let .sleepTimeline(timestamp, stages)? = events.first else {
            return XCTFail("expected sleepTimeline, got \(events)")
        }
        XCTAssertEqual(timestamp, utc)
        XCTAssertEqual(stages.count, 40)
        XCTAssertEqual(Array(stages[0..<10]), Array(repeating: SleepStage.light, count: 10))
        XCTAssertEqual(Array(stages[10..<30]), Array(repeating: SleepStage.deep, count: 20))
        XCTAssertEqual(Array(stages[30..<40]), Array(repeating: SleepStage.rem, count: 10))
    }

    func testJieliTemperatureAndBloodSugarScaling() {
        // SDK: whole Celsius + truncated hundredths. Blood sugar is u16 ÷ 10 mmol/L.
        let temp = decoder.decodeJieli(
            triple: RWfitJLTriple(cmd: 0x05, key: 0x08, keyFlag: 0x10),
            payload: cat([0x05, 0x08, 0x10], jieliEpoch(), [36, 59])   // 36 + floor(59 / 10) / 10 → 36.5 °C
        )
        guard case let .historyMeasurement(kind, celsius, _)? = temp.first else { return XCTFail("unexpected event shape") }
        XCTAssertEqual(kind, .temperature)
        XCTAssertEqual(celsius, 36.5, accuracy: 0.001)

        let sugar = decoder.decodeJieli(
            triple: RWfitJLTriple(cmd: 0x05, key: 0x10, keyFlag: 0x10),
            payload: cat([0x05, 0x10, 0x10], jieliEpoch(), [0x00, 0x37])   // 5.5 mmol/L
        )
        guard case let .historyMeasurement(kind2, mgdl, _)? = sugar.first else { return XCTFail("unexpected event shape") }
        XCTAssertEqual(kind2, .bloodSugar)
        XCTAssertEqual(mgdl, 5.5 * 18.016, accuracy: 0.01)
    }

    func testFunctionMenuUsesDocumentedOffsetsAndGlobalHealthGate() {
        var payload = [UInt8](repeating: 0, count: 0x5f)
        payload[0] = 2; payload[1] = 0x63; payload[2] = 0x10
        for offset in [0x2c, 0x53, 0x54, 0x55, 0x56, 0x59, 0x5a, 0x5e] { payload[offset] = 1 }
        let menu = RWfitFunctionMenu(payload: payload)
        XCTAssertEqual(menu?.historyTypes, [.steps, .todaySteps, .heartRate, .bloodPressure, .spo2, .hrv, .temperature])
        XCTAssertEqual(menu?.requiresPassword, true)
        XCTAssertTrue(menu?.capabilities.contains(.manualHeartRate) == true)
        payload[0x53] = 0
        XCTAssertEqual(RWfitFunctionMenu(payload: payload)?.historyTypes, [])
        XCTAssertNil(RWfitFunctionMenu(payload: Array(payload.dropLast())))
    }

    func testJieliBatteryFirmwareAndRealtime() {
        let battery = decoder.decodeJieli(
            triple: .battery, payload: [0x02, 0x03, 0x10, 76, 0x0e, 0xd8]
        )
        guard case let .battery(percent)? = battery.first else { return XCTFail("unexpected event shape") }
        XCTAssertEqual(percent, 76)

        let info = decoder.decodeJieli(
            triple: .deviceInfo, payload: [0x02, 0x04, 0x10, 1, 2, 11]
        )
        guard case let .firmware(version)? = info.first else { return XCTFail("unexpected event shape") }
        XCTAssertEqual(version, "1.2.11")

        let status = decoder.decodeJieli(
            triple: .realtimeMeasure, payload: [0x06, 0x09, 0x00, 0x03, 0x05, 0]
        )
        guard case let .rwfitMeasurementStatus(type, value)? = status.first else {
            return XCTFail("expected completion status, never a reading")
        }
        XCTAssertEqual(type, 3)
        XCTAssertEqual(value, 0)
    }

    func testLiveResultsUseTimestampedSixByteRecords() {
        let hr = decoder.decodeJieli(
            triple: RWfitJLTriple(cmd: 2, key: 0x24, keyFlag: 0),
            payload: cat([2, 0x24, 0], jieliEpoch(), [72, 0])
        )
        guard case let .heartRateSample(bpm, timestamp)? = hr.first else { return XCTFail("expected live HR") }
        XCTAssertEqual(bpm, 72)
        XCTAssertEqual(timestamp, utc)
        let bp = decoder.decodeJieli(
            triple: RWfitJLTriple(cmd: 2, key: 0x31, keyFlag: 0),
            payload: cat([2, 0x31, 0], jieliEpoch(), [120, 80])
        )
        guard case let .bloodPressureSample(sys, dia, _)? = bp.first else { return XCTFail("expected BP") }
        XCTAssertEqual(sys, 120)
        XCTAssertEqual(dia, 80)
    }

    func testLiveOxygenHrvAndTemperature() {
        let oxygen = decoder.decodeJieli(
            triple: RWfitJLTriple(cmd: 2, key: 0x4e, keyFlag: 0),
            payload: cat([2, 0x4e, 0], jieliEpoch(), [98, 0])
        )
        guard case let .spo2Result(value, _)? = oxygen.first else { return XCTFail("expected SpO2") }
        XCTAssertEqual(value, 98)
        let hrv = decoder.decodeJieli(
            triple: RWfitJLTriple(cmd: 2, key: 0x69, keyFlag: 0),
            payload: cat([2, 0x69, 0], jieliEpoch(), [45, 0])
        )
        guard case let .hrvSample(ms, _)? = hrv.first else { return XCTFail("expected HRV") }
        XCTAssertEqual(ms, 45)
        let temperature = decoder.decodeJieli(
            triple: RWfitJLTriple(cmd: 2, key: 0x30, keyFlag: 0),
            payload: cat([2, 0x30, 0], jieliEpoch(), [36, 59])
        )
        guard case let .temperatureSample(celsius, _)? = temperature.first else { return XCTFail("expected temperature") }
        XCTAssertEqual(celsius, 36.5, accuracy: 0.001)
    }

    func testTodayStepsEmitsCumulativeTotal() throws {
        let payload = cat([5, 0x1a, 0x10], jieliEpoch(), [0, 0, 0x03, 0xe8],
                          RWfitBytes.packU32BE(1250), RWfitBytes.packU32BE(5000))
        let events = try decoder.validatedJieliHistory(key: 0x1a, payload: payload)
        guard case let .activityUpdate(timestamp, steps, meters, calories)? = events.first else {
            return XCTFail("expected cumulative current-day activity")
        }
        XCTAssertEqual(timestamp, utc)
        XCTAssertEqual(steps, 1000)
        XCTAssertEqual(meters, 500)
        XCTAssertEqual(calories, 125)
    }

    func testTodayStepsPreservesHourlyDetailsBeforeCumulativeTotal() throws {
        let total = cat([5, 0x1a, 0x10], jieliEpoch(), [0, 0, 0x03, 0xe8],
                        RWfitBytes.packU32BE(1250), RWfitBytes.packU32BE(5000))
        let hour = cat(jieliEpoch(3600), [1, 0, 0, 100],
                       RWfitBytes.packU32BE(100), RWfitBytes.packU32BE(500))
        let events = try decoder.validatedJieliHistory(key: 0x1a, payload: total + hour)
        XCTAssertEqual(events.count, 2)
        guard case let .activityBucket(timestamp, steps, meters) = events[0] else {
            return XCTFail("expected hourly bucket")
        }
        XCTAssertEqual(timestamp, utc.addingTimeInterval(3600))
        XCTAssertEqual(steps, 100)
        XCTAssertEqual(meters, 50)
        guard case let .activityUpdate(_, cumulative, _, _) = events[1] else {
            return XCTFail("expected separate cumulative total, never a 1000-step bucket")
        }
        XCTAssertEqual(cumulative, 1000)
        let bridged = events.flatMap { RingEventBridge.events(for: $0, now: utc.addingTimeInterval(7200)) }
        XCTAssertEqual(bridged.count, 2)
        guard case .activityBucket = bridged[0], case .activityUpdate = bridged[1] else {
            return XCTFail("bridge must preserve bucket versus cumulative semantics")
        }
    }

    func testValidatedHistoryRejectsPartialRecordsAndIncompleteSleep() throws {
        XCTAssertThrowsError(try decoder.validatedJieliHistory(key: 3, payload: [5, 3, 0x10, 1]))
        XCTAssertTrue(try decoder.validatedJieliHistory(key: 3, payload: [5, 3, 0x10]).isEmpty)
        let open = cat([5, 5, 0x10], jieliEpoch(), [0x11, 0, 0])
        XCTAssertNoThrow(try RWfitDecoder.validateJieliSleepPage(open))
        XCTAssertThrowsError(try decoder.validatedJieliHistory(key: 5, payload: open))
        let end = cat(jieliEpoch(600), [0x22, 0, 0])
        let joined = open + end + Array(open.dropFirst(3))
        let events = try decoder.validatedJieliHistory(key: 5, payload: joined)
        guard case let .sleepTimeline(_, stages)? = events.first else { return XCTFail("expected assembled sleep") }
        XCTAssertEqual(stages.count, 10)
    }

    func testSleepDeduplicatesChangedFlagsButRejectsConflictingStages() throws {
        let start = cat(jieliEpoch(), [0x11, 0, 0])
        let changedFlags = cat(jieliEpoch(), [0x11, 1, 0xff])
        let end = cat(jieliEpoch(600), [0x22, 0, 0])
        let events = try decoder.validatedJieliHistory(
            key: 5, payload: [5, 5, 0x10] + start + end + changedFlags
        )
        guard case let .sleepTimeline(_, stages)? = events.first else { return XCTFail("expected sleep") }
        XCTAssertEqual(stages.count, 10)
        let conflicting = cat(jieliEpoch(), [1, 0, 0])
        XCTAssertThrowsError(try decoder.validatedJieliHistory(
            key: 5, payload: [5, 5, 0x10] + start + conflicting + end
        ))
    }

    func testSDKStartupCommandBytes() {
        let encoder = RWfitEncoder()
        XCTAssertEqual(encoder.sessionInitialize(), .jieli(payload: [3, 2, 0x20, 0, 0, 0, 1]))
        XCTAssertEqual(encoder.timezone(offsetSeconds: -14400), .jieli(payload: [2, 2, 0, 0xf0, 1]))
        XCTAssertEqual(encoder.functionMenu(), .jieli(payload: [2, 0x63, 0x10]))
        XCTAssertEqual(encoder.authenticate(), .jieli(payload: [3, 4, 0x10, 48, 48, 48, 48]))
        XCTAssertEqual(encoder.historyDelete(type: 5), .jieli(payload: [5, 5, 0x30]))
    }
}
