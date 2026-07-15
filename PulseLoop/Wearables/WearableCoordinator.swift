import Foundation
@preconcurrency import CoreBluetooth

/// Stable identifier for a wearable family. Persisted on `Device.deviceTypeRaw`, so **append cases,
/// never rename/reorder.** Adding a new wearable = add a case here + a `WearableCoordinator`.
enum RingDeviceType: String, Codable, CaseIterable, Sendable {
    case jring
    case colmiR02
    case tk5
    /// Colmi rings that ship with the **SmartHealth** app instead of QRing. Same hardware line as
    /// `.colmiR02`, entirely different firmware: they speak YCBT (the TK5's protocol), so they share
    /// that driver, not `ColmiDriver`. Which of the two a given ring is cannot be read off its
    /// advertisement — the user declares it at pairing (see `RingAppVariant`).
    case colmiSmartHealth
    /// LuckRing / TK18 family (the "K6" vendor SDK, company ID `0xFF64`). Sold under simsonlab and other
    /// brands; TK18 is the hardware-tested unit. See `LuckRingCoordinator`.
    case luckRing

    /// Human-facing default name when no advertised name is available.
    var displayName: String {
        switch self {
        case .jring: return "SMART_RING"
        case .colmiR02: return "Colmi / Yawell ring"
        case .tk5: return "TK5 ring"
        case .colmiSmartHealth: return "Colmi ring (SmartHealth)"
        case .luckRing: return "LuckRing"
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

    /// Capabilities this family will accept **only if the connected unit's own capability bitmap claims
    /// them** (YCBT's `02 01` reply; see `YCBTSupportFunction`). Empty by default.
    ///
    /// Exists because a *family* is not a *SKU*: two Colmi rings that speak the identical protocol can
    /// differ on whether they have a temperature or blood-pressure sensor at all. A static set is then
    /// wrong in one of two ways — it hides a metric the ring really has, or it promises one it doesn't
    /// and the card renders permanently empty. Listing a capability here says "this family *may* have
    /// it; ask the device."
    ///
    /// Deliberately additive-only (see `refinedCapabilities`): the bitmap can never remove a baseline
    /// capability, so a family that lists nothing here is bit-for-bit unaffected by any of this.
    var bitmapGatedCapabilities: Set<WearableCapability> { get }

    /// Fallback display name + icon for the device card / discovered-ring rows.
    var displayName: String { get }
    var iconSystemName: String { get }

    /// Build the connection/protocol handler for one connection. A fresh driver per connection keeps
    /// per-connection state (big-data buffers, sync-machine state) from leaking across reconnects.
    func makeDriver(writer: RingCommandWriter) -> WearableDriver
}

extension WearableCoordinator {
    var displayName: String { Self.deviceType.displayName }

    /// Nothing is bitmap-gated unless a family opts in, so jring / QRing-Colmi — neither of which speaks
    /// YCBT, and so has no bitmap to consult — keep their static sets. Both YCBT families opt in.
    var bitmapGatedCapabilities: Set<WearableCapability> { [] }

    /// Fold a device-reported capability bitmap into this family's capability set.
    ///
    /// `baseline ∪ (gated ∩ derived)` — the bitmap may only **add**, and only from the set the family
    /// pre-approved. Two properties fall out of that, and both are load-bearing:
    ///
    /// - A bitmap can never *remove* a baseline capability. Firmware bitmaps under-report in the field
    ///   (an old firmware simply sends a shorter array), and a device whose metric card vanished mid-
    ///   session because of a truncated reply is a worse bug than one extra card.
    /// - A bitmap can never *add* a capability the family didn't list. A bit we mapped wrongly, or a
    ///   metric PulseLoop has no decoder for, therefore cannot conjure a UI surface out of nothing.
    func refinedCapabilities(bitmapDerived: Set<WearableCapability>) -> Set<WearableCapability> {
        capabilities.union(bitmapGatedCapabilities.intersection(bitmapDerived))
    }
}
