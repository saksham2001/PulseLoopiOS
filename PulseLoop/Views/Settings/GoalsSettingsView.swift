import SwiftUI
import SwiftData

/// The Settings host for the same goal editor used during onboarding.
struct GoalsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Query private var goals: [UserGoal]
    @Query private var profiles: [UserProfile]

    @State private var draft = GoalDraft(units: .metric)
    @State private var loaded = false

    private var units: UnitsPreference { profiles.first?.units ?? ProfileDraft.preferredUnits(for: .current) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GoalEditorView(draft: $draft, units: units)
                PrimaryButton(title: "Save goals", systemImage: "checkmark", action: save)
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Goals")
        .onAppear(perform: loadIfNeeded)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        draft = GoalDraft(goal: goals.first, units: units)
    }

    private func save() {
        let goal: UserGoal
        if let existing = goals.first {
            goal = existing
        } else {
            goal = UserGoal()
            modelContext.insert(goal)
        }
        draft.apply(to: goal, units: units, includeWeeklyWorkouts: true)
        try? modelContext.save()
        coordinator.setGoal(steps: Int(draft.steps))
        dismiss()
    }
}
