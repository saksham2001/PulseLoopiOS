import XCTest
@testable import PulseLoop

/// The encoder's byte layouts, each pinned against its `K6_*` vendor struct: the MixInfo binding bundle
/// (property set + order + framing), the clock, the real-time toggles, and the requests. A wrong offset
/// here is a command the ring silently ignores, so the golden assertions are the contract.
@MainActor
final class LuckRingEncoderTests: XCTestCase {
    private let fixedProfile = UserProfileValues(metric: true, sex: "male", age: 30, heightCm: 175, weightKg: 70)
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Struct layouts

    func testUserInfoBytesMatchK6SendUserInfo() {
        // [userId u32 LE][sex][age][height][weight][reserved]; sex is inverted (male → 0).
        let bytes = LuckRingEncoder.userInfoBytes(fixedProfile)
        XCTAssertEqual(bytes, [0, 0, 0, 0, 0, 30, 175, 70, 0])
    }

    func testUserInfoSexInversionAndAgeFloor() {
        let female = UserProfileValues(metric: true, sex: "female", age: 0, heightCm: 160, weightKg: 55)
        let bytes = LuckRingEncoder.userInfoBytes(female)
        XCTAssertEqual(bytes[4], 1, "female → sex byte 1")
        XCTAssertEqual(bytes[5], 20, "age 0 floors to the vendor default of 20")
    }

    func testTimeBytesAreTrueUtcSeconds() {
        let bytes = LuckRingEncoder.timeBytes(date: fixedDate, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(bytes.count, 9)
        XCTAssertEqual(LuckRingBytes.u32(bytes, 0), 1_700_000_000)   // abs seconds (UTC, no wall-clock shift)
        XCTAssertEqual(LuckRingBytes.u32(bytes, 4), 0)              // UTC offset
        XCTAssertEqual(bytes[8], 0)                                 // format byte
    }

    func testGoalBytesMatchK6SendGoal() {
        let bytes = LuckRingEncoder.goalBytes(steps: 8000)
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(LuckRingBytes.u32(bytes, 0), 8000)          // step goal, LE
        XCTAssertEqual(Array(bytes[4...]), [UInt8](repeating: 0, count: 12))   // distance/cal/sleep/duration = 0
    }

    // MARK: MixInfo bundle

    func testStartupBundleHasVendorPropertyOrderAndData() {
        var encoder = LuckRingEncoder()
        let frame = encoder.startupBundle(profile: fixedProfile, goalSteps: 8000, firstPair: true, date: fixedDate)
        XCTAssertEqual(frame.cmdType, .send)
        XCTAssertEqual(frame.dataType, 110)

        let props = LuckRingMixInfoTLV.decode(frame.payload)
        // Exact order of `sendAynInfoDetail()`: 102, 104, 124, 103, 109, 111, 120.
        XCTAssertEqual(props.map(\.type), [102, 104, 124, 103, 109, 111, 120])
        XCTAssertEqual(props[0].data, LuckRingEncoder.userInfoBytes(fixedProfile))
        XCTAssertEqual(props[1].data.count, 9)                      // time
        XCTAssertEqual(props[2].data, [1, 0xFF, 0xFF, 0, 0])        // call-alarm constant
        XCTAssertEqual(props[3].data, [0])                         // language
        XCTAssertEqual(props[4].data, [1])                        // data-switch enables real-time pushes
        XCTAssertEqual(props[5].data, LuckRingEncoder.goalBytes(steps: 8000))
        XCTAssertEqual(props[6].data, [1, 0])                     // first-pair token
    }

    func testStartupBundleClearsPairTokenAfterFirstBind() {
        var encoder = LuckRingEncoder()
        let frame = encoder.startupBundle(profile: fixedProfile, goalSteps: 0, firstPair: false, date: fixedDate)
        let props = LuckRingMixInfoTLV.decode(frame.payload)
        XCTAssertEqual(props.last?.data, [0, 0], "a non-first bind must not re-trigger the pairing animation")
    }

    // MARK: Toggles / requests

    func testRealTimeToggleLayouts() {
        var encoder = LuckRingEncoder()
        assertFrame(encoder.realHeartRate(on: true), .send, 24, [1])
        assertFrame(encoder.realSpO2(on: true), .send, 20, [1, 0, 0, 0, 0])
        assertFrame(encoder.realHRV(on: true), .send, 45, [1])
        assertFrame(encoder.realBloodPressure(on: true), .send, 18, [1, 0, 0, 0, 0, 0])
        assertFrame(encoder.realTemperature(on: true), .send, 46, [1])
        assertFrame(encoder.realHeartRate(on: false), .send, 24, [0])
    }

    func testRequestIsAnEmptyRequestFrame() {
        var encoder = LuckRingEncoder()
        assertFrame(encoder.request(LuckRingDataType.battery), .request, 3, [])
    }

    /// Opcode 128 (`K6_DATA_TYPE_HEART_AUTO_SWITCH`): `[autoHR][hr24h=0][interval min][autoO2][0×4]`.
    /// The firmware default is monitoring *off*, so this frame is what arms background history logging.
    func testAutoMonitoringMatchesK6HeartAutoSwitch() {
        var encoder = LuckRingEncoder()
        let settings = MeasurementSettings(
            hrEnabled: true, hrIntervalMinutes: 30,
            spo2Enabled: true, stressEnabled: false, hrvEnabled: false, temperatureEnabled: false
        )
        assertFrame(encoder.autoMonitoring(settings), .send, 128, [1, 0, 30, 1, 0, 0, 0, 0])
        let off = MeasurementSettings(
            hrEnabled: false, hrIntervalMinutes: 5,
            spo2Enabled: false, stressEnabled: false, hrvEnabled: false, temperatureEnabled: false
        )
        assertFrame(encoder.autoMonitoring(off), .send, 128, [0, 0, 5, 0, 0, 0, 0, 0])
    }

    func testFindDeviceAndUnbind() {
        var encoder = LuckRingEncoder()
        assertFrame(encoder.findDevice(), .send, 11, [1])
        assertFrame(encoder.unbind(), .send, 159, [1])
    }

    func testSequenceCounterIncrementsPerFrame() {
        var encoder = LuckRingEncoder()
        XCTAssertEqual(encoder.realHeartRate(on: true).seq, 0)
        XCTAssertEqual(encoder.realHeartRate(on: false).seq, 1)
        XCTAssertEqual(encoder.request(LuckRingDataType.battery).seq, 2)
    }

    private func assertFrame(
        _ frame: LuckRingFrame, _ cmd: LuckRingCmdType, _ dataType: UInt8, _ payload: [UInt8],
        line: UInt = #line
    ) {
        XCTAssertEqual(frame.cmdType, cmd, line: line)
        XCTAssertEqual(frame.dataType, dataType, line: line)
        XCTAssertEqual(frame.payload, payload, line: line)
    }
}
