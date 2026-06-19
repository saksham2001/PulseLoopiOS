import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for the Colmi R02 (and the wider Yawell ring family that shares this protocol).
/// Declares the rich capability set and recognizes the ring by its advertised name / service UUIDs.
@MainActor
final class ColmiCoordinator: WearableCoordinator {
    static let deviceType: RingDeviceType = .colmiR02

    /// R02 advertises as `R02_XXXX`. (Other Colmi/Yawell models use different prefixes — widen here
    /// to support them, since they share `ColmiDriver`.)
    private static let namePattern = try! NSRegularExpression(pattern: "^R02_.*", options: [])
    private static let serviceV1 = CBUUID(string: ColmiUUIDs.serviceV1)
    private static let serviceV2 = CBUUID(string: ColmiUUIDs.serviceV2)

    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        if let name {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if namePattern.firstMatch(in: name, options: [], range: range) != nil { return true }
        }
        if advertisement.serviceUUIDs.contains(serviceV1) || advertisement.serviceUUIDs.contains(serviceV2) {
            return true
        }
        return false
    }

    let capabilities: Set<WearableCapability> = [
        .heartRate, .spo2, .steps, .sleep, .battery,
        .remSleep, .stress, .hrv, .temperature,
        .manualHeartRate, .realtimeHeartRate, .realtimeSteps,
        .findDevice, .powerOff, .factoryReset,
    ]

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        ColmiDriver(writer: writer)
    }
}
