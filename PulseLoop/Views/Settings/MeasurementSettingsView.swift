import SwiftUI
import SwiftData

/// Measurement Frequency detail screen. Lets the user tune how often the ring measures HR (a real
/// interval, 5–60 min) and which background vitals it records. Persisted per device and pushed to the
/// ring on Save. Only shown for devices that declare `.measurementInterval` (Colmi); a defensive
/// empty-state covers the case of arriving here without that capability.
struct MeasurementSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator

    // Draft state — committed to the model only on Save.
    @State private var hrEnabled = true
    @State private var hrIntervalMinutes = 5
    @State private var spo2Enabled = true
    @State private var stressEnabled = true
    @State private var hrvEnabled = true
    @State private var temperatureEnabled = true
    @State private var loaded = false
    @State private var saveStatus: String?

    private var capabilities: Set<WearableCapability> {
        MetricsService.activeCapabilities(context: modelContext, ble: ble)
    }

    private var supportsInterval: Bool { capabilities.contains(.measurementInterval) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if supportsInterval {
                    content
                } else {
                    SectionHeader(title: "Not available", action: nil)
                    StatusCopy(
                        title: "Unsupported on this ring",
                        body: "The connected device doesn't support changing measurement frequency."
                    )
                }
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Measurement")
        .onAppear(perform: loadIfNeeded)
    }

    @ViewBuilder
    private var content: some View {
        SettingsGroup(header: "Heart rate") {
            FormToggleRow(title: "All-day heart rate", isOn: $hrEnabled)
            if hrEnabled {
                hrIntervalCard
            }
        }

        SettingsGroup(
            header: "Other vitals",
            footer: "These vitals are recorded in the background throughout the day. The ring doesn't expose a separate interval for them, so each is a simple on/off."
        ) {
            if capabilities.contains(.spo2) { FormToggleRow(title: "Blood oxygen (SpO₂)", isOn: $spo2Enabled) }
            if capabilities.contains(.stress) { FormToggleRow(title: "Stress", isOn: $stressEnabled) }
            if capabilities.contains(.hrv) { FormToggleRow(title: "HRV", isOn: $hrvEnabled) }
            if capabilities.contains(.temperature) { FormToggleRow(title: "Skin temperature", isOn: $temperatureEnabled) }
        }

        PrimaryButton(title: "Save & sync to ring", systemImage: "checkmark") { save() }

        if let saveStatus {
            Text(saveStatus).font(.caption).foregroundStyle(PulseColors.textMuted)
        } else if ble.state != .connected {
            Text("Not connected — changes will apply the next time your ring syncs.")
                .font(.caption).foregroundStyle(PulseColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hrIntervalCard: some View {
        FormField {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Measure every").font(PulseFont.subheadline).foregroundStyle(PulseColors.textPrimary)
                    Spacer()
                    Text("\(hrIntervalMinutes) min")
                        .font(PulseFont.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(PulseColors.accent)
                }
                Slider(
                    value: Binding(
                        get: { Double(hrIntervalMinutes) },
                        set: { hrIntervalMinutes = Int(($0 / 5).rounded()) * 5 }
                    ),
                    in: 5...60,
                    step: 5
                )
                .tint(PulseColors.accent)
                Text("More frequent readings give finer trends but use more battery.")
                    .font(.caption).foregroundStyle(PulseColors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Load / save

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let device = DeviceRepository.current(context: modelContext) else { return }
        let config = MeasurementConfigRepository.configOrDefault(deviceId: device.id, context: modelContext)
        hrEnabled = config.hrEnabled
        hrIntervalMinutes = config.hrIntervalMinutes
        spo2Enabled = config.spo2Enabled
        stressEnabled = config.stressEnabled
        hrvEnabled = config.hrvEnabled
        temperatureEnabled = config.temperatureEnabled
    }

    private func save() {
        guard let device = DeviceRepository.current(context: modelContext) else {
            saveStatus = "No device to save to."
            return
        }
        let config = MeasurementConfigRepository.configOrDefault(deviceId: device.id, context: modelContext)
        config.hrEnabled = hrEnabled
        config.hrIntervalMinutes = min(60, max(5, (hrIntervalMinutes / 5) * 5))
        config.spo2Enabled = spo2Enabled
        config.stressEnabled = stressEnabled
        config.hrvEnabled = hrvEnabled
        config.temperatureEnabled = temperatureEnabled
        MeasurementConfigRepository.save(config, context: modelContext)
        coordinator.applyMeasurementSettings()
        saveStatus = ble.state == .connected ? "Saved and sent to your ring." : "Saved — will apply on next sync."
    }
}
