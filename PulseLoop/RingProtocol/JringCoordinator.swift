import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for the original "jring" (`SMART_RING`, service `000056ff…`). Declares its
/// capabilities and recognizes the device from its advertisement — matching logic lifted verbatim
/// from the old `RingBLEClient.matchesRing`.
@MainActor
final class JringCoordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .jring

    private static let advertisedName = "SMART_RING"
    private static let manufacturerHexNeedle = "41422ec75b6a"
    private static let serviceCBUUID = CBUUID(string: RingUUIDs.service)

    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        if let name, name == advertisedName { return true }
        if advertisement.serviceUUIDs.contains(serviceCBUUID) { return true }
        if let mfg = advertisement.manufacturerData, mfg.hexString.contains(manufacturerHexNeedle) {
            return true
        }
        return false
    }

    let capabilities: Set<WearableCapability> = [
        .heartRate, .spo2, .steps, .sleep, .battery,
        .manualHeartRate, .manualSpo2,   // jring supports on-demand HR + SpO2 spot readings
        .realtimeHeartRate, .findDevice,
    ]

    let iconSystemName = "circle.hexagongrid.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        JringDriver(writer: writer)
    }
}
