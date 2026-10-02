import XCTest
@testable import PulseLoop

/// Unit tests for `CRPSyncEngine` — the connect handshake and interactive commands enqueue the right
/// CRP frames. Mirrors the vendor's connect flow (set clock, then user info). Ported from the Android
/// app's `CRPSyncEngineTest.kt`, adapted to iOS's `UserProfileValues` initializer.
@MainActor
final class CRPSyncEngineTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
        /// (group, cmd) of each written frame.
        var opcodes: [[Int]] { sent.map { let b = [UInt8]($0); return [Int(b[4]), Int(b[5])] } }
        func payloadByte(_ frame: Int, _ index: Int) -> Int { Int([UInt8](sent[frame])[index]) }
    }

    private func finishTimingHistory(_ engine: CRPSyncEngine) {
        engine.handle(.timingHistoryFrame(cmd: CRPCommands.cmdQueryTimingHR, day: 0, frameIndex: 1))
        engine.handle(.timingHistoryFrame(cmd: CRPCommands.cmdQueryTimingSpO2, day: 0, frameIndex: 1))
        engine.handle(.timingHistoryFrame(cmd: CRPCommands.cmdQueryTimingStress, day: 0, frameIndex: 1))
        engine.handle(.timingHistoryFrame(cmd: CRPCommands.cmdQueryTimingHRV, day: 0, frameIndex: 3))
    }

    /// The connect handshake leads with set-time, then user info once a profile exists, then the
    /// self-description queries. Everything after that is the all-day timing config and the history
    /// pull, covered by their own tests below.
    func testRunStartupSendsSetTimeThenUserInfoOnceAProfileIsStored() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        // set-time, then the firmware query that keeps the UI off "Firmware: reading". Firmware is
        // group 3 / cmd 3 (`b1/l.k`) — the old group-7 opcode was the vendor's Gomore module.
        XCTAssertEqual(Array(w.opcodes.prefix(2)), [[1, 1], [3, 3]])

        w.sent.removeAll()
        engine.setUserProfile(UserProfileValues(metric: true, sex: "male", age: 30, heightCm: 180, weightKg: 75))
        engine.runStartup()
        XCTAssertEqual(Array(w.opcodes.prefix(2)), [[1, 1], [1, 0]])
    }

    /// Nothing may target group 7 any more: every `b1/r` builder is a Gomore call, and the R11
    /// answered none of the 23 sends in zaggash's 2026-07-25 capture (Android issue #29).
    func testNothingIsSentToTheGomoreGroup() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.setUserProfile(UserProfileValues(metric: true, sex: "male", age: 30, heightCm: 180, weightKg: 75))
        engine.runStartup()
        XCTAssertFalse(w.opcodes.contains { $0[0] == 7 }, "group 7 is Gomore, not device info")
    }

    // MARK: - Connection read-backs

    /// The read-backs must precede `applyTimingSettings`: they report each monitor's *current*
    /// interval, and the timing config force-enables everything moments later. Asked afterwards,
    /// every reply would describe the state we just imposed.
    func testReadBacksAreSentBeforeTheTimingConfig() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        // Read-backs: SpO2 support 2/37, then the monitor-state queries 2/6, 2/7, 2/8, 2/45, 2/21.
        for cmd in [37, 6, 7, 8, 45, 21] {
            XCTAssertTrue(w.opcodes.contains([2, cmd]), "expected read-back group2/cmd\(cmd)")
        }
        guard let lastReadBack = w.opcodes.lastIndex(where: { $0[0] == 2 && [37, 6, 7, 8, 45, 21].contains($0[1]) }),
              let firstTimingConfig = w.opcodes.firstIndex(where: { $0[0] == 1 && [6, 7, 8, 39, 13].contains($0[1]) })
        else { return XCTFail("missing read-backs or timing config") }
        XCTAssertLessThan(lastReadBack, firstTimingConfig,
                          "read-backs must be asked before we impose a config")
    }

    /// Neither a firmware string nor a sensor roster changes between syncs, and `runStartup` is also
    /// the background re-sync — so re-asking would add seven writes to every pass on a single-channel
    /// ring. Firmware is included: it used to be sent unconditionally, contradicting that argument.
    func testConnectionQueriesAreSentOncePerConnectionNotPerPass() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        XCTAssertTrue(w.opcodes.contains([3, 3]), "firmware asked on the first pass")

        w.sent.removeAll()
        engine.runStartup()
        XCTAssertFalse(w.opcodes.contains([3, 3]), "firmware must not repeat every pass")
        for cmd in [37, 6, 7, 8, 45, 21] {
            XCTAssertFalse(w.opcodes.contains([2, cmd]), "read-back group2/cmd\(cmd) must not repeat")
        }
    }

    // MARK: - Sleep backfill

    /// The poll pass only asks for `daysAgo = 0`, so without a backfill the app's stored history
    /// could only grow one night at a time. Each reply is self-describing, so this is safe to send
    /// blind — a day the ring has no record of simply produces no reply.
    func testSleepBackfillPullsThePriorWeekOncePerConnection() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        let sleepDays = w.opcodes.indices
            .filter { w.opcodes[$0] == [2, 14] }
            .map { w.payloadByte($0, 6) }
        XCTAssertEqual(sleepDays, [0, 1, 2, 3, 4, 5, 6], "today plus six nights of backfill")

        finishTimingHistory(engine)
        w.sent.removeAll()
        engine.runStartup()
        let secondPass = w.opcodes.indices
            .filter { w.opcodes[$0] == [2, 14] }
            .map { w.payloadByte($0, 6) }
        XCTAssertEqual(secondPass, [0], "the backfill is once per connection; the pass re-pulls today only")
    }

    func testHeartRateStartAndStopEnqueueGroup1Cmd9() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.startHeartRate()
        engine.stopHeartRate()
        XCTAssertEqual(w.opcodes, [[1, 9], [1, 9]])
        XCTAssertEqual(w.payloadByte(0, 6), 1)   // enable
        XCTAssertEqual(w.payloadByte(1, 6), 0)   // disable
    }

    func testFindDeviceEnqueuesItsCommand() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.findDevice()
        XCTAssertEqual(w.opcodes, [[9, 2]])
    }

    func testApplyUserProfilePushesUserInfoImmediately() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.applyUserProfile(UserProfileValues(metric: true, sex: "female", age: 25, heightCm: 165, weightKg: 60))
        XCTAssertEqual(w.opcodes, [[1, 0]])
        // height passes through; stride is estimated as ~0.43*height.
        XCTAssertEqual(w.payloadByte(0, 6), 165)
        XCTAssertEqual(w.payloadByte(0, 10), Int(165.0 * 0.43))   // 70
    }

    // MARK: - All-day monitoring + history pull

    /// A fresh R11 ships with every all-day monitor OFF, so connecting without a saved config must
    /// still force them on — otherwise the ring records nothing and every history query comes back
    /// empty (Android issue #29).
    func testRunStartupForcesAllDayMonitoringOnWithoutASavedConfig() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        // Enable-timing opcodes are group 1: HR 6, HRV 7, SpO2 8, stress 39, temp 13.
        for cmd in [6, 7, 8, 39, 13] {
            XCTAssertTrue(w.opcodes.contains([1, cmd]), "expected all-day enable for group1/cmd\(cmd)")
        }
    }

    /// A saved config must actually reach the ring. `setMeasurementSettings` once took an Optional —
    /// a signature that satisfied no protocol requirement, so `RingSyncCoordinator`'s call hit the
    /// no-op default extension and the user's config was silently dropped in favour of `.allOnDefault`.
    func testSavedMeasurementSettingsAreHonouredOverTheForcedDefault() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        var settings = MeasurementSettings.allOnDefault
        settings.spo2Enabled = false
        engine.setMeasurementSettings(settings)
        engine.runStartup()
        guard let index = w.opcodes.firstIndex(of: [1, 8]) else { return XCTFail("no SpO2 timing command") }
        XCTAssertEqual(w.payloadByte(index, 6), 0, "a disabled vital sends interval 0, not the default")
    }

    /// The history pull uses the group-2 opcodes. Temperature is cmd **22** (`b1/i0.b`) — cmd 48 is
    /// the vendor's `querySleepState`, which is why the ring never answered the old query.
    func testRunStartupQueriesHistoryOnGroupTwo() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        for cmd in [15, 17, 16, 47, 22, 14] {   // HR, SpO2, HRV, stress, temp, sleep
            XCTAssertTrue(w.opcodes.contains([2, cmd]), "expected group2/cmd\(cmd) history query")
        }
        XCTAssertFalse(w.opcodes.contains([2, 48]), "cmd 48 is querySleepState, not temperature history")
    }

    /// Each timing query starts at frame 0 of today.
    func testHistoryQueriesStartAtTodayFrameZero() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        guard let index = w.opcodes.firstIndex(of: [2, 15]) else { return XCTFail("no HR history query") }
        XCTAssertEqual(w.payloadByte(index, 6), 0)   // day = today
        XCTAssertEqual(w.payloadByte(index, 7), 0)   // frameIndex = 0
    }

    /// A frame below the vital's terminal index pulls the next one — the vendor's sequential
    /// `insertBleMessage(<query>.b(day, index + 1))`.
    func testTimingFrameBelowTerminalIndexRequestsTheNextFrame() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        XCTAssertEqual(w.opcodes, [[2, 15]])
        XCTAssertEqual(w.payloadByte(0, 7), 1, "should ask for frame 1")
    }

    /// HR/SpO2/stress finish at frame 1 (two 144-slot frames); HRV runs to frame 3 (four 72-slot).
    func testTerminalFrameIndexEndsTheWalkPerVital() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()

        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 1))
        XCTAssertTrue(w.sent.isEmpty, "HR terminates at frame 1")

        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 16, day: 0, frameIndex: 1))
        XCTAssertEqual(w.opcodes, [[2, 16]], "HRV continues past frame 1")

        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 16, day: 0, frameIndex: 3))
        XCTAssertTrue(w.sent.isEmpty, "HRV terminates at frame 3")
    }

    /// A ring that re-sends the same frame must not trigger a request storm.
    func testDuplicateFrameDoesNotRequestTwice() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        XCTAssertEqual(w.sent.count, 1)
    }

    /// Each completed sync pass re-pulls the whole timeline, so its dedupe guard resets for the next.
    func testFollowUpGuardResetsEachSyncPass() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        finishTimingHistory(engine)
        engine.syncHistory()
        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        XCTAssertEqual(w.sent.count, 1, "a new pass may re-request frame 1")
    }

    /// The follow-up guard keys on `day` too. Today every timing query is `day 0`, but this engine
    /// already issues multi-day requests for sleep, so a key without `day` would silently swallow
    /// day 1's frame-1 follow-up the moment the timing vitals get the same backfill treatment.
    func testFollowUpGuardDistinguishesDays() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        engine.handle(.timingHistoryFrame(cmd: 15, day: 1, frameIndex: 0))
        XCTAssertEqual(w.sent.count, 2, "a different day is a different follow-up")
        XCTAssertEqual(w.payloadByte(0, 6), 0)   // day 0
        XCTAssertEqual(w.payloadByte(1, 6), 1)   // day 1
    }

    /// A non-timing event must not be mistaken for a history cursor.
    func testNonTimingEventsAreIgnoredByHandle() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        w.sent.removeAll()
        engine.handle(.heartRateSample(bpm: 60, timestamp: Date()))
        engine.handle(.wearingStatus(worn: false, timestamp: Date()))
        XCTAssertTrue(w.sent.isEmpty)
    }

    // MARK: - Sync lifecycle + completion

    func testPeriodicSyncHistoryIsStandaloneAndRejectsAConcurrentKick() {
        let w = FakeWriter()
        var stages: [String] = []
        let engine = CRPSyncEngine(writer: w, eventSink: { event in
            if case let .syncProgress(stage) = event { stages.append(stage) }
        })

        engine.syncHistory()
        let firstPass = w.sent
        engine.syncHistory()

        XCTAssertEqual(w.sent, firstPass, "an in-flight pass must reject a duplicate periodic kick")
        XCTAssertEqual(stages, ["Syncing ring history…"])
        XCTAssertFalse(w.opcodes.contains([3, 3]), "periodic history must not replay the connect handshake")
        let sleepDays = w.opcodes.indices
            .filter { w.opcodes[$0] == [2, 14] }
            .map { w.payloadByte($0, 6) }
        XCTAssertEqual(sleepDays, [0], "periodic history pulls today, not the per-link backfill")
    }

    func testAllTerminalTimingStreamsPublishExactlyOneDone() {
        let w = FakeWriter()
        var stages: [String] = []
        let engine = CRPSyncEngine(writer: w, eventSink: { event in
            if case let .syncProgress(stage) = event { stages.append(stage) }
        })
        engine.syncHistory()

        engine.handle(.timingHistoryFrame(cmd: CRPCommands.cmdQueryTimingHR, day: 0, frameIndex: 1))
        engine.handle(.timingHistoryFrame(cmd: CRPCommands.cmdQueryTimingSpO2, day: 0, frameIndex: 1))
        engine.handle(.timingHistoryFrame(cmd: CRPCommands.cmdQueryTimingStress, day: 0, frameIndex: 1))
        XCTAssertEqual(stages, ["Syncing ring history…"], "one stream is still outstanding")

        engine.handle(.timingHistoryFrame(cmd: CRPCommands.cmdQueryTimingHRV, day: 0, frameIndex: 3))
        engine.handle(.timingHistoryFrame(cmd: CRPCommands.cmdQueryTimingHRV, day: 0, frameIndex: 3))
        XCTAssertEqual(stages, ["Syncing ring history…", "done"])
    }

    func testSilentTimingStreamsCompleteAtTheBoundedWatchdog() async {
        let w = FakeWriter()
        var stages: [String] = []
        let engine = CRPSyncEngine(
            writer: w,
            historyWatchdogNanos: 20_000_000,
            eventSink: { event in
                if case let .syncProgress(stage) = event { stages.append(stage) }
            }
        )
        engine.syncHistory()

        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(stages, ["Syncing ring history…", "done"])

        // A late nonterminal reply after the watchdog must neither restart the cursor walk nor publish
        // a second completion.
        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: CRPCommands.cmdQueryTimingHR, day: 0, frameIndex: 0))
        XCTAssertTrue(w.sent.isEmpty)
        XCTAssertEqual(stages.filter { $0 == "done" }.count, 1)
    }

    func testDisconnectCancelsCompletionAndReconnectResendsPerLinkQueries() async {
        let w = FakeWriter()
        var stages: [String] = []
        let engine = CRPSyncEngine(
            writer: w,
            historyWatchdogNanos: 20_000_000,
            eventSink: { event in
                if case let .syncProgress(stage) = event { stages.append(stage) }
            }
        )
        engine.runStartup()
        XCTAssertTrue(w.opcodes.contains([3, 3]))

        engine.connectionDidEnd()
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(stages.contains("done"), "a dropped link is not a completed sync")

        w.sent.removeAll()
        engine.connectionDidStart()
        engine.runStartup()
        XCTAssertTrue(w.opcodes.contains([3, 3]), "firmware/read-backs are once per GATT link")
        let sleepDays = w.opcodes.indices
            .filter { w.opcodes[$0] == [2, 14] }
            .map { w.payloadByte($0, 6) }
        XCTAssertEqual(sleepDays, [0, 1, 2, 3, 4, 5, 6], "backfill must be retried on the new link")
    }
}
