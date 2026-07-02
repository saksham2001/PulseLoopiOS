import SwiftUI
import SwiftData

/// Top-level Settings: a categorized list. Each row pushes a focused detail screen via `AppRoute`,
/// replacing the old single flat scroll. Detail screens live under `Views/Settings/`.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Query private var profiles: [UserProfile]
    @Binding var path: NavigationPath

    /// Capabilities of the live device (preferred) or the last stored device, used to decide whether
    /// the device-specific "Measurement" entry should appear.
    private var capabilities: Set<WearableCapability> {
        MetricsService.activeCapabilities(context: modelContext, ble: ble)
    }

    private var profileSubtitle: String {
        profiles.first?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Set up your profile"
    }

    private var wearableSubtitle: String {
        ble.state == .connected
            ? (ble.activeDeviceType?.displayName ?? "Connected")
            : ble.state.rawValue.capitalized
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SettingsCategoryRow(
                    icon: "person.crop.circle",
                    tint: PulseColors.accent,
                    title: "User Profile",
                    subtitle: profileSubtitle
                ) { path.append(AppRoute.settingsProfile) }

                SettingsCategoryRow(
                    icon: "lungs",
                    tint: PulseColors.hrv,
                    title: "Physiology",
                    subtitle: "Athlete mode, altitude, and reference-range tuning"
                ) { path.append(AppRoute.settingsPhysiology) }

                SettingsCategoryRow(
                    icon: "bell.badge",
                    tint: PulseColors.warning,
                    title: "Notifications",
                    subtitle: "Daily check-ins and reminders"
                ) { path.append(AppRoute.settingsNotifications) }

                SettingsCategoryRow(
                    icon: "sparkles",
                    tint: PulseColors.accent,
                    title: "AI Coach",
                    subtitle: "Provider, model, key, and memory"
                ) { path.append(AppRoute.settingsCoach) }

                SettingsCategoryRow(
                    icon: "dot.radiowaves.left.and.right",
                    tint: PulseColors.info,
                    title: "Wearable",
                    subtitle: wearableSubtitle
                ) { path.append(AppRoute.settingsWearable) }

                SettingsCategoryRow(
                    icon: "circle.circle",
                    tint: PulseColors.accent,
                    title: "Today",
                    subtitle: "Which tiles to show and chart detail on Today"
                ) { path.append(AppRoute.settingsToday) }

                SettingsCategoryRow(
                    icon: "heart.text.square",
                    tint: PulseColors.heartRate,
                    title: "Vitals",
                    subtitle: "Which vitals to show and chart detail"
                ) { path.append(AppRoute.settingsVitals) }

                SettingsCategoryRow(
                    icon: "figure.run",
                    tint: PulseColors.success,
                    title: "Activity Tracking",
                    subtitle: "Workout sensors, cadence, and GPS"
                ) { path.append(AppRoute.settingsActivityTracking) }

                SettingsCategoryRow(
                    icon: "target",
                    tint: PulseColors.readiness,
                    title: "Goals",
                    subtitle: "Daily steps, sleep, activity, and weekly workouts"
                ) { path.append(AppRoute.settingsGoals) }

                // Device-specific: only rings that expose a configurable measurement interval (Colmi)
                // declare `.measurementInterval`, so the generic 56ff jring never shows this row.
                if capabilities.contains(.measurementInterval) {
                    SettingsCategoryRow(
                        icon: "timer",
                        tint: PulseColors.spo2,
                        title: "Measurement Frequency",
                        subtitle: "How often the ring measures vitals"
                    ) { path.append(AppRoute.settingsMeasurement) }
                }

                // Device-specific: only the 56ff jring measures BP / blood sugar (Colmi has neither
                // sensor and never declares these), so the calibration screen is jring-only.
                if capabilities.contains(.bloodPressure) || capabilities.contains(.bloodSugar) {
                    SettingsCategoryRow(
                        icon: "slider.horizontal.3",
                        tint: PulseColors.bloodPressure,
                        title: "Calibration",
                        subtitle: "Tune blood pressure and blood sugar accuracy"
                    ) { path.append(AppRoute.settingsCalibration) }
                }

                SettingsCategoryRow(
                    icon: "lock.shield",
                    tint: PulseColors.success,
                    title: "Privacy & Data",
                    subtitle: "Export, clear, and manage your data"
                ) { path.append(AppRoute.settingsPrivacyData) }

                #if DEBUG
                SettingsCategoryRow(
                    icon: "ladybug",
                    tint: PulseColors.danger,
                    title: "Developer",
                    subtitle: "Debug feed and component gallery"
                ) { path.append(AppRoute.debug) }
                #endif

                SettingsCategoryRow(
                    icon: "info.circle",
                    tint: PulseColors.textMuted,
                    title: "About",
                    subtitle: "Version and project info"
                ) { path.append(AppRoute.settingsAbout) }
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Settings")
    }
}

/// A single tappable category row: leading tinted icon, title + subtitle, trailing chevron.
struct SettingsCategoryRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(PulseColors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(PulseColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PulseColors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
