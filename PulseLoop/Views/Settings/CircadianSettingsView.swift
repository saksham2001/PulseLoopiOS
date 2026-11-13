import SwiftUI

/// Settings → Circadian rhythm: the on/off switch for the Sleep-page tile, plus what goes on it.
///
/// Follows `NutritionSettingsView`'s rule: every group is ALWAYS rendered and gated with
/// `.disabled/.opacity`; nothing is conditionally inserted, because glass surfaces that
/// appear/disappear morph through capsule shapes on device.
struct CircadianSettingsView: View {
    @State private var store = CircadianPrefsStore.shared
    @State private var nutritionStore = NutritionPrefsStore.shared

    private var prefs: Binding<CircadianPrefs> {
        Binding(get: { store.prefs }, set: { store.prefs = $0 })
    }

    private var tileOn: Bool { store.prefs.enabled }
    private var nutritionOn: Bool { nutritionStore.prefs.masterEnabled }
    private var mealsOn: Bool { tileOn && nutritionOn && store.prefs.showMeals }
    private var customMeals: Bool { mealsOn && store.prefs.mealSelection == .manual }
    private var workoutsOn: Bool { tileOn && store.prefs.showWorkouts }

    private static let habitRule = "on 4 of the last 7 days, or 10 of the last 28"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(
                    footer: "A dial on the Sleep page showing when you usually wake, eat, train and go to bed, "
                        + "and how far the day or period you're viewing drifted from that. "
                        + "Wake and bedtime are always on it."
                ) {
                    FormToggleRow(title: "Show circadian rhythm", isOn: prefs.enabled)
                }

                mealsGroup
                workoutsGroup

                SettingsGroup(
                    header: "Your usual",
                    footer: "Each event's usual time is its average over the 30 days before the day or period "
                        + "you're viewing, or as many of those days as you've tracked. It needs at least 5 nights "
                        + "before it shows a comparison, and a missed night here and there doesn't reset it."
                ) {
                    FormValueRow(title: "Based on") {
                        Text("Previous 30 days")
                            .font(PulseFont.body)
                            .foregroundStyle(PulseColors.textSecondary)
                    }
                }
                .disabled(!tileOn)
                .opacity(tileOn ? 1 : 0.5)
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Circadian rhythm")
        .onChange(of: store.prefs) { _, _ in
            // The Sleep page gates and builds the tile from these — refresh it immediately.
            PulseDataChange.shared.notify()
        }
    }

    private var mealsGroup: some View {
        SettingsGroup(header: "Meals", footer: mealsFooter) {
            FormToggleRow(title: "Show meals", isOn: prefs.showMeals)
            FormMenuRow(title: "Which meals", value: store.prefs.mealSelection == .smart ? "Smart" : "Custom") {
                Picker("Which meals", selection: prefs.mealSelection) {
                    Text("Smart").tag(CircadianSelectionMode.smart)
                    Text("Custom").tag(CircadianSelectionMode.manual)
                }
            }
            .disabled(!mealsOn)
            .opacity(mealsOn ? 1 : 0.5)
            Group {
                FormToggleRow(title: "Breakfast", isOn: prefs.showBreakfast)
                FormToggleRow(title: "Lunch", isOn: prefs.showLunch)
                FormToggleRow(title: "Dinner", isOn: prefs.showDinner)
            }
            .disabled(!customMeals)
            .opacity(customMeals ? 1 : 0.5)
        }
        .disabled(!tileOn || !nutritionOn)
        .opacity(tileOn && nutritionOn ? 1 : 0.5)
    }

    private var mealsFooter: String {
        guard nutritionOn else {
            return "Meals come from nutrition tracking, which is off. Turn it on in Settings, under Nutrition."
        }
        return "Smart shows a meal only when you log it regularly: \(Self.habitRule). "
            + "Custom shows the meals you pick below. Snacks are never shown."
    }

    private var workoutsGroup: some View {
        SettingsGroup(
            header: "Workouts",
            footer: "A workout appears as a green band at the time you trained, with a runner for cardio or "
                + "weights for strength. Smart shows workouts only when you train regularly: \(Self.habitRule). "
                + "Always shows every workout."
        ) {
            FormToggleRow(title: "Show workouts", isOn: prefs.showWorkouts)
            FormMenuRow(title: "When", value: store.prefs.workoutSelection == .smart ? "Smart" : "Always") {
                Picker("When", selection: prefs.workoutSelection) {
                    Text("Smart").tag(CircadianSelectionMode.smart)
                    Text("Always").tag(CircadianSelectionMode.manual)
                }
            }
            .disabled(!workoutsOn)
            .opacity(workoutsOn ? 1 : 0.5)
        }
        .disabled(!tileOn)
        .opacity(tileOn ? 1 : 0.5)
    }
}
