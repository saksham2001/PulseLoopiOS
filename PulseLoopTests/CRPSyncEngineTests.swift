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

    func testRunStartupSendsSetTimeThenUserInfoOnceAProfileIsStored() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        XCTAssertEqual(w.opcodes, [[1, 1]])   // set-time only, no profile yet

        w.sent.removeAll()
        engine.setUserProfile(UserProfileValues(metric: true, sex: "male", age: 30, heightCm: 180, weightKg: 75))
        engine.runStartup()
        XCTAssertEqual(w.opcodes, [[1, 1], [1, 0]])   // set-time then set-user-info
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
}
