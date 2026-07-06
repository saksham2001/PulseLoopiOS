import SwiftUI

struct GoalEditorView: View {
    @Binding var draft: GoalDraft
    let units: UnitsPreference
    var includeWeeklyWorkouts = true

    private var distanceUnit: String { units == .metric ? "km" : "mi" }
    private var distanceRange: ClosedRange<Double> { units == .metric ? 1...30 : 1...20 }

    private struct GoalCardSpec {
        let title: String
        let icon: String
        let tint: Color
        let range: ClosedRange<Double>
        let step: Double
    }

    var body: some View {
        VStack(spacing: 16) {
            SectionHeader(title: "Daily targets", action: nil)
            goalCard(
                GoalCardSpec(
                    title: "Steps", icon: "shoeprints.fill", tint: PulseColors.steps,
                    range: 2_000...20_000, step: 500
                ),
                value: $draft.steps,
                label: "\(Int(draft.steps).formatted())"
            )
            goalCard(
                GoalCardSpec(
                    title: "Distance", icon: "location.fill", tint: PulseColors.distance,
                    range: distanceRange, step: 0.5
                ),
                value: $draft.distance,
                label: String(format: "%.1f %@", draft.distance, distanceUnit)
            )
            goalCard(
                GoalCardSpec(
                    title: "Calories", icon: "flame.fill", tint: PulseColors.calories,
                    range: 100...2_000, step: 50
                ),
                value: $draft.calories,
                label: "\(Int(draft.calories)) cal"
            )
            goalCard(
                GoalCardSpec(
                    title: "Active minutes", icon: "figure.walk", tint: PulseColors.readiness,
                    range: 10...180, step: 5
                ),
                value: $draft.activeMinutes,
                label: "\(Int(draft.activeMinutes)) min"
            )
            goalCard(
                GoalCardSpec(
                    title: "Sleep", icon: "moon.fill", tint: PulseColors.sleep,
                    range: 5...10, step: 0.5
                ),
                value: $draft.sleepHours,
                label: String(format: "%.1f h", draft.sleepHours)
            )

            if includeWeeklyWorkouts {
                SectionHeader(title: "Weekly target", action: nil)
                goalCard(
                    GoalCardSpec(
                        title: "Workouts", icon: "figure.run", tint: PulseColors.success,
                        range: 1...7, step: 1
                    ),
                    value: $draft.workouts,
                    label: "\(Int(draft.workouts)) / week"
                )
            }
        }
    }

    private func goalCard(
        _ spec: GoalCardSpec,
        value: Binding<Double>,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: spec.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(spec.tint)
                    .frame(width: 30, height: 30)
                    .background(spec.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(spec.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PulseColors.textPrimary)
                Spacer()
                Text(label)
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(spec.tint)
            }
            Slider(value: value, in: spec.range, step: spec.step)
                .tint(spec.tint)
                .accessibilityLabel(spec.title)
                .accessibilityValue(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PulseColors.borderSubtle, lineWidth: 1)
        )
    }
}
