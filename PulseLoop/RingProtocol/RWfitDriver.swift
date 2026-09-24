import Foundation
@preconcurrency import CoreBluetooth

/// Both RwFit protocols share A00A/B002/B003. OTA services are an initial hint, not
/// proof of framing; only a checksum-validated response confirms the active protocol.
@MainActor
final class RWfitDriver: WearableDriver {
    nonisolated deinit {}
    private weak var writer: RingCommandWriter?
    private let legacyCodec = RWfitLegacyCodec()
    private let jlCodec = RWfitJLCodec()
    private let clock = RWfitClock()
    private let decoder: RWfitDecoder
    private let gate: RWfitCommandGate
    private let historySync: RWfitHistorySync
    private weak var engine: RWfitSyncEngine?
    private(set) var framing: RWfitFraming = .legacy
    private(set) var framingValidated = false
    private var ready = false

    init(writer: RingCommandWriter) {
        self.writer = writer
        decoder = RWfitDecoder(clock: clock)
        gate = RWfitCommandGate(writer: writer, legacyCodec: legacyCodec, jlCodec: jlCodec)
        historySync = RWfitHistorySync(gate: gate, clock: clock)
    }

    let serviceUUIDs = [CBUUID(string: RWfitUUIDs.service)]
    let writeUUID = CBUUID(string: RWfitUUIDs.write)
    let notifyUUIDs = [CBUUID(string: RWfitUUIDs.notify)]
    let batteryServiceUUID: CBUUID? = nil
    let batteryCharUUID: CBUUID? = nil
    var requiredSubscriptionsBeforeConnected: [CBUUID] { notifyUUIDs }
    func frame(_ command: Data) -> Data { command }

    func servicesDiscovered(_ services: [CBUUID]) {
        let markers = [RWfitUUIDs.jieli, RWfitUUIDs.telinkOTA, RWfitUUIDs.pixartOTA].map { CBUUID(string: $0) }
        select(services.contains(where: markers.contains) ? .jieli : .legacy)
        rwfitDiagnostic("Services discovered", ["services": services.map(\.uuidString).joined(separator: ","),
                                                 "initialFraming": framing.rawValue])
    }

    private func select(_ framing: RWfitFraming) {
        self.framing = framing
        gate.framing = framing
        historySync.framing = framing
    }

    private func validate(_ framing: RWfitFraming) {
        guard !framingValidated else { return }
        select(framing)
        framingValidated = true
        rwfitDiagnostic("Protocol validated", ["framing": framing.rawValue])
    }

    func connectionDidStart() {
        connectionDidEnd()
        framingValidated = false
    }

    func connectionDidEnd() {
        ready = false
        engine?.cancel()
        legacyCodec.reset()
        jlCodec.reset()
        gate.cancel()
        historySync.cancel()
    }

    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        guard characteristic == notifyUUIDs[0] else { return [] }
        // Until a response validates a framing, feed both bounded codecs. This also handles a
        // modern ring with no OTA sibling service and notifications arriving before startup.
        if !framingValidated {
            let modern = jlCodec.decode(data)
            if modern.contains(where: { if case .frame = $0 { return true }; return false }) {
                validate(.jieli)
                return ingestModern(modern)
            }
            return ingestLegacy(legacyCodec.decode(data))
        }
        return framing == .jieli ? ingestModern(jlCodec.decode(data)) : ingestLegacy(legacyCodec.decode(data))
    }

    private func ingestLegacy(_ inbound: [RWfitLegacyInbound]) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        for item in inbound {
            switch item {
            case let .ackNeeded(cmd, serial):
                writer?.enqueue(legacyCodec.ack(cmd: cmd, serial: serial, status: 0))
            case let .checksumFailed(cmd, serial):
                writer?.enqueue(legacyCodec.ack(cmd: cmd, serial: serial, status: 2))
                rwfitDiagnostic("Legacy checksum failed")
            case let .deviceAck(cmd, serial, status):
                gate.noteLegacyAck(cmd: cmd, serial: serial, status: status)
            case let .frame(cmd, payload):
                validate(.legacy)
                if let type = RWfitHistoryType(legacyCommand: cmd), historySync.isRunning {
                    historySync.noteReceived(type: type, payload: payload)
                    gate.noteLegacyFrame(cmd: cmd, payload: payload)
                    continue
                }
                gate.noteLegacyFrame(cmd: cmd, payload: payload)
                events += decoder.decodeLegacy(cmd: cmd, payload: payload).filter { event in
                    if case .supportFunctions = event { return ready }; return true
                }
            }
        }
        return events
    }

    private func ingestModern(_ inbound: [RWfitJLInbound]) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        for item in inbound {
            switch item {
            case .crcFailed: rwfitDiagnostic("Modern frame CRC failed")
            case let .frame(flag, triple, payload):
                if flag == 0x01 { writer?.enqueue(jlCodec.ack(triple: triple)) }
                gate.noteJieliFrame(flag: flag, triple: triple, payload: payload)
                // History response ownership belongs to the pager's awaited persistence boundary.
                // Publishing it here would acknowledge storage before SwiftData had saved it.
                if triple.cmd == 0x05 { continue }
                events += decoder.decodeJieli(triple: triple, payload: payload).filter { event in
                    if case .supportFunctions = event { return false }
                    return true
                }
            }
        }
        return events
    }

    func makeSyncEngine() -> RingSyncEngine {
        let result = RWfitSyncEngine(gate: gate, historySync: historySync, clock: clock,
                                    framingProvider: { [weak self] in self?.framing ?? .legacy },
                                    selectFraming: { [weak self] in self?.select($0) },
                                    readiness: { [weak self] capabilities in
            guard let self else { return }
            self.ready = capabilities != nil
            self.writer?.emit(.supportFunctions(capabilities ?? []))
        }, deviceIdentifier: { [weak self] in self?.writer?.deviceIdentifier })
        engine = result
        return result
    }
}
