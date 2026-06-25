import XCTest
@testable import PulseLoop

/// The pure `RingDecodedEvent → [PulseEvent]` mapping, including its sanity gates.
final class EventBridgeTests: XCTestCase {
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
}
