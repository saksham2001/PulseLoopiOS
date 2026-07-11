import Foundation

/// Setting-group (`0x01`) keys — `Constants.DATATYPE` low bytes.
enum YCBTSettingKey {
    static let setTime: UInt8 = 0x00              // SettingTime          256
    static let userInfo: UInt8 = 0x03             // SettingUserInfo      259
    static let units: UInt8 = 0x04                // SettingUnit          260
    static let heartMonitor: UInt8 = 0x0c         // SettingHeartMonitor  268
    static let language: UInt8 = 0x12             // SettingLanguage      274
    static let bloodPressureMonitor: UInt8 = 0x1c // SettingBloodPressureMonitor 284
    static let temperatureMonitor: UInt8 = 0x20   // SettingTemperatureMonitor   288
    static let bloodOxygenMonitor: UInt8 = 0x26   // SettingBloodOxygenModeMonitor 294
    static let hrvMonitor: UInt8 = 0x45           // SettingHRVMonitor    325
}

/// Byte builders for the Setting group, shared by every YCBT family. Each returns a *logical* command
/// (`[type, cmd, payload…]`); the driver's `frame(_:)` adds the length field and CRC.
///
/// Every one of these is idempotent and individually ACKed by the ring with a 1-byte status.
struct YCBTSettingsEncoder {
    /// The ring's all-day sampler refuses intervals under 30 minutes (SmartHealth clamps the same way
    /// for rings: `if (isRing() && interval < 30) interval = 30`). The vendor default is 60.
    static let minimumIntervalMinutes = 30
    static let defaultIntervalMinutes = 60

    /// Clamp a user-chosen cadence into what the firmware will actually accept. PulseLoop's shared
    /// `MeasurementSettings` default is 5 minutes (a Colmi cadence), which this floors to 30 rather
    /// than silently letting the ring reject the write.
    static func clampInterval(_ minutes: Int) -> UInt8 {
        guard minutes > 0 else { return UInt8(defaultIntervalMinutes) }
        return UInt8(min(255, max(minimumIntervalMinutes, minutes)))
    }

    // MARK: - Clock

    /// `01 00` + `[year:u16 LE][month][day][hour][min][sec][weekday]`.
    ///
    /// The weekday byte is **Mon=0 … Sun=6** (`TimeUtil.makeBleTime`: `dayOfWeek == 1 ? 6 : dayOfWeek - 2`,
    /// against Gregorian `Calendar` where Sunday == 1). PulseLoop used to hard-code `0x00`, so the ring
    /// believed every day was Monday.
    func setTime(_ date: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let year = UInt16(c.year ?? 2000)
        let gregorianWeekday = c.weekday ?? 1
        let weekday = UInt8(gregorianWeekday == 1 ? 6 : gregorianWeekday - 2)
        return [YCBTGroup.setting, YCBTSettingKey.setTime,
                UInt8(year & 0xff), UInt8((year >> 8) & 0xff),
                UInt8(c.month ?? 1), UInt8(c.day ?? 1),
                UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0),
                weekday]
    }

    // MARK: - Profile / locale

    /// `01 03` + `[heightCm][weightKg][sex][age]`. The ring feeds these into its step, calorie and BP
    /// algorithms, so a wrong profile is a wrong reading — PulseLoop used to replay the capture's
    /// `aa 40 00 2b` blob (170 cm / 64 kg / 43 y) for every user.
    ///
    /// UNVERIFIED: the sex byte's polarity. The SDK never asserts the mapping (`settingUserInfo(…, sex, …)`
    /// passes it straight through) and the capture carries `0x00`; we send 1 for male, 0 otherwise,
    /// which is the vendor convention. A wrong value skews calorie estimates slightly and nothing else.
    func userInfo(_ profile: UserProfileValues) -> [UInt8] {
        [YCBTGroup.setting, YCBTSettingKey.userInfo,
         profile.heightCm, profile.weightKg, profile.gender == 0x01 ? 1 : 0, profile.age]
    }

    /// `01 04` + `[distance][weight][temp][timeFormat][bloodSugar][uricAcid]` — 0 = metric everywhere;
    /// `timeFormat` is 1 for 12-hour, 0 for 24-hour (the SDK sends `!is24Hour`). Blood-sugar and
    /// uric-acid units stay 0 (mmol/L, µmol/L) since PulseLoop displays neither yet.
    func units(metric: Bool, is24Hour: Bool = true) -> [UInt8] {
        let imperial: UInt8 = metric ? 0 : 1
        return [YCBTGroup.setting, YCBTSettingKey.units,
                imperial, imperial, imperial, is24Hour ? 0 : 1, 0, 0]
    }

    /// `01 12` + `[languageCode]` (the vendor's own enum; 0 = English, which is what the capture sent).
    func language(_ code: UInt8 = 0) -> [UInt8] {
        [YCBTGroup.setting, YCBTSettingKey.language, code]
    }

    // MARK: - All-day monitors

    /// The five background samplers, each `{enable, intervalMinutes}`. **These — not the `05 4x` burst
    /// PulseLoop used to send — are what make the ring record anything between syncs.** `05 40…4E` are
    /// the Health *Delete* opcodes.
    ///
    /// `MeasurementSettings` has no blood-pressure flag (no other family has an all-day BP sampler), and
    /// the ring derives BP from the same PPG sweep as heart rate, so BP rides the HR toggle.
    /// `stressEnabled` has no YCBT monitor command — the ring stores stress in the body-data history
    /// record (`05 33`), it doesn't sample it on its own schedule.
    func monitorCommands(_ settings: MeasurementSettings) -> [[UInt8]] {
        let interval = Self.clampInterval(settings.hrIntervalMinutes)
        return [
            heartMonitor(enabled: settings.hrEnabled, intervalMinutes: interval),
            bloodPressureMonitor(enabled: settings.hrEnabled, intervalMinutes: interval),
            temperatureMonitor(enabled: settings.temperatureEnabled, intervalMinutes: interval),
            bloodOxygenMonitor(enabled: settings.spo2Enabled, intervalMinutes: interval),
            hrvMonitor(enabled: settings.hrvEnabled, intervalMinutes: interval),
        ]
    }

    func heartMonitor(enabled: Bool, intervalMinutes: UInt8) -> [UInt8] {
        [YCBTGroup.setting, YCBTSettingKey.heartMonitor, enabled ? 1 : 0, intervalMinutes]
    }

    func bloodPressureMonitor(enabled: Bool, intervalMinutes: UInt8) -> [UInt8] {
        [YCBTGroup.setting, YCBTSettingKey.bloodPressureMonitor, enabled ? 1 : 0, intervalMinutes]
    }

    func temperatureMonitor(enabled: Bool, intervalMinutes: UInt8) -> [UInt8] {
        [YCBTGroup.setting, YCBTSettingKey.temperatureMonitor, enabled ? 1 : 0, intervalMinutes]
    }

    func bloodOxygenMonitor(enabled: Bool, intervalMinutes: UInt8) -> [UInt8] {
        [YCBTGroup.setting, YCBTSettingKey.bloodOxygenMonitor, enabled ? 1 : 0, intervalMinutes]
    }

    /// HRV takes a 5-byte payload (`settingHRVMonitor(a,b,c,d,e)`). Only the first two args are named in
    /// the SDK's own call sites; UNVERIFIED: the trailing three (window / weekday mask / reserved).
    /// Zero-filled — a wrong non-zero guess could arm a schedule we didn't intend, and zeros are what
    /// the SDK's own default call passes.
    func hrvMonitor(enabled: Bool, intervalMinutes: UInt8) -> [UInt8] {
        [YCBTGroup.setting, YCBTSettingKey.hrvMonitor, enabled ? 1 : 0, intervalMinutes, 0, 0, 0]
    }
}
