import SwiftUI
import SwiftData
import UIKit

/// Privacy & Data detail screen. Grouped iOS-style sections, each a single inset card of full-width
/// rows with a one-line description footer:
///   • Diagnostics — export a diagnostics bundle (leaves room for a future Import).
///   • App data — destructive reset/restore: unpair the ring, factory-reset app data, or both.
///   • Demo data — clear or reseed the local demo dataset.
/// Everything here is local and explicit, reflecting the app's transparency/privacy ethos.
struct PrivacyDataSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @State private var diagnosticsURL: URL?

    /// Which destructive App-data action is awaiting confirmation.
    @State private var pendingReset: ResetAction?

    private enum ResetAction: Identifiable {
        case unpairRing
        case resetAppData
        case unpairAndReset

        var id: Int { hashValue }

        var title: String {
            switch self {
            case .unpairRing:     return "Unpair ring?"
            case .resetAppData:   return "Reset app data?"
            case .unpairAndReset: return "Unpair ring & reset app data?"
            }
        }

        var message: String {
            switch self {
            case .unpairRing:
                return "Unpair your ring? The ring will forget this phone; your data stays."
            case .resetAppData:
                return "This permanently erases all your data — metrics, sleep, activity, coach history, settings, and saved API keys — and can't be undone."
            case .unpairAndReset:
                return "This unpairs your ring, then permanently erases all your data — metrics, sleep, activity, coach history, settings, and saved API keys — and can't be undone."
            }
        }

        /// Destructive-button label inside the confirmation dialog.
        var confirmLabel: String {
            switch self {
            case .unpairRing:     return "Unpair ring"
            case .resetAppData:   return "Reset app data"
            case .unpairAndReset: return "Unpair & reset"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(
                    header: "Diagnostics",
                    footer: "A local snapshot for troubleshooting — nothing leaves the device unless you share it."
                ) {
                    actionRow("Export diagnostics", systemImage: "square.and.arrow.up") {
                        diagnosticsURL = DiagnosticsExporter.exportFile(context: modelContext)
                    }
                }

                SettingsGroup(
                    header: "App data",
                    footer: "Unpair releases the ring for other apps and keeps your health data. Resetting erases everything on this device and returns the app to onboarding."
                ) {
                    actionRow("Unpair ring", systemImage: "wave.3.right.circle", tint: PulseColors.danger) {
                        pendingReset = .unpairRing
                    }
                    actionRow("Reset app data", systemImage: "trash", tint: PulseColors.danger) {
                        pendingReset = .resetAppData
                    }
                    actionRow("Unpair ring & reset app data", systemImage: "trash.slash", tint: PulseColors.danger) {
                        pendingReset = .unpairAndReset
                    }
                }

                SettingsGroup(
                    header: "Demo data",
                    footer: "Sample data for exploring the app without a ring."
                ) {
                    actionRow("Clear demo data", systemImage: "trash") {
                        SeedData.clearAll(modelContext)
                        let fresh = UserProfile()
                        fresh.onboardingCompleted = true
                        fresh.baselineCompleted = true
                        modelContext.insert(fresh)
                        try? modelContext.save()
                    }
                    actionRow("Reseed demo data", systemImage: "arrow.clockwise") {
                        SeedData.clearAll(modelContext)
                        SeedData.seedDemo(modelContext, completeOnboarding: true)
                    }
                }
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Privacy & Data")
        .sheet(item: $diagnosticsURL) { url in
            DiagnosticsShareSheet(items: [url])
        }
        .confirmationDialog(
            pendingReset?.title ?? "",
            isPresented: Binding(
                get: { pendingReset != nil },
                set: { if !$0 { pendingReset = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingReset
        ) { action in
            Button(action.confirmLabel, role: .destructive) {
                perform(action)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    // MARK: - Rows

    /// A flat, full-width settings row (icon + title) that runs `action`. No inner capsule — it sits
    /// directly inside `SettingsGroup`, which supplies the grouped glass surface + hairline dividers,
    /// so it matches the app's other grouped rows. `tint` colors both icon and title (danger for the
    /// destructive App-data actions).
    private func actionRow(
        _ title: String,
        systemImage: String,
        tint: Color = PulseColors.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(PulseFont.body)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .font(PulseFont.body)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reset actions

    private func perform(_ action: ResetAction) {
        switch action {
        case .unpairRing:
            ble.forget()
        case .resetAppData:
            resetAppData()
        case .unpairAndReset:
            // Unbind the ring FIRST so the UNBOND write goes out before the store is wiped.
            ble.forget()
            resetAppData()
        }
    }

    /// Factory reset: wipe SwiftData, the coach API keys in Keychain, and all UserDefaults, then reset the
    /// in-memory shared settings singletons so the wipe reflects without a relaunch. Clearing every
    /// `UserProfile` makes RootViews' `profiles` @Query empty, so it switches back to onboarding on its own.
    private func resetAppData() {
        // 1. All SwiftData model types (this removes UserProfile → RootViews returns to onboarding).
        SeedData.clearAll(modelContext)

        // 2. Coach API keys from the Keychain (survive UserDefaults wipe, so delete explicitly).
        try? OpenAIKeychainStore().deleteKey()
        try? GeminiKeychainStore().deleteKey()
        try? OpenRouterKeychainStore().deleteKey()
        try? MiniMaxKeychainStore().deleteKey()

        // 3. Wipe UserDefaults (metric prefs, coach settings, calibration, remembered ring, flags, …).
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // 4. Reset the in-memory shared settings singletons so the cleared state shows immediately
        //    (they cache their `settings` in memory; reassigning to `.default` re-persists the fresh
        //    defaults into the now-empty UserDefaults too).
        MetricPrefsStore.shared.settings = .default
        CoachSettingsStore.shared.settings = .default
        CalibrationStore.shared.settings = .default

        // 5. RootViews reacts to the emptied `profiles` @Query and swaps MainTabView → OnboardingFlowView,
        //    tearing down this pushed page automatically — no manual navigation needed. In DEBUG the
        //    `forceOnboarding` flag also gates onboarding, so re-arm it after the domain wipe cleared it.
        #if DEBUG
        UserDefaults.standard.set(true, forKey: "forceOnboarding")
        #endif
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Minimal UIKit share-sheet wrapper for exporting the diagnostics file.
struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
