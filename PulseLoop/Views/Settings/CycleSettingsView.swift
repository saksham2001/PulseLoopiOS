import SwiftUI
import SwiftData
import UserNotifications

/// Cycle-tracking settings: master switch (behind an explicit disclaimer), tracking goal,
/// hormonal-contraception flag, notifications, and the coach-sharing opt-in. Only reachable
/// when the paired ring measures temperature (`CycleService.isAvailable`).
struct CycleSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @State private var store = CycleSettingsStore.shared
    @State private var showDisclaimer = false
    @State private var notifPermissionDenied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Cycle tracking", action: nil)
                toggleRow("Track my cycle", isOn: Binding(
                    get: { store.isActive },
                    set: { setEnabled($0) }
                ))
                caption("Estimates cycle phases from the skin temperature your ring already measures during sleep. "
                    + "You only log period days — everything else is passive.")

                if store.isActive {
                    goalSection
                    notificationsSection
                    privacySection
                }

                SectionHeader(title: "About these estimates", action: nil)
                StatusCopy(title: "Not a medical device", body: Self.disclaimerText)
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Cycle")
        .sheet(isPresented: $showDisclaimer) {
            CycleDisclaimerSheet(
                onAccept: { goal, hormonal in
                    store.settings.goal = goal
                    store.settings.onHormonalContraception = hormonal
                    store.settings.disclaimerAcceptedAt = Date()
                    store.settings.enabled = true
                    ensureRingMeasuresTemperature()
                    requestNotificationPermission()
                },
                onCancel: { showDisclaimer = false }
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder private var goalSection: some View {
        SectionHeader(title: "Goal", action: nil)
        labeledRow("I'm tracking to") {
            Picker("Goal", selection: Binding(
                get: { store.settings.goal },
                set: { store.settings.goal = $0 }
            )) {
                ForEach(CycleGoal.allCases) { goal in
                    Text(goal.label).tag(goal)
                }
            }
            .pickerStyle(.menu)
            .tint(PulseColors.accent)
        }
        if store.settings.goal == .avoid {
            Text("Heads-up: PulseLoop shows a deliberately wider fertile window in this mode, "
                 + "but it is NOT a contraception method and must never be relied on as one.")
                .font(.caption).foregroundStyle(PulseColors.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }

        toggleRow("I use hormonal contraception", isOn: Binding(
            get: { store.settings.onHormonalContraception },
            set: { store.settings.onHormonalContraception = $0 }
        ))
        if store.settings.onHormonalContraception {
            caption("Hormonal contraception suppresses ovulation, so temperature analysis and fertility "
                + "estimates are hidden — period logging and the calendar stay available.")
        }
    }

    @ViewBuilder private var notificationsSection: some View {
        SectionHeader(title: "Notifications", action: nil)
        toggleRow("Ask on the predicted day", isOn: Binding(
            get: { store.settings.periodPromptEnabled },
            set: { store.settings.periodPromptEnabled = $0; CycleNotificationCenter.shared.scheduleNext() }
        ))
        caption("“Your period is due around today — has it started?” with a one-tap Yes that logs day 1 from the lock screen.")
        toggleRow("Heads-up 2 days before", isOn: Binding(
            get: { store.settings.preAlertEnabled },
            set: { store.settings.preAlertEnabled = $0; CycleNotificationCenter.shared.scheduleNext() }
        ))
        if notifPermissionDenied {
            Text("Notifications are disabled for PulseLoop in iOS Settings.")
                .font(.caption).foregroundStyle(PulseColors.danger)
        }
    }

    @ViewBuilder private var privacySection: some View {
        SectionHeader(title: "Privacy", action: nil)
        toggleRow("Share cycle data with the AI Coach", isOn: Binding(
            get: { store.settings.shareWithCoach },
            set: { store.settings.shareWithCoach = $0 }
        ))
        caption("Off by default. Cycle data stays on this device and is never included in coach requests "
            + "or diagnostics exports unless you turn this on.")
    }

    // MARK: - Actions

    private func setEnabled(_ on: Bool) {
        if on {
            // First enable (or re-enable) goes through the disclaimer, always.
            showDisclaimer = true
        } else {
            store.settings.enabled = false
            CycleNotificationCenter.shared.cancel()
        }
    }

    /// Cycle tracking is pointless with the ring's temperature sampling off — flip it on in
    /// the device config and push it, mirroring MeasurementSettingsView's save path.
    private func ensureRingMeasuresTemperature() {
        guard let device = DeviceRepository.current(context: modelContext) else { return }
        let config = MeasurementConfigRepository.configOrDefault(deviceId: device.id, context: modelContext)
        guard !config.temperatureEnabled else { return }
        config.temperatureEnabled = true
        MeasurementConfigRepository.save(config, context: modelContext)
        coordinator.applyMeasurementSettings()
    }

    private func requestNotificationPermission() {
        guard store.settings.periodPromptEnabled || store.settings.preAlertEnabled else { return }
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            notifPermissionDenied = !granted
            if granted { CycleNotificationCenter.shared.scheduleNext() }
        }
    }

    // MARK: - Layout helpers (match settings idiom)

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(PulseColors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

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

    static let disclaimerText = """
    PulseLoop estimates your cycle phases from the skin temperature measured by your ring. \
    These estimates are indicators, not certainties: their reliability depends on your sleep, \
    how the ring is worn, and your physiology. This feature is not a medical device, is not \
    clinically validated, and must never be used on its own as a contraception method or to \
    make medical decisions. Talk to a healthcare professional for any medical question. \
    PulseLoop's contributors accept no liability for how these estimates are used.
    """
}

/// The activation flow: disclaimer with explicit acceptance, tracking-goal choice, and the
/// hormonal-contraception question — asked once, editable later in settings.
struct CycleDisclaimerSheet: View {
    let onAccept: (CycleGoal, Bool) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var goal: CycleGoal = .understand
    @State private var hormonalContraception = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Before you start")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(PulseColors.textPrimary)

                Text(CycleSettingsView.disclaimerText)
                    .font(.system(size: 14))
                    .foregroundStyle(PulseColors.textSecondary)
                    .lineSpacing(4)

                VStack(alignment: .leading, spacing: 10) {
                    Text("I'm tracking to…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PulseColors.textPrimary)
                    ForEach(CycleGoal.allCases) { option in
                        goalOption(option)
                    }
                }

                if goal == .avoid {
                    Text("PulseLoop will show a deliberately wider fertile window, "
                         + "but it is NOT a contraception method. Never rely on it as one.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PulseColors.warning)
                }

                Toggle(isOn: $hormonalContraception) {
                    Text("I currently use hormonal contraception")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(PulseColors.textPrimary)
                }
                .tint(PulseColors.accent)

                PrimaryButton(title: "I understand — enable", systemImage: "checkmark") {
                    onAccept(goal, hormonalContraception)
                    dismiss()
                }
                SecondaryButton(title: "Cancel", systemImage: "xmark") {
                    onCancel()
                    dismiss()
                }
            }
            .padding(24)
        }
        .background(PulseColors.background)
        .presentationDetents([.large])
    }

    private func goalOption(_ option: CycleGoal) -> some View {
        Button {
            goal = option
        } label: {
            HStack {
                Image(systemName: goal == option ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(goal == option ? PulseColors.accent : PulseColors.textMuted)
                Text(option.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PulseColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(goal == option ? PulseColors.accent.opacity(0.6) : PulseColors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
