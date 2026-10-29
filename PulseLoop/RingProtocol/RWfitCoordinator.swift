import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for the RWfit family (`com.rw.revivalfit` — rings sold under assorted brands,
/// including "Colmi"-labelled units that share nothing with the Colmi protocol). This file is the
/// whole of what makes an RWfit ring an RWfit ring: its advertised identity and its capability set;
/// the two-framings problem lives entirely in `RWfitDriver`.
///
/// Recognition is by **strong, family-exclusive signals** — exactly the ones the vendor's own
/// scanner keys on (`r5/d.java:70-134`):
/// - the advertised `A00A` service (the vendor's `pidType 1` pattern `02 01 06 03 03 0a a0` is
///   Flags + a 16-bit service list containing `0xA00A`, which CoreBluetooth surfaces as a service
///   UUID), or
/// - manufacturer data opening with company ID `0x05D6` (`d6 05 02 00` / `d6 05 41 54` "AT") or
///   `0x06D6` (`d6 06 02 00`, the "T-Ring" line).
///
/// **No name matching, on purpose**: the one field a rebrander always changes is the name — the
/// known unit was bought as a "Colmi" — and the catalog card's `advertisedNamePatterns` is empty
/// until a diagnostics export shows what these rings actually call themselves.
@MainActor
final class RWfitCoordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .rwfit

    /// Manufacturer-data prefixes: little-endian company ID + the vendor's fixed lead-in bytes.
    static let manufacturerHexPrefixes = ["d6050200", "d6054154", "d6060200"]

    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        if advertisesService(advertisement) { return true }
        if let mfg = advertisement.manufacturerData {
            let hex = mfg.hexString
            if manufacturerHexPrefixes.contains(where: hex.hasPrefix) { return true }
        }
        return false
    }

    /// True when the advertisement carries the `A00A` service, 16-bit or 128-bit form.
    private static func advertisesService(_ advertisement: AdvertisementInfo) -> Bool {
        advertisement.serviceUUIDs.contains { uuid in
            let value = uuid.uuidString.uppercased()
            return value == "A00A" || value == "0000A00A-0000-1000-8000-00805F9B34FB"
        }
    }

    /// Until initialization verifies the per-unit feature menu, only battery is advertised.
    let capabilities: Set<WearableCapability> = [.battery]

    /// Sensor and manual capabilities are granted from the validated feature menu. Legacy rings
    /// can expose supported history sensors but never the modern on-demand commands.
    let bitmapGatedCapabilities: Set<WearableCapability> = [
        .heartRate, .spo2, .steps, .sleep, .remSleep,
        .temperature, .bloodPressure, .manualBloodPressure,
        .hrv, .manualHrv, .stress, .bloodSugar,
        .realtimeHeartRate, .manualHeartRate, .manualSpo2,
    ]

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        RWfitDriver(writer: writer)
    }
}
