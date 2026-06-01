import Foundation

enum RingUUIDs {
    static let service = "000056ff-0000-1000-8000-00805f9b34fb"
    static let write = "000033f3-0000-1000-8000-00805f9b34fb"
    static let notify = "000033f4-0000-1000-8000-00805f9b34fb"
    static let battery = "00002a19-0000-1000-8000-00805f9b34fb"
}

enum RingCommandID: UInt8 {
    case timeSync = 0x01
    case activityQueryAck = 0x02
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
    case spo2StartStop = 0x23
    case spo2ResultProgress = 0x24
    case heartRateComplete = 0x27
    case spo2Complete = 0x28
    case appIdentifier = 0x48
    case mode = 0x52
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
    case heartRateSample(bpm: Int, timestamp: Date)
    case heartRateComplete(timestamp: Date)
    case spo2Progress(percent: Int?, timestamp: Date)
    case spo2Result(value: Int, timestamp: Date)
    case spo2Complete(timestamp: Date)
    case sleepTimeline(timestamp: Date, stages: [SleepStage])
    case historyMeasurement(kind: MeasurementKind, value: Double, timestamp: Date)
    case battery(percent: Int)
    case status(address: String?)
    case timeSyncAck(timestamp: Date)
    case commandAck(commandId: UInt8)
    case unknown(commandId: UInt8, raw: Data)
    
    var kind: String {
        switch self {
        case .activityUpdate: return "activity"
        case .heartRateSample: return "hr_sample"
        case .heartRateComplete: return "hr_complete"
        case .spo2Progress: return "spo2_progress"
        case .spo2Result: return "spo2_result"
        case .spo2Complete: return "spo2_complete"
        case .sleepTimeline: return "sleep_timeline"
        case .historyMeasurement: return "history_measurement"
        case .battery: return "battery"
        case .status: return "status"
        case .timeSyncAck: return "time_sync_ack"
        case .commandAck: return "command_ack"
        case .unknown: return "unknown"
        }
    }
    
    var confidence: DecodeConfidence {
        switch self {
        case .unknown:
            return .unknown
        case .commandAck, .heartRateComplete, .spo2Complete, .spo2Progress:
            return .partial
        default:
            return .known
        }
    }
    
    var debugJSON: String {
        switch self {
        case let .activityUpdate(_, steps, distanceMeters, calories):
            return #"{"steps":\#(steps),"distance_m":\#(Int(distanceMeters)),"calories":\#(Int(calories))}"#
        case let .heartRateSample(bpm, _):
            return #"{"bpm":\#(bpm)}"#
        case let .spo2Result(value, _):
            return #"{"spo2":\#(value)}"#
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
            let address = bytes.count >= 9 ? bytes[3...8].map { String(format: "%02x", $0) }.joined(separator: ":") : nil
            return .status(address: address)
        case 0x11 where bytes.count >= 20:
            let timestamp = Date(timeIntervalSince1970: TimeInterval(u32le(bytes, 1)))
            let stages = bytes[5..<20].map(stage)
            return .sleepTimeline(timestamp: timestamp, stages: stages)
        case 0x14 where bytes.count >= 6:
            return .heartRateSample(bpm: Int(bytes[5]), timestamp: now)
        case 0x16 where bytes.count >= 9:
            let timestamp = Date(timeIntervalSince1970: TimeInterval(u32le(bytes, bytes[1] == 0xaa ? 3 : 2)))
            let values = bytes.dropFirst(8).filter { $0 > 0 }
            if let first = values.first {
                return .historyMeasurement(kind: .heartRate, value: Double(first), timestamp: timestamp)
            }
            return .commandAck(commandId: packet.commandId)
        case 0x24:
            if bytes.count >= 5, (80...100).contains(bytes[4]) {
                return .spo2Result(value: Int(bytes[4]), timestamp: now)
            }
            return .spo2Progress(percent: nil, timestamp: now)
        case 0x27:
            return .heartRateComplete(timestamp: now)
        case 0x28:
            return .spo2Complete(timestamp: now)
        default:
            return .unknown(commandId: packet.commandId, raw: packet.raw)
        }
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
