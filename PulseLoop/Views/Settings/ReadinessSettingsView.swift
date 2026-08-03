import SwiftUI
import SwiftData

/// Settings → Readiness: the master toggle for the daily recovery score plus its sub-settings.
///
/// Structure mirrors `NutritionSettingsView` 1:1 — every group is ALWAYS rendered and gated with
/// `.disabled/.opacity` rather than conditionally inserted, because glass surfaces that appear and
/// disappear morph through capsule shapes on device.
///
/// Unlike nutrition, the master toggle defaults **on**: readiness adds no permission, no network
/// egress, and stores nothing the ring wasn't already collecting. See `ReadinessPrefsStore`.
struct ReadinessSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var store = ReadinessPrefsStore.shared

    private var prefs: Binding<ReadinessPrefs> {
        Binding(get: { store.prefs }, set: { store.prefs = $0 })
    }

    private var masterOn: Bool { store.prefs.masterEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(
                    footer: "A daily 0–100 recovery score from your overnight HRV, resting heart rate, sleep, skin temperature, and yesterday's activity. Computed entirely on this device."
                ) {
                    FormToggleRow(title: "Daily readiness score", isOn: prefs.masterEnabled)
                }

                SettingsGroup(header: "Display") {
                    FormToggleRow(title: "Show on Today & widgets", isOn: prefs.showOnToday)
                }
                .disabled(!masterOn)
                .opacity(masterOn ? 1 : 0.5)

                SettingsGroup(
                    header: "AI Coach",
                    footer: "The coach sees your score and which signals drove it, so it can explain a change rather than guess at one."
                ) {
                    FormToggleRow(title: "Share readiness with Coach", isOn: prefs.shareWithCoach)
                    FormToggleRow(title: "Mention in check-ins", isOn: prefs.includeInNotifications)
                        .disabled(!store.prefs.shareWithCoach)
                        .opacity(store.prefs.shareWithCoach ? 1 : 0.5)
                }
                .disabled(!masterOn)
                .opacity(masterOn ? 1 : 0.5)

                SettingsGroup(
                    footer: "Every contributor, weight, and threshold is documented — readiness is not a black box. See docs/project/readiness.md."
                ) {
                    EmptyView()
                }
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Readiness")
        .onChange(of: store.prefs.masterEnabled) { _, isOn in
            // Turning it on should not leave an empty tile until the next sync — score what's
            // already there. Backfill skips days already at the current algorithm version.
            if isOn {
                ReadinessService.backfill(days: 30, context: modelContext)
            }
            PulseDataChange.shared.notify()
        }
        .onChange(of: store.prefs.showOnToday) { _, _ in
            PulseDataChange.shared.notify()
        }
    }
}
