import SwiftUI
import SwiftData

struct SleepView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var allSummaries: [CoachSummary]
    @State private var range: SleepRangeKey
    @State private var coachStore = CoachSettingsStore.shared

    init() {
        let raw = UserDefaults.standard.string(forKey: "startSleepRange")
        _range = State(initialValue: SleepRangeKey.allCases.first { $0.rawValue == raw } ?? .day)
    }

    private var summaryService: CoachSummaryService { CoachSummaryService(modelContext: modelContext) }
    private var coachEnabled: Bool { coachStore.settings.coachMasterEnabled }

    private var daySummary: CoachSummary? {
        allSummaries.filter { $0.kind == "sleep_day" }.max(by: { $0.updatedAt < $1.updatedAt })
    }
    private func rangeSummary(_ range: SleepRangeKey) -> CoachSummary? {
        allSummaries.first { $0.kind == "sleep_range_\(range.rawValue)" }
    }

    var body: some View {
        let summary = SleepService.sleepRange(range, context: modelContext)
        let goalMin = MetricsRepository.goals(context: modelContext)?.sleepMinutes
        let activitySteps = MetricsRepository.latestActivity(context: modelContext)?.steps

        ScrollView {
            VStack(spacing: 16) {
                SleepRangeSelectorView(selection: $range)

                if range == .day {
                    dayView(summary: summary, activitySteps: activitySteps)
                } else {
                    aggregateView(summary: summary, goalMin: goalMin)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .background(PulseColors.background)
        .refreshable { await coordinator.pullToRefresh() }
        .task(id: range) {
            guard coachEnabled else { return }
            if range == .day { await summaryService.refreshSleepDayIfNeeded() }
            else { await summaryService.refreshSleepRangeIfNeeded(range) }
        }
    }

    /// A summary-backed coach card; falls back to the scripted `SleepCoach` until
    /// the LLM summary is generated. Tapping opens the seeded chat thread.
    /// Hidden entirely when the AI Coach master switch is off.
    @ViewBuilder
    private func summaryCard(_ summary: CoachSummary?, fallback: SleepCoach) -> some View {
        if coachEnabled {
            if let summary {
                Button { summaryService.openInChat(summary) } label: {
                    CoachMessageCard(headline: summary.title, body: summary.body, chips: summary.chips)
                }
                .buttonStyle(.plain)
            } else {
                CoachMessageCard(headline: fallback.headline, body: fallback.body, chips: fallback.chips)
            }
        }
    }

    // MARK: Day

    @ViewBuilder
    private func dayView(summary: SleepRangeSummary, activitySteps: Int?) -> some View {
        if let night = SleepInsights.validSessions(summary.sessions).last {
            let score = SleepScore.calculate(night)
            let coach = SleepInsights.dayCoach(night, score: score.score, awakePct: score.awakePct, deepPct: score.deepPct, activitySteps: activitySteps)
            SleepHeroCardView(
                label: SleepInsights.rangeHeroLabel[.day] ?? "Last Sleep",
                value: SleepFormat.duration(night.session.totalMinutes),
                support: "\(SleepFormat.clockTime(night.session.startAt)) to \(SleepFormat.clockTime(night.session.endAt))",
                score: score.score,
                scoreLabel: score.label.rawValue
            )
            VisualizationCard(eyebrow: "Stages", title: "Sleep architecture", legend: true) {
                SleepHypnogramView(blocks: night.blocks, totalMin: night.session.totalMinutes, startTs: night.session.startAt)
            }
            SleepStageSummaryCardsView(
                deep: SleepFormat.duration(night.deepMinutes),
                light: SleepFormat.duration(night.lightMinutes),
                awake: SleepFormat.duration(night.awakeMinutes)
            )
            summaryCard(daySummary, fallback: coach)
        } else {
            let noData = SleepInsights.noDataState(.day)
            SleepHeroCardView(label: noData.label, value: noData.value, support: noData.support, score: nil, noData: true)
            VisualizationCard(eyebrow: "Stages", title: "Sleep architecture", legend: false) {
                InlineEmptyState(title: "No sleep recorded", message: "Wear your ring overnight to see your hypnogram here.")
                    .frame(height: 180)
            }
            SleepStageSummaryCardsView(deep: "—", light: "—", awake: "—")
            if coachEnabled {
                CoachMessageCard(headline: SleepInsights.dayNoDataCoach.headline, body: SleepInsights.dayNoDataCoach.body, chips: SleepInsights.dayNoDataCoach.chips)
            }
        }
    }

    // MARK: Aggregate

    @ViewBuilder
    private func aggregateView(summary: SleepRangeSummary, goalMin: Int?) -> some View {
        let valid = SleepInsights.validSessions(summary.sessions)
        let enough = valid.count >= 2
        let avgMin = SleepInsights.averageDuration(valid)
        let avgScore = SleepInsights.averageScore(valid)
        let stageAvg = SleepInsights.averageStages(valid)
        let coach = SleepInsights.aggregateCoach(range: range, sessions: summary.sessions, expectedNights: summary.expectedNights, goalMin: goalMin)
        let noData = SleepInsights.noDataState(range)
        let heroSupport = range == .year
            ? "Tracked \(valid.count) \(valid.count == 1 ? "night" : "nights") this year"
            : "\(valid.count) of \(summary.expectedNights) nights tracked"
        let bars = range == .year
            ? SleepInsights.buildMonthBuckets(end: summary.end, sessions: summary.sessions)
            : SleepInsights.buildNightAxis(start: summary.start, end: summary.end, sessions: summary.sessions, range: range)
        let vizTitle = range == .year ? "Monthly average" : "Nightly sleep"

        SleepHeroCardView(
            label: SleepInsights.rangeHeroLabel[range] ?? "Sleep",
            value: enough ? SleepFormat.duration(avgMin) : noData.value,
            support: heroSupport,
            score: enough ? avgScore : nil,
            scoreLabel: enough ? avgScore.map { SleepScore.qualityLabel($0).rawValue } : nil,
            noData: !enough
        )
        VisualizationCard(eyebrow: "Duration", title: vizTitle, legend: false) {
            SleepDurationHistogramChart(bars: bars, goalMin: goalMin, slim: range == .month, barWidth: range == .week ? 30 : nil, weekBars: range == .week)
        }
        SleepStageSummaryCardsView(
            prefix: "Avg ",
            deep: stageAvg.map { SleepFormat.duration($0.deep) } ?? "—",
            light: stageAvg.map { SleepFormat.duration($0.light) } ?? "—",
            awake: stageAvg.map { SleepFormat.duration($0.awake) } ?? "—"
        )
        summaryCard(rangeSummary(range), fallback: coach)
    }
}

/// Card wrapper for sleep visualizations (eyebrow + title + optional stage legend).
private struct VisualizationCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let legend: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(eyebrow.uppercased()).font(.system(size: 11, weight: .medium)).tracking(1.8).foregroundStyle(PulseColors.textMuted)
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
                }
                Spacer()
                if legend {
                    HStack(spacing: 8) {
                        legendItem("Deep", SleepStageColors.deep)
                        legendItem("Light", SleepStageColors.light)
                        legendItem("REM", SleepStageColors.rem)
                        legendItem("Awake", SleepStageColors.awake)
                    }
                    .fixedSize()
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundStyle(PulseColors.textSecondary)
        }
    }
}
