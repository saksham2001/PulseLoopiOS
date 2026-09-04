import SwiftUI
import SwiftData

/// Full cycle screen behind the Vitals card: phase ring + countdown, BBT chart with the
/// coverline (browsable across past cycles), the month calendar for retro-logging, and the
/// cycle-length history. Read-only except the log sheet and the one-tap period button.
struct CycleDetailView: View {
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    @State private var overview: CycleOverview?
    @State private var settings = CycleSettingsStore.shared
    @State private var dataChange = PulseDataChange.shared
    @State private var displayedMonth = Date()
    @State private var logItem: CycleLogItem?
    /// 0 = current cycle; 1…n = completed cycles counting back from the most recent.
    @State private var cycleOffset = 0
    @State private var pastChartDays: [CycleChartDay] = []
    @State private var dismissedSuggestion: Date?

    private var units: UnitsPreference { profiles.first?.units ?? .metric }
    private var hormonal: Bool { settings.settings.onHormonalContraception }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let overview {
                    content(overview)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .background(PulseColors.background)
        .navigationTitle("Cycle")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { path.append(AppRoute.settingsCycle) } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .task { reload() }
        .onChange(of: dataChange.token) { _, _ in reload() }
        .sheet(item: $logItem) { item in
            CycleLogSheet(date: item.date) { reload() }
        }
    }

    @ViewBuilder
    private func content(_ overview: CycleOverview) -> some View {
        if let analysis = overview.analysis {
            if let suggestion = analysis.disturbanceSuggestion, suggestion != dismissedSuggestion {
                disturbanceBanner(suggestion)
            }
            ForEach(bannersToShow(analysis), id: \.self) { message in
                StatusCopy(title: "Heads-up", body: message)
            }
            statusCard(analysis)
            if CycleCopy.shouldOfferPeriodStart(analysis) {
                PeriodStartButton { logPeriod(on: Date()) }
            }
            if !hormonal {
                chartCard(analysis)
            }
            calendarCard(overview)
            if !analysis.completedCycles.isEmpty {
                historyCard(analysis)
            }
        } else {
            emptyStateCard
            calendarCard(overview)
        }
        footer
    }

    // MARK: - Status

    private func statusCard(_ analysis: CycleAnalysis) -> some View {
        PulseCard {
            VStack(spacing: 14) {
                CyclePhaseRing(segments: ringSegments(analysis), progress: ringProgress(analysis)) {
                    VStack(spacing: 2) {
                        Text("Day \(analysis.dayNumber)")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .foregroundStyle(PulseColors.textPrimary)
                        Text(CycleCopy.phaseLabel(analysis, hormonal: hormonal))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(PulseColors.textSecondary)
                    }
                }
                .frame(height: 190)

                Text(CycleCopy.headline(analysis, hormonal: hormonal))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(PulseColors.textPrimary)

                if let prediction = analysis.nextPeriod, !hormonal {
                    Text(predictionLine(prediction))
                        .font(.system(size: 12))
                        .foregroundStyle(PulseColors.textMuted)
                } else if analysis.completedCycles.isEmpty && !hormonal {
                    Text("First cycle — predictions unlock once one full cycle is logged.")
                        .font(.system(size: 12))
                        .foregroundStyle(PulseColors.textMuted)
                }
                legend
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func predictionLine(_ prediction: PeriodPrediction) -> String {
        let expected = prediction.expected.formatted(.dateTime.day().month(.wide))
        let earliest = prediction.earliest.formatted(.dateTime.day())
        let latest = prediction.latest.formatted(.dateTime.day().month(.abbreviated))
        return "Next period around \(expected) (\(earliest)–\(latest))"
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(PulseColors.cycle, "Period")
            if !hormonal {
                legendDot(PulseColors.cycleFertile, "Fertile")
                legendDot(PulseColors.cycleLuteal, "Luteal")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(PulseColors.textMuted)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private func chartCard(_ analysis: CycleAnalysis) -> some View {
        let past = analysis.completedCycles
        PulseCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Basal temperature")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PulseColors.textPrimary)
                    Spacer()
                    if !past.isEmpty {
                        cycleSelector(pastCount: past.count)
                    }
                }
                if cycleOffset == 0 {
                    CycleBBTChart(
                        days: overview?.chartDays ?? [],
                        coverline: analysis.coverline,
                        fertileWindow: analysis.drawnFertileWindow(),
                        units: units
                    )
                } else {
                    CycleBBTChart(days: pastChartDays, coverline: nil, fertileWindow: nil, units: units)
                }
                Text(cycleOffset == 0
                     ? "Nightly medians of your ring's sleep temperature. Hollow points are excluded nights."
                     : pastCycleCaption(past))
                    .font(.system(size: 11))
                    .foregroundStyle(PulseColors.textMuted)
            }
        }
    }

    private func cycleSelector(pastCount: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                setCycleOffset(min(cycleOffset + 1, pastCount))
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .disabled(cycleOffset >= pastCount)
            Text(cycleOffset == 0 ? "Current" : "−\(cycleOffset)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PulseColors.textSecondary)
                .frame(minWidth: 52)
            Button {
                setCycleOffset(max(cycleOffset - 1, 0))
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
            .disabled(cycleOffset == 0)
        }
        .foregroundStyle(PulseColors.textSecondary)
    }

    private func pastCycleCaption(_ past: [CompletedCycleSummary]) -> String {
        guard cycleOffset >= 1, cycleOffset <= past.count else { return "" }
        let cycle = past[past.count - cycleOffset]
        var caption = "Started \(cycle.start.formatted(.dateTime.day().month(.abbreviated))) · \(cycle.lengthDays) days"
        if let index = cycle.ovulationDayIndex {
            caption += " · est. ovulation day \(index + 1)"
        }
        return caption
    }

    private func setCycleOffset(_ offset: Int) {
        cycleOffset = offset
        guard offset >= 1, let past = overview?.analysis?.completedCycles, offset <= past.count else { return }
        pastChartDays = CycleService.chartDays(for: past[past.count - offset], context: modelContext)
    }

    // MARK: - Calendar

    private func calendarCard(_ overview: CycleOverview) -> some View {
        PulseCard {
            VStack(spacing: 10) {
                HStack {
                    Button {
                        displayedMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                    } label: {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                    Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PulseColors.textPrimary)
                    Spacer()
                    Button {
                        displayedMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                    } label: {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(PulseColors.textSecondary)

                CycleMonthCalendar(month: displayedMonth, overview: overview, today: Date()) { day in
                    logItem = CycleLogItem(date: day)
                }
                CycleCalendarLegend(showFertility: !hormonal)
                    .padding(.top, 2)
                Text("Tap a day to log a period or exclude a disturbed night.")
                    .font(.system(size: 11))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - History

    private func historyCard(_ analysis: CycleAnalysis) -> some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Past cycles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                ForEach(analysis.completedCycles.suffix(6).reversed()) { cycle in
                    HStack {
                        Text(cycle.start.formatted(.dateTime.day().month(.abbreviated).year(.twoDigits)))
                            .font(.system(size: 13))
                            .foregroundStyle(PulseColors.textSecondary)
                        Spacer()
                        if let luteal = cycle.lutealDays {
                            Text("luteal \(luteal) d")
                                .font(.system(size: 11))
                                .foregroundStyle(PulseColors.textMuted)
                        }
                        Text("\(cycle.lengthDays) days")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(PulseColors.textPrimary)
                    }
                }
                if let typical = analysis.typicalCycleLengthDays {
                    Text("Typical length \(typical) days · luteal phase \(analysis.lutealLengthDays) days")
                        .font(.system(size: 11))
                        .foregroundStyle(PulseColors.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Banners & empty state

    private func disturbanceBanner(_ night: Date) -> some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Last night looks unusual", systemImage: "thermometer.variable.and.figure")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PulseColors.warning)
                Text("The night of \(night.formatted(.dateTime.day().month(.wide))) ran well above your recent "
                     + "baseline — fever, alcohol, or a bad night can do that. Exclude it from the analysis?")
                    .font(.system(size: 13))
                    .foregroundStyle(PulseColors.textSecondary)
                HStack(spacing: 8) {
                    QuickActionButton(label: "Exclude night", accent: true) { excludeNight(night) }
                    QuickActionButton(label: "Keep it") { dismissedSuggestion = night }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyStateCard: some View {
        PulseCard {
            VStack(spacing: 12) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 34))
                    .foregroundStyle(PulseColors.cycle)
                Text("Start with day 1")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(PulseColors.textPrimary)
                Text("Log the first day of your period — that's the only input needed. Overnight temperatures "
                     + "from your ring do the rest. You can backfill past days from the calendar below.")
                    .font(.system(size: 13))
                    .foregroundStyle(PulseColors.textSecondary)
                    .multilineTextAlignment(.center)
                PeriodStartButton { logPeriod(on: Date()) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        Text("Estimates only — not clinically validated, not a medical device, and never a contraception method.")
            .font(.system(size: 10))
            .foregroundStyle(PulseColors.textMuted)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    private func bannersToShow(_ analysis: CycleAnalysis) -> [String] {
        var messages: [String] = []
        if hormonal {
            messages.append("Hormonal contraception suppresses ovulation, so temperature analysis and fertility "
                + "estimates are paused. Period logging and the calendar still work.")
        }
        if settings.settings.goal == .avoid && !hormonal {
            messages.append("Reminder: the fertile window shown is deliberately widened, but PulseLoop is not a contraception method.")
        }
        messages.append(contentsOf: analysis.flags.map(CycleCopy.flagMessage))
        return messages
    }

    // MARK: - Ring math

    /// Arc segments for the phase ring, over a full turn representing the expected cycle.
    private func ringSegments(_ analysis: CycleAnalysis) -> [CyclePhaseSegment] {
        let calendar = Calendar.current
        let total = Double(ringTotalDays(analysis))
        var segments: [CyclePhaseSegment] = []

        // Leading run of logged period days (at least the derived day 1).
        var periodLength = 0
        for day in overview?.chartDays ?? [] {
            if day.isPeriod { periodLength += 1 } else { break }
        }
        periodLength = max(periodLength, 1)
        segments.append(CyclePhaseSegment(start: 0, end: Double(periodLength) / total, color: PulseColors.cycle))

        guard !hormonal else { return segments }

        if let window = analysis.drawnFertileWindow(calendar: calendar) {
            let startIndex = max(0, CycleAnalyzer.daysBetween(analysis.cycleStart, window.lowerBound, calendar: calendar))
            let endIndex = CycleAnalyzer.daysBetween(analysis.cycleStart, window.upperBound, calendar: calendar) + 1
            if endIndex > startIndex {
                segments.append(CyclePhaseSegment(
                    start: min(Double(startIndex) / total, 1),
                    end: min(Double(endIndex) / total, 1),
                    color: PulseColors.cycleFertile.opacity(0.85)
                ))
            }
            if analysis.ovulation.isConfirmed {
                segments.append(CyclePhaseSegment(
                    start: min(Double(endIndex) / total, 1),
                    end: 1,
                    color: PulseColors.cycleLuteal.opacity(0.7)
                ))
            }
        }
        return segments
    }

    private func ringProgress(_ analysis: CycleAnalysis) -> Double {
        let total = Double(ringTotalDays(analysis))
        return min(Double(analysis.dayNumber - 1) / total, 0.999)
    }

    private func ringTotalDays(_ analysis: CycleAnalysis) -> Int {
        var total = analysis.typicalCycleLengthDays ?? 28
        if let prediction = analysis.nextPeriod {
            total = max(total, CycleAnalyzer.daysBetween(analysis.cycleStart, prediction.expected))
        }
        return max(total, analysis.dayNumber)
    }

    // MARK: - Actions

    private func reload() {
        overview = CycleService.overview(context: modelContext)
        if let past = overview?.analysis?.completedCycles, cycleOffset > past.count {
            cycleOffset = 0
        }
    }

    private func logPeriod(on date: Date) {
        let day = CycleRepository.dayOrNew(for: date, context: modelContext)
        day.isPeriod = true
        CycleRepository.save(day, context: modelContext)
        CycleNotificationCenter.shared.scheduleNext()
        reload()
    }

    private func excludeNight(_ night: Date) {
        let day = CycleRepository.dayOrNew(for: night, context: modelContext)
        day.isDisturbed = true
        day.disturbedAutoDetected = true
        CycleRepository.save(day, context: modelContext)
        reload()
    }
}

private struct CycleLogItem: Identifiable {
    let date: Date
    var id: Date { date }
}
