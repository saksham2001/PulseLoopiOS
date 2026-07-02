import SwiftUI
import SwiftData

private let weekLabels = ["M", "T", "W", "T", "F", "S", "S"]

struct ActivityView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query(sort: \ActivitySession.startedAt, order: .reverse) private var sessions: [ActivitySession]
    @Query private var profiles: [UserProfile]
    @Binding var path: NavigationPath

    private var units: UnitsPreference { profiles.first?.units ?? .metric }

    @State private var goalsOpen = false
    @State private var historyOpen = false

    var body: some View {
        let summary = MetricsService.buildTodaySummary(context: modelContext)
        let stale = ActivityRecorderService.recoverStaleSession(context: modelContext)
        let todayWorkouts = sessions.filter { $0.status == .finished && Calendar.current.isDateInToday($0.startedAt) }
        let stepGoal = summary.goals.stepsDaily
        let activeGoal = summary.goals.activeMinutesDaily
        let todayIdx = todayWeekIndex()
        let days = weeklyDays(summary: summary, stepGoal: stepGoal, todayIndex: todayIdx)
        let activeDayCount = days.filter(\.completed).count

        ScrollView {
            VStack(spacing: 16) {
                if !stale.isEmpty {
                    StaleSessionRecoveryCard(sessions: stale)
                }

                DailyActivitySummaryCard(
                    summary: summary,
                    units: units,
                    caloriesAvailable: MetricsService.isVisible(.calories, context: modelContext)
                ) {
                    path.append(AppRoute.activityTrends)
                }

                HStack(spacing: 12) {
                    Button { path.append(AppRoute.recordSelect) } label: {
                        Text("+ Record Activity")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .foregroundStyle(.white)
                            .background(PulseColors.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button { historyOpen = true } label: {
                        Image(systemName: "calendar")
                            .font(.system(size: 18))
                            .foregroundStyle(PulseColors.textSecondary)
                            .frame(width: 60, height: 60)
                            .background(PulseColors.card, in: Circle())
                            .overlay(Circle().stroke(PulseColors.borderSubtle, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                // Today's workouts
                VStack(alignment: .leading, spacing: 8) {
                    Text("TODAY").font(.system(size: 11, weight: .medium)).tracking(1.4)
                        .foregroundStyle(PulseColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if todayWorkouts.isEmpty {
                        VStack(spacing: 4) {
                            Text("No workouts recorded today").font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
                            Text("Start one manually when your ring misses an activity.").font(.system(size: 12)).foregroundStyle(PulseColors.textMuted)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                        .background(PulseColors.card).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
                    } else {
                        ForEach(todayWorkouts) { session in
                            ActivityWorkoutRow(session: session) { path.append(AppRoute.activityDetail(session.id)) }
                        }
                    }
                }

                // Weekly goal widget
                Button { goalsOpen = true } label: {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 16) {
                            ProgressRingView(value: Double(summary.activeMinutes ?? 0), max: Double(activeGoal), color: PulseColors.steps) {
                                VStack(spacing: 0) {
                                    Text("\(summary.activeMinutes ?? 0)").font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                                    Text("MIN").font(.system(size: 10, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("WEEKLY GOAL").font(.system(size: 11, weight: .medium)).tracking(1.4).foregroundStyle(PulseColors.textMuted)
                                Text("\(activeDayCount) of 7 active days").font(.system(size: 16)).foregroundStyle(PulseColors.textPrimary)
                            }
                            Spacer(minLength: 0)
                        }
                        WeeklyPillCalendarView(days: days)
                        Text("TAP TO EDIT GOALS").font(.system(size: 10, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(PulseColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .background(PulseColors.background)
        .refreshable { await coordinator.pullToRefresh() }
        .sheet(isPresented: $goalsOpen) { GoalEditorSheet() }
        .sheet(isPresented: $historyOpen) {
            WorkoutHistorySheet { id in
                historyOpen = false
                path.append(AppRoute.activityDetail(id))
            }
        }
    }

    // MARK: data

    private func weeklyDays(summary: TodaySummary, stepGoal: Int, todayIndex: Int) -> [WeeklyDay] {
        let steps = summary.trends.steps7d.map(\.value)
        return weekLabels.indices.map { i in
            WeeklyDay(
                label: weekLabels[i],
                completed: Int(steps.indices.contains(i) ? steps[i] : 0) >= stepGoal,
                isToday: i == todayIndex
            )
        }
    }

    private func todayWeekIndex() -> Int {
        let weekday = Calendar.current.component(.weekday, from: Date()) // 1=Sun..7=Sat
        let jsDay = weekday - 1
        return (jsDay + 6) % 7
    }
}

// MARK: - Daily activity summary widget

/// Full-width Apple-Fitness-style daily summary: colored Steps / Distance / Calories metrics on the
/// left, three concentric progress rings on the right (outer→inner: steps, distance, calories). Reads
/// the same daily totals and goals the page already uses; tapping opens the Activity Trends detail.
/// Missing (nil) metrics render an em dash and an inactive ring — the ring math is nil/zero-safe.
struct DailyActivitySummaryCard: View {
    let summary: TodaySummary
    let units: UnitsPreference
    /// Whether the paired ring supports active-energy tracking. When false, calories are treated as
    /// unavailable (em dash + inactive ring) rather than showing whatever raw value the ring reports.
    var caloriesAvailable: Bool = true
    var onTap: () -> Void

    /// Calories only when the device actually tracks them; otherwise nil so text shows "—" and the
    /// ring stays a muted track (matches the Today page's `isVisible(.calories)` gating).
    private var effectiveCalories: Double? { caloriesAvailable ? summary.calories : nil }

    private var distanceUnit: String { UnitsFormatter.distance(meters: 0, units: units).unit }
    private var distanceValue: String? { summary.distanceMeters.map { UnitsFormatter.distance(meters: $0, units: units).value } }
    /// Goal distance converted to the display unit, matching `distanceValue`, so the ring and text agree.
    private var distanceGoalDisplay: Double {
        Double(UnitsFormatter.distance(meters: summary.goals.distanceMetersDaily, units: units).value) ?? 0
    }
    private var distanceDisplay: Double? {
        summary.distanceMeters.flatMap { Double(UnitsFormatter.distance(meters: $0, units: units).value) }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 0) {
                            metric(label: "Steps", value: summary.steps.map { $0.formatted() } ?? "—", unit: nil, color: PulseColors.steps)
                            metric(label: "Distance", value: distanceValue ?? "—", unit: distanceValue == nil ? nil : distanceUnit, color: PulseColors.distance)
                        }
                        metric(label: "Calories", value: effectiveCalories.map { Int($0).formatted() } ?? "—", unit: effectiveCalories == nil ? nil : "cal", color: PulseColors.calories)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ActivityRingsView(rings: [
                        ActivityRing(value: summary.steps.map(Double.init), goal: Double(summary.goals.stepsDaily), color: PulseColors.steps),
                        ActivityRing(value: distanceDisplay, goal: distanceGoalDisplay, color: PulseColors.distance),
                        ActivityRing(value: effectiveCalories, goal: Double(summary.goals.caloriesDaily), color: PulseColors.calories)
                    ], size: 112, stroke: 11, spacing: 5)
                    .frame(width: 112, height: 112)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func metric(label: String, value: String, unit: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 15, weight: .bold)).tracking(0.6)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let unit {
                    Text(unit).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Goal editor

struct GoalEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]
    @State private var steps: Double = 8000
    @State private var activeMinutes: Double = 60
    @State private var sleepHours: Double = 8
    @State private var workouts: Double = 4
    /// Distance goal edited in the user's display unit (km or mi); persisted as metres.
    @State private var distance: Double = 5
    @State private var calories: Double = 500
    @State private var loaded = false

    private var units: UnitsPreference { profiles.first?.units ?? .metric }
    private var distanceUnit: String { UnitsFormatter.distance(meters: 0, units: units).unit }
    private var metersPerUnit: Double { units == .metric ? 1000 : 1609.344 }
    private var distanceRange: ClosedRange<Double> { units == .metric ? 1...30 : 1...20 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Daily targets") {
                    stepper("Steps", value: $steps, range: 2000...20000, step: 500, format: { "\(Int($0).formatted())" })
                    stepper("Distance", value: $distance, range: distanceRange, step: 0.5, format: { String(format: "%.1f \(distanceUnit)", $0) })
                    stepper("Calories", value: $calories, range: 100...2000, step: 50, format: { "\(Int($0)) cal" })
                    stepper("Active minutes", value: $activeMinutes, range: 10...180, step: 5, format: { "\(Int($0)) min" })
                    stepper("Sleep", value: $sleepHours, range: 5...10, step: 0.5, format: { String(format: "%.1f h", $0) })
                }
                Section("Weekly target") {
                    stepper("Workouts", value: $workouts, range: 1...7, step: 1, format: { "\(Int($0)) / week" })
                }
            }
            .navigationTitle("Edit goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: load)
    }

    private func stepper(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack { Text(label); Spacer(); Text(format(value.wrappedValue)).foregroundStyle(.secondary) }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let goal = MetricsRepository.goals(context: modelContext) {
            steps = Double(goal.steps)
            activeMinutes = Double(goal.activeMinutes)
            sleepHours = Double(goal.sleepMinutes) / 60
            workouts = Double(goal.workoutsPerWeek)
            distance = (goal.distanceMeters / metersPerUnit).rounded(toPlaces: 1)
            calories = Double(goal.calories)
        }
    }

    private func save() {
        let goal = MetricsRepository.goals(context: modelContext) ?? {
            let g = UserGoal()
            modelContext.insert(g)
            return g
        }()
        goal.steps = Int(steps)
        goal.activeMinutes = Int(activeMinutes)
        goal.sleepMinutes = Int(sleepHours * 60)
        goal.workoutsPerWeek = Int(workouts)
        goal.distanceMeters = distance * metersPerUnit
        goal.calories = Int(calories)
        goal.updatedAt = Date()
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Workout history

struct WorkoutHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ActivitySession.startedAt, order: .reverse) private var sessions: [ActivitySession]
    let onSelect: (UUID) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    let finished = sessions.filter { $0.status == .finished }
                    if finished.isEmpty {
                        EmptyStateView(title: "No workouts yet", body: "Recorded workouts will appear here.")
                    } else {
                        ForEach(finished) { session in
                            ActivityWorkoutRow(session: session) { onSelect(session.id) }
                        }
                    }
                }
                .padding()
            }
            .background(PulseColors.background)
            .navigationTitle("Workout history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
