import SwiftUI
import SwiftData

/// Calibration detail screen (56ff/jring only). Two independent calibrations, both mirrored from the
/// Android port:
/// - **Blood pressure** — enter a reference cuff reading. It's pushed to the ring (`0x33`) so the ring
///   applies an on-device offset, and an app-side display offset is derived against the latest raw BP.
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

    private var capabilities: Set<WearableCapability> {
        MetricsService.activeCapabilities(context: modelContext, ble: ble)
    }
    private var supportsBP: Bool { capabilities.contains(.bloodPressure) }
    private var supportsGlucose: Bool { capabilities.contains(.bloodSugar) }

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

        PrimaryButton(title: "Calibrate blood pressure", systemImage: "checkmark") { saveBP() }
        if store.settings.hasBPReference {
            SecondaryButton(title: "Reset", systemImage: "arrow.counterclockwise") { resetBP() }
        }
        if let bpStatus {
            Text(bpStatus).font(.caption).foregroundStyle(PulseColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
    }

    private func saveBP() {
        guard let sys = Int(bpSystolicText), let dia = Int(bpDiastolicText), sys > 0, dia > 0 else {
            bpStatus = "Enter both systolic and diastolic."
            return
        }
        let latestSys = MetricsService.latestRaw(kind: .bloodPressureSystolic, context: modelContext)
        let latestDia = MetricsService.latestRaw(kind: .bloodPressureDiastolic, context: modelContext)
        store.calibrateBloodPressure(referenceSystolic: sys, referenceDiastolic: dia,
                                     latestRawSystolic: latestSys, latestRawDiastolic: latestDia)
        coordinator.applyBloodPressureCalibration()
        bpStatus = ble.state == .connected ? "Saved and sent to your ring." : "Saved — will apply on next sync."
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
