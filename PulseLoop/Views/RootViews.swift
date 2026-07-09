import SwiftUI
import SwiftData
import UIKit

struct RootAppView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LiveWorkoutManager.self) private var liveWorkout
    @Query private var profiles: [UserProfile]
    @State private var path = NavigationPath()
    @State private var didFinishForcedOnboarding = false

    private var forceOnboardingForTesting: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "forceOnboarding")
        #else
        false
        #endif
    }

    @Namespace private var zoomNS

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if (!forceOnboardingForTesting || didFinishForcedOnboarding),
                   profiles.first?.onboardingCompleted == true {
                    MainTabView(path: $path)
                } else {
                    OnboardingFlowView {
                        didFinishForcedOnboarding = true
                    }
                }
            }
            .background(PulseColors.background.ignoresSafeArea())
            .environment(\.zoomNamespace, zoomNS)
            // Demo data is opt-in: load it from Settings → "Reseed demo data", or via the
            // `-seedDemo YES` launch arg (test tooling only). Normal launches start empty.
            .task {
                if UserDefaults.standard.bool(forKey: "seedDemo") {
                    SeedData.clearAll(modelContext)
                    SeedData.seedDemo(modelContext, completeOnboarding: true)
                }
                // Test tooling: deep-link straight to a seeded workout's detail (route map).
                if UserDefaults.standard.bool(forKey: "openWorkout"),
                   let session = ActivityRepository.sessions(context: modelContext).first(where: { $0.status == .finished && $0.useGps }) {
                    path.append(AppRoute.activityDetail(session.id))
                }
                if UserDefaults.standard.bool(forKey: "openRecord") {
                    path.append(AppRoute.recordSelect)
                }
                // Re-attach to an in-progress workout left running across launches.
                liveWorkout.recover()
                routeDeepLinkIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    liveWorkout.recover()
                    routeDeepLinkIfNeeded()
                }
            }
            .onOpenURL { url in
                guard url.scheme == "pulseloop", url.host == "workout",
                      let id = UUID(uuidString: url.lastPathComponent) else { return }
                liveWorkout.requestOpen(sessionID: id)
                routeDeepLinkIfNeeded()
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case let .activityDetail(id):
                    ActivityDetailView(sessionId: id)
                case let .metricDetail(metric):
                    MetricDetailView(metric: metric, path: $path)
                        .pulseZoomDestination(route, in: zoomNS)
                case .activityTrends:
                    ActivityTrendsView(path: $path)
                case .recordSelect:
                    RecordSelectView(path: $path)
                case .logPastActivity:
                    LogPastActivityView(path: $path)
                case let .recordLive(id):
                    RecordLiveView(sessionId: id, path: $path)
                case let .recordSummary(id):
                    RecordSummaryView(sessionId: id, path: $path)
                case .settings:
                    SettingsView(path: $path)
                case .settingsProfile:
                    ProfileSettingsView()
                case .settingsPhysiology:
                    PhysiologySettingsView()
                case .settingsNotifications:
                    NotificationsSettingsView()
                case .settingsCoach:
                    CoachSettingsDetailView()
                case .settingsWearable:
                    WearableSettingsView(path: $path)
                case .settingsMeasurement:
                    MeasurementSettingsView()
                case .settingsActivityTracking:
                    WorkoutSettingsView()
                case .settingsGoals:
                    GoalsSettingsView()
                case .settingsVitals:
                    VitalsSettingsView()
                case .settingsToday:
                    TodaySettingsView()
                case .settingsCalibration:
                    CalibrationSettingsView()
                case .settingsPrivacyData:
                    PrivacyDataSettingsView()
                case .settingsAbout:
                    AboutSettingsView(path: $path)
                case .pairing:
                    PairingView(onConnected: { path.removeLast() })
                case .debug:
                    DebugView()
                case .componentGallery:
                    ComponentGalleryView()
                }
            }
        }
        .tint(PulseColors.accent)
        .preferredColorScheme(.dark)
    }

    /// Navigate to a workout requested by a Live Activity tap / Lock Screen control.
    private func routeDeepLinkIfNeeded() {
        guard let id = liveWorkout.pendingDeepLinkSession else { return }
        liveWorkout.clearDeepLink()
        guard let session = ActivityRepository.sessions(context: modelContext).first(where: { $0.id == id }) else { return }
        let route: AppRoute = session.status == .finished ? .recordSummary(id) : .recordLive(id)
        path.append(route)
    }
}

struct MainTabView: View {
    @Binding var path: NavigationPath
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @State private var selected: MainTab
    @State private var nav = CoachNavigation.shared
    @State private var coachStore = CoachSettingsStore.shared
    /// Route requested from inside the Coach sheet, pushed once the sheet dismisses.
    @State private var pendingCoachRoute: AppRoute?

    init(path: Binding<NavigationPath>) {
        self._path = path
        // Optional `-startTab vitals` launch arg (parsed into UserDefaults) for screenshot tooling.
        let raw = UserDefaults.standard.string(forKey: "startTab")
        let requested = MainTab.allCases.first { $0.rawValue.lowercased() == raw } ?? .today
        // Coach is no longer a tab (it opens as a sheet), so `-startTab coach`
        // just lands on Today.
        _selected = State(initialValue: requested == .coach ? .today : requested)
    }

    private var coachEnabled: Bool { coachStore.settings.coachMasterEnabled }
    private var visibleTabs: [MainTab] {
        // Coach is intentionally NOT a tab — it opens as a sheet. Keeping it a tab
        // pushed the count to 6 and iOS collapsed everything into a "More" tab.
        MainTab.allCases.filter { $0 != .coach }
    }

    /// The screen for a given tab. Shared by the iOS 26 stock `Tab` bar and the
    /// iOS 18–25 paged fallback so content wiring stays in one place.
    @ViewBuilder
    private func tabDestination(_ tab: MainTab) -> some View {
        switch tab {
        case .today:    TodayView(path: $path, selectedTab: $selected, isActive: selected == .today)
        case .vitals:   VitalsView(path: $path, isActive: selected == .vitals)
        case .activity: ActivityView(path: $path)
        case .sleep:    SleepView()
        case .coach:    CoachView()
        case .settings: SettingsView(path: $path)
        }
    }

    /// A workout card tapped inside the chat can't push onto `path` directly: the sheet
    /// sits outside this NavigationStack, so the detail would slide in behind it. Park
    /// the route and dismiss; `pushPendingCoachRoute` runs once the sheet is gone.
    private func requestCoachRoute(_ activityId: UUID) {
        pendingCoachRoute = .activityDetail(activityId)
        nav.showCoach = false
    }

    private func pushPendingCoachRoute() {
        guard let route = pendingCoachRoute else { return }
        pendingCoachRoute = nil
        path.append(route)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(path: $path)
            // Thin sync-progress accent directly under the greeting; only present while the ring
            // is actively syncing. The always-present container lets iOS 26 materialize the
            // bar (glass light-bending in/out) instead of a hard opacity cut.
            Group {
                if coordinator.isSyncing {
                    SyncProgressBar()
                        .pulseMaterialize()
                }
            }
            .pulseGlassContainer(spacing: 8)
            if #available(iOS 26, *) {
                // iOS 26+: native TabView renders Apple's stock Liquid Glass tab bar —
                // real lensing, morphing selection, and content diffusing under the bar.
                // Swipe-between-tabs is intentionally dropped (the stock bar can't swipe).
                TabView(selection: $selected) {
                    ForEach(visibleTabs) { tab in
                        Tab(tab.rawValue, systemImage: tab.symbol, value: tab) {
                            tabDestination(tab)
                        }
                    }
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .onChange(of: selected) { _, _ in UIApplication.shared.endEditing() }
            } else {
                // iOS 18–25: no stock Liquid Glass, so keep the paged swipe + custom bar.
                ZStack(alignment: .bottom) {
                    TabView(selection: $selected) {
                        ForEach(visibleTabs) { tab in
                            tabDestination(tab).tag(tab)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    BottomNavBar(selected: $selected, tabs: visibleTabs)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .onChange(of: selected) { _, _ in UIApplication.shared.endEditing() }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.isSyncing)
        .animation(PulseMotion.materialize, value: coachEnabled)   // FAB materializes in/out
        // Floating Coach chat bubble, bottom-right, hovering above the tab bar.
        .overlay(alignment: .bottomTrailing) {
            if coachEnabled {
                CoachFAB { CoachNavigation.shared.openRoot() }
                    .padding(.trailing, 18)
                    .padding(.bottom, 72)   // sits just above the tab bar
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .onChange(of: coachEnabled) { _, enabled in
            // Coach turned off — dismiss the sheet and clear any pending deep link.
            if !enabled { nav.requestedConversationId = nil; nav.showCoach = false }
        }
        // Coach opens as a sheet (swipe-to-dismiss) instead of a tab, so it never
        // crowds the tab bar. All entry points set `nav.showCoach`.
        .sheet(isPresented: $nav.showCoach, onDismiss: pushPendingCoachRoute) {
            CoachView(onOpenWorkout: requestCoachRoute)
                .presentationDragIndicator(.visible) // grabber ("pull tab") at the top of the sheet
        }
        .background(PulseColors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Fixed top header mirroring the web app's `TopStatusBar`: small uppercase brand over a
/// time-based greeting on the left; a connection-status pill plus quick nav icons on the right.
struct AppHeader: View {
    @Binding var path: NavigationPath
    @Environment(RingBLEClient.self) private var ble
    @Query private var devices: [Device]
    @Query private var profiles: [UserProfile]

    /// Profile's first name (text before the first space), or nil when no name is set.
    private var firstName: String? {
        guard let full = profiles.first?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !full.isEmpty else { return nil }
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    /// A rotating, time-of-day greeting. Each variant is a `lead` phrase plus a `suffix`
    /// (usually "" or "?") so it composes both with a name — "\(lead), \(name)\(suffix)" — and
    /// without — "\(lead)\(suffix)". The pick advances every 2 hours (and differs day to day),
    /// so it stays stable within each 2-hour block — no flicker as the view re-renders.
    private var greeting: (lead: String, suffix: String) {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let day = cal.ordinality(of: .day, in: .year, for: now) ?? 0
        // 12 two-hour blocks per day; a global block index rotates the variant every 2 hours.
        let block = day * 12 + hour / 2
        let variants = Self.greetingVariants(hour: hour)
        return variants[block % variants.count]
    }

    private static func greetingVariants(hour: Int) -> [(lead: String, suffix: String)] {
        switch hour {
        case 5..<12: // Morning
            return [
                ("Good morning", ""),
                ("Rise and shine", ""),
                ("Ready for a run", "?"),
                ("Ready to seize the day", "?"),
                ("Fresh start", "")
            ]
        case 12..<17: // Afternoon
            return [
                ("Good afternoon", ""),
                ("Keeping the momentum", "?"),
                ("Staying on track", "?"),
                ("How's the day treating you", "?"),
                ("Powering through", "?")
            ]
        case 17..<22: // Evening
            return [
                ("Good evening", ""),
                ("How was your day", "?"),
                ("Time to unwind", ""),
                ("Winding down", "?"),
                ("Evening, champ", "")
            ]
        default: // Night (22–5)
            return [
                ("Good night", ""),
                ("Time to wind down", ""),
                ("Ready to rest", "?"),
                ("Rest well", ""),
                ("Burning the midnight oil", "?")
            ]
        }
    }

    var body: some View {
        let greeting = self.greeting
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                if let firstName {
                    // Two lines: greeting on top, name below — avoids truncating a long name.
                    Text("\(greeting.lead),")
                        .font(PulseFont.footnote)
                        .foregroundStyle(PulseColors.textMuted)
                    Text("\(firstName)\(greeting.suffix)")
                        .font(PulseFont.title2.weight(.semibold))
                        .foregroundStyle(PulseColors.textPrimary)
                        .lineLimit(1)
                } else {
                    Text("\(greeting.lead)\(greeting.suffix)")
                        .font(PulseFont.title3)
                        .foregroundStyle(PulseColors.textPrimary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // Clean top bar: just the live connection status. Settings is in the tab
            // bar; Coach is the floating bubble above the tab bar.
            ConnectionStatusPill(state: effectiveState, batteryPercent: effectiveBattery)
                .font(PulseFont.headline.weight(.regular))
                .foregroundStyle(PulseColors.textSecondary)
                // Tap the status pill → Wearable settings (add-a-ring / status).
                .onTapGesture { path.append(AppRoute.settingsWearable) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(PulseColors.background)
    }

    /// Prefer live BLE state; otherwise fall back to the stored device so demo
    /// data shows "Connected · 82%" instead of a permanently disconnected ring.
    private var liveActive: Bool {
        [.connected, .connecting, .reconnecting, .scanning].contains(ble.state)
    }
    private var effectiveState: RingConnectionState {
        liveActive ? ble.state : (devices.first?.state ?? ble.state)
    }
    private var effectiveBattery: Int? {
        ble.batteryPercent ?? devices.first?.batteryPercent
    }
}

/// Colored-dot + label pill describing the BLE connection state, matching the web app.
struct ConnectionStatusPill: View {
    let state: RingConnectionState
    let batteryPercent: Int?
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .opacity(isPulsing && pulse ? 0.35 : 1)
            Text(label)
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Interactive glass — the pill is tappable (navigates to Settings).
        .pulseGlass(Capsule(), interactive: true)
        .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            guard isPulsing else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var isPulsing: Bool {
        state == .connecting || state == .reconnecting
    }

    private var dotColor: Color {
        switch state {
        case .connected: return PulseColors.success
        case .connecting, .reconnecting: return PulseColors.accent
        // No ring linked: the header's background auto-reconnect scan (which never
        // resolves without a reachable ring) reads as "Disconnected" to the user,
        // not an in-progress action. Show it in danger red like the other
        // not-connected states. (Active pairing has its own UI in PairingView.)
        case .scanning: return PulseColors.danger
        case .failed: return PulseColors.danger
        case .idle, .disconnected: return PulseColors.danger
        }
    }

    private var label: String {
        switch state {
        case .connected:
            if let battery = batteryPercent, battery > 0 { return "Connected · \(battery)%" }
            return "Connected"
        case .connecting, .reconnecting: return "Connecting…"
        case .scanning: return "Disconnected"
        case .failed: return "Sync failed"
        case .idle, .disconnected: return "Disconnected"
        }
    }
}

/// Time-of-day greeting, mirroring the web app's `greetingForHour()`.
func greetingForHour(_ date: Date = Date()) -> String {
    switch Calendar.current.component(.hour, from: date) {
    case 5..<12: return "Good morning"
    case 12..<17: return "Good afternoon"
    case 17..<22: return "Good evening"
    default: return "Good night"
    }
}

/// Floating Coach chat bubble — a circular tinted-glass button that hovers above
/// the tab bar (bottom-right) and opens the Coach chat sheet. Real Liquid Glass on
/// iOS 26+, solid accent fallback on older systems / Reduce Transparency.
struct CoachFAB: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(PulseFont.title2)
                .foregroundStyle(PulseColors.accent)
                .frame(width: 56, height: 56)
                .modifier(CoachFABGlass())
                // Consume every touch inside the circle so taps never fall through
                // to the content scrolling underneath the bubble.
                .contentShape(Circle())
        }
        .buttonStyle(FABPressStyle())
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .accessibilityLabel("Open Coach chat")
    }
}

/// Press-in spring for the FAB. A ButtonStyle (not a gesture) so it never leaks
/// the touch to the view below.
private struct FABPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Frosted Liquid Glass bubble (no solid fill) so the icon reads as glass. Real
/// glass on iOS 26+, Material fallback otherwise / under Reduce Transparency.
private struct CoachFABGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
    }
}

struct BottomNavBar: View {
    @Binding var selected: MainTab
    var tabs: [MainTab] = MainTab.allCases
    // Drives the sliding selection lozenge that morphs between tabs.
    @Namespace private var tabSelection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isSelected = selected == tab
                Button {
                    // Switch the page instantly (no scroll-through of intermediate
                    // pages, so rapid taps land reliably). The lozenge still animates
                    // via the `.animation(value:)` below; manual swipe is unaffected.
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) { selected = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(PulseFont.headline)
                            .frame(width: 38, height: 28)
                            .background {
                                // The active lozenge slides between tabs instead of
                                // hard-cutting — matchedGeometryEffect works on every OS.
                                if isSelected {
                                    Capsule()
                                        .fill(PulseColors.accentSoft)
                                        .matchedGeometryEffect(id: "tabLozenge", in: tabSelection)
                                }
                            }
                        Text(tab.rawValue)
                            .font(PulseFont.micro)
                    }
                    .foregroundStyle(isSelected ? PulseColors.textPrimary : PulseColors.textMuted)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        // Slide the selection lozenge smoothly whenever the tab changes.
        .animation(PulseMotion.spring, value: selected)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        // Single interactive glass surface — real Liquid Glass (touch illumination)
        // on iOS 26+, Material fallback below.
        .pulseGlass(Capsule(), interactive: true)
        .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
        // Consume every touch inside the capsule so taps never fall through to the
        // scrolling content beneath the floating bar.
        .contentShape(Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }
}

struct OnboardingHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(PulseFont.numberHero)
                .foregroundStyle(PulseColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(PulseFont.callout.weight(.regular))
                .foregroundStyle(PulseColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }
}

// MARK: - Shared small views

struct SectionHeader: View {
    let title: String
    let action: String?
    var body: some View {
        HStack {
            Text(title)
                .font(PulseFont.footnote.weight(.semibold))
                .foregroundStyle(PulseColors.textSecondary)
                .textCase(.uppercase)
            Spacer()
            if let action {
                Text(action)
                    .font(.caption)
                    .foregroundStyle(PulseColors.accent)
            }
        }
    }
}

struct StatusCopy: View {
    let title: String
    let text: String

    init(title: String, body: String) {
        self.title = title
        self.text = body
    }

    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(PulseFont.subheadline.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    init(title: String, body: String) {
        self.title = title
        self.message = body
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(PulseColors.textMuted)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(PulseColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

/// Compact inline empty state for charts/cards (web's `EmptyState` used inside cards).
struct InlineEmptyState: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(PulseFont.subheadline).foregroundStyle(PulseColors.textPrimary)
            Text(message).font(PulseFont.caption.weight(.regular)).foregroundStyle(PulseColors.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
