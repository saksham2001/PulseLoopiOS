import Foundation

enum RingUUIDs {
    static let service = "000056ff-0000-1000-8000-00805f9b34fb"
    static let write = "000033f3-0000-1000-8000-00805f9b34fb"
    static let notify = "000033f4-0000-1000-8000-00805f9b34fb"
    static let battery = "00002a19-0000-1000-8000-00805f9b34fb"
}

enum RingCommandID: UInt8 {
    case timeSync = 0x01
    /// User profile (age/sex/height/weight). The 0x02 *reply* is a generic ack; the *command* sets
    /// the on-device profile that drives the ring's blood-sugar/calorie algorithms.
    case userInfo = 0x02
    case currentActivity = 0x03
    case findRingCandidate = 0x04
    case percentStatus = 0x0b
    case status = 0x0c
    case historySummary = 0x10
    case sleepTimeline = 0x11
    case activitySummary = 0x13
    case heartRateSampleOrStart = 0x14
    case heartRateStop = 0x15
    case historyMeasurementStream = 0x16
    case goalOrConfig = 0x1a
    case deviceTimeOrConfig = 0x20
    case locale = 0x21
    case combinedStartStop = 0x23
    /// Combined sensor result: HR + systolic + diastolic + SpO₂ + fatigue + stress + blood sugar +
    /// HRV in one 9-byte payload (per the APK decompile's `onReceiveSensorData`). iOS previously
    /// mislabelled this `spo2ResultProgress`.
    case combinedResult = 0x24
    case heartRateComplete = 0x27
    /// Blood-data notify (measurement-complete marker). iOS previously mislabelled this `spo2Complete`.
    case bloodDataNotify = 0x28
    /// Blood-pressure calibration: pushes a reference cuff systolic/diastolic so the ring applies an
    /// on-device offset.
    case bpAdjust = 0x33
    /// Keepalive ping — prevents the ring's ~20s idle disconnect.
    case keepalive = 0x3a
    case spo2Toggle = 0x3e
    case spo2Result = 0x3f
    case appIdentifier = 0x48
    /// Bind/unbind handshake (ring-driven claim + app-driven release on Forget).
    case bind = 0x4b
    case mode = 0x52
    /// Firmware version notify (alternate to the 0x0c status payload).
    case firmware = 0xf6
}

enum RingProtocolError: Error {
    case invalidLength(Int)
    case invalidHex(String)
}

struct RingPacket {
    let commandId: UInt8
    let payload: [UInt8]
    let raw: Data

    init(data: Data) throws {
        guard data.count == 20 else {
            throw RingProtocolError.invalidLength(data.count)
        }
        self.raw = data
        self.commandId = data[0]
        self.payload = Array(data.dropFirst())
    }
}

enum RingDecodedEvent: Sendable {
    case activityUpdate(timestamp: Date, steps: Int, distanceMeters: Double, calories: Double)
    /// One intraday activity bucket (e.g. a Colmi quarter-hour history sample). Unlike the cumulative
    /// `activityUpdate`, buckets are *summed* into the day — so live vs. history aggregate correctly.
    /// Calories are intentionally omitted (the ring's calorie field is unverified).
    case activityBucket(timestamp: Date, steps: Int, distanceMeters: Double)
    case heartRateSample(bpm: Int, timestamp: Date)
    case heartRateComplete(timestamp: Date)
    case spo2Progress(percent: Int?, timestamp: Date)
    case spo2Result(value: Int, timestamp: Date)
    case spo2Complete(timestamp: Date)
    case sleepTimeline(timestamp: Date, stages: [SleepStage])
    case historyMeasurement(kind: MeasurementKind, value: Double, timestamp: Date)
    case stressSample(value: Int, timestamp: Date)
    case hrvSample(value: Int, timestamp: Date)            // milliseconds
    case temperatureSample(celsius: Double, timestamp: Date)
    // Extra metrics carried in the 0x24 combined-sensor packet (jring/56ff).
    case bloodPressureSample(systolic: Int, diastolic: Int, timestamp: Date)
    case fatigueSample(value: Int, timestamp: Date)        // 0–100 scale
    case bloodSugarSample(mgdl: Double, timestamp: Date)
    case historySyncProgress(stage: String)
    case historySyncFinished
    case battery(percent: Int)
    case status(address: String?)
    /// Firmware version string parsed from the 0x0c status / 0xf6 firmware payload.
    case firmware(version: String)
    /// Ring bind/unbind handshake frame (0x4B): `action`/`state` per the protocol state machine.
    case bind(action: UInt8, state: UInt8)
    case timeSyncAck(timestamp: Date)
    case commandAck(commandId: UInt8)
    case unknown(commandId: UInt8, raw: Data)

    var kind: String {
        switch self {
        case .activityUpdate: return "activity"
        case .activityBucket: return "activity_bucket"
        case .heartRateSample: return "hr_sample"
        case .heartRateComplete: return "hr_complete"
        case .spo2Progress: return "spo2_progress"
        case .spo2Result: return "spo2_result"
        case .spo2Complete: return "spo2_complete"
        case .sleepTimeline: return "sleep_timeline"
        case .historyMeasurement: return "history_measurement"
        case .stressSample: return "stress_sample"
        case .hrvSample: return "hrv_sample"
        case .temperatureSample: return "temperature_sample"
        case .bloodPressureSample: return "blood_pressure_sample"
        case .fatigueSample: return "fatigue_sample"
        case .bloodSugarSample: return "blood_sugar_sample"
        case .historySyncProgress: return "history_sync_progress"
        case .historySyncFinished: return "history_sync_finished"
        case .battery: return "battery"
        case .status: return "status"
        case .firmware: return "firmware"
        case .bind: return "bind"
        case .timeSyncAck: return "time_sync_ack"
        case .commandAck: return "command_ack"
        case .unknown: return "unknown"
        }
    }

    var confidence: DecodeConfidence {
        switch self {
        case .unknown:
            return .unknown
        case .commandAck, .heartRateComplete, .spo2Complete, .spo2Progress, .bind, .firmware:
            return .partial
        default:
            return .known
        }
    }

    var debugJSON: String {
        switch self {
        case let .activityUpdate(_, steps, distanceMeters, calories):
            return #"{"steps":\#(steps),"distance_m":\#(Int(distanceMeters)),"calories":\#(Int(calories))}"#
        case let .activityBucket(_, steps, distanceMeters):
            return #"{"steps":\#(steps),"distance_m":\#(Int(distanceMeters))}"#
        case let .heartRateSample(bpm, _):
            return #"{"bpm":\#(bpm)}"#
        case let .spo2Result(value, _):
            return #"{"spo2":\#(value)}"#
        case let .stressSample(value, _):
            return #"{"stress":\#(value)}"#
        case let .hrvSample(value, _):
            return #"{"hrv_ms":\#(value)}"#
        case let .temperatureSample(celsius, _):
            return #"{"temp_c":\#(celsius)}"#
        case let .bloodPressureSample(systolic, diastolic, _):
            return #"{"systolic":\#(systolic),"diastolic":\#(diastolic)}"#
        case let .fatigueSample(value, _):
            return #"{"fatigue":\#(value)}"#
        case let .bloodSugarSample(mgdl, _):
            return #"{"glucose_mgdl":\#(Int(mgdl))}"#
        case let .firmware(version):
            return #"{"firmware":"\#(version)"}"#
        case let .bind(action, state):
            return #"{"bind_action":\#(action),"bind_state":\#(state)}"#
        case let .historySyncProgress(stage):
            return #"{"stage":"\#(stage)"}"#
        case let .battery(percent):
            return #"{"percent":\#(percent)}"#
        case let .status(address):
            return #"{"address":"\#(address ?? "")"}"#
        default:
            return #"{}"#
        }
    }
}

struct RingDecoder {
    /// Decode one inbound frame into *all* the events it carries. Most frames decode to a single
    /// event; the `0x24` combined-sensor packet fans out into several (HR, BP, SpO₂, fatigue, stress,
    /// blood sugar, HRV). `JringDriver.ingest` calls this.
    func decodeAll(_ data: Data) -> [RingDecodedEvent] {
        guard let packet = try? RingPacket(data: data) else {
            return [.unknown(commandId: data.first ?? 0, raw: data)]
        }
        let bytes = [UInt8](packet.raw)
        if packet.commandId == 0x24 {
            return decodeCombined(bytes, now: Date())
        }
        // 0x16 history "data" blocks (sub-type 0xA0) carry 12 one-minute HR samples → two 6-sample
        // averages 60s apart. Fan those out; all other 0x16 sub-types fall through to `decode`.
        if packet.commandId == 0x16, bytes.count >= 20, bytes[1] == 0xa0 {
            return decodeHistoryHeartRate(bytes)
        }
        // The 0x0c status payload carries both the embedded address and the firmware string; emit both.
        if packet.commandId == 0x0c, bytes.count >= 13 {
            return [decode(data), .firmware(version: firmwareString(bytes))]
        }
        return [decode(data)]
    }

    /// Decode a 0x16 `0xA0` data block: base timestamp at [2..5] (LE u32), then two consecutive
    /// blocks of six 1-minute HR samples at [8..13] and [14..19]. Each block is averaged into one
    /// reading, the second timestamped 60s after the first. Mirrors the Android multi-packet routing.
    private func decodeHistoryHeartRate(_ bytes: [UInt8]) -> [RingDecodedEvent] {
        let base = TimeInterval(u32le(bytes, 2))
        func average(_ slice: ArraySlice<UInt8>) -> Int? {
            let valid = slice.map { Int($0) }.filter { $0 > 0 }
            guard !valid.isEmpty else { return nil }
            return Int((Double(valid.reduce(0, +)) / Double(valid.count)).rounded())
        }
        var events: [RingDecodedEvent] = []
        if let avg = average(bytes[8..<14]) {
            events.append(.historyMeasurement(kind: .heartRate, value: Double(avg),
                                               timestamp: Date(timeIntervalSince1970: base)))
        }
        if let avg = average(bytes[14..<20]) {
            events.append(.historyMeasurement(kind: .heartRate, value: Double(avg),
                                               timestamp: Date(timeIntervalSince1970: base + 60)))
        }
        return events.isEmpty ? [.commandAck(commandId: 0x16)] : events
    }

    /// Decode the 9-byte `0x24` combined-sensor payload into one event per valid metric. Byte map
    /// (matching the official Jring app's `onReceiveSensorData`): [1]=HR, [2]=systolic, [3]=diastolic,
    /// [4]=SpO₂, [5]=fatigue, [6]=stress, [7]=blood sugar (mmol/L×10), [8]=HRV (ms).
    private func decodeCombined(_ bytes: [UInt8], now: Date) -> [RingDecodedEvent] {
        guard bytes.count >= 9 else { return [.commandAck(commandId: 0x24)] }
        var events: [RingDecodedEvent] = []
        let hr = Int(bytes[1])
        if hr > 0 { events.append(.heartRateSample(bpm: hr, timestamp: now)) }
        let systolic = Int(bytes[2]), diastolic = Int(bytes[3])
        if systolic > 0, diastolic > 0 {
            events.append(.bloodPressureSample(systolic: systolic, diastolic: diastolic, timestamp: now))
        }
        if (80...100).contains(bytes[4]) {
            events.append(.spo2Result(value: Int(bytes[4]), timestamp: now))
        }
        if bytes[5] > 0 { events.append(.fatigueSample(value: Int(bytes[5]), timestamp: now)) }
        if bytes[6] > 0 { events.append(.stressSample(value: Int(bytes[6]), timestamp: now)) }
        if bytes[7] > 0 {
            // Ring reports mmol/L×10; convert to the mg/dL the rest of the app displays.
            let mgdl = (Double(bytes[7]) / 10.0) * 18.016
            events.append(.bloodSugarSample(mgdl: mgdl, timestamp: now))
        }
        if bytes[8] > 0 { events.append(.hrvSample(value: Int(bytes[8]), timestamp: now)) }
        // A genuinely empty packet (warm-up) still needs to advance the write queue downstream.
        return events.isEmpty ? [.commandAck(commandId: 0x24)] : events
    }

    func decode(_ data: Data) -> RingDecodedEvent {
        guard let packet = try? RingPacket(data: data) else {
            return .unknown(commandId: data.first ?? 0, raw: data)
        }

        let bytes = [UInt8](packet.raw)
        let now = Date()

        switch packet.commandId {
        case 0x01 where bytes.count >= 6:
            return .timeSyncAck(timestamp: Date(timeIntervalSince1970: TimeInterval(u32le(bytes, 1))))
        case 0x02:
            return .commandAck(commandId: packet.commandId)
        case 0x03 where bytes.count >= 17:
            let timestamp = Date(timeIntervalSince1970: TimeInterval(u32le(bytes, 1)))
            let steps = Int(u32le(bytes, 5))
            let distance = Double(u32le(bytes, 9))
            let calories = Double(u32le(bytes, 13))
            return .activityUpdate(timestamp: timestamp, steps: steps, distanceMeters: distance, calories: calories)
        case 0x0b where bytes.count >= 2:
            return .battery(percent: Int(bytes[1]))
        case 0x0c:
            // The 0x0c payload also carries firmware (version/cid/did); that's fanned out separately
            // in `decodeAll`. Here we surface just the embedded address (re-asserts connected state).
            let address = bytes.count >= 9 ? bytes[3...8].map { String(format: "%02x", $0) }.joined(separator: ":") : nil
            return .status(address: address)
        case 0x11 where bytes.count >= 20:
            let timestamp = Date(timeIntervalSince1970: TimeInterval(u32le(bytes, 1)))
            let stages = bytes[5..<20].map(stage)
            return .sleepTimeline(timestamp: timestamp, stages: stages)
        case 0x14 where bytes.count >= 6:
            return .heartRateSample(bpm: Int(bytes[5]), timestamp: now)
        case 0x16:
            // Header (0xF0) carries the total packet count; index (0xAA) / finished (0xFF) are
            // sync-flow markers. Data blocks (0xA0) are handled in `decodeAll`. None decode to a
            // measurement on their own, so they're plain acks here.
            return .commandAck(commandId: packet.commandId)
        case 0x24:
            // Combined-sensor packet: `decodeAll` fans out every metric; a single-event caller just
            // gets the first (HR) for backwards compatibility.
            return decodeCombined(bytes, now: now).first ?? .commandAck(commandId: packet.commandId)
        case 0x27:
            return .heartRateComplete(timestamp: now)
        case 0x28:
            // Blood-data notify: a measurement-complete marker. Keep emitting `spo2Complete` so the
            // existing "measurement finished" consumers still fire.
            return .spo2Complete(timestamp: now)
        case 0x3f where bytes.count >= 2 && (80...100).contains(bytes[1]):
            // Dedicated SpO₂ result command (separate from the combined packet).
            return .spo2Result(value: Int(bytes[1]), timestamp: now)
        case 0x4b where bytes.count >= 3:
            return .bind(action: bytes[1], state: bytes[2])
        case 0xf6 where bytes.count >= 6:
            // Alternate firmware notify: version at [4..5] (LE u16).
            let version = Int(bytes[4]) | (Int(bytes[5]) << 8)
            return .firmware(version: "V\(version)")
        default:
            return .unknown(commandId: packet.commandId, raw: packet.raw)
        }
    }

    /// Build the firmware string from a 0x0c status payload: `"%04X%04XV%d"` of cid, did, version.
    private func firmwareString(_ bytes: [UInt8]) -> String {
        let version = Int(bytes[1]) | (Int(bytes[2]) << 8)
        let cid = Int(bytes[9]) | (Int(bytes[10]) << 8)
        let did = Int(bytes[11]) | (Int(bytes[12]) << 8)
        return String(format: "%04X%04XV%d", cid, did, version)
    }

    private func u32le(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard bytes.count >= offset + 4 else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private func stage(_ byte: UInt8) -> SleepStage {
        switch byte {
        case 0x28: return .light
        case 0x63: return .deep
        case 0x00: return .awake
        default: return .unknown
        }
    }
}

struct RingEncoder {
    func makeStatusCommand() -> Data { data(hex: "0c00000000000000000000000000000000000000") }
    func makeLocaleCommand(locale: String = "en-US") -> Data { data(hex: "21656e2d55530000000000000000000000000000") }
    func makeActivityQueryCommand() -> Data { data(hex: "0299b85a00000000000000000000000000000000") }
    func makeHistoryQueryCommand() -> Data { data(hex: "1000000000000000000000000000000000000000") }
    func makeHistoryMeasurementQueryCommand() -> Data { data(hex: "1600000000000000000000000000000000000000") }
    func makeHeartRateStartCommand() -> Data { data(hex: "14b4000000000000000000000000000000000000") }
    func makeHeartRateStopCommand() -> Data { data(hex: "1500000000000000000000000000000000000000") }
    func makeSpO2StartCommand() -> Data { data(hex: "2301000000000000000000000000000000000000") }
    func makeSpO2StopCommand() -> Data { data(hex: "2300000000000000000000000000000000000000") }
    func makeFindRingCommand() -> Data { data(hex: "040a000000000000000000000000000000000000") }

    /// Daily step goal command (0x1a) — opcode + u32 little-endian goal value, zero-padded.
    /// Protocol.md: `1a 10 27 00 00 …` sets a 10000-step goal.
    func makeGoalCommand(steps: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x1a
        let value = UInt32(max(0, steps))
        bytes[1] = UInt8(value & 0xff)
        bytes[2] = UInt8((value >> 8) & 0xff)
        bytes[3] = UInt8((value >> 16) & 0xff)
        bytes[4] = UInt8((value >> 24) & 0xff)
        return Data(bytes)
    }

    /// Automatic background heart-rate schedule (0x19). Protocol.md:
    /// `19 00 00 17 3b <enable> <cadenceMin> 02 …` — window 00:00–23:59, enable flag, cadence in
    /// minutes, mode 0x02. Used to restore the ring's normal background cadence after a workout's
    /// live HR stream is stopped.
    func makeAutomaticHeartRateCommand(enabled: Bool, cadenceMinutes: Int = 30) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x19
        bytes[1] = 0x00          // start HH
        bytes[2] = 0x00          // start MM
        bytes[3] = 0x17          // end HH (23)
        bytes[4] = 0x3b          // end MM (59)
        bytes[5] = enabled ? 0x01 : 0x00
        bytes[6] = UInt8(clamping: max(1, cadenceMinutes))
        bytes[7] = 0x02
        return Data(bytes)
    }

    /// User profile (0x02). The ring uses age/sex/height/weight for its blood-sugar/calorie
    /// algorithms. Byte layout (matching the Android encoder): `[1]=(age & 0x7F)|(male?0x80:0)`,
    /// `[2]=heightCm`, `[3]=weightKg`, `[4]=0x00` (metric flag, always metric on the wire).
    func makeUserInfoCommand(age: Int, isMale: Bool, heightCm: Int, weightKg: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x02
        bytes[1] = UInt8(max(0, min(127, age))) | (isMale ? 0x80 : 0x00)
        bytes[2] = UInt8(clamping: heightCm)
        bytes[3] = UInt8(clamping: weightKg)
        bytes[4] = 0x00
        return Data(bytes)
    }

    /// Blood-pressure calibration (0x33): reference cuff systolic/diastolic as little-endian u16s, so
    /// the ring applies an on-device offset. `[1..2]=systolic`, `[3..4]=diastolic`.
    func makeBPAdjustCommand(systolic: Int, diastolic: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x33
        let sys = UInt16(max(0, min(65535, systolic)))
        let dia = UInt16(max(0, min(65535, diastolic)))
        bytes[1] = UInt8(sys & 0xff)
        bytes[2] = UInt8((sys >> 8) & 0xff)
        bytes[3] = UInt8(dia & 0xff)
        bytes[4] = UInt8((dia >> 8) & 0xff)
        return Data(bytes)
    }

    /// App identity (0x48): claims the ring with a persistent app ID so it streams data to PulseLoop
    /// (prevents the mute behaviour after another app claimed the ring). Up to 18 ASCII bytes.
    func makeAppIdentifierCommand(appId: String = "PulseLoop") -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x48
        let ascii = Array(appId.utf8.prefix(18))
        for (i, byte) in ascii.enumerated() { bytes[1 + i] = byte }
        return Data(bytes)
    }

    /// Keepalive ping (0x3A) — sent on an interval to prevent the ring's ~20s idle disconnect.
    func makeKeepaliveCommand() -> Data { data(hex: "3a00000000000000000000000000000000000000") }

    /// Bind/unbind handshake frame (0x4B). `[1]=action`, `[2]=state` (0), `[3]=type` (always 1).
    /// Actions: 0 INIT, 1 APP_START, 2 ACK, 3 ACK_CANCEL, 4 SUCCESS, 5 UNBOND, 6 UNBOND_ACK.
    func makeBindCommand(action: UInt8, state: UInt8 = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x4b
        bytes[1] = action
        bytes[2] = state
        bytes[3] = 0x01
        return Data(bytes)
    }

    func makeTimeSyncCommand(date: Date = Date()) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x01
        let ts = UInt32(date.timeIntervalSince1970)
        bytes[1] = UInt8(ts & 0xff)
        bytes[2] = UInt8((ts >> 8) & 0xff)
        bytes[3] = UInt8((ts >> 16) & 0xff)
        bytes[4] = UInt8((ts >> 24) & 0xff)
        bytes[5] = UInt8(bitPattern: Int8(TimeZone.current.secondsFromGMT(for: date) / 3600))
        return Data(bytes)
    }

    private func data(hex: String) -> Data {
        (try? Data(hexString: hex)) ?? Data()
    }
}

extension Data {
    init(hexString: String) throws {
        let clean = hexString.replacingOccurrences(of: " ", with: "")
        guard clean.count.isMultiple(of: 2) else { throw RingProtocolError.invalidHex(hexString) }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                throw RingProtocolError.invalidHex(hexString)
            }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
