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

    /// A fragmented SpO2 reply must not be corrupted by a complete sleep reply arriving mid-reassembly
    /// (the real-capture bug). Type-keyed buffers should let both decode independently.
    @MainActor
    func testInterleavedBigDataDoesNotCorrupt() {
        let driver = ColmiDriver(writer: NullWriter())
        let notifyV2 = CBUUID(string: ColmiUUIDs.notifyV2)

        // SpO2 frame: one day, hour 0 has min=96,max=98 (→ 97); pad to 24 hourly pairs.
        var spo2Payload: [UInt8] = [0x00, 96, 98]
        spo2Payload.append(contentsOf: [UInt8](repeating: 0, count: 46))
        let spo2Full = bigData(type: ColmiCommandID.bigDataSpo2, payload: spo2Payload)
        // Sleep frame: complete in one notification (daysInPacket=1, one session deep+rem).
        let start = 480, end = 540
        let sleepPayload: [UInt8] = [
            0x01, 0x00, 0x08,
            UInt8(start & 0xff), UInt8(start >> 8), UInt8(end & 0xff), UInt8(end >> 8),
            ColmiCommandID.sleepDeep, 30, ColmiCommandID.sleepREM, 30,
        ]
        let len = sleepPayload.count
        var sleepBytes: [UInt8] = [ColmiCommandID.bigDataV2, ColmiCommandID.bigDataSleep,
                                   UInt8(len & 0xff), UInt8((len >> 8) & 0xff), 0, 0]
        sleepBytes.append(contentsOf: sleepPayload)

        // Interleave: SpO2 header chunk → complete sleep frame → SpO2 continuation.
        let spo2First = spo2Full.prefix(12)
        let spo2Rest = spo2Full.suffix(from: 12)
        _ = driver.ingest(Data(spo2First), from: notifyV2)         // SpO2 partial
        let sleepEvents = driver.ingest(Data(sleepBytes), from: notifyV2)   // complete sleep mid-SpO2
        let spo2Events = driver.ingest(Data(spo2Rest), from: notifyV2)      // SpO2 completes

        XCTAssertTrue(sleepEvents.contains { if case .sleepTimeline = $0 { return true }; return false },
                      "sleep should decode even though it arrived mid-SpO2 reassembly")
        let spo2s = spo2Events.compactMap { event -> Double? in
            if case let .historyMeasurement(kind, value, _) = event, kind == .spo2 { return value }
            return nil
        }
        XCTAssertEqual(spo2s.first, 97, "SpO2 should reassemble uncorrupted")
    }

    // MARK: Real captured R11 packets (from a diagnostics export)

    /// The 7 real `0x43` activity buckets from the capture. Each is one quarter-hour bucket dated
    /// 2026-06-17. We anchor `now` near that date so the freshness guard accepts them.
    private static let realActivityBuckets = [
        "432606174c06072d05e800a9000000a2",
        "43260617480507a32a8406670500009d",
        "4326061744040776133b037a02000018",
        "432606174003074714290393020000ec",
        "432606173c02077f231f06860400001c",
        "432606172c010757000f000b0000002b",
        "4326061728000798001b00130000007b",
    ]
    private var activityNow: Date {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 18
        return calendar.date(from: c) ?? Date()
    }

    func testRealActivityBucketsDecodeWithoutCalories() throws {
        var totalSteps = 0
        for hex in Self.realActivityBuckets {
            let data = try XCTUnwrap(try? Data(hexString: hex))
            let events = decoder.decodeHistory(data, day: activityNow, calendar: calendar, now: activityNow)
            // Exactly one bucket, steps+distance only (no activityUpdate / calories).
            XCTAssertEqual(events.count, 1)
            guard case let .activityBucket(_, steps, _) = events.first else {
                return XCTFail("expected activityBucket, got \(String(describing: events.first?.kind))")
            }
            totalSteps += steps
        }
        // Real day's steps sum to a sane ~5,145 (not the 1668 single-bucket "max" the old code showed).
        XCTAssertEqual(totalSteps, 5145)
    }

    @MainActor
    func testActivityBucketSummingIsIdempotentAcrossResync() throws {
        let context = try TestSupport.makeContext()

        // Mirror EventPersistenceSubscriber: reset each day once on its first bucket of the run.
        func runSync() {
            var resetDays: Set<Date> = []
            for hex in Self.realActivityBuckets {
                guard let data = try? Data(hexString: hex) else { continue }
                let events = decoder.decodeHistory(data, day: activityNow, calendar: calendar, now: activityNow)
                if case let .activityBucket(ts, steps, dist) = events.first {
                    let dayKey = calendar.startOfDay(for: ts)
                    let reset = !resetDays.contains(dayKey)
                    resetDays.insert(dayKey)
                    ActivityService.applyActivityBucket(date: ts, steps: steps, distanceMeters: dist, resetDay: reset, context: context)
                }
            }
            try? context.save()
        }

        runSync()
        let after1 = MetricsRepository.activityRows(context: context).map(\.steps).reduce(0, +)
        runSync()   // re-sync the exact same packets
        let after2 = MetricsRepository.activityRows(context: context).map(\.steps).reduce(0, +)

        XCTAssertEqual(after1, 5145, "first sync sums buckets into the day")
        XCTAssertEqual(after2, after1, "re-sync must not inflate (idempotent)")
        // Calories are never summed from ring buckets.
        let cal = MetricsRepository.activityRows(context: context).map(\.calories).reduce(0, +)
        XCTAssertEqual(cal, 0)
    }

    func testRealtimeHeartRateNoReadingReply() {
        // Real capture: we sent 1e01, the ring replied 9eee00… (not worn / no reading).
        let frame = try! Data(hexString: "9eee000000000000000000000000008c")
        let events = decoder.decodeNormal(frame)
        // No heart-rate sample; a completion (no-reading) signal is fine.
        XCTAssertFalse(events.contains { if case .heartRateSample = $0 { return true }; return false })
    }

    func testManualHeartRateOkAndError() {
        // ok: 69 00 00 <bpm>
        let okFrame = ColmiPacket.frame([ColmiCommandID.manualHeartRate, 0, 0, 72])
        XCTAssertTrue(decoder.decodeNormal(okFrame).contains { if case let .heartRateSample(bpm, _) = $0 { return bpm == 72 }; return false })
        // worn incorrectly: 69 00 01 <bpm> -> no sample
        let errFrame = ColmiPacket.frame([ColmiCommandID.manualHeartRate, 0, 1, 72])
        XCTAssertFalse(decoder.decodeNormal(errFrame).contains { if case .heartRateSample = $0 { return true }; return false })
    }

    /// Real-capture regression: the manual stream warms up with `69 02 00 00` (bpm 0, no error) for
    /// ~25s. Those must emit NOTHING (not `.heartRateComplete`) so the measurement isn't aborted on the
    /// first warm-up frame; real readings (`69 02 00 4f` = 79 bpm) decode normally.
    func testManualHeartRateWarmUpEmitsNothing() {
        // Mirrors the real `69 02 00 00` warm-up frame (v[1]=02, errorCode=v[2]=0, bpm=v[3]=0).
        let warmUp = ColmiPacket.frame([ColmiCommandID.manualHeartRate, 0x02, 0x00, 0x00])
        XCTAssertTrue(decoder.decodeNormal(warmUp).isEmpty, "warm-up bpm 0 should produce no events")

        // Real reading `69 02 00 4f` = 79 bpm.
        let reading = ColmiPacket.frame([ColmiCommandID.manualHeartRate, 0x02, 0x00, 0x4f])
        XCTAssertTrue(decoder.decodeNormal(reading).contains { if case let .heartRateSample(bpm, _) = $0 { return bpm == 79 }; return false },
                      "real reading 0x4f should decode to 79 bpm")

        // A genuine error reply (errorCode != 0) still signals completion (no sample).
        let errReply = ColmiPacket.frame([ColmiCommandID.manualHeartRate, 0x02, 0x01, 0x4f])
        XCTAssertTrue(decoder.decodeNormal(errReply).contains { if case .heartRateComplete = $0 { return true }; return false })
    }

    // MARK: Big-data command-channel routing

    @MainActor
    func testColmiRoutesBigDataToCommandChannel() {
        let driver = ColmiDriver(writer: NullWriter())
        // Big-data (0xbc) requests must go to the command characteristic.
        XCTAssertTrue(driver.usesCommandChannel(for: Data([ColmiCommandID.bigDataV2, ColmiCommandID.bigDataSleep])))
        // Normal commands (battery 0x03, etc.) use the write characteristic.
        XCTAssertFalse(driver.usesCommandChannel(for: ColmiPacket.frame([ColmiCommandID.battery])))
        // The command characteristic UUID is exposed.
        XCTAssertEqual(driver.commandUUID, CBUUID(string: ColmiUUIDs.command))
    }

    @MainActor
    func testJringHasNoCommandChannel() {
        let driver = JringDriver(writer: NullWriter())
        XCTAssertNil(driver.commandUUID)
        XCTAssertFalse(driver.usesCommandChannel(for: Data([0x14])))
    }
}

/// A no-op command writer for driver tests.
@MainActor
private final class NullWriter: RingCommandWriter {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
    func enqueue(_ command: Data) {}
}
