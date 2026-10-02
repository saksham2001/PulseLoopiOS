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

    /// Real-time vital capabilities backed by decoded group-1 replies (`g1/a.java` lines 664–712):
    /// HR (cmd 9), HRV (cmd 10), SpO2 (cmd 11), stress (cmd 14), temperature (cmd 32).
    ///
    /// The stored day timelines are decoded too: sleep (group-2/cmd-14) and the all-day "timing"
    /// vital histories (HR/SpO2/HRV/stress, group-2/cmd 15/16/17/47) — see `CRPDecoder`. They are
    /// pulled by `CRPSyncEngine.runStartup` and persisted through the event bridge; no capability
    /// bit gates them, so none is claimed here.
    ///
    /// `manualSpo2` is claimed alongside `manualHeartRate`: both surface a "Measure now" button in
    /// Vitals, the start/stop commands are confirmed (`b1/h.d`), and cmd-11 results now decode.
    /// SpO2 stays **unconditional** rather than bitmap-gated even though `CRPSyncEngine` now asks the
    /// ring directly (`querySupportSpO2Type`, group 2 / cmd 37): the hardware is confirmed by a real
    /// reading in zaggash's 2026-07-23 capture (`group 1 / cmd 11` payload `0x61` = 97 %), and
    /// `refinedCapabilities` is additive-only, so gating it would only ever be a no-op or a
    /// regression. The read-back is decoded for the raw-packet feed — see `CRPDecoder.decodeSpO2Support`.
    ///
    /// Steps push (`fdd1`), battery (`2a19`), find-device also confirmed. Note: HR does NOT use the
    /// standard `2a37` characteristic on CRP rings — all vital results come back as framed replies
    /// on `fdd3` group 1.
    let capabilities: Set<WearableCapability> = [
        .steps, .realtimeSteps,
        .heartRate, .realtimeHeartRate, .manualHeartRate, .manualSpo2,
        .spo2, .stress, .hrv, .sleep,
        .battery,
        .findDevice,
    ]

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver { CRPDriver(writer: writer) }
}
