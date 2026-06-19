import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var profiles: [UserProfile]
    @Binding var path: NavigationPath
    @State private var diagnosticsURL: URL?

    private var appVersionLabel: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var lastSyncedLabel: String {
        guard let date = coordinator.lastSyncAt else { return "Not yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Profile", action: nil)
                StatusCopy(title: "Name", body: profiles.first?.name ?? "Not set")

                SectionHeader(title: "Ring", action: nil)
                if ble.state == .connected {
                    StatusCopy(title: "Device", body: ble.activeDeviceType?.displayName ?? "Connected ring")
                    StatusCopy(title: "Battery", body: ble.batteryPercent.map { "\($0)%" } ?? "--")
                    StatusCopy(title: "Last synced", body: lastSyncedLabel)
                    SecondaryButton(title: "Sync now", systemImage: "clock.arrow.circlepath") { coordinator.syncNow() }
                    SecondaryButton(title: "Find ring", systemImage: "bell.fill") { coordinator.findRing() }
                    SecondaryButton(title: "Disconnect", systemImage: "xmark.circle") { ble.disconnect() }
                    SecondaryButton(title: "Forget ring", systemImage: "trash") { ble.forget() }
                } else {
                    StatusCopy(title: "Status", body: ble.state.rawValue.capitalized)
                    if ble.state == .scanning {
                        SecondaryButton(title: "Stop scanning", systemImage: "stop.circle") { ble.stopScanning() }
                    } else {
                        SecondaryButton(title: "Scan for ring", systemImage: "dot.radiowaves.left.and.right") { ble.startScanning() }
                    }
                    if ble.hasLastKnownRing && ble.state != .reconnecting {
                        SecondaryButton(title: "Reconnect last ring", systemImage: "arrow.clockwise") { ble.connectLastKnown() }
                    }
                    if ble.state == .scanning && ble.discovered.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Scanning… wake the ring by tapping or moving it.")
                                .font(.caption)
                                .foregroundStyle(PulseColors.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(ble.discovered) { ring in
                        Button {
                            ble.connect(to: ring.id)
                        } label: {
                            HStack {
                                Image(systemName: ring.isLikelyRing ? "circle.hexagongrid.circle.fill" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(ring.isLikelyRing ? PulseColors.accent : PulseColors.textMuted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ring.name).font(.subheadline.weight(.medium))
                                    if let type = ring.deviceType {
                                        Text(type.displayName).font(.caption2).foregroundStyle(PulseColors.accent)
                                    }
                                }
                                Spacer()
                                Text("\(ring.rssi) dBm")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(PulseColors.textMuted)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let error = ble.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(PulseColors.heartRate)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                CoachSettingsSection()

                SectionHeader(title: "About", action: nil)
                StatusCopy(title: "Version", body: appVersionLabel)
                SecondaryButton(title: "Export diagnostics", systemImage: "square.and.arrow.up") {
                    diagnosticsURL = DiagnosticsExporter.exportFile(context: modelContext)
                }

                #if DEBUG
                SectionHeader(title: "Developer", action: nil)
                PrimaryButton(title: "Debug feed", systemImage: "ladybug") {
                    path.append(AppRoute.debug)
                }
                SecondaryButton(title: "Component gallery", systemImage: "square.grid.2x2") {
                    path.append(AppRoute.componentGallery)
                }
                #endif

                SectionHeader(title: "Data", action: nil)
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
        .navigationTitle("Settings")
        .sheet(item: $diagnosticsURL) { url in
            DiagnosticsShareSheet(items: [url])
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Minimal UIKit share-sheet wrapper for exporting the diagnostics file.
private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
