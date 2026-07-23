import SwiftUI
import SwiftData

/// The full calorie-tracking page (pushed via `AppRoute.nutrition`): calorie budget hero,
/// macro progress, and the day's meals grouped by meal type. Day navigation via chevrons.
/// Only reachable when the nutrition feature is enabled — entry points are gated.
struct NutritionView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var path: NavigationPath

    @State private var dataChange = PulseDataChange.shared
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    // Cached off the render path (reload() on token/day change), mirroring ActivityView —
    // an @Query invalidation re-running the fetch every body eval flashes glass on iOS 26.
    @State private var entries: [MealEntry] = []
    @State private var totals = NutritionDayTotals()
    @State private var goals: GoalsSummary?
    @State private var burned: Double?
    @State private var hasEverLogged = true
    @State private var logSheet: LogSheetRequest?
    @State private var analysisSheet: AnalysisRequest?

    private struct LogSheetRequest: Identifiable {
        let id = UUID()
        var mealType: MealType
        var editingId: UUID?
    }

    private struct AnalysisRequest: Identifiable {
        let id = UUID()
        var startWithCamera: Bool
    }

    /// AI photo analysis needs the coach on, a provider that accepts images (not on-device),
    /// and the nutrition photo-analysis sub-toggle.
    private var photoAnalysisAvailable: Bool {
        let coach = CoachSettingsStore.shared.settings
        return coach.coachMasterEnabled
            && coach.providerMode != .appleOnDevice
            && NutritionPrefsStore.shared.prefs.photoAnalysisEnabled
    }

    /// Text describe-analysis needs a cloud provider too (the on-device path can't run the
    /// structured estimator).
    private var describeAnalysisAvailable: Bool {
        let coach = CoachSettingsStore.shared.settings
        return coach.coachMasterEnabled && coach.providerMode != .appleOnDevice
    }

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDay) }

    private func reload() {
        entries = NutritionRepository.entries(on: selectedDay, context: modelContext)
        totals = NutritionRepository.totals(of: entries)
        let summary = MetricsService.buildTodaySummary(context: modelContext)
        goals = summary.goals
        burned = isToday ? summary.calories : nil
        hasEverLogged = NutritionRepository.hasAnyEntry(context: modelContext)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                dayHeader

                if !hasEverLogged && isToday {
                    NutritionEmptyStateCard()
                }

                CalorieBudgetGauge(totals: totals, goal: goals?.intakeCalories, burned: burned)

                DetailCard(title: "Macros", color: PulseColors.calories) {
                    VStack(spacing: 14) {
                        MacroProgressRow(kind: .protein, consumed: totals.proteinG, goal: goals?.intakeProteinG)
                        MacroProgressRow(kind: .carbs, consumed: totals.carbsG, goal: goals?.intakeCarbsG)
                        MacroProgressRow(kind: .fat, consumed: totals.fatG, goal: goals?.intakeFatG)
                    }
                    .padding(.top, 14)
                }

                logActions

                mealGroups
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .background(PulseColors.background)
        .pageChrome("Nutrition") {
            Button { path.append(AppRoute.settingsNutrition) } label: {
                Image(systemName: "gearshape")
                    .font(PulseFont.bodyEmphasis)
                    .foregroundStyle(PulseColors.textPrimary)
                    .frame(width: 36, height: 36)
                    .pulseGlass(Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Nutrition settings")
        }
        .pulseScrollEdges()
        .task(id: dataChange.token) { reload() }
        .onChange(of: selectedDay) { _, _ in reload() }
        .sheet(item: $logSheet) { request in
            MealLogSheet(day: selectedDay, presetMealType: request.mealType, editingId: request.editingId)
        }
        .sheet(item: $analysisSheet) { request in
            MealAnalysisSheet(day: selectedDay, startWithCamera: request.startWithCamera)
        }
    }

    /// Quick log actions: AI photo / AI describe (gated on provider capability) + search/manual.
    private var logActions: some View {
        HStack(spacing: 10) {
            if photoAnalysisAvailable {
                logPill("camera", "Photo") { analysisSheet = AnalysisRequest(startWithCamera: true) }
            }
            if describeAnalysisAvailable {
                logPill("sparkles", "Describe") { analysisSheet = AnalysisRequest(startWithCamera: false) }
            }
            logPill("magnifyingglass", "Search") { logSheet = LogSheetRequest(mealType: MealType.inferred()) }
        }
        .pulseGlassContainer(spacing: 10)
    }

    private func logPill(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(PulseFont.title3.weight(.regular))
                    .foregroundStyle(PulseColors.calories)
                Text(label)
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous), interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Day navigation

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    private var dayTitle: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(selectedDay) { return "Yesterday" }
        return Self.dayFormatter.string(from: selectedDay)
    }

    private var dayHeader: some View {
        HStack {
            dayChevron("chevron.left", enabled: true) { shiftDay(-1) }
            Spacer()
            VStack(spacing: 2) {
                Text(dayTitle.uppercased())
                    .font(PulseFont.caption2)
                    .tracking(1.4)
                    .foregroundStyle(PulseColors.textMuted)
                Text("\(totals.entryCount) \(totals.entryCount == 1 ? "entry" : "entries")")
                    .font(PulseFont.caption.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
            }
            Spacer()
            dayChevron("chevron.right", enabled: !isToday) { shiftDay(1) }
        }
    }

    private func dayChevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(PulseFont.bodyEmphasis)
                .foregroundStyle(enabled ? PulseColors.textPrimary : PulseColors.textMuted.opacity(0.4))
                .frame(width: 36, height: 36)
                .pulseGlass(Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func shiftDay(_ delta: Int) {
        guard let day = Calendar.current.date(byAdding: .day, value: delta, to: selectedDay) else { return }
        selectedDay = min(Calendar.current.startOfDay(for: day), Calendar.current.startOfDay(for: Date()))
    }

    // MARK: - Meal groups

    private var mealGroups: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(MealType.allCases, id: \.self) { mealType in
                let group = entries.filter { $0.mealType == mealType }
                // Past days hide empty sections; today shows a ghost add-row per empty group.
                if !group.isEmpty || isToday {
                    mealGroup(mealType, entries: group)
                }
            }
        }
    }

    @ViewBuilder
    private func mealGroup(_ mealType: MealType, entries groupEntries: [MealEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(headerText(mealType, groupEntries))
                    .font(PulseFont.caption2)
                    .tracking(1.4)
                    .foregroundStyle(PulseColors.textMuted)
                Spacer()
                Button { logSheet = LogSheetRequest(mealType: mealType) } label: {
                    Image(systemName: "plus")
                        .font(PulseFont.footnote.weight(.semibold))
                        .foregroundStyle(PulseColors.textPrimary)
                        .frame(width: 28, height: 28)
                        .pulseGlass(Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(mealType.label.lowercased())")
            }
            if groupEntries.isEmpty {
                Button { logSheet = LogSheetRequest(mealType: mealType) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(PulseFont.subheadline)
                        Text("Add \(mealType.label.lowercased())")
                            .font(PulseFont.subheadline)
                    }
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ForEach(groupEntries) { entry in
                    MealEntryRow(entry: entry) { path.append(AppRoute.mealDetail(entry.id)) }
                        .contextMenu {
                            Button {
                                logSheet = LogSheetRequest(mealType: entry.mealType, editingId: entry.id)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                NutritionRepository.delete(id: entry.id, context: modelContext)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    private func headerText(_ mealType: MealType, _ groupEntries: [MealEntry]) -> String {
        let kcal = groupEntries.reduce(0) { $0 + $1.calories }
        guard !groupEntries.isEmpty else { return mealType.label.uppercased() }
        return "\(mealType.label.uppercased()) · \(NutritionFormat.kcal(kcal)) KCAL"
    }
}
