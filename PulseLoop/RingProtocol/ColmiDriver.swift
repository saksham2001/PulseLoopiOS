import Foundation
@preconcurrency import CoreBluetooth

/// Colmi R02 driver. Owns the 16-byte checksum framing, the two notify channels (V1 normal + V2
/// big-data), and the multi-packet big-data reassembly buffer. History frames (HR/stress/HRV/
/// activity) are routed to the `ColmiSyncEngine`, which knows the current sync-day and advances the
/// response-driven state machine; everything else (realtime HR, notifications, reassembled big-data)
/// is decoded directly.
@MainActor
final class ColmiDriver: WearableDriver {
    private weak var writer: RingCommandWriter?
    private let decoder = ColmiDecoder()
    private let engine: ColmiSyncEngine

    // Big-data reassembly state (V2 channel).
    private var bigDataBuffer: Data?
    private var bigDataExpectedLength = 0

    init(writer: RingCommandWriter) {
        self.writer = writer
        self.engine = ColmiSyncEngine(writer: writer, decoder: decoder)
    }

    // MARK: BLE topology
    let serviceUUIDs: [CBUUID] = [CBUUID(string: ColmiUUIDs.serviceV1), CBUUID(string: ColmiUUIDs.serviceV2)]
    let writeUUID = CBUUID(string: ColmiUUIDs.write)
    let notifyUUIDs: [CBUUID] = [CBUUID(string: ColmiUUIDs.notifyV1), CBUUID(string: ColmiUUIDs.notifyV2)]
    let batteryServiceUUID: CBUUID? = nil   // battery is in-band (cmd 0x03 / notification 0x73·0x0c)
    let batteryCharUUID: CBUUID? = nil

    private var notifyV2UUID: CBUUID { CBUUID(string: ColmiUUIDs.notifyV2) }

    // MARK: Framing
    func frame(_ command: Data) -> Data {
        // Big-data requests (0xbc) are sent raw, not 16-byte framed.
        if command.first == ColmiCommandID.bigDataV2 { return command }
        return ColmiPacket.frame([UInt8](command))
    }

    // MARK: Inbound decode (+ reassembly + history routing)
    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        if characteristic == notifyV2UUID {
            return ingestBigData(data)
        }
        return ingestNormal(data)
    }

    private func ingestNormal(_ data: Data) -> [RingDecodedEvent] {
        // History opcodes are day/paging-stateful — let the engine decode + advance the machine.
        if let op = data.first, ColmiSyncEngine.isHistoryOpcode(op) {
            return engine.handleHistoryFrame(data)
        }
        let events = decoder.decodeNormal(data)
        // Realtime HR keepalive is managed by the engine; let it observe realtime frames.
        if data.first == ColmiCommandID.realtimeHeartRate {
            engine.observedRealtimeHeartRate()
        }
        return events
    }

    /// Accumulate V2 notifications until a full `0xbc` frame (length + 6 bytes) is present, then decode.
    private func ingestBigData(_ data: Data) -> [RingDecodedEvent] {
        if bigDataBuffer != nil {
            bigDataBuffer!.append(data)
        } else if data.first == ColmiCommandID.bigDataV2 {
            let v = [UInt8](data)
            guard v.count >= 4 else { return [] }
            bigDataExpectedLength = ColmiBytes.u16(v[2], v[3])
            bigDataBuffer = data
        } else {
            return [.unknown(commandId: data.first ?? 0, raw: data)]
        }

        guard let buffer = bigDataBuffer else { return [] }
        if buffer.count < bigDataExpectedLength + 6 {
            return []   // wait for more packets
        }
        let complete = buffer
        bigDataBuffer = nil
        bigDataExpectedLength = 0
        let events = decoder.decodeBigData(complete)
        // Big-data completion advances the history machine to its next stage.
        engine.handleBigDataComplete(type: [UInt8](complete).count > 1 ? complete[1] : 0)
        return events
    }

    func makeSyncEngine() -> RingSyncEngine { engine }
}
