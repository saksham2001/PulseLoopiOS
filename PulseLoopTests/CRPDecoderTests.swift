import XCTest
import CoreBluetooth
@testable import PulseLoop

/// Unit tests for CRP inbound decoding + reassembly (`CRPDecoder`, `CRPFrameAssembler`) and the
/// `CRPDriver.ingest` routing. Byte layouts are from the decompiled Moyoung app (`e1/k.b` steps,
/// `e1/f.b` HR, `g1/a.k` frame reassembly). No BLE stack needed. Ported from the Android app's
/// `CRPDecoderTest.kt`.
@MainActor
final class CRPDecoderTests: XCTestCase {

    private let fdd1 = CRPUUIDs.stepsNotifyCBUUID
    private let fdd3 = CRPUUIDs.cmdNotifyCBUUID

    // MARK: - Steps

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

    // MARK: - Assembler

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

    // MARK: - Vital result decoding (group 1, real-time)

    func testGroup1Cmd9DecodesHeartRateBpm() {
        // HR response: group1/cmd9, payload[0]=74 (0x4A) → 74 bpm
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdMeasureHR, payload: [0x4A])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case let .heartRateSample(bpm, _) = events[0] else {
            return XCTFail("expected heartRateSample, got \(events[0])")
        }
        XCTAssertEqual(bpm, 74)
    }

    func testGroup1Cmd9HeartRateBelowPlausibilityThresholdDropped() {
        // bpm=30 is below the 40..200 guard.
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdMeasureHR, payload: [0x1E])
        XCTAssertTrue(CRPDecoder.decode(frame, from: fdd3).isEmpty)
    }

    func testGroup1Cmd9HeartRateAbovePlausibilityThresholdDropped() {
        // bpm=250 is above the 40..200 guard.
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdMeasureHR, payload: [0xFA])
        XCTAssertTrue(CRPDecoder.decode(frame, from: fdd3).isEmpty)
    }

    func testGroup1Cmd10DecodesHRV() {
        // HRV response: group1/cmd10, payload[0]=45 → 45 ms. The RESULT opcode (10), not the
        // enable-timing opcode (7) — a reply on 7 is the all-day config being acked, not a reading.
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdResultHRV, payload: [0x2D])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case let .hrvSample(value, _) = events[0] else {
            return XCTFail("expected hrvSample, got \(events[0])")
        }
        XCTAssertEqual(value, 45)
    }

    func testGroup1Cmd11DecodesSpO2() {
        // SpO2 response: group1/cmd11, payload[0]=96 → 96%
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdResultSpO2, payload: [0x60])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case let .spo2Result(value, _) = events[0] else {
            return XCTFail("expected spo2Result, got \(events[0])")
        }
        XCTAssertEqual(value, 96)
    }

    func testGroup1Cmd14DecodesStress() {
        // Stress response: group1/cmd14, payload[0]=42 → stress 42
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdResultStress, payload: [0x2A])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case let .stressSample(value, _) = events[0] else {
            return XCTFail("expected stressSample, got \(events[0])")
        }
        XCTAssertEqual(value, 42)
    }

    func testGroup1Cmd32DecodesTemperature() {
        // Temp response: group1/cmd32. Vendor `e1/m.a(payload[1], payload[0])` is
        // twoBytes2int / 10, so 36.5 °C arrives as 365 = 0x016D little-endian.
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdResultTemp, payload: [0x6D, 0x01])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case let .temperatureSample(celsius, _) = events[0] else {
            return XCTFail("expected temperatureSample, got \(events[0])")
        }
        XCTAssertEqual(celsius, 36.5, accuracy: 0.001)
    }

    /// A single-byte temperature payload is not the vendor layout — reject rather than
    /// mis-scale it by 10x (the old placeholder decoded `[0x26]` as 38 °C).
    func testGroup1Cmd32RejectsShortTemperaturePayload() {
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdResultTemp, payload: [0x26])
        XCTAssertTrue(CRPDecoder.decode(frame, from: fdd3).isEmpty)
    }

    /// A reply on an enable-timing opcode is the all-day config being acknowledged. It must NOT
    /// decode as a reading — that conflation is what made the interval byte look like a vital.
    func testEnableTimingRepliesAreAcksNotReadings() {
        for cmd in [CRPCommands.cmdEnableTimingHRV, CRPCommands.cmdEnableTimingSpO2,
                    CRPCommands.cmdEnableTimingStress, CRPCommands.cmdEnableTimingHR] {
            let frame = CRPProtocol.frame(group: 1, cmd: cmd, payload: [0x05])   // interval = 5 min
            let events = CRPDecoder.decode(frame, from: fdd3)
            XCTAssertEqual(events.count, 1)
            guard case .commandAck = events[0] else {
                return XCTFail("cmd \(cmd) should ack, got \(events[0])")
            }
        }
    }

    func testGroup1UnknownCmdReturnsCommandAck() {
        // Unknown cmd in group 1 → ack, not a fabricated metric.
        let frame = CRPProtocol.frame(group: 1, cmd: 99)
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case .commandAck = events[0] else {
            return XCTFail("expected commandAck, got \(events[0])")
        }
    }

    // MARK: - Driver routing

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

    /// The driver instance survives auto-reconnect (`didDisconnectPeripheral` re-dials with a bare
    /// `central.connect`; only `installDriver` rebuilds it), so both lifecycle hooks must drop a
    /// partial frame. Otherwise the new link's first bytes finish the old link's frame.
    func testDriverDiscardsAPartialFrameAcrossAReconnect() {
        let full = CRPProtocol.frame(group: 1, cmd: 9, payload: [0x50]) // size 7
        let resets: [(String, (CRPDriver) -> Void)] = [
            ("connectionDidStart", { $0.connectionDidStart() }),
            ("connectionDidEnd", { $0.connectionDidEnd() }),
        ]
        for (name, reset) in resets {
            let driver = CRPDriver(writer: nil)
            XCTAssertTrue(driver.ingest(Data(full.prefix(4)), from: fdd3).isEmpty)
            reset(driver)
            XCTAssertTrue(driver.ingest(Data(full.suffix(3)), from: fdd3).isEmpty,
                          "\(name): the dropped link's tail must not complete a frame")
            // The fresh link's own frames still decode.
            XCTAssertEqual(driver.ingest(full, from: fdd3).count, 1, name)
        }
    }

    /// `.connected` fires on the first notify characteristic to report `isNotifying`, and that is
    /// `fdd1` for CRP — never `fdd3`, which carries every command reply. Since `.connected` is what
    /// runs `runStartup`, the handshake would otherwise write ~26 frames into a channel we aren't
    /// listening to yet, and a lost reply is indistinguishable from a slow one.
    func testDriverHoldsConnectedUntilTheCommandReplyChannelIsLive() {
        let driver = CRPDriver(writer: nil)
        XCTAssertEqual(driver.requiredSubscriptionsBeforeConnected, [CRPUUIDs.cmdNotifyCBUUID])
        // Must be a subset of notifyUUIDs or it could never be satisfied.
        for uuid in driver.requiredSubscriptionsBeforeConnected {
            XCTAssertTrue(driver.notifyUUIDs.contains(uuid), "\(uuid) is not a declared notify char")
        }
    }

    // MARK: - Wear state (group 3 / cmd 7)

    /// `g1/a.java` decodes group3/cmd7 as `onWearStateChange(payload[0] > 0)`. `[00]` = not worn,
    /// which is why an optical spot measure returns nothing (Android issue #29).
    func testWearStateDecodesBothPolarities() {
        for (byte, expected) in [(UInt8(0x00), false), (UInt8(0x01), true)] {
            let frame = CRPProtocol.frame(group: CRPCommands.groupPower,
                                          cmd: CRPCommands.cmdWearState, payload: [byte])
            let events = CRPDecoder.decode(frame, from: fdd3)
            XCTAssertEqual(events.count, 1)
            guard case let .wearingStatus(worn, _) = events[0] else {
                return XCTFail("expected wearingStatus, got \(events[0])")
            }
            XCTAssertEqual(worn, expected)
        }
    }

    /// Other group-3 commands (factory reset, restart) stay acks — only cmd 7 is wear state.
    func testOtherGroup3CommandsRemainAcks() {
        let frame = CRPProtocol.frame(group: CRPCommands.groupPower, cmd: CRPCommands.cmdFactoryReset)
        guard case .commandAck = CRPDecoder.decode(frame, from: fdd3).first else {
            return XCTFail("expected commandAck")
        }
    }

    // MARK: - All-day "timing" vital history (group 2)

    /// A UTC calendar keeps slot maths independent of the machine's zone: the ring stamps history
    /// against LOCAL midnight, so the decoder must anchor on the injected calendar's day start.
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// HR is one byte per 5-minute slot. Slot n of frame 0 lands at localMidnight + n*5min, and
    /// zero means "no reading" rather than a real zero-bpm sample.
    func testTimingHeartRateHistoryDecodesOneBytePerFiveMinuteSlot() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = utcCalendar
        // [day=0][frame=0][slot0=60][slot1=0 (no reading)][slot2=61]
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryTimingHR,
                                      payload: [0, 0, 60, 0, 61])
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: cal)

        let samples = events.compactMap { event -> (MeasurementKind, Double, Date)? in
            guard case let .historyMeasurement(kind, value, ts) = event else { return nil }
            return (kind, value, ts)
        }
        XCTAssertEqual(samples.count, 2, "the zero slot must be dropped")
        let midnight = cal.startOfDay(for: now)
        XCTAssertEqual(samples[0].0, .heartRate)
        XCTAssertEqual(samples[0].1, 60)
        XCTAssertEqual(samples[0].2, midnight)
        XCTAssertEqual(samples[1].1, 61)
        XCTAssertEqual(samples[1].2, midnight.addingTimeInterval(10 * 60), "slot 2 = +10 min")
    }

    /// HRV is a little-endian TWO-byte value per slot with 72 slots/frame, so frame 1's first slot
    /// is global slot 72 — not 144 as it would be for the one-byte vitals.
    func testTimingHrvHistoryIsTwoByteAndUsesSeventyTwoSlotFrames() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = utcCalendar
        // [day=0][frame=1][slot0 = 0x012C = 300]
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryTimingHRV,
                                      payload: [0, 1, 0x2C, 0x01])
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: cal)
        guard case let .historyMeasurement(kind, value, ts) = events[0] else {
            return XCTFail("expected historyMeasurement, got \(events[0])")
        }
        XCTAssertEqual(kind, .hrv)
        XCTAssertEqual(value, 300)
        XCTAssertEqual(ts, cal.startOfDay(for: now).addingTimeInterval(72 * 5 * 60))
    }

    /// `day` counts back from today in whole LOCAL days.
    func testTimingHistoryAnchorsOnTheRequestedDay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = utcCalendar
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryTimingHR,
                                      payload: [2, 0, 60])
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: cal)
        guard case let .historyMeasurement(_, _, ts) = events[0] else {
            return XCTFail("expected historyMeasurement")
        }
        let expected = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: now))!
        XCTAssertEqual(ts, expected)
    }

    /// Every timing reply ends with the cursor the sync engine walks.
    func testTimingHistoryEmitsFrameMarkerForFollowUp() {
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryTimingStress,
                                      payload: [0, 1, 40])
        let events = CRPDecoder.decode(frame, from: fdd3)
        guard case let .timingHistoryFrame(cmd, day, frameIndex) = events.last else {
            return XCTFail("expected trailing timingHistoryFrame, got \(String(describing: events.last))")
        }
        XCTAssertEqual(cmd, CRPCommands.cmdQueryTimingStress)
        XCTAssertEqual(day, 0)
        XCTAssertEqual(frameIndex, 1)
    }

    /// Out-of-range values are the vendor's per-vital clamps, not real samples.
    func testTimingHistoryDropsOutOfRangeSamples() {
        // HR clamp is 40…200: 30 and 250 are both noise, 80 is real.
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryTimingHR,
                                      payload: [0, 0, 30, 250, 80])
        let events = CRPDecoder.decode(frame, from: fdd3)
        let samples = events.filter { if case .historyMeasurement = $0 { return true } else { return false } }
        XCTAssertEqual(samples.count, 1)
    }

    /// A day beyond CRPHistoryDay's 14-day window is a corrupt reply — ack, don't invent samples.
    func testTimingHistoryRejectsImplausibleDay() {
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryTimingHR,
                                      payload: [200, 0, 60])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case .commandAck = events[0] else {
            return XCTFail("expected commandAck, got \(events[0])")
        }
    }

    func testTimingHistoryRejectsOutOfRangeFrameIndices() {
        for (cmd, frameIndex) in [(CRPCommands.cmdQueryTimingHR, 2),
                                  (CRPCommands.cmdQueryTimingHRV, 4)] {
            let frame = CRPProtocol.frame(group: CRPCommands.groupHistory, cmd: cmd,
                                          payload: [0, UInt8(frameIndex), 60])
            let events = CRPDecoder.decode(frame, from: fdd3)
            XCTAssertEqual(events.count, 1)
            guard case .commandAck = events[0] else {
                return XCTFail("expected malformed frame to ack, got \(events[0])")
            }
        }
    }

    func testTimingHistoryRejectsOversizedFramesAndMisalignedHRV() {
        let oversizedHR = CRPProtocol.frame(
            group: CRPCommands.groupHistory,
            cmd: CRPCommands.cmdQueryTimingHR,
            payload: [0, 0] + [UInt8](repeating: 60, count: 145)
        )
        let oversizedHRV = CRPProtocol.frame(
            group: CRPCommands.groupHistory,
            cmd: CRPCommands.cmdQueryTimingHRV,
            payload: [0, 0] + [UInt8](repeating: 1, count: 73 * 2)
        )
        let misalignedHRV = CRPProtocol.frame(
            group: CRPCommands.groupHistory,
            cmd: CRPCommands.cmdQueryTimingHRV,
            payload: [0, 0, 40]
        )
        for frame in [oversizedHR, oversizedHRV, misalignedHRV] {
            let events = CRPDecoder.decode(frame, from: fdd3)
            XCTAssertEqual(events.count, 1)
            guard case .commandAck = events[0] else {
                return XCTFail("expected malformed frame to ack, got \(events[0])")
            }
        }
    }

    func testTimingHistoryUsesWallClockSlotsAndSkipsSpringForwardGap() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        var samples = [UInt8](repeating: 0, count: 37)
        samples[24] = 60 // 02:00 does not exist on this day.
        samples[36] = 61 // 03:00 is the first slot after the jump.
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryTimingHR,
                                      payload: [0, 0] + samples)
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: cal)
        let history = events.compactMap { event -> (Double, Date)? in
            guard case let .historyMeasurement(_, value, timestamp) = event else { return nil }
            return (value, timestamp)
        }
        XCTAssertEqual(history.count, 1, "the nonexistent 02:00 slot must be skipped")
        XCTAssertEqual(history[0].0, 61)
        XCTAssertEqual(cal.component(.hour, from: history[0].1), 3)
        XCTAssertEqual(cal.component(.minute, from: history[0].1), 0)
    }

    func testTimingHistoryChoosesFirstOccurrenceOfRepeatedFallBackSlot() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        var samples = [UInt8](repeating: 0, count: 19)
        samples[18] = 60 // 01:30 occurs twice.
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryTimingHR,
                                      payload: [0, 0] + samples)
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: cal)
        guard case let .historyMeasurement(_, _, timestamp) = events.first else {
            return XCTFail("expected historyMeasurement")
        }
        XCTAssertEqual(cal.timeZone.secondsFromGMT(for: timestamp), -4 * 60 * 60,
                       "the first 01:30 is still in daylight time")
    }

    /// Temperature history (cmd 48) has no confirmed layout yet — it must stay an ack.
    func testTemperatureHistoryStaysAnAck() {
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryHistoryTemp, payload: [0, 0, 1, 2])
        guard case .commandAck = CRPDecoder.decode(frame, from: fdd3).first else {
            return XCTFail("expected commandAck")
        }
    }

    // MARK: - Sleep (group 2 / cmd 14)

    /// Vendor `e1/j.b`: `[dayIndex]` then 3-byte `[state, hour, minute]` records, each marking the
    /// moment that state BEGINS and running until the next record.
    func testSleepDecodesStagesOnePerMinute() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = utcCalendar
        // 01:00 light (60 min) → 02:00 deep (30 min) → 02:30 awake (ends the night)
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryHistorySleep,
                                      payload: [0, 1, 1, 0, 2, 2, 0, 0, 2, 30])
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: cal)
        XCTAssertEqual(events.count, 1)
        guard case let .sleepTimeline(ts, stages) = events[0] else {
            return XCTFail("expected sleepTimeline, got \(events[0])")
        }
        XCTAssertEqual(stages.count, 90, "60 light + 30 deep, one entry per minute")
        XCTAssertEqual(stages.prefix(60).filter { $0 == .light }.count, 60)
        XCTAssertEqual(stages.suffix(30).filter { $0 == .deep }.count, 30)
        XCTAssertEqual(ts, cal.startOfDay(for: now).addingTimeInterval(60 * 60), "anchored at 01:00")
    }

    /// A day can hold a night plus a nap; an awake run of >= the session gap splits them.
    func testSleepSplitsBoutsOnALongAwakeGap() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 01:00 light 60m → 02:00 awake 180m → 05:00 light 30m → 05:30 awake
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryHistorySleep,
                                      payload: [0, 1, 1, 0, 0, 2, 0, 1, 5, 0, 0, 5, 30])
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: utcCalendar)
        XCTAssertEqual(events.count, 2, "a >=60-minute awake run separates the bouts")
    }

    /// A short mid-night wake stays inside its bout as awake minutes.
    func testSleepKeepsShortWakesInsideTheBout() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 01:00 light 60m → 02:00 awake 10m → 02:10 light 30m → 02:40 awake
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryHistorySleep,
                                      payload: [0, 1, 1, 0, 0, 2, 0, 1, 2, 10, 0, 2, 40])
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: utcCalendar)
        XCTAssertEqual(events.count, 1)
        guard case let .sleepTimeline(_, stages) = events[0] else { return XCTFail("expected sleepTimeline") }
        XCTAssertEqual(stages.count, 100, "60 light + 10 awake + 30 light")
        XCTAssertEqual(stages.filter { $0 == .awake }.count, 10)
    }

    /// The vendor requires `length % 3 == 1` (one day byte + whole records).
    func testSleepRejectsMalformedPayloadLength() {
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryHistorySleep,
                                      payload: [0, 1, 1, 0, 2])   // 5 bytes → 5 % 3 == 2
        XCTAssertTrue(CRPDecoder.decode(frame, from: fdd3).isEmpty)
    }

    /// An awake-only reply carries no sleep, so it must produce no timeline at all.
    func testSleepEmitsNothingWhenNoActualSleep() {
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryHistorySleep,
                                      payload: [0, 0, 1, 0, 0, 2, 0])
        XCTAssertTrue(CRPDecoder.decode(frame, from: fdd3).isEmpty)
    }

    // MARK: - Firmware version + capability read-backs

    /// `group 3 / cmd 3` carries a bare UTF-8 string with no length prefix or terminator
    /// (`g1/a.i1`: `onVersion(new String(payload, UTF_8))`) — `MOY-R1K3-2.1.6` on zaggash's R11.
    func testFirmwareVersionDecodesAsABareUTF8String() {
        let frame = CRPProtocol.frame(group: CRPCommands.groupPower,
                                      cmd: CRPCommands.cmdQueryFirmwareVersion,
                                      payload: Array("MOY-R1K3-2.1.6".utf8))
        guard case let .firmware(version) = CRPDecoder.decode(frame, from: fdd3).first else {
            return XCTFail("expected firmware")
        }
        XCTAssertEqual(version, "MOY-R1K3-2.1.6")
    }

    /// Some firmwares pad the frame to a fixed width; NUL padding must not survive into the UI.
    func testFirmwareVersionTrimsNulPadding() {
        let frame = CRPProtocol.frame(group: CRPCommands.groupPower,
                                      cmd: CRPCommands.cmdQueryFirmwareVersion,
                                      payload: Array("V1.2".utf8) + [0, 0, 0])
        guard case let .firmware(version) = CRPDecoder.decode(frame, from: fdd3).first else {
            return XCTFail("expected firmware")
        }
        XCTAssertEqual(version, "V1.2")
    }

    /// An empty/all-padding payload has no version in it — ack rather than publish an empty string.
    func testEmptyFirmwarePayloadFallsBackToAnAck() {
        let frame = CRPProtocol.frame(group: CRPCommands.groupPower,
                                      cmd: CRPCommands.cmdQueryFirmwareVersion,
                                      payload: [0, 0])
        guard case .commandAck = CRPDecoder.decode(frame, from: fdd3).first else {
            return XCTFail("expected commandAck")
        }
    }

    /// Whatever this returns is shown verbatim in Settings, so a payload that isn't a version string
    /// must ack rather than publish. `String(decoding:as:)` would have coerced both of these into
    /// U+FFFD runs / control junk and presented them as a firmware version.
    func testNonTextFirmwarePayloadsAreRejectedRatherThanCoerced() {
        // Invalid UTF-8 (lone continuation bytes), and valid UTF-8 that is still binary junk.
        for payload: [UInt8] in [[0xC3, 0x28, 0xA0, 0xFF], [0x01, 0x02, 0x03, 0x41]] {
            let frame = CRPProtocol.frame(group: CRPCommands.groupPower,
                                          cmd: CRPCommands.cmdQueryFirmwareVersion, payload: payload)
            guard case .commandAck = CRPDecoder.decode(frame, from: fdd3).first else {
                return XCTFail("expected commandAck for \(payload)")
            }
        }
    }

    // MARK: - Assembler lifecycle

    /// Auto-reconnect re-uses the same `CRPDriver`, so a frame left half-assembled when the old link
    /// dropped would be completed with bytes from the new one and decoded as genuine data. Without the
    /// reset the two halves below splice into one plausible-looking frame.
    func testAssemblerResetDiscardsAPartialFrameFromADroppedLink() {
        let a = CRPFrameAssembler()
        let full = CRPProtocol.frame(group: 1, cmd: 9, payload: [1, 2, 3, 4])   // size 10
        XCTAssertNil(a.append(full.prefix(6)))       // link drops mid-frame
        a.reset()                                     // connectionDidStart / connectionDidEnd
        // The new link's leading bytes must not complete the old frame.
        XCTAssertNil(a.append(full.suffix(4)), "continuation with no in-progress frame is noise")
        // …and a whole frame after the reset still assembles normally.
        XCTAssertEqual(a.append(full), full)
    }

    /// `CRPBloodOxygenType` defines exactly three values: 0 NOT_SUPPORT, 1 SLEEP_OXYGEN,
    /// 2 TIMING_OXYGEN. Only 1 and 2 are a claim of support.
    func testSpO2SupportGrantsCapabilitiesOnlyForTheTwoDocumentedTypes() {
        for type in [1, 2] {
            let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                          cmd: CRPCommands.cmdQuerySupportSpO2Type,
                                          payload: [UInt8(type)])
            guard case let .supportFunctions(caps) = CRPDecoder.decode(frame, from: fdd3).first else {
                return XCTFail("expected supportFunctions for type \(type)")
            }
            XCTAssertEqual(caps, [.spo2, .manualSpo2])
        }
    }

    /// `0xFF` is this ring's no-reading sentinel (a failed spot SpO2 answers `1/11 [FF]`). Treating
    /// "any non-zero" as support would read that sentinel as a capability claim.
    func testSpO2SupportRejectsNotSupportAndTheFFSentinel() {
        for type: UInt8 in [0, 0xFF] {
            let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                          cmd: CRPCommands.cmdQuerySupportSpO2Type,
                                          payload: [type])
            guard case let .supportFunctions(caps) = CRPDecoder.decode(frame, from: fdd3).first else {
                return XCTFail("expected supportFunctions for type \(type)")
            }
            XCTAssertTrue(caps.isEmpty, "type \(type) must not claim SpO2")
        }
    }

    /// Group 7 is the vendor's Gomore module. Nothing we send lands there, but an unsolicited frame
    /// should still be recorded rather than dropped.
    func testGomoreGroupRepliesAreAcked() {
        let frame = CRPProtocol.frame(group: CRPCommands.groupGomore,
                                      cmd: CRPCommands.cmdQuerySupportGomore, payload: [1])
        guard case .commandAck = CRPDecoder.decode(frame, from: fdd3).first else {
            return XCTFail("expected commandAck")
        }
    }

    /// A night that starts before midnight: the first record reads later on the clock than the last,
    /// so the anchor rolls back a day rather than placing the night in the wrong evening.
    func testSleepAnchorsAnEveningStartBeforeMidnight() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = utcCalendar
        // 23:00 light 120m → 01:00 deep 60m → 02:00 awake
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryHistorySleep,
                                      payload: [0, 1, 23, 0, 2, 1, 0, 0, 2, 0])
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: cal)
        guard case let .sleepTimeline(ts, stages) = events.first else {
            return XCTFail("expected sleepTimeline")
        }
        XCTAssertEqual(stages.count, 180)
        // 23:00 the previous evening = wake-day midnight minus 60 minutes.
        XCTAssertEqual(ts, cal.startOfDay(for: now).addingTimeInterval(-60 * 60))
    }

    func testSleepAnchorsFromMidnightRolloverWhenALaterBoutEndsAfterTheFirstClockTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = utcCalendar
        // Prior 23:00 light → 07:00 awake, then 22:30 light → 23:30 awake on the wake day.
        // The final clock time is later than the first, but the 23:00→07:00 rollover still proves
        // that the first bout began on the previous day.
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryHistorySleep,
                                      payload: [0, 1, 23, 0, 0, 7, 0, 1, 22, 30, 0, 23, 30])
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: cal)
        XCTAssertEqual(events.count, 2)
        guard case let .sleepTimeline(firstStart, _) = events[0],
              case let .sleepTimeline(secondStart, _) = events[1] else {
            return XCTFail("expected two sleep bouts")
        }
        let wakeDayStart = cal.startOfDay(for: now)
        XCTAssertEqual(firstStart, wakeDayStart.addingTimeInterval(-60 * 60))
        XCTAssertEqual(secondStart, wakeDayStart.addingTimeInterval((22 * 60 + 30) * 60))
    }

    func testSleepNeverMovesAOneDayReplyBackMoreThanOneDay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = utcCalendar
        // Two backward clock transitions are malformed for one day reply. They must not shift the
        // first transition two days back; dayIndex identifies a single wake day.
        let frame = CRPProtocol.frame(group: CRPCommands.groupHistory,
                                      cmd: CRPCommands.cmdQueryHistorySleep,
                                      payload: [0, 1, 23, 0, 2, 1, 0, 1, 23, 0, 0, 1, 0])
        let events = CRPDecoder.decode(frame, from: fdd3, now: now, calendar: cal)
        guard case let .sleepTimeline(firstStart, _) = events.first else {
            return XCTFail("expected sleepTimeline")
        }
        XCTAssertEqual(firstStart, cal.startOfDay(for: now).addingTimeInterval(-60 * 60))
    }
}
