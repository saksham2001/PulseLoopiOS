import SwiftUI
import SwiftData

/// Goals detail screen: daily/weekly targets (steps, active minutes, sleep, workouts) edited with
/// sliders. Writes to the shared `UserGoal` model, so every consumer — the Today/Activity rings, the
/// step-bar goal lines, the Sleep goal marker, the Coach context, and notifications — picks the new
/// targets up automatically. The step goal is also pushed to the ring via the coordinator.
struct GoalsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Query private var goals: [UserGoal]
    @Query private var profiles: [UserProfile]

    @State private var steps: Double = 8000
    @State private var activeMinutes: Double = 60
    @State private var sleepHours: Double = 8
    @State private var workouts: Double = 4
    /// Distance goal edited in the user's display unit (km or mi); persisted as metres.
    @State private var distance: Double = 5
    @State private var calories: Double = 500
    @State private var loaded = false

    private var units: UnitsPreference { profiles.first?.units ?? .metric }
    private var distanceUnit: String { UnitsFormatter.distance(meters: 0, units: units).unit }
    private var metersPerUnit: Double { units == .metric ? 1000 : 1609.344 }
    private var distanceRange: ClosedRange<Double> { units == .metric ? 1...30 : 1...20 }

    /// Static config for one goal slider; the dynamic value/label come from bindings.
    private struct GoalSpec {
        let title: String
        let icon: String
        let tint: Color
        let range: ClosedRange<Double>
        let step: Double
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Daily targets", action: nil)
                sliderCard(
                    GoalSpec(title: "Steps", icon: "shoeprints.fill", tint: PulseColors.steps, range: 2000...20000, step: 500),
                    value: $steps, valueLabel: "\(Int(steps).formatted())"
                )
                sliderCard(
                    GoalSpec(title: "Distance", icon: "location.fill", tint: PulseColors.distance, range: distanceRange, step: 0.5),
                    value: $distance, valueLabel: String(format: "%.1f \(distanceUnit)", distance)
                )
                sliderCard(
                    GoalSpec(title: "Calories", icon: "flame.fill", tint: PulseColors.calories, range: 100...2000, step: 50),
                    value: $calories, valueLabel: "\(Int(calories)) cal"
                )
                sliderCard(
                    GoalSpec(title: "Active minutes", icon: "figure.walk", tint: PulseColors.readiness, range: 10...180, step: 5),
                    value: $activeMinutes, valueLabel: "\(Int(activeMinutes)) min"
                )
                sliderCard(
                    GoalSpec(title: "Sleep", icon: "moon.fill", tint: PulseColors.sleep, range: 5...10, step: 0.5),
                    value: $sleepHours, valueLabel: String(format: "%.1f h", sleepHours)
                )

                SectionHeader(title: "Weekly target", action: nil)
                sliderCard(
                    GoalSpec(title: "Workouts", icon: "figure.run", tint: PulseColors.success, range: 1...7, step: 1),
                    value: $workouts, valueLabel: "\(Int(workouts)) / week"
                )

                PrimaryButton(title: "Save goals", systemImage: "checkmark") { save() }
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Goals")
        .onAppear(perform: loadIfNeeded)
    }

    private func sliderCard(_ spec: GoalSpec, value: Binding<Double>, valueLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: spec.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(spec.tint)
                    .frame(width: 30, height: 30)
                    .background(spec.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(spec.title).font(.system(size: 15, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
                Spacer()
                Text(valueLabel)
                    .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(spec.tint)
            }
            Slider(value: value, in: spec.range, step: spec.step).tint(spec.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let goal = goals.first {
            steps = Double(goal.steps)
            activeMinutes = Double(goal.activeMinutes)
            sleepHours = Double(goal.sleepMinutes) / 60
            workouts = Double(goal.workoutsPerWeek)
            distance = (goal.distanceMeters / metersPerUnit * 10).rounded() / 10
            calories = Double(goal.calories)
        }
    }

    private func save() {
        let goal = goals.first ?? {
            let fresh = UserGoal()
            modelContext.insert(fresh)
            return fresh
        }()
        goal.activeMinutes = Int(activeMinutes)
        goal.sleepMinutes = Int(sleepHours * 60)
        goal.workoutsPerWeek = Int(workouts)
        goal.distanceMeters = distance * metersPerUnit
        goal.calories = Int(calories)
        goal.updatedAt = Date()
        try? modelContext.save()
        // Steps go through the coordinator so the goal also reaches the ring (and persists). It writes
        // the same `UserGoal`, so the save above + this keep one canonical row.
        coordinator.setGoal(steps: Int(steps))
        dismiss()
    }
}
