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
                case .activityTrends:
                    ActivityTrendsView(path: $path)
                case .recordSelect:
                    RecordSelectView(path: $path)
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

    init(path: Binding<NavigationPath>) {
        self._path = path
        // Optional `-startTab vitals` launch arg (parsed into UserDefaults) for screenshot tooling.
        let raw = UserDefaults.standard.string(forKey: "startTab")
        let requested = MainTab.allCases.first { $0.rawValue.lowercased() == raw } ?? .today
        // If the coach is off, the coach tab doesn't exist — fall back to Today
        // so a `-startTab coach` arg doesn't strand us on an empty selection.
        let masterOn = CoachSettingsStore.shared.settings.coachMasterEnabled
        _selected = State(initialValue: (requested == .coach && !masterOn) ? .today : requested)
    }

    private var coachEnabled: Bool { coachStore.settings.coachMasterEnabled }
    private var visibleTabs: [MainTab] {
        coachEnabled ? MainTab.allCases : MainTab.allCases.filter { $0 != .coach }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(path: $path)
            // Thin sync-progress accent directly under the greeting; only present while the ring
            // is actively syncing so the user knows wearable data is still streaming in.
            if coordinator.isSyncing {
                SyncProgressBar()
                    .transition(.opacity)
            }
            ZStack(alignment: .bottom) {
                TabView(selection: $selected) {
                    TodayView(path: $path, selectedTab: $selected, isActive: selected == .today).tag(MainTab.today)
                    VitalsView(path: $path, isActive: selected == .vitals).tag(MainTab.vitals)
                    ActivityView(path: $path).tag(MainTab.activity)
                    SleepView().tag(MainTab.sleep)
                    if coachEnabled {
                        CoachView().tag(MainTab.coach)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                BottomNavBar(selected: $selected, tabs: visibleTabs)
            }
            // Pin the whole tab layout so the keyboard never shifts the nav bar or
            // tab content. CoachView lifts its own composer via a keyboard observer.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onChange(of: selected) { _, _ in UIApplication.shared.endEditing() }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.isSyncing)
        .onChange(of: nav.requestedConversationId) { _, id in
            if id != nil && coachEnabled { selected = .coach }  // CoachView opens the thread + resets the flag
        }
        .onChange(of: coachEnabled) { _, enabled in
            // Coach was turned off while on the coach tab — bounce home.
            if !enabled && selected == .coach { selected = .today }
            if !enabled { nav.requestedConversationId = nil }
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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("PulseLoop")
                    .font(.system(size: 12, weight: .medium))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(PulseColors.textMuted)
                Text(greetingForHour())
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                ConnectionStatusPill(state: effectiveState, batteryPercent: effectiveBattery)
                    .onTapGesture { path.append(AppRoute.settings) }
                Button {
                    path.append(AppRoute.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .font(.system(size: 17))
            .foregroundStyle(PulseColors.textSecondary)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PulseColors.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(PulseColors.card, in: Capsule())
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

struct BottomNavBar: View {
    @Binding var selected: MainTab
    var tabs: [MainTab] = MainTab.allCases

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    selected = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 38, height: 28)
                            .background(selected == tab ? PulseColors.accentSoft : Color.clear)
                            .clipShape(Capsule())
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selected == tab ? PulseColors.textPrimary : PulseColors.textMuted)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(PulseColors.borderSubtle).frame(height: 1)
        }
    }
}

struct OnboardingHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(PulseColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 15))
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
                .font(.system(size: 13, weight: .semibold))
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
                    .font(.system(size: 14))
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
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
            Text(message).font(.system(size: 12)).foregroundStyle(PulseColors.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
