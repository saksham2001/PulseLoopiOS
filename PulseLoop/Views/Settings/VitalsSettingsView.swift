import SwiftUI
import SwiftData

/// Per-page metric visibility + chart-detail settings. The Today and Vitals pages each get their own
/// independent scope (`MetricScope`), so hiding a tile or coarsening a chart on one page never affects
/// the other. Only metrics the current device *supports* are offered — you can never "show" a vital
/// the hardware can't produce.
///
/// The two entry points below (`VitalsSettingsView`, `TodaySettingsView`) are thin wrappers that bind
/// this shared body to a scope and a scope-appropriate toggle list.
struct MetricPrefsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var store = MetricPrefsStore.shared

    let scope: MetricScope
    let navTitle: String
    /// Copy explaining what the visibility toggles affect on this page.
    let visibilityBlurb: String
    /// The toggles to offer, in display order. Each is shown only when the device supports it.
    let toggleable: [(metric: MetricKey, label: String, color: Color)]

    private var supported: [(metric: MetricKey, label: String, color: Color)] {
        toggleable.filter { MetricsService.supports($0.metric, context: modelContext) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Visible tiles", action: nil)
                Text(visibilityBlurb)
                    .font(.system(size: 12))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(supported, id: \.metric) { item in
                    visibilityRow(item.metric, label: item.label, color: item.color)
                }

                SectionHeader(title: "Chart detail", action: nil)
                Text("When the ring measures often, charts can look busy. Smoother levels average nearby points into a cleaner line — "
                     + "this only changes the display on this page, not your stored data.")
                    .font(.system(size: 12))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                resolutionCard
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle(navTitle)
    }

    private var resolutionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Resolution", selection: Binding(
                get: { store.resolution(for: scope) },
                set: { store.setResolution($0, for: scope) }
            )) {
                ForEach(GraphResolution.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(store.resolution(for: scope).blurb)
                .font(.caption)
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private func visibilityRow(_ metric: MetricKey, label: String, color: Color) -> some View {
        Toggle(isOn: Binding(
            get: { !store.isHidden(metric, scope: scope) },
            set: { store.setHidden(metric, !$0, scope: scope) }
        )) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
            }
        }
        .tint(PulseColors.accent)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

/// Vitals-page scope: which vitals appear on the Vitals screen + that page's chart detail.
struct VitalsSettingsView: View {
    var body: some View {
        MetricPrefsSettingsView(
            scope: .vitals,
            navTitle: "Vitals",
            visibilityBlurb: "Hidden vitals are removed from the Vitals screen. This doesn't stop the ring from collecting them — your data stays intact.",
            toggleable: [
                (.heartRate, "Heart rate", PulseColors.heartRate),
                (.spo2, "Blood oxygen", PulseColors.spo2),
                (.calories, "Calories", PulseColors.calories),
                (.stress, "Stress", PulseColors.stress),
                (.hrv, "HRV", PulseColors.hrv),
                (.temperature, "Skin temperature", PulseColors.temperature),
                (.bloodPressureSystolic, "Blood pressure", PulseColors.bloodPressure),
                (.bloodSugar, "Blood sugar", PulseColors.bloodSugar),
                (.fatigue, "Fatigue", PulseColors.fatigue),
            ]
        )
    }
}

/// Today-page scope: which tiles appear on the Today screen + that page's chart detail. Steps,
/// distance, and calories are collapsed into a single "Activity" tile (keyed on `.steps`), so they
/// aren't offered individually here.
struct TodaySettingsView: View {
    var body: some View {
        MetricPrefsSettingsView(
            scope: .today,
            navTitle: "Today",
            visibilityBlurb: "Choose which tiles appear on the Today screen. This only changes the Today layout — your data and the Vitals screen are unaffected.",
            toggleable: [
                (.steps, "Activity", PulseColors.steps),
                (.sleep, "Sleep", PulseColors.sleep),
                (.heartRate, "Heart rate", PulseColors.heartRate),
                (.spo2, "Blood oxygen", PulseColors.spo2),
                (.hrv, "HRV", PulseColors.hrv),
                (.temperature, "Skin temperature", PulseColors.temperature),
                (.stress, "Stress", PulseColors.stress),
                (.fatigue, "Fatigue", PulseColors.fatigue),
                (.bloodPressureSystolic, "Blood pressure", PulseColors.bloodPressure),
                (.bloodSugar, "Blood sugar", PulseColors.bloodSugar),
            ]
        )
    }
}
