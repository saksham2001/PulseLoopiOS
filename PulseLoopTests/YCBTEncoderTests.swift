import XCTest
@testable import PulseLoop

/// Outbound byte correctness for the connect handshake. Two of these guard against frames that are
/// actively harmful: `05 40…4E` are the Health **Delete** opcodes (the old "enable monitoring" burst),
/// and `02 24/26/28` are GetCardInfo/GetSleepStatus/GetMeasurementFunction (the old "history" paging).
final class YCBTEncoderTests: XCTestCase {
    private let encoder = YCBTEncoder()

    private func gregorian(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: iso)!
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: setTime

    /// The weekday byte is Mon=0 … Sun=6. PulseLoop used to send a literal `0x00`, so the ring believed
    /// every day was Monday. 2026-07-06 is a Monday, so the capture's `…0e 00` still holds.
    func testSetTimeWeekdayByteIsCorrectForEveryDay() {
        // Mon 2026-07-06 → 0 … Sun 2026-07-12 → 6.
        for (offset, expected) in (0...6).map({ ($0, UInt8($0)) }) {
            let date = gregorian("2026-07-06 12:34:14").addingTimeInterval(TimeInterval(offset) * 86_400)
            let command = encoder.setTime(date, calendar: utcCalendar)
            XCTAssertEqual(command.last, expected, "weekday byte for day +\(offset)")
        }
    }

    func testSetTimeMatchesTheCapturedFrame() {
        let command = encoder.setTime(gregorian("2026-07-06 12:34:14"), calendar: utcCalendar)
        // 01 00 | year 2026 LE | 07 | 06 | 0c | 22 | 0e | weekday 0 (Monday)
        XCTAssertEqual(command, [0x01, 0x00, 0xea, 0x07, 0x07, 0x06, 0x0c, 0x22, 0x0e, 0x00])
    }

    // MARK: Monitors

    /// The five real monitor enables, each `{enable, intervalMinutes}`. The ring's firmware refuses an
    /// interval below 30 minutes, and PulseLoop's shared default is 5 (a Colmi cadence) — so it must be
    /// floored, not passed through.
    func testMonitorCommandsClampTheIntervalToThirtyMinutes() {
        let settings = MeasurementSettings(
            hrEnabled: true, hrIntervalMinutes: 5,
            spo2Enabled: true, stressEnabled: true, hrvEnabled: true, temperatureEnabled: true
        )
        XCTAssertEqual(encoder.monitorCommands(settings), [
            [0x01, 0x0c, 0x01, 30],            // heart rate
            [0x01, 0x1c, 0x01, 30],            // blood pressure (rides the HR toggle — same PPG sweep)
            [0x01, 0x20, 0x01, 30],            // temperature
            [0x01, 0x26, 0x01, 30],            // SpO₂
            [0x01, 0x45, 0x01, 30, 0, 0, 0],   // HRV — 5-byte payload, tail UNVERIFIED, zero-filled
        ])
    }

    func testMonitorCommandsHonourAnIntervalAboveTheFloorAndTheDisabledFlags() {
        let settings = MeasurementSettings(
            hrEnabled: true, hrIntervalMinutes: 60,
            spo2Enabled: false, stressEnabled: false, hrvEnabled: false, temperatureEnabled: false
        )
        XCTAssertEqual(encoder.monitorCommands(settings), [
            [0x01, 0x0c, 0x01, 60],
            [0x01, 0x1c, 0x01, 60],
            [0x01, 0x20, 0x00, 60],
            [0x01, 0x26, 0x00, 60],
            [0x01, 0x45, 0x00, 60, 0, 0, 0],
        ])
    }

    // MARK: User profile

    /// The old encoder replayed the capture's `01 03 aa 40 00 2b` blob — 170 cm / 64 kg / 43 y — for
    /// every user, which skews the ring's own calorie and BP algorithms.
    func testUserInfoCarriesTheRealProfile() {
        let profile = UserProfileValues(metric: true, sex: "male", age: 31, heightCm: 183, weightKg: 78)
        XCTAssertEqual(encoder.userInfo(profile), [0x01, 0x03, 183, 78, 1, 31])

        let female = UserProfileValues(metric: false, sex: "female", age: 29, heightCm: 165, weightKg: 60)
        XCTAssertEqual(encoder.userInfo(female), [0x01, 0x03, 165, 60, 0, 29])
    }

    // MARK: Startup handshake

    func testStartupSendsNoHealthDeleteOrRetiredGetOpcodes() {
        let sequence = encoder.startupSequence()

        for command in sequence {
            let group = command[0]
            let cmd = command[1]
            XCTAssertFalse(group == 0x05 && (0x40...0x4e).contains(cmd),
                           "05 \(String(cmd, radix: 16)) is a Health-DELETE opcode — never send it")
            XCTAssertFalse(group == 0x05,
                           "the handshake must not touch the Health group at all; the transfer machine owns it")
            XCTAssertFalse(group == 0x02 && [0x24, 0x26, 0x28].contains(cmd),
                           "02 \(String(cmd, radix: 16)) is GetCardInfo/GetSleepStatus/GetMeasurementFunction, not history")
        }
    }

    /// Order matters: the SmartHealth app interrogates the device before it writes settings, and the
    /// live-status push is last (`03 09 01 00 02` — without it the ring never streams `06 00` and live
    /// steps freeze).
    func testStartupOrderMirrorsTheSmartHealthHandshake() {
        let sequence = encoder.startupSequence().map { Array($0.prefix(2)) }

        XCTAssertEqual(sequence.first, [0x01, 0x00], "the clock goes first")
        XCTAssertEqual(sequence.last, [0x03, 0x09], "the live-status push goes last")
        XCTAssertEqual(Array(sequence[1...5]), [
            [0x02, 0x00],   // GetDeviceInfo — battery + firmware
            [0x02, 0x01],   // GetSupportFunction — capability bitmap
            [0x02, 0x1b],   // GetChipScheme
            [0x02, 0x03],   // GetDeviceName
            [0x02, 0x07],   // GetUserConfig
        ])
        XCTAssertEqual(encoder.startupSequence().last, [0x03, 0x09, 0x01, 0x00, 0x02])

        // Settings follow the interrogation: language, units, the five monitors, then the profile.
        XCTAssertEqual(Array(sequence[6...]), [
            [0x01, 0x12], [0x01, 0x04],
            [0x01, 0x0c], [0x01, 0x1c], [0x01, 0x20], [0x01, 0x26], [0x01, 0x45],
            [0x01, 0x03],
            [0x03, 0x09],
        ])
    }

    // MARK: History commands

    func testHistoryRequestAndBlockAckBytes() {
        XCTAssertEqual(encoder.healthHistoryRequest(.heart), [0x05, 0x06])
        XCTAssertEqual(encoder.healthHistoryRequest(.all), [0x05, 0x09])
        XCTAssertEqual(encoder.healthHistoryRequest(.sleep), [0x05, 0x04])
        XCTAssertEqual(encoder.historyBlockAck(status: 0x00), [0x05, 0x80, 0x00])
        XCTAssertEqual(encoder.historyBlockAck(status: 0x04), [0x05, 0x80, 0x04])
    }

    // MARK: Live measurement

    func testLiveMeasurementModesUseDistinctSensors() {
        // The 03 2f payload's mode byte selects the sensor/LED; each metric must use its own.
        XCTAssertEqual(encoder.heartRateStart(), [0x03, 0x2f, 0x01, 0x00])       // HR (green)
        XCTAssertEqual(encoder.bloodPressureStart(), [0x03, 0x2f, 0x01, 0x01])   // BP
        XCTAssertEqual(encoder.spo2Start(), [0x03, 0x2f, 0x01, 0x02])            // SpO₂ (red/IR)
        XCTAssertEqual(encoder.hrvStart(), [0x03, 0x2f, 0x01, 0x0a])             // HRV
    }

    /// The stop **echoes the mode it started** — it is not a mode-agnostic `{00, 00}`. Every SmartHealth
    /// measure screen passes its own `getType()` to `appStartMeasurement(enable, type)` in both
    /// directions; the capture's `03 2f 00 00` was just the HR screen's stop. Sending mode 0 to stop an
    /// SpO₂ sweep was telling the ring to stop *heart rate*.
    func testLiveMeasurementStopEchoesItsOwnMode() {
        XCTAssertEqual(encoder.heartRateStop(), [0x03, 0x2f, 0x00, 0x00])
        XCTAssertEqual(encoder.bloodPressureStop(), [0x03, 0x2f, 0x00, 0x01])
        XCTAssertEqual(encoder.spo2Stop(), [0x03, 0x2f, 0x00, 0x02])
        XCTAssertEqual(encoder.hrvStop(), [0x03, 0x2f, 0x00, 0x0a])
    }

    // MARK: Find device

    /// The real find-device is AppControl `03 00` (`CMD.KEY_AppControl.FindDevice == 0`) with the exact
    /// payload SmartHealth's own button sends (`appFindDevice(1, 5, 2)`). The old `04 0e 00` was not a
    /// command at all — group 4 is the *device→app* push channel and key `0x0e` is `MeasurementResult`,
    /// so the capture was showing SmartHealth **ACKing a push**, which `YCBTDriver` now does for itself.
    func testFindDeviceUsesAppControlNotADevControlAck() {
        XCTAssertEqual(encoder.findDevice(), [0x03, 0x00, 0x01, 0x05, 0x02])
        XCTAssertNotEqual(encoder.findDevice()[0], 0x04, "group 4 is device→app; the app never initiates one")
    }
}
