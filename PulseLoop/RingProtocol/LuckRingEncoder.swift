import Foundation

/// Builds *logical* LuckRing frames — the connect bundle, the clock, history requests, the real-time
/// toggles, and the device actions. It owns the rolling `seq` counter (the head packet's `[3]`), so each
/// frame it hands out carries the next sequence number; `LuckRingPacketizer` stamps it into the wire
/// bytes.
///
/// The connect bundle is **parameterized**, not a captured replay: it reproduces the exact property set
/// and order of `K6SendDataManager.sendAynInfoDetail()` — the method the vendor app runs on connect —
/// with every field built from the SDK's own struct byte layouts (`K6_SendUserInfo`, `K6_CESyncTime`,
/// `K6_SendGoal`, `K6_MixInfoStruct`). Wire spec: `tasks/luckring-protocol.md` §MixInfo.
struct LuckRingEncoder {
    /// The rolling per-frame sequence. `queue/b.java` writes it to head `[3]` and the ring echoes it in
    /// its ACK; only monotonic-ish uniqueness matters, so a plain wrapping `UInt8` is enough.
    private var seq: UInt8 = 0

    private mutating func nextSeq() -> UInt8 {
        let value = seq
        seq = seq &+ 1
        return value
    }

    private mutating func frame(_ cmdType: LuckRingCmdType, _ dataType: UInt8, _ payload: [UInt8]) -> LuckRingFrame {
        LuckRingFrame(cmdType: cmdType, dataType: dataType, payload: payload, seq: nextSeq())
    }

    // MARK: - Struct byte layouts (each matches its `K6_*` entity exactly)

    /// `K6_SendUserInfo.getBytes()` — 9 bytes: `[userId u32 LE][sex][age][height cm][weight kg][reserved]`.
    ///
    /// **Sex is inverted on the wire.** `sendAynInfoDetail()` sends `(appSex == 1) ? 0 : 1`, where the
    /// app's `1` is male — so the ring's sex byte is `0 = male, 1 = otherwise`. `UserProfileValues.gender`
    /// is `1 = male`, hence `gender == 1 ? 0 : 1`. Age floors at the vendor's default of 20 when unset.
    static func userInfoBytes(_ profile: UserProfileValues, userId: UInt32 = 0) -> [UInt8] {
        var bytes = LuckRingBytes.le32(userId)
        bytes.append(profile.gender == 1 ? 0 : 1)
        bytes.append(profile.age < 1 ? 20 : profile.age)
        bytes.append(profile.heightCm)
        bytes.append(profile.weightKg)
        bytes.append(0)                     // reserved
        return bytes
    }

    /// `K6_CESyncTime.getBytes()` — 9 bytes: `[absSeconds u32 LE][utcOffsetSeconds u32 LE][formatByte]`.
    ///
    /// `absSeconds` is the **true UTC** Unix epoch (`TimeUtil.now()/1000`), not local wall-clock — so
    /// unlike the jring/YCBT clocks, every ring-stamped record decodes with no offset to un-apply
    /// (`TimeUtil.s2CForDev(sec, true) == sec*1000`). The format byte is `(timeDisplay ^ (dateDisplay<<1))`;
    /// both displays default to 0, so it is 0.
    static func timeBytes(date: Date = Date(), timeZone: TimeZone = .current) -> [UInt8] {
        var bytes = LuckRingBytes.le32(UInt32(date.timeIntervalSince1970))
        let offset = UInt32(bitPattern: Int32(timeZone.secondsFromGMT(for: date)))
        bytes.append(contentsOf: LuckRingBytes.le32(offset))
        bytes.append(0)                     // format byte (12/24h ^ date order << 1); both default 0
        return bytes
    }

    /// `K6_SendGoal.getBytes()` — 16 bytes: `[step u32][distance u32][calories u32][sleep u16][duration u16]`,
    /// all LE. PulseLoop only tracks a step goal; the other four are 0.
    static func goalBytes(steps: Int) -> [UInt8] {
        var bytes = LuckRingBytes.le32(UInt32(max(0, steps)))
        bytes.append(contentsOf: LuckRingBytes.le32(0))   // distance
        bytes.append(contentsOf: LuckRingBytes.le32(0))   // calories
        bytes.append(contentsOf: LuckRingBytes.le16(0))   // sleep
        bytes.append(contentsOf: LuckRingBytes.le16(0))   // duration
        return bytes
    }

    // MARK: - Connect bundle (MixInfo 110)

    /// The binding / startup bundle, in `sendAynInfoDetail()`'s exact property order:
    /// 102 user info → 104 time → 124 call-alarm → 103 language → 109 data-switch → 111 goals → 120 pair.
    ///
    /// - `109 data-switch = 1` is what enables the ring's real-time pushes.
    /// - `120 pair = {firstPair ? 1 : 0, 0}`: the leading 1 asks the ring to run its pairing animation and
    ///   is sent only on the very first bind; every later connect sends `{0,0}`, or the ring re-pairs.
    /// - `124 call-alarm = {1, 0xFF, 0xFF, 0, 0}` is the vendor's literal constant.
    mutating func startupBundle(
        profile: UserProfileValues,
        goalSteps: Int,
        firstPair: Bool,
        date: Date = Date(),
        languageCode: UInt8 = 0
    ) -> LuckRingFrame {
        let properties: [LuckRingMixInfoTLV.Property] = [
            .init(type: LuckRingDataType.userInfo, data: Self.userInfoBytes(profile)),
            .init(type: LuckRingDataType.time, data: Self.timeBytes(date: date)),
            .init(type: LuckRingDataType.callAlarm, data: [1, 0xFF, 0xFF, 0, 0]),
            .init(type: LuckRingDataType.language, data: [languageCode]),
            .init(type: LuckRingDataType.dataSwitch, data: [1]),
            .init(type: LuckRingDataType.goals, data: Self.goalBytes(steps: goalSteps)),
            .init(type: LuckRingDataType.pairFinish, data: [firstPair ? 1 : 0, 0]),
        ]
        return frame(.send, LuckRingDataType.mixInfo, LuckRingMixInfoTLV.encode(properties))
    }

    // MARK: - Standalone settings

    /// Push the ring clock on its own (`104`, the live timezone-change path).
    mutating func setTime(date: Date = Date()) -> LuckRingFrame {
        frame(.send, LuckRingDataType.time, Self.timeBytes(date: date))
    }

    /// Push the user's profile on its own (`102`).
    mutating func userInfo(_ profile: UserProfileValues) -> LuckRingFrame {
        frame(.send, LuckRingDataType.userInfo, Self.userInfoBytes(profile))
    }

    /// Set the step goal on its own (`111`).
    mutating func setGoal(steps: Int) -> LuckRingFrame {
        frame(.send, LuckRingDataType.goals, Self.goalBytes(steps: steps))
    }

    /// Enable/disable the real-time push data-switch (`109`).
    mutating func dataSwitch(on: Bool) -> LuckRingFrame {
        frame(.send, LuckRingDataType.dataSwitch, [on ? 1 : 0])
    }

    /// Auto-monitoring config (`128`, `K6_DATA_TYPE_HEART_AUTO_SWITCH` — 8 bytes:
    /// `[autoHR][hr24h][interval min][autoO2][0×4]`). This is what makes the ring log HR/SpO₂ history
    /// **on its own**: the firmware default is *off* (`new K6_DATA_TYPE_HEART_AUTO_SWITCH(0, 0, 30)`),
    /// so a ring that never visited the vendor app's monitoring screen records nothing between syncs
    /// until this is sent. `hr24h` (continuous mode) stays 0, matching the vendor default.
    mutating func autoMonitoring(_ settings: MeasurementSettings) -> LuckRingFrame {
        frame(.send, LuckRingDataType.heartAutoSwitch, [
            settings.hrEnabled ? 1 : 0,
            0,
            UInt8(clamping: settings.hrIntervalMinutes),
            settings.spo2Enabled ? 1 : 0,
            0, 0, 0, 0,
        ])
    }

    // MARK: - Requests (cmdType REQUEST, empty payload)

    /// Ask the ring for a data type: a bare `REQUEST` with no payload (`new CEDevData(3, dataType)`).
    /// Used for device info (2), battery (3), settings-sync (9), and every history stream.
    mutating func request(_ dataType: UInt8) -> LuckRingFrame {
        frame(.request, dataType, [])
    }

    // MARK: - Real-time toggles (each is its own `K6_DATA_TYPE_REAL_*` send)

    /// Real HR toggle (`24`, `K6_DATA_TYPE_REAL_HR` — 1 payload byte). The stream itself comes back on
    /// dataType 7.
    mutating func realHeartRate(on: Bool) -> LuckRingFrame {
        frame(.send, LuckRingDataType.realHR, [on ? 1 : 0])
    }

    /// Real SpO₂ toggle (`20`, `K6_DATA_TYPE_REAL_O2` — `[on,0,0,0,0]`).
    mutating func realSpO2(on: Bool) -> LuckRingFrame {
        frame(.send, LuckRingDataType.realO2, [on ? 1 : 0, 0, 0, 0, 0])
    }

    /// Real HRV toggle (`45`, `K6_DATA_TYPE_REAL_HRV` — 1 payload byte).
    mutating func realHRV(on: Bool) -> LuckRingFrame {
        frame(.send, LuckRingDataType.realHRV, [on ? 1 : 0])
    }

    /// Real blood-pressure toggle (`18`, `K6_DATA_TYPE_REAL_BP` — `[on,0,0,0,0,0]`).
    mutating func realBloodPressure(on: Bool) -> LuckRingFrame {
        frame(.send, LuckRingDataType.realBP, [on ? 1 : 0, 0, 0, 0, 0, 0])
    }

    /// Real temperature toggle (`46`, `K6_DATA_TYPE_REAL_TEMP` — 1 payload byte).
    mutating func realTemperature(on: Bool) -> LuckRingFrame {
        frame(.send, LuckRingDataType.realTemp, [on ? 1 : 0])
    }

    // MARK: - Device actions

    /// Buzz the ring (`11`, `K6_DATA_TYPE_FIND_PHONE_OR_DEVICE` — 1 payload byte).
    mutating func findDevice() -> LuckRingFrame {
        frame(.send, LuckRingDataType.findDevice, [1])
    }

    /// Release the ring on Forget (`159`, `sendUnbind` — 1 payload byte).
    mutating func unbind() -> LuckRingFrame {
        frame(.send, LuckRingDataType.unbind, [1])
    }
}
