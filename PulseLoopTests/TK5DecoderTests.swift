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

    func testHistoryShortFramePacksEightHourlyHR() {
        // One 05 15 frame carries eight 6-byte HR records (overnight hourly samples); all must decode.
        let frame = TK5Frame(validating: bytes(
            "051536001cf0de3100471afede310042260cdf31003f3b1adf31003e4328df3100425136df31003c6444df3100419852df31003aa951"))!
        let hr = decoder.decode(frame).compactMap { event -> Double? in
            if case let .historyMeasurement(.heartRate, value, _) = event { return value } else { return nil }
        }
        XCTAssertEqual(hr, [71, 66, 63, 62, 66, 60, 65, 58])
    }

    func testHistoryLongFramePacksPeriodicSpo2AndHRV() {
        // One 05 18 frame carries eight 20-byte combined-vitals records; each yields SpO₂ + HRV.
        let frame = TK5Frame(validating: bytes(
            "0518a6001cf0de31080d47734c620e3404000f00000033de1afede31000042704a610d2b02000f000000d24b260cdf310000" +
            "3f7049610db106000f000000ce273b1adf3100003e6d49600c5f02000f00000077a54328df310000426f49610d2105000f00" +
            "0000474b5136df3100003c6f47600c2104000f00000024f66444df310000416e49610d3d05000f00000015769852df310000" +
            "3a6a465f0c8002000f000000d89dc5a3"))!
        let events = decoder.decode(frame)
        let spo2 = events.compactMap { e -> Double? in
            if case let .historyMeasurement(.spo2, v, _) = e { return v } else { return nil }
        }
        let hrv = events.compactMap { e -> Double? in
            if case let .historyMeasurement(.hrv, v, _) = e { return v } else { return nil }
        }
        XCTAssertEqual(spo2, [98, 97, 97, 96, 97, 96, 97, 95])
        XCTAssertEqual(hrv, [52, 43, 177, 95, 33, 33, 61, 128])
        // Periodic BP at offsets 7/8 — last record (06:00) verified 106/70 against the app.
        let bp = events.compactMap { e -> (Int, Int)? in
            if case let .bloodPressureSample(s, d, _) = e { return (s, d) } else { return nil }
        }
        XCTAssertEqual(bp.map(\.0), [115, 112, 112, 109, 111, 111, 110, 106])   // systolic
        XCTAssertEqual(bp.last?.1, 70)                                          // 06:00 diastolic
        // Cumulative per-day steps emitted as activityUpdate (max per day); this frame's first record
        // carries the 23:00 daily total of 3336.
        let steps = events.compactMap { e -> Int? in
            if case let .activityUpdate(_, s, _, _) = e { return s } else { return nil }
        }
        XCTAssertEqual(steps.max(), 3336)
    }

    func testLiveExtendedDisambiguatesBPvsHRV() {
        // 06 03 in BP mode: [sys][dia]… → 111/74 (verified against the app's 6:52 reading).
        let bpFrame = TK5Frame(validating: bytes("060314006f4a44000000000000000000000074f1"))!
        guard case let .bloodPressureSample(sys, dia, _) = decoder.decode(bpFrame).first else {
            return XCTFail("expected bloodPressureSample")
        }
        XCTAssertEqual([sys, dia], [111, 74])
        // 06 03 in HRV mode: [0,0,0,hrv]… → HRV, not misread as BP.
        let hrvFrame = TK5Frame(validating: bytes("06031400000000b1000000000000000000001579"))!
        guard case let .hrvSample(value, _) = decoder.decode(hrvFrame).first else {
            return XCTFail("expected hrvSample")
        }
        XCTAssertEqual(value, 177)
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

    // MARK: Sleep

    func testSleepDecodeMatchesAppBreakdown() {
        // Reassembled 05 13 sleep record (3 frames concatenated). Stage tags f1=deep/f2=light/f3=rem,
        // verified against the app's on-screen breakdown (deep 93 / light 249 / rem 130 min; the small
        // deltas below are per-segment minute rounding).
        let record = bytes(
            "affaa4019fe9de31bd58df31ffff971efb15733af29fe9de313c0500f1dceede312d0100f30af0de31d90100f2e4f1de31c9" +
            "0400f1aef6de31320100f3e1f7de31c10100f2a3f9de31b50400f159fede319b0100f3f5ffde31b00100f2a501df31660200" +
            "f10b04df313d0500f34809df31ae0800f2f611df31cc0100f1c213df31170200f3d915df317d0100f25617df31ef0000f345" +
            "18df31060100f24b19df31670200f1b21bdf31910000f2431cdf31030000f3461cdf314c0000f2921cdf31f70100f3891edf" +
            "31720200f2fb20df31e00000f3db21df31590100f23423df310e0100f34224df31d30100f21526df317a0000f38f26df31c1" +
            "0000f25027df31be0400f10f2cdf312f0100f33f2ddf31aa0100f2ea2edf317a0500f16534df316b0100f3d135df319e0000" +
            "f17036df319e0100f20e38df31450500f1543ddf318b0100f3e03edf31de0100f2bf40df31000500f1c045df315e0100f31f" +
            "47df31730100f29348df31a00000f13449df319c0000f2d049df316d0500f13e4fdf31410100f38050df31d80100f25952df" +
            "31050100f15f53df311e0100f27d54df31400400")
        guard case let .sleepTimeline(_, stages) = decoder.decodeSleep([UInt8](record)).first else {
            return XCTFail("expected sleepTimeline")
        }
        // Per-minute rounding means totals land within a couple minutes of the app's displayed values.
        XCTAssertEqual(Double(stages.filter { $0 == .light }.count), 249, accuracy: 3)
        XCTAssertEqual(Double(stages.filter { $0 == .deep }.count), 93, accuracy: 3)
        XCTAssertEqual(Double(stages.filter { $0 == .rem }.count), 130, accuracy: 3)
        XCTAssertFalse(stages.contains(.awake))
    }

    // MARK: Live-measurement mode selection

    func testLiveMeasurementModesUseDistinctSensors() {
        // The 03 2f payload's mode byte selects the sensor/LED; each metric must use its own.
        let e = TK5Encoder()
        XCTAssertEqual(e.heartRateStart(), [0x03, 0x2f, 0x01, 0x00])  // HR (green)
        XCTAssertEqual(e.spo2Start(), [0x03, 0x2f, 0x01, 0x02])       // SpO₂ (red/IR)
        XCTAssertEqual(e.hrvStart(), [0x03, 0x2f, 0x01, 0x0a])        // HRV
        XCTAssertEqual(e.liveStreamStop(), [0x03, 0x2f, 0x00, 0x00])  // stop (mode-agnostic)
    }

    // MARK: Startup

    func testStartupEnablesLiveStatusStream() {
        // Without `03 09 01 00 02` the ring never auto-pushes 06 00 status, so live steps freeze.
        let seq = TK5Encoder().startupSequence()
        XCTAssertTrue(seq.contains([0x03, 0x09, 0x01, 0x00, 0x02]),
                      "startup must enable the live status auto-push")
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
