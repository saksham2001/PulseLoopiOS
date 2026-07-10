import XCTest
@testable import PulseLoop

/// The jring's connect-time command sequence. The load-bearing assertion is that `runStartup` emits
/// the 0x19 background-monitoring command: that is what arms the ring's continuous sensor logging,
/// and its absence is why users previously had to initialise the ring with the vendor app first.
@MainActor
final class JringSyncEngineTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
        var opcodes: [UInt8] { sent.compactMap(\.first) }
        func frame(opcode: UInt8) -> [UInt8]? { sent.first { $0.first == opcode }.map { [UInt8]($0) } }
    }

    private func makeEngine() -> (JringSyncEngine, FakeWriter) {
        let writer = FakeWriter()
        return (JringSyncEngine(writer: writer, clock: JringClock()), writer)
    }

    func testStartupArmsBackgroundMonitoringAndQueriesCapabilities() {
        let (engine, writer) = makeEngine()
        engine.runStartup()

        XCTAssertEqual(writer.opcodes, [
            0x48,   // claim the ring
            0x02,   // user profile
            0x0c,   // status / firmware
            0x01,   // time sync (local wall clock)
            0x21,   // locale
            0x19,   // background monitoring  ← arms the ring's sensor logging
            0x20,   // capability bitmask
            0x10,   // activity history
            0x16,   // measurement history
        ])
    }

    /// The 0x19 sent at connect must carry the user's configured cadence, an all-day window, and the
    /// constant 0x01 trailer the vendor SDK hardcodes.
    func testStartupSendsConfiguredCadence() {
        let (engine, writer) = makeEngine()
        var settings = MeasurementSettings.jringDefault
        settings.hrIntervalMinutes = 15
        engine.setMeasurementSettings(settings)
        engine.runStartup()

        let frame = try? XCTUnwrap(writer.frame(opcode: 0x19))
        XCTAssertEqual(frame?[1...7].map { $0 }, [0x00, 0x00, 0x17, 0x3b, 0x01, 15, 0x01])
    }

    /// Disabling all-day HR clears the enable byte rather than dropping the command.
    func testDisabledHeartRateSendsEnableZero() {
        let (engine, writer) = makeEngine()
        var settings = MeasurementSettings.jringDefault
        settings.hrEnabled = false
        engine.applyMeasurementSettings(settings)

        let frame = try? XCTUnwrap(writer.frame(opcode: 0x19))
        XCTAssertEqual(frame?[5], 0x00)
    }

    /// BP calibration only rides the connect sequence when the user has actually calibrated.
    func testUncalibratedStartupOmitsBPAdjust() {
        let (engine, writer) = makeEngine()
        engine.runStartup()
        XCTAssertFalse(writer.opcodes.contains(0x33))

        let (calibrated, calWriter) = makeEngine()
        calibrated.setBloodPressureCalibration(systolic: 120, diastolic: 80)
        calibrated.runStartup()
        XCTAssertTrue(calWriter.opcodes.contains(0x33))
    }

    // MARK: - SpO₂

    /// SpO₂ is mode 2 of the 0x23 selector — mode 1 would run a *blood-pressure* measurement.
    func testSpO2UsesCombinedModeSelector() {
        let (engine, writer) = makeEngine()
        engine.startSpO2()
        engine.stopSpO2()
        XCTAssertEqual([UInt8](writer.sent[0])[0...1], [0x23, 0x02])
        XCTAssertEqual([UInt8](writer.sent[1])[0...1], [0x23, 0x00])
    }

    /// Blood pressure is mode 1 of the same 0x23 selector — the mode the app used to send for SpO₂.
    func testBloodPressureUsesCombinedModeOne() {
        let (engine, writer) = makeEngine()
        engine.startBloodPressure()
        engine.stopBloodPressure()
        XCTAssertEqual([UInt8](writer.sent[0])[0...1], [0x23, 0x01])
        XCTAssertEqual([UInt8](writer.sent[1])[0...1], [0x23, 0x00])
    }

    /// The combined sweep sends the SpO₂ mode — confirmed on hardware to return HR, BP, SpO₂ and
    /// fatigue in one 0x24 packet.
    func testCombinedVitalsUsesCombinedModeTwo() {
        let (engine, writer) = makeEngine()
        engine.startCombinedVitals()
        engine.stopCombinedVitals()
        XCTAssertEqual([UInt8](writer.sent[0])[0...1], [0x23, 0x02])
        XCTAssertEqual([UInt8](writer.sent[1])[0...1], [0x23, 0x00])
    }

    /// SpO₂ and BP must never collide on the same mode byte.
    func testSpO2AndBloodPressureUseDistinctModes() {
        let spo2 = [UInt8](RingEncoder().makeSpO2StartCommand())[1]
        let bp = [UInt8](RingEncoder().makeBloodPressureStartCommand())[1]
        XCTAssertNotEqual(spo2, bp)
        XCTAssertEqual(spo2, 0x02)
        XCTAssertEqual(bp, 0x01)
    }

    /// The capability reply is recorded for the offline-history chain, but nothing branches on it yet
    /// — in particular SpO₂ must keep using 0x23 regardless (the vendor never sends 0x3E).
    func testBandFunctionIsRecordedWithoutChangingSpO2Routing() {
        let (engine, writer) = makeEngine()
        var payload = [UInt8](repeating: 0, count: 19)
        payload[65 / 8] = 1 << UInt8(65 % 8)   // "separate BP/SpO₂ mode"
        engine.handle(.bandFunction(JringBandCapabilities(bytes: payload)))
        XCTAssertEqual(engine.bandCapabilities?.separateBloodOxygenMode, true)

        engine.startSpO2()
        XCTAssertEqual([UInt8](writer.sent[0])[0...1], [0x23, 0x02])
    }

    // MARK: - Bind handshake

    func testBindHandshakeRespondsToRingInitiatedClaim() {
        let (engine, writer) = makeEngine()
        engine.handle(.bind(action: 0, state: 0))          // ring: INIT
        engine.handle(.bind(action: 2, state: 0))          // ring: ACK
        XCTAssertEqual(writer.sent.map { [UInt8]($0)[1] }, [1, 4])   // app: APP_START, SUCCESS
    }

    // MARK: - Time

    /// `resyncTime` re-latches the offset and re-sends 0x01, so a timezone change doesn't leave the
    /// ring's RTC (and therefore its sleep detection) on the old offset.
    func testResyncTimeReSendsTimeSync() {
        let (engine, writer) = makeEngine()
        engine.resyncTime()
        XCTAssertEqual(writer.opcodes, [0x01])
    }

    /// Stopping a live HR stream restores the user's cadence, not a hardcoded one.
    func testStopHeartRateRestoresUserCadence() {
        let (engine, writer) = makeEngine()
        var settings = MeasurementSettings.jringDefault
        settings.hrIntervalMinutes = 45
        engine.setMeasurementSettings(settings)

        engine.stopHeartRate()
        XCTAssertEqual(writer.opcodes, [0x15, 0x19])
        XCTAssertEqual([UInt8](writer.sent[1])[6], 45)
    }
}
