import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for the LuckRing / TK18 family (the "K6" vendor SDK). Declares what the driver can decode
/// and recognizes the device from its advertisement. The *protocol* is not TK18-specific — the whole
/// 0xFF64 LuckRing family speaks it — so the driver / encoder / decoder / sync engine it builds are the
/// shared `LuckRing*` types. This file is the whole of what makes a LuckRing a LuckRing: its advertised
/// identity and its capability set.
///
/// Recognition is by **strong, family-exclusive signals**: the advertised `F618` service, or the
/// `0xFF64` manufacturer company ID (little-endian `64 FF` prefix), or a catalog name pattern (TK18).
/// The Android SDK matches on the company ID alone with no name whitelist, so a TK18 sibling that renames
/// itself is still claimed.
@MainActor
final class LuckRingCoordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .luckRing

    /// The manufacturer-data prefix: company ID `0xFF64` in the little-endian slot ⇒ `64 FF`. This is the
    /// single signal the vendor app itself matches on, so it is authoritative.
    static let manufacturerHexPrefix = "64ff"

    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        if advertisesService(advertisement) { return true }
        if let mfg = advertisement.manufacturerData, mfg.hexString.hasPrefix(manufacturerHexPrefix) {
            return true
        }
        if WearableModel.model(advertisedName: name)?.family == .luckRing { return true }
        return false
    }

    /// True when the advertisement carries the `F618` service, in either its 16-bit or full 128-bit form.
    private static func advertisesService(_ advertisement: AdvertisementInfo) -> Bool {
        advertisement.serviceUUIDs.contains { uuid in
            let value = uuid.uuidString.uppercased()
            return value == "F618" || value == "0000F618-0000-1000-8000-00805F9B34FB"
        }
    }

    /// The baseline the LuckRing driver can decode: live + history HR, live + history SpO₂ (with the all-day
    /// log), day steps, sleep, HRV, temperature, blood pressure, stress, and the in-band battery, plus the
    /// find-device buzz. All are unconditional promises — every metric maps onto a `LuckRing*` decoder path.
    ///
    /// **`bitmapGatedCapabilities` is empty on purpose.** The K6 `FUNCTION_CONTROL` (dataType 22) bitmap is
    /// obfuscated in the decompile, so no capability can yet be deferred to the connected unit; the whole
    /// baseline stands as a family promise. TK18 is the only hardware-tested unit — a `.limited` family —
    /// so capabilities the physical ring refuses should be pruned here once on-device testing confirms them
    /// (see `docs/hardware/luckring.md`).
    let capabilities: Set<WearableCapability> = [
        .heartRate, .realtimeHeartRate, .manualHeartRate,
        .spo2, .manualSpo2, .spo2History,
        .steps, .realtimeSteps,
        .sleep, .battery,
        .hrv, .manualHrv,
        .temperature,
        .bloodPressure, .manualBloodPressure,
        .stress,
        .findDevice,
        // The K6 auto-monitoring config (opcode 128: auto-HR on/off, interval, auto-SpO₂) is a real
        // device knob — the firmware ships with it *off*, so exposing the interval UI is what lets the
        // ring log history at all.
        .measurementInterval,
    ]

    let bitmapGatedCapabilities: Set<WearableCapability> = []

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        LuckRingDriver(writer: writer)
    }
}
