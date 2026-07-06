import XCTest
import CoreBluetooth
@testable import PulseLoop

/// TK5 protocol parity against the SmartHealth-app btsnoop capture (see docs/TK5-Protocol.md). Pure —
/// no hardware. Frame bytes are copied verbatim from the capture, so these exercise the CRC16/CCITT
/// round-trip, the decoder's field offsets, and coordinator recognition.
final class TK5DecoderTests: XCTestCase {
    private let decoder = TK5Decoder()

    private func bytes(_ hex: String) -> Data {
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let n = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<n], radix: 16)!)
            i = n
        }
        return Data(out)
    }

    // MARK: Framing / CRC

    func testCRC16MatchesCapturedSetTimeFrame() {
        // Captured set-time frame: 01 00 0e00 ea0707060c220e00 <crc=26c7>.
        let body = bytes("01000e00ea0707060c220e00")
        let crc = TK5Frame.crc16([UInt8](body))
        XCTAssertEqual(crc, 0xc726)   // little-endian on the wire = 26 c7
    }

    func testFrameBuildsLengthAndCRC() {
        // Logical [type, cmd, payload…] → full framed packet identical to the capture.
        let logical: [UInt8] = [0x01, 0x00, 0xea, 0x07, 0x07, 0x06, 0x0c, 0x22, 0x0e, 0x00]
        let framed = TK5Frame.frame(logical)
        XCTAssertEqual(framed.hexString, "01000e00ea0707060c220e0026c7")
    }

    func testValidatingRejectsBadCRC() {
        var raw = [UInt8](bytes("01000e00ea0707060c220e0026c7"))
        raw[raw.count - 1] ^= 0xff
        XCTAssertNil(TK5Frame(validating: Data(raw)))
    }

    func testValidatingRejectsWrongDeclaredLength() {
        // Declared length (0x00ff) doesn't match actual byte count.
        XCTAssertNil(TK5Frame(validating: bytes("0100ff00ea0707060c220e0026c7")))
    }

    // MARK: Decode — verified fields

    func testLiveHeartRateDecodes() {
        // 06 01 0700 <bpm=52> <crc> — captured live HR of 0x52 = 82 bpm.
        let frame = TK5Frame(validating: bytes("06010700521a55"))!
        guard case let .heartRateSample(bpm, _) = decoder.decode(frame).first else {
            return XCTFail("expected heartRateSample")
        }
        XCTAssertEqual(bpm, 82)
    }

    func testLiveStatusDecodesSteps() {
        // 06 00 0c00 7b02 9701 1a00 <crc> — steps 0x027b = 635.
        let frame = TK5Frame(validating: bytes("06000c007b0297011a00b60d"))!
        guard case let .activityUpdate(_, steps, distance, calories) = decoder.decode(frame).first else {
            return XCTFail("expected activityUpdate")
        }
        XCTAssertEqual(steps, 635)
        XCTAssertEqual(distance, 407)     // 0x0197 (capture-inferred)
        XCTAssertEqual(calories, 26)      // 0x001a (capture-inferred)
    }

    func testStatusDecodesBattery() {
        // 02 00 status; battery at payload[5] = 0x64 = 100.
        let frame = TK5Frame(validating: bytes("02001e00a30012010064000100030000000001000000010000000000ef10"))!
        let events = decoder.decode(frame)
        guard case let .battery(percent) = events.last else {
            return XCTFail("expected battery event")
        }
        XCTAssertEqual(percent, 100)
    }

    func testHistoryActivityRecordDecodesTimestampAndSteps() {
        // 05 18 record: ts (2000-epoch) + steps 0x027b = 635.
        let frame = TK5Frame(validating: bytes("05181a00f05dde317b0200000000003600000f000000b457896a"))!
        guard case let .activityBucket(timestamp, steps, _) = decoder.decode(frame).first else {
            return XCTFail("expected activityBucket")
        }
        XCTAssertEqual(steps, 635)
        // ts 0x31de5df0 in 2000-epoch seconds → 2026-07-06.
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: timestamp)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 6)
    }

    func testHistoryRecordDecodesHRV() {
        // Two 05 18 records copied verbatim from the capture; payload[11] = HRV, verified against the
        // app's displayed values (48 ms @1:00, 79 ms @1:32).
        for (hex, expected) in [
            ("05181a005f63de317b02446e4b620e3006000f000000d9ebc397", 48.0),
            ("05181a00ee6ade31de0200000000004f00000f000000b5e74ff0", 79.0),
        ] {
            let frame = TK5Frame(validating: bytes(hex))!
            let hrv = decoder.decode(frame).compactMap { event -> Double? in
                if case let .historyMeasurement(.hrv, value, _) = event { return value } else { return nil }
            }
            XCTAssertEqual(hrv, [expected], "HRV decode for \(hex)")
        }
    }

    // MARK: Coordinator recognition

    @MainActor
    func testCoordinatorMatchesTK5Name() {
        let noAdv = AdvertisementInfo(serviceUUIDs: [], manufacturerData: nil)
        XCTAssertTrue(TK5Coordinator.matches(name: "TK5 24AA", advertisement: noAdv))
        XCTAssertFalse(TK5Coordinator.matches(name: "SMART_RING", advertisement: noAdv))
        XCTAssertFalse(JringCoordinator.matches(name: "TK5 24AA", advertisement: noAdv))
    }

    @MainActor
    func testCoordinatorMatchesManufacturerPrefix() {
        let adv = AdvertisementInfo(
            serviceUUIDs: [],
            manufacturerData: bytes("10786501000101120000000000"))
        XCTAssertTrue(TK5Coordinator.matches(name: "Unlabeled", advertisement: adv))
    }
}
