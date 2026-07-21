import Foundation
@preconcurrency import CoreBluetooth

/// CRP ("crrepa"/CRPsmart) driver — the `fdda`-profile family behind the Moyoung "Da Rings" app,
/// the official app for the CRP-firmware Colmi R11 (see `CRPProtocol` and `decompiled-moyoung-official/`).
///
/// **BLE topology.** Proprietary service `fdda`; write to `fdd2`; notify on `fdd1` (current-steps
/// push), `fdd3` (framed command replies) and `fdd6` (recording/OTA, ignored in v1). Heart rate
/// rides the standard `180d`/`2a37` characteristic and battery the standard `180f`/`2a19` — both
/// declared so `RingBLEClient` binds them.
///
/// **Framing is identity.** `CRPProtocol` and `CRPSyncEngine` emit fully-framed `FD DA …` packets
/// (all v1 commands fit one ≤20-byte packet, so no chunking is needed), so `frame(_:)` returns its input.
///
/// **Inbound.** `fdd3` replies may span several notifications and are reassembled by
/// `CRPFrameAssembler`; `fdd1`/`2a37` pushes are self-contained. A fresh driver is built per connect
/// (`RingBLEClient.installDriver` calls `coordinator.makeDriver` every time), so the assembler starts
/// clean without an explicit reset hook (matches `JringDriver`/`LuckRingDriver`).
@MainActor
final class CRPDriver: WearableDriver {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let assembler = CRPFrameAssembler()

    init(writer: RingCommandWriter?) {
        self.writer = writer
    }

    // MARK: BLE topology
    let serviceUUIDs: [CBUUID] = [CRPUUIDs.serviceCBUUID, CRPUUIDs.heartRateServiceCBUUID]
    let writeUUID = CRPUUIDs.writeCBUUID
    let notifyUUIDs: [CBUUID] = [
        CRPUUIDs.stepsNotifyCBUUID,
        CRPUUIDs.cmdNotifyCBUUID,
        CRPUUIDs.recordingNotifyCBUUID,
        CRPUUIDs.heartRateMeasureCBUUID,
    ]
    let batteryServiceUUID: CBUUID? = CRPUUIDs.batteryServiceCBUUID
    let batteryCharUUID: CBUUID? = CRPUUIDs.batteryLevelCBUUID

    // MARK: Framing — the protocol/engine already build full CRP frames.
    func frame(_ command: Data) -> Data { command }

    // MARK: Inbound decode
    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        // Framed command replies (fdd3) reassemble across notifications; everything else is a
        // self-contained push routed by source characteristic inside CRPDecoder.
        if characteristic == CRPUUIDs.cmdNotifyCBUUID {
            guard let frame = assembler.append(data) else { return [] }
            return CRPDecoder.decode(frame, from: characteristic)
        }
        return CRPDecoder.decode(data, from: characteristic)
    }

    func makeSyncEngine() -> RingSyncEngine { CRPSyncEngine(writer: writer) }
}
