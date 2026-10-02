import XCTest
@testable import PulseLoop

@MainActor
final class RWfitSyncEngineTests: XCTestCase {
    private final class Fixture: RingCommandWriter {
        nonisolated deinit {}
        var frames: [Data] = []
        var framing = RWfitFraming.jieli
        var menu = [UInt8](repeating: 0, count: 0x5f)
        var authenticationStatus: UInt8 = 0
        var answerModern = true
        var answerOptionalCommands = true
        var readiness: [Bool] = []
        lazy var gate = RWfitCommandGate(writer: self, legacyCodec: RWfitLegacyCodec(), jlCodec: RWfitJLCodec(), responseTimeout: 0.01)
        lazy var history = RWfitHistorySync(gate: gate, progressSink: { _ in })
        lazy var engine = RWfitSyncEngine(gate: gate, historySync: history, clock: RWfitClock(),
            framingProvider: { [weak self] in self?.framing ?? .legacy },
            selectFraming: { [weak self] in self?.framing = $0 },
            readiness: { [weak self] in self?.readiness.append($0 != nil) },
            deviceIdentifier: { UUID().uuidString })
        init() {
            menu[0] = 2; menu[1] = 0x63; menu[2] = 0x10
        }
        func enqueue(_ command: Data) { frames.append(command) }
        func enqueueTracked(_ command: Data, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            frames.append(command)
            completion(.success(()))
            guard command.first == 0xab, answerModern else { return }
            let payload = Array(command.dropFirst(6))
            if !answerOptionalCommands && payload[0] == 2 && [0x03, 0x04, 0x06, 0x11].contains(payload[1]) { return }
            var response = payload
            if payload[0] == 2 && payload[1] == 0x63 { response = menu }
            if payload[0] == 3 && payload[1] == 4 { response = Array(payload.prefix(3)) + [authenticationStatus] }
            gate.noteJieliFrame(flag: 0x11, triple: .init(cmd: payload[0], key: payload[1], keyFlag: payload[2]), payload: response)
        }
        var modernPayloads: [[UInt8]] { frames.filter { $0.first == 0xab }.map { Array($0.dropFirst(6)) } }
        func prepare() {
            gate.framing = framing
            history.framing = framing
            history.persist = { _ in }
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<800 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for session state")
    }

    func testStartupIsSequentialAndReadinessFollowsAuthentication() async {
        let fixture = Fixture()
        fixture.menu[0x2c] = 1
        fixture.prepare()
        fixture.engine.runStartup()
        fixture.engine.startHeartRate()
        fixture.engine.syncHistory()
        await waitUntil { fixture.engine.isReady }
        XCTAssertEqual(fixture.modernPayloads.prefix(5).map { Array($0.prefix(2)) },
                       [[3, 2], [2, 2], [2, 1], [2, 0x63], [3, 4]])
        XCTAssertEqual(fixture.readiness, [false, true])
        XCTAssertFalse(fixture.modernPayloads.contains { $0[0] == 6 || $0[0] == 5 })
        fixture.engine.cancel()
    }

    func testPasswordRejectionPreventsReadinessAndHistory() async {
        let fixture = Fixture()
        fixture.menu[0x2c] = 1
        fixture.authenticationStatus = 1
        fixture.prepare()
        fixture.engine.runStartup()
        await waitUntil { fixture.readiness.count == 2 }
        XCTAssertFalse(fixture.engine.isReady)
        XCTAssertEqual(fixture.readiness, [false, false])
        XCTAssertFalse(fixture.modernPayloads.contains { $0[0] == 5 })
        XCTAssertEqual(Array(fixture.modernPayloads.last?.prefix(2) ?? []), [3, 4])
        fixture.engine.cancel()
    }

    func testMalformedMenuPreventsReadiness() async {
        let fixture = Fixture()
        fixture.menu = [2, 0x63, 0x10]
        fixture.prepare()
        fixture.engine.runStartup()
        await waitUntil { fixture.readiness.count == 2 }
        XCTAssertFalse(fixture.engine.isReady)
        XCTAssertEqual(fixture.modernPayloads.count, 4)
        fixture.engine.cancel()
    }

    func testLegacyProbeSilenceFallsBackToModernHandshake() async {
        let fixture = Fixture()
        fixture.framing = .legacy
        fixture.prepare()
        fixture.engine.runStartup()
        await waitUntil { fixture.engine.isReady }
        XCTAssertEqual(fixture.frames.filter { $0.first == 0x7e }.count, 2)
        XCTAssertEqual(fixture.framing, .jieli)
        XCTAssertEqual(Array(fixture.modernPayloads.first?.prefix(2) ?? []), [3, 2])
        fixture.engine.cancel()
    }

    func testTotalSilenceFailsReadinessAndReconnectStartsFresh() async {
        let fixture = Fixture()
        fixture.answerModern = false
        fixture.prepare()
        fixture.engine.runStartup()
        await waitUntil { fixture.readiness.count == 2 }
        XCTAssertFalse(fixture.engine.isReady)
        XCTAssertEqual(fixture.modernPayloads.count, 3)
        fixture.engine.cancel()
        fixture.answerModern = true
        fixture.engine.runStartup()
        await waitUntil { fixture.engine.isReady }
        XCTAssertEqual(fixture.readiness, [false, false, false, true])
        fixture.engine.cancel()
    }
    func testStopBeforeStartTaskRunsCannotTurnMeasurementOnAfterward() async {
        let fixture = Fixture()
        fixture.menu[0x53] = 1
        fixture.menu[0x55] = 1
        fixture.prepare()
        fixture.engine.runStartup()
        await waitUntil { fixture.engine.isReady }
        fixture.engine.startHeartRate()
        fixture.engine.stopHeartRate()
        await waitUntil { fixture.modernPayloads.contains { $0[0] == 6 && $0[1] == 9 } }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let measurements = fixture.modernPayloads.filter { $0[0] == 6 && $0[1] == 9 }
        XCTAssertEqual(measurements.count, 1, "The pending start must not send ON after STOP")
        XCTAssertEqual(measurements.first?.last, 0)
        XCTAssertFalse(fixture.history.isPaused)
        fixture.engine.cancel()
    }

    func testUnansweredOptionalConfigurationCannotBlockModernReadiness() async {
        let fixture = Fixture()
        fixture.answerOptionalCommands = false
        fixture.prepare()
        fixture.engine.runStartup()
        await waitUntil { fixture.engine.isReady }
        await waitUntil { fixture.modernPayloads.contains { $0[0] == 2 && $0[1] == 4 } }
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(fixture.engine.isReady, "Optional metadata timeouts must not invalidate authenticated readiness")
        XCTAssertEqual(fixture.readiness, [false, true])
        XCTAssertEqual(fixture.modernPayloads.prefix(4).map { Array($0.prefix(2)) }, [[3, 2], [2, 2], [2, 1], [2, 0x63]])
        XCTAssertFalse(fixture.modernPayloads.contains { $0[0] == 2 && $0[1] == 0x11 }, "Legacy units configuration is not part of the modern handshake")
        fixture.engine.cancel()
    }

}
