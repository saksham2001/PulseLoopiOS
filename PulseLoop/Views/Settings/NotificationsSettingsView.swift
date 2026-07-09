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
    /// Mirrors the raw `pulseloop.batteryalerts.enabled` default (absent = ON). Held in @State so the
    /// toggle refreshes reliably; seeded in `onAppear`.
    @State private var batteryAlertsEnabled = true

    private var coachEnabled: Bool { store.settings.coachMasterEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !coachEnabled {
                    StatusCopy(
                        title: "AI Coach is off",
                        body: "Enable the AI Coach to change these — daily check-ins are written by the coach from your recent trends."
                    )
                }

                notificationsControls
                    .disabled(!coachEnabled)
                    .opacity(coachEnabled ? 1 : 0.5)

                // Ring battery alerts are independent of the AI Coach — no LLM involved — so this
                // section sits outside the coach-gated block above.
                batteryAlertControls
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Coach Check-Ins")
        .onAppear {
            batteryAlertsEnabled = UserDefaults.standard.object(forKey: BatteryAlertMonitor.enabledKey) as? Bool ?? true
        }
    }

    @ViewBuilder private var batteryAlertControls: some View {
        SettingsGroup(
            header: "Ring battery alerts",
            footer: "Get a heads-up when your ring drops below 20% and 10%."
        ) {
            FormToggleRow(title: "Low battery notifications", isOn: Binding(
                get: { batteryAlertsEnabled },
                set: { setBatteryAlerts($0) }
            ))
        }
    }

    @ViewBuilder private var notificationsControls: some View {
        SettingsGroup(header: "Daily check-ins") {
            FormToggleRow(title: "Daily check-in notifications", isOn: Binding(
                get: { store.settings.notificationsEnabled },
                set: { setNotifications($0) }
            ))
            if store.settings.notificationsEnabled {
                FormValueRow(title: "Morning") { hourPicker(hourBinding(\.morningHour)) }
                FormValueRow(title: "Midday") { hourPicker(hourBinding(\.middayHour)) }
                FormValueRow(title: "Evening") { hourPicker(hourBinding(\.eveningHour)) }
            }
        }

        if store.settings.notificationsEnabled {
            QuickActionButton(label: "Send a test check-in now") { sendTestCheckin() }
            if let testStatus {
                Text(testStatus).font(.caption).foregroundStyle(PulseColors.textMuted)
                    .padding(.horizontal, 4)
            }

            // Proactive anomaly alerts — on-device only (free/private local
            // inference makes "watch the stream and speak up" practical).
            SettingsGroup(
                header: "Proactive alerts",
                footer: store.settings.providerMode == .appleOnDevice
                    ? "When something looks off (low SpO₂, short sleep), I'll send a calm heads-up — generated privately on your iPhone."
                    : "Requires the On-device (Apple) provider. Switch to it in AI Coach settings to enable."
            ) {
                FormToggleRow(title: "Anomaly heads-ups (on-device)", isOn: Binding(
                    get: { store.settings.proactiveAlertsEnabled },
                    set: { store.settings.proactiveAlertsEnabled = $0 }
                ))
            }
        }
        if notifPermissionDenied {
            Text("Notifications are disabled for PulseLoop in iOS Settings.")
                .font(.caption).foregroundStyle(PulseColors.danger)
                .padding(.horizontal, 4)
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

    /// Toggle ring battery alerts. Turning ON mirrors `setNotifications`: request authorization and, if
    /// refused, leave the toggle off + surface the denied hint. Turning OFF just writes false.
    private func setBatteryAlerts(_ on: Bool) {
        guard on else {
            batteryAlertsEnabled = false
            UserDefaults.standard.set(false, forKey: BatteryAlertMonitor.enabledKey)
            return
        }
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            batteryAlertsEnabled = granted
            UserDefaults.standard.set(granted, forKey: BatteryAlertMonitor.enabledKey)
            notifPermissionDenied = !granted
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

}
