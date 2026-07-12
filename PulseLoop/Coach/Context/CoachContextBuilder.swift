import Foundation
import SwiftData

/// Composes the `CoachContextPacket` from the app's existing derived summaries
/// and repositories — the Swift analogue of `build_coach_context`. Runs on the
/// main actor because it reads SwiftData via the `@MainActor` services.
@MainActor
enum CoachContextBuilder {
    static func build(
        context: ModelContext,
        conversationSummary: String? = nil,
        now: Date = Date(),
        budget: CoachContextBudget = .full,
        environment: CoachContextPacket.EnvironmentContext? = nil
    ) -> CoachContextPacket {
        let summary = MetricsService.buildTodaySummary(context: context)
        let profile = ProfileRepository.profile(context: context)
        let device = DeviceRepository.current(context: context)

        let completeness = profileCompleteness(profile)
        let stepsPoints = summary.trends.steps7d
        let daysAvailable = stepsPoints.filter { $0.value > 0 }.count
        let weekSteps = stepsPoints.map { Int($0.value) }
        let mostActive = stepsPoints.max(by: { $0.value < $1.value })

        let profileContext = CoachContextPacket.ProfileContext(
            name: profile?.name, age: profile?.age, sex: profile?.sex,
            heightCm: profile?.heightCm, weightKg: profile?.weightKg,
            units: (profile?.units ?? .metric).rawValue,
            completeness: completeness
        )

        let deviceContext = CoachContextPacket.DeviceContext(
            name: device?.name,
            batteryPercent: device?.batteryPercent,
            state: (device?.state ?? .idle).rawValue,
            lastConnectedAt: device?.lastConnectedAt.map(iso),
            lastSyncAt: device?.lastSyncAt.map(iso)
        )

        let goals = CoachContextPacket.GoalContext(
            stepsDaily: summary.goals.stepsDaily,
            activeMinutesDaily: summary.goals.activeMinutesDaily,
            sleepHours: summary.goals.sleepHours,
            exerciseDaysWeekly: summary.goals.exerciseDaysWeekly
        )

        let today = CoachContextPacket.DayContext(
            localDate: localDate(summary.date),
            steps: summary.steps,
            calories: summary.calories,
            distanceKm: summary.distanceMeters.map { ($0 / 1000).rounded(toPlaces: 2) },
            activeMinutes: summary.activeMinutes,
            dataConfidence: dataConfidence(summary)
        )

        let week = CoachContextPacket.WeekContext(
            daysAvailable: daysAvailable,
            // `steps7d` is a fixed 7-slot week scaffold with missing days zero-filled, so it is never
            // empty and `weekSteps.count` is always 7. Average over the days that actually have data
            // (matching `ActivityTrendsView.dailyAverage` and the `get_activity_history` tool) and key
            // the no-data case off `daysAvailable`, so avgSteps and totalSteps agree on "no data".
            avgSteps: daysAvailable == 0 ? nil : weekSteps.reduce(0, +) / daysAvailable,
            totalSteps: daysAvailable == 0 ? nil : weekSteps.reduce(0, +),
            activeMinutesTotal: nil,
            exerciseDays: daysAvailable,
            mostActiveDay: mostActive.flatMap { $0.value > 0 ? "\(localDate($0.date)) (\(Int($0.value)) steps)" : nil }
        )

        let vitals = CoachContextPacket.VitalsContext(
            latestHr: summary.latestHeartRate?.value,
            latestHrAt: summary.latestHeartRate.map { iso($0.timestamp) },
            latestSpo2: summary.latestSpO2?.value,
            latestSpo2At: summary.latestSpO2.map { iso($0.timestamp) },
            restingHrEstimate: summary.restingHeartRateEstimate,
            peakHrToday: summary.peakHeartRateToday
        )

        let sleep = summary.sleep.map { s -> CoachContextPacket.SleepContext in
            CoachContextPacket.SleepContext(
                date: localDate(s.session.date),
                totalMin: s.session.totalMinutes,
                deepMin: s.deepMinutes,
                lightMin: s.lightMinutes,
                awakeMin: s.awakeMinutes,
                score: s.session.score,
                confidence: "medium",
                decoderNote: DataQualityAnalyzer.sleepDecoderNote
            )
        }

        let warnings = DataQualityAnalyzer.warnings(
            .init(
                profileCompleteness: completeness,
                daysAvailable: daysAvailable,
                hasSleep: sleep != nil,
                lastSyncAt: device?.lastSyncAt,
                isDemo: summary.isDemo
            ),
            now: now
        )

        return CoachContextPacket(
            generatedAt: iso(now),
            timezone: TimeZone.current.identifier,
            profile: profileContext,
            device: deviceContext,
            goals: goals,
            today: today,
            lastSevenDays: week,
            latestVitals: vitals,
            latestSleep: sleep,
            recentWorkouts: recentWorkouts(context: context, limit: budget.maxWorkouts),
            memories: memories(context: context, limit: budget.maxMemories, valueCap: budget.memoryValueCap),
            conversationSummary: cap(conversationSummary, to: budget.conversationSummaryCap),
            dataQualityWarnings: Array(warnings.prefix(budget.maxWarnings)),
            environment: environment
        )
    }

    // MARK: - Helpers

    /// Truncates a string to `limit` characters (adding an ellipsis when cut).
    /// `Int.max` (the full budget) is a no-op.
    private static func cap(_ text: String?, to limit: Int) -> String? {
        guard let text, limit != .max, text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    private static func recentWorkouts(context: ModelContext, limit: Int = 8) -> [CoachContextPacket.WorkoutContext] {
        ActivityRepository.sessions(context: context)
            .filter { $0.status == .finished }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { s in
                let duration = s.endedAt.map {
                    (($0.timeIntervalSince(s.startedAt) - s.totalPauseSeconds) / 60).rounded(toPlaces: 1)
                }
                return CoachContextPacket.WorkoutContext(
                    id: s.id.uuidString,
                    type: s.type,
                    startTime: iso(s.startedAt),
                    durationMin: duration,
                    distanceKm: s.distanceMeters.map { ($0 / 1000).rounded(toPlaces: 2) },
                    avgHr: s.avgHeartRate,
                    status: s.status.rawValue
                )
            }
    }

    private static func memories(context: ModelContext, limit: Int = 8, valueCap: Int = .max, now: Date = Date()) -> [CoachContextPacket.MemoryContext] {
        let descriptor = FetchDescriptor<CoachMemory>(
            sortBy: [SortDescriptor(\.importance, order: .reverse), SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows
            .filter { $0.expiresAt == nil || $0.expiresAt! > now }  // drop expired
            .prefix(limit)
            .map { .init(type: $0.memoryType, key: $0.key, value: cap($0.value, to: valueCap) ?? $0.value, importance: $0.importance) }
    }

    private static func profileCompleteness(_ profile: UserProfile?) -> String {
        guard let profile else { return "empty" }
        let filled = [profile.name as Any?, profile.age as Any?, profile.heightCm as Any?, profile.weightKg as Any?]
        let have = filled.compactMap { $0 }.count
        if have == 0 { return "empty" }
        return have == filled.count ? "complete" : "partial"
    }

    private static func dataConfidence(_ summary: TodaySummary) -> String {
        let hrCount = summary.trends.hrSamples24h.count
        let hasActivity = summary.steps != nil
        if !hasActivity && hrCount == 0 { return "none" }
        if hrCount >= 30 && hasActivity { return "high" }
        if hasActivity || hrCount > 0 { return "medium" }
        return "low"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    private static func localDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}
