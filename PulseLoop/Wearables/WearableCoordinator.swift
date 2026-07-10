import Foundation
@preconcurrency import CoreBluetooth

/// Stable identifier for a wearable family. Persisted on `Device.deviceTypeRaw`, so **append cases,
/// never rename/reorder.** Adding a new wearable = add a case here + a `WearableCoordinator`.
enum RingDeviceType: String, Codable, CaseIterable, Sendable {
    case jring
    case colmiR02
    case tk5

    /// Human-facing default name when no advertised name is available.
    var displayName: String {
        switch self {
        case .jring: return "SMART_RING"
        case .colmiR02: return "Colmi / Yawell ring"
        case .tk5: return "TK5 ring"
        }
    }
}

/// The advertisement facts a coordinator needs to claim a discovered peripheral, wrapped so
/// `matches` doesn't depend on CoreBluetooth's raw `[String: Any]` advertisement dictionary.
struct AdvertisementInfo {
    let serviceUUIDs: [CBUUID]
    let manufacturerData: Data?
}

/// Capability + metadata descriptor for a wearable family — the "what can it do / how do we
/// recognize it" half of GadgetBridge's Coordinator/DeviceSupport split. A coordinator performs
/// **no I/O**; it only describes the device and builds its `WearableDriver`.
@MainActor
protocol WearableCoordinator {
    /// Coordinators are instantiated from the registry by metatype, so they need a no-arg init.
    init()

    /// The persisted device-type discriminator this coordinator handles.
    static var deviceType: RingDeviceType { get }

    /// Claim a discovered peripheral by advertised name / service UUID / manufacturer data.
    /// First coordinator in the registry whose `matches` returns true wins.
    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool

    /// Everything this device can do — drives capability-gated UI.
    var capabilities: Set<WearableCapability> { get }

    /// Fallback display name + icon for the device card / discovered-ring rows.
    var displayName: String { get }
    var iconSystemName: String { get }

    /// Build the connection/protocol handler for one connection. A fresh driver per connection keeps
    /// per-connection state (big-data buffers, sync-machine state) from leaking across reconnects.
    func makeDriver(writer: RingCommandWriter) -> WearableDriver
}

extension WearableCoordinator {
    var displayName: String { Self.deviceType.displayName }
}
