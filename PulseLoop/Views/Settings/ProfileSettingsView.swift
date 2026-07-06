import SwiftUI
import SwiftData

/// The Settings host for the same compact profile editor used during onboarding.
struct ProfileSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    @State private var draft = ProfileDraft()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ProfileEditorView(draft: $draft)
                PrimaryButton(title: "Save profile", systemImage: "checkmark", action: save)
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PulseColors.background)
        .navigationTitle("Profile")
        .onAppear(perform: loadIfNeeded)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        draft = ProfileDraft(profile: profiles.first)
    }

    private func save() {
        let profile: UserProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = UserProfile()
            modelContext.insert(profile)
        }
        draft.apply(to: profile)
        try? modelContext.save()
        coordinator.applyUserProfile()
        dismiss()
    }
}
