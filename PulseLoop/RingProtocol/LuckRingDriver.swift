import Foundation
@preconcurrency import CoreBluetooth

/// LuckRing / TK18 driver. Topology is a single service `F618` with a write char `B002` and a notify char
/// `B001`; the standard `180D` Heart Rate characteristic is deliberately left unsubscribed (mirror the
/// YCBT rationale — the proprietary `07` stream reflects real finger contact).
///
/// **Framing is identity.** The encoder / sync engine / history pager already emit fully-framed 20-byte
/// packets (a logical frame is split into head + continuation packets and enqueued individually — the
/// jring pattern), so `frame(_:)` returns its input untouched. `RingBLEClient`'s serialized `withResponse`
/// write queue with its 4 s ACK timeout handles pacing between packets.
///
/// **Inbound: ACK-before-decode.** The ring retransmits a device-initiated **SEND** until the app answers
/// with a matching ACK (`queue/b.java`'s app-ACK rule), so `ingest` enqueues the protocol ACK *before* it
/// decodes — a slow decode must never be able to stall the ring. A device ACK or a SEND_NO_ACK is never
/// ACKed (the former is not data; the latter, by definition, expects no reply).
@MainActor
final class LuckRingDriver: WearableDriver {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let decoder = LuckRingDecoder()
    private let packetizer = LuckRingPacketizer()
    /// Notify packets → whole logical frames. A multi-packet frame (e.g. the ring's history streams) is
    /// split across notifications, so it must be reassembled before decode.
    private let assembler = LuckRingFrameAssembler()
    /// The history pager. The driver owns it because only the driver sees frames (`noteReceived`), and it
    /// is handed to the engine so `runStartup` can seed the catalog pass.
    private let historySync: LuckRingHistorySync

    init(writer: RingCommandWriter) {
        self.writer = writer
        self.historySync = LuckRingHistorySync(writer: writer)
    }

    // MARK: BLE topology
    let serviceUUIDs: [CBUUID] = [CBUUID(string: LuckRingUUIDs.service)]
    let writeUUID = CBUUID(string: LuckRingUUIDs.write)
    let notifyUUIDs: [CBUUID] = [CBUUID(string: LuckRingUUIDs.notify)]
    let batteryServiceUUID: CBUUID? = nil    // battery is in-band (dataType 3)
    let batteryCharUUID: CBUUID? = nil

    // MARK: Framing
    /// Identity — the engine/encoder emit fully-framed 20-byte packets, enqueued one per packet.
    func frame(_ command: Data) -> Data { command }

    // MARK: Lifecycle

    /// Auto-reconnect reuses this driver, so a frame half-assembled when the old link dropped would be
    /// completed with bytes from the new one, and a history pass would still think it was mid-type.
    func connectionDidStart() {
        assembler.reset()
        historySync.cancel()
    }

    /// The history pager's settle/stall watchdogs are timers; a ring that drops mid-pass leaves them
    /// stepping through the rest of the catalog into a write queue the reconnect will flush before its
    /// handshake. Kill it at disconnect — the one place that can't race the reconnect.
    func connectionDidEnd() {
        assembler.reset()
        historySync.cancel()
    }

    // MARK: Inbound decode

    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        guard let frame = assembler.append(data) else { return [] }

        // ACK a device-initiated SEND before decoding — the ring retransmits until we do.
        if frame.cmdType == .send {
            writer?.enqueue(packetizer.ack(dataType: frame.dataType, seq: frame.seq, devType: frame.devType))
        }

        // Let the history pager settle/advance on this type's data frames.
        if frame.cmdType == .send || frame.cmdType == .sendNoAck {
            historySync.noteReceived(dataType: frame.dataType)
        }

        return decoder.decode(frame)
    }

    func makeSyncEngine() -> RingSyncEngine {
        LuckRingSyncEngine(writer: writer, historySync: historySync)
    }
}
