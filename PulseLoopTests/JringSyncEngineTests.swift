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
        var emitted: [RingDecodedEvent] = []
        var deviceIdentifier: String? { "test-ring" }
        func enqueue(_ command: Data) { sent.append(command) }
        func emit(_ event: RingDecodedEvent) { emitted.append(event) }
        var opcodes: [UInt8] { sent.compactMap(\.first) }
        func frame(opcode: UInt8) -> [UInt8]? { sent.first { $0.first == opcode }.map { [UInt8]($0) } }
        /// `[opcode, day]` of every history request, in send order.
        var historyRequests: [[UInt8]] {
            var requests: [[UInt8]] = []
            for frame in sent where frame.first == 0x10 || frame.first == 0x16 {
                requests.append([UInt8](frame.prefix(2)))
            }
            return requests
        }
        var doneCount: Int {
            emitted.filter { if case .historySyncFinished = $0 { return true } else { return false } }.count
        }
    }

    private static let lastSyncKey = "jring.lastHistorySyncFinishedAt.test-ring"
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "JringSyncEngineTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Long timers by default so only the tests that inject short ones ever see one fire.
    private func makeEngine(lastSync: Date? = nil, now: Date = Date(),
                            quiet: TimeInterval = 60, watchdog: TimeInterval = 60) -> (JringSyncEngine, FakeWriter) {
        if let lastSync { defaults.set(lastSync, forKey: Self.lastSyncKey) }
        let writer = FakeWriter()
        let engine = JringSyncEngine(writer: writer, clock: JringClock(), defaults: defaults, now: { now },
                                     activityQuietSeconds: quiet, stepWatchdogSeconds: watchdog)
        return (engine, writer)
    }

    private func daysAgo(_ days: Int, from now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now)!
    }

    /// End both steps of the current day the way the ring does on failure / end-of-stream.
    private func finishDay(_ engine: JringSyncEngine) {
        engine.handle(.jringHistoryFrame(.activityFailed))
        engine.handle(.jringHistoryFrame(.measurementEnd))
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
            0x10,   // activity history — the 16 follows once this day's 10 transfer ends
        ])
        // Never synced here → the vendor's maximum look-back, 6 days.
        XCTAssertEqual(writer.historyRequests, [[0x10, 6]])
    }

    // MARK: - Per-day history loop

    /// `10 dd` / `16 dd` are 20-byte frames, zero padded (vendor `BluetoothLeService.a(int,int)`).
    func testDayQueryCommandBytes() {
        let encoder = RingEncoder()
        XCTAssertEqual([UInt8](encoder.makeHistoryQueryCommand(day: 3)), [0x10, 0x03] + [UInt8](repeating: 0, count: 18))
        XCTAssertEqual([UInt8](encoder.makeHistoryMeasurementQueryCommand(day: 3)), [0x16, 0x03] + [UInt8](repeating: 0, count: 18))
        // The no-argument forms stay "today".
        XCTAssertEqual([UInt8](encoder.makeHistoryQueryCommand()), [0x10] + [UInt8](repeating: 0, count: 19))
        XCTAssertEqual([UInt8](encoder.makeHistoryMeasurementQueryCommand()), [0x16] + [UInt8](repeating: 0, count: 19))
    }

    /// `iMax` = whole days since the last finished sync: two days ago → start at day 2.
    func testStartupStartsAtDaysSinceLastFinishedSync() {
        let (engine, writer) = makeEngine(lastSync: daysAgo(2))
        engine.runStartup()
        XCTAssertEqual(writer.historyRequests, [[0x10, 2]])
    }

    /// The look-back is capped at 6, like the vendor's.
    func testLookBackIsCappedAtSixDays() {
        let (engine, writer) = makeEngine(lastSync: daysAgo(30))
        engine.runStartup()
        XCTAssertEqual(writer.historyRequests, [[0x10, 6]])
    }

    /// `0x90` ends the steps step → `16` of the same day; `16 FF` → the next-newer day's `10`.
    func testMeasurementEndAdvancesToNextDay() {
        let (engine, writer) = makeEngine(lastSync: daysAgo(2))
        engine.runStartup()
        engine.handle(.jringHistoryFrame(.activityFailed))
        XCTAssertEqual(writer.historyRequests, [[0x10, 2], [0x16, 2]])
        engine.handle(.jringHistoryFrame(.measurementEnd))
        XCTAssertEqual(writer.historyRequests, [[0x10, 2], [0x16, 2], [0x10, 1]])
    }

    /// `0x10`/`0x11` packets have no terminator: 2 s (here 50 ms) without one ends the step.
    func testQuietWindowAdvancesStepsToHeartRate() async throws {
        let (engine, writer) = makeEngine(lastSync: daysAgo(1), quiet: 0.05)
        engine.runStartup()
        engine.handle(.jringHistoryFrame(.activity))
        engine.handle(.jringHistoryFrame(.activity))
        XCTAssertEqual(writer.historyRequests, [[0x10, 1]], "still inside the quiet window")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(writer.historyRequests, [[0x10, 1], [0x16, 1]])
    }

    /// The vendor's other `16` terminator: the last segment's last `A0` block (`bad.java:3881`).
    func testHeartRateEndsWhenLastSegmentsLastBlockArrives() {
        let (engine, writer) = makeEngine(lastSync: daysAgo(1))
        engine.runStartup()
        engine.handle(.jringHistoryFrame(.activityFailed))
        engine.handle(.jringHistoryFrame(.measurementHeader(segments: 2)))
        engine.handle(.jringHistoryFrame(.measurementSegment(index: 1, blocks: 2)))
        engine.handle(.jringHistoryFrame(.measurementBlock(index: 0)))
        engine.handle(.jringHistoryFrame(.measurementBlock(index: 1)))   // last block, but not the last segment
        engine.handle(.jringHistoryFrame(.measurementSegment(index: 2, blocks: 2)))
        engine.handle(.jringHistoryFrame(.measurementBlock(index: 0)))
        XCTAssertEqual(writer.historyRequests.count, 2)
        engine.handle(.jringHistoryFrame(.measurementBlock(index: 1)))
        XCTAssertEqual(writer.historyRequests, [[0x10, 1], [0x16, 1], [0x10, 0]])
        // A trailing FF from the finished day must not skip today's steps.
        engine.handle(.jringHistoryFrame(.measurementEnd))
        XCTAssertEqual(writer.historyRequests.count, 3)
    }

    /// "done" fires exactly once, after day 0's heart rate — not per day — and records the sync point.
    func testDoneFiresOnceAfterDayZeroAndRecordsFinish() {
        let now = Date()
        let (engine, writer) = makeEngine(lastSync: daysAgo(1, from: now), now: now)
        engine.runStartup()
        finishDay(engine)
        XCTAssertEqual(writer.doneCount, 0)
        finishDay(engine)
        XCTAssertEqual(writer.historyRequests, [[0x10, 1], [0x16, 1], [0x10, 0], [0x16, 0]])
        XCTAssertEqual(writer.doneCount, 1)
        XCTAssertEqual(defaults.object(forKey: Self.lastSyncKey) as? Date, now)

        // Stale terminators after the pass change nothing.
        finishDay(engine)
        XCTAssertEqual(writer.doneCount, 1)
        XCTAssertEqual(writer.historyRequests.count, 4)

        // The next connect starts from today.
        let (next, nextWriter) = makeEngine(now: now)
        next.runStartup()
        XCTAssertEqual(nextWriter.historyRequests, [[0x10, 0]])
    }

    /// A step the ring never answers is skipped by the watchdog; the pass still reports "done" but is
    /// not recorded as finished, so the next sync re-reads the same days.
    func testWatchdogSkipsSilentStepsWithoutRecordingFinish() async throws {
        let lastSync = daysAgo(0)
        let (engine, writer) = makeEngine(lastSync: lastSync, watchdog: 0.05)
        engine.runStartup()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(writer.historyRequests, [[0x10, 0], [0x16, 0]])
        XCTAssertEqual(writer.doneCount, 1)
        XCTAssertEqual(defaults.object(forKey: Self.lastSyncKey) as? Date, lastSync)
    }

    /// A dropped link cancels the loop: no timer fires into the reconnect gap, and late frames are ignored.
    func testDisconnectCancelsLoop() async throws {
        let (engine, writer) = makeEngine(lastSync: daysAgo(1), quiet: 0.05, watchdog: 0.05)
        engine.runStartup()
        engine.handle(.jringHistoryFrame(.activity))
        engine.connectionDidEnd()
        try await Task.sleep(nanoseconds: 300_000_000)
        engine.handle(.jringHistoryFrame(.activityFailed))
        engine.handle(.jringHistoryFrame(.measurementEnd))
        XCTAssertEqual(writer.historyRequests, [[0x10, 1]])
        XCTAssertEqual(writer.doneCount, 0)

        // The next link starts a fresh pass.
        engine.connectionDidStart()
        engine.runStartup()
        XCTAssertEqual(writer.historyRequests, [[0x10, 1], [0x10, 1]])
    }

    /// A full 7-day pass walks 6 → 0 and never writes an `0x0E` frame (`0E 12 34 12 34 …` is the
    /// factory reset; other `0E` frames are OTA / power-off / restart).
    func testFullPassWalksSixDaysToTodayAndNeverSends0E() {
        let (engine, writer) = makeEngine()
        engine.runStartup()
        for _ in 0...6 { finishDay(engine) }
        engine.syncVitalsHistory()
        engine.handle(.jringHistoryFrame(.measurementEnd))
        engine.unbind()
        var expected: [[UInt8]] = []
        for day in stride(from: UInt8(6), through: 0, by: -1) {
            expected.append([0x10, day])
            expected.append([0x16, day])
        }
        expected.append([0x16, 0])   // the post-workout backfill
        XCTAssertEqual(writer.historyRequests, expected)
        XCTAssertFalse(writer.opcodes.contains(0x0e))
        XCTAssertEqual(writer.doneCount, 2)
    }

    /// Post-workout backfill stays today-only `16 00`; its end reports "done" but is not a full sync.
    func testVitalsHistoryIsTodayOnlyAndNotAFullSync() {
        let lastSync = daysAgo(3)
        let (engine, writer) = makeEngine(lastSync: lastSync)
        engine.syncVitalsHistory()
        XCTAssertEqual(writer.historyRequests, [[0x16, 0]])
        engine.handle(.jringHistoryFrame(.measurementEnd))
        XCTAssertEqual(writer.doneCount, 1)
        XCTAssertEqual(defaults.object(forKey: Self.lastSyncKey) as? Date, lastSync)
    }

    /// During a full pass the backfill would interleave a second `16`; the pass covers today anyway.
    func testVitalsHistoryIsSkippedDuringFullPass() {
        let (engine, writer) = makeEngine(lastSync: daysAgo(1))
        engine.runStartup()
        engine.syncVitalsHistory()
        XCTAssertEqual(writer.historyRequests, [[0x10, 1]])
    }

    /// Forget clears the ring's sync point, so pairing it again re-reads the full week.
    func testUnbindClearsSyncPoint() {
        let (engine, writer) = makeEngine(lastSync: daysAgo(1))
        engine.unbind()
        XCTAssertNil(defaults.object(forKey: Self.lastSyncKey))
        XCTAssertEqual(writer.opcodes, [0x4b])
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
