import SwiftUI

/// Pure, view-agnostic description of the ring's state for the Settings hero card.
/// All branching lives here so `DeviceHeroCard` stays declarative and this stays unit-testable.
struct DeviceHeroStatus: Equatable {
    enum Action: Equatable {
        case disconnect
        case connect
        case setUp
        case pending // a connect attempt is in flight (connecting / reconnecting / scanning)
    }

    let title: String
    let statusLine: String
    let statusTint: Color
    let batteryText: String?
    let syncText: String?
    let action: Action

    var actionTitle: String {
        switch action {
        case .disconnect: return "Disconnect"
        case .connect: return "Connect"
        case .setUp: return "Set up a ring"
        case .pending: return "Connecting…"
        }
    }

    /// The action button is inert while a connection attempt is in flight, so a tap can't cancel or
    /// restart an in-progress (re)connect.
    var actionEnabled: Bool { action != .pending }

    /// `connectedName` reflects the live connection (nil unless connected); `knownName` is the
    /// last stored device (survives disconnect). Separating them distinguishes "known but
    /// disconnected" (`.connect`) from "never paired" (`.setUp`).
    static func make(
        state: RingConnectionState,
        connectedName: String?,
        knownName: String?,
        batteryPercent: Int?,
        lastSync: Date?,
        now: Date
    ) -> DeviceHeroStatus {
        let title = connectedName ?? knownName ?? "No ring connected"

        let statusLine: String
        let statusTint: Color
        switch state {
        case .connected:
            statusLine = "Connected"; statusTint = PulseColors.success
        case .connecting, .reconnecting:
            statusLine = "Connecting…"; statusTint = PulseColors.warning
        case .scanning:
            statusLine = "Searching…"; statusTint = PulseColors.warning
        case .failed:
            statusLine = "Connection failed"; statusTint = PulseColors.danger
        case .idle, .disconnected:
            statusLine = knownName == nil ? "No ring paired" : "Disconnected"
            statusTint = PulseColors.textSecondary
        }

        let batteryText = batteryPercent.map { "\(max(0, min(100, $0)))%" }

        let syncText: String?
        if let lastSync {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            syncText = "Synced " + formatter.localizedString(for: lastSync, relativeTo: now)
        } else {
            syncText = nil
        }

        let action: Action
        switch state {
        case .connected:
            action = .disconnect
        case .connecting, .reconnecting, .scanning:
            action = .pending
        case .idle, .disconnected, .failed:
            action = knownName != nil ? .connect : .setUp
        }

        return DeviceHeroStatus(
            title: title, statusLine: statusLine, statusTint: statusTint,
            batteryText: batteryText, syncText: syncText, action: action
        )
    }
}

/// Rich ring-connectivity card at the top of Settings. The card (or its trailing chevron) opens the
/// Wearable screen; a separate action button connects/disconnects/sets up. The two are distinct
/// controls so both are reachable by touch and VoiceOver.
struct DeviceHeroCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Binding var path: NavigationPath

    var body: some View {
        // One SwiftData read for the stored device, reused for name, battery, and art.
        let device = DeviceRepository.current(context: modelContext)
        let deviceType = ble.activeDeviceType ?? device?.deviceType
        let battery = ble.batteryPercent ?? device?.batteryPercent
        let status = DeviceHeroStatus.make(
            state: ble.state,
            connectedName: ble.state == .connected ? ble.activeDeviceType?.displayName : nil,
            knownName: deviceType?.displayName,
            batteryPercent: battery,
            lastSync: coordinator.lastSyncAt,
            now: Date()
        )

        // Three peer buttons (no nesting): the card body + the chevron navigate to Wearable settings;
        // the action button connects/disconnects. Peers, not nested, so a tap never double-fires.
        HStack(spacing: 12) {
            Button { path.append(AppRoute.settingsWearable) } label: {
                HStack(spacing: 16) {
                    RingArtView(tint: PulseColors.info, size: 72, imageName: ringImageName(for: deviceType))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(status.title)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(PulseColors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(status.statusLine)
                            .font(.system(size: 13))
                            .foregroundStyle(status.statusTint)
                            .lineLimit(1)

                        if let battery {
                            Text("Battery: \(max(0, min(100, battery)))%")
                                .font(.system(size: 13))
                                .foregroundStyle(PulseColors.textSecondary)
                                .lineLimit(1)
                        }

                        if let syncText = status.syncText {
                            Text(syncText)
                                .font(.system(size: 12))
                                .foregroundStyle(PulseColors.textSecondary)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cardAccessibilityLabel(status))
            .accessibilityHint("Opens ring settings")

            Button(action: { performAction(status.action) }) {
                Text(status.actionTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status.actionEnabled ? PulseColors.accent : PulseColors.textMuted)
                    .padding(.vertical, 13) // 44pt min touch target
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!status.actionEnabled)
            .accessibilityLabel(status.actionTitle)

            Button { path.append(AppRoute.settingsWearable) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(width: 20, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true) // decorative; the card body already provides this navigation
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private func cardAccessibilityLabel(_ status: DeviceHeroStatus) -> String {
        [status.title, status.statusLine, status.batteryText.map { "Battery \($0)" }, status.syncText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func performAction(_ action: DeviceHeroStatus.Action) {
        switch action {
        case .disconnect: ble.disconnect()
        case .connect: ble.connectLastKnown()
        case .setUp: path.append(AppRoute.pairing)
        case .pending: break
        }
    }

    /// Representative product image for the connected/known ring family (the connection only reveals
    /// the family, not the exact model); nil falls back to the generic ring in `RingArtView`.
    private func ringImageName(for type: RingDeviceType?) -> String? {
        switch type {
        case .jring: return "jring"
        case .colmiR02: return "colmi-r02"
        case nil: return nil
        }
    }

}
