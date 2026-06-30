import SwiftUI
import UIKit

/// "Apple Health" block for `SettingsView`, shown above the AI Coach section.
/// Tapping **Apple Health** checks the connection: if already authorized it confirms
/// so, otherwise it presents the system Health Access sheet (read + write for every
/// metric the ring captures). **Sync workouts history** exports everything captured.
struct HealthSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var service = HealthSyncService.shared
    @State private var alert: HealthAlert?
    @State private var statusText = "—"

    var body: some View {
        Group {
            SectionHeader(title: "Apple Health", action: nil)
            StatusCopy(title: "Status", body: statusText)

            SecondaryButton(title: "Apple Health", systemImage: "heart.fill") {
                handleAppleHealthTap()
            }

            SecondaryButton(
                title: service.isSyncing ? "Syncing…" : "Sync workouts history",
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                syncHistory()
            }
            .disabled(service.isSyncing)

            if let result = service.lastResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: refreshStatus)
        .alert(
            alert?.title ?? "",
            isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
            presenting: alert
        ) { a in
            if a.showSettings {
                Button("Open Settings") { openSettings() }
            }
            Button("OK", role: .cancel) {}
        } message: { a in
            Text(a.message)
        }
    }

    // MARK: - Actions

    private func handleAppleHealthTap() {
        switch service.authState {
        case .unavailable:
            alert = HealthAlert(title: "Apple Health Unavailable",
                                message: "Apple Health isn't available on this device.")
        case .authorized:
            alert = HealthAlert(title: "Apple Health Connected",
                                message: "PulseLoop is connected to Apple Health and can read and write your ring's data. Use “Sync workouts history” to push everything captured.")
        case .denied:
            alert = HealthAlert(title: "Apple Health Access Off",
                                message: "Allow PulseLoop to read and write health data in the Health app (under Sharing → Apps & Services) or in system Settings → Health → Data Access & Devices.",
                                showSettings: true)
        case .notDetermined:
            Task {
                do {
                    try await service.requestAuthorization()
                    refreshStatus()
                    switch service.authState {
                    case .authorized:
                        alert = HealthAlert(title: "Apple Health Connected",
                                            message: "PulseLoop can now sync your ring data to Apple Health. Tap “Sync workouts history” to export everything captured.")
                    default:
                        alert = HealthAlert(
                            title: "Apple Health",
                            message: "You can change PulseLoop's access anytime in the Health app "
                                + "(under Sharing → Apps & Services) or in system Settings → "
                                + "Health → Data Access & Devices.",
                            showSettings: true)
                    }
                } catch {
                    alert = HealthAlert(title: "Apple Health", message: error.localizedDescription)
                }
            }
        }
    }

    private func syncHistory() {
        Task {
            await service.syncAll(context: modelContext, forceAll: true)
            refreshStatus()
            if service.authState == .denied {
                alert = HealthAlert(
                    title: "Apple Health Access Off",
                    message: "Allow PulseLoop to read and write health data in the Health app "
                        + "(under Sharing → Apps & Services) or in system Settings → "
                        + "Health → Data Access & Devices.",
                    showSettings: true)
            }
        }
    }

    private func refreshStatus() {
        switch service.authState {
        case .unavailable:   statusText = "Not available on this device"
        case .authorized:    statusText = "Connected — reading & writing ring data"
        case .denied:        statusText = "Access off (enable in Settings)"
        case .notDetermined: statusText = "Not connected"
        }
    }

    private func openSettings() {
        if let healthURL = URL(string: "x-apple-health://") {
            UIApplication.shared.open(healthURL) { success in
                if !success, let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }
}

private struct HealthAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var showSettings = false
}
