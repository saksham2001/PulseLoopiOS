import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for the Colmi R02 (and the wider Yawell ring family that shares this protocol).
/// Declares the rich capability set and recognizes the ring by its advertised name / service UUIDs.
@MainActor
final class ColmiCoordinator: WearableCoordinator {
    static let deviceType: RingDeviceType = .colmiR02

    /// The whole Colmi/Yawell ring family advertises under many names but shares one protocol, so
    /// they all route through `ColmiDriver`. Patterns mirror GadgetBridge's `yawell/ring` coordinators.
    private static let namePatterns: [NSRegularExpression] = [
        "^R02_.*",
        "^R03_.*",
        "^R06_.*",
        "^COLMI R07_.*",
        "^R09_.*",
        "^COLMI R10_.*",
        "^COLMI R12_.*",
        "^R05_[0-9A-F]{4}$",
        "^R10_[0-9A-F]{4}$",
        "^R11C?_[0-9A-F]{4}$",
        "^H59_.*",
    ].map { try! NSRegularExpression(pattern: $0, options: []) }
    private static let serviceV1 = CBUUID(string: ColmiUUIDs.serviceV1)
    private static let serviceV2 = CBUUID(string: ColmiUUIDs.serviceV2)

    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        if let name {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if namePatterns.contains(where: { $0.firstMatch(in: name, options: [], range: range) != nil }) {
                return true
            }
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
