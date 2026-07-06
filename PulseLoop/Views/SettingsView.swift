import SwiftUI
import SwiftData

/// Top-level Settings: a hero ring-device card over five inset-grouped sections. Each row pushes a
/// focused detail screen via `AppRoute`; detail screens live under `Views/Settings/`.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @State private var coachStore = CoachSettingsStore.shared
    /// Unlocked by tapping the version 7× in About; shows the Developer row.
    @AppStorage("developerUnlocked") private var developerUnlocked = false
    @Binding var path: NavigationPath

    /// Capabilities of the live device (preferred) or the last stored device, used to decide whether
    /// device-specific rows appear.
    private var capabilities: Set<WearableCapability> {
        MetricsService.activeCapabilities(context: modelContext, ble: ble)
    }

    /// Provider-aware AI Coach summary. Local modes identify where inference runs; hosted
    /// providers show the selected model so stale settings cannot mislabel them as "Balanced".
    private var coachTrailing: String {
        guard coachStore.settings.coachMasterEnabled else { return "Off" }
        let settings = coachStore.settings
        switch settings.providerMode {
        case .offlineStub:
            return "Offline"
        case .appleOnDevice:
            return "Apple on-device"
        case .userOpenAIKey:
            return CoachModel(rawValue: settings.model)?.label ?? settings.model
        case .userGeminiKey:
            return GeminiModel(rawValue: settings.model)?.label ?? settings.model
        case .userOpenRouterKey:
            return OpenRouterModel(rawValue: settings.model)?.label ?? settings.openRouterModel
        case .userMiniMaxKey:
            return MiniMaxModel(rawValue: settings.model)?.label ?? settings.minimaxModel
        case .backendProxy:
            return "Backend proxy"
        }
    }

    private var notificationsTrailing: String {
        coachStore.settings.notificationsEnabled ? "On" : "Off"
    }

    var body: some View {
        let caps = capabilities // evaluate once (one device fetch) and share across sections
        ScrollView {
            VStack(spacing: 20) {
                DeviceHeroCard(path: $path)

                SettingsSection(title: "Device", rows: deviceRows(caps))
                SettingsSection(title: "AI Coach", rows: aiCoachRows)
                SettingsSection(title: "General", rows: generalRows)
                SettingsSection(title: "Metrics", rows: metricsRows)
                SettingsSection(title: "Resources", rows: resourcesRows(caps))
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Settings")
    }

    // MARK: - Rows

    private func deviceRows(_ caps: Set<WearableCapability>) -> [SettingsRowItem] {
        var rows: [SettingsRowItem] = []
        // Only rings that expose a configurable measurement interval (Colmi) declare
        // `.measurementInterval`, so the generic 56ff jring never shows this row.
        if caps.contains(.measurementInterval) {
            rows.append(SettingsRowItem(icon: "timer", tint: PulseColors.spo2, title: "Measurement Frequency") {
                path.append(AppRoute.settingsMeasurement)
            })
        }
        return rows
    }

    /// AI Coach and its notifications live together — the notifications screen only configures coach
    /// alerts, so it's a sub-feature of the coach, not a peer of the other General items.
    private var aiCoachRows: [SettingsRowItem] {
        var rows: [SettingsRowItem] = [
            SettingsRowItem(icon: "sparkles", tint: PulseColors.accent, title: "AI Coach", trailingValue: coachTrailing) {
                path.append(AppRoute.settingsCoach)
            }
        ]
        // Check-ins are a coach sub-feature — only show the row once the coach is on.
        if coachStore.settings.coachMasterEnabled {
            rows.append(SettingsRowItem(icon: "bell.badge", tint: PulseColors.warning, title: "Coach Check-Ins", trailingValue: notificationsTrailing) {
                path.append(AppRoute.settingsNotifications)
            })
        }
        return rows
    }

    private var generalRows: [SettingsRowItem] {
        [
            SettingsRowItem(icon: "person.crop.circle", tint: PulseColors.accent, title: "User Profile") {
                path.append(AppRoute.settingsProfile)
            },
            SettingsRowItem(icon: "lungs", tint: PulseColors.hrv, title: "Physiology") {
                path.append(AppRoute.settingsPhysiology)
            }
        ]
    }

    private var metricsRows: [SettingsRowItem] {
        [
            SettingsRowItem(icon: "circle.circle", tint: PulseColors.accent, title: "Today") {
                path.append(AppRoute.settingsToday)
            },
            SettingsRowItem(icon: "heart.text.square", tint: PulseColors.heartRate, title: "Vitals") {
                path.append(AppRoute.settingsVitals)
            },
            SettingsRowItem(icon: "figure.run", tint: PulseColors.success, title: "Activity Tracking") {
                path.append(AppRoute.settingsActivityTracking)
            },
            SettingsRowItem(icon: "target", tint: PulseColors.readiness, title: "Goals") {
                path.append(AppRoute.settingsGoals)
            }
        ]
    }

    private func resourcesRows(_ caps: Set<WearableCapability>) -> [SettingsRowItem] {
        var rows: [SettingsRowItem] = []
        // jring-only: only the 56ff jring measures BP / blood sugar, so Calibration hides otherwise.
        if caps.contains(.bloodPressure) || caps.contains(.bloodSugar) {
            rows.append(SettingsRowItem(icon: "slider.horizontal.3", tint: PulseColors.bloodPressure, title: "Calibration") {
                path.append(AppRoute.settingsCalibration)
            })
        }
        // Hidden until unlocked by tapping the version 7× in About (like Android's developer options).
        if developerUnlocked {
            rows.append(SettingsRowItem(icon: "ladybug", tint: PulseColors.danger, title: "Developer") {
                path.append(AppRoute.debug)
            })
        }
        rows.append(SettingsRowItem(icon: "lock.shield", tint: PulseColors.success, title: "Privacy & Data") {
            path.append(AppRoute.settingsPrivacyData)
        })
        rows.append(SettingsRowItem(icon: "info.circle", tint: PulseColors.textMuted, title: "About PulseLoop") {
            path.append(AppRoute.settingsAbout)
        })
        return rows
    }
}
