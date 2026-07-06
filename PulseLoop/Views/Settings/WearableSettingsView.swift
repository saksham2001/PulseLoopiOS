import SwiftUI
import SwiftData

/// Wearable detail screen: connection state and the ring actions (sync / find / disconnect / forget /
/// pair). Relocated from the old flat `SettingsView` Ring section.
struct WearableSettingsView: View {
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var devices: [Device]
    @Binding var path: NavigationPath

    /// Colmi reports battery in-band (not via a GATT characteristic), so it lands on the persisted
    /// `Device` rather than `ble.batteryPercent`. Mirror the header's fallback so this never shows "--"
    /// when the header shows a value.
    private var batteryPercent: Int? { ble.batteryPercent ?? devices.first?.batteryPercent }
    private var wearableDisplayName: String {
        let storedModel = WearableModel.model(id: devices.first?.wearableModelID)
        return ble.activeWearableModel?.displayName
            ?? storedModel?.displayName
            ?? ble.activeDeviceType?.displayName
            ?? devices.first?.deviceType.displayName
            ?? "Connected ring"
    }

    /// `RelativeDateTimeFormatter` is expensive to allocate; reuse one instance instead of building
    /// a fresh formatter on every access.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var lastSyncedLabel: String {
        guard let date = coordinator.lastSyncAt else { return "Not yet" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if ble.state == .connected {
                    SectionHeader(title: "Connected ring", action: nil)
                    StatusCopy(title: "Device", body: wearableDisplayName)
                    StatusCopy(title: "Battery", body: batteryPercent.map { "\($0)%" } ?? "--")
                    StatusCopy(title: "Last synced", body: lastSyncedLabel)
                    SecondaryButton(title: "Sync now", systemImage: "clock.arrow.circlepath") { coordinator.syncNow() }
                    SecondaryButton(title: "Find ring", systemImage: "bell.fill") { coordinator.findRing() }
                    SecondaryButton(title: "Disconnect", systemImage: "xmark.circle") { ble.disconnect() }
                    SecondaryButton(title: "Forget ring", systemImage: "trash") { ble.forget() }
                } else {
                    SectionHeader(title: "No ring connected", action: nil)
                    StatusCopy(title: "Status", body: ble.state.rawValue.capitalized)
                    PrimaryButton(title: "Add a ring", systemImage: "plus.circle") {
                        path.append(AppRoute.pairing)
                    }
                    if ble.hasLastKnownRing && ble.state != .reconnecting {
                        SecondaryButton(title: "Reconnect last ring", systemImage: "arrow.clockwise") { ble.connectLastKnown() }
                        SecondaryButton(title: "Forget ring", systemImage: "trash") { ble.forget() }
                    }
                }
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Wearable")
    }
}
