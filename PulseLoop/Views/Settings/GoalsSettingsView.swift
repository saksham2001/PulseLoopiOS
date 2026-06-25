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

    @State private var steps: Double = 8000
    @State private var activeMinutes: Double = 60
    @State private var sleepHours: Double = 8
    @State private var workouts: Double = 4
    @State private var loaded = false

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
                    GoalSpec(title: "Active minutes", icon: "flame.fill", tint: PulseColors.calories, range: 10...180, step: 5),
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
        goal.updatedAt = Date()
        try? modelContext.save()
        // Steps go through the coordinator so the goal also reaches the ring (and persists). It writes
        // the same `UserGoal`, so the save above + this keep one canonical row.
        coordinator.setGoal(steps: Int(steps))
        dismiss()
    }
}
