import Foundation
@preconcurrency import CoreBluetooth

/// TK5 driver. Owns the length-prefixed CRC16 framing and the split-channel topology: the command
/// characteristic `be940001` is *both* the write target and a notify source (command replies), while
/// `be940003` carries the async live/history stream. The standard `180D`/`2A37` Heart Rate
/// characteristic is also subscribed as an auth-independent fallback live-HR source.
///
/// Because `be940001` is simultaneously the write and a notify characteristic, `RingBLEClient`'s
/// discovery subscribes any `notifyUUIDs` entry even when it also matches `writeUUID`.
@MainActor
final class TK5Driver: WearableDriver {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let decoder = TK5Decoder()

    private let streamUUID = CBUUID(string: TK5UUIDs.stream)
    private let hrMeasurementUUID = CBUUID(string: TK5UUIDs.heartRateMeasurement)

    init(writer: RingCommandWriter) {
        self.writer = writer
    }

    // MARK: BLE topology
    let serviceUUIDs: [CBUUID] = [CBUUID(string: TK5UUIDs.service), CBUUID(string: TK5UUIDs.heartRateService)]
    let writeUUID = CBUUID(string: TK5UUIDs.command)
    let notifyUUIDs: [CBUUID] = [
        CBUUID(string: TK5UUIDs.command),   // command replies (also the write char)
        CBUUID(string: TK5UUIDs.stream),    // async live + history stream
        CBUUID(string: TK5UUIDs.heartRateMeasurement),  // standard-BLE fallback HR
    ]
    let batteryServiceUUID: CBUUID? = nil   // battery is in-band (0x02 0x00 status, payload[5])
    let batteryCharUUID: CBUUID? = nil

    // MARK: Framing
    func frame(_ command: Data) -> Data {
        // Logical command is `[type, cmd, payload…]`; insert the total-length field and append CRC16.
        TK5Frame.frame([UInt8](command))
    }

    // MARK: Inbound decode
    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        if characteristic == hrMeasurementUUID {
            return decodeStandardHeartRate(data)
        }
        guard let frame = TK5Frame(validating: data) else {
            return [.unknown(commandId: data.first ?? 0, raw: data)]
        }
        return decoder.decode(frame)
    }

    /// Decode a standard BLE Heart Rate Measurement (`2A37`): flags byte, then 8- or 16-bit bpm per
    /// the format bit. Auth-independent, so it works regardless of the proprietary stream's state.
    private func decodeStandardHeartRate(_ data: Data) -> [RingDecodedEvent] {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return [] }
        let is16Bit = (bytes[0] & 0x01) != 0
        let bpm = is16Bit ? (bytes.count >= 3 ? Int(bytes[1]) | (Int(bytes[2]) << 8) : 0) : Int(bytes[1])
        guard bpm > 0 else { return [] }
        return [.heartRateSample(bpm: bpm, timestamp: Date())]
    }

    func makeSyncEngine() -> RingSyncEngine {
        TK5SyncEngine(writer: writer)
    }
}
