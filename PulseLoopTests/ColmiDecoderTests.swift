import XCTest
import CoreBluetooth
@testable import PulseLoop

/// Colmi R02 decoder/encoder parity against the layouts in docs/ColmiR02-Protocol.md. Pure — no
/// hardware. Frames are built with `ColmiPacket.frame` (which appends the checksum), so these also
/// exercise the checksum round-trip.
final class ColmiDecoderTests: XCTestCase {
    private let decoder = ColmiDecoder()
    private var calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    // MARK: Framing / checksum

    func testFrameAppendsChecksumAndIsSixteenBytes() {
        let framed = ColmiPacket.frame([0x03])
        XCTAssertEqual(framed.count, 16)
        // checksum = sum(content 0..14) & 0xff = 0x03
        XCTAssertEqual(framed[15], 0x03)
    }

    func testValidatingRejectsBadChecksum() {
        var bytes = [UInt8](ColmiPacket.frame([0x03]))
        bytes[15] = bytes[15] &+ 1   // corrupt checksum
        XCTAssertNil(ColmiPacket(validating: Data(bytes)))
    }

    func testValidatingRejectsWrongLength() {
        XCTAssertNil(ColmiPacket(validating: Data([0x03, 0x00])))
    }

    func testBadChecksumDecodesAsUnknown() {
        var bytes = [UInt8](ColmiPacket.frame([0x03, 0x55]))
        bytes[15] = bytes[15] &+ 1
        let events = decoder.decodeNormal(Data(bytes))
        guard case .unknown = events.first else {
            return XCTFail("expected unknown for bad checksum, got \(String(describing: events.first?.kind))")
        }
    }

    // MARK: Normal-channel decode

    func testBattery() {
        let frame = ColmiPacket.frame([ColmiCommandID.battery, 84, 1])
        let events = decoder.decodeNormal(frame)
        guard case let .battery(percent) = events.first else {
            return XCTFail("expected battery, got \(String(describing: events.first?.kind))")
        }
        XCTAssertEqual(percent, 84)
    }

    func testRealtimeHeartRate() {
        let frame = ColmiPacket.frame([ColmiCommandID.realtimeHeartRate, 72])
        let events = decoder.decodeNormal(frame)
        guard case let .heartRateSample(bpm, _) = events.first else {
            return XCTFail("expected heartRateSample, got \(String(describing: events.first?.kind))")
        }
        XCTAssertEqual(bpm, 72)
    }

    func testRealtimeHeartRateZeroDropped() {
        let frame = ColmiPacket.frame([ColmiCommandID.realtimeHeartRate, 0])
        XCTAssertTrue(decoder.decodeNormal(frame).isEmpty)
    }

    func testManualHeartRateError() {
        // 69 <?> errorCode=1 bpm=80  → worn incorrectly → no sample, completion event
        let frame = ColmiPacket.frame([ColmiCommandID.manualHeartRate, 0, 1, 80])
        let events = decoder.decodeNormal(frame)
        guard case .heartRateComplete = events.first else {
            return XCTFail("expected heartRateComplete on error, got \(String(describing: events.first?.kind))")
        }
    }

    func testManualHeartRateOk() {
        let frame = ColmiPacket.frame([ColmiCommandID.manualHeartRate, 0, 0, 77])
        let events = decoder.decodeNormal(frame)
        guard case let .heartRateSample(bpm, _) = events.first else {
            return XCTFail("expected heartRateSample, got \(String(describing: events.first?.kind))")
        }
        XCTAssertEqual(bpm, 77)
    }

    func testBatteryNotification() {
        // 73 0c <level> <charging>
        let frame = ColmiPacket.frame([ColmiCommandID.notification, ColmiCommandID.notifBattery, 65, 0])
        let events = decoder.decodeNormal(frame)
        guard case let .battery(percent) = events.first else {
            return XCTFail("expected battery, got \(String(describing: events.first?.kind))")
        }
        XCTAssertEqual(percent, 65)
    }

    func testLiveActivityNotification() {
        // 73 12 then steps(u24 @2..4)=500, calories(u24 @5..7)=1234 (=123.4), distance(u24 @8..10)=300
        // steps 500 = 0xF4 0x01 0x00 ; cal 1234 = 0xD2 0x04 0x00 ; dist 300 = 0x2C 0x01 0x00
        let frame = ColmiPacket.frame([
            ColmiCommandID.notification, ColmiCommandID.notifLiveActivity,
            0xF4, 0x01, 0x00,
            0xD2, 0x04, 0x00,
            0x2C, 0x01, 0x00,
        ])
        let events = decoder.decodeNormal(frame)
        guard case let .activityUpdate(_, steps, distance, calories) = events.first else {
            return XCTFail("expected activityUpdate, got \(String(describing: events.first?.kind))")
        }
        XCTAssertEqual(steps, 500)
        XCTAssertEqual(distance, 300)
        XCTAssertEqual(calories, 123.4, accuracy: 0.01)
    }

    // MARK: Big-data (V2)

    /// Build a complete big-data frame: [0xbc, type, lenLo, lenHi, 0, 0, payload...] where len =
    /// payload length. (Total frame = len + 6.)
    private func bigData(type: UInt8, payload: [UInt8]) -> Data {
        let len = payload.count
        var bytes: [UInt8] = [ColmiCommandID.bigDataV2, type, UInt8(len & 0xff), UInt8((len >> 8) & 0xff), 0, 0]
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    func testTemperatureBigData() throws {
        // One day (daysAgo=0), unknown byte 0x1e, then 24 (t00,t30) pairs. Put 35.0°C at hour 0:00.
        // °C = byte/10 + 20  ⇒  byte = (35.0 - 20) * 10 = 150
        var payload: [UInt8] = [0x00, 0x1e]
        payload.append(150)   // hour 0 t00
        payload.append(0)     // hour 0 t30
        // pad to 24 hours worth of pairs so length ≥ 50
        payload.append(contentsOf: [UInt8](repeating: 0, count: 46))
        let frame = bigData(type: ColmiCommandID.bigDataTemperature, payload: payload)
        let events = decoder.decodeBigData(frame, calendar: calendar)
        let temps = events.compactMap { event -> Double? in
            if case let .temperatureSample(celsius, _) = event { return celsius }
            return nil
        }
        let first = try XCTUnwrap(temps.first)
        XCTAssertEqual(first, 35.0, accuracy: 0.01)
    }

    func testSpo2BigData() {
        // One day, 24 (min,max) hourly pairs; put min=96,max=98 at hour 0 → mean 97.
        var payload: [UInt8] = [0x00]
        payload.append(96); payload.append(98)
        payload.append(contentsOf: [UInt8](repeating: 0, count: 46))
        let frame = bigData(type: ColmiCommandID.bigDataSpo2, payload: payload)
        let events = decoder.decodeBigData(frame, calendar: calendar)
        let spo2s = events.compactMap { event -> Double? in
            if case let .historyMeasurement(kind, value, _) = event, kind == .spo2 { return value }
            return nil
        }
        XCTAssertEqual(spo2s.first, 97)
    }

    func testSleepBigDataMapsStages() {
        // packetLength ≥ 2; days=1; day record: daysAgo=0, dayBytes=8, start=480(08:00), end=540(09:00),
        // then stage pairs: (deep,30)(rem,30). j runs 4..<dayBytes in steps of 2 → 2 pairs.
        let start = 480, end = 540
        let payload: [UInt8] = [
            0x01,                              // days in packet  (byte[6])
            0x00,                              // daysAgo
            0x08,                              // dayBytes
            UInt8(start & 0xff), UInt8(start >> 8),
            UInt8(end & 0xff), UInt8(end >> 8),
            ColmiCommandID.sleepDeep, 30,
            ColmiCommandID.sleepREM, 30,
        ]
        // Frame layout: [bc, type, lenLo, lenHi, 0, daysInPacket, dayRecord...]; decoder reads
        // daysInPacket from v[6] and data from index 7, so place daysInPacket at v[6].
        let len = payload.count
        var bytes: [UInt8] = [ColmiCommandID.bigDataV2, ColmiCommandID.bigDataSleep,
                              UInt8(len & 0xff), UInt8((len >> 8) & 0xff), 0, 0]
        bytes.append(contentsOf: payload)
        let events = decoder.decodeBigData(Data(bytes), calendar: calendar)
        guard case let .sleepTimeline(_, stages) = events.first else {
            return XCTFail("expected sleepTimeline, got \(String(describing: events.first?.kind))")
        }
        // 30 minutes deep + 30 minutes REM, expanded per-minute.
        XCTAssertTrue(stages.contains(.deep))
        XCTAssertTrue(stages.contains(.rem))
        XCTAssertEqual(stages.filter { $0 == .deep }.count, 30)
        XCTAssertEqual(stages.filter { $0 == .rem }.count, 30)
    }

    // MARK: Reassembly across split notifications (via the driver)

    @MainActor
    func testBigDataReassemblyAcrossPackets() {
        let writer = NullWriter()
        let driver = ColmiDriver(writer: writer)
        let notifyV2 = CBUUID(string: ColmiUUIDs.notifyV2)

        // A temperature big-data frame split into two BLE notifications.
        var payload: [UInt8] = [0x00, 0x1e, 150, 0]
        payload.append(contentsOf: [UInt8](repeating: 0, count: 46))
        let full = bigData(type: ColmiCommandID.bigDataTemperature, payload: payload)
        let firstHalf = full.prefix(10)
        let secondHalf = full.suffix(from: 10)

        let firstEvents = driver.ingest(Data(firstHalf), from: notifyV2)
        XCTAssertTrue(firstEvents.isEmpty, "incomplete frame should yield no events yet")

        let secondEvents = driver.ingest(Data(secondHalf), from: notifyV2)
        let temps = secondEvents.compactMap { event -> Double? in
            if case let .temperatureSample(celsius, _) = event { return celsius }
            return nil
        }
        XCTAssertFalse(temps.isEmpty, "reassembled frame should decode")
    }
}

/// A no-op command writer for driver tests.
@MainActor
private final class NullWriter: RingCommandWriter {
    func enqueue(_ command: Data) {}
}
