import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query(filter: #Predicate<CoachSummary> { $0.kind == "today" }, sort: \CoachSummary.updatedAt, order: .reverse)
    private var todaySummaries: [CoachSummary]
    @Binding var path: NavigationPath
    @Binding var selectedTab: MainTab
    @State private var measuring: MeasurementSheet.Kind?
    @State private var coachStore = CoachSettingsStore.shared

    private var summaryService: CoachSummaryService { CoachSummaryService(modelContext: modelContext) }
    private var coachEnabled: Bool { coachStore.settings.coachMasterEnabled }
    private var isImperial: Bool { WorkoutAppGroup.useImperialUnits }
    private var distanceDivisor: Double { isImperial ? 1609.34 : 1000.0 }
    private var distanceUnit: String { isImperial ? "mi" : "km" }

    var body: some View {
        let summary = MetricsService.buildTodaySummary(context: modelContext)
        let hero = TodayInsights.deriveHero(summary)
        // On-demand measurement is capability-gated: a ring that can't do an instant reading (e.g.
        // Colmi has no spot SpO2) makes that tile non-tappable — the tile still shows synced history.
        let caps = MetricsService.deviceCapabilities(modelContext)
        let coachSummary = todaySummaries.first { $0.scopeKey == CoachDataAccess.localDateString(Date()) }
        ScrollView {
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
                    MetricCardButton(
                        metric: "hr", label: "Heart rate",
                        value: TodayInsights.hrRangeLabel(summary.trends.hrSamples24h, summary.latestHeartRate?.value),
                        unit: hasHR(summary) ? "bpm" : nil,
                        color: PulseColors.heartRate,
                        sparkline: summary.trends.hrSamples24h.map(\.value),
                        onTap: caps.contains(.manualHeartRate) ? { measuring = .hr } : nil
                    )
                    MetricCardButton(
                        metric: "spo2", label: "SpO₂",
                        value: TodayInsights.averageLabel(summary.trends.spo2Samples24h, summary.latestSpO2?.value),
                        unit: hasSpO2(summary) ? "%" : nil,
                        color: PulseColors.spo2,
                        sparkline: summary.trends.spo2Samples24h.map(\.value),
                        onTap: caps.contains(.manualSpo2) ? { measuring = .spo2 } : nil
                    )
                    MetricCardButton(
                        metric: "sleep", label: "Sleep",
                        value: summary.sleep.map { SleepFormat.duration($0.session.totalMinutes) } ?? "—",
                        color: PulseColors.sleep,
                        sparkline: summary.sleep.map { [Double($0.lightMinutes), Double($0.deepMinutes), Double($0.awakeMinutes)] } ?? [],
                        onTap: { selectedTab = .sleep }
                    )
                    MetricCardButton(
                        metric: "calories", label: "Calories",
                        value: summary.calories.map { Int($0).formatted() } ?? "—",
                        unit: summary.calories == nil ? nil : "kcal",
                        color: PulseColors.calories,
                        delta: TodayInsights.deltaFor(summary, value: summary.calories, series: summary.trends.calories7d.map(\.value)),
                        sparkline: summary.trends.calories7d.map(\.value)
                    )
                    MetricCardButton(
                        metric: "distance", label: "Distance",
                        value: summary.distanceMeters.map { String(format: "%.2f", $0 / distanceDivisor) } ?? "—",
                        unit: summary.distanceMeters == nil ? nil : distanceUnit,
                        color: PulseColors.distance,
                        delta: TodayInsights.deltaFor(summary, value: summary.distanceMeters.map { $0 / distanceDivisor }, series: summary.trends.distance7d.map { $0.value / distanceDivisor }),
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("TODAY SO FAR")
                        .font(.system(size: 11, weight: .medium)).tracking(1.4)
                        .foregroundStyle(PulseColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if summary.timeline.isEmpty {
                        InlineEmptyState(title: "No events yet", message: "Sync your ring to see activity here.")
                            .background(PulseColors.card)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
                    } else {
                        ForEach(summary.timeline.prefix(5).map { $0 }) { event in
                            EventRow(event: event)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .background(PulseColors.background)
        .refreshable { await coordinator.pullToRefresh() }
        .task {
            if coachEnabled { await summaryService.refreshTodayIfNeeded() }
        }
        .sheet(item: Binding(get: { measuring.map(MeasuringItem.init) }, set: { measuring = $0?.kind })) { item in
            MeasurementSheet(kind: item.kind)
        }
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

struct EventRow: View {
    let event: TimelineEvent
    var body: some View {
        PulseCard(padding: 12) {
            HStack {
                Circle().fill(metricColor).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.system(size: 14, weight: .medium))
                    Text(event.detail)
                        .font(.caption)
                        .foregroundStyle(PulseColors.textMuted)
                }
                Spacer()
                Text(event.timestamp, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PulseColors.textMuted)
            }
        }
    }

    private var metricColor: Color {
        switch event.metric {
        case "hr": return PulseColors.heartRate
        case "spo2": return PulseColors.spo2
        case "sleep": return PulseColors.sleep
        default: return PulseColors.accent
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
