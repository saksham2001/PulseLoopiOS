import XCTest
@testable import PulseLoop

/// Decoder/encoder parity against the byte-exact captures in Protocol.md. Pure — no hardware.
final class RingDecoderTests: XCTestCase {
    private let decoder = RingDecoder()

    private func decode(_ hex: String) -> RingDecodedEvent {
        decoder.decode((try? Data(hexString: hex)) ?? Data())
    }

    func testActivityPacket() {
        // 03 + ts + steps(0x148=328) + distance(0x11f=287) + calories(0x12=18)
        let event = decode("03fd7c156a480100001f01000012000000504600")
        guard case let .activityUpdate(_, steps, distance, calories) = event else {
            return XCTFail("expected activityUpdate, got \(event.kind)")
        }
        XCTAssertEqual(steps, 328)
        XCTAssertEqual(distance, 287)
        XCTAssertEqual(calories, 18)
        XCTAssertEqual(event.confidence, .known)
    }

    func testHeartRateSample() {
        let event = decode("14bbec146a500000000000000000000000000000")
        guard case let .heartRateSample(bpm, _) = event else {
            return XCTFail("expected heartRateSample, got \(event.kind)")
        }
        XCTAssertEqual(bpm, 0x50) // 80 bpm
    }

    func testSpO2Result() {
        let event = decode("245e774d63050000000000000000000000000000")
        guard case let .spo2Result(value, _) = event else {
            return XCTFail("expected spo2Result, got \(event.kind)")
        }
        XCTAssertEqual(value, 99)
    }

    func testSpO2Progress() {
        let event = decode("2400000000000000000000000000000000000000")
        guard case .spo2Progress = event else {
            return XCTFail("expected spo2Progress, got \(event.kind)")
        }
        XCTAssertEqual(event.confidence, .partial)
    }

    func testBatteryPercentStatus() {
        let event = decode("0b37000000000000000000000000000000000000")
        guard case let .battery(percent) = event else {
            return XCTFail("expected battery, got \(event.kind)")
        }
        XCTAssertEqual(percent, 0x37) // 55%
    }

    func testStatusAddress() {
        let event = decode("0c7a0041422ec75b6a3a00160000000000000000")
        guard case let .status(address) = event else {
            return XCTFail("expected status, got \(event.kind)")
        }
        XCTAssertEqual(address, "41:42:2e:c7:5b:6a")
    }

    func testSleepTimelineLight() {
        let event = decode("11989a176a282828282828282828282828282828")
        guard case let .sleepTimeline(_, stages) = event else {
            return XCTFail("expected sleepTimeline, got \(event.kind)")
        }
        XCTAssertEqual(stages.count, 15)
        XCTAssertTrue(stages.allSatisfy { $0 == .light })
    }

    func testUnknownPacketStaysInspectable() {
        let event = decode("5200000000010000000000000000000000000000")
        guard case .unknown = event else {
            return XCTFail("expected unknown, got \(event.kind)")
        }
        XCTAssertEqual(event.confidence, .unknown)
    }

    func testTimeSyncCommandLayout() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let data = [UInt8](RingEncoder().makeTimeSyncCommand(date: date))
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(data[0], 0x01)
        let ts = UInt32(data[1]) | UInt32(data[2]) << 8 | UInt32(data[3]) << 16 | UInt32(data[4]) << 24
        XCTAssertEqual(ts, 1_700_000_000)
    }

    func testGoalCommandLayout() {
        let data = [UInt8](RingEncoder().makeGoalCommand(steps: 10000))
        XCTAssertEqual(data[0], 0x1a)
        let value = UInt32(data[1]) | UInt32(data[2]) << 8 | UInt32(data[3]) << 16 | UInt32(data[4]) << 24
        XCTAssertEqual(value, 10000)
    }
}
