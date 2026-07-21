import XCTest
import CoreBluetooth
@testable import PulseLoop

/// Unit tests for CRP inbound decoding + reassembly (`CRPDecoder`, `CRPFrameAssembler`) and the
/// `CRPDriver.ingest` routing. Byte layouts are from the decompiled Moyoung app (`e1/k.b` steps,
/// `g1/a.B` heart rate, `g1/a.k` frame reassembly). No BLE stack needed. Ported from the Android
/// app's `CRPDecoderTest.kt`.
@MainActor
final class CRPDecoderTests: XCTestCase {

    private let fdd1 = CRPUUIDs.stepsNotifyCBUUID
    private let fdd3 = CRPUUIDs.cmdNotifyCBUUID
    private let hr = CRPUUIDs.heartRateMeasureCBUUID

    func testCurrentStepsPushDecodesLittleEndianStepsDistanceCalories() {
        // steps=1000 (E8 03 00), distance=500 (F4 01 00), calories=42 (2A 00 00)
        let data = Data([0xE8, 0x03, 0x00, 0xF4, 0x01, 0x00, 0x2A, 0x00, 0x00])
        let events = CRPDecoder.decode(data, from: fdd1)
        XCTAssertEqual(events.count, 1)
        guard case let .activityUpdate(_, steps, distanceMeters, calories) = events[0] else {
            return XCTFail("expected activityUpdate, got \(events[0])")
        }
        XCTAssertEqual(steps, 1000)
        XCTAssertEqual(distanceMeters, 500)
        XCTAssertEqual(calories, 42)
    }

    func testStepsPushWithOnlyTheStepTripleDecodesDistanceAndCaloriesZero() {
        guard case let .activityUpdate(_, steps, distanceMeters, calories) =
                CRPDecoder.decode(Data([0x0A, 0x00, 0x00]), from: fdd1)[0] else {
            return XCTFail("expected activityUpdate")
        }
        XCTAssertEqual(steps, 10)
        XCTAssertEqual(distanceMeters, 0)
        XCTAssertEqual(calories, 0)
    }

    func testStepsPushOfNonMultipleOfThreeLengthIsRejected() {
        XCTAssertTrue(CRPDecoder.decode(Data([1, 2]), from: fdd1).isEmpty)
    }

    func testHeartRate2a37ReadsBpmFromByte1WhenThe0x0400MarkerIsPresent() {
        // [status, bpm=72, 0x00, 0x04] -> marker bytes[2..3] == 0x0400
        guard case let .heartRateSample(bpm, _) = CRPDecoder.decode(Data([0x00, 72, 0x00, 0x04]), from: hr)[0] else {
            return XCTFail("expected heartRateSample")
        }
        XCTAssertEqual(bpm, 72)
    }

    func testHeartRate2a37WithWrongMarkerIsDropped() {
        XCTAssertTrue(CRPDecoder.decode(Data([0x00, 72, 0x00, 0x08]), from: hr).isEmpty)
    }

    func testHeartRate2a37WithZeroBpmIsDropped() {
        XCTAssertTrue(CRPDecoder.decode(Data([0x00, 0, 0x00, 0x04]), from: hr).isEmpty)
    }

    func testAssemblerReturnsASinglePacketFrameImmediately() {
        let a = CRPFrameAssembler()
        let frame = CRPProtocol.frame(group: 1, cmd: 9, payload: [0x50]) // len 7
        XCTAssertEqual(a.append(frame), frame)
    }

    func testAssemblerReassemblesAFrameSplitAcrossTwoNotifications() {
        let a = CRPFrameAssembler()
        // A 10-byte frame: FD DA 10 0A 02 05 + 4 payload bytes, delivered as 6 + 4.
        let full = CRPProtocol.frame(group: 2, cmd: 5, payload: [1, 2, 3, 4]) // size 10
        XCTAssertNil(a.append(Data(full.prefix(6))))          // header only — not complete
        let done = a.append(Data(full.suffix(4)))             // continuation completes it
        XCTAssertEqual(done, full)
    }

    func testAssemblerDropsAContinuationWithNoInProgressFrame() {
        let a = CRPFrameAssembler()
        XCTAssertNil(a.append(Data([1, 2, 3, 4])))
    }

    func testDriverRoutesFdd1ToStepsAndReassemblesFdd3Replies() {
        let driver = CRPDriver(writer: nil)
        let steps = driver.ingest(Data([0x05, 0x00, 0x00]), from: fdd1)
        XCTAssertEqual(steps.count, 1)
        guard case .activityUpdate = steps[0] else { return XCTFail("expected activityUpdate") }

        // A framed reply split across two fdd3 notifications yields exactly one decoded event.
        let full = CRPProtocol.frame(group: 1, cmd: 9, payload: [0x50]) // size 7
        XCTAssertTrue(driver.ingest(Data(full.prefix(4)), from: fdd3).isEmpty)
        XCTAssertEqual(driver.ingest(Data(full.suffix(3)), from: fdd3).count, 1)
    }
}
