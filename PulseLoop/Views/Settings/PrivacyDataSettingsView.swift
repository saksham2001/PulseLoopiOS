import SwiftUI
import SwiftData
import UIKit

/// Privacy & Data detail screen: export diagnostics, and clear/reseed local data. Reflects the app's
/// transparency/privacy ethos — everything here is local and explicit.
struct PrivacyDataSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var diagnosticsURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StatusCopy(
                    title: "Local-first",
                    body: "Ring data is stored only on this device. Nothing is uploaded except a Coach question you choose to send."
                )

                SecondaryButton(title: "Export diagnostics", systemImage: "square.and.arrow.up") {
                    diagnosticsURL = DiagnosticsExporter.exportFile(context: modelContext)
                }

                SecondaryButton(title: "Clear demo data", systemImage: "trash") {
                    SeedData.clearAll(modelContext)
                    let fresh = UserProfile()
                    fresh.onboardingCompleted = true
                    fresh.baselineCompleted = true
                    modelContext.insert(fresh)
                    try? modelContext.save()
                }
                SecondaryButton(title: "Reseed demo data", systemImage: "arrow.clockwise") {
                    SeedData.clearAll(modelContext)
                    SeedData.seedDemo(modelContext, completeOnboarding: true)
                }
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Privacy & Data")
        .sheet(item: $diagnosticsURL) { url in
            DiagnosticsShareSheet(items: [url])
        }
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
