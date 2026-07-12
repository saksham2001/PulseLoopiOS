import XCTest
import CoreBluetooth
@testable import PulseLoop

/// YCBT framing + live-stream decode, against the SmartHealth-app btsnoop capture. Pure — no hardware.
/// Frame bytes are copied verbatim from the capture, so these exercise the CRC16/CCITT round-trip and
/// the decoder's field offsets.
///
/// History lives elsewhere now: the transfer protocol is in `YCBTHistoryTransferTests`, the record
/// layouts in `YCBTHealthRecordsTests`, and GATT reassembly in `YCBTFrameAssemblerTests`. Health-group
/// (`0x05`) frames never reach `YCBTDecoder` at all.
final class YCBTDecoderTests: XCTestCase {
    private let decoder = YCBTDecoder()

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
        let crc = YCBTFrame.crc16([UInt8](body))
        XCTAssertEqual(crc, 0xc726)   // little-endian on the wire = 26 c7
    }

    func testFrameBuildsLengthAndCRC() {
        // Logical [type, cmd, payload…] → full framed packet identical to the capture.
        let logical: [UInt8] = [0x01, 0x00, 0xea, 0x07, 0x07, 0x06, 0x0c, 0x22, 0x0e, 0x00]
        let framed = YCBTFrame.frame(logical)
        XCTAssertEqual(framed.hexString, "01000e00ea0707060c220e0026c7")
    }

    func testValidatingRejectsBadCRC() {
        var raw = [UInt8](bytes("01000e00ea0707060c220e0026c7"))
        raw[raw.count - 1] ^= 0xff
        XCTAssertNil(YCBTFrame(validating: Data(raw)))
    }

    func testValidatingRejectsWrongDeclaredLength() {
        // Declared length (0x00ff) doesn't match actual byte count.
        XCTAssertNil(YCBTFrame(validating: bytes("0100ff00ea0707060c220e0026c7")))
    }

    // MARK: Live stream (be940003, group 0x06)

    func testLiveHeartRateDecodes() {
        // 06 01 0700 <bpm=52> <crc> — captured live HR of 0x52 = 82 bpm.
        let frame = YCBTFrame(validating: bytes("06010700521a55"))!
        guard case let .heartRateSample(bpm, _) = decoder.decode(frame).first else {
            return XCTFail("expected heartRateSample")
        }
        XCTAssertEqual(bpm, 82)
    }

    func testLiveStatusDecodesSteps() {
        // 06 00 0c00 7b02 9701 1a00 <crc> — steps 0x027b = 635.
        let frame = YCBTFrame(validating: bytes("06000c007b0297011a00b60d"))!
        guard case let .activityUpdate(_, steps, distance, calories) = decoder.decode(frame).first else {
            return XCTFail("expected activityUpdate")
        }
        XCTAssertEqual(steps, 635)
        XCTAssertEqual(distance, 407)     // 0x0197 (capture-inferred)
        XCTAssertEqual(calories, 26)      // 0x001a (capture-inferred)
    }

    /// `06 03` is one fixed layout (`unpackRealBloodData`), not two shapes: `[SBP][DBP][hr][hrv][spo2]`
    /// `[tempInt][tempFrac]`. The old "BP-vs-HRV heuristic" was reading exactly these offsets without
    /// knowing it — in BP mode the ring fills @0/@1 and zeroes @3, in HRV mode the reverse — so both
    /// captured frames still decode the same way.
    func testLiveVitalsDecodesBothCapturedShapes() {
        // 06 03 in BP mode: [sys=111][dia=74][hr=68]… (verified against the app's 6:52 reading).
        let bpFrame = YCBTFrame(validating: bytes("060314006f4a44000000000000000000000074f1"))!
        let bpEvents = decoder.decode(bpFrame)
        guard case let .bloodPressureSample(sys, dia, _) = bpEvents.first else {
            return XCTFail("expected bloodPressureSample first, got \(bpEvents)")
        }
        XCTAssertEqual([sys, dia], [111, 74])
        // The HR the BP sweep also measures used to be thrown away with the rest of the frame.
        XCTAssertEqual(bpEvents.compactMap { event -> Int? in
            if case let .heartRateSample(bpm, _) = event { return bpm } else { return nil }
        }, [68])

        // 06 03 in HRV mode: [0,0,0,hrv=177]… → HRV alone, not misread as BP.
        let hrvFrame = YCBTFrame(validating: bytes("06031400000000b1000000000000000000001579"))!
        let hrvEvents = decoder.decode(hrvFrame)
        guard case let .hrvSample(value, _) = hrvEvents.first else {
            return XCTFail("expected hrvSample first, got \(hrvEvents)")
        }
        XCTAssertEqual(value, 177)
        XCTAssertEqual(hrvEvents.count, 1, "zeroed fields are 'no sample', not readings")
    }

    /// SpO₂ and temperature ride the same frame's tail. Temperature is int/frac **string-concatenated**
    /// (`36` + `.` + `4`), not `int + frac/100` — the realtime report had that wrong; SmartHealth's own
    /// temperature screen does `Double.parseDouble(int + "." + frac)`.
    func testLiveVitalsDecodesSpO2AndTemperatureTail() {
        // [sys=118][dia=79][hr=70][hrv=42][spo2=97][tempInt=36][tempFrac=4]
        let frame = YCBTFrame(validating: YCBTFrame.frame([0x06, 0x03, 118, 79, 70, 42, 97, 36, 4]))!
        let events = decoder.decode(frame)

        XCTAssertEqual(events.compactMap { event -> Int? in
            if case let .spo2Result(value, _) = event { return value } else { return nil }
        }, [97])
        XCTAssertEqual(events.compactMap { event -> Double? in
            if case let .temperatureSample(celsius, _) = event { return celsius } else { return nil }
        }, [36.4])
    }

    // MARK: Live pushes (group 0x06)

    /// `06 15` (`unpackUploadBatteryLevel`): `[chargingStatus][percent]`. The ring pushes it unprompted,
    /// so battery stays fresh without polling `02 00`.
    func testBatteryPushDecodes() {
        let frame = YCBTFrame(validating: YCBTFrame.frame([0x06, 0x15, 0x01, 0x5b]))!
        guard case let .battery(percent) = decoder.decode(frame).first else {
            return XCTFail("expected battery")
        }
        XCTAssertEqual(percent, 91)
    }

    /// `06 13` (`unpackWearingStatusData`): `[ts:u32 2000-epoch][status]`. Debug-feed only — it produces
    /// no `PulseEvent`, so a wrong polarity guess can't reach the UI.
    func testWearingStatusPushDecodes() {
        let seconds = YCBTBytes.ringSeconds(Date())
        let ts: [UInt8] = (0..<4).map { UInt8((seconds >> (8 * $0)) & 0xff) }

        let worn = YCBTFrame(validating: YCBTFrame.frame([0x06, 0x13] + ts + [0x01]))!
        guard case let .wearingStatus(isWorn, timestamp) = decoder.decode(worn).first else {
            return XCTFail("expected wearingStatus")
        }
        XCTAssertTrue(isWorn)
        XCTAssertEqual(timestamp.timeIntervalSince1970, Date().timeIntervalSince1970, accuracy: 2)

        let removed = YCBTFrame(validating: YCBTFrame.frame([0x06, 0x13] + ts + [0x00]))!
        guard case let .wearingStatus(isWorn, _) = decoder.decode(removed).first else {
            return XCTFail("expected wearingStatus")
        }
        XCTAssertFalse(isWorn)

        // It must stay out of the typed fan-out — nothing in the app gates on wear state yet.
        XCTAssertTrue(RingEventBridge.events(for: .wearingStatus(worn: true, timestamp: Date())).isEmpty)
    }

    // MARK: Device pushes (group 0x04, DevControl)

    /// `04 13` MeasurStatusAndResults (1043): `[type][state]` then the value(s) for that type. `type` is
    /// the *same* mode byte `03 2f` starts a measurement with, so one table drives both.
    func testMeasurementStatusPushDecodesPerType() {
        func decodeStatus(_ payload: [UInt8]) -> [RingDecodedEvent] {
            decoder.decode(YCBTFrame(validating: YCBTFrame.frame([0x04, 0x13] + payload))!)
        }

        guard case let .heartRateSample(bpm, _) = decodeStatus([0x00, 0x01, 72]).first else {
            return XCTFail("type 0 → heart rate")
        }
        XCTAssertEqual(bpm, 72)

        guard case let .bloodPressureSample(sys, dia, _) = decodeStatus([0x01, 0x01, 118, 79]).first else {
            return XCTFail("type 1 → blood pressure")
        }
        XCTAssertEqual([sys, dia], [118, 79])

        guard case let .spo2Result(spo2, _) = decodeStatus([0x02, 0x01, 98]).first else {
            return XCTFail("type 2 → SpO₂")
        }
        XCTAssertEqual(spo2, 98)

        guard case let .temperatureSample(celsius, _) = decodeStatus([0x04, 0x01, 36, 5]).first else {
            return XCTFail("type 4 → temperature")
        }
        XCTAssertEqual(celsius, 36.5, accuracy: 0.001)

        // Blood sugar is tenths of mmol/L (`int * 10 + frac`), converted to the mg/dL the app stores.
        guard case let .bloodSugarSample(mgdl, _) = decodeStatus([0x05, 0x01, 5, 5]).first else {
            return XCTFail("type 5 → blood sugar")
        }
        XCTAssertEqual(mgdl, 5.5 * YCBTHealthRecords.mgdlPerMmol, accuracy: 0.001)
    }

    /// A warm-up push (state set, value still 0) must not surface a 0-bpm reading, and a type with no
    /// PulseLoop surface (3 = respiratory rate) must not fabricate one. Both just ack.
    func testMeasurementStatusPushWithNoValueAcks() {
        func decodeStatus(_ payload: [UInt8]) -> RingDecodedEvent? {
            decoder.decode(YCBTFrame(validating: YCBTFrame.frame([0x04, 0x13] + payload))!).first
        }
        guard case .commandAck = decodeStatus([0x00, 0x00, 0x00]) else {
            return XCTFail("a 0-value heart-rate push is a warm-up, not a reading")
        }
        guard case .commandAck = decodeStatus([0x03, 0x01, 16]) else {
            return XCTFail("respiratory rate has no live event; it must not be fabricated")
        }
    }

    /// `04 0e` MeasurementResult carries `[measureType][result]` and **no value** — it acks (and logs).
    func testMeasurementResultPushAcks() {
        let frame = YCBTFrame(validating: YCBTFrame.frame([0x04, 0x0e, 0x01, 0x02]))!
        guard case let .commandAck(commandId) = decoder.decode(frame).first else {
            return XCTFail("expected commandAck")
        }
        XCTAssertEqual(commandId, 0x0e)
    }

    // MARK: AppControl replies (group 0x03) — the ring's verdict on a `03 2f` start

    /// `03 2f` is answered with **one status byte and no mode**: `0x00` started, anything else refused.
    /// The R99 refuses HRV (mode `0x0a` → `0x01`) because it has no HRV sensor, and we only know *which*
    /// measurement was refused because the driver remembers the start it sent (`startedMode`).
    func testMeasurementStartReplyDistinguishesAcceptanceFromRefusal() throws {
        func reply(_ status: UInt8, startedMode: UInt8?) throws -> RingDecodedEvent {
            let frame = try XCTUnwrap(YCBTFrame(validating: YCBTFrame.frame([0x03, 0x2f, status])))
            return try XCTUnwrap(decoder.decode(frame, startedMode: startedMode).first)
        }

        guard case let .measurementRejected(mode) = try reply(0x01, startedMode: YCBTMeasurementMode.hrv) else {
            return XCTFail("a non-zero `03 2f` status is the ring refusing to start the measurement")
        }
        XCTAssertEqual(mode, YCBTMeasurementMode.hrv)

        // Status 0 is the ring *starting* the sweep — the reply every working measurement gets. If this
        // read as a rejection, every HR/SpO₂/BP reading would abort itself before it began.
        guard case .commandAck = try reply(0x00, startedMode: YCBTMeasurementMode.hrv) else {
            return XCTFail("status 0x00 is an acceptance, not a rejection")
        }

        // A refusal with no start outstanding belongs to nothing (a rejected stop, a duplicate reply):
        // it must not name a mode, because naming one is what cancels a measurement.
        guard case .commandAck = try reply(0x01, startedMode: nil) else {
            return XCTFail("a refusal that answers no start must stay an ack")
        }
    }

    /// The driver is the only thing that sees both directions, so it is what pairs the modeless reply with
    /// the start it came from — and what makes sure a *stray* refusal can't be attributed to anything.
    @MainActor
    func testDriverPairsARefusalWithTheStartItSentAndOnlyOnce() {
        let driver = makeDriver()
        let refusal = YCBTFrame.frame([0x03, 0x2f, 0x01])

        driver.send(start: YCBTMeasurementMode.hrv)
        guard case let .measurementRejected(mode) = driver.ingest(refusal, from: commandChannel).first else {
            return XCTFail("the refusal belongs to the start the driver just framed")
        }
        XCTAssertEqual(mode, YCBTMeasurementMode.hrv)

        // The start's one reply is spent: a duplicate or late frame answers no outstanding start.
        guard case .commandAck = driver.ingest(refusal, from: commandChannel).first else {
            return XCTFail("a second reply refers to no outstanding start")
        }

        // A rejected *stop* has no in-flight measurement to abort — it names no mode, so it stays an ack.
        driver.send(stop: YCBTMeasurementMode.hrv)
        guard case .commandAck = driver.ingest(refusal, from: commandChannel).first else {
            return XCTFail("a rejected stop is an ack, not a rejected measurement")
        }
    }

    /// **Two `03 2f` commands are routinely outstanding at once**, which is why the driver queues them
    /// instead of remembering one.
    ///
    /// Framing happens when a command is *enqueued* (`RingBLEClient.enqueueWrite` calls `frame(_:)` on the
    /// way into the serialized write queue), not when it reaches the wire — and every spot measurement ends
    /// with `engine.stopX()` immediately followed by `restartWorkoutHeartRateIfActive()`, so during a
    /// workout a stop and a start go into the queue back-to-back with both replies still owed.
    ///
    /// With one remembered mode the start overwrote the stop, the **stop's** `0x00` reply was then read as
    /// the start's verdict and cleared it, and the start's real refusal decoded anonymously and was
    /// swallowed — the ring said no and the user still watched the whole window run out, the exact failure
    /// this path exists to kill.
    @MainActor
    func testAStopsReplyDoesNotConsumeTheModeOfTheStartQueuedBehindIt() {
        let driver = makeDriver()

        // What `measureSpO2()` emits while a workout is streaming HR: stop SpO₂, then restart HR.
        driver.send(stop: YCBTMeasurementMode.spo2)
        driver.send(start: YCBTMeasurementMode.heartRate)

        // Reply 1 answers the stop. A stop names no measurement, so it can only ever be an ack …
        guard case .commandAck = driver.ingest(YCBTFrame.frame([0x03, 0x2f, 0x00]), from: commandChannel).first else {
            return XCTFail("the first reply answers the stop, which has no measurement to name")
        }
        // … and the HR start, still outstanding, keeps its mode for its own reply.
        guard case let .measurementRejected(mode) =
                driver.ingest(YCBTFrame.frame([0x03, 0x2f, 0x01]), from: commandChannel).first else {
            return XCTFail("the second reply is the start's refusal — swallowing it is the bug")
        }
        XCTAssertEqual(mode, YCBTMeasurementMode.heartRate)
    }

    /// The wrong-cancel half of the same pipelining bug: a **NAKed stop** must not cancel the measurement
    /// started right behind it. With one slot the start's mode was the only one held, so the stop's
    /// non-zero status decoded as a refusal *of the start* — aborting a measurement the ring had accepted
    /// and was busy running.
    @MainActor
    func testANakedStopCannotCancelTheMeasurementStartedBehindIt() {
        let driver = makeDriver()

        driver.send(stop: YCBTMeasurementMode.hrv)
        driver.send(start: YCBTMeasurementMode.heartRate)

        // The ring NAKs the stop (status 0x02). It refuses a *stop*: nothing is cancelled.
        let events = driver.ingest(YCBTFrame.frame([0x03, 0x2f, 0x02]), from: commandChannel)
        guard case .commandAck = events.first else {
            return XCTFail("a refused stop must never be attributed to the start queued behind it")
        }
        // The HR start's own reply is still owed, and still pairs with HR.
        guard case let .measurementRejected(mode) =
                driver.ingest(YCBTFrame.frame([0x03, 0x2f, 0x01]), from: commandChannel).first else {
            return XCTFail("the start's reply is still outstanding")
        }
        XCTAssertEqual(mode, YCBTMeasurementMode.heartRate)
    }

    /// A reconnect re-uses the driver, so commands the old link never answered must not pair with the new
    /// link's replies: the fresh connection's first `03 2f` verdict would otherwise be stamped with a dead
    /// command's mode.
    @MainActor
    func testAReconnectDropsTheCommandsTheOldLinkNeverAnswered() {
        let driver = makeDriver()
        driver.send(start: YCBTMeasurementMode.hrv)   // the ring drops out before replying

        driver.connectionDidEnd()
        driver.connectionDidStart()

        guard case .commandAck = driver.ingest(YCBTFrame.frame([0x03, 0x2f, 0x01]), from: commandChannel).first else {
            return XCTFail("the new connection owes nothing to a command the old one never answered")
        }
    }

    /// A rejection is a verdict on a command, not data: it must never reach the metric store. It travels
    /// on the raw-packet feed (whence `RingSyncCoordinator` reads it) and shows up in the debug trace.
    func testARejectionProducesNoPulseEventButIsVisibleInTheDebugFeed() {
        let rejected = RingDecodedEvent.measurementRejected(mode: YCBTMeasurementMode.hrv)
        XCTAssertTrue(RingEventBridge.events(for: rejected).isEmpty)
        XCTAssertEqual(rejected.kind, "measurement_rejected")
        XCTAssertEqual(rejected.debugJSON, #"{"rejected_mode":10}"#)
    }

    // MARK: Command channel (be940001, group 0x02)

    /// `02 00` is **GetDeviceInfo** (`CMD.KEY_Get.DeviceInfo == 0`), not "status": battery state at
    /// payload[4], battery percent at [5], firmware as `[3].[2]`. The old decoder had `0x00` and `0x01`
    /// swapped and never surfaced a firmware version at all.
    func testDeviceInfoDecodesBatteryAndFirmware() {
        let frame = YCBTFrame(validating: bytes("02001e00a30012010064000100030000000001000000010000000000ef10"))!
        let events = decoder.decode(frame)

        let battery = events.compactMap { event -> Int? in
            if case let .battery(percent) = event { return percent } else { return nil }
        }
        let firmware = events.compactMap { event -> String? in
            if case let .firmware(version) = event { return version } else { return nil }
        }
        XCTAssertEqual(battery, [100])       // payload[5] = 0x64
        XCTAssertEqual(firmware, ["1.18"])   // payload[3].payload[2] = 0x01 . 0x12
    }

    /// The SDK **zero-pads** a single-digit sub-version (`i4 < 10 ? main + ".0" + sub : main + "." + sub`),
    /// so sub 5 is the "1.05" the vendor's release notes name. Rendering it "1.5" makes a user comparing
    /// against those notes think they are on different firmware.
    func testFirmwareSubVersionIsZeroPaddedLikeTheSDK() {
        let frame = YCBTFrame(validating: YCBTFrame.frame([0x02, 0x00, 0xa3, 0x00, 0x05, 0x01, 0x00, 0x64]))!
        let firmware = decoder.decode(frame).compactMap { event -> String? in
            if case let .firmware(version) = event { return version } else { return nil }
        }
        XCTAssertEqual(firmware, ["1.05"])
    }

    // The `02 01` SupportFunction reply and the bitmap it carries are covered in
    // `YCBTSupportFunctionTests` — the bitmap is a capability question, not a frame-decoding one, and
    // it now has a dedicated suite.

    // MARK: Timestamp decode

    func testDateDecodeRecoversTrueInstantAcrossTimeZone() {
        // The ring has no timezone concept: `setTime` sends *local* wall-clock fields, and the ring
        // stores them naively as if they were UTC (no timezone byte in the wire format). Simulate that
        // here for a non-UTC zone and confirm decode still recovers the true absolute instant, rather
        // than shifting it by a full UTC-offset (which is what put last night's sleep session on the
        // wrong side of the app's 7 PM day boundary).
        let tz = TimeZone(identifier: "America/New_York")!
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = tz

        // Snap to the second so DateComponents round-trips exactly.
        let trueInstant = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let localFields = localCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: trueInstant
        )

        // What the ring's own naive clock would store: the local fields, reinterpreted as if they
        // were UTC (no timezone concept on-device).
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let ringNaiveInstant = utcCalendar.date(from: localFields)!
        let ringSecondsFromRing = Int(ringNaiveInstant.timeIntervalSince1970 - YCBTBytes.epochOffset)

        let decoded = YCBTBytes.date(ringSecondsFromRing, timeZone: tz)

        XCTAssertEqual(decoded.timeIntervalSince1970, trueInstant.timeIntervalSince1970, accuracy: 1)
    }

    func testRingSecondsAndDateRoundTrip() {
        let tz = TimeZone(identifier: "America/New_York")!
        let date = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())

        let ringSeconds = YCBTBytes.ringSeconds(date, timeZone: tz)
        let decoded = YCBTBytes.date(ringSeconds, timeZone: tz)

        XCTAssertEqual(decoded.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
    }

    /// Sleep segment durations are u24; a u16 read truncates anything over 18h12m.
    func testU24ReadsThreeBytesLittleEndian() {
        XCTAssertEqual(YCBTBytes.u24([0x40, 0x19, 0x01], 0), 72_000)
        XCTAssertEqual(YCBTBytes.u24([0x00, 0x00], 0), 0, "a short buffer reads 0, never out of bounds")
    }

    // MARK: Driver test support

    /// Command replies come back on `be940001` — the same characteristic the app writes to.
    private var commandChannel: CBUUID { CBUUID(string: YCBTUUIDs.command) }

    @MainActor
    private func makeDriver() -> YCBTDriver {
        YCBTDriver(writer: SilentRingWriter())
    }
}

/// A driver needs a writer (it ACKs DevControl pushes through one); nothing in these tests reads what it
/// sends, so it drops everything.
private final class SilentRingWriter: RingCommandWriter {
    nonisolated deinit {}
    func enqueue(_ command: Data) {}
}

/// The two commands `RingSyncCoordinator` actually emits, sent the way `RingBLEClient.enqueueWrite` does:
/// through `frame(_:)`, which is where the driver records that a reply is owed.
@MainActor
private extension YCBTDriver {
    func send(start mode: UInt8) { _ = frame(Data([0x03, 0x2f, 0x01, mode])) }
    func send(stop mode: UInt8) { _ = frame(Data([0x03, 0x2f, 0x00, mode])) }
}
