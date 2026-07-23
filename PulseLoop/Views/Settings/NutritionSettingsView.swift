import SwiftUI
import SwiftData

/// Settings → Nutrition: the master opt-in for calorie tracking plus its sub-settings.
/// Privacy-first — everything below the master toggle only appears once it's on, and the
/// footer states exactly where meal data lives and when it leaves the device.
struct NutritionSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var store = NutritionPrefsStore.shared
    @State private var healthStore = AppleHealthPrefsStore.shared

    private var prefs: Binding<NutritionPrefs> {
        Binding(get: { store.prefs }, set: { store.prefs = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsGroup(
                    footer: "Meals are stored only on this device. Nothing is shared unless you turn it on below."
                ) {
                    FormToggleRow(title: "Track nutrition", isOn: prefs.masterEnabled)
                }

                // Plain conditional reveal (the Coach settings idiom) — SettingsGroup already
                // paints its own glass, so no extra glass/materialize here (a second glass layer
                // rendered capsule artifacts over the groups on iOS 26 devices).
                if store.prefs.masterEnabled {
                    Group {
                        NutritionGoalsGroup()

                        SettingsGroup(
                            header: "Integrations",
                            footer: "Sharing with the coach adds your meals and goals to its context and check-ins. "
                                + "Apple Health export writes dietary energy and macros (requires Apple Health sync to be on)."
                        ) {
                            FormToggleRow(title: "Share meals with Coach", isOn: prefs.shareWithCoach)
                            if store.prefs.shareWithCoach {
                                FormToggleRow(title: "Mention in check-ins", isOn: prefs.includeInNotifications)
                                FormToggleRow(title: "Allow meal photo analysis", isOn: prefs.photoAnalysisEnabled)
                            }
                            FormToggleRow(
                                title: "Export to Apple Health",
                                isOn: Binding(
                                    get: { healthStore.prefs.syncNutrition },
                                    set: { healthStore.prefs.syncNutrition = $0 }
                                )
                            )
                        }

                        SettingsGroup(header: "Display") {
                            FormToggleRow(title: "Show on Today & widgets", isOn: prefs.showOnToday)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding()
            .padding(.bottom, PulseLayout.scrollBottomInset)
            .animation(.default, value: store.prefs.masterEnabled)
        }
        .background(PulseColors.background)
        .pageChrome("Nutrition")
        .pulseScrollEdges()
        .onChange(of: store.prefs.masterEnabled) { _, _ in
            // Tiles/cards/widgets gate on the master toggle — nudge dependents immediately.
            PulseDataChange.shared.notify()
        }
        .onChange(of: store.prefs.showOnToday) { _, _ in
            PulseDataChange.shared.notify()
        }
    }
}

/// Daily intake targets (kcal + macro grams), stored on `UserGoal` — the same row the coach's
/// `set_goal` tool writes. Values save immediately on change. A live helper line shows the
/// kcal implied by the macro split and offers a one-tap 30/40/30 rebalance when they drift.
private struct NutritionGoalsGroup: View {
    @Environment(\.modelContext) private var modelContext
    @State private var loaded = false
    @State private var kcal: Double = 0        // 0 = not set
    @State private var protein: Double = 0
    @State private var carbs: Double = 0
    @State private var fat: Double = 0

    /// kcal implied by the macro grams (4/4/9).
    private var macroKcal: Double { protein * 4 + carbs * 4 + fat * 9 }
    private var macrosSet: Bool { protein > 0 || carbs > 0 || fat > 0 }
    private var drifted: Bool {
        kcal > 0 && macrosSet && abs(macroKcal - kcal) / kcal > 0.05
    }

    var body: some View {
        SettingsGroup(
            header: "Daily targets",
            footer: "Set targets yourself, or ask the coach to suggest them from your profile and activity."
        ) {
            FormField {
                stepperRow("Calories", value: $kcal, range: 0...4500, step: 50,
                           format: { $0 == 0 ? "Not set" : "\(Int($0).formatted()) kcal" })
            }
            FormField {
                stepperRow("Protein", value: $protein, range: 0...300, step: 5,
                           format: { $0 == 0 ? "Not set" : "\(Int($0)) g" })
            }
            FormField {
                stepperRow("Carbs", value: $carbs, range: 0...500, step: 5,
                           format: { $0 == 0 ? "Not set" : "\(Int($0)) g" })
            }
            FormField {
                stepperRow("Fat", value: $fat, range: 0...200, step: 5,
                           format: { $0 == 0 ? "Not set" : "\(Int($0)) g" })
            }
            if kcal > 0 {
                FormField(padding: 12) {
                    HStack {
                        Text(helperText)
                            .font(PulseFont.caption.weight(.regular).monospacedDigit())
                            .foregroundStyle(drifted ? PulseColors.warning : PulseColors.textMuted)
                        Spacer()
                        if drifted || !macrosSet {
                            Button("Balance macros") { rebalance() }
                                .font(PulseFont.caption)
                                .foregroundStyle(PulseColors.accent)
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: kcal) { _, _ in save() }
        .onChange(of: protein) { _, _ in save() }
        .onChange(of: carbs) { _, _ in save() }
        .onChange(of: fat) { _, _ in save() }
    }

    private var helperText: String {
        guard macrosSet else { return "Macros not set" }
        return "Macros = \(Int(macroKcal).formatted()) kcal"
    }

    /// Redistribute the calorie goal across macros at 30% protein / 40% carbs / 30% fat.
    private func rebalance() {
        guard kcal > 0 else { return }
        protein = (kcal * 0.30 / 4).rounded()
        carbs = (kcal * 0.40 / 4).rounded()
        fat = (kcal * 0.30 / 9).rounded()
    }

    private func stepperRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                            step: Double, format: @escaping (Double) -> String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label).font(PulseFont.body).foregroundStyle(PulseColors.textPrimary)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(PulseFont.subheadline.monospacedDigit())
                    .foregroundStyle(value.wrappedValue == 0 ? PulseColors.textMuted : PulseColors.textSecondary)
            }
        }
        .tint(PulseColors.accent)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let goal = MetricsRepository.goals(context: modelContext)
        kcal = Double(goal?.intakeCalories ?? 0)
        protein = Double(goal?.intakeProteinG ?? 0)
        carbs = Double(goal?.intakeCarbsG ?? 0)
        fat = Double(goal?.intakeFatG ?? 0)
    }

    private func save() {
        guard loaded else { return }
        let goal = MetricsRepository.goals(context: modelContext) ?? {
            let g = UserGoal()
            modelContext.insert(g)
            return g
        }()
        goal.intakeCalories = kcal > 0 ? Int(kcal) : nil
        goal.intakeProteinG = protein > 0 ? Int(protein) : nil
        goal.intakeCarbsG = carbs > 0 ? Int(carbs) : nil
        goal.intakeFatG = fat > 0 ? Int(fat) : nil
        goal.updatedAt = Date()
        try? modelContext.save()
        PulseDataChange.shared.notify()
    }
}
