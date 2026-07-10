import Foundation
@preconcurrency import CoreBluetooth

/// TK5 driver. Owns the length-prefixed CRC16 framing and the split-channel topology: the command
/// characteristic `be940001` is *both* the write target and a notify source (command replies), while
/// `be940003` carries the async live/history stream. The standard `180D`/`2A37` Heart Rate
/// characteristic is deliberately left unsubscribed — see the BLE-topology note below.
///
/// Because `be940001` is simultaneously the write and a notify characteristic, `RingBLEClient`'s
/// discovery subscribes any `notifyUUIDs` entry even when it also matches `writeUUID`.
@MainActor
final class TK5Driver: WearableDriver {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let decoder = TK5Decoder()

    init(writer: RingCommandWriter) {
        self.writer = writer
    }

    // MARK: BLE topology
    //
    // Only the proprietary `be940000` service is used. The standard `180D`/`2A37` Heart Rate
    // characteristic is intentionally NOT subscribed: on the TK5 it emits a cached resting HR
    // periodically even when the ring is off the finger (observed as a constant ~87 bpm), which would
    // override a real on-demand measurement. The official app never subscribes it either — live HR
    // comes solely from the proprietary `06 01` stream, which reflects actual finger contact.
    let serviceUUIDs: [CBUUID] = [CBUUID(string: TK5UUIDs.service)]
    let writeUUID = CBUUID(string: TK5UUIDs.command)
    let notifyUUIDs: [CBUUID] = [
        CBUUID(string: TK5UUIDs.command),   // command replies (also the write char)
        CBUUID(string: TK5UUIDs.stream),    // async live + history stream
    ]
    let batteryServiceUUID: CBUUID? = nil   // battery is in-band (0x02 0x00 status, payload[5])
    let batteryCharUUID: CBUUID? = nil

    // MARK: Framing
    func frame(_ command: Data) -> Data {
        // Logical command is `[type, cmd, payload…]`; insert the total-length field and append CRC16.
        TK5Frame.frame([UInt8](command))
    }

    // Sleep-record reassembly. The sleep timeline (`05 13`) is one logical record split across several
    // be940003 frames, with stage segments straddling frame boundaries. The header frame starts with
    // the `af fa` magic and carries the total concatenated payload length at bytes [2..3]; we buffer
    // until that many bytes arrive, then decode.
    private var sleepBuffer: [UInt8] = []
    private var sleepTotal = 0

    // MARK: Inbound decode
    //
    // Every history frame is announced with a leading `.historySyncProgress` before its decoded
    // records. The sync engine's watchdog needs to know *a history frame arrived*, and it can't infer
    // that from the events alone: a sleep continuation frame decodes to nothing until the record is
    // complete, an all-unworn `05 18` page yields only `.activityUpdate`, and `.activityUpdate` is
    // also what the ring's continuous live `06 00` status pushes. Only the frame type distinguishes
    // them, and only the driver sees it.
    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        guard let frame = TK5Frame(validating: data) else {
            return [.unknown(commandId: data.first ?? 0, raw: data)]
        }
        guard frame.type == TK5FrameType.register else { return decoder.decode(frame) }
        switch frame.cmd {
        case TK5Command.sleepRecord:
            return [.historySyncProgress(stage: "Syncing sleep…")] + reassembleSleep(frame.payload)
        case TK5Command.historyRecordShort, TK5Command.historyRecordLong:
            return [.historySyncProgress(stage: "Syncing history…")] + decoder.decode(frame)
        default:
            return decoder.decode(frame)   // register reads / pref-write acks
        }
    }

    private func reassembleSleep(_ payload: [UInt8]) -> [RingDecodedEvent] {
        if payload.count >= 4, payload[0] == 0xaf, payload[1] == 0xfa {
            // Header frame — start a fresh buffer and read the total length.
            sleepBuffer = payload
            sleepTotal = Int(payload[2]) | (Int(payload[3]) << 8)
        } else if !sleepBuffer.isEmpty {
            sleepBuffer.append(contentsOf: payload)   // continuation
        } else {
            return []   // continuation with no header seen (mid-stream connect) — ignore
        }
        guard sleepTotal > 0, sleepBuffer.count >= sleepTotal else { return [] }   // still buffering
        let record = Array(sleepBuffer.prefix(sleepTotal))
        sleepBuffer = []
        sleepTotal = 0
        return decoder.decodeSleep(record)
    }

    func makeSyncEngine() -> RingSyncEngine {
        TK5SyncEngine(writer: writer)
    }
}
