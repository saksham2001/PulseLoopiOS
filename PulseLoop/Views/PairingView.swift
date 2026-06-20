import SwiftUI

/// The dedicated, modern ring-pairing screen. Swipe a carousel of supported ring models (stylized
/// vector art + name), pick yours, then scan and connect to a matching nearby device. Reused in two
/// contexts: the onboarding pair step (with a "Skip for now") and pushed from Settings → "Add a ring".
///
/// All scan/discover/connect UI lives here so Settings stays a clean device card. Pairing logic is
/// just orchestration over `RingBLEClient`; the chosen model's `family` biases which discovered
/// device we surface/auto-connect, while `RingBLEClient.coordinators` still does the real matching.
struct PairingView: View {
    @Environment(RingBLEClient.self) private var ble

    /// Called once a ring is connected (onboarding finishes; Settings pops the route).
    var onConnected: (() -> Void)? = nil
    /// When set, shows a "Skip for now" action (onboarding only).
    var onSkip: (() -> Void)? = nil

    @State private var selectedIndex = 0
    @State private var isLooking = false
    @State private var didFireConnected = false

    private let models = WearableModel.catalog

    private var selectedModel: WearableModel { models[min(selectedIndex, models.count - 1)] }

    /// Discovered rings whose matched family equals the selected model's family (recognized first),
    /// falling back to all named devices if nothing matches yet so the user is never stuck.
    private var matchingRings: [RingBLEClient.DiscoveredRing] {
        let family = selectedModel.family
        let matches = ble.discovered.filter { $0.deviceType == family }
        return matches.isEmpty ? ble.discovered : matches
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                OnboardingHeader(
                    title: "Add your ring",
                    subtitle: "Swipe to find your model, then tap to connect. You can also explore first and pair later."
                )

                if !ble.isBluetoothReady {
                    bluetoothOffCard
                } else if ble.state == .connected {
                    connectedCard
                } else {
                    carousel
                    actionArea
                }

                if let error = ble.lastError, ble.state != .connected {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(PulseColors.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                if let onSkip, ble.state != .connected {
                    Button("Skip for now", action: onSkip)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(PulseColors.textMuted)
                        .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .background(PulseColors.background.ignoresSafeArea())
        .onChange(of: ble.state) { _, state in
            if state == .connected, !didFireConnected {
                didFireConnected = true
                isLooking = false
                onConnected?()
            }
        }
        .onDisappear { ble.stopScanning() }
    }

    // MARK: - Carousel

    private var carousel: some View {
        VStack(spacing: 12) {
            TabView(selection: $selectedIndex) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    VStack(spacing: 16) {
                        RingArtView(tint: model.tint)
                        Text(model.displayName)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(PulseColors.textPrimary)
                        Text(model.blurb)
                            .font(.system(size: 13))
                            .foregroundStyle(PulseColors.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: 320)
        }
        .onChange(of: selectedIndex) { _, _ in
            // Re-scan/filter as the user changes their selected model.
            if isLooking { ble.startScanning() }
        }
    }

    // MARK: - Action area (scan + discovered rings)

    @ViewBuilder
    private var actionArea: some View {
        if !isLooking {
            PrimaryButton(title: "This is my ring", systemImage: "dot.radiowaves.left.and.right") {
                isLooking = true
                ble.startScanning()
            }
            if ble.hasLastKnownRing && ble.state != .reconnecting {
                SecondaryButton(title: "Reconnect last ring", systemImage: "arrow.clockwise") {
                    ble.connectLastKnown()
                }
            }
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    if ble.state == .connecting || ble.state == .reconnecting {
                        ProgressView()
                        Text("Connecting…")
                    } else {
                        ProgressView()
                        Text("Looking for your \(selectedModel.displayName)…")
                    }
                }
                .font(.caption)
                .foregroundStyle(PulseColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(matchingRings) { ring in
                    Button {
                        ble.connect(to: ring.id)
                    } label: {
                        ringRow(ring)
                    }
                    .buttonStyle(.plain)
                }

                if matchingRings.isEmpty {
                    InlineEmptyState(
                        title: "No rings found yet",
                        message: "Wake the ring by tapping or moving it, and keep it close."
                    )
                }

                SecondaryButton(title: "Stop", systemImage: "stop.circle") {
                    isLooking = false
                    ble.stopScanning()
                }
            }
        }
    }

    private func ringRow(_ ring: RingBLEClient.DiscoveredRing) -> some View {
        HStack {
            Image(systemName: ring.isLikelyRing ? "circle.hexagongrid.circle.fill" : "dot.radiowaves.left.and.right")
                .foregroundStyle(ring.isLikelyRing ? PulseColors.accent : PulseColors.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(ring.name).font(.subheadline.weight(.medium)).foregroundStyle(PulseColors.textPrimary)
                if let type = ring.deviceType {
                    Text(type.displayName).font(.caption2).foregroundStyle(PulseColors.accent)
                }
            }
            Spacer()
            Text("\(ring.rssi) dBm")
                .font(.caption.monospacedDigit())
                .foregroundStyle(PulseColors.textMuted)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        .contentShape(Rectangle())
    }

    // MARK: - States

    private var connectedCard: some View {
        VStack(spacing: 16) {
            RingArtView(tint: selectedModel.tint, size: 140)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(PulseColors.success)
                Text("Connected to \(ble.activeDeviceType?.displayName ?? selectedModel.displayName)")
                    .font(.headline)
                    .foregroundStyle(PulseColors.textPrimary)
            }
            if let onSkip {
                PrimaryButton(title: "Continue", systemImage: "checkmark", action: onSkip)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var bluetoothOffCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 34))
                .foregroundStyle(PulseColors.textMuted)
            Text("Bluetooth is off")
                .font(.headline)
                .foregroundStyle(PulseColors.textPrimary)
            Text("Turn on Bluetooth to find and connect your ring.")
                .font(.subheadline)
                .foregroundStyle(PulseColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
