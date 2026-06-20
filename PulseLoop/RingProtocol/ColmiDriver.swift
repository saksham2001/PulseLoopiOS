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

    // Big-data reassembly state (V2 channel), keyed by the 0xbc *type* byte so interleaved/fragmented
    // SpO2 / sleep / temperature replies reassemble independently instead of corrupting one buffer.
    private var bigDataBuffers: [UInt8: Data] = [:]
    /// The type of the most recently started buffer — a continuation chunk (no 0xbc header) appends here.
    private var activeBigDataType: UInt8?

    init(writer: RingCommandWriter) {
        self.writer = writer
        self.engine = ColmiSyncEngine(writer: writer, decoder: decoder)
    }

    // MARK: BLE topology
    let serviceUUIDs: [CBUUID] = [CBUUID(string: ColmiUUIDs.serviceV1), CBUUID(string: ColmiUUIDs.serviceV2)]
    let writeUUID = CBUUID(string: ColmiUUIDs.write)
    let commandUUID: CBUUID? = CBUUID(string: ColmiUUIDs.command)   // big-data requests go here
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

    /// Big-data (`0xbc`) requests must go to the Command characteristic (`de5bf72a`), not the normal
    /// write char — replies come back on the V2 notify char. Everything else uses the write char.
    func usesCommandChannel(for frame: Data) -> Bool {
        frame.first == ColmiCommandID.bigDataV2
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
    /// Buffers are keyed by the `0xbc` *type* byte so a fragmented SpO2 reply and an interleaved sleep
    /// reply reassemble independently. A header chunk (`0xbc <type> <lenLo> <lenHi> …`) starts/replaces
    /// that type's buffer and becomes the active type; a continuation chunk appends to the active type.
    private func ingestBigData(_ data: Data) -> [RingDecodedEvent] {
        let type: UInt8
        if data.first == ColmiCommandID.bigDataV2 {
            let v = [UInt8](data)
            guard v.count >= 4 else { return [] }
            type = v[1]
            bigDataBuffers[type] = data        // start (or restart) this type's buffer
        } else if let active = activeBigDataType, bigDataBuffers[active] != nil {
            type = active
            bigDataBuffers[active]!.append(data)   // continuation of the in-flight frame
        } else {
            return [.unknown(commandId: data.first ?? 0, raw: data)]
        }

        guard let buffer = bigDataBuffers[type] else { return [] }
        let bytes = [UInt8](buffer)
        guard bytes.count >= 4 else { return [] }
        let expectedLength = ColmiBytes.u16(bytes[2], bytes[3])
        if buffer.count < expectedLength + 6 {
            // Still incomplete — this type is the one continuation chunks should append to.
            activeBigDataType = type
            return []
        }
        // Complete — consume this type's buffer. Point `activeBigDataType` at whatever buffer is still
        // open (if any), so a frame that completes in one packet doesn't orphan another in-flight one.
        bigDataBuffers[type] = nil
        activeBigDataType = bigDataBuffers.keys.first
        let events = decoder.decodeBigData(buffer)
        // Big-data completion advances the history machine to its next stage.
        engine.handleBigDataComplete(type: type)
        return events
    }

    func makeSyncEngine() -> RingSyncEngine { engine }
}
