import Foundation
import SwiftData

@MainActor
enum MetricsService {
    private static let calibrationDays = 7
    private static let minimumTrendDays = 3
    
    static func buildTodaySummary(context: ModelContext) -> TodaySummary {
        let calendar = Calendar.current
        let activityRows = MetricsRepository.activityRows(context: context)
        let measurements = MetricsRepository.measurements(context: context)
        let device = DeviceRepository.current(context: context)
        let isDemo = activityRows.contains { $0.source == "mock" } || measurements.contains { $0.sourceRaw == MeasurementSource.mock.rawValue }
        let today = activityRows.sorted { $0.date < $1.date }.last
        let anchorDate = today?.date ?? calendar.startOfDay(for: Date())
        let alignedRows = alignedWeekActivity(rows: activityRows, anchor: isDemo ? anchorDate : Date())
        let hrRows = measurements.filter { $0.kind == .heartRate }
        let spo2Rows = measurements.filter { $0.kind == .spo2 }
        let hrSamples = samplesSinceCutoff(rows: hrRows, range: .twentyFourHours, includeAll: isDemo)
        let spo2Samples = samplesSinceCutoff(rows: spo2Rows, range: .twentyFourHours, includeAll: isDemo)
        let latestHR = hrRows.last
        let latestSpO2 = spo2Rows.last
        let calibration = calibrationState(device: device, activityRows: activityRows, measurements: measurements, isDemo: isDemo)
        let hrFreshness = freshness(lastUpdatedAt: latestHR?.timestamp, isDemo: isDemo)
        let spo2Freshness = freshness(lastUpdatedAt: latestSpO2?.timestamp, isDemo: isDemo)
        let sleep = SleepService.latestSleep(context: context)
        let goals = goalsSummary(context: context)
        let trends = TrendsSummary(
            steps7d: alignedRows.map { DailyMetricPoint(date: $0.date, value: Double($0.steps)) },
            calories7d: alignedRows.map { DailyMetricPoint(date: $0.date, value: $0.calories) },
            distance7d: alignedRows.map { DailyMetricPoint(date: $0.date, value: $0.distanceMeters) },
            hrSamples24h: hrSamples,
            spo2Samples24h: spo2Samples
        )
        let metricStates = buildMetricStates(MetricStateInputs(
            today: today,
            sleep: sleep,
            latestHR: latestHR,
            latestSpO2: latestSpO2,
            hrFreshness: hrFreshness,
            spo2Freshness: spo2Freshness,
            activityRows: activityRows,
            calibration: calibration,
            isDemo: isDemo
        ))
        
        // The ring's calorie field is unverified, so ring-history days don't carry calories — show
        // "—" rather than a misleading 0. Steps/distance from the ring are trustworthy.
        let todayCalories: Double? = today?.source == ActivityService.ringHistorySource ? nil : today?.calories
        return TodaySummary(
            date: today?.date ?? calendar.startOfDay(for: Date()),
            steps: today?.steps,
            calories: todayCalories,
            distanceMeters: today?.distanceMeters,
            activeMinutes: today?.activeMinutes,
            activeMinutesSource: today?.source ?? "none",
            latestHeartRate: valueIsFresh(hrFreshness) ? latestHR : nil,
            latestSpO2: valueIsFresh(spo2Freshness) ? latestSpO2 : nil,
            restingHeartRateEstimate: restingHeartRate(samples: hrSamples),
            peakHeartRateToday: hrSamples.map(\.value).max(),
            sleep: sleep,
            batteryPercent: device?.batteryPercent ?? 0,
            deviceState: device?.state ?? .idle,
            trends: trends,
            timeline: buildTimeline(
                device: device,
                today: today,
                hrSamples: hrSamples,
                spo2Samples: spo2Samples,
                sleep: sleep,
                context: context
            ),
            metricStates: metricStates,
            calibration: calibration,
            goals: goals,
            isDemo: isDemo
        )
    }
    
    static func metricRange(metric: MetricKey, range: MetricRange, context: ModelContext) -> [MetricSample] {
        switch metric {
        case .heartRate:
            return rangeSamples(kind: .heartRate, range: range, context: context)
        case .spo2:
            return rangeSamples(kind: .spo2, range: range, context: context)
        case .stress:
            return rangeSamples(kind: .stress, range: range, context: context)
        case .hrv:
            return rangeSamples(kind: .hrv, range: range, context: context)
        case .temperature:
            return rangeSamples(kind: .temperature, range: range, context: context)
        case .steps, .calories, .distance, .activeMinutes:
            return activitySamples(metric: metric, range: range, context: context)
        default:
            return []
        }
    }
    
    static func fetchMeasurements(_ context: ModelContext) -> [Measurement] {
        MetricsRepository.measurements(context: context).sorted { $0.timestamp > $1.timestamp }
    }
    
    static func fetchActivity(_ context: ModelContext) -> [ActivityDaily] {
        MetricsRepository.activityRows(descending: context)
    }

    /// The current device's capabilities, used to gate metric UI. Falls back to the jring base set
    /// for legacy rows that predate capability stamping (empty `capabilitiesRaw`), so existing users
    /// keep seeing HR / SpO₂ / steps / sleep / battery.
    static func deviceCapabilities(_ context: ModelContext) -> Set<WearableCapability> {
        let caps = fetchDevices(context).first?.capabilities ?? []
        if caps.isEmpty {
            return [.heartRate, .spo2, .steps, .sleep, .battery]
        }
        return caps
    }

    /// Whether a metric should be shown for the current device.
    static func supports(_ metric: MetricKey, context: ModelContext) -> Bool {
        guard let required = metric.requiredCapability else { return true }
        return deviceCapabilities(context).contains(required)
    }
    
    static func fetchDevices(_ context: ModelContext) -> [Device] {
        DeviceRepository.devices(context: context)
    }
    
    static func insertMockMeasurement(kind: MeasurementKind, context: ModelContext) {
        let value: Double
        switch kind {
        case .heartRate:
            value = Double(Int.random(in: 62...86))
        case .spo2:
            value = Double(Int.random(in: 96...99))
        case .stress:
            value = Double(Int.random(in: 20...70))
        case .hrv:
            value = Double(Int.random(in: 30...90))
        case .temperature:
            value = Double.random(in: 33...36)
        }
        let row = MeasurementRepository.insertMeasurement(
            kind: kind,
            value: value,
            unit: kind.unit,
            timestamp: Date(),
            source: .mock,
            context: context
        )
        context.insert(DerivedUpdateRow(kind: "\(kind.rawValue)_sample", entityType: "measurement", entityId: row.id.uuidString))
        _ = ActivityRecorderService.linkSample(kind: kind, value: value, timestamp: row.timestamp, measurementId: row.id, source: .mock, confidence: .known, context: context)
        try? context.save()
    }
    
    private static func rangeSamples(kind: MeasurementKind, range: MetricRange, context: ModelContext) -> [MetricSample] {
        let rows = MetricsRepository.measurements(kind: kind, context: context)
        let isDemo = rows.contains { $0.sourceRaw == MeasurementSource.mock.rawValue }
        return samplesSinceCutoff(rows: rows, range: range, includeAll: isDemo)
    }
    
    private static func activitySamples(metric: MetricKey, range: MetricRange, context: ModelContext) -> [MetricSample] {
        let rows = MetricsRepository.activityRows(context: context)
        let isDemo = rows.contains { $0.source == "mock" }
        let filtered = rowsSinceCutoff(rows: rows, range: range, includeAll: isDemo)
        if range == .twelveMonths {
            let calendar = Calendar.current
            let grouped = Dictionary(grouping: filtered) { row in
                let components = calendar.dateComponents([.year, .month], from: row.date)
                return "\(components.year ?? 0)-\(components.month ?? 0)"
            }
            return grouped.compactMap { _, rows in
                guard let first = rows.map(\.date).min() else { return nil }
                let components = calendar.dateComponents([.year, .month], from: first)
                let monthStart = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1, hour: 12)) ?? first
                return MetricSample(timestamp: monthStart, value: rows.reduce(0) { $0 + value(row: $1, metric: metric) })
            }
            .sorted { $0.timestamp < $1.timestamp }
        }
        return filtered.map { MetricSample(timestamp: $0.date, value: value(row: $0, metric: metric)) }
    }
    
    private static func value(row: ActivityDaily, metric: MetricKey) -> Double {
        switch metric {
        case .steps: return Double(row.steps)
        case .calories: return row.calories
        case .distance: return row.distanceMeters
        case .activeMinutes: return Double(row.activeMinutes)
        default: return 0
        }
    }
    
    private static func rowsSinceCutoff(rows: [ActivityDaily], range: MetricRange, includeAll: Bool) -> [ActivityDaily] {
        guard !includeAll else { return rows }
        let days: Int
        switch range {
        case .twentyFourHours, .sevenDays:
            days = 7
        case .thirtyDays:
            days = 30
        case .twelveMonths:
            days = 365
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return rows.filter { $0.date >= Calendar.current.startOfDay(for: cutoff) }
    }
    
    private static func samplesSinceCutoff(rows: [Measurement], range: MetricRange, includeAll: Bool) -> [MetricSample] {
        let filtered: [Measurement]
        if includeAll {
            filtered = rows
        } else {
            let cutoff: Date
            switch range {
            case .twentyFourHours:
                cutoff = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
            case .sevenDays:
                cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            case .thirtyDays:
                cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            case .twelveMonths:
                cutoff = Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? Date()
            }
            filtered = rows.filter { $0.timestamp >= cutoff }
        }
        return filtered.sorted { $0.timestamp < $1.timestamp }.map { MetricSample(timestamp: $0.timestamp, value: $0.value) }
    }
    
    private static func alignedWeekActivity(rows: [ActivityDaily], anchor: Date) -> [ActivityDaily] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let anchorStart = calendar.startOfDay(for: anchor)
        let weekday = calendar.component(.weekday, from: anchorStart)
        let daysSinceMonday = (weekday + 5) % 7
        let weekStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: anchorStart) ?? anchorStart
        let byDay = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.date) }
        return (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
            return byDay[date]?.first ?? ActivityDaily(date: date, source: "none")
        }
    }
    
    private static func calibrationState(device: Device?, activityRows: [ActivityDaily], measurements: [Measurement], isDemo: Bool) -> CalibrationState {
        if isDemo {
            return CalibrationState(isCalibrating: false, day: calibrationDays, totalDays: calibrationDays, startedAt: nil, reason: "Demo data active")
        }
        var candidates: [Date] = []
        if let lastConnected = device?.lastConnectedAt { candidates.append(lastConnected) }
        if let lastSync = device?.lastSyncAt { candidates.append(lastSync) }
        candidates.append(contentsOf: activityRows.compactMap(\.syncedAt))
        candidates.append(contentsOf: measurements.map(\.timestamp))
        let started = candidates.min()
        let day: Int
        if let started {
            let elapsed = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: started), to: Calendar.current.startOfDay(for: Date())).day ?? 0
            day = max(1, min(calibrationDays, elapsed + 1))
        } else {
            day = 1
        }
        return CalibrationState(
            isCalibrating: day < calibrationDays,
            day: day,
            totalDays: calibrationDays,
            startedAt: started,
            reason: day < calibrationDays ? "Learning your baseline" : "Baseline ready"
        )
    }
    
    private static func freshness(lastUpdatedAt: Date?, isDemo: Bool) -> DataFreshness {
        if isDemo { return .demo }
        guard let lastUpdatedAt else { return .missing }
        return Calendar.current.isDateInToday(lastUpdatedAt) ? .syncedToday : .stale
    }
    
    private static func valueIsFresh(_ freshness: DataFreshness) -> Bool {
        [.live, .syncedToday, .demo].contains(freshness)
    }
    
    private static func restingHeartRate(samples: [MetricSample]) -> Double? {
        let resting = samples.map(\.value).filter { $0 <= 72 }
        return resting.min()
    }
    
    /// Inputs for `buildMetricStates`, bundled to keep the call site readable.
    private struct MetricStateInputs {
        let today: ActivityDaily?
        let sleep: SleepSummary?
        let latestHR: Measurement?
        let latestSpO2: Measurement?
        let hrFreshness: DataFreshness
        let spo2Freshness: DataFreshness
        let activityRows: [ActivityDaily]
        let calibration: CalibrationState
        let isDemo: Bool
    }

    private static func buildMetricStates(_ inputs: MetricStateInputs) -> [MetricKey: MetricState] {
        let today = inputs.today
        let sleep = inputs.sleep
        let latestHR = inputs.latestHR
        let latestSpO2 = inputs.latestSpO2
        let hrFreshness = inputs.hrFreshness
        let spo2Freshness = inputs.spo2Freshness
        let activityRows = inputs.activityRows
        let calibration = inputs.calibration
        let isDemo = inputs.isDemo

        let activityFreshness = freshness(lastUpdatedAt: today?.syncedAt, isDemo: isDemo)
        let activitySampleCount = activityRows.count
        return [
            .steps: metricState(
                freshness: activityFreshness,
                confidence: today == nil ? .partial : .high,
                source: today?.source,
                sampleCount: activitySampleCount,
                requiredSamples: minimumTrendDays,
                lastUpdatedAt: today?.syncedAt,
                status: activityStatus("Steps", today: today, calibration: calibration, isDemo: isDemo),
                zeroIsReal: today?.steps == 0
            ),
            .calories: metricState(
                freshness: activityFreshness,
                confidence: today == nil ? .partial : .low,
                source: today?.source,
                sampleCount: activitySampleCount,
                requiredSamples: minimumTrendDays,
                lastUpdatedAt: today?.syncedAt,
                status: activityStatus("Calories", today: today, calibration: calibration, isDemo: isDemo),
                zeroIsReal: today?.calories == 0
            ),
            .distance: metricState(
                freshness: activityFreshness,
                confidence: today == nil ? .partial : .medium,
                source: today?.source,
                sampleCount: activitySampleCount,
                requiredSamples: minimumTrendDays,
                lastUpdatedAt: today?.syncedAt,
                status: activityStatus("Distance", today: today, calibration: calibration, isDemo: isDemo),
                zeroIsReal: today?.distanceMeters == 0
            ),
            .activeMinutes: metricState(
                freshness: activityFreshness,
                confidence: today == nil ? .partial : .medium,
                source: today?.source,
                sampleCount: activitySampleCount,
                requiredSamples: minimumTrendDays,
                lastUpdatedAt: today?.syncedAt,
                status: activityStatus("Active minutes", today: today, calibration: calibration, isDemo: isDemo),
                zeroIsReal: today?.activeMinutes == 0
            ),
            .heartRate: metricState(
                freshness: hrFreshness,
                confidence: latestHR == nil ? .partial : confidence(from: latestHR),
                source: latestHR?.sourceRaw,
                sampleCount: latestHR == nil ? 0 : 1,
                requiredSamples: 1,
                lastUpdatedAt: latestHR?.timestamp,
                status: readingStatus(rowExists: latestHR != nil, calibration: calibration, isDemo: isDemo)
            ),
            .spo2: metricState(
                freshness: spo2Freshness,
                confidence: latestSpO2 == nil ? .partial : confidence(from: latestSpO2),
                source: latestSpO2?.sourceRaw,
                sampleCount: latestSpO2 == nil ? 0 : 1,
                requiredSamples: 1,
                lastUpdatedAt: latestSpO2?.timestamp,
                status: readingStatus(rowExists: latestSpO2 != nil, calibration: calibration, isDemo: isDemo)
            ),
            .sleep: metricState(
                freshness: freshness(lastUpdatedAt: sleep?.session.syncedAt, isDemo: isDemo),
                confidence: sleep == nil ? .partial : .medium,
                source: sleep?.session.syncedAt == nil ? nil : "sync",
                sampleCount: sleep == nil ? 0 : 1,
                requiredSamples: 1,
                lastUpdatedAt: sleep?.session.syncedAt,
                status: sleep == nil ? "No sleep data" : calibration.isCalibrating ? "Baseline learning" : "Sleep synced"
            )
        ]
    }
    
    private static func metricState(
        freshness: DataFreshness,
        confidence: MetricConfidence,
        source: String?,
        sampleCount: Int,
        requiredSamples: Int,
        lastUpdatedAt: Date?,
        status: String,
        zeroIsReal: Bool = false
    ) -> MetricState {
        MetricState(
            freshness: freshness,
            confidence: confidence,
            source: source,
            sampleCount: sampleCount,
            requiredSamples: requiredSamples,
            lastUpdatedAt: lastUpdatedAt,
            status: status,
            zeroIsReal: zeroIsReal
        )
    }
    
    private static func confidence(from measurement: Measurement?) -> MetricConfidence {
        switch measurement?.confidenceRaw {
        case DecodeConfidence.known.rawValue:
            return .high
        case DecodeConfidence.partial.rawValue:
            return .partial
        case DecodeConfidence.unknown.rawValue:
            return .partial
        default:
            return .partial
        }
    }
    
    private static func activityStatus(_ label: String, today: ActivityDaily?, calibration: CalibrationState, isDemo: Bool) -> String {
        if today == nil { return "No data yet" }
        if isDemo { return "Demo" }
        if calibration.isCalibrating { return "Baseline learning" }
        return "\(label) synced"
    }
    
    private static func readingStatus(rowExists: Bool, calibration: CalibrationState, isDemo: Bool) -> String {
        if isDemo && rowExists { return "Demo" }
        if rowExists && calibration.isCalibrating { return "Baseline learning" }
        return rowExists ? "Latest reading" : "No reading yet"
    }
    
    private static func goalsSummary(context: ModelContext) -> GoalsSummary {
        if let goal = MetricsRepository.goals(context: context) {
            return GoalsSummary(
                stepsDaily: goal.steps,
                activeMinutesDaily: goal.activeMinutes,
                sleepHours: Double(goal.sleepMinutes) / 60,
                exerciseDaysWeekly: goal.workoutsPerWeek
            )
        }
        return GoalsSummary(stepsDaily: 8000, activeMinutesDaily: 60, sleepHours: 7.5, exerciseDaysWeekly: 4)
    }
    
    private static func buildTimeline(
        device: Device?,
        today: ActivityDaily?,
        hrSamples: [MetricSample],
        spo2Samples: [MetricSample],
        sleep: SleepSummary?,
        context: ModelContext
    ) -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        if let lastSyncAt = device?.lastSyncAt {
            events.append(TimelineEvent(title: "Sync complete", detail: "Ring data updated", timestamp: lastSyncAt, metric: "sync"))
        }
        if let last = hrSamples.last {
            events.append(TimelineEvent(title: "Heart rate", detail: "\(Int(last.value)) bpm", timestamp: last.timestamp, metric: "hr"))
        }
        if let last = spo2Samples.last {
            events.append(TimelineEvent(title: "SpO2", detail: "\(Int(last.value)) %", timestamp: last.timestamp, metric: "spo2"))
        }
        if let today, today.activeMinutes > 0 {
            let timestamp = today.syncedAt ?? Calendar.current.date(bySettingHour: 14, minute: 25, second: 0, of: today.date) ?? today.date
            events.append(TimelineEvent(title: "Activity sync", detail: "\(min(today.activeMinutes, 22)) min active", timestamp: timestamp, metric: "activity"))
        }
        if let sleep {
            events.append(TimelineEvent(title: "Sleep synced", detail: "\(sleep.session.totalMinutes / 60)h \(sleep.session.totalMinutes % 60)m", timestamp: sleep.session.endAt, metric: "sleep"))
        }
        let selfies = DebugRepository.queryPackets(filter: DebugPacketFilter(commandId: 0x06), context: context).prefix(3)
        for packet in selfies {
            events.append(TimelineEvent(title: "Gesture event", detail: "Decoded packet", timestamp: packet.timestamp, metric: "debug"))
        }
        return events.sorted { $0.timestamp > $1.timestamp }.prefix(8).map { $0 }
    }
}

@MainActor
enum SleepService {
    static func latestSleep(context: ModelContext) -> SleepSummary? {
        guard let session = SleepRepository.latestSession(context: context) else { return nil }
        // Gate on *today* so the Today screen only shows a recent night; a session more than a
        // day old (with nothing newer) is hidden rather than shown as if it were last night.
        let staleCutoff = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        guard Calendar.current.startOfDay(for: session.date) >= staleCutoff else { return nil }
        return summary(for: session, includeStages: true, context: context)
    }
    
    static func sleepForDate(_ date: Date, context: ModelContext) -> SleepSummary? {
        let start = Calendar.current.startOfDay(for: date)
        guard let session = SleepRepository.sessions(context: context).first(where: { Calendar.current.isDate($0.date, inSameDayAs: start) }) else {
            return nil
        }
        return summary(for: session, includeStages: true, context: context)
    }
    
    static func sleepRange(_ range: SleepRangeKey, context: ModelContext, now: Date = Date()) -> SleepRangeSummary {
        let expected = expectedNights(for: range)
        // Day view is "last night" — anchored on the current reference night, not
        // the latest recorded one. If nothing was captured we want to show the
        // empty state, not a stale night from days ago. Week/Month/Year keep the
        // last-recorded anchor so historical data still surfaces.
        let anchor = range == .day
            ? dayReferenceNight(now: now)
            : sleepAnchor(context: context)
        let start = Calendar.current.date(byAdding: .day, value: -(expected - 1), to: anchor) ?? anchor
        // End-of-day cap on the anchor so sessions stored mid-day are included.
        let end = Calendar.current.date(byAdding: .day, value: 1, to: anchor)?.addingTimeInterval(-1) ?? anchor
        let includeStages = range == .day
        let sessions = SleepRepository.sessions(context: context)
            .filter { $0.date >= start && $0.date <= end }
            .map { summary(for: $0, includeStages: includeStages, context: context) }
        return SleepRangeSummary(range: range, start: start, end: anchor, expectedNights: expected, sessions: sessions)
    }

    /// The "night to show on the Day view." Sessions are keyed by the date the
    /// night belongs to (the morning of waking). Before 4 AM local we still want
    /// to show the night that is currently in progress / just ended — i.e.
    /// yesterday's date. From 4 AM onwards we flip to today; if no session
    /// landed under today's key by then, the view shows "no sleep last night".
    static func dayReferenceNight(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let hour = calendar.component(.hour, from: now)
        if hour < 4 {
            return calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        }
        return startOfToday
    }
    
    static func summary(for session: SleepSession, context: ModelContext) -> SleepSummary {
        summary(for: session, includeStages: true, context: context)
    }
    
    private static func summary(for session: SleepSession, includeStages: Bool, context: ModelContext) -> SleepSummary {
        let blocks = SleepRepository.blocks(sessionId: session.id, context: context)
        let light = blocks.filter { $0.stage == .light }.reduce(0) { $0 + $1.durationMinutes }
        let deep = blocks.filter { $0.stage == .deep }.reduce(0) { $0 + $1.durationMinutes }
        let awake = blocks.filter { $0.stage == .awake }.reduce(0) { $0 + $1.durationMinutes }
        return SleepSummary(
            session: session,
            lightMinutes: light,
            deepMinutes: deep,
            awakeMinutes: awake,
            blocks: includeStages ? blocks : []
        )
    }
    
    private static func expectedNights(for range: SleepRangeKey) -> Int {
        switch range {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .year: return 365
        }
    }
    
    private static func sleepAnchor(context: ModelContext) -> Date {
        if let latest = SleepRepository.latestSession(context: context) {
            return Calendar.current.startOfDay(for: latest.date)
        }
        return Calendar.current.startOfDay(for: Date())
    }
}

@MainActor
enum ActivityService {
    private static let defaultRestingHR = 60.0
    private static let absoluteFloorBPM = 100.0
    private static let restingOffsetBPM = 30.0
    private static let liveDensityThreshold = 5
    private static let minutesPerBucket = 30
    
    @discardableResult
    static func applyActivityUpdate(_ update: ActivityDailyUpdate, context: ModelContext) -> ActivityDaily {
        let row: ActivityDaily
        if let existing = MetricsRepository.activity(on: update.date, context: context) {
            row = existing
        } else {
            row = ActivityDaily(date: update.date, source: update.source)
            context.insert(row)
        }
        if let steps = update.steps { row.steps = max(row.steps, steps) }
        if let calories = update.calories { row.calories = max(row.calories, calories) }
        if let distanceMeters = update.distanceMeters { row.distanceMeters = max(row.distanceMeters, distanceMeters) }
        if let activeMinutes = update.activeMinutes { row.activeMinutes = max(row.activeMinutes, activeMinutes) }
        row.source = update.source
        row.syncedAt = update.syncedAt
        row.updatedAt = Date()
        return row
    }

    /// Tag for days whose totals are summed from ring history buckets (vs. live cumulative updates).
    static let ringHistorySource = "ring_history"

    /// One-time cleanup of `ActivityDaily` rows inflated by the old `+=` accumulator bug (steps that
    /// compounded into the millions across repeated syncs). Deletes ring-history daily rows so they get
    /// recomputed cleanly from buckets on the next sync. Idempotent + UserDefaults-gated so it runs once.
    static func migrateInflatedActivityIfNeeded(context: ModelContext) {
        let key = "activityBucketMigration.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for row in MetricsRepository.activityRows(context: context) where row.source == ringHistorySource {
            context.delete(row)
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Persist one intraday activity **bucket** from ring history (e.g. a Colmi quarter-hour `0x43`
    /// sample) and recompute its day's total. The bucket is **upserted by its start time** into
    /// `ActivityBucketSample`, so re-syncing the same bucket *replaces* it (never accumulates), and the
    /// day's `ActivityDaily.steps/distance` is recomputed as the **sum of distinct buckets** for that
    /// day. This is the GadgetBridge model and fixes daily totals drifting upward across repeated syncs.
    /// Calories are intentionally not summed (the ring's calorie field is unverified).
    @discardableResult
    static func applyActivityBucket(date timestamp: Date, steps: Int, distanceMeters: Double, syncedAt: Date = Date(), context: ModelContext) -> ActivityDaily {
        let dayStart = Calendar.current.startOfDay(for: timestamp)
        let epoch = Int(timestamp.timeIntervalSince1970)

        // Upsert the bucket sample by its unique start epoch (replace on re-sync).
        if let existing = (try? context.fetch(FetchDescriptor<ActivityBucketSample>(
            predicate: #Predicate { $0.startEpoch == epoch }
        )))?.first {
            existing.steps = steps
            existing.distanceMeters = distanceMeters
            existing.updatedAt = Date()
        } else {
            context.insert(ActivityBucketSample(timestamp: timestamp, steps: steps, distanceMeters: distanceMeters, source: ringHistorySource))
        }
        // Persist the upsert so the recompute fetch below reliably sees it (SwiftData fetches don't
        // always include pending inserts).
        try? context.save()

        // Recompute the day's total from all its buckets (sum of distinct samples).
        let buckets = (try? context.fetch(FetchDescriptor<ActivityBucketSample>(
            predicate: #Predicate { $0.date == dayStart }
        ))) ?? []
        let totalSteps = buckets.reduce(0) { $0 + $1.steps }
        let totalDistance = buckets.reduce(0.0) { $0 + $1.distanceMeters }

        let row: ActivityDaily
        if let existing = MetricsRepository.activity(on: dayStart, context: context) {
            row = existing
        } else {
            row = ActivityDaily(date: dayStart, source: ringHistorySource)
            context.insert(row)
        }
        row.steps = totalSteps
        row.distanceMeters = totalDistance
        row.source = ringHistorySource
        row.syncedAt = syncedAt
        row.updatedAt = Date()
        return row
    }

    
    static func computeActiveMinutes(for date: Date, context: ModelContext) -> ActiveMinutesResult {
        let samples = MetricsRepository.measurements(kind: .heartRate, context: context)
            .filter { Calendar.current.isDate($0.timestamp, inSameDayAs: date) }
        guard !samples.isEmpty else { return ActiveMinutesResult(minutes: 0, source: "none") }
        let threshold = max(absoluteFloorBPM, restingHeartRate(context: context) + restingOffsetBPM)
        let grouped = Dictionary(grouping: samples) { bucketKey(for: $0.timestamp) }
        var total = 0
        var source = "hr_buckets"
        for bucketSamples in grouped.values {
            let result = credit(for: bucketSamples, threshold: threshold)
            total += result.minutes
            if result.source == "hr_live" { source = "hr_live" }
        }
        return ActiveMinutesResult(minutes: min(total, 1440), source: source)
    }
    
    @discardableResult
    static func finishSummary(for session: ActivitySession, endedAt: Date = Date(), context: ModelContext) -> ActivitySessionSummary {
        backfillSamples(for: session, endedAt: endedAt, context: context)
        let samples = ActivityRepository.samples(sessionId: session.id, context: context)
        let hr = samples.filter { $0.kind == MeasurementKind.heartRate.rawValue && $0.value > 0 }.map(\.value)
        let spo2Rows = samples.filter { $0.kind == MeasurementKind.spo2.rawValue && $0.value > 0 }.sorted { $0.timestamp < $1.timestamp }
        let spo2 = spo2Rows.map(\.value)
        let distance = gpsDistance(sessionId: session.id, context: context) ?? session.distanceMeters
        let duration = max(0, Int(endedAt.timeIntervalSince(session.startedAt) - session.totalPauseSeconds))
        let calories = session.calories ?? max(0, Double(duration) / 60 * 8)
        
        session.endedAt = endedAt
        session.status = .finished
        session.distanceMeters = distance
        session.calories = calories
        session.avgHeartRate = average(hr)
        session.minHeartRate = hr.min()
        session.maxHeartRate = hr.max()
        session.avgSpO2 = average(spo2)
        session.latestSpO2 = spo2Rows.last?.value
        session.updatedAt = Date()
        
        let workoutMinutes = duration / 60
        if workoutMinutes > 0 {
            let row: ActivityDaily
            if let existing = MetricsRepository.activity(on: session.startedAt, context: context) {
                row = existing
            } else {
                row = ActivityDaily(date: session.startedAt, source: "manual_recording")
                context.insert(row)
            }
            row.activeMinutes += workoutMinutes
            if let distance, session.useGps {
                row.distanceMeters += distance
            }
            row.syncedAt = Date()
            row.updatedAt = Date()
            row.source = row.source == "manual_recording" ? "manual_recording" : "hr_and_manual"
        }
        
        return ActivitySessionSummary(
            session: session,
            durationSeconds: duration,
            distanceMeters: distance,
            calories: calories,
            averageHeartRate: session.avgHeartRate,
            minHeartRate: session.minHeartRate,
            maxHeartRate: session.maxHeartRate,
            averageSpO2: session.avgSpO2,
            latestSpO2: session.latestSpO2,
            heartRateSampleCount: hr.count,
            spo2SampleCount: spo2.count
        )
    }
    
    private static func restingHeartRate(context: ModelContext) -> Double {
        let values = MetricsRepository.measurements(kind: .heartRate, context: context).map(\.value).filter { $0 > 0 }.sorted()
        guard values.count >= 20 else { return defaultRestingHR }
        let index = max(0, Int(0.10 * Double(values.count)) - 1)
        return values[index]
    }
    
    private static func bucketKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = (components.minute ?? 0) < 30 ? 0 : 30
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)-\(components.hour ?? 0)-\(minute)"
    }
    
    private static func credit(for samples: [Measurement], threshold: Double) -> ActiveMinutesResult {
        let liveSamples = samples.filter { $0.sourceRaw == MeasurementSource.live.rawValue }
        if liveSamples.count >= liveDensityThreshold {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
            let perMinute = Dictionary(grouping: liveSamples) { calendar.component(.minute, from: $0.timestamp) }
            let credited = perMinute.values.filter { bucket in
                let mean = bucket.reduce(0) { $0 + $1.value } / Double(bucket.count)
                return mean >= threshold
            }.count
            return ActiveMinutesResult(minutes: credited, source: "hr_live")
        }
        let mean = samples.reduce(0) { $0 + $1.value } / Double(samples.count)
        return ActiveMinutesResult(minutes: mean >= threshold ? minutesPerBucket : 0, source: "hr_buckets")
    }
    
    private static func backfillSamples(for session: ActivitySession, endedAt: Date, context: ModelContext) {
        let linked = Set(ActivityRepository.samples(sessionId: session.id, context: context).compactMap(\.measurementId))
        let rows = MetricsRepository.measurements(context: context).filter { row in
            (row.kind == .heartRate || row.kind == .spo2)
            && row.timestamp >= session.startedAt
            && row.timestamp <= endedAt
            && !linked.contains(row.id)
        }
        for row in rows {
            context.insert(ActivitySample(
                sessionId: session.id,
                measurementId: row.id,
                kind: row.kind.rawValue,
                value: row.value,
                unit: row.unit,
                timestamp: row.timestamp,
                source: row.sourceRaw,
                confidence: DecodeConfidence(rawValue: row.confidenceRaw) ?? .known
            ))
        }
    }
    
    private static func gpsDistance(sessionId: UUID, context: ModelContext) -> Double? {
        let points = ActivityRepository.gpsPoints(sessionId: sessionId, context: context).filter { $0.accepted }
        guard points.count >= 2 else { return nil }
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        return zip(sorted, sorted.dropFirst()).reduce(0) { total, pair in
            total + haversineMeters(pair.0.latitude, pair.0.longitude, pair.1.latitude, pair.1.longitude)
        }
    }
    
    private static func haversineMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6_371_000.0
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dPhi = (lat2 - lat1) * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2) + cos(p1) * cos(p2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * radius * asin(sqrt(a))
    }
    
    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

@MainActor
enum ActivityRecorderService {
    static func start(type: String, useGps: Bool, notes: String?, context: ModelContext) -> ActivitySession {
        let session = ActivitySession(type: type, status: .recording, notes: notes, useGps: useGps)
        context.insert(session)
        context.insert(ActivityEvent(sessionId: session.id, kind: "created"))
        context.insert(ActivityEvent(sessionId: session.id, kind: "started"))
        try? context.save()
        return session
    }
    
    static func pause(_ session: ActivitySession, context: ModelContext) {
        guard session.status == .recording else { return }
        session.status = .paused
        context.insert(ActivityEvent(sessionId: session.id, kind: "paused"))
        context.insert(ActivityEvent(sessionId: session.id, kind: "gps_stopped"))
        try? context.save()
    }
    
    static func resume(_ session: ActivitySession, context: ModelContext) {
        guard session.status == .paused else { return }
        if let lastPause = ActivityRepository.events(sessionId: session.id, context: context).last(where: { $0.kind == "paused" }) {
            session.totalPauseSeconds += max(0, Date().timeIntervalSince(lastPause.timestamp))
        }
        session.status = .recording
        context.insert(ActivityEvent(sessionId: session.id, kind: "resumed"))
        context.insert(ActivityEvent(sessionId: session.id, kind: "gps_started"))
        try? context.save()
    }
    
    static func finish(_ session: ActivitySession, context: ModelContext) {
        _ = ActivityService.finishSummary(for: session, context: context)
        context.insert(ActivityEvent(sessionId: session.id, kind: "gps_stopped"))
        context.insert(ActivityEvent(sessionId: session.id, kind: "finished"))
        try? context.save()
    }
    
    static func cancel(_ session: ActivitySession, context: ModelContext) {
        session.status = .cancelled
        session.endedAt = Date()
        session.updatedAt = Date()
        context.insert(ActivityEvent(sessionId: session.id, kind: "gps_stopped"))
        context.insert(ActivityEvent(sessionId: session.id, kind: "cancelled"))
        try? context.save()
    }
    
    /// Permanently deletes a workout and all of its child rows (samples, GPS points, events, sensor
    /// poll events — all raw-UUID FKs, so no SwiftData cascade) and reverses its contribution to the
    /// day's activity rollup so the totals stay honest.
    @MainActor
    static func delete(_ session: ActivitySession, context: ModelContext) {
        if let ended = session.endedAt {
            let minutes = max(0, Int(ended.timeIntervalSince(session.startedAt) - session.totalPauseSeconds)) / 60
            if minutes > 0, let row = MetricsRepository.activity(on: session.startedAt, context: context) {
                row.activeMinutes = max(0, row.activeMinutes - minutes)
                if session.useGps, let dist = session.distanceMeters {
                    row.distanceMeters = max(0, row.distanceMeters - dist)
                }
                row.updatedAt = Date()
            }
        }

        let id = session.id
        ActivityRepository.samples(sessionId: id, context: context).forEach(context.delete)
        ActivityRepository.gpsPoints(sessionId: id, context: context).forEach(context.delete)
        ActivityRepository.events(sessionId: id, context: context).forEach(context.delete)
        let polls = ((try? context.fetch(FetchDescriptor<ActivitySensorPollEvent>())) ?? []).filter { $0.sessionId == id }
        polls.forEach(context.delete)
        context.delete(session)
        try? context.save()
    }

    static func recoverStaleSession(context: ModelContext) -> [ActivitySession] {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -6, to: Date()) ?? Date()
        return ActivityRepository.sessions(context: context)
            .filter { ($0.status == .recording || $0.status == .paused) && $0.startedAt < cutoff }
    }
    
    @discardableResult
    static func linkSample(
        kind: MeasurementKind,
        value: Double,
        timestamp: Date,
        measurementId: UUID?,
        source: MeasurementSource,
        confidence: DecodeConfidence,
        context: ModelContext
    ) -> ActivitySample? {
        guard let active = ActivityRepository.sessions(context: context).first(where: { session in
            (session.status == .recording || session.status == .paused) && timestamp >= session.startedAt && timestamp <= Date()
        }) else {
            return nil
        }
        if let measurementId, ActivityRepository.samples(sessionId: active.id, context: context).contains(where: { $0.measurementId == measurementId }) {
            return nil
        }
        let sample = ActivitySample(
            sessionId: active.id,
            measurementId: measurementId,
            kind: kind.rawValue,
            value: value,
            unit: kind == .heartRate ? "bpm" : "%",
            timestamp: timestamp,
            source: source.rawValue,
            confidence: confidence
        )
        context.insert(sample)
        context.insert(ActivityEvent(sessionId: active.id, kind: "sensor_sample_linked", timestamp: timestamp))
        return sample
    }
}
