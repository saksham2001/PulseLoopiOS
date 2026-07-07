import SwiftUI
import UIKit

/// The dedicated, modern ring-pairing screen. Swipe a carousel of supported ring models (stylized
/// vector art + name), pick yours, then scan and connect to a matching nearby device. Reused in two
/// contexts: the onboarding pair step (with a "Skip for now") and pushed from Settings → "Add a ring".
///
/// All scan/discover/connect UI lives here so Settings stays a clean device card. Pairing logic is
/// just orchestration over `RingBLEClient`; the chosen model's `family` biases which discovered
/// device we surface/auto-connect, while `RingBLEClient.coordinators` still does the real matching.
struct PairingView: View {
    @Environment(RingBLEClient.self) private var ble

    private var forcePairingUIForTesting: Bool {
        #if DEBUG
        #if targetEnvironment(simulator)
        UserDefaults.standard.bool(forKey: "forcePairingUI")
        #else
        false
        #endif
        #else
        false
        #endif
    }

    /// Called once a ring is connected (onboarding finishes; Settings pops the route).
    var onConnected: (() -> Void)?
    /// When set, shows a "Skip for now" action (onboarding only).
    var onSkip: (() -> Void)?

    init(onConnected: (() -> Void)? = nil, onSkip: (() -> Void)? = nil) {
        self.onConnected = onConnected
        self.onSkip = onSkip
    }

    @State private var selectedIndex = 0
    @State private var selectedBrand = Self.allBrandsTab
    @State private var isLooking = false
    @State private var didFireConnected = false
    @State private var connectedAppeared = false

    private static let allBrandsTab = "All"
    private let allModels = WearableModel.catalog
    /// Prepared when scanning starts so the success haptic fires promptly on connect. `@State` keeps
    /// one instance across re-renders so `prepare()` and the later `notificationOccurred` share it.
    @State private var successHaptic = UINotificationFeedbackGenerator()

    /// Brand tabs: "All" first, then each distinct brand alphabetically.
    private var brands: [String] {
        [Self.allBrandsTab] + Set(allModels.map(\.brand))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Models for the selected brand tab, sorted alphabetically by name.
    private var models: [WearableModel] {
        let scoped = selectedBrand == Self.allBrandsTab
            ? allModels
            : allModels.filter { $0.brand == selectedBrand }
        return scoped.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedModel: WearableModel {
        guard !models.isEmpty else { return .jring }
        return models[min(selectedIndex, models.count - 1)]
    }

    /// Discovered rings whose matched family equals the selected model's family (recognized first),
    /// falling back to all named devices if nothing matches yet so the user is never stuck.
    private var matchingRings: [RingBLEClient.DiscoveredRing] {
        let family = selectedModel.family
        let matches = ble.discovered.filter { $0.deviceType == family }
        return matches.isEmpty ? ble.discovered : matches
    }

    private var canUseBluetoothUI: Bool { ble.isBluetoothReady || forcePairingUIForTesting }
    private var showsActionFooter: Bool {
        guard ble.state != .connected else { return false }
        return isLooking ? onSkip != nil : (canUseBluetoothUI || onSkip != nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                OnboardingHeader(
                    title: "Add your ring",
                    subtitle: "Swipe to find your model, then tap to connect.\nYou can also explore first and pair later."
                )
                .frame(maxWidth: .infinity) // full-width anchor: forces the column full so the button
                                            // never hugs to the (variable-width) dot row

                if !ble.isBluetoothReady && !forcePairingUIForTesting {
                    bluetoothOffCard
                } else if ble.state == .connected {
                    connectedCard
                } else {
                    carousel
                    if isLooking { scanningArea }
                }

                if let error = ble.lastError,
                   ble.state != .connected,
                   !forcePairingUIForTesting {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(PulseColors.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

            }
            .padding(24)
            .containerRelativeFrame(.horizontal) // size the column to the screen exactly (not to its
                                                 // content), so the button is full-width on every tab
        }
        .scrollBounceBehavior(.basedOnSize) // static when it fits; scrolls only if content overflows
                                            // (small devices / scanning list) so nothing clips
        .background(PulseColors.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsActionFooter {
                OnboardingActionFooter { pairingFooterContent }
            }
        }
        .onChange(of: ble.state) { _, state in
            if state == .connected, !didFireConnected {
                didFireConnected = true
                isLooking = false
                successHaptic.notificationOccurred(.success) // §6 success haptic
                onConnected?()
            }
        }
        .onDisappear { isLooking = false; ble.stopScanning() } // reset so a re-appear doesn't show a frozen scan
    }

    // MARK: - Carousel

    private var carousel: some View {
        VStack(spacing: 12) {
            brandTabs

            TabView(selection: $selectedIndex) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    VStack(spacing: 16) {
                        RingArtView(tint: model.tint, imageName: model.imageName)
                        Text(model.displayName)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(PulseColors.textPrimary)
                        CapabilityChips(blurb: model.blurb) // §2 replaces blurb Text
                    }
                    .frame(maxWidth: .infinity) // constant page width so content doesn't drive reflow
                    .tag(index)
                    .accessibilityElement(children: .combine) // §2
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never)) // §2 Fix #2 — dots moved to modelDotRow
            .frame(height: 300) // §2 Fix #2
            .id(selectedBrand) // recreate on brand change so pages swap instantly (no page-slide)

            modelDotRow // §2 fixed-height dot area keeps layout stable across tabs
        }
        .onChange(of: selectedIndex) { _, _ in
            // Re-scan/filter as the user changes their selected model.
            if isLooking { ble.startScanning() }
        }
    }

    private var modelDotRow: some View {
        HStack(spacing: 6) {
            if models.count > 1 {
                ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                    Button {
                        selectedIndex = index
                    } label: {
                        Capsule()
                            .fill(selectedIndex == index ? PulseColors.accent : PulseColors.elevated)
                            .overlay(
                                Capsule().strokeBorder(PulseColors.borderStrong,
                                                       lineWidth: selectedIndex == index ? 0 : 1)
                            )
                            .frame(width: selectedIndex == index ? 20 : 6, height: 6)
                            .animation(.spring(response: 0.3), value: selectedIndex)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Page \(index + 1) of \(models.count): \(model.displayName)")
                }
            }
        }
        .frame(maxWidth: .infinity) // center dots; keep row from driving column width
        .frame(height: 44) // reserve a constant 44pt tappable dot area across every brand tab
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    /// Brand filter: centered when the pills fit on screen, horizontally scrollable when they don't.
    private var brandTabs: some View {
        ViewThatFits(in: .horizontal) {
            brandPillRow
            ScrollView(.horizontal, showsIndicators: false) { brandPillRow }
        }
        .frame(maxWidth: .infinity) // full width so the centered pill row stays centered and stable
        .sensoryFeedback(.selection, trigger: selectedBrand)
    }

    private var brandPillRow: some View {
        HStack(spacing: 8) {
            ForEach(brands, id: \.self) { brand in
                let isSelected = brand == selectedBrand
                Button {
                    // Switch brand without animating: prevents the TabView page-slide / reflow that
                    // read as the whole screen shifting right and back.
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        selectedBrand = brand
                        selectedIndex = 0
                    }
                    if isLooking { ble.startScanning() }
                } label: {
                    Text(brand)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : PulseColors.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(isSelected ? PulseColors.accent : PulseColors.card, in: Capsule())
                        .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: isSelected ? 0 : 1))
                        .animation(.spring(response: 0.25, dampingFraction: 0.82), value: selectedBrand)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Action area (scan + discovered rings)

    @ViewBuilder
    private var pairingFooterContent: some View {
        VStack(spacing: 10) {
            if !isLooking, canUseBluetoothUI {
                PrimaryButton(title: "Connect ring", systemImage: "dot.radiowaves.left.and.right") {
                    isLooking = true
                    successHaptic.prepare()
                    ble.startScanning()
                }
                if ble.hasLastKnownRing && ble.state != .reconnecting {
                    SecondaryButton(title: "Reconnect last ring", systemImage: "arrow.clockwise") {
                        ble.connectLastKnown()
                    }
                }
            }

            if let onSkip {
                SecondaryButton(title: "Skip for now", systemImage: "arrow.right", action: onSkip)
                Text("You can pair a ring later from Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(PulseColors.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var scanningArea: some View {
        VStack(spacing: 12) {
                HStack(spacing: 8) {
                    if ble.state == .connecting || ble.state == .reconnecting {
                        ProgressView()
                            .accessibilityLabel("Searching") // §4
                        Text("Connecting to \(selectedModel.displayName)…") // §4
                    } else {
                        ProgressView()
                            .accessibilityLabel("Searching") // §4
                        Text("Scanning for \(selectedModel.displayName)…") // §4
                    }
                }
                .font(.caption)
                .foregroundStyle(PulseColors.textMuted)
                .frame(maxWidth: .infinity, alignment: .center) // §4 centered

                ForEach(matchingRings) { ring in
                    Button {
                        ble.connect(to: ring.id, selectedModelID: selectedModel.id)
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
                    .padding(.top, 8) // §4
                }

                SecondaryButton(title: "Stop scanning", systemImage: "stop.circle") { // §4
                    isLooking = false
                    ble.stopScanning()
                }
        }
        .padding(16) // §4 card wrapper
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PulseColors.borderSubtle, lineWidth: 1)
        )
    }

    private func ringRow(_ ring: RingBLEClient.DiscoveredRing) -> some View {
        let signalLevel: String = ring.rssi >= -65 ? "Strong signal"
            : ring.rssi >= -80 ? "Medium signal"
            : "Weak signal"
        return HStack {
            Image(systemName: ring.isLikelyRing ? "circle.hexagongrid.circle.fill" : "dot.radiowaves.left.and.right")
                .foregroundStyle(ring.isLikelyRing ? PulseColors.accent : PulseColors.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(ring.name).font(.subheadline.weight(.medium)).foregroundStyle(PulseColors.textPrimary)
                if let type = ring.deviceType {
                    Text(WearableModel.model(id: ring.wearableModelID)?.displayName ?? type.displayName)
                        .font(.caption2)
                        .foregroundStyle(PulseColors.accent)
                }
            }
            Spacer()
            SignalStrengthDots(rssi: ring.rssi) // §5
                .accessibilityHidden(true) // §5 row provides spoken signal level
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(PulseColors.card)
        .overlay(alignment: .leading) { // §5 accent left-stripe for likely rings
            if ring.isLikelyRing {
                Rectangle()
                    .fill(PulseColors.accent)
                    .frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) // §5 clips stripe
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine) // §5
        .accessibilityLabel(Text( // §5 spoken label with signal level
            "\(ring.name)\(ring.deviceType.map { ", \($0.displayName)" } ?? ""), \(signalLevel)"
        ))
    }

    // MARK: - States

    private var connectedCard: some View {
        VStack(spacing: 16) {
            ZStack { // §6 success ring wraps RingArtView
                RingArtView(tint: selectedModel.tint, size: 140, imageName: selectedModel.imageName)
                Circle()
                    .strokeBorder(PulseColors.success, lineWidth: 2)
                    .frame(width: 152, height: 152)
                    .scaleEffect(connectedAppeared ? 1.0 : 0.7)
                    .opacity(connectedAppeared ? 1.0 : 0.0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6), value: connectedAppeared) // §6
            }
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(PulseColors.success)
                    .scaleEffect(didFireConnected ? 1.0 : 0.3) // §6 checkmark spring
                    .animation(.spring(response: 0.45, dampingFraction: 0.55), value: didFireConnected) // §6
                Text("Connected to \(ble.activeWearableModel?.displayName ?? ble.activeDeviceType?.displayName ?? selectedModel.displayName)")
                    .font(.headline)
                    .foregroundStyle(PulseColors.textPrimary)
            }
            if let onSkip {
                PrimaryButton(title: "Continue", systemImage: "checkmark", action: onSkip)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear {
            connectedAppeared = true // §6 triggers success ring scale/fade animation
        }
    }

    private var bluetoothOffCard: some View {
        VStack(spacing: 14) { // §6 spacing bumped to 14
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
            SecondaryButton(title: "Open Settings", systemImage: "gear") { // §6
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
