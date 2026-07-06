import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for the TK5 ring (SmartHealth app). Declares the capabilities we can actually decode
/// and recognizes the device from its advertisement.
///
/// Recognition is name-first: the TK5's proprietary `be940000` service is **not advertised** (only
/// standard Heart Rate + a generic `FEE7` service are), so the reliable signal is the `TK5 …` local
/// name, backed up by the manufacturer-data prefix observed in the nRF capture.
@MainActor
final class TK5Coordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .tk5

    /// Manufacturer-data prefix from the capture (`10786501…`, company 0x7810). The trailing bytes are
    /// device-specific (they echo the name suffix), so only the prefix is matched.
    private static let manufacturerHexPrefix = "10786501"

    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        if let name, name.uppercased().hasPrefix("TK5") { return true }
        if WearableModel.model(advertisedName: name)?.family == .tk5 { return true }
        if let mfg = advertisement.manufacturerData, mfg.hexString.hasPrefix(manufacturerHexPrefix) {
            return true
        }
        return false
    }

    /// Metrics decoded from the captures: live + history HR, live SpO₂, day steps, HRV (history +
    /// live, verified against the app's displayed values), and the in-band battery. Stress is *not*
    /// claimed — the ring doesn't store it; SmartHealth derives it from HRV app-side. Sleep/temperature
    /// are omitted until a capture contains them, so no empty cards appear.
    let capabilities: Set<WearableCapability> = [
        .heartRate, .spo2, .steps, .battery, .hrv,
        .realtimeHeartRate, .realtimeSteps,
        .findDevice,
    ]

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        TK5Driver(writer: writer)
    }
}
