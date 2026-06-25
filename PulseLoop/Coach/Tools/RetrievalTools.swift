import Foundation
import SwiftData

/// Read-only retrieval tools. Each maps to existing repositories/services via
/// `CoachDataAccess`; the model never touches SwiftData directly.
@MainActor
enum RetrievalTools {
    static var all: [AnyCoachTool] {
        [profileContext, dailySummary, rangeSummary, metricSeries,
         activitySessions, summarizeSession,
         syncStatus, dataAvailability, sleepTrends, goalProgress, recentAnomalies]
    }

    private static let metricEnum = ["steps", "hr", "spo2", "sleep", "active_minutes", "calories", "distance"]

    // MARK: get_profile_context

    private static var profileContext: AnyCoachTool {
        struct Result: Encodable {
            let profile: CoachContextPacket.ProfileContext
            let device: CoachContextPacket.DeviceContext
            let goals: CoachContextPacket.GoalContext
            let timezone: String
            let dataQualityWarnings: [String]
        }
        return .make(
            name: "get_profile_context",
            label: "Checking your profile and ring status",
            description: "Get user profile, units, timezone, default goals, device sync status, and known data-quality warnings.",
            parameters: JSONSchema.empty,
            argsType: NoArgs.self
        ) { _, ctx in
            let p = CoachContextBuilder.build(context: ctx.modelContext)
            return .encoding(Result(profile: p.profile, device: p.device, goals: p.goals,
                                    timezone: p.timezone, dataQualityWarnings: p.dataQualityWarnings))
        }
    }

    // MARK: get_daily_summary

    private struct DateArg: Decodable { let date: String }

    private static var dailySummary: AnyCoachTool {
        .make(
            name: "get_daily_summary",
            label: "Reading that day's ring data",
            description: "Fetch daily activity and biometric summary for a local date (YYYY-MM-DD).",
            parameters: JSONSchema.object(["date": JSONSchema.string], required: ["date"]),
            argsType: DateArg.self
        ) { args, ctx in
            let day = args.date
            let row = CoachDataAccess.activityRow(on: day, context: ctx.modelContext)
            let hr = CoachDataAccess.measurements(kind: .heartRate, start: day, end: day, context: ctx.modelContext).map(\.value)
            let spo2 = CoachDataAccess.measurements(kind: .spo2, start: day, end: day, context: ctx.modelContext).map(\.value)
            let sleep = CoachDataAccess.sleepSessions(start: day, end: day, context: ctx.modelContext).first

            var result: [String: Any] = ["date": day, "data_available": (row != nil || !hr.isEmpty || sleep != nil)]
            if let row {
                result["activity"] = [
                    "steps": row.steps, "calories": row.calories,
                    "distance_km": (row.distanceMeters / 1000).rounded(toPlaces: 2),
                    "active_minutes": row.activeMinutes,
                ]
            }
            result["hr"] = encodeStats(CoachDataAccess.stats(hr))
            result["spo2"] = encodeStats(CoachDataAccess.stats(spo2))
            if let sleep {
                result["sleep"] = [
                    "total_min": sleep.totalMinutes, "score": sleep.score as Any,
                    "confidence": "medium", "note": "experimental decoder (no REM)",
                ]
            }
            return .object(result)
        }
    }

    // MARK: get_range_summary

    private struct RangeArg: Decodable {
        let startDate: String, endDate: String, granularity: String, include: [String]
        enum CodingKeys: String, CodingKey {
            case startDate = "start_date", endDate = "end_date", granularity, include
        }
    }

    private static var rangeSummary: AnyCoachTool {
        .make(
            name: "get_range_summary",
            label: "Fetching your ring data for that range",
            description: "Fetch summarized activity, HR, SpO2, and sleep over a date range. Use for weekly/monthly summaries.",
            parameters: JSONSchema.object([
                "start_date": JSONSchema.string,
                "end_date": JSONSchema.string,
                "granularity": JSONSchema.enumString(["day", "week", "month"]),
                "include": JSONSchema.array(JSONSchema.enumString(["activity", "hr", "spo2", "sleep", "goals"])),
            ], required: ["start_date", "end_date", "granularity", "include"]),
            argsType: RangeArg.self
        ) { args, ctx in
            let include = Set(args.include)
            var result: [String: Any] = [
                "start_date": args.startDate, "end_date": args.endDate, "granularity": args.granularity,
            ]
            if include.contains("activity") || include.contains("goals") {
                let rows = CoachDataAccess.activityRows(start: args.startDate, end: args.endDate, context: ctx.modelContext)
                let totalSteps: Int = rows.reduce(0) { $0 + $1.steps }
                let totalCalories: Double = rows.reduce(0.0) { $0 + $1.calories }
                let totalActive: Int = rows.reduce(0) { $0 + $1.activeMinutes }
                let totals: [String: Any] = [
                    "steps": totalSteps,
                    "calories": totalCalories.rounded(toPlaces: 0),
                    "active_minutes": totalActive,
                ]
                let days: [[String: Any]] = rows.map { row in
                    ["date": CoachDataAccess.localDateString(row.date),
                     "steps": row.steps,
                     "active_minutes": row.activeMinutes]
                }
                var activity: [String: Any] = ["days_available": rows.count, "totals": totals, "days": days]
                activity["avg_steps"] = rows.isEmpty ? NSNull() : totalSteps / rows.count
                result["activity"] = activity
            }
            if include.contains("hr") {
                let hr = CoachDataAccess.measurements(kind: .heartRate, start: args.startDate, end: args.endDate, context: ctx.modelContext).map(\.value)
                result["hr"] = encodeStats(CoachDataAccess.stats(hr))
            }
            if include.contains("spo2") {
                let spo2 = CoachDataAccess.measurements(kind: .spo2, start: args.startDate, end: args.endDate, context: ctx.modelContext).map(\.value)
                result["spo2"] = encodeStats(CoachDataAccess.stats(spo2))
            }
            if include.contains("sleep") {
                let sleeps = CoachDataAccess.sleepSessions(start: args.startDate, end: args.endDate, context: ctx.modelContext)
                let avg = sleeps.isEmpty ? nil : sleeps.reduce(0) { $0 + $1.totalMinutes } / sleeps.count
                result["sleep"] = ["sessions": sleeps.count, "avg_total_min": avg as Any,
                                   "confidence": "medium", "note": "experimental decoder (light/deep/awake only)"]
            }
            return .object(result)
        }
    }

    // MARK: get_metric_series

    private struct SeriesArg: Decodable {
        let metric: String, start: String, end: String, granularity: String
    }

    private static var metricSeries: AnyCoachTool {
        .make(
            name: "get_metric_series",
            label: "Pulling the numbers",
            // swiftlint:disable:next line_length
            description: "Fetch a time-series for one metric over a date range. For hr/spo2 use granularity 'raw' for a within-a-single-day trend (individual readings), 'hour' to bucket by hour, or 'day' for daily averages across multiple days. Activity/sleep are always daily.",
            parameters: JSONSchema.object([
                "metric": JSONSchema.enumString(metricEnum),
                "start": JSONSchema.string, "end": JSONSchema.string,
                "granularity": JSONSchema.enumString(["raw", "hour", "day"]),
            ], required: ["metric", "start", "end", "granularity"]),
            argsType: SeriesArg.self
        ) { args, ctx in
            guard let metric = CoachChartMetric.from(args.metric) else { return .error("unknown metric '\(args.metric)'") }
            let series = CoachDataAccess.seriesPoints(metric: metric, start: args.start, end: args.end, granularity: args.granularity, context: ctx.modelContext)
            let points = series.map { ["x": $0.x, "y": $0.y] }
            return .object(["metric": args.metric, "granularity": args.granularity, "count": points.count, "points": points])
        }
    }

    // MARK: get_activity_sessions

    private struct SessionsArg: Decodable {
        let startDate: String, endDate: String, includeSamples: Bool, includeGps: Bool
        enum CodingKeys: String, CodingKey {
            case startDate = "start_date", endDate = "end_date"
            case includeSamples = "include_samples", includeGps = "include_gps"
        }
    }

    private static var activitySessions: AnyCoachTool {
        .make(
            name: "get_activity_sessions",
            label: "Looking up your workouts",
            description: "Fetch saved activity sessions over a date range.",
            parameters: JSONSchema.object([
                "start_date": JSONSchema.string, "end_date": JSONSchema.string,
                "include_samples": JSONSchema.boolean, "include_gps": JSONSchema.boolean,
            ], required: ["start_date", "end_date", "include_samples", "include_gps"]),
            argsType: SessionsArg.self
        ) { args, ctx in
            let sessions = CoachDataAccess.activitySessions(start: args.startDate, end: args.endDate, context: ctx.modelContext)
            let out = sessions.map { sessionDict($0, includeSamples: args.includeSamples, includeGps: args.includeGps, context: ctx.modelContext) }
            return .object(["count": out.count, "sessions": out])
        }
    }

    // MARK: summarize_activity_session

    private struct SessionIdArg: Decodable {
        let activityId: String
        enum CodingKeys: String, CodingKey { case activityId = "activity_id" }
    }

    private static var summarizeSession: AnyCoachTool {
        .make(
            name: "summarize_activity_session",
            label: "Summarizing that workout",
            description: "Compute summary statistics for one activity session (duration, distance, HR, SpO2, GPS availability).",
            parameters: JSONSchema.object(["activity_id": JSONSchema.string], required: ["activity_id"]),
            argsType: SessionIdArg.self
        ) { args, ctx in
            guard let uuid = UUID(uuidString: args.activityId),
                  let session = ActivityRepository.sessions(context: ctx.modelContext).first(where: { $0.id == uuid }) else {
                return .error("activity '\(args.activityId)' not found")
            }
            return .object(sessionDict(session, includeSamples: true, includeGps: true, context: ctx.modelContext))
        }
    }

    // MARK: get_sync_status

    private static var syncStatus: AnyCoachTool {
        .make(
            name: "get_sync_status",
            label: "Checking ring connection",
            description: "Get the ring's current connection state, battery, last sync time, and whether data is demo/sample.",
            parameters: JSONSchema.empty, argsType: NoArgs.self
        ) { _, ctx in
            let device = DeviceRepository.current(context: ctx.modelContext)
            let summary = MetricsService.buildTodaySummary(context: ctx.modelContext)
            return .object([
                "device_name": device?.name as Any,
                "state": (device?.state ?? .idle).rawValue,
                "battery_percent": device?.batteryPercent as Any,
                "last_sync_at": device?.lastSyncAt.map(CoachDataAccess.isoString) as Any,
                "last_connected_at": device?.lastConnectedAt.map(CoachDataAccess.isoString) as Any,
                "is_demo": summary.isDemo,
            ])
        }
    }

    // MARK: get_data_availability

    private struct AvailArg: Decodable { let start: String, end: String }

    private static var dataAvailability: AnyCoachTool {
        .make(
            name: "get_data_availability",
            label: "Checking what data exists",
            description: "Report how many readings exist per metric in a date range, plus data-quality warnings. Call before answering range questions.",
            parameters: JSONSchema.object(["start": JSONSchema.string, "end": JSONSchema.string], required: ["start", "end"]),
            argsType: AvailArg.self
        ) { args, ctx in
            let act = CoachDataAccess.activityRows(start: args.start, end: args.end, context: ctx.modelContext)
            let hr = CoachDataAccess.measurements(kind: .heartRate, start: args.start, end: args.end, context: ctx.modelContext)
            let spo2 = CoachDataAccess.measurements(kind: .spo2, start: args.start, end: args.end, context: ctx.modelContext)
            let sleep = CoachDataAccess.sleepSessions(start: args.start, end: args.end, context: ctx.modelContext)
            let workouts = CoachDataAccess.activitySessions(start: args.start, end: args.end, context: ctx.modelContext)
            let packet = CoachContextBuilder.build(context: ctx.modelContext)
            return .object([
                "start": args.start, "end": args.end,
                "available_metrics": [
                    "activity_days": act.count, "heart_rate": hr.count, "spo2": spo2.count,
                    "sleep_nights": sleep.count, "workouts": workouts.count,
                ],
                "warnings": packet.dataQualityWarnings,
            ])
        }
    }

    // MARK: get_sleep_trends

    private struct SleepTrendArg: Decodable { let range: String }

    private static var sleepTrends: AnyCoachTool {
        .make(
            name: "get_sleep_trends",
            label: "Reviewing your sleep",
            description: "Summarize sleep over a range: average duration, nights tracked, average score and stage split.",
            parameters: JSONSchema.object(["range": JSONSchema.enumString(["week", "month", "year"])], required: ["range"]),
            argsType: SleepTrendArg.self
        ) { args, ctx in
            let key = SleepRangeKey(rawValue: args.range) ?? .week
            let summary = SleepService.sleepRange(key, context: ctx.modelContext)
            let valid = SleepInsights.validSessions(summary.sessions)
            let stages = SleepInsights.averageStages(valid)
            return .object([
                "range": args.range,
                "expected_nights": summary.expectedNights,
                "nights_tracked": valid.count,
                "avg_total_min": SleepInsights.averageDuration(valid) as Any,
                "avg_score": SleepInsights.averageScore(valid) as Any,
                "avg_stages_min": stages.map { ["deep": $0.deep, "light": $0.light, "awake": $0.awake] } as Any,
                "note": DataQualityAnalyzer.sleepDecoderNote,
            ])
        }
    }

    // MARK: get_goal_progress

    private static var goalProgress: AnyCoachTool {
        .make(
            name: "get_goal_progress",
            label: "Checking your goals",
            description: "Compare today's metrics and this week's exercise days against the user's goals.",
            parameters: JSONSchema.empty, argsType: NoArgs.self
        ) { _, ctx in
            let s = MetricsService.buildTodaySummary(context: ctx.modelContext)
            let exerciseDays = s.trends.steps7d.filter { $0.value > 0 }.count
            return .object([
                "today": [
                    "steps": s.steps as Any, "steps_goal": s.goals.stepsDaily,
                    "active_minutes": s.activeMinutes as Any, "active_minutes_goal": s.goals.activeMinutesDaily,
                ],
                "week": [
                    "exercise_days": exerciseDays, "exercise_days_goal": s.goals.exerciseDaysWeekly,
                ],
                "sleep_hours_goal": s.goals.sleepHours,
            ])
        }
    }

    // MARK: get_recent_anomalies

    private static var recentAnomalies: AnyCoachTool {
        .make(
            name: "get_recent_anomalies",
            label: "Scanning for anything unusual",
            description: "Detect statistical outliers in steps and resting heart rate over the last ~14 days.",
            parameters: JSONSchema.empty, argsType: NoArgs.self
        ) { _, ctx in
            let end = CoachDataAccess.localDateString(Date())
            let start = CoachDataAccess.localDateString(Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date())
            let steps = CoachDataAccess.dailySeries(metric: .steps, start: start, end: end, context: ctx.modelContext)
            let hr = CoachDataAccess.dailySeries(metric: .hr, start: start, end: end, context: ctx.modelContext)
            return .object([
                "start": start, "end": end,
                "steps_outliers": AnalysisEngine.outliers(steps).map { ["date": $0.date, "value": $0.value, "z": $0.zScore] },
                "hr_outliers": AnalysisEngine.outliers(hr).map { ["date": $0.date, "value": $0.value, "z": $0.zScore] },
            ])
        }
    }

    // MARK: - shared

    private static func encodeStats(_ s: CoachDataAccess.Stats) -> [String: Any] {
        ["count": s.count, "avg": s.avg as Any, "min": s.min as Any, "max": s.max as Any]
    }

    private static func sessionDict(
        _ s: ActivitySession, includeSamples: Bool, includeGps: Bool, context: ModelContext
    ) -> [String: Any] {
        let duration = s.endedAt.map { (($0.timeIntervalSince(s.startedAt) - s.totalPauseSeconds) / 60).rounded(toPlaces: 1) }
        var dict: [String: Any] = [
            "id": s.id.uuidString, "type": s.type, "status": s.status.rawValue,
            "start_time": CoachDataAccess.isoString(s.startedAt),
            "duration_min": duration as Any,
            "distance_km": s.distanceMeters.map { ($0 / 1000).rounded(toPlaces: 2) } as Any,
            "avg_hr": s.avgHeartRate as Any, "max_hr": s.maxHeartRate as Any,
            "avg_spo2": s.avgSpO2 as Any, "notes": s.notes as Any,
            "perceived_effort": s.perceivedEffort as Any,
        ]
        if includeSamples {
            let samples = ActivityRepository.samples(sessionId: s.id, context: context)
            dict["sample_count"] = samples.count
        }
        if includeGps {
            let gps = ActivityRepository.gpsPoints(sessionId: s.id, context: context)
            dict["gps_point_count"] = gps.count
        }
        return dict
    }
}

extension CoachChartMetric {
    static func from(_ s: String) -> CoachChartMetric? {
        switch s {
        case "steps": return .steps
        case "hr": return .hr
        case "spo2": return .spo2
        case "sleep": return .sleep
        case "active_minutes": return .activeMinutes
        case "calories": return .calories
        case "distance": return .distance
        default: return nil
        }
    }
}
