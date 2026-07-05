import SwiftUI

/// Activity Tracking detail screen: how workouts record — which sensors to capture, their poll cadence,
/// and GPS defaults. Backed by `WorkoutPrefsStore`; the recording services read these at use-time so
/// changes apply to the next workout.
struct WorkoutSettingsView: View {
    @State private var store = WorkoutPrefsStore.shared

    // Seconds. HR options span 15s spot cadence up to 5 min for the ring's background log.
    private let hrIntervals = [15, 30, 60, 120, 300]
    private let spo2Intervals = [120, 300, 600]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Sensors during workouts", action: nil)
                Text("Choose which sensors the ring reads while a workout is recording, and how often. "
                     + "More frequent reads give finer detail but use more battery.")
                    .font(.system(size: 12))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                toggleRow("Capture heart rate", isOn: Binding(
                    get: { store.settings.captureHeartRate },
                    set: { store.settings.captureHeartRate = $0 }
                ))
                if store.settings.captureHeartRate {
                    labeledRow("HR every") {
                        Picker("HR interval", selection: Binding(
                            get: { store.settings.hrPollIntervalSeconds },
                            set: { store.settings.hrPollIntervalSeconds = $0 }
                        )) {
                            ForEach(hrIntervals, id: \.self) { Text(intervalLabel($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(PulseColors.accent)
                    }
                }

                toggleRow("Capture blood oxygen (SpO₂)", isOn: Binding(
                    get: { store.settings.captureSpO2 },
                    set: { store.settings.captureSpO2 = $0 }
                ))
                if store.settings.captureSpO2 {
                    labeledRow("SpO₂ every") {
                        Picker("SpO2 interval", selection: Binding(
                            get: { store.settings.spo2PollIntervalSeconds },
                            set: { store.settings.spo2PollIntervalSeconds = $0 }
                        )) {
                            ForEach(spo2Intervals, id: \.self) { Text(intervalLabel($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(PulseColors.accent)
                    }
                }

                SectionHeader(title: "GPS", action: nil)
                toggleRow("Record GPS route by default", isOn: Binding(
                    get: { store.settings.useGpsByDefault },
                    set: { store.settings.useGpsByDefault = $0 }
                ))
                accuracyCard
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Activity Tracking")
    }

    private var accuracyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("GPS accuracy", selection: Binding(
                get: { store.settings.gpsAccuracy },
                set: { store.settings.gpsAccuracy = $0 }
            )) {
                ForEach(GpsAccuracy.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(store.settings.gpsAccuracy.blurb)
                .font(.caption)
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    /// "45s", "1 min", "1.5 min", "5 min" — never truncates, so 90s reads "1.5 min" instead of
    /// colliding with 60s on "1 min".
    private func intervalLabel(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = Double(seconds) / 60
        return minutes == minutes.rounded()
            ? "\(Int(minutes)) min"
            : String(format: "%.1f min", minutes)
    }

    // MARK: - Layout helpers (match the settings idiom)

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
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}
