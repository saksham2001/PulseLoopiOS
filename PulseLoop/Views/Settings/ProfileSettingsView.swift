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

    // Apple Health profile import
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var importSucceeded = false

    private let validSexValues = ["female", "male", "other"]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ProfileEditorView(draft: $draft)

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

    /// Pull age / sex / height / weight from HealthKit into the editor's draft (canonical metric;
    /// the editor reformats to the chosen units). Name is intentionally skipped.
    private func importFromAppleHealth() {
        isImporting = true
        importMessage = nil
        Task { @MainActor in
            do {
                try await HealthSyncService.shared.requestAuthorization()
                let data = await HealthSyncService.shared.fetchUserProfileData()
                var imported = 0
                if let a = data.age { draft.age = a; imported += 1 }
                if let s = data.sex, validSexValues.contains(s) { draft.sex = s; imported += 1 }
                if let h = data.heightCm { draft.heightCm = h; imported += 1 }
                if let w = data.weightKg { draft.weightKg = w; imported += 1 }
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
        let profile: UserProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = UserProfile()
            modelContext.insert(profile)
        }
        draft.apply(to: profile)
        // Mirror the units preference into the app group so the Live Activity widget (which can't read
        // SwiftData) and model-layer helpers format distance/pace/temperature consistently.
        WorkoutAppGroup.useImperialUnits = (draft.units == .imperial)
        try? modelContext.save()
        coordinator.applyUserProfile()
        dismiss()
    }
}
