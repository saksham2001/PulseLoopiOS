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
    @State private var measuring: MeasurementSheet.Kind?
    @State private var coachStore = CoachSettingsStore.shared
    @State private var dataChange = PulseDataChange.shared
    /// Owns the prepared dashboard state. Created lazily in `.task` (never in `body`) so a `body`
    /// re-render never triggers DB work — it just reads the already-prepared store.
    @State private var store: TodayStore?

    private var summaryService: CoachSummaryService { CoachSummaryService(modelContext: modelContext) }
    private var coachEnabled: Bool { coachStore.settings.coachMasterEnabled }
    private var units: UnitsPreference { profiles.first?.units ?? .metric }

    /// Build the store exactly once, off the `body` path.
    private func ensureStore() {
        if store == nil { store = TodayStore(modelContext: modelContext) }
    }

    var body: some View {
        let _ = PerfTrace.renderTick("TodayView", Self.self)
        guard let activeStore = store else {
            // One pre-`.task` frame before the store is built: themed background, zero DB work.
            return AnyView(PulseColors.background.ignoresSafeArea().task { ensureStore() })
        }
        let summary = activeStore.summary
        let hero = activeStore.hero
        let caps = activeStore.capabilities
        let coachSummary = todaySummaries.first { $0.scopeKey == CoachDataAccess.localDateString(Date()) }
        return AnyView(ScrollView {
            VStack(spacing: 16) {
                HeroInsightCardView(title: hero.title, summary: hero.summary, chips: hero.chips)

                if coachEnabled {
                    Button { selectedTab = .coach } label: {
                        Text("Ask Coach")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background(PulseColors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricCardButton(
                        metric: "steps", label: "Steps",
                        value: summary.steps.map { $0.formatted() } ?? "—",
                        color: PulseColors.steps,
                        delta: TodayInsights.deltaFor(summary, value: summary.steps.map(Double.init), series: summary.trends.steps7d.map(\.value)),
                        sparkline: summary.trends.steps7d.map(\.value)
                    )
                    if MetricsService.isVisible(.heartRate, context: modelContext) {
                        MetricCardButton(
                            metric: "hr", label: "Heart rate",
                            value: TodayInsights.hrRangeLabel(summary.trends.hrSamples24h, summary.latestHeartRate?.value),
                            unit: hasHR(summary) ? "bpm" : nil,
                            color: PulseColors.heartRate,
                            sparkline: summary.trends.hrSamples24h.map(\.value),
                            onTap: caps.contains(.manualHeartRate) ? { measuring = .hr } : nil
                        )
                    }
                    if MetricsService.isVisible(.spo2, context: modelContext) {
                        MetricCardButton(
                            metric: "spo2", label: "SpO₂",
                            value: TodayInsights.averageLabel(summary.trends.spo2Samples24h, summary.latestSpO2?.value),
                            unit: hasSpO2(summary) ? "%" : nil,
                            color: PulseColors.spo2,
                            sparkline: summary.trends.spo2Samples24h.map(\.value),
                            onTap: caps.contains(.manualSpo2) ? { measuring = .spo2 } : nil
                        )
                    }
                    MetricCardButton(
                        metric: "sleep", label: "Sleep",
                        value: summary.sleep.map { SleepFormat.duration($0.session.totalMinutes) } ?? "—",
                        color: PulseColors.sleep,
                        sparkline: summary.sleep.map { [Double($0.lightMinutes), Double($0.deepMinutes), Double($0.awakeMinutes)] } ?? [],
                        onTap: { selectedTab = .sleep }
                    )
                    if MetricsService.isVisible(.calories, context: modelContext) {
                        MetricCardButton(
                            metric: "calories", label: "Calories",
                            value: summary.calories.map { Int($0).formatted() } ?? "—",
                            unit: summary.calories == nil ? nil : "kcal",
                            color: PulseColors.calories,
                            delta: TodayInsights.deltaFor(summary, value: summary.calories, series: summary.trends.calories7d.map(\.value)),
                            sparkline: summary.trends.calories7d.map(\.value)
                        )
                    }
                    MetricCardButton(
                        metric: "distance", label: "Distance",
                        value: summary.distanceMeters.map { UnitsFormatter.distance(meters: $0, units: units).value } ?? "—",
                        unit: summary.distanceMeters.map { _ in UnitsFormatter.distance(meters: 0, units: units).unit },
                        color: PulseColors.distance,
                        delta: TodayInsights.deltaFor(summary, value: summary.distanceMeters.map { $0 / 1000 }, series: summary.trends.distance7d.map { $0.value / 1000 }),
                        sparkline: summary.trends.distance7d.map(\.value)
                    )
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
            if isActive { store?.refreshIfNeeded() }
            if coachEnabled { await summaryService.refreshTodayIfNeeded() }
        }
        // Keep the dashboard live while on-screen: the persistence layer bumps one coalesced token
        // per batched save, so we refresh once per sync burst (not per packet) — and only while this
        // tab is visible. The store's signature check still makes each refresh a cheap no-op when
        // nothing changed.
        .onChange(of: dataChange.token) { _, _ in if isActive { store?.refreshIfNeeded() } }
        .onChange(of: isActive) { _, active in if active { store?.refreshIfNeeded() } }
        .sheet(item: Binding(get: { measuring.map(MeasuringItem.init) }, set: { measuring = $0?.kind })) { item in
            MeasurementSheet(kind: item.kind)
        })
    }

    private func hasHR(_ summary: TodaySummary) -> Bool {
        !summary.trends.hrSamples24h.isEmpty || summary.latestHeartRate != nil
    }
    private func hasSpO2(_ summary: TodaySummary) -> Bool {
        !summary.trends.spo2Samples24h.isEmpty || summary.latestSpO2 != nil
    }
}

private struct MeasuringItem: Identifiable {
    let kind: MeasurementSheet.Kind
    var id: Int { kind == .hr ? 0 : 1 }
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
