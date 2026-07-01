import SwiftUI
import SwiftData

/// Vitals & Display detail screen: choose which vitals appear across the app, and (Stage 4) how
/// detailed the charts are. Only metrics the current device *supports* are offered — you can never
/// "show" a vital the hardware can't produce.
struct VitalsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var store = MetricPrefsStore.shared

    /// Vitals that are meaningful to toggle, in display order. Each is shown only when the device
    /// supports it (capability gate).
    private let toggleable: [(metric: MetricKey, label: String, color: Color)] = [
        (.heartRate, "Heart rate", PulseColors.heartRate),
        (.spo2, "Blood oxygen", PulseColors.spo2),
        (.calories, "Calories", PulseColors.calories),
        (.stress, "Stress", PulseColors.stress),
        (.hrv, "HRV", PulseColors.hrv),
        (.temperature, "Skin temperature", PulseColors.temperature),
        // jring/56ff metrics — appear only when the connected ring declares the capability.
        (.bloodPressureSystolic, "Blood pressure", PulseColors.bloodPressure),
        (.bloodSugar, "Blood sugar", PulseColors.bloodSugar),
        (.fatigue, "Fatigue", PulseColors.fatigue),
    ]

    private var supported: [(metric: MetricKey, label: String, color: Color)] {
        toggleable.filter { MetricsService.supports($0.metric, context: modelContext) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Visible vitals", action: nil)
                Text("Hidden vitals are removed from the Today and Vitals screens. This doesn't stop the ring from collecting them — your data stays intact.")
                    .font(.system(size: 12))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(supported, id: \.metric) { item in
                    visibilityRow(item.metric, label: item.label, color: item.color)
                }

                SectionHeader(title: "Chart detail", action: nil)
                Text("When the ring measures often, charts can look busy. Smoother levels average nearby points into a cleaner line — this only changes the display, not your stored data.")
                    .font(.system(size: 12))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                resolutionCard
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Vitals & Display")
    }

    private var resolutionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Resolution", selection: Binding(
                get: { store.settings.resolution },
                set: { store.settings.resolution = $0 }
            )) {
                ForEach(GraphResolution.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(store.settings.resolution.blurb)
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
            get: { !store.isHidden(metric) },
            set: { store.setHidden(metric, !$0) }
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
