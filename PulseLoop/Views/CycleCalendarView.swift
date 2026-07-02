import SwiftUI
import SwiftData

/// Month grid for the cycle detail screen: logged period days filled, predicted period days
/// tinted, the fertile window softly highlighted, ovulation starred, disturbed nights dotted.
/// Tapping any past-or-today day opens the quick log sheet.
struct CycleMonthCalendar: View {
    let month: Date                       // any day inside the displayed month
    let overview: CycleOverview
    let today: Date
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

        let isPredictedPeriod = predictedPeriodDays?.contains(day) ?? false
        let inFertileWindow = analysis?.fertileWindow?.contains(day) ?? false
        let ovulation = analysis?.ovulation.estimatedDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false

        return Button {
            onSelect(day)
        } label: {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(background(facts: facts, predicted: isPredictedPeriod, fertile: inFertileWindow))
                    .overlay(Circle().stroke(isToday ? PulseColors.accent : .clear, lineWidth: 1.5))
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 13, weight: facts?.isPeriod == true ? .semibold : .regular))
                    .foregroundStyle(facts?.isPeriod == true ? Color.white : (isFuture ? PulseColors.textMuted : PulseColors.textPrimary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if ovulation {
                    Image(systemName: analysis?.ovulation.isConfirmed == true ? "star.fill" : "star")
                        .font(.system(size: 8))
                        .foregroundStyle(PulseColors.cycleLuteal)
                        .offset(x: 1, y: -1)
                }
                if facts?.isDisturbed == true {
                    Circle()
                        .fill(PulseColors.warning)
                        .frame(width: 5, height: 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .offset(y: -2)
                }
            }
            .frame(height: 40)
            .opacity(isFuture ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }

    private func background(facts: CycleOverview.CycleDayFacts?, predicted: Bool, fertile: Bool) -> Color {
        if facts?.isPeriod == true { return PulseColors.cycle }
        if predicted { return PulseColors.cycle.opacity(0.20) }
        if fertile { return PulseColors.cycleFertile.opacity(0.12) }
        return PulseColors.cardSoft.opacity(0.5)
    }

    /// Predicted flow days: the expected start plus a typical 5-day period, future only.
    private var predictedPeriodDays: [Date]? {
        guard let expected = overview.analysis?.nextPeriod?.expected, expected > today else { return nil }
        return (0..<5).compactMap { calendar.date(byAdding: .day, value: $0, to: expected) }
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
