import SwiftUI
import SwiftData

/// User Profile detail screen: editable name / age / sex / height / weight + units preference. Values
/// are stored canonically in metric on `UserProfile` (the ring's user-preferences command and the rest
/// of the app read metric); height/weight are entered in the chosen units and converted on save.
struct ProfileSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    @State private var name: String = ""
    @State private var age: Int = 30
    @State private var sex: String = "other"
    /// Canonical metric, updated from the text fields on save.
    @State private var heightCm: Double = 175
    @State private var weightKg: Double = 70
    /// What the user types for weight, in the displayed units.
    @State private var weightText: String = ""
    @State private var units: UnitsPreference = .metric
    @State private var loaded = false

    // Apple Health profile import
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var importSucceeded = false

    private let sexOptions: [(value: String, label: String)] = [
        ("female", "Female"), ("male", "Male"), ("other", "Other")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Identity", action: nil)
                fieldCard("Name") {
                    TextField("Your name", text: $name)
                        .textInputAutocapitalization(.words)
                        .foregroundStyle(PulseColors.textPrimary)
                        .multilineTextAlignment(.trailing)
                }

                fieldCard("Age") {
                    Picker("Age", selection: $age) {
                        ForEach(13...100, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(PulseColors.accent)
                }

                labeledCard("Sex") {
                    Picker("Sex", selection: $sex) {
                        ForEach(sexOptions, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .pickerStyle(.segmented)
                }

                SectionHeader(title: "Body metrics", action: nil)
                labeledCard(units == .metric ? "Height (cm)" : "Height (in)") {
                    Picker("Height", selection: heightSelection) {
                        ForEach(heightRange, id: \.self) { Text(heightLabel($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(PulseColors.accent)
                }
                numberCard(units == .metric ? "Weight (kg)" : "Weight (lb)", text: $weightText)

                SectionHeader(title: "Units", action: nil)
                labeledCard("Measurement units") {
                    Picker("Units", selection: $units) {
                        ForEach(UnitsPreference.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                SectionHeader(title: "Apple Health", action: nil)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Import age, sex, height, and weight directly from Apple Health. Name is not syncable due to privacy limits.")
                        .font(.system(size: 13))
                        .foregroundStyle(PulseColors.textSecondary)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SecondaryButton(
                        title: isImporting ? "Syncing…" : "Sync from Apple Health",
                        systemImage: "arrow.down.heart.fill"
                    ) { importFromAppleHealth() }
                    .disabled(isImporting)
                    if let importMessage {
                        Text(importMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(importSucceeded ? PulseColors.success : PulseColors.danger)
                    }
                }
                .padding(16)
                .background(PulseColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))

                PrimaryButton(title: "Save profile", systemImage: "checkmark") { save() }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PulseColors.background)
        .navigationTitle("Profile")
        .onAppear(perform: loadIfNeeded)
        // Reformat the weight field when the units toggle flips, so the number stays consistent.
        // (Height is a dropdown bound to canonical cm, so it converts automatically.)
        .onChange(of: units) { _, newUnits in
            commitWeightFromText(using: oldUnitsBeforeChange ?? newUnits)
            seedWeightText(for: newUnits)
        }
    }

    /// Captured just before `onChange(of: units)` fires so we can parse the still-displayed numbers in
    /// the *previous* unit system before reformatting them into the new one.
    @State private var oldUnitsBeforeChange: UnitsPreference?

    // MARK: - Number entry card

    private func numberCard(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(PulseColors.textPrimary)
                .frame(maxWidth: 90)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    // MARK: - Height picker (dropdown), Weight text entry

    /// Height is picked from a dropdown in whole cm (metric) or whole inches (imperial), stored as cm.
    private var heightRange: [Int] {
        units == .metric ? Array(120...220) : Array(48...87)   // 48–87 in ≈ 4'0"–7'3"
    }
    private var heightSelection: Binding<Int> {
        Binding(
            get: { units == .metric ? Int(heightCm.rounded()) : Int((heightCm / 2.54).rounded()) },
            set: { heightCm = units == .metric ? Double($0) : Double($0) * 2.54 }
        )
    }
    private func heightLabel(_ value: Int) -> String {
        guard units == .imperial else { return "\(value)" }
        let feet = value / 12
        let inches = value % 12
        return "\(value) (\(feet)'\(inches)\")"
    }

    // MARK: - Weight text ↔ canonical kg

    private func seedWeightText(for units: UnitsPreference) {
        oldUnitsBeforeChange = units
        weightText = UnitsFormatter.weight(kg: weightKg, units: units).value
    }

    /// Parse the weight text field (interpreted in `units`) back into canonical kg.
    private func commitWeightFromText(using units: UnitsPreference) {
        if let w = Double(weightText) {
            weightKg = units == .metric ? w : w / 2.2046226
        }
    }

    // MARK: - Load / save

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let profile = profiles.first {
            name = profile.name ?? ""
            age = profile.age ?? 30
            sex = profile.sex ?? "other"
            heightCm = profile.heightCm ?? 175
            weightKg = profile.weightKg ?? 70
            units = profile.units
        }
        seedWeightText(for: units)
    }

    /// Pull age / sex / height / weight from HealthKit into the editor's fields (canonical metric;
    /// the height picker and weight text reformat to the chosen units). Name is intentionally skipped.
    private func importFromAppleHealth() {
        isImporting = true
        importMessage = nil
        Task { @MainActor in
            do {
                try await HealthSyncService.shared.requestAuthorization()
                let data = await HealthSyncService.shared.fetchUserProfileData()
                var imported = 0
                if let a = data.age { age = a; imported += 1 }
                if let s = data.sex, sexOptions.contains(where: { $0.value == s }) { sex = s; imported += 1 }
                if let h = data.heightCm { heightCm = h; imported += 1 }
                if let w = data.weightKg { weightKg = w; seedWeightText(for: units); imported += 1 }
                isImporting = false
                importSucceeded = imported > 0
                importMessage = imported > 0
                    ? "Imported \(imported) metric\(imported == 1 ? "" : "s") from Apple Health."
                    : "No profile data was found in Apple Health."
            } catch {
                isImporting = false
                importSucceeded = false
                importMessage = "Health access denied or failed: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        commitWeightFromText(using: units)
        let profile = profiles.first ?? {
            let fresh = UserProfile()
            modelContext.insert(fresh)
            return fresh
        }()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = trimmed.isEmpty ? nil : trimmed
        profile.age = age
        profile.sex = sex
        profile.heightCm = heightCm
        profile.weightKg = weightKg
        profile.units = units
        profile.updatedAt = Date()
        // Mirror the units preference into the app group so the Live Activity widget (which can't read
        // SwiftData) and model-layer helpers format distance/pace/temperature consistently.
        WorkoutAppGroup.useImperialUnits = (units == .imperial)
        try? modelContext.save()
        // Push the refreshed profile (incl. units) to the connected ring's user-preferences.
        coordinator.applyUserProfile()
        // Pop back to the settings list to signal the save succeeded.
        dismiss()
    }

    // MARK: - Row builders (match CoachSettingsSection idiom)

    private func fieldCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        labeledCard(title, content: content)
    }

    private func labeledCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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
}
