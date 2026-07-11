import SwiftUI
import UIKit

/// The dedicated, modern ring-pairing screen. Swipe a carousel of supported ring models (product art,
/// name, capability chips, and a "Limited support" badge for experimental families), pick yours, then
/// scan and connect to a matching nearby device. Reused in two contexts: the onboarding pair step
/// (with a "Skip for now") and pushed from Settings → "Add a ring".
///
/// All scan/discover/connect UI lives here so Settings stays a clean device card. Pairing logic is
/// just orchestration over `RingBLEClient`; the chosen model's `family` biases which discovered
/// device we surface/auto-connect, while `RingBLEClient.coordinators` still does the real matching.
struct PairingView: View {
    @Environment(RingBLEClient.self) private var ble
    @Environment(\.dismiss) private var dismiss

    /// Pushed onto the Settings nav stack (no onboarding "Skip"): show our own glass
    /// back button and hide the system nav bar so it doesn't stack a second, empty
    /// header above the big "Add your ring" title.
    private var isPushed: Bool { onSkip == nil }

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
    /// The app variant the user picked, or nil while they haven't touched the picker — which is what
    /// lets the discovery hint supply the default without ever overriding a deliberate choice.
    @State private var pickedVariant: RingAppVariant?
    /// The ring the user last tapped, so the wrong-variant recovery can re-dial the same one.
    @State private var lastAttemptedRingID: UUID?

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

    // MARK: - App variant (which native app the selected ring shipped with)

    /// The app the *advertisement* hints at, from the family the scan tagged a discovered row with. Only
    /// ever a default: a QRing- and a SmartHealth-Colmi can advertise the identical local name, so the
    /// hint is provisional by construction (`ColmiSmartHealthCoordinator.Advertisement`) and the user's
    /// pick is the authority.
    private var hintedVariant: RingAppVariant? {
        ble.discovered.lazy.compactMap(\.deviceType).compactMap(selectedModel.variant(for:)).first
    }

    /// The card's current variant — what the picker shows and what the blurb/badge describe. Row-free:
    /// a *connect* resolves the variant against the tapped row instead (`connectingVariant(for:)`).
    /// nil for a single-firmware card (no picker, no override — auto-detection as before).
    private var effectiveVariant: RingAppVariant? {
        selectedModel.variant(picked: pickedVariant, rowFamily: nil, hinted: hintedVariant)
    }

    private var variantBinding: Binding<RingAppVariant> {
        Binding(
            get: { effectiveVariant ?? .qring },
            set: { pickedVariant = $0 }
        )
    }

    /// The app a tap on this row would connect as (see `WearableModel.variant(picked:rowFamily:hinted:)`).
    private func connectingVariant(for ring: RingBLEClient.DiscoveredRing) -> RingAppVariant? {
        selectedModel.variant(picked: pickedVariant, rowFamily: ring.deviceType, hinted: hintedVariant)
    }

    /// Connect to a tapped row, driving the app *that row* resolves to.
    ///
    /// The picker is parked on that same app first, so everything the screen then says about the attempt
    /// — the blurb, the "Limited support" badge, and the one-tap `variantRetry` — describes the driver
    /// actually in flight, rather than a hint that may have come from a different ring in the scan.
    private func connect(to ring: RingBLEClient.DiscoveredRing) {
        lastAttemptedRingID = ring.id
        let variant = connectingVariant(for: ring)
        pickedVariant = variant
        ble.connect(
            to: ring.id,
            selectedModelID: selectedModel.id,
            preferredFamily: selectedModel.preferredFamily(
                picked: variant,
                rowFamily: ring.deviceType,
                hinted: hintedVariant
            )
        )
    }

    /// Discovered rings whose matched family is one the selected model can resolve to (recognized
    /// first), falling back to all named devices if nothing matches yet so the user is never stuck.
    /// Matching on *every* family the card can be — not just its default — is what keeps a row the scan
    /// tagged `.colmiSmartHealth` visible under the Colmi card.
    private var matchingRings: [RingBLEClient.DiscoveredRing] {
        let families = selectedModel.families
        let matches = ble.discovered.filter { $0.deviceType.map(families.contains) ?? false }
        return matches.isEmpty ? ble.discovered : matches
    }

    private var canUseBluetoothUI: Bool { ble.isBluetoothReady || forcePairingUIForTesting }
    private var showsActionFooter: Bool {
        guard ble.state != .connected else { return false }
        return isLooking ? onSkip != nil : (canUseBluetoothUI || onSkip != nil)
    }

    var body: some View {
        content
            .background(PulseColors.background.ignoresSafeArea())
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

    /// Wraps the scroll content with a glass back button + hidden nav bar when pushed
    /// from Settings; onboarding (no nav stack) uses the bare scroll content.
    @ViewBuilder
    private var content: some View {
        if isPushed {
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(PulseFont.bodyEmphasis)
                            .foregroundStyle(PulseColors.textPrimary)
                            .frame(width: 36, height: 36)
                            .pulseGlass(Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 2)
                scrollContent
            }
            .toolbar(.hidden, for: .navigationBar)
            .enablesBackSwipe()
        } else {
            scrollContent
        }
    }

    private var scrollContent: some View {
        ScrollView {
            // Tight vertical rhythm so the whole picker — carousel *and* its scrub bar — clears the
            // pinned footer without scrolling. When it didn't, the scrub bar sat behind the footer,
            // whose glass sampled the accent thumb as a purple smear under "Connect ring".
            VStack(spacing: 16) {
                OnboardingHeader(
                    title: "Add your ring",
                    subtitle: "Swipe to find your model, then tap to connect."
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
                    VStack(spacing: 10) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(PulseColors.danger)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        variantRetry
                    }
                }

            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .containerRelativeFrame(.horizontal) // size the column to the screen exactly (not to its
                                                 // content), so the button is full-width on every tab
        }
        .scrollBounceBehavior(.basedOnSize) // static when it fits; scrolls only if content overflows
                                            // (small devices / scanning list) so nothing clips
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsActionFooter {
                OnboardingActionFooter { pairingFooterContent }
            }
        }
    }

    // MARK: - Carousel

    private var carousel: some View {
        VStack(spacing: 6) {
            brandTabs

            TabView(selection: $selectedIndex) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    // The picker only applies to the card in front; every other page shows its default.
                    let variant = model.id == selectedModel.id ? effectiveVariant : nil
                    VStack(spacing: 10) {
                        RingArtView(tint: model.tint, imageName: model.imageName)
                        Text(model.displayName)
                            .font(PulseFont.numberL)
                            .foregroundStyle(PulseColors.textPrimary)
                        SupportBadge(level: model.supportLevel(for: variant)) // nothing when fully supported
                        CapabilityChips(blurb: model.blurb(for: variant)) // §2 replaces blurb Text
                    }
                    .frame(maxWidth: .infinity) // constant page width so content doesn't drive reflow
                    .tag(index)
                    .accessibilityElement(children: .combine) // §2
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never)) // §2 Fix #2 — dots moved to modelDotRow
            // Hugs the tallest page (art + name + support badge + chips). Slack here shows up as dead
            // space between the chips and the scrub bar below, so keep it tight.
            .frame(height: 292)
            .id(selectedBrand) // recreate on brand change so pages swap instantly (no page-slide)

            modelDotRow // §2 fixed-height dot area keeps layout stable across tabs

            // Below the carousel, not on the page: the app variant is a property of the *selection*, and
            // pages that have no variants (jring, TK5) must not grow a gap where the picker would be.
            if !selectedModel.appVariants.isEmpty {
                AppVariantPicker(options: selectedModel.appVariants, selection: variantBinding)
                    .padding(.top, 2)
            }
        }
        .onChange(of: selectedIndex) { _, _ in
            // Re-scan/filter as the user changes their selected model.
            if isLooking { ble.startScanning() }
        }
        .onChange(of: selectedModel.id) { _, _ in
            // A different ring is a different question: drop the previous card's answer so the new one
            // starts from its own discovery hint.
            pickedVariant = nil
        }
    }

    /// Page position shown as a liquid-glass scroll bar: a faint glass track with an
    /// accent glass thumb that slides to the selected model and can be dragged to scrub.
    /// Scales to any catalog size — never clips or overflows like a per-model dot row.
    private var modelDotRow: some View {
        Group {
            if models.count > 1 {
                GlassScrollIndicator(count: models.count, index: $selectedIndex) {
                    if isLooking { ble.startScanning() } // re-filter scan as selection scrubs
                }
                .frame(maxWidth: 220)
                .accessibilityLabel("Model \(selectedIndex + 1) of \(models.count): \(selectedModel.displayName)")
            }
        }
        .frame(maxWidth: .infinity) // center the bar; keep it from driving column width
        .frame(height: 20)          // constant area across every brand tab; the bar centres inside it
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
                        .font(PulseFont.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? .white : PulseColors.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        // Selected = accent-tinted interactive glass; others = plain glass.
                        .pulseGlass(Capsule(), interactive: true, tint: isSelected ? PulseColors.accent : nil)
                        .animation(.spring(response: 0.25, dampingFraction: 0.82), value: selectedBrand)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
        }
        .padding(.horizontal, 2)
        .pulseGlassContainer(spacing: 8) // morph pills as the selection moves
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
                    .font(PulseFont.caption.weight(.regular))
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

                VStack(spacing: 8) {
                    ForEach(matchingRings) { ring in
                        Button {
                            connect(to: ring)
                        } label: {
                            ringRow(ring)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .pulseGlassContainer(spacing: 8) // discovered glass rows blend/morph together

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
        .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The wrong-pick escape hatch. A user-initiated connect that dies in `.failed` on a two-app card is,
    /// far more often than not, the other app's driver — the ring never answered because we were speaking
    /// the wrong protocol at it. One tap flips the picker and re-dials the same ring, which is the whole
    /// reason `RingBLEClient` bothers to time the attempt out instead of spinning forever.
    @ViewBuilder
    private var variantRetry: some View {
        if ble.state == .failed,
           let variant = effectiveVariant,
           let other = selectedModel.otherVariant(than: variant),
           let ringID = lastAttemptedRingID {
            SecondaryButton(title: "Try as \(other.displayName)", systemImage: "arrow.triangle.2.circlepath") {
                pickedVariant = other
                ble.connect(
                    to: ringID,
                    selectedModelID: selectedModel.id,
                    preferredFamily: selectedModel.family(for: other)
                )
            }
        }
    }

    private func ringRow(_ ring: RingBLEClient.DiscoveredRing) -> some View {
        let signalLevel: String = ring.rssi >= -65 ? "Strong signal"
            : ring.rssi >= -80 ? "Medium signal"
            : "Weak signal"
        // Maturity is a property of the family we would actually drive, so the matched family wins over
        // the model card: a Colmi tagged `.colmiSmartHealth` is an unproven driver even though the same
        // card, on QRing, is a fully-supported one. Falls back to the model when the scan matched nothing.
        let support = ring.deviceType?.supportLevel
            ?? WearableModel.model(id: ring.wearableModelID)?.supportLevel ?? .full
        return HStack {
            Image(systemName: ring.isLikelyRing ? "circle.hexagongrid.circle.fill" : "dot.radiowaves.left.and.right")
                .foregroundStyle(ring.isLikelyRing ? PulseColors.accent : PulseColors.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(ring.name).font(.subheadline.weight(.medium)).foregroundStyle(PulseColors.textPrimary)
                if let type = ring.deviceType {
                    HStack(spacing: 6) {
                        Text(WearableModel.model(id: ring.wearableModelID)?.displayName ?? type.displayName)
                            .font(.caption2)
                            .foregroundStyle(PulseColors.accent)
                        SupportBadge(level: support) // renders nothing for fully-supported families
                    }
                }
            }
            Spacer()
            SignalStrengthDots(rssi: ring.rssi) // §5
                .accessibilityHidden(true) // §5 row provides spoken signal level
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        // Interactive glass row (it's a tappable connect button).
        .pulseGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
        .overlay(alignment: .leading) { // §5 accent left-stripe for likely rings
            if ring.isLikelyRing {
                Rectangle()
                    .fill(PulseColors.accent)
                    .frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) // §5 clips stripe
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine) // §5
        .accessibilityLabel(Text( // §5 spoken label with signal level
            "\(ring.name)\(ring.deviceType.map { ", \($0.displayName)" } ?? "")"
                + (support == .limited ? ", limited support" : "")
                + ", \(signalLevel)"
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
                .font(PulseFont.largeTitle.weight(.regular))
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
        .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
