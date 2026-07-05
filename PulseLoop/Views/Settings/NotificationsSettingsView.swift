import SwiftUI
import SwiftData
import UserNotifications

/// Coach Check-Ins detail screen. Hosts the daily Coach check-in controls (enable, morning/evening
/// windows, test send). These depend on the AI Coach being enabled, so when it's off the controls are
/// shown disabled with a hint to turn the Coach on.
struct NotificationsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @State private var store = CoachSettingsStore.shared
    @State private var testStatus: String?
    @State private var notifPermissionDenied = false

    private var coachEnabled: Bool { store.settings.coachMasterEnabled }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Daily check-ins", action: nil)
                if !coachEnabled {
                    StatusCopy(
                        title: "AI Coach is off",
                        body: "Enable the AI Coach to change these — daily check-ins are written by the coach from your recent trends."
                    )
                }

                notificationsControls
                    .disabled(!coachEnabled)
                    .opacity(coachEnabled ? 1 : 0.5)
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Coach Check-Ins")
    }

    @ViewBuilder private var notificationsControls: some View {
        toggleRow("Daily check-in notifications", isOn: Binding(
            get: { store.settings.notificationsEnabled },
            set: { setNotifications($0) }
        ))

        if store.settings.notificationsEnabled {
            labeledRow("Morning") { hourPicker(hourBinding(\.morningHour)) }
            labeledRow("Midday") { hourPicker(hourBinding(\.middayHour)) }
            labeledRow("Evening") { hourPicker(hourBinding(\.eveningHour)) }
            QuickActionButton(label: "Send a test check-in now") { sendTestCheckin() }
            if let testStatus {
                Text(testStatus).font(.caption).foregroundStyle(PulseColors.textMuted)
            }

            // Proactive anomaly alerts — on-device only (free/private local
            // inference makes "watch the stream and speak up" practical).
            SectionHeader(title: "Proactive alerts", action: nil)
            toggleRow("Anomaly heads-ups (on-device)", isOn: Binding(
                get: { store.settings.proactiveAlertsEnabled },
                set: { store.settings.proactiveAlertsEnabled = $0 }
            ))
            Text(store.settings.providerMode == .appleOnDevice
                 ? "When something looks off (low SpO₂, short sleep), I'll send a calm heads-up — generated privately on your iPhone."
                 : "Requires the On-device (Apple) provider. Switch to it in AI Coach settings to enable.")
                .font(.caption).foregroundStyle(PulseColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
        if notifPermissionDenied {
            Text("Notifications are disabled for PulseLoop in iOS Settings.")
                .font(.caption).foregroundStyle(PulseColors.danger)
        }
    }

    // MARK: - Notification helpers (relocated from CoachSettingsSection)

    private func hourPicker(_ binding: Binding<Int>) -> some View {
        Picker("Hour", selection: binding) {
            ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
        }
        .pickerStyle(.menu)
        .tint(PulseColors.accent)
    }

    private func hourBinding(_ keyPath: WritableKeyPath<CoachSettings, Int>) -> Binding<Int> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0; CoachNotificationScheduler.shared.scheduleNext() }
        )
    }

    private func setNotifications(_ on: Bool) {
        guard on else {
            store.settings.notificationsEnabled = false
            CoachNotificationScheduler.shared.cancel()
            return
        }
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            store.settings.notificationsEnabled = granted
            notifPermissionDenied = !granted
            if granted { CoachNotificationScheduler.shared.scheduleNext() }
        }
    }

    private func sendTestCheckin() {
        testStatus = "Sending…"
        let service = CoachNotificationService(modelContext: modelContext, coordinator: coordinator)
        Task {
            let outcome = await service.runDueSlot(force: true)
            switch outcome {
            case .sent(let slot): testStatus = "Sent a \(slot.label.lowercased()) check-in."
            default: testStatus = "Couldn't send (\(outcome))."
            }
        }
    }

    // MARK: - Layout helpers (match CoachSettingsSection idiom)

    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
            Spacer()
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
        }
        .tint(PulseColors.accent)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}
