import Foundation

/// Shared state for the Quick Connect auto-pairing popup. Mirrors `CoachNavigation`: a single
/// `@Observable` singleton that `MainTabView` observes to drive a bottom sheet.
///
/// While the app is foregrounded and NO ring is paired, `MainTabView` ambiently scans for rings
/// (see `RingBLEClient.startAmbientScan()`). When a close, known ring shows up, it sets `candidate`
/// + `isPresented` to slide up the "Is this your ring?" sheet. `dismissed` remembers the peripheral
/// UUIDs the user closed this session so we don't re-nag them for the same ring.
@MainActor
@Observable
final class QuickConnectNavigation {
    static let shared = QuickConnectNavigation()

    /// The ring currently offered in the popup.
    var candidate: RingBLEClient.DiscoveredRing?
    /// Drives the Quick Connect sheet.
    var isPresented = false
    /// Peripheral UUIDs the user dismissed this session — never re-offered until relaunch.
    var dismissed: Set<UUID> = []

    /// Offer a ring: stash it and present the sheet.
    func present(_ ring: RingBLEClient.DiscoveredRing) {
        candidate = ring
        isPresented = true
    }

    /// User closed the popup on this ring — remember it so we don't re-offer it, and dismiss.
    func dismiss(_ id: UUID) {
        dismissed.insert(id)
        isPresented = false
        candidate = nil
    }

    /// Just close the sheet (e.g. after a successful connect) without blocklisting the ring.
    func close() {
        isPresented = false
        candidate = nil
    }
}
