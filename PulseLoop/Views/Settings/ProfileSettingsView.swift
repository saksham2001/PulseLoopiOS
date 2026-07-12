import SwiftUI
import SwiftData

/// The Settings host for the same compact profile editor used during onboarding.
struct ProfileSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var profiles: [UserProfile]

    @State private var draft = ProfileDraft()
    @State private var loaded = false
    @State private var importing = false
    @State private var importStatus: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ProfileEditorView(draft: $draft)
                appleHealthImport
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PulseColors.background)
        .pageChrome("Profile")
        .onAppear(perform: loadIfNeeded)
        // Autosave: every field edit persists immediately — no explicit Save step. Health-imported
        // values flow through the same `draft` bindings, so this also persists them.
        .onChange(of: draft) { _, _ in autosave() }
    }

    /// One-way import of age/sex/height/weight from Apple Health. This never writes to Health — the
    /// button only reads profile characteristics and drops them into the editor's `draft`, which the
    /// autosave `.onChange` above persists. Read authorization is invisible in HealthKit, so an empty
    /// result is reported as "nothing found / access may be off", never as an outright denial.
    @ViewBuilder private var appleHealthImport: some View {
        let available = HealthSyncService.shared.isAvailable
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(
                header: "Apple Health",
                footer: "Imports age, sex, height and weight. Nothing is written to Health from here."
            ) {
                FormField {
                    QuickActionButton(label: importing ? "Importing…" : "Import from Apple Health") {
                        importFromHealth()
                    }
                    .disabled(importing)
                    .opacity(importing ? 0.6 : 1)
                }
            }
            if let importStatus {
                Text(importStatus)
                    .font(.caption)
                    .foregroundStyle(PulseColors.textMuted)
                    .padding(.horizontal, 4)
            }
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
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

    private func importFromHealth() {
        importing = true
        importStatus = nil
        Task {
            do {
                try await HealthSyncService.shared.requestProfileReadAuthorization()
            } catch {
                importing = false
                importStatus = "Couldn't reach Apple Health."
                return
            }
            let data = await HealthSyncService.shared.fetchUserProfileData()
            var imported = 0
            if let age = data.age { draft.age = age; imported += 1 }
            if let sex = data.sex, ["female", "male", "other"].contains(sex) {
                draft.sex = sex
                imported += 1
            }
            if let heightCm = data.heightCm { draft.heightCm = heightCm; imported += 1 }
            if let weightKg = data.weightKg { draft.weightKg = weightKg; imported += 1 }
            importing = false
            importStatus = imported > 0
                ? "Imported \(imported) metric\(imported == 1 ? "" : "s")."
                : "No profile data found in Apple Health — it may be empty or access may be off."
        }
    }
}
