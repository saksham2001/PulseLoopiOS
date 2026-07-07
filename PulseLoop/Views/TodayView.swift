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
                HeroInsightCardView(title: hero.title, summary: hero.summary, chips: hero.chips)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    tiles(activeStore)
                }

                if coachEnabled {
                    Button {
                        if let coachSummary { summaryService.openInChat(coachSummary) } else { selectedTab = .coach }
                    } label: {
                        CoachMessageCard(
                            headline: coachSummary?.title ?? (summary.calibration.isCalibrating ? "Baseline in progress" : "Want a recap?"),
                            body: coachSummary?.body ?? (summary.calibration.isCalibrating
                                ? "I can help explain what data is collected and what is still missing."
                                : "Want a summary from the latest ring context? Tap to open the coach."),
                            chips: coachSummary?.chips ?? []
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .background(PulseColors.background)
        .refreshable { await coordinator.pullToRefresh() }
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

    /// The half-width tiles, gated by the Today-scope visibility set prepared in the store. Each metric
    /// uses its own visual language (activity loop, sleep bar, zone chart, gauge, dual BP gauge).
    @ViewBuilder
    private func tiles(_ store: TodayStore) -> some View {
        let physiology = UserPhysiologyProfile(profile)
        let visible = store.visibleMetrics

        // Activity: the single combined loop, gated by the Today "Activity" toggle (`.steps` key).
        if visible.contains(.steps) {
            ActivityTileView(
                summary: store.summary, units: units,
                caloriesAvailable: MetricsService.isVisible(.calories, context: modelContext, scope: .today),
                onTap: { selectedTab = .activity }
            )
        }

        // Sleep: duration + stage distribution bar + score.
        if visible.contains(.sleep) {
            SleepTileView(sleep: store.summary.sleep) { selectedTab = .sleep }
        }

        if visible.contains(.heartRate) { chartTile(store, .heartRate, physiology) }
        if visible.contains(.spo2) { chartTile(store, .spo2, physiology, showPoints: true) }
        if visible.contains(.hrv) { chartTile(store, .hrv, physiology) }
        if visible.contains(.temperature) { chartTile(store, .temperature, physiology) }

        if visible.contains(.stress) { gaugeTile(store, .stress) }
        if visible.contains(.fatigue) { gaugeTile(store, .fatigue) }
        if visible.contains(.bloodSugar) { gaugeTile(store, .glucose) }

        if visible.contains(.bloodPressureSystolic) { bpTile(store, physiology) }
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
