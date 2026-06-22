import SwiftUI
import SwiftData

private let weekLabels = ["M", "T", "W", "T", "F", "S", "S"]

struct ActivityView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query(sort: \ActivitySession.startedAt, order: .reverse) private var sessions: [ActivitySession]
    @Binding var path: NavigationPath

    @State private var stepsRange: MetricRange = .sevenDays
    @State private var distanceRange: MetricRange = .sevenDays
    @State private var caloriesRange: MetricRange = .sevenDays
    @State private var goalsOpen = false
    @State private var historyOpen = false

    private var isImperial: Bool { WorkoutAppGroup.useImperialUnits }
    private var distanceDivisor: Double { isImperial ? 1609.34 : 1000.0 }
    private var distanceUnit: String { isImperial ? "mi" : "km" }

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
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activity").font(.system(size: 26, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
                        Text("Record workouts and track movement from your ring")
                            .font(.system(size: 14)).foregroundStyle(PulseColors.textMuted)
                    }
                    Spacer()
                    Button { historyOpen = true } label: {
                        Image(systemName: "calendar")
                            .font(.system(size: 16))
                            .foregroundStyle(PulseColors.textSecondary)
                            .frame(width: 40, height: 40)
                            .background(PulseColors.card, in: Circle())
                            .overlay(Circle().stroke(PulseColors.borderSubtle, lineWidth: 1))
                    }
                }

                if !stale.isEmpty {
                    StaleSessionRecoveryCard(sessions: stale)
                }

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
                                Text("Goal: \(stepGoal.formatted()) steps · \(activeGoal) active min")
                                    .font(.system(size: 12)).foregroundStyle(PulseColors.textSecondary)
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

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricCardButton(metric: "steps", label: "Steps", value: summary.steps.map { $0.formatted() } ?? "—", color: PulseColors.steps)
                    MetricCardButton(metric: "calories", label: "Calories", value: summary.calories.map { Int($0).formatted() } ?? "—", unit: summary.calories == nil ? nil : "kcal", color: PulseColors.calories)
                    MetricCardButton(metric: "distance", label: "Distance", value: summary.distanceMeters.map { String(format: "%.2f", $0 / distanceDivisor) } ?? "—", unit: summary.distanceMeters == nil ? nil : distanceUnit, color: PulseColors.distance)
                    MetricCardButton(metric: "readiness", label: "Active min", value: summary.activeMinutes.map { "\($0)" } ?? "—", unit: summary.activeMinutes == nil ? nil : "min", color: PulseColors.readiness)
                }

                // Trend graphs with range toggles
                ActivitySectionCard(title: "Steps · \(rangeLabel(stepsRange))", range: $stepsRange) {
                    let values = stepsValues(summary)
                    if values.isEmpty {
                        InlineEmptyState(title: "No step data", message: "Wear your ring to start tracking.")
                    } else {
                        StepBarsChart(values: values, labels: stepsLabels(summary), goal: stepsRange == .sevenDays ? Double(stepGoal) : nil, todayIndex: stepsRange == .sevenDays ? todayIdx : nil)
                    }
                }

                ActivitySectionCard(title: "Distance · \(rangeLabel(distanceRange))", range: $distanceRange) {
                    let values = distanceValues(summary)
                    if values.isEmpty {
                        InlineEmptyState(title: "No distance data", message: "Wear your ring to start tracking.")
                    } else {
                        DistanceLineChart(values: values)
                    }
                }

                ActivitySectionCard(title: "Calories · \(rangeLabel(caloriesRange))", range: $caloriesRange) {
                    let values = caloriesValues(summary)
                    if values.isEmpty {
                        InlineEmptyState(title: "No calorie data", message: "Wear your ring to start tracking.")
                    } else {
                        CaloriesAreaChart(values: values)
                    }
                }
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

    private func stepsValues(_ summary: TodaySummary) -> [Double] {
        stepsRange == .sevenDays ? summary.trends.steps7d.map(\.value) : MetricsService.metricRange(metric: .steps, range: stepsRange, context: modelContext).map(\.value)
    }
    private func distanceValues(_ summary: TodaySummary) -> [Double] {
        let raw = distanceRange == .sevenDays ? summary.trends.distance7d.map(\.value) : MetricsService.metricRange(metric: .distance, range: distanceRange, context: modelContext).map(\.value)
        return raw.map { $0 / distanceDivisor }
    }
    private func caloriesValues(_ summary: TodaySummary) -> [Double] {
        caloriesRange == .sevenDays ? summary.trends.calories7d.map(\.value) : MetricsService.metricRange(metric: .calories, range: caloriesRange, context: modelContext).map(\.value)
    }

    private func stepsLabels(_ summary: TodaySummary) -> [String] {
        if stepsRange == .sevenDays { return weekLabels }
        let samples = MetricsService.metricRange(metric: .steps, range: stepsRange, context: modelContext)
        let formatter = DateFormatter()
        formatter.dateFormat = stepsRange == .twelveMonths ? "MMM" : "d"
        return samples.map { formatter.string(from: $0.timestamp) }
    }

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

    private func rangeLabel(_ range: MetricRange) -> String {
        switch range {
        case .thirtyDays: return "last 30 days"
        case .twelveMonths: return "last 12 months"
        default: return "last 7 days"
        }
    }
}

// MARK: - Goal editor

struct GoalEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var steps: Double = 8000
    @State private var activeMinutes: Double = 60
    @State private var sleepHours: Double = 8
    @State private var workouts: Double = 4
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Daily targets") {
                    stepper("Steps", value: $steps, range: 2000...20000, step: 500, format: { "\(Int($0).formatted())" })
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
