import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for the CRP ("crrepa"/CRPsmart) `fdda`-profile family — official app Moyoung
/// "Da Rings" (`com.moyoung.ring`). Declares what `CRPDriver` can decode and how the ring is
/// recognised. See `CRPProtocol` and `decompiled-moyoung-official/`.
///
/// **Recognition / reachability.** The family's authoritative signal is the advertised `fdda`
/// service, matched below for completeness. In practice the CRP Colmi R11 advertises the generic name
/// `SMART_RING` with **no** service UUID pre-connect, so nothing matches it at scan and it falls back
/// to jring. The Android app re-routes to this driver once discovery reveals `fdda` post-connect;
/// iOS has no such post-connect driver swap, and instead — exactly as it separates the QRing vs
/// SmartHealth Colmi firmwares — relies on the user picking the "Colmi R11 (Da Rings app)" card
/// (`WearableModel.colmiR11CRP`), which routes `preferredFamily = .crp` to this coordinator up front.
///
/// **Bonding.** Unlike the Colmi-UART R11, the CRP ring connects GATT-only — the vendor app performs
/// no OS bond in its connect path (bonding there is a separate opt-in HID/camera feature). iOS's
/// CoreBluetooth has no explicit bond step in the connect path anyway, so there is nothing to gate.
@MainActor
final class CRPCoordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .crp

    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        // Only the family-exclusive `fdda` service claims a CRP ring at scan. The CRP R11 doesn't
        // advertise it, so this is effectively never hit pre-connect — the user's carousel pick is
        // the real entry point (see the class doc). Kept so a ring that *does* advertise `fdda` lands
        // here rather than on the jring fallback.
        advertisement.serviceUUIDs.contains(CRPUUIDs.serviceCBUUID)
    }

    /// v1 baseline — only capabilities backed by a decode path confirmed from the decompile:
    /// current-steps push (`fdd1`), the standard HR stream (`2a37`) with its start/stop command, its
    /// spot reading, the standard battery read, and find-device. Sleep / SpO2 / HRV / stress /
    /// temperature and history sync are deferred until their CRP reply layouts are confirmed against
    /// hardware — deliberately not promised here so the product UI hides them.
    let capabilities: Set<WearableCapability> = [
        .steps, .realtimeSteps,
        .heartRate, .realtimeHeartRate, .manualHeartRate,
        .battery,
        .findDevice,
    ]

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver { CRPDriver(writer: writer) }
}
