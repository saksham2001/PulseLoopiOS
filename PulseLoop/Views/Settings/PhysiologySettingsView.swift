import SwiftUI
import SwiftData

/// Physiology inputs that tune the vitals reference ranges (`VitalsThresholdEngine`). These are
/// optional refinements — the engine works with sensible defaults when nothing is set. Saving bumps
/// `UserProfile.updatedAt`, which the `VitalsStore` signature watches so cards re-interpret without a
/// new measurement.
struct PhysiologySettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    @State private var athleteMode = false
    @State private var altitudeText = ""
    @State private var betaBlockers: TriState = .unset
    @State private var lungCondition: TriState = .unset
    @State private var glucoseUnit: GlucoseUnit = .mgdl
    @State private var units: UnitsPreference = .metric
    @State private var loaded = false

    /// Beta-blocker / lung-condition answers are tri-state: the user may not have told us.
    private enum TriState: String, CaseIterable, Identifiable {
        case unset, no, yes
        var id: String { rawValue }
        var label: String { self == .unset ? "Not set" : (self == .yes ? "Yes" : "No") }
        var boolValue: Bool? { self == .unset ? nil : (self == .yes) }
        init(_ value: Bool?) { self = value == nil ? .unset : (value == true ? .yes : .no) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(
                    header: "Fitness",
                    footer: "Treats a low resting heart rate as a sign of fitness rather than a concern, and relaxes the low-HR threshold."
                ) {
                    FormToggleRow(title: "Athlete mode", isOn: $athleteMode)
                }

                SettingsGroup(
                    header: "Environment",
                    footer: "Above ~2000 m, normal blood-oxygen readings run lower. We use this to avoid false low-oxygen warnings."
                ) {
                    numberField(units == .metric ? "Typical altitude (m)" : "Typical altitude (ft)", text: $altitudeText)
                }

                SettingsGroup(
                    header: "Health context",
                    footer: "Optional. Both can change what's expected for your heart rate or oxygen, so we adjust labels instead of alarming."
                ) {
                    triStateRow("Beta-blockers", selection: $betaBlockers)
                    triStateRow("Known lung condition", selection: $lungCondition)
                }

                SettingsGroup(header: "Units") {
                    FormValueRow(title: "Glucose unit") {
                        Picker("Glucose unit", selection: $glucoseUnit) {
                            ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                PrimaryButton(title: "Save", systemImage: "checkmark") { save() }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PulseColors.background)
        .pageChrome("Physiology")
        .onAppear(perform: loadIfNeeded)
    }

    // MARK: - Cards

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        FormValueRow(title: title) {
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(PulseColors.textPrimary)
                .frame(maxWidth: 90)
        }
    }

    private func triStateRow(_ title: String, selection: Binding<TriState>) -> some View {
        FormValueRow(title: title) {
            Picker(title, selection: selection) {
                ForEach(TriState.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)
        }
    }

    // MARK: - Load / save

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let p = profiles.first else { return }
        units = p.units
        athleteMode = p.athleteMode
        betaBlockers = TriState(p.usesBetaBlockers)
        lungCondition = TriState(p.hasKnownLungCondition)
        glucoseUnit = p.preferredGlucoseUnit
        if let alt = p.altitudeMeters {
            altitudeText = units == .metric ? "\(Int(alt))" : "\(Int((alt / 0.3048).rounded()))"
        }
    }

    private func save() {
        let profile = profiles.first ?? {
            let fresh = UserProfile()
            modelContext.insert(fresh)
            return fresh
        }()
        profile.athleteMode = athleteMode
        profile.usesBetaBlockers = betaBlockers.boolValue
        profile.hasKnownLungCondition = lungCondition.boolValue
        profile.preferredGlucoseUnit = glucoseUnit
        // Altitude entered in display units; store canonical metres.
        if let entered = Double(altitudeText.trimmingCharacters(in: .whitespaces)), entered > 0 {
            profile.altitudeMeters = units == .metric ? entered : entered * 0.3048
        } else {
            profile.altitudeMeters = nil
        }
        profile.updatedAt = Date()
        try? modelContext.save()
        dismiss()
    }
}
