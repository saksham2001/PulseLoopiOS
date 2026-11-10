import SwiftUI
import SwiftData

/// Measurement Frequency detail screen. Lets the user tune how often the ring measures HR (a real
/// interval: 5–60 min, or 30–120 min on YCBT rings — `RingDeviceType.heartRateIntervalRange`), how often
/// it measures SpO₂ where the ring takes a separate interval, and which background vitals it records. Persisted per device and pushed to the
/// ring on Save. Only shown for devices that declare `.measurementInterval` (Colmi, jring); a
/// defensive empty-state covers the case of arriving here without that capability.
///
/// Note: on the jring only the HR interval maps to a command — SpO₂/stress/HRV/temperature ride its
/// combined-sensor packet and its background log, with no per-metric opcode to switch them off, so
/// those toggles are inert there. On the TK5 the same is true of **stress alone**: the ring derives it
/// from the HRV sweep and files it in the body-data record, and the YCBT setting catalog has no stress
/// monitor key to toggle (SpO₂/HRV/temperature each do have one) — so YCBT rings don't offer it.
struct MeasurementSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator

    // Draft state — committed to the model only on Save.
    @State private var hrEnabled = true
    @State private var hrIntervalMinutes = 5
    @State private var spo2Enabled = true
    /// `0` = follow the heart-rate interval.
    @State private var spo2IntervalMinutes = 0
    @State private var stressEnabled = true
    @State private var hrvEnabled = true
    @State private var temperatureEnabled = true
    @State private var loaded = false
    @State private var saveStatus: String?

    private var capabilities: Set<WearableCapability> {
        MetricsService.activeCapabilities(context: modelContext, ble: ble)
    }

    private var supportsInterval: Bool { capabilities.contains(.measurementInterval) }

    private var deviceType: RingDeviceType? {
        ble.activeDeviceType ?? DeviceRepository.current(context: modelContext)?.deviceType
    }

    private var intervalRange: ClosedRange<Int> { deviceType?.heartRateIntervalRange ?? 5...60 }

    private var supportsSpO2Interval: Bool { deviceType?.supportsSeparateSpO2Interval == true }

    /// YCBT has no stress monitor command (stress is filed in the body-data record), so a toggle there
    /// would be a switch the ring never sees.
    private var offersStressToggle: Bool {
        capabilities.contains(.stress) && deviceType?.speaksYCBT != true
    }

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
            footer: supportsSpO2Interval
                ? "These vitals are recorded in the background throughout the day. Blood oxygen can run on its own interval; the rest follow heart rate, at most hourly."
                : "These vitals are recorded in the background throughout the day. The ring doesn't expose a separate interval for them, so each is a simple on/off."
        ) {
            if capabilities.contains(.spo2) {
                FormToggleRow(title: "Blood oxygen (SpO₂)", isOn: $spo2Enabled)
                if spo2Enabled && supportsSpO2Interval { spo2IntervalCard }
            }
            if offersStressToggle { FormToggleRow(title: "Stress", isOn: $stressEnabled) }
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
                    in: Double(intervalRange.lowerBound)...Double(intervalRange.upperBound),
                    step: 5
                )
                .tint(PulseColors.accent)
                Text("More frequent readings give finer trends but use more battery.")
                    .font(.caption).foregroundStyle(PulseColors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Blood oxygen's own interval. The bottom stop of the track is "follow heart rate" rather than an
    /// interval shorter than the ring honours; the top is 60 — no evidence past an hour on that key.
    private var spo2IntervalCard: some View {
        let followStop = intervalRange.lowerBound - 5
        return FormField {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Measure SpO₂").font(PulseFont.subheadline).foregroundStyle(PulseColors.textPrimary)
                    Spacer()
                    Text(spo2IntervalMinutes <= 0 ? "With heart rate" : "Every \(spo2IntervalMinutes) min")
                        .font(PulseFont.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(PulseColors.accent)
                }
                Slider(
                    value: Binding(
                        get: { Double(spo2IntervalMinutes <= 0 ? followStop : spo2IntervalMinutes) },
                        set: {
                            let stepped = Int(($0 / 5).rounded()) * 5
                            spo2IntervalMinutes = stepped < intervalRange.lowerBound ? 0 : min(60, stepped)
                        }
                    ),
                    in: Double(followStop)...60,
                    step: 5
                )
                .tint(PulseColors.accent)
                Text(spo2IntervalMinutes <= 0
                     ? "Follows the heart-rate interval, at most every 60 min. Each SpO₂ reading runs the red light, so a longer interval saves the most battery."
                     : "Each SpO₂ reading runs the red light, so a longer interval saves the most battery. Some rings keep SpO₂ on the heart-rate schedule regardless.")
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
        hrIntervalMinutes = Self.clamped(config.hrIntervalMinutes, to: intervalRange)
        spo2Enabled = config.spo2Enabled
        spo2IntervalMinutes = config.spo2IntervalMinutes <= 0
            ? 0 : Self.clamped(config.spo2IntervalMinutes, to: intervalRange.lowerBound...60)
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
        config.hrIntervalMinutes = Self.clamped(hrIntervalMinutes, to: intervalRange)
        config.spo2Enabled = spo2Enabled
        config.spo2IntervalMinutes = supportsSpO2Interval && spo2IntervalMinutes > 0
            ? Self.clamped(spo2IntervalMinutes, to: intervalRange.lowerBound...60) : 0
        config.stressEnabled = stressEnabled
        config.hrvEnabled = hrvEnabled
        config.temperatureEnabled = temperatureEnabled
        MeasurementConfigRepository.save(config, context: modelContext)
        coordinator.applyMeasurementSettings()
        saveStatus = ble.state == .connected ? "Saved and sent to your ring." : "Saved — will apply on next sync."
    }

    /// Snap down to the 5-minute grid, then into `range`.
    static func clamped(_ minutes: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, (minutes / 5) * 5))
    }
}
