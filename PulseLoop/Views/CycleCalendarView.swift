import SwiftUI
import SwiftData

/// How one day of the month grid is shaded. Precedence is total and top-down — a logged flow day
/// beats a predicted one, which beats the fertile band, which beats the luteal phase — so every
/// day resolves to exactly one tint. Kept out of the view (and free of SwiftUI) so the date
/// arithmetic can be unit-tested on its own.
enum CycleCalendarShading: Equatable {
    case period
    case predictedPeriod
    case fertile
    case luteal
    case none

    /// A predicted period is drawn as the expected day plus a typical flow length.
    static let predictedFlowDays = 5

    /// Classify one day against the logged facts and the derived analysis.
    static func shading(
        for day: Date,
        overview: CycleOverview,
        today: Date,
        calendar: Calendar = .current
    ) -> CycleCalendarShading {
        let day = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: today)
        if overview.loggedDays[CycleDay.key(for: day)]?.isPeriod == true { return .period }
        guard let analysis = overview.analysis else { return .none }
        if isPredictedPeriod(day, analysis: analysis, today: today, calendar: calendar) { return .predictedPeriod }
        if analysis.drawnFertileWindow(calendar: calendar)?.contains(day) == true { return .fertile }
        if isLuteal(day, analysis: analysis, today: today, calendar: calendar) { return .luteal }
        return .none
    }

    /// Expected flow: the predicted start plus a typical period, drawn as soon as the expected day
    /// is today or later — the day the headline reads "Period due today" the flow is shaded from
    /// today on. Once the expected day has passed the period is late and nothing is drawn: past
    /// days show what the user actually logged, not what was forecast.
    private static func isPredictedPeriod(_ day: Date, analysis: CycleAnalysis, today: Date, calendar: Calendar) -> Bool {
        guard let predicted = analysis.nextPeriod?.expected else { return false }
        let expected = calendar.startOfDay(for: predicted)
        guard expected >= today, day >= expected else { return false }
        return CycleAnalyzer.daysBetween(expected, day, calendar: calendar) < predictedFlowDays
    }

    /// Luteal days of the running cycle *and* of every past cycle whose shift was detected.
    private static func isLuteal(_ day: Date, analysis: CycleAnalysis, today: Date, calendar: Calendar) -> Bool {
        if currentLutealRange(analysis, today: today, calendar: calendar)?.contains(day) == true { return true }
        return analysis.completedCycles.contains { completedLutealRange($0, calendar: calendar)?.contains(day) == true }
    }

    /// The running cycle's luteal band: from the day after the confirming high — the very test
    /// `CycleAnalyzer` uses to switch the phase — to the day before the next period. Only a
    /// *confirmed* shift draws it; while the rise is merely probable the days still read fertile.
    /// A prediction carries the band into the future; without one it stops at today.
    private static func currentLutealRange(_ analysis: CycleAnalysis, today: Date, calendar: Calendar) -> ClosedRange<Date>? {
        guard case let .confirmed(_, confirmedOn) = analysis.ovulation,
              let start = calendar.date(byAdding: .day, value: 1, to: confirmedOn) else { return nil }
        let end = analysis.nextPeriod.flatMap { calendar.date(byAdding: .day, value: -1, to: $0.expected) } ?? today
        return start <= end ? start...end : nil
    }

    /// A closed cycle's luteal band: the day after its estimated ovulation through the day before
    /// the period that ended it.
    private static func completedLutealRange(_ cycle: CompletedCycleSummary, calendar: Calendar) -> ClosedRange<Date>? {
        guard let ovulationIndex = cycle.ovulationDayIndex,
              let start = calendar.date(byAdding: .day, value: ovulationIndex + 1, to: cycle.start),
              let end = calendar.date(byAdding: .day, value: cycle.lengthDays - 1, to: cycle.start),
              start <= end else { return nil }
        return start...end
    }
}

/// Shading → paint. The opacities here are the *final* rendered strength, so no caller may dim a
/// cell on top of them: that double-dimming is exactly what washed predicted days out to nothing.
private extension CycleCalendarShading {
    var fill: Color {
        switch self {
        case .period: return PulseColors.cycle
        case .predictedPeriod: return PulseColors.cycle.opacity(0.22)
        case .fertile: return PulseColors.cycleFertile.opacity(0.30)
        case .luteal: return PulseColors.cycleLuteal.opacity(0.26)
        case .none: return PulseColors.cardSoft.opacity(0.5)
        }
    }

    /// Only predicted flow carries a ring — dashed, in the period color — so "expected" is told
    /// apart from "logged" by shape, not merely by how strong the pink is.
    var ring: (color: Color, style: StrokeStyle)? {
        guard self == .predictedPeriod else { return nil }
        return (PulseColors.cycle.opacity(0.85), StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
    }
}

/// The circle a day of the grid is drawn with. Shared with the legend so a swatch can never drift
/// from the cells it explains.
private struct CycleShadingCircle: View {
    let shading: CycleCalendarShading

    var body: some View {
        Circle()
            .fill(shading.fill)
            .overlay {
                if let ring = shading.ring {
                    Circle().strokeBorder(ring.color, style: ring.style)
                }
            }
    }
}

/// Month grid for the cycle detail screen: logged period days filled, predicted period days
/// tinted and dashed, the fertile window and the luteal phase highlighted, ovulation starred,
/// disturbed nights dotted. Tapping any past-or-today day opens the quick log sheet.
struct CycleMonthCalendar: View {
    let month: Date                       // any day inside the displayed month
    let overview: CycleOverview
    let today: Date
    /// Off under hormonal contraception, where the thermal analysis is paused.
    var showFertility = true
    let onSelect: (Date) -> Void

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 8) {
            weekdayHeader
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(monthDays, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
    }

    // MARK: - Cells

    private func dayCell(_ day: Date) -> some View {
        let facts = overview.loggedDays[CycleDay.key(for: day)]
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isFuture = day > today
        let analysis = overview.analysis
        let shading = shading(for: day)
        let ovulation = analysis?.ovulation.estimatedDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false

        // A fixed-size circle with the number drawn by the same center-aligned ZStack keeps the
        // digit dead-center; the star/disturbed markers live in overlays so they can't skew it.
        // A future day is dimmed through its *digit* only: fading the whole cell multiplied with
        // the fill's own opacity and left the predicted period at ~0.11, i.e. invisible.
        return Button {
            onSelect(day)
        } label: {
            ZStack {
                CycleShadingCircle(shading: shading)
                    .overlay(Circle().stroke(isToday ? PulseColors.accent : .clear, lineWidth: 1.5))
                    .frame(width: 36, height: 36)
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 13, weight: shading == .period ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(digitColor(shading: shading, isFuture: isFuture))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .overlay(alignment: .topTrailing) {
                if ovulation {
                    Image(systemName: analysis?.ovulation.isConfirmed == true ? "star.fill" : "star")
                        .font(.system(size: 8))
                        .foregroundStyle(PulseColors.cycleLuteal)
                        .offset(x: -2, y: 1)
                }
            }
            .overlay(alignment: .bottom) {
                if facts?.isDisturbed == true {
                    Circle()
                        .fill(PulseColors.warning)
                        .frame(width: 5, height: 5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }

    /// Fertility shading (fertile band, luteal phase) is dropped under hormonal contraception,
    /// where the thermal analysis is paused — the same gate the chart and the legend already use.
    private func shading(for day: Date) -> CycleCalendarShading {
        let shading = CycleCalendarShading.shading(for: day, overview: overview, today: today, calendar: calendar)
        if !showFertility, shading == .fertile || shading == .luteal { return .none }
        return shading
    }

    private func digitColor(shading: CycleCalendarShading, isFuture: Bool) -> Color {
        if shading == .period { return .white }
        return isFuture ? PulseColors.textMuted : PulseColors.textPrimary
    }

    // MARK: - Month math

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
    }

    private var monthDays: [Date] {
        let count = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: monthStart) }
    }

    private var leadingBlanks: Int {
        let weekday = calendar.component(.weekday, from: monthStart)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private var weekdayHeader: some View {
        let symbols = calendar.veryShortWeekdaySymbols
        let ordered = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        return HStack(spacing: 4) {
            ForEach(ordered.indices, id: \.self) { index in
                Text(ordered[index])
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Compact legend for the calendar's markers. Fertility items disappear in hormonal-
/// contraception mode, where the thermal analysis (and thus those markers) is paused.
struct CycleCalendarLegend: View {
    var showFertility = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                item(label: "Period") { CycleShadingCircle(shading: .period) }
                item(label: "Predicted") { CycleShadingCircle(shading: .predictedPeriod) }
                if showFertility {
                    item(label: "Fertile window") { CycleShadingCircle(shading: .fertile) }
                }
            }
            HStack(spacing: 14) {
                if showFertility {
                    item(label: "Luteal") { CycleShadingCircle(shading: .luteal) }
                    item(label: "Est. ovulation") {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(PulseColors.cycleLuteal)
                    }
                }
                item(label: "Excluded night") {
                    Circle().fill(PulseColors.warning).frame(width: 5, height: 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func item<Symbol: View>(label: String, @ViewBuilder symbol: () -> Symbol) -> some View {
        HStack(spacing: 5) {
            symbol()
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(PulseColors.textMuted)
        }
    }
}

/// Quick log sheet for one day — the *only* manual input the feature asks for: period yes/no,
/// disturbed night yes/no, optional note. Saving an all-empty day removes the row.
struct CycleLogSheet: View {
    let date: Date
    let onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var isPeriod = false
    @State private var isDisturbed = false
    @State private var notes = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(date.formatted(date: .complete, time: .omitted))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(PulseColors.textPrimary)

            toggleRow("Period", subtitle: "A flow day — day 1 is worked out automatically", isOn: $isPeriod)
            toggleRow("Disturbed night", subtitle: "Fever, illness, alcohol… excludes it from the analysis", isOn: $isDisturbed)

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PulseColors.textSecondary)
                TextField("Optional", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(PulseColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
            }

            PrimaryButton(title: "Save", systemImage: "checkmark") { save() }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PulseColors.background)
        .presentationDetents([.medium])
        .onAppear { loadIfNeeded() }
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(PulseColors.textMuted)
            }
        }
        .tint(PulseColors.accent)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let existing = CycleRepository.day(for: date, context: modelContext) else { return }
        isPeriod = existing.isPeriod
        isDisturbed = existing.isDisturbed
        notes = existing.notes ?? ""
    }

    private func save() {
        let day = CycleRepository.dayOrNew(for: date, context: modelContext)
        day.isPeriod = isPeriod
        day.isDisturbed = isDisturbed
        // A manual edit of the toggle overrides any auto-detection provenance.
        if !isDisturbed { day.disturbedAutoDetected = false }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        day.notes = trimmed.isEmpty ? nil : trimmed
        CycleRepository.save(day, context: modelContext)
        CycleNotificationCenter.shared.scheduleNext()
        onSaved()
        dismiss()
    }
}
