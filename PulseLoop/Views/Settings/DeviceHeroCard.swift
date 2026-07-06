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
        let wearableModel = ble.activeWearableModel ?? WearableModel.model(id: device?.wearableModelID)
        let battery = ble.batteryPercent ?? device?.batteryPercent
        let status = DeviceHeroStatus.make(
            state: ble.state,
            connectedName: ble.state == .connected ? wearableModel?.displayName ?? ble.activeDeviceType?.displayName : nil,
            knownName: wearableModel?.displayName ?? deviceType?.displayName,
            batteryPercent: battery,
            lastSync: coordinator.lastSyncAt,
            now: Date()
        )

        // The connected card is purely informational and opens Wearable settings, where Disconnect
        // lives. Setup/reconnect remain available here only when the ring is not connected.
        VStack(spacing: 10) {
            Button { path.append(AppRoute.settingsWearable) } label: {
                HStack(alignment: .top, spacing: 16) {
                    RingArtView(
                        tint: PulseColors.info,
                        size: 72,
                        imageName: wearableModel?.imageName ?? ringImageName(for: deviceType)
                    )
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

                        if let syncText = status.syncText {
                            Text(syncText)
                                .font(.system(size: 12))
                                .foregroundStyle(PulseColors.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    VStack(alignment: .trailing, spacing: 14) {
                        if let batteryText = status.batteryText {
                            HStack(spacing: 4) {
                                Image(systemName: "battery.100")
                                Text(batteryText)
                            }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(PulseColors.success)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(PulseColors.success.opacity(0.12), in: Capsule())
                                .fixedSize()
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PulseColors.textMuted)
                            .frame(width: 20, height: 20)
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cardAccessibilityLabel(status))
            .accessibilityHint("Opens ring settings")

            if status.action != .disconnect {
                Button(action: { performAction(status.action) }) {
                    Text(status.actionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(status.actionEnabled ? PulseColors.accent : PulseColors.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            status.actionEnabled ? PulseColors.accent.opacity(0.12) : PulseColors.elevated,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!status.actionEnabled)
                .accessibilityLabel(status.actionTitle)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
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
        case .colmiR02: return nil
        case nil: return nil
        }
    }

}
