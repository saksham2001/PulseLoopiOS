import XCTest
@testable import PulseLoop

/// The pure `RingDecodedEvent → [PulseEvent]` mapping, including its sanity gates.
final class EventBridgeTests: XCTestCase {

    // MARK: - History-measurement plausibility

    func testHistoryMeasurementInWindowMapsThrough() {
        let now = Date()
        let events = RingEventBridge.events(
            for: .historyMeasurement(kind: .heartRate, value: 70, timestamp: now.addingTimeInterval(-900)),
            now: now
        )
        XCTAssertEqual(events.count, 1)
    }

    /// A jring's on-ring log can still hold records stamped under an older *UTC* clock. Once the app
    /// sets the ring's RTC to local time, those decode hours into the future — observed at +3.7 h on a
    /// real device. They must be dropped, not persisted (they would poison "today" and peak HR).
    func testFutureHistoryMeasurementDropped() {
        let now = Date()
        XCTAssertTrue(RingEventBridge.events(
            for: .historyMeasurement(kind: .heartRate, value: 70, timestamp: now.addingTimeInterval(3.7 * 3600)),
            now: now
        ).isEmpty)
    }

    /// Anything older than the ~8-day history horizon is a misdecoded frame.
    func testAncientHistoryMeasurementDropped() {
        let now = Date()
        XCTAssertTrue(RingEventBridge.events(
            for: .historyMeasurement(kind: .heartRate, value: 70, timestamp: now.addingTimeInterval(-9 * 24 * 3600)),
            now: now
        ).isEmpty)
    }

    // MARK: - Per-kind history gates (YCBT/TK5 history types)
    //
    // History is where a range gate earns its keep: the ring replays its *entire* log on every sync and
    // history rows upsert on (kind, timestamp), so a misdecoded record re-persists on every future sync.

    /// One value each side of the gate, per kind.
    private struct Gate {
        let kind: MeasurementKind
        let accepted: Double
        let rejected: Double
    }

    func testHistoryMeasurementRangeGatesPerKind() {
        let gates = [
            // The floor is the display floor of consumer oximetry, not its 70 % accuracy spec: 12 % is a
            // misdecoded byte, but 68 % is a desaturation the QRing-Colmi log has always been allowed to
            // report (see `ColmiDecoderTests.testSevereDesaturationSurvivesTheSharedHistoryGate`).
            Gate(kind: .spo2, accepted: 68, rejected: 12),
            Gate(kind: .hrv, accepted: 62.5, rejected: 0),
            Gate(kind: .stress, accepted: 34.25, rejected: 0),
            Gate(kind: .fatigue, accepted: 18, rejected: 0),
            Gate(kind: .temperature, accepted: 36.6, rejected: 0.15),   // the ring's `int=0, frac=15` filler
            Gate(kind: .bloodPressureSystolic, accepted: 118, rejected: 300),
            Gate(kind: .bloodPressureDiastolic, accepted: 79, rejected: 10),
            Gate(kind: .bloodSugar, accepted: 99.088, rejected: 10),
            Gate(kind: .respiratoryRate, accepted: 14, rejected: 90),
            Gate(kind: .vo2max, accepted: 42, rejected: 5),
        ]
        let now = Date()
        let timestamp = now.addingTimeInterval(-900)
        for gate in gates {
            XCTAssertEqual(
                RingEventBridge.events(
                    for: .historyMeasurement(kind: gate.kind, value: gate.accepted, timestamp: timestamp), now: now
                ).count,
                1, "\(gate.kind) \(gate.accepted) should map through"
            )
            XCTAssertTrue(
                RingEventBridge.events(
                    for: .historyMeasurement(kind: gate.kind, value: gate.rejected, timestamp: timestamp), now: now
                ).isEmpty,
                "\(gate.kind) \(gate.rejected) should be dropped"
            )
        }
    }

    /// Every kind must be *reachable* through the gate — a kind accidentally left out of the range
    /// switch would silently persist garbage (or, worse, drop everything).
    func testEveryMeasurementKindHasAPlausibleValueThatMapsThrough() {
        let plausible: [MeasurementKind: Double] = [
            .heartRate: 70, .spo2: 97, .stress: 40, .hrv: 55, .temperature: 36.6,
            .bloodPressureSystolic: 118, .bloodPressureDiastolic: 79, .fatigue: 20,
            .bloodSugar: 99, .respiratoryRate: 14, .vo2max: 42,
        ]
        let now = Date()
        for kind in MeasurementKind.allCases {
            guard let value = plausible[kind] else {
                XCTFail("new MeasurementKind \(kind) — add a plausible value here and a gate in RingEventBridge")
                continue
            }
            XCTAssertEqual(
                RingEventBridge.events(
                    for: .historyMeasurement(kind: kind, value: value, timestamp: now.addingTimeInterval(-900)),
                    now: now
                ).count,
                1, "\(kind) has no path through the history gate"
            )
        }
    }

    func testHeartRateSampleMapsThrough() {
        let events = RingEventBridge.events(for: .heartRateSample(bpm: 72, timestamp: Date()))
        XCTAssertEqual(events.count, 1)
        guard case .heartRateSample(72, _) = events[0] else {
            return XCTFail("expected heartRateSample")
        }
    }

    func testZeroBpmDropped() {
        XCTAssertTrue(RingEventBridge.events(for: .heartRateSample(bpm: 0, timestamp: Date())).isEmpty)
    }

    func testImplausibleBpmDropped() {
        // 0xb4 = 180 is the HR-start echo byte; values above the plausible range are dropped.
        XCTAssertTrue(RingEventBridge.events(for: .heartRateSample(bpm: 250, timestamp: Date())).isEmpty)
    }

    func testSpO2ResultMapsThrough() {
        let events = RingEventBridge.events(for: .spo2Result(value: 98, timestamp: Date()))
        guard case .spo2Result(98, _) = events.first else {
            return XCTFail("expected spo2Result")
        }
    }

    func testUnknownProducesNoTypedEvents() {
        XCTAssertTrue(RingEventBridge.events(for: .unknown(commandId: 0x52, raw: Data())).isEmpty)
    }

    // MARK: - 0x24 combined-sensor metric gates

    func testBloodPressureMapsThroughWhenPlausible() {
        let events = RingEventBridge.events(for: .bloodPressureSample(systolic: 120, diastolic: 80, timestamp: Date()))
        guard case .bloodPressureSample(120, 80, _) = events.first else {
            return XCTFail("expected bloodPressureSample")
        }
    }

    func testImplausibleBloodPressureDropped() {
        // Systolic 300 is out of the 60…250 range.
        XCTAssertTrue(RingEventBridge.events(for: .bloodPressureSample(systolic: 300, diastolic: 80, timestamp: Date())).isEmpty)
    }

    func testFatigueGate() {
        XCTAssertEqual(RingEventBridge.events(for: .fatigueSample(value: 50, timestamp: Date())).count, 1)
        XCTAssertTrue(RingEventBridge.events(for: .fatigueSample(value: 0, timestamp: Date())).isEmpty)
    }

    func testBloodSugarGate() {
        XCTAssertEqual(RingEventBridge.events(for: .bloodSugarSample(mgdl: 95, timestamp: Date())).count, 1)
        // 10 mg/dL is below the 40…600 plausible range.
        XCTAssertTrue(RingEventBridge.events(for: .bloodSugarSample(mgdl: 10, timestamp: Date())).isEmpty)
    }

    func testFirmwareMapsThrough() {
        guard case .firmwareVersion("003A002AV138") = RingEventBridge.events(for: .firmware(version: "003A002AV138")).first else {
            return XCTFail("expected firmwareVersion")
        }
    }

    func testBindProducesNoTypedEvents() {
        XCTAssertTrue(RingEventBridge.events(for: .bind(action: 0, state: 0)).isEmpty)
    }

    func testCommandAckProducesNoTypedEvents() {
        XCTAssertTrue(RingEventBridge.events(for: .commandAck(commandId: 0x02)).isEmpty)
    }

    func testStatusMapsToDeviceState() {
        let events = RingEventBridge.events(for: .status(address: "41:42:2e:c7:5b:6a"))
        guard case let .deviceStateChanged(state, address) = events.first else {
            return XCTFail("expected deviceStateChanged")
        }
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(address, "41:42:2e:c7:5b:6a")
    }

    func testStaleSleepTimelineRejected() {
        // The plausibility window is ~8 days (matches the Colmi multi-night history horizon),
        // so a timestamp well outside it indicates a misdecoded frame and must be dropped.
        let oldStart = Date().addingTimeInterval(-10 * 24 * 3600)
        XCTAssertTrue(RingEventBridge.events(for: .sleepTimeline(timestamp: oldStart, stages: [.light])).isEmpty)
    }

    func testRecentSleepTimelineAccepted() {
        let recent = Date().addingTimeInterval(-3 * 3600)
        let events = RingEventBridge.events(for: .sleepTimeline(timestamp: recent, stages: [.light, .deep]))
        guard case .sleepTimeline = events.first else {
            return XCTFail("expected sleepTimeline")
        }
    }

    // MARK: - live activity update plausibility gates

    func testActivityUpdateMapsThroughWhenPlausible() {
        let events = RingEventBridge.events(for: .activityUpdate(timestamp: Date(), steps: 8000, distanceMeters: 6200, calories: 320))
        guard case .activityUpdate(_, 8000, 6200, 320) = events.first else {
            return XCTFail("expected activityUpdate")
        }
    }

    func testImplausibleStepsDropped() {
        // A misframed u24 read paints millions of steps — well beyond the 100k daily ceiling.
        XCTAssertTrue(RingEventBridge.events(for: .activityUpdate(timestamp: Date(), steps: 16_700_000, distanceMeters: 0, calories: 0)).isEmpty)
    }

    func testImplausibleDistanceDropped() {
        // 1,000 km in a day is beyond the 120 km ceiling.
        XCTAssertTrue(RingEventBridge.events(for: .activityUpdate(timestamp: Date(), steps: 0, distanceMeters: 1_000_000, calories: 0)).isEmpty)
    }

    func testImplausibleCaloriesDropped() {
        // 50,000 kcal is beyond the 10,000 kcal ceiling.
        XCTAssertTrue(RingEventBridge.events(for: .activityUpdate(timestamp: Date(), steps: 0, distanceMeters: 0, calories: 50_000)).isEmpty)
    }

    func testFutureActivityTimestampDropped() {
        // A garbage ring-clock timestamp in the future would otherwise poison "today" permanently.
        let future = Date().addingTimeInterval(2 * 24 * 3600)
        XCTAssertTrue(RingEventBridge.events(for: .activityUpdate(timestamp: future, steps: 100, distanceMeters: 80, calories: 5)).isEmpty)
    }

    func testStaleActivityTimestampDropped() {
        let old = Date().addingTimeInterval(-10 * 24 * 3600)
        XCTAssertTrue(RingEventBridge.events(for: .activityUpdate(timestamp: old, steps: 100, distanceMeters: 80, calories: 5)).isEmpty)
    }

    func testRecentActivityTimestampAccepted() {
        let recent = Date().addingTimeInterval(-3600)
        let events = RingEventBridge.events(for: .activityUpdate(timestamp: recent, steps: 100, distanceMeters: 80, calories: 5))
        guard case .activityUpdate = events.first else {
            return XCTFail("expected activityUpdate")
        }
    }

    // MARK: - activity bucket boundary gates

    func testActivityBucketAtCeilingAccepted() {
        let events = RingEventBridge.events(for: .activityBucket(timestamp: Date(), steps: 4_999, distanceMeters: 5_999))
        guard case .activityBucket = events.first else {
            return XCTFail("expected activityBucket")
        }
    }

    func testActivityBucketAboveCeilingDropped() {
        // A single ~15-min bucket can't exceed the per-bucket step ceiling.
        XCTAssertTrue(RingEventBridge.events(for: .activityBucket(timestamp: Date(), steps: 5_001, distanceMeters: 0)).isEmpty)
    }

    /// A bucket carries a ring-supplied timestamp, and unlike a live update (which only ratchets today's
    /// row) it *creates* the day it is dated — so a sport record logged before the ring's first time-sync
    /// (RTC at the 2000 epoch) would mint an `ActivityDaily` for 2000-01-01 and re-upsert it on every
    /// sync, for good. Same ~8-day window as every other ring-stamped history event.
    func testActivityBucketWithAnImplausibleTimestampDropped() {
        let unsetRingClock = Date(timeIntervalSince1970: 946_684_800)   // 2000-01-01, the TK5 epoch
        XCTAssertTrue(RingEventBridge.events(
            for: .activityBucket(timestamp: unsetRingClock, steps: 120, distanceMeters: 90)).isEmpty)
    }
}
