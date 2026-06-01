import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var profiles: [UserProfile]
    @Binding var path: NavigationPath

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "Profile", action: nil)
                StatusCopy(title: "Name", body: profiles.first?.name ?? "Not set")

                SectionHeader(title: "Ring", action: nil)
                StatusCopy(title: "Status", body: ble.state.rawValue.capitalized)
                if ble.state == .connected {
                    StatusCopy(title: "Battery", body: ble.batteryPercent.map { "\($0)%" } ?? "--")
                    SecondaryButton(title: "Sync now", systemImage: "clock.arrow.circlepath") { coordinator.syncNow() }
                    SecondaryButton(title: "Find ring", systemImage: "bell.fill") { coordinator.findRing() }
                    SecondaryButton(title: "Disconnect", systemImage: "xmark.circle") { ble.disconnect() }
                } else {
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
                                    if ring.isLikelyRing {
                                        Text("SMART_RING").font(.caption2).foregroundStyle(PulseColors.accent)
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

                SectionHeader(title: "Tools", action: nil)
                PrimaryButton(title: "Debug", systemImage: "ladybug") {
                    path.append(AppRoute.debug)
                }
                SecondaryButton(title: "Component gallery", systemImage: "square.grid.2x2") {
                    path.append(AppRoute.componentGallery)
                }

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
    }
}
