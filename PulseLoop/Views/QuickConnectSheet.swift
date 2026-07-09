import SwiftUI
import UIKit

/// The Quick Connect bottom sheet: "Ring found nearby — is this your ring?" It shows the detected
/// ring's product art, resolved model name, its advertised Bluetooth name (e.g. "R09_AC03"), and a
/// signal-strength readout, then offers Connect / scan-for-others / Close.
///
/// iOS exposes NO MAC address, so identity is the advertised NAME + product image only — there is
/// deliberately no address shown. Connect calls the real `RingBLEClient.connect(to:selectedModelID:)`;
/// the sheet auto-dismisses once `ble.state == .connected`.
struct QuickConnectSheet: View {
    @Environment(RingBLEClient.self) private var ble
    @State private var quickConnect = QuickConnectNavigation.shared
    @State private var isConnecting = false
    @State private var showOthers = false
    @State private var successHaptic = UINotificationFeedbackGenerator()

    /// The ring being offered. Snapshotted from the nav state so the layout is stable even if
    /// `discovered` reshuffles underneath us.
    let candidate: RingBLEClient.DiscoveredRing

    /// Resolve the exact catalog model for the candidate (drives the image + display name). Falls back
    /// to the Colmi family when the advertisement didn't tag a device type.
    private var model: WearableModel? {
        WearableModel.resolve(
            advertisedName: candidate.name,
            selectedModelID: candidate.wearableModelID,
            family: candidate.deviceType ?? .colmiR02
        )
    }

    /// Other likely rings nearby (excluding the current candidate) for the "scan for others" list.
    private var otherRings: [RingBLEClient.DiscoveredRing] {
        ble.discovered.filter { $0.isLikelyRing && $0.id != candidate.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                RingArtView(tint: model?.tint ?? PulseColors.accent, size: 150, imageName: model?.imageName)

                VStack(spacing: 6) {
                    Text(model?.displayName ?? candidate.deviceType?.displayName ?? "Smart ring")
                        .font(PulseFont.numberL)
                        .foregroundStyle(PulseColors.textPrimary)
                    // The raw advertised Bluetooth name — the only stable, iOS-exposed identity.
                    Text(candidate.name)
                        .font(PulseFont.footnote.monospaced())
                        .foregroundStyle(PulseColors.textSecondary)
                    SignalStrengthDots(rssi: candidate.rssi)
                        .padding(.top, 2)
                }

                actionButtons

                if showOthers { othersList }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(PulseColors.background.ignoresSafeArea())
        .onChange(of: ble.state) { _, state in
            // Connected — celebrate and dismiss (persisting the ring stops the ambient scan upstream).
            if state == .connected {
                successHaptic.notificationOccurred(.success)
                quickConnect.close()
            }
        }
        .onAppear { successHaptic.prepare() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Ring found nearby")
                .font(PulseFont.footnote.weight(.semibold))
                .foregroundStyle(PulseColors.accent)
                .textCase(.uppercase)
            Text("Is this your ring?")
                .font(PulseFont.title3.weight(.semibold))
                .foregroundStyle(PulseColors.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            if isConnecting || ble.state == .connecting || ble.state == .reconnecting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting…")
                        .font(PulseFont.callout.weight(.semibold))
                        .foregroundStyle(PulseColors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
            } else {
                PrimaryButton(title: "Connect", systemImage: "dot.radiowaves.left.and.right") {
                    connect(candidate)
                }

                SecondaryButton(title: "Not this one — scan for others", systemImage: "magnifyingglass") {
                    withAnimation(.easeInOut(duration: 0.2)) { showOthers.toggle() }
                }

                SecondaryButton(title: "Close", systemImage: "xmark") {
                    quickConnect.dismiss(candidate.id)
                }
            }
        }
    }

    private var othersList: some View {
        VStack(spacing: 8) {
            if otherRings.isEmpty {
                InlineEmptyState(
                    title: "No other rings nearby",
                    message: "Wake another ring by tapping or moving it, and keep it close."
                )
            } else {
                ForEach(otherRings) { ring in
                    Button { connect(ring) } label: { otherRow(ring) }
                        .buttonStyle(.plain)
                }
            }
        }
        .pulseGlassContainer(spacing: 8) // discovered glass rows blend/morph together
    }

    private func otherRow(_ ring: RingBLEClient.DiscoveredRing) -> some View {
        let resolved = WearableModel.resolve(
            advertisedName: ring.name,
            selectedModelID: ring.wearableModelID,
            family: ring.deviceType ?? .colmiR02
        )
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(resolved?.displayName ?? ring.deviceType?.displayName ?? ring.name)
                    .font(PulseFont.subheadline.weight(.medium))
                    .foregroundStyle(PulseColors.textPrimary)
                Text(ring.name)
                    .font(PulseFont.caption2.monospaced())
                    .foregroundStyle(PulseColors.textMuted)
            }
            Spacer()
            SignalStrengthDots(rssi: ring.rssi)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .pulseGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(resolved?.displayName ?? ring.name), \(signalLabel(ring.rssi))"))
    }

    private func signalLabel(_ rssi: Int) -> String {
        rssi >= -65 ? "Strong signal" : rssi >= -80 ? "Medium signal" : "Weak signal"
    }

    /// Kick off a real connection to `ring` through the shared client.
    private func connect(_ ring: RingBLEClient.DiscoveredRing) {
        isConnecting = true
        let resolved = WearableModel.resolve(
            advertisedName: ring.name,
            selectedModelID: ring.wearableModelID,
            family: ring.deviceType ?? .colmiR02
        )
        ble.connect(to: ring.id, selectedModelID: resolved?.id)
    }
}
