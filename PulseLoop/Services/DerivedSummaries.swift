import Foundation

enum MetricKey: String, CaseIterable {
    case steps
    case heartRate = "hr"
    case spo2
    case sleep
    case calories
    case distance
    case activeMinutes = "active_minutes"
    case battery
    // Colmi R02 metrics (capability-gated in the UI).
    case stress
    case hrv
    case temperature = "temp"

    /// The wearable capability that must be present for this metric to be shown.
    var requiredCapability: WearableCapability? {
        switch self {
        case .heartRate: return .heartRate
        case .spo2: return .spo2
        case .stress: return .stress
        case .hrv: return .hrv
        case .temperature: return .temperature
        case .steps, .calories, .distance, .activeMinutes: return .steps
        case .sleep: return .sleep
        case .battery: return .battery
        }
    }
}

enum MetricRange: String, CaseIterable {
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case twelveMonths = "12mo"
}

enum SleepRangeKey: String, CaseIterable {
    case day
    case week
    case month
    case year
}

enum DataFreshness: String {
    case live
    case syncedToday = "synced_today"
    case stale
    case missing
    case demo
    case calibrating
    case experimental
}

enum MetricConfidence: String {
    case high
    case medium
    case low
    case partial
    case experimental
}

struct MetricSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

struct DailyMetricPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct MetricState {
    let freshness: DataFreshness
    let confidence: MetricConfidence
    let source: String?
    let sampleCount: Int
    let requiredSamples: Int
    let lastUpdatedAt: Date?
    let status: String
    let zeroIsReal: Bool
}

struct CalibrationState {
    let isCalibrating: Bool
    let day: Int
    let totalDays: Int
    let startedAt: Date?
    let reason: String
}

struct GoalsSummary {
    let stepsDaily: Int
    let activeMinutesDaily: Int
    let sleepHours: Double
    let exerciseDaysWeekly: Int
}

struct TrendsSummary {
    let steps7d: [DailyMetricPoint]
    let calories7d: [DailyMetricPoint]
    let distance7d: [DailyMetricPoint]
    let hrSamples24h: [MetricSample]
    let spo2Samples24h: [MetricSample]
}

struct TimelineEvent: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let timestamp: Date
    let metric: String?
}

struct SleepSummary {
    let session: SleepSession
    let lightMinutes: Int
    let deepMinutes: Int
    let awakeMinutes: Int
    let blocks: [SleepStageBlock]
}

struct SleepRangeSummary {
    let range: SleepRangeKey
    let start: Date
    let end: Date
    let expectedNights: Int
    let sessions: [SleepSummary]
    
    var hasData: Bool { !sessions.isEmpty }
    
    var averageTotalMinutes: Int? {
        guard !sessions.isEmpty else { return nil }
        return sessions.reduce(0) { $0 + $1.session.totalMinutes } / sessions.count
    }
}

struct ActivitySessionSummary {
    let session: ActivitySession
    let durationSeconds: Int?
    let distanceMeters: Double?
    let calories: Double?
    let averageHeartRate: Double?
    let minHeartRate: Double?
    let maxHeartRate: Double?
    let averageSpO2: Double?
    let latestSpO2: Double?
    let heartRateSampleCount: Int
    let spo2SampleCount: Int
}

struct ActiveMinutesResult {
    let minutes: Int
    let source: String
}

struct ActivityDailyUpdate {
    let date: Date
    let steps: Int?
    let calories: Double?
    let distanceMeters: Double?
    let activeMinutes: Int?
    let source: String
    let syncedAt: Date?
    
    init(
        date: Date,
        steps: Int? = nil,
        calories: Double? = nil,
        distanceMeters: Double? = nil,
        activeMinutes: Int? = nil,
        source: String = "sync",
        syncedAt: Date? = Date()
    ) {
        self.date = date
        self.steps = steps
        self.calories = calories
        self.distanceMeters = distanceMeters
        self.activeMinutes = activeMinutes
        self.source = source
        self.syncedAt = syncedAt
    }
}

struct TodaySummary {
    var date: Date
    var steps: Int?
    var calories: Double?
    var distanceMeters: Double?
    var activeMinutes: Int?
    var activeMinutesSource: String
    var latestHeartRate: Measurement?
    var latestSpO2: Measurement?
    var restingHeartRateEstimate: Double?
    var peakHeartRateToday: Double?
    var sleep: SleepSummary?
    var batteryPercent: Int?
    var deviceState: RingConnectionState
    var trends: TrendsSummary
    var timeline: [TimelineEvent]
    var metricStates: [MetricKey: MetricState]
    var calibration: CalibrationState
    var goals: GoalsSummary
    var isDemo: Bool
    
    var sevenDaySteps: [DailyMetricPoint] { trends.steps7d }
}
