import SwiftUI
import SwiftData

/// Calibration detail screen (56ff/jring only). Two independent calibrations, both mirrored from the
/// Android port:
/// - **Blood pressure** — enter a reference cuff reading. It's pushed to the ring (`0x33`) so the ring
///   applies an on-device offset, and an app-side display offset is derived against a ring reading.
///   When the ring supports on-demand BP (`.manualBloodPressure`) we take that reading *during* save,
///   so the two values are from the same moment; otherwise we fall back to the last stored one.
/// - **Blood sugar** — the ring estimates glucose from your profile (no real sensor), so the only
///   calibration is an app-side offset: `offset = labReading − latestRaw`.
///
/// Capability-gated: only rings that declare `.bloodPressure` / `.bloodSugar` (the jring) reach here;
/// a defensive empty-state covers arriving without those capabilities (e.g. a Colmi).
struct CalibrationSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @State private var store = CalibrationStore.shared

    // Draft input fields.
    @State private var bpSystolicText = ""
    @State private var bpDiastolicText = ""
    @State private var glucoseRefText = ""
    @State private var bpStatus: String?
    @State private var glucoseStatus: String?
    @State private var loaded = false
    @State private var bpMeasuring = false
    /// When the ring last produced a blood-pressure reading, so the user can tell whether the offset
    /// we're about to derive is based on anything recent.
    @State private var bpLastMeasuredAt: Date?

    private var capabilities: Set<WearableCapability> {
        MetricsService.activeCapabilities(context: modelContext, ble: ble)
    }
    private var supportsBP: Bool { capabilities.contains(.bloodPressure) }
    private var supportsGlucose: Bool { capabilities.contains(.bloodSugar) }
    /// The ring can take a BP reading on demand, so calibration can measure first rather than lean on
    /// whatever reading happens to be stored.
    private var canMeasureBP: Bool {
        ble.state == .connected && capabilities.contains(.manualBloodPressure)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if supportsBP || supportsGlucose {
                    if supportsBP { bpSection }
                    if supportsGlucose { glucoseSection }
                    if ble.state != .connected {
                        Text("Not connected — calibration is saved and applied the next time your ring syncs.")
                            .font(.caption).foregroundStyle(PulseColors.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    SectionHeader(title: "Not available", action: nil)
                    StatusCopy(
                        title: "Unsupported on this ring",
                        body: "The connected device doesn't measure blood pressure or blood sugar, so there's nothing to calibrate."
                    )
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PulseColors.background)
        .pageChrome("Calibration")
        .onAppear(perform: loadIfNeeded)
    }

    // MARK: - Blood pressure

    @ViewBuilder
    private var bpSection: some View {
        SettingsGroup(
            header: "Blood pressure",
            footer: """
            Enter a reading from a cuff taken at the same time as a ring measurement. We send it to the \
            ring to correct its sensor and adjust the values shown here.
            """
        ) {
            numberRow("Reference systolic (mmHg)", text: $bpSystolicText)
            numberRow("Reference diastolic (mmHg)", text: $bpDiastolicText)
        }

        Text(bpLastMeasuredCopy)
            .font(.caption).foregroundStyle(PulseColors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)

        PrimaryButton(
            title: bpMeasuring ? "Measuring…" : "Calibrate blood pressure",
            systemImage: bpMeasuring ? "waveform.path.ecg" : "checkmark"
        ) {
            Task { await saveBP() }
        }
        .disabled(bpMeasuring)
        if store.settings.hasBPReference, !bpMeasuring {
            SecondaryButton(title: "Reset", systemImage: "arrow.counterclockwise") { resetBP() }
        }
        if let bpStatus {
            Text(bpStatus).font(.caption).foregroundStyle(PulseColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Last ring reading: 5 minutes ago" — or a nudge when we've never seen one.
    private var bpLastMeasuredCopy: String {
        guard let bpLastMeasuredAt else {
            return canMeasureBP
                ? "No ring reading yet. Calibrating will take one first."
                : "No ring reading yet. Connect your ring and take a measurement so the offset has something to correct."
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return "Last ring reading: \(relative.localizedString(for: bpLastMeasuredAt, relativeTo: Date()))."
    }

    // MARK: - Blood sugar

    @ViewBuilder
    private var glucoseSection: some View {
        SettingsGroup(
            header: "Blood sugar",
            footer: """
            The ring estimates blood sugar from your profile, not a real sensor. Enter a lab or meter \
            reading taken alongside a ring measurement to offset the displayed values.
            """
        ) {
            numberRow("Reference (mg/dL)", text: $glucoseRefText)
        }

        PrimaryButton(title: "Calibrate blood sugar", systemImage: "checkmark") { saveGlucose() }
        if store.settings.isGlucoseCalibrated {
            SecondaryButton(title: "Reset", systemImage: "arrow.counterclockwise") { resetGlucose() }
        }
        if let glucoseStatus {
            Text(glucoseStatus).font(.caption).foregroundStyle(PulseColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func numberRow(_ title: String, text: Binding<String>) -> some View {
        FormValueRow(title: title) {
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(PulseColors.textPrimary)
                .frame(maxWidth: 90)
        }
    }

    // MARK: - Load / save

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let s = store.settings
        if s.bpReferenceSystolic > 0 { bpSystolicText = "\(s.bpReferenceSystolic)" }
        if s.bpReferenceDiastolic > 0 { bpDiastolicText = "\(s.bpReferenceDiastolic)" }
        if s.glucoseRefMgdl > 0 { glucoseRefText = "\(Int(s.glucoseRefMgdl))" }
        refreshBPLastMeasuredAt()
    }

    private func refreshBPLastMeasuredAt() {
        bpLastMeasuredAt = MetricsRepository
            .latestMeasurement(kind: .bloodPressureSystolic, context: modelContext)?
            .timestamp
    }

    /// The app-side display offset is `reference − ringReading`, so it's only meaningful against a
    /// reading taken at the same time as the cuff. When the ring can measure on demand, take a fresh
    /// reading now instead of trusting whatever happens to be stored; otherwise fall back to the last
    /// stored one (and say so).
    private func saveBP() async {
        guard let sys = Int(bpSystolicText), let dia = Int(bpDiastolicText), sys > 0, dia > 0 else {
            bpStatus = "Enter both systolic and diastolic."
            return
        }
        guard sys > dia else {
            bpStatus = "Systolic must be higher than diastolic."
            return
        }

        var rawSys = MetricsService.latestRaw(kind: .bloodPressureSystolic, context: modelContext)
        var rawDia = MetricsService.latestRaw(kind: .bloodPressureDiastolic, context: modelContext)
        var measuredNow = false

        if canMeasureBP {
            bpMeasuring = true
            bpStatus = "Taking a ring reading — keep still…"
            // Use the returned pair rather than re-reading the store: persistence is batched, so the
            // new rows may not have been flushed yet.
            if let reading = await coordinator.measureBloodPressure() {
                rawSys = Double(reading.systolic)
                rawDia = Double(reading.diastolic)
                measuredNow = true
            }
            bpMeasuring = false
            refreshBPLastMeasuredAt()
        }

        store.calibrateBloodPressure(referenceSystolic: sys, referenceDiastolic: dia,
                                     latestRawSystolic: rawSys, latestRawDiastolic: rawDia)
        coordinator.applyBloodPressureCalibration()
        bpStatus = bpSaveStatus(measuredNow: measuredNow, hasRawReading: rawSys != nil && rawDia != nil)
    }

    private func bpSaveStatus(measuredNow: Bool, hasRawReading: Bool) -> String {
        guard ble.state == .connected else { return "Saved — will apply on next sync." }
        if measuredNow { return "Measured and calibrated. Sent to your ring." }
        if canMeasureBP { return "Couldn't get a ring reading. Calibration saved and sent, but the displayed offset uses your last reading." }
        if hasRawReading { return "Saved and sent to your ring." }
        return "Saved and sent to your ring — take a ring measurement to apply the displayed offset."
    }

    private func resetBP() {
        store.resetBloodPressure()
        bpSystolicText = ""; bpDiastolicText = ""
        bpStatus = "Calibration cleared."
    }

    private func saveGlucose() {
        guard let ref = Double(glucoseRefText), ref > 0 else {
            glucoseStatus = "Enter a reference reading."
            return
        }
        let latest = MetricsService.latestRaw(kind: .bloodSugar, context: modelContext)
        store.calibrateGlucose(referenceMgdl: ref, latestRawMgdl: latest)
        glucoseStatus = latest == nil ? "Saved — take a ring measurement to apply the offset." : "Calibration applied."
    }

    private func resetGlucose() {
        store.resetGlucose()
        glucoseRefText = ""
        glucoseStatus = "Calibration cleared."
    }
}
