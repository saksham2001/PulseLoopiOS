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
            VStack(spacing: 16) {
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
        .navigationTitle("Measurement")
        .onAppear(perform: loadIfNeeded)
    }

    @ViewBuilder
    private var content: some View {
        SectionHeader(title: "Heart rate", action: nil)
        toggleRow("All-day heart rate", isOn: $hrEnabled)
        if hrEnabled {
            hrIntervalCard
        }

        SectionHeader(title: "Other vitals", action: nil)
        Text("These vitals are recorded in the background throughout the day. The ring doesn't expose a separate interval for them, so each is a simple on/off.")
            .font(.system(size: 12))
            .foregroundStyle(PulseColors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)

        if capabilities.contains(.spo2) { toggleRow("Blood oxygen (SpO₂)", isOn: $spo2Enabled) }
        if capabilities.contains(.stress) { toggleRow("Stress", isOn: $stressEnabled) }
        if capabilities.contains(.hrv) { toggleRow("HRV", isOn: $hrvEnabled) }
        if capabilities.contains(.temperature) { toggleRow("Skin temperature", isOn: $temperatureEnabled) }

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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Measure every").font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
                Spacer()
                Text("\(hrIntervalMinutes) min")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
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
        .padding(16)
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
