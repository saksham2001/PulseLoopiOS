import XCTest
@testable import PulseLoop

/// The CRP (COLMI R11) spot HR / SpO₂ rule: the ring answers with one terminal result frame, so the
/// first result decides. Ported from the Android app's `CRPSpotControllerTest.kt`.
@MainActor
final class CRPSpotMeasurementTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func result(_ kind: CRPSpotMeasurement.Kind, _ payload: [UInt8]) -> Data {
        CRPProtocol.frame(group: CRPCommands.groupDevice, cmd: kind.resultCmd, payload: payload)
    }

    private func written(_ kind: CRPSpotMeasurement.Kind) -> CRPSpotMeasurement {
        var m = CRPSpotMeasurement(kind: kind, queuedAt: t0)
        m.noteStartWritten(true, at: t0.addingTimeInterval(1))
        return m
    }

    // MARK: Result frames

    func testValidHRResultCompletesImmediately() {
        var m = written(.heartRate)
        m.ingest(result(.heartRate, [72]))
        XCTAssertEqual(m.check(at: t0.addingTimeInterval(17)), .reading(72))
    }

    func testValidSpO2ResultCompletesImmediately() {
        var m = written(.spo2)
        m.ingest(result(.spo2, [97]))
        XCTAssertEqual(m.check(at: t0.addingTimeInterval(48)), .reading(97))
    }

    func testNoReadingResultsEndTheMeasurementAsFailure() {
        let cases: [(CRPSpotMeasurement.Kind, [UInt8])] = [
            (.heartRate, []), (.heartRate, [0]), (.heartRate, [0xFF]), (.heartRate, [30]), (.heartRate, [201]),
            (.spo2, []), (.spo2, [0]), (.spo2, [0xFF]), (.spo2, [69]), (.spo2, [101]),
        ]
        for (kind, payload) in cases {
            var m = written(kind)
            m.ingest(result(kind, payload))
            XCTAssertEqual(m.check(at: t0.addingTimeInterval(2)), .failed(.noReading), "\(kind) \(payload)")
        }
    }

    func testTheOtherKindsResultDoesNotDecide() {
        var m = written(.spo2)
        m.ingest(result(.heartRate, [72]))
        XCTAssertNil(m.check(at: t0.addingTimeInterval(2)))
    }

    // MARK: Wear state and link

    func testNotWornPushEndsTheMeasurement() {
        var m = written(.heartRate)
        m.ingest(CRPProtocol.frame(group: CRPCommands.groupPower, cmd: CRPCommands.cmdWearState, payload: [0]))
        XCTAssertEqual(m.check(at: t0.addingTimeInterval(2)), .failed(.notWorn))

        var bridged = written(.spo2)
        bridged.noteWorn(false)
        XCTAssertEqual(bridged.check(at: t0.addingTimeInterval(2)), .failed(.notWorn))
    }

    func testAWornPushDoesNothing() {
        var m = written(.heartRate)
        m.ingest(CRPProtocol.frame(group: CRPCommands.groupPower, cmd: CRPCommands.cmdWearState, payload: [1]))
        m.noteWorn(true)
        XCTAssertNil(m.check(at: t0.addingTimeInterval(2)))
    }

    func testDisconnectFailsImmediately() {
        var m = written(.spo2)
        m.noteDisconnected()
        XCTAssertEqual(m.check(at: t0.addingTimeInterval(2)), .failed(.disconnected))
    }

    func testTheFirstVerdictWins() {
        var m = written(.heartRate)
        m.ingest(result(.heartRate, [72]))
        m.noteWorn(false)
        m.noteDisconnected()
        XCTAssertEqual(m.check(at: t0.addingTimeInterval(40)), .reading(72))
    }

    // MARK: Traffic that must not decide

    func testHistoryTrafficDoesNotCompleteASpotMeasurement() {
        var m = written(.heartRate)
        // Group 2 HR timeline frame (cmd 15) carrying plausible bpm values, and a sleep reply.
        m.ingest(CRPProtocol.frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryTimingHR, payload: [0, 0, 72, 74]))
        m.ingest(CRPProtocol.frame(group: CRPCommands.groupHistory, cmd: CRPCommands.cmdQueryHistorySleep, payload: [0, 1, 1, 0]))
        // A fragment that merely starts like a frame is not a whole result frame.
        m.ingest(result(.heartRate, [72]).prefix(5))
        XCTAssertNil(m.check(at: t0.addingTimeInterval(10)))
    }

    // MARK: Deadlines

    func testTheDeadlineCountsFromTheWriteNotTheQueue() {
        var m = CRPSpotMeasurement(kind: .heartRate, queuedAt: t0)
        m.noteStartWritten(true, at: t0.addingTimeInterval(10))
        XCTAssertNil(m.check(at: t0.addingTimeInterval(35)), "30 s from the queue, only 25 s from the write")
        XCTAssertEqual(m.check(at: t0.addingTimeInterval(40)), .failed(.timedOut))
    }

    func testSpO2GetsItsLongerWindow() {
        var m = written(.spo2)
        XCTAssertNil(m.check(at: t0.addingTimeInterval(50)), "the R11 answers SpO2 ~48 s in")
        XCTAssertEqual(m.check(at: t0.addingTimeInterval(61)), .failed(.timedOut))
    }

    func testAStartThatIsNeverWrittenFailsAfterTheDispatchTimeout() {
        var m = CRPSpotMeasurement(kind: .spo2, queuedAt: t0)
        XCTAssertNil(m.check(at: t0.addingTimeInterval(CRPSpotMeasurement.dispatchTimeout - 1)))
        XCTAssertEqual(m.check(at: t0.addingTimeInterval(CRPSpotMeasurement.dispatchTimeout)), .failed(.notDispatched))
    }

    func testAFailedWriteFailsAtOnce() {
        var m = CRPSpotMeasurement(kind: .heartRate, queuedAt: t0)
        m.noteStartWritten(false, at: t0)
        XCTAssertEqual(m.check(at: t0), .failed(.notDispatched))
    }

    // MARK: Engine frames

    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
    }

    func testEngineWritesTheSpotStartTrackedAndTheStop() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        var writtenFlags: [Bool] = []
        engine.startSpot(.spo2) { writtenFlags.append($0) }
        engine.stopSpot(.spo2)
        engine.startSpot(.heartRate) { writtenFlags.append($0) }
        XCTAssertEqual(w.sent, [CRPProtocol.measureSpO2(true), CRPProtocol.measureSpO2(false), CRPProtocol.measureHeartRate(true)])
        XCTAssertEqual(writtenFlags, [true, true])
    }
}
