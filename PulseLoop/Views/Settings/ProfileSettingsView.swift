import SwiftUI
import SwiftData

/// The Settings host for the same compact profile editor used during onboarding.
struct ProfileSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var profiles: [UserProfile]

    @State private var draft = ProfileDraft()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ProfileEditorView(draft: $draft)
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PulseColors.background)
        .pageChrome("Profile")
        .onAppear(perform: loadIfNeeded)
        // Autosave: every field edit persists immediately — no explicit Save step.
        .onChange(of: draft) { _, _ in autosave() }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        // Assign the draft before flipping `loaded`, so the resulting onChange lands while
        // `loaded` is still false and autosave skips it (no write just from opening the screen).
        draft = ProfileDraft(profile: profiles.first)
        loaded = true
    }

    private func autosave() {
        guard loaded else { return }
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
    }
}
