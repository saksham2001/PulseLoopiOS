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

    private func decodeAll(_ hex: String) -> [RingDecodedEvent] {
        decoder.decodeAll((try? Data(hexString: hex)) ?? Data())
    }

    /// The 0x24 combined-sensor packet fans out into one event per valid metric. Byte map:
    /// [1]=HR, [2]=systolic, [3]=diastolic, [4]=SpO₂, [5]=fatigue, [6]=stress, [7]=glucose(mmol/L×10),
    /// [8]=HRV. Here: HR=70, sys=120, dia=80, SpO₂=98, fatigue=40, stress=30, glucose=51, HRV=45.
    func testCombinedSensorPacketDecodesAllMetrics() {
        // 24 46 78 50 62 28 1e 33 2d ...
        let events = decodeAll("2446785062281e332d0000000000000000000000")
        func first<T>(_ predicate: (RingDecodedEvent) -> T?) -> T? { events.lazy.compactMap(predicate).first }

        XCTAssertEqual(first { if case let .heartRateSample(b, _) = $0 { return b } else { return nil } }, 0x46)
        let bp = first { e -> (Int, Int)? in if case let .bloodPressureSample(s, d, _) = e { return (s, d) } else { return nil } }
        XCTAssertEqual(bp?.0, 120); XCTAssertEqual(bp?.1, 80)
        XCTAssertEqual(first { if case let .spo2Result(v, _) = $0 { return v } else { return nil } }, 98)
        XCTAssertEqual(first { if case let .fatigueSample(v, _) = $0 { return v } else { return nil } }, 40)
        XCTAssertEqual(first { if case let .stressSample(v, _) = $0 { return v } else { return nil } }, 30)
        XCTAssertEqual(first { if case let .hrvSample(v, _) = $0 { return v } else { return nil } }, 45)

        // Blood sugar: raw 0x33 = 51 → 5.1 mmol/L → 5.1 × 18.016 ≈ 91.88 mg/dL.
        let glucose = first { e -> Double? in if case let .bloodSugarSample(mgdl, _) = e { return mgdl } else { return nil } }
        XCTAssertEqual(glucose ?? 0, 91.88, accuracy: 0.05)
    }

    /// A warm-up 0x24 packet (all metric bytes zero) yields no measurements, just an ack so the queue
    /// still advances.
    func testCombinedSensorEmptyPacketIsAck() {
        let events = decodeAll("2400000000000000000000000000000000000000")
        XCTAssertEqual(events.count, 1)
        guard case .commandAck = events[0] else { return XCTFail("expected commandAck, got \(events[0].kind)") }
    }

    /// SpO₂ outside 80…100 is rejected (byte[4]=0x05) — no spo2Result emitted.
    func testCombinedSensorRejectsImplausibleSpO2() {
        let events = decodeAll("245e774d05050000000000000000000000000000")
        XCTAssertFalse(events.contains { if case .spo2Result = $0 { return true } else { return false } })
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

    /// 0x01 carries *local wall-clock* seconds (`utc + offset`), not a UTC epoch — the ring's RTC runs
    /// on local time, and `JringClock` subtracts the offset back off on decode.
    func testTimeSyncCommandSendsLocalWallClockEpoch() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        // 2023-11-14 is standard time in New York → UTC-5.
        let tz = TimeZone(identifier: "America/New_York")!
        let data = [UInt8](RingEncoder().makeTimeSyncCommand(date: date, timeZone: tz))
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(data[0], 0x01)
        let ts = UInt32(data[1]) | UInt32(data[2]) << 8 | UInt32(data[3]) << 16 | UInt32(data[4]) << 24
        XCTAssertEqual(ts, UInt32(1_700_000_000 - 5 * 3600))
        XCTAssertEqual(Int8(bitPattern: data[5]), -5)
    }

    /// Half-hour zones truncate byte[5] (IST +5:30 → 5), exactly as the vendor's encoder does. The
    /// full offset still rides bytes[1..4], so the round-trip through `JringClock` stays exact.
    func testTimeSyncCommandHalfHourZoneTruncatesOffsetByte() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let tz = TimeZone(identifier: "Asia/Kolkata")!
        let data = [UInt8](RingEncoder().makeTimeSyncCommand(date: date, timeZone: tz))
        let ts = UInt32(data[1]) | UInt32(data[2]) << 8 | UInt32(data[3]) << 16 | UInt32(data[4]) << 24
        XCTAssertEqual(ts, UInt32(1_700_000_000 + 5 * 3600 + 30 * 60))   // full +5:30 offset
        XCTAssertEqual(Int8(bitPattern: data[5]), 5)                     // truncated hours
    }

    /// The encode/decode halves must cancel: a timestamp the ring echoes back at `now` decodes to `now`.
    @MainActor
    func testRingTimestampRoundTripsThroughClock() throws {
        let tz = TimeZone(identifier: "Asia/Kolkata")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = JringClock(timeZone: tz, now: now)

        let sent = [UInt8](RingEncoder().makeTimeSyncCommand(date: now, timeZone: tz))
        // Pretend the ring echoes its RTC straight back in an 0x01 ack.
        var frame = [UInt8](repeating: 0, count: 20)
        frame[0] = 0x01
        frame[1...4] = sent[1...4]

        let event = RingDecoder(clock: clock).decode(Data(frame))
        guard case let .timeSyncAck(decoded) = event else {
            return XCTFail("expected timeSyncAck, got \(event.kind)")
        }
        XCTAssertEqual(decoded.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
    }

    /// A sleep timeline stamped in the ring's local wall clock must decode back to the true instant.
    @MainActor
    func testSleepTimelineSubtractsRingOffset() {
        let tz = TimeZone(identifier: "America/New_York")!   // UTC-5 on this date
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = JringClock(timeZone: tz, now: now)

        let ringEpoch = UInt32(1_700_000_000 - 5 * 3600)     // what the ring's RTC reads
        var frame = [UInt8](repeating: 0, count: 20)
        frame[0] = 0x11
        frame[1] = UInt8(ringEpoch & 0xff)
        frame[2] = UInt8((ringEpoch >> 8) & 0xff)
        frame[3] = UInt8((ringEpoch >> 16) & 0xff)
        frame[4] = UInt8((ringEpoch >> 24) & 0xff)
        frame[5] = 0x28   // one light-sleep minute so `stages` is non-empty

        let event = RingDecoder(clock: clock).decode(Data(frame))
        guard case let .sleepTimeline(timestamp, stages) = event else {
            return XCTFail("expected sleepTimeline, got \(event.kind)")
        }
        XCTAssertEqual(timestamp.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
        XCTAssertEqual(stages.first, .light)
    }

    /// A decoder with no clock (the DebugView / legacy path) subtracts nothing.
    func testDecoderWithoutClockLeavesTimestampsUnshifted() {
        var frame = [UInt8](repeating: 0, count: 20)
        frame[0] = 0x01
        let epoch = UInt32(1_700_000_000)
        frame[1] = UInt8(epoch & 0xff)
        frame[2] = UInt8((epoch >> 8) & 0xff)
        frame[3] = UInt8((epoch >> 16) & 0xff)
        frame[4] = UInt8((epoch >> 24) & 0xff)

        guard case let .timeSyncAck(decoded) = RingDecoder().decode(Data(frame)) else {
            return XCTFail("expected timeSyncAck")
        }
        XCTAssertEqual(decoded.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    // MARK: - Background-monitoring + measurement-mode layouts

    /// 0x19 auto-HR: all-day window, enable flag, cadence minutes, and the constant 0x01 trailer.
    func testAutomaticHeartRateCommandLayout() {
        let data = [UInt8](RingEncoder().makeAutomaticHeartRateCommand(enabled: true, cadenceMinutes: 15))
        XCTAssertEqual(data[0], 0x19)
        XCTAssertEqual(data[1], 0x00)   // start 00:00
        XCTAssertEqual(data[2], 0x00)
        XCTAssertEqual(data[3], 0x17)   // end 23:59
        XCTAssertEqual(data[4], 0x3b)
        XCTAssertEqual(data[5], 0x01)   // enabled
        XCTAssertEqual(data[6], 15)     // cadence minutes
        XCTAssertEqual(data[7], 0x01)   // constant — the vendor SDK hardcodes this
    }

    /// 0x23 is a mode selector: SpO₂ is mode 2. Mode 1 would run a *blood-pressure* measurement.
    func testSpO2StartUsesCombinedModeTwo() {
        let start = [UInt8](RingEncoder().makeSpO2StartCommand())
        XCTAssertEqual(start[0], 0x23)
        XCTAssertEqual(start[1], 0x02)

        let stop = [UInt8](RingEncoder().makeSpO2StopCommand())
        XCTAssertEqual(stop[0], 0x23)
        XCTAssertEqual(stop[1], 0x00)
    }

    func testBloodOxygenModeCommandLayout() {
        XCTAssertEqual([UInt8](RingEncoder().makeBloodOxygenModeCommand(enabled: true))[0...1], [0x3e, 0x01])
        XCTAssertEqual([UInt8](RingEncoder().makeBloodOxygenModeCommand(enabled: false))[0...1], [0x3e, 0x00])
    }

    func testBandFunctionCommandAndDecode() {
        XCTAssertEqual([UInt8](RingEncoder().makeBandFunctionCommand())[0], 0x20)

        // Payload starts at frame byte[1], so capability bit N lives at payload bit N.
        var frame = [UInt8](repeating: 0, count: 20)
        frame[0] = 0x20
        frame[1 + 10 / 8] = 1 << UInt8(10 % 8)   // bit 10 → temperature
        guard case let .bandFunction(caps) = RingDecoder().decode(Data(frame)) else {
            return XCTFail("expected bandFunction")
        }
        XCTAssertTrue(caps.hasTemperature)
        XCTAssertFalse(caps.separateBloodOxygenMode)
        XCTAssertFalse(caps.hasPressureHistory)
    }

    func testGoalCommandLayout() {
        let data = [UInt8](RingEncoder().makeGoalCommand(steps: 10000))
        XCTAssertEqual(data[0], 0x1a)
        let value = UInt32(data[1]) | UInt32(data[2]) << 8 | UInt32(data[3]) << 16 | UInt32(data[4]) << 24
        XCTAssertEqual(value, 10000)
    }

    // MARK: - Ring-config command layouts

    /// 0x02 user info: age=25 male → byte[1] = 25 | 0x80 = 0x99; height 184 → 0xB8; weight 90 → 0x5A.
    /// Matches the legacy hardcoded `0299b85a…` activity-query bytes.
    func testUserInfoCommandLayout() {
        let data = [UInt8](RingEncoder().makeUserInfoCommand(age: 25, isMale: true, heightCm: 184, weightKg: 90))
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(data[0], 0x02)
        XCTAssertEqual(data[1], 0x99)
        XCTAssertEqual(data[2], 0xb8)
        XCTAssertEqual(data[3], 0x5a)
        XCTAssertEqual(data[4], 0x00)
    }

    func testUserInfoCommandFemaleClearsHighBit() {
        let data = [UInt8](RingEncoder().makeUserInfoCommand(age: 30, isMale: false, heightCm: 165, weightKg: 60))
        XCTAssertEqual(data[1], 30)   // no 0x80 bit
    }

    /// 0x33 BP calibration: systolic/diastolic as little-endian u16s.
    func testBPAdjustCommandLayout() {
        let data = [UInt8](RingEncoder().makeBPAdjustCommand(systolic: 120, diastolic: 80))
        XCTAssertEqual(data[0], 0x33)
        XCTAssertEqual(UInt16(data[1]) | UInt16(data[2]) << 8, 120)
        XCTAssertEqual(UInt16(data[3]) | UInt16(data[4]) << 8, 80)
    }

    /// 0x48 app identity: ASCII app id starting at byte[1].
    func testAppIdentifierCommandLayout() {
        let data = [UInt8](RingEncoder().makeAppIdentifierCommand(appId: "PulseLoop"))
        XCTAssertEqual(data[0], 0x48)
        XCTAssertEqual(data[1], UInt8(ascii: "P"))
        let ascii = String(bytes: data[1...9], encoding: .utf8)
        XCTAssertEqual(ascii, "PulseLoop")
    }

    /// 0x4B bind frame: [1]=action, [2]=state, [3]=1.
    func testBindCommandLayout() {
        let data = [UInt8](RingEncoder().makeBindCommand(action: 1))
        XCTAssertEqual(data[0], 0x4b)
        XCTAssertEqual(data[1], 1)
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[3], 1)
    }

    func testKeepaliveCommandLayout() {
        let data = [UInt8](RingEncoder().makeKeepaliveCommand())
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(data[0], 0x3a)
        XCTAssertTrue(data.dropFirst().allSatisfy { $0 == 0 })
    }

    // MARK: - Decode: bind, firmware, 0x16 history averaging

    func testBindDecode() {
        let event = decode("4b00000100000000000000000000000000000000")
        guard case let .bind(action, state) = event else { return XCTFail("expected bind, got \(event.kind)") }
        XCTAssertEqual(action, 0)
        XCTAssertEqual(state, 0)
    }

    /// 0x0c status fans out into both the address (status) and the firmware string.
    func testStatusPayloadAlsoEmitsFirmware() {
        let events = decodeAll("0c7a0041422ec75b6a3a00160000000000000000")
        XCTAssertTrue(events.contains { if case .status = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .firmware = $0 { return true } else { return false } })
    }

    /// 0x16 with the end-of-stream marker (bytes[1] == 0xFF) decodes as `.historySyncFinished`, which
    /// the event bridge maps to `.syncProgress("done")` so the coordinator's endSync fires.
    func testHistoryMeasurementFinishedMarker() {
        let event = decode("16ff000000000000000000000000000000000000")
        guard case .historySyncFinished = event else {
            return XCTFail("expected historySyncFinished, got \(event.kind)")
        }
    }

    /// A non-0xFF 0x16 sub-type (e.g. the 0xF0 header marker) still decodes as a plain ack, unchanged.
    func testHistoryMeasurementHeaderStillAcks() {
        let event = decode("16f0000000000000000000000000000000000000")
        guard case let .commandAck(commandId) = event else {
            return XCTFail("expected commandAck, got \(event.kind)")
        }
        XCTAssertEqual(commandId, 0x16)
    }

    /// 0x16 data block (sub-type 0xA0): base ts at [2..5], then two 6-sample HR blocks → two averages
    /// 60s apart. Here both blocks are all 60 → averages 60, second timestamped +60s.
    func testHistoryHeartRateAveraging() {
        let base: UInt32 = 1_700_000_000
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x16; bytes[1] = 0xa0
        bytes[2] = UInt8(base & 0xff); bytes[3] = UInt8((base >> 8) & 0xff)
        bytes[4] = UInt8((base >> 16) & 0xff); bytes[5] = UInt8((base >> 24) & 0xff)
        for i in 8..<20 { bytes[i] = 60 }
        let events = decoder.decodeAll(Data(bytes))
        let hr = events.compactMap { e -> (Double, Date)? in
            if case let .historyMeasurement(kind, value, ts) = e, kind == .heartRate { return (value, ts) } else { return nil }
        }
        XCTAssertEqual(hr.count, 2)
        XCTAssertEqual(hr[0].0, 60)
        XCTAssertEqual(hr[1].0, 60)
        XCTAssertEqual(hr[1].1.timeIntervalSince1970 - hr[0].1.timeIntervalSince1970, 60, accuracy: 0.5)
    }
}
