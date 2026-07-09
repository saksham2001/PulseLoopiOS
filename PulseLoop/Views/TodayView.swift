import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query(filter: #Predicate<CoachSummary> { $0.kind == "today" }, sort: \CoachSummary.updatedAt, order: .reverse)
    private var todaySummaries: [CoachSummary]
    @Query private var profiles: [UserProfile]
    @Binding var path: NavigationPath
    @Binding var selectedTab: MainTab
    /// Whether the Today tab is on screen (adjacent tabs stay alive under the `.page` TabView).
    let isActive: Bool
    @State private var coachStore = CoachSettingsStore.shared
    @State private var dataChange = PulseDataChange.shared
    /// Owns the prepared dashboard state. Created lazily in `.task` (never in `body`) so a `body`
    /// re-render never triggers DB work — it just reads the already-prepared store.
    @State private var store: TodayStore?
    // Tile reorder ("edit mode"): long-press a tile to enter, drag to reorder, Done to exit.
    @State private var editing = false
    @State private var dragging: MetricKey?
    @State private var prefs = MetricPrefsStore.shared

    /// Canonical Today tile order (used until the user reorders). Tile id = `MetricKey`.
    private static let defaultOrder: [MetricKey] = [
        .steps, .sleep, .heartRate, .spo2, .hrv, .temperature,
        .stress, .fatigue, .bloodSugar, .bloodPressureSystolic
    ]

    private var summaryService: CoachSummaryService { CoachSummaryService(modelContext: modelContext) }
    private var coachEnabled: Bool { coachStore.settings.coachMasterEnabled }
    private var units: UnitsPreference { profiles.first?.units ?? .metric }

    private var profile: UserProfile? { profiles.first }

    /// Build the store exactly once, off the `body` path.
    private func ensureStore() {
        if store == nil { store = TodayStore(modelContext: modelContext, profile: profile) }
    }

    var body: some View {
        guard let activeStore = store else {
            // One pre-`.task` frame before the store is built: themed background, zero DB work.
            return AnyView(PulseColors.background.ignoresSafeArea().task { ensureStore() })
        }
        let summary = activeStore.summary
        let hero = activeStore.hero
        let coachSummary = todaySummaries.first { $0.scopeKey == CoachDataAccess.localDateString(Date()) }
        return AnyView(ScrollView {
            VStack(spacing: 16) {
                // Top insight card. When the coach is on it owns this slot (tap → chat);
                // otherwise the deterministic hero fills it. Only ever one card here, so the
                // coach summary and the hero can't render the same content twice on one screen.
                if coachEnabled, let coachSummary {
                    Button {
                        summaryService.openInChat(coachSummary)
                    } label: {
                        CoachMessageCard(
                            headline: coachSummary.title,
                            body: coachSummary.body,
                            chips: coachSummary.chips
                        )
                    }
                    .buttonStyle(.plain)
                } else if coachEnabled {
                    // Coach on but no summary generated yet: offer the chat entry point.
                    Button { selectedTab = .coach } label: {
                        CoachMessageCard(
                            headline: summary.calibration.isCalibrating ? "Baseline in progress" : "Want a recap?",
                            body: summary.calibration.isCalibrating
                                ? "I can help explain what data is collected and what is still missing."
                                : "Want a summary from the latest ring context? Tap to open the coach.",
                            chips: []
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    HeroInsightCardView(title: hero.title, summary: hero.summary, chips: hero.chips)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    tiles(activeStore)
                }

                // Restore tray: only while editing, and only if something is hidden.
                if editing {
                    HiddenMetricsTray(
                        hidden: hiddenKeys(),
                        restore: { restore($0) },
                        displayName: { $0.reorderDisplayName },
                        symbolName: { $0.reorderSymbolName }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .background(PulseColors.background)
        // Tap-outside-to-exit: a catcher behind the cards, live only while editing.
        .background {
            if editing {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { exitEdit() }
                    .accessibilityHidden(true)
            }
        }
        .refreshable { await coordinator.pullToRefresh() }
        .overlay(alignment: .top) { if editing { editDoneBar } }
        .task {
            ensureStore()
            if isActive { store?.updateProfile(profile) }
            if coachEnabled { await summaryService.refreshTodayIfNeeded() }
        }
        // Keep the dashboard live while on-screen: the persistence layer bumps one coalesced token
        // per batched save, so we refresh once per sync burst (not per packet) — and only while this
        // tab is visible. The store's signature check still makes each refresh a cheap no-op when
        // nothing changed.
        .onChange(of: dataChange.token) { _, _ in if isActive { store?.refreshIfNeeded() } }
        .onChange(of: isActive) { _, active in if active { store?.updateProfile(profile) } }
        .onChange(of: profile?.updatedAt) { _, _ in store?.updateProfile(profile) })
    }

    // MARK: - Tile grid

    /// The half-width tiles, in the user's saved order, gated by the Today-scope visibility set.
    /// Each metric uses its own visual language. Long-press any tile → reorder mode.
    @ViewBuilder
    private func tiles(_ store: TodayStore) -> some View {
        let physiology = UserPhysiologyProfile(profile)
        let keys = orderedKeys(store)

        ReorderableForEach(items: keys, isEditing: editing, dragging: $dragging,
                           move: { from, to in move(keys, from, to) },
                           hide: { key in hide(key) },
                           displayName: { $0.reorderDisplayName }) { key in
            cardFor(key, store, physiology)
                // simultaneousGesture so the long-press fires even though each tile is a Button
                // (a plain .onLongPressGesture is swallowed by the button's own tap gesture).
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in enterEdit() }
                )
        }
    }

    /// Metrics hidden in the Today scope: the full Today set filtered by `prefs.isHidden`, so the
    /// restore tray stays in lockstep with Settings visibility. (Filtering the default order rather
    /// than "visible minus resolved" keeps device-unsupported metrics out of the tray.)
    private func hiddenKeys() -> [MetricKey] {
        Self.defaultOrder.filter { prefs.isHidden($0, scope: .today) }
    }

    private func hide(_ key: MetricKey) {
        UISelectionFeedbackGenerator().selectionChanged()
        prefs.setHidden(key, true, scope: .today)
    }

    private func restore(_ key: MetricKey) {
        prefs.setHidden(key, false, scope: .today)
    }

    /// Visible Today tiles in the saved order (falling back to `defaultOrder`).
    private func orderedKeys(_ store: TodayStore) -> [MetricKey] {
        // Live hide/restore: filter by `prefs.isHidden` directly, not just the store's cached
        // `visibleMetrics` snapshot, so the "–" badge / Hidden-tray "+" drop or re-add a card
        // immediately (the view observes `prefs`, so this re-renders on toggle).
        let visible = store.visibleMetrics
            .intersection(Set(Self.defaultOrder))
            .filter { !prefs.isHidden($0, scope: .today) }
        let raws = prefs.resolvedOrder(
            visible: Set(visible.map(\.rawValue)),
            defaultOrder: Self.defaultOrder.map(\.rawValue),
            scope: .today
        )
        return raws.compactMap { MetricKey(rawValue: $0) }
    }

    @ViewBuilder
    private func cardFor(_ key: MetricKey, _ store: TodayStore, _ physiology: UserPhysiologyProfile) -> some View {
        switch key {
        case .steps:
            ActivityTileView(
                summary: store.summary, units: units,
                caloriesAvailable: MetricsService.isVisible(.calories, context: modelContext, scope: .today),
                onTap: { selectedTab = .activity }
            )
        case .sleep:
            SleepTileView(sleep: store.summary.sleep) { selectedTab = .sleep }
        case .heartRate: chartTile(store, .heartRate, physiology)
        case .spo2: chartTile(store, .spo2, physiology, showPoints: true)
        case .hrv: chartTile(store, .hrv, physiology)
        case .temperature: chartTile(store, .temperature, physiology)
        case .stress: gaugeTile(store, .stress)
        case .fatigue: gaugeTile(store, .fatigue)
        case .bloodSugar: gaugeTile(store, .glucose)
        case .bloodPressureSystolic: bpTile(store, physiology)
        default: EmptyView()
        }
    }

    private func move(_ keys: [MetricKey], _ from: Int, _ to: Int) {
        var k = keys
        let item = k.remove(at: from)
        k.insert(item, at: min(to, k.count))
        prefs.setOrder(k.map(\.rawValue), for: .today)
    }

    private func enterEdit() {
        guard !editing else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.2)) { editing = true }
        // Drag is invisible to VoiceOver — tell VO users how to reorder without it.
        AccessibilityNotification.Announcement(
            "Editing layout. Double-tap and hold to drag, or use actions to move cards."
        ).post()
    }

    private func exitEdit() {
        guard editing else { return }
        withAnimation(.easeInOut(duration: 0.2)) { editing = false }
    }

    /// Floating "Done" pill shown while reordering.
    private var editDoneBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold))
            Text("Drag to reorder").font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 12)
            Button {
                exitEdit()
            } label: {
                Text("Done").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(PulseColors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PulseColors.card, in: Capsule())
        .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func chartTile(_ store: TodayStore, _ metric: MetricKind,
                           _ physiology: UserPhysiologyProfile, showPoints: Bool = false) -> some View {
        if let model = store.cards[metric] {
            let baseline = metric == .hrv ? BaselineStats.compute(store.hrvSamples) : nil
            TodayChartTile(model: model, profile: physiology, baseline: baseline, showPoints: showPoints) {
                path.append(AppRoute.metricDetail(metric))
            }
        }
    }

    @ViewBuilder
    private func gaugeTile(_ store: TodayStore, _ metric: MetricKind) -> some View {
        if let model = store.cards[metric] {
            TodayGaugeTile(model: model) { path.append(AppRoute.metricDetail(metric)) }
        }
    }

    @ViewBuilder
    private func bpTile(_ store: TodayStore, _ physiology: UserPhysiologyProfile) -> some View {
        if let model = store.cards[.bloodPressure] {
            TodayBloodPressureTile(
                model: model,
                systolic: store.systolicSamples.last?.value,
                diastolic: store.diastolicSamples.last?.value,
                systolicZones: VitalsThresholdEngine.zones(for: .bloodPressure, profile: physiology),
                diastolicZones: VitalsThresholdEngine.diastolicReferenceZones(),
                onTap: { path.append(AppRoute.metricDetail(.bloodPressure)) }
            )
        }
    }
}

/// Today hero + delta derivation, ported from `frontend/src/screens/Today.tsx`.
enum TodayInsights {
    struct Hero {
        let title: String
        let summary: String
        let chips: [ToneChip]
    }

    private static func avg(_ arr: [Double]) -> Double {
        arr.isEmpty ? 0 : arr.reduce(0, +) / Double(arr.count)
    }

    private static func pct(_ value: Double, _ base: Double) -> Int {
        base == 0 ? 0 : Int((((value - base) / base) * 100).rounded())
    }

    static func hrRangeLabel(_ samples: [MetricSample], _ fallback: Double?) -> String {
        let values = samples.map(\.value).filter { $0 > 0 }
        guard !values.isEmpty else { return fallback.map { "\(Int($0.rounded()))" } ?? "—" }
        let lo = Int(values.min()!.rounded()), hi = Int(values.max()!.rounded())
        return lo == hi ? "\(lo)" : "\(lo)-\(hi)"
    }

    static func averageLabel(_ samples: [MetricSample], _ fallback: Double?) -> String {
        let values = samples.map(\.value).filter { $0 > 0 }
        guard !values.isEmpty else { return fallback.map { "\(Int($0.rounded()))" } ?? "—" }
        return "\(Int((values.reduce(0, +) / Double(values.count)).rounded()))"
    }

    static func deltaFor(_ summary: TodaySummary, value: Double?, series: [Double]) -> MetricDelta? {
        guard !summary.calibration.isCalibrating, let value, series.count >= 3 else { return nil }
        let base = avg(Array(series.dropLast()))
        return MetricDelta(value: pct(value, base == 0 ? avg(series) : base), label: "vs 7d")
    }

    static func deriveHero(_ today: TodaySummary) -> Hero {
        if today.calibration.isCalibrating {
            return Hero(
                title: "Learning your baseline",
                summary: "Your ring is paired. Wear it through the day and sync once before bed so PulseLoop can start building your activity and recovery baseline.",
                chips: [
                    ToneChip(label: "Day \(today.calibration.day) of \(today.calibration.totalDays)", tone: .warn),
                    ToneChip(label: today.latestHeartRate == nil ? "HR pending" : "HR collected", tone: today.latestHeartRate == nil ? .warn : .neutral),
                    ToneChip(label: today.sleep != nil ? "Sleep synced" : "Sleep pending", tone: today.sleep != nil ? .neutral : .warn)
                ]
            )
        }

        guard let steps = today.steps else {
            return Hero(
                title: "Waiting for first sync",
                summary: "Sync your ring to start collecting movement, heart rate, blood oxygen, and recovery context.",
                chips: [
                    ToneChip(label: "Baseline pending", tone: .warn),
                    ToneChip(label: today.latestHeartRate == nil ? "HR pending" : "HR collected", tone: .neutral),
                    ToneChip(label: "Sleep pending", tone: .warn)
                ]
            )
        }

        let series = today.trends.steps7d.map(\.value)
        let stepsAvg = avg(Array(series.dropLast()))
        let stepsDelta = pct(Double(steps), stepsAvg == 0 ? avg(series) : stepsAvg)

        var title = "Steady build"
        if stepsDelta >= 20 { title = "Building momentum" }
        else if stepsDelta <= -20 { title = "Take it easy" }

        let hrStr = today.latestHeartRate.map { "\(Int($0.value)) bpm" } ?? "—"
        let summaryText = today.sleep == nil
            ? "You're at \(steps.formatted()) steps. Sync after waking to add recovery context."
            : "You're at \(steps.formatted()) steps, \(SleepFormat.duration(today.sleep!.session.totalMinutes)) of sleep, and your latest reading is \(hrStr)."

        let stepsTone: ChipTone = stepsDelta > 5 ? .up : stepsDelta < -5 ? .down : .neutral
        let hrTone: ChipTone = today.latestHeartRate == nil ? .warn : (today.latestHeartRate!.value < 100 ? .neutral : .warn)

        return Hero(
            title: title,
            summary: summaryText,
            chips: [
                ToneChip(label: series.count > 1 ? "Steps \(stepsDelta >= 0 ? "+" : "")\(stepsDelta)%" : "Steps collected", tone: stepsTone),
                ToneChip(label: today.latestHeartRate == nil ? "HR pending" : "HR collected", tone: hrTone),
                ToneChip(label: today.sleep != nil ? "Sleep synced" : "Sleep pending", tone: today.sleep != nil ? .neutral : .warn)
            ]
        )
    }
}
