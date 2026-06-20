import Foundation

/// Builds Colmi command payloads. Normal commands are returned as *logical* content (the 16-byte
/// framing + checksum is applied by `ColmiDriver.frame`). Big-data requests are returned raw (they
/// are not 16-byte framed and go out on the command characteristic).
///
/// Layouts from `docs/ColmiR02-Protocol.md` / GadgetBridge. `// UNVERIFIED` marks anything not
/// checkable without a physical ring.
struct ColmiEncoder {

    // MARK: Startup / settings

    func phoneName() -> [UInt8] {
        // 04 <clientMajor> <clientMinor> 'P' 'L'  (PulseLoop)
        [ColmiCommandID.phoneName, 0x02, 0x0a, UInt8(ascii: "P"), UInt8(ascii: "L")]
    }

    /// Set date/time. **UNVERIFIED (GadgetBridge-derived):** each decimal field is re-encoded as a
    /// hex literal (BCD-ish), e.g. minute 25 → 0x25. year is `year % 2000`, month is `month` (1-based).
    func setDateTime(date: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func bcd(_ value: Int) -> UInt8 {
            // Interpret the decimal value's digits as hex (matches Byte.parseByte(String(v), 16)).
            UInt8(value % 100 / 10) << 4 | UInt8(value % 10)
        }
        return [
            ColmiCommandID.setDateTime,
            bcd((c.year ?? 2000) % 2000),
            bcd(c.month ?? 1),
            bcd(c.day ?? 1),
            bcd(c.hour ?? 0),
            bcd(c.minute ?? 0),
            bcd(c.second ?? 0),
        ]
    }

    /// User profile. Sensible neutral defaults; PulseLoop can wire real profile values later.
    func userPreferences(metric: Bool = true, gender: UInt8 = 0x02, age: UInt8 = 25, heightCm: UInt8 = 175, weightKg: UInt8 = 70) -> [UInt8] {
        [
            ColmiCommandID.preferences,
            ColmiCommandID.prefWrite,
            0x00,                       // 24h format
            metric ? 0x00 : 0x01,       // distance unit
            gender, age, heightCm, weightKg,
            0x00, 0x00, 0x00,           // systolic, diastolic, hr-warn (unset)
        ]
    }

    func battery() -> [UInt8] { [ColmiCommandID.battery] }

    func readPref(_ command: UInt8) -> [UInt8] { [command, ColmiCommandID.prefRead] }
    /// Enable/disable an all-day measurement pref (SpO2 `0x2c`, stress `0x36`, HRV `0x38`).
    func writePref(_ command: UInt8, enabled: Bool) -> [UInt8] {
        [command, ColmiCommandID.prefWrite, enabled ? 0x01 : 0x00]
    }
    /// Temperature pref has an extra `0x03` byte before the read/write flag.
    func readTempPref() -> [UInt8] { [ColmiCommandID.autoTempPref, 0x03, ColmiCommandID.prefRead] }
    func readGoals() -> [UInt8] { [ColmiCommandID.goals, ColmiCommandID.prefRead] }

    // MARK: Measurements / actions

    /// Manual single HR is a continuous stream: `0x69 01` starts, `0x69 02` stops it.
    func manualHeartRate(enable: Bool = true) -> [UInt8] {
        [ColmiCommandID.manualHeartRate, enable ? 0x01 : 0x02]
    }

    func realtimeHeartRate(enable: Bool) -> [UInt8] {
        [ColmiCommandID.realtimeHeartRate, enable ? 0x01 : 0x02]
    }
    /// Keepalive sent every ~30s while streaming (the ring times out realtime HR after 60s).
    func realtimeHeartRateContinue() -> [UInt8] { [ColmiCommandID.realtimeHeartRate, 0x03] }

    func findDevice() -> [UInt8] { [ColmiCommandID.findDevice, 0x55, 0xAA] }
    func powerOff() -> [UInt8] { [ColmiCommandID.powerOff, 0x01] }
    func factoryReset() -> [UInt8] { [ColmiCommandID.factoryReset, 0x66, 0x66] }

    // MARK: History requests (normal channel)

    /// Activity history for `daysAgo`. Request shape `43 <daysAgo> 0f 00 5f 01` per GadgetBridge.
    func syncActivity(daysAgo: Int) -> [UInt8] {
        [ColmiCommandID.syncActivity, UInt8(clamping: daysAgo), 0x0f, 0x00, 0x5f, 0x01]
    }

    /// HR history from a unix timestamp (seconds), little-endian in bytes 1-4.
    func syncHeartRate(fromUnix seconds: Int) -> [UInt8] {
        let ts = UInt32(truncatingIfNeeded: seconds)
        return [
            ColmiCommandID.syncHeartRate,
            UInt8(ts & 0xff),
            UInt8((ts >> 8) & 0xff),
            UInt8((ts >> 16) & 0xff),
            UInt8((ts >> 24) & 0xff),
        ]
    }

    func syncStress() -> [UInt8] { [ColmiCommandID.syncStress] }

    /// HRV history carries `daysAgo` as a little-endian u32.
    func syncHRV(daysAgo: Int) -> [UInt8] {
        let d = UInt32(clamping: daysAgo)
        return [
            ColmiCommandID.syncHRV,
            UInt8(d & 0xff),
            UInt8((d >> 8) & 0xff),
            UInt8((d >> 16) & 0xff),
            UInt8((d >> 24) & 0xff),
        ]
    }

    // MARK: Big-data requests (raw, sent on the command characteristic)

    func bigDataSpo2() -> Data {
        Data([ColmiCommandID.bigDataV2, ColmiCommandID.bigDataSpo2, 0x01, 0x00, 0xff, 0x00, 0xff])
    }
    func bigDataSleep() -> Data {
        Data([ColmiCommandID.bigDataV2, ColmiCommandID.bigDataSleep, 0x01, 0x00, 0xff, 0x00, 0xff])
    }
    func bigDataTemperature() -> Data {
        Data([ColmiCommandID.bigDataV2, ColmiCommandID.bigDataTemperature, 0x01, 0x00, 0x3e, 0x81, 0x02])
    }
}
