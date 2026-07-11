import Foundation
import SwiftData

enum RingConnectionState: String, Codable, CaseIterable {
    case idle
    case scanning
    case connecting
    case connected
    case disconnected
    case reconnecting
    case failed
}

enum MeasurementKind: String, Codable, CaseIterable {
    case heartRate = "hr"
    case spo2
    // Colmi R02 metrics jring lacks. Raw values are persisted — append, never rename.
    case stress
    case hrv
    case temperature = "temp"
    // jring/56ff metrics from the 0x24 combined-sensor packet. Append only — raw values persisted.
    case bloodPressureSystolic = "bp_sys"
    case bloodPressureDiastolic = "bp_dia"
    case fatigue
    case bloodSugar = "glucose"
    // YCBT/TK5 history metrics: respiratory rate rides the "All" record (byte 10), VO₂max the
    // body-data record (byte 16). Append only — raw values persisted.
    case respiratoryRate = "resp_rate"
    case vo2max

    /// Display unit for a measurement of this kind.
    var unit: String {
        switch self {
        case .heartRate: return "bpm"
        case .spo2: return "%"
        case .stress: return ""
        case .hrv: return "ms"
        case .temperature: return "°C"
        case .bloodPressureSystolic, .bloodPressureDiastolic: return "mmHg"
        case .fatigue: return ""
        case .bloodSugar: return "mg/dL"
        case .respiratoryRate: return "brpm"    // breaths per minute
        case .vo2max: return "mL/kg/min"
        }
    }
}

enum MeasurementSource: String, Codable, CaseIterable {
    case ring
    case mock
    case history
    case workout
    case manual
    case live
    case colmi
}

enum SleepStage: String, Codable, CaseIterable {
    case light
    case deep
    case awake
    case unknown
    case rem
}

enum ActivitySessionStatus: String, Codable, CaseIterable {
    case recording
    case paused
    case finished
    case cancelled
}

enum PacketDirection: String, Codable, CaseIterable {
    case incoming
    case outgoing
}

enum DecodeConfidence: String, Codable, CaseIterable {
    case known
    case partial
    case unknown
    
    var debugLabel: String {
        switch self {
        case .known: return "high"
        case .partial: return "medium"
        case .unknown: return "unknown"
        }
    }
}

@Model
final class Device {
    @Attribute(.unique) var id: UUID
    var name: String
    var advertisedName: String?
    var peripheralIdentifier: String?
    var bleAddressHint: String?
    var batteryPercent: Int?
    var stateRaw: String
    var lastConnectedAt: Date?
    var lastDisconnectedAt: Date?
    var lastSyncAt: Date?
    /// When the last *full history sync* actually completed (`.syncProgress("done")`), as distinct
    /// from `lastSyncAt` — which is re-stamped on every CONNECT before any data streams. The coach
    /// freshness gate reads this so a check-in doesn't fire on connect with pre-sync data. Optional +
    /// defaulted to nil, so it's an additive SwiftData lightweight migration (same pattern as the
    /// fields below).
    var lastFullSyncAt: Date?
    var firmwareVersion: String?
    /// Exact catalog model (for example `colmi-r10`), separate from the protocol/driver family.
    var wearableModelID: String?
    // Defaulted so SwiftData lightweight migration is additive (existing rows become jring with no
    // declared capabilities until the next connect stamps them).
    var deviceTypeRaw: String = RingDeviceType.jring.rawValue
    var capabilitiesRaw: String = ""   // CSV of WearableCapability raw values
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "SMART_RING",
        advertisedName: String? = nil,
        peripheralIdentifier: String? = nil,
        bleAddressHint: String? = nil,
        batteryPercent: Int? = nil,
        state: RingConnectionState = .idle,
        deviceType: RingDeviceType = .jring,
        wearableModelID: String? = nil,
        capabilities: Set<WearableCapability> = []
    ) {
        self.id = id
        self.name = name
        self.advertisedName = advertisedName
        self.peripheralIdentifier = peripheralIdentifier
        self.bleAddressHint = bleAddressHint
        self.batteryPercent = batteryPercent
        self.stateRaw = state.rawValue
        self.deviceTypeRaw = deviceType.rawValue
        self.wearableModelID = wearableModelID
        self.capabilitiesRaw = capabilities.csv
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var state: RingConnectionState {
        get { RingConnectionState(rawValue: stateRaw) ?? .idle }
        set {
            stateRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var deviceType: RingDeviceType {
        get { RingDeviceType(rawValue: deviceTypeRaw) ?? .jring }
        set {
            deviceTypeRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var capabilities: Set<WearableCapability> {
        get { Set(csv: capabilitiesRaw) }
        set {
            capabilitiesRaw = newValue.csv
            updatedAt = Date()
        }
    }
}

@Model
final class ActivityDaily {
    @Attribute(.unique) var id: UUID
    var date: Date
    var steps: Int
    var calories: Double
    var distanceMeters: Double
    var activeMinutes: Int
    var source: String
    var syncedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        date: Date,
        steps: Int = 0,
        calories: Double = 0,
        distanceMeters: Double = 0,
        activeMinutes: Int = 0,
        source: String = "mock"
    ) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
        self.steps = steps
        self.calories = calories
        self.distanceMeters = distanceMeters
        self.activeMinutes = activeMinutes
        self.source = source
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class Measurement {
    // Indexes for the hot read paths: time-window scans (timestamp), per-kind windows + latest
    // value (kindRaw, timestamp), and demo detection (sourceRaw). Additive, non-destructive.
    #Index<Measurement>([\.timestamp], [\.kindRaw, \.timestamp], [\.sourceRaw])
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var value: Double
    var unit: String
    var timestamp: Date
    var sourceRaw: String
    var confidenceRaw: String
    var activitySessionId: UUID?
    var rawPacketId: UUID?
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        kind: MeasurementKind,
        value: Double,
        unit: String,
        timestamp: Date,
        source: MeasurementSource = .ring,
        confidence: DecodeConfidence = .known,
        activitySessionId: UUID? = nil,
        rawPacketId: UUID? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.value = value
        self.unit = unit
        self.timestamp = timestamp
        self.sourceRaw = source.rawValue
        self.confidenceRaw = confidence.rawValue
        self.activitySessionId = activitySessionId
        self.rawPacketId = rawPacketId
        self.createdAt = Date()
    }
    
    var kind: MeasurementKind { MeasurementKind(rawValue: kindRaw) ?? .heartRate }
}

/// A single historical battery reading, kept so the Wearable screen can chart drainage over time.
/// Battery is stored separately from `Measurement` (it isn't a health vital) but follows the same
/// timestamped-sample shape. Writes are throttled (on-change or a 30-min floor) so the table stays
/// tiny — at most a few dozen rows a day. Indexed on `timestamp` for the windowed chart query.
@Model
final class BatterySample {
    #Index<BatterySample>([\.timestamp])
    @Attribute(.unique) var id: UUID
    var percent: Int
    var timestamp: Date
    var createdAt: Date

    init(id: UUID = UUID(), percent: Int, timestamp: Date = Date()) {
        self.id = id
        self.percent = percent
        self.timestamp = timestamp
        self.createdAt = Date()
    }
}

@Model
final class SleepSession {
    @Attribute(.unique) var id: UUID
    var date: Date
    var startAt: Date
    var endAt: Date
    var totalMinutes: Int
    var score: Int?
    var syncedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        date: Date,
        startAt: Date,
        endAt: Date,
        totalMinutes: Int,
        score: Int? = nil,
        syncedAt: Date? = nil
    ) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
        self.startAt = startAt
        self.endAt = endAt
        self.totalMinutes = totalMinutes
        self.score = score
        self.syncedAt = syncedAt
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class SleepStageBlock {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var startAt: Date
    var startMinute: Int
    var durationMinutes: Int
    var stageRaw: String
    
    init(
        id: UUID = UUID(),
        sessionId: UUID,
        startAt: Date,
        startMinute: Int,
        durationMinutes: Int,
        stage: SleepStage
    ) {
        self.id = id
        self.sessionId = sessionId
        self.startAt = startAt
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.stageRaw = stage.rawValue
    }
    
    var stage: SleepStage { SleepStage(rawValue: stageRaw) ?? .unknown }
}

@Model
final class RawPacketRow {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var directionRaw: String
    var commandId: Int
    var hexPayload: String
    var decodedKind: String?
    var decodedJSON: String?
    var confidenceRaw: String
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        direction: PacketDirection,
        commandId: Int,
        hexPayload: String,
        decodedKind: String? = nil,
        decodedJSON: String? = nil,
        confidence: DecodeConfidence = .unknown
    ) {
        self.id = id
        self.timestamp = timestamp
        self.directionRaw = direction.rawValue
        self.commandId = commandId
        self.hexPayload = hexPayload
        self.decodedKind = decodedKind
        self.decodedJSON = decodedJSON
        self.confidenceRaw = confidence.rawValue
        self.createdAt = Date()
    }
    
    var direction: PacketDirection { PacketDirection(rawValue: directionRaw) ?? .incoming }
    var confidence: DecodeConfidence { DecodeConfidence(rawValue: confidenceRaw) ?? .unknown }
}

@Model
final class DerivedUpdateRow {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var kind: String
    var entityType: String
    var entityId: String
    var payloadJSON: String?
    
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: String,
        entityType: String,
        entityId: String,
        payloadJSON: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.entityType = entityType
        self.entityId = entityId
        self.payloadJSON = payloadJSON
    }
}

/// Whether the user sees metric (cm/kg/°C/km) or imperial (in/lb/°F/mi) units. Persisted as a raw
/// string on `UserProfile.unitsRaw`; also fed to the ring's user-preferences command.
enum UnitsPreference: String, CaseIterable, Codable, Sendable {
    case metric
    case imperial

    var label: String { self == .metric ? "Metric" : "Imperial" }
}

@Model
final class UserProfile {
    @Attribute(.unique) var id: UUID
    var name: String?
    var age: Int?
    var sex: String?
    var heightCm: Double?
    var weightKg: Double?
    /// Display/units preference. Defaulted so existing stored profiles migrate without a data change.
    var unitsRaw: String = UnitsPreference.metric.rawValue
    var onboardingCompleted: Bool
    var baselineCompleted: Bool
    var createdAt: Date
    var updatedAt: Date

    // Physiology inputs that shift vitals reference ranges (consumed by VitalsThresholdEngine via
    // UserPhysiologyProfile). All optional/defaulted so existing stored profiles migrate via SwiftData
    // lightweight migration with no schema version bump — same pattern as `unitsRaw`.
    /// Lower resting-HR thresholds; treat a low resting HR as athletic rather than a concern.
    var athleteMode: Bool = false
    /// Home/typical altitude in metres; above ~2000 m shifts the expected SpO₂ range down.
    var altitudeMeters: Double?
    /// Beta-blocker use lowers resting HR; nil = not specified.
    var usesBetaBlockers: Bool?
    /// Known lung condition lowers expected SpO₂; nil = not specified.
    var hasKnownLungCondition: Bool?
    /// Preferred glucose display unit.
    var preferredGlucoseUnitRaw: String = GlucoseUnit.mgdl.rawValue

    var units: UnitsPreference {
        get { UnitsPreference(rawValue: unitsRaw) ?? .metric }
        set { unitsRaw = newValue.rawValue }
    }

    var preferredGlucoseUnit: GlucoseUnit {
        get { GlucoseUnit(rawValue: preferredGlucoseUnitRaw) ?? .mgdl }
        set { preferredGlucoseUnitRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String? = nil,
        age: Int? = nil,
        sex: String? = nil,
        heightCm: Double? = nil,
        weightKg: Double? = nil,
        units: UnitsPreference = .metric,
        onboardingCompleted: Bool = false,
        baselineCompleted: Bool = false,
        athleteMode: Bool = false,
        altitudeMeters: Double? = nil,
        usesBetaBlockers: Bool? = nil,
        hasKnownLungCondition: Bool? = nil,
        preferredGlucoseUnit: GlucoseUnit = .mgdl
    ) {
        self.id = id
        self.name = name
        self.age = age
        self.sex = sex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.unitsRaw = units.rawValue
        self.onboardingCompleted = onboardingCompleted
        self.baselineCompleted = baselineCompleted
        self.athleteMode = athleteMode
        self.altitudeMeters = altitudeMeters
        self.usesBetaBlockers = usesBetaBlockers
        self.hasKnownLungCondition = hasKnownLungCondition
        self.preferredGlucoseUnitRaw = preferredGlucoseUnit.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class UserGoal {
    @Attribute(.unique) var id: UUID
    var steps: Int
    var sleepMinutes: Int
    var activeMinutes: Int
    var workoutsPerWeek: Int
    /// Daily distance goal in canonical metres (converted to km/mi for display, like all stored distance).
    /// Defaulted so this is a safe additive SwiftData migration for existing rows.
    var distanceMeters: Double = 8000
    /// Daily active-energy goal in kcal. Defaulted for the same additive-migration reason.
    var calories: Int = 500
    var updatedAt: Date

    init(id: UUID = UUID(), steps: Int = 10000, sleepMinutes: Int = 480, activeMinutes: Int = 45, workoutsPerWeek: Int = 4, distanceMeters: Double = 8000, calories: Int = 500) {
        self.id = id
        self.steps = steps
        self.sleepMinutes = sleepMinutes
        self.activeMinutes = activeMinutes
        self.workoutsPerWeek = workoutsPerWeek
        self.distanceMeters = distanceMeters
        self.calories = calories
        self.updatedAt = Date()
    }
}

/// Per-device all-day measurement configuration: how often the ring measures HR and which background
/// vitals it records. Keyed by `Device.id` so each paired wearable keeps its own config (future-proof
/// for multiple devices). Only devices declaring `.measurementInterval` (Colmi) act on this; the
/// generic jring never surfaces it. All fields are defaulted so this is a safe additive migration.
@Model
final class DeviceMeasurementConfig {
    @Attribute(.unique) var deviceId: UUID
    /// All-day HR sampling interval, minutes. Colmi accepts 5…60 in 5-minute steps.
    var hrIntervalMinutes: Int = 5
    var hrEnabled: Bool = true
    var spo2Enabled: Bool = true
    var stressEnabled: Bool = true
    var hrvEnabled: Bool = true
    var temperatureEnabled: Bool = true
    var updatedAt: Date = Date()

    init(deviceId: UUID) {
        self.deviceId = deviceId
    }

    /// Project to the device-agnostic value the sync engine consumes.
    var asSettings: MeasurementSettings {
        MeasurementSettings(
            hrEnabled: hrEnabled,
            hrIntervalMinutes: hrIntervalMinutes,
            spo2Enabled: spo2Enabled,
            stressEnabled: stressEnabled,
            hrvEnabled: hrvEnabled,
            temperatureEnabled: temperatureEnabled
        )
    }
}

@Model
final class ActivitySession {
    @Attribute(.unique) var id: UUID
    var type: String
    var statusRaw: String
    var startedAt: Date
    var endedAt: Date?
    var totalPauseSeconds: Double
    var calories: Double?
    var distanceMeters: Double?
    var avgHeartRate: Double?
    var minHeartRate: Double?
    var maxHeartRate: Double?
    var avgSpO2: Double?
    var latestSpO2: Double?
    var notes: String?
    var useGps: Bool
    var perceivedEffort: String?
    var createdAt: Date
    var updatedAt: Date

    // Recording-quality + Live Activity metadata. Defaulted so SwiftData lightweight
    // migration is additive on the existing (unversioned) store.
    var gpsPointCount: Int = 0
    var rejectedGpsPointCount: Int = 0
    var hrPollCount: Int = 0
    var hrPollFailureCount: Int = 0
    var spo2PollCount: Int = 0
    var spo2PollFailureCount: Int = 0
    var liveActivityID: String?
    var lastSensorPollAt: Date?
    var lastGpsPointAt: Date?
    // How workout HR was captured: "stream" (continuous live HR stream) or "spot" (timer-driven
    // one-shot reads). Defaulted so the migration stays additive.
    var vitalsModeRaw: String = "spot"

    init(
        id: UUID = UUID(),
        type: String,
        status: ActivitySessionStatus = .recording,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        totalPauseSeconds: Double = 0,
        calories: Double? = nil,
        distanceMeters: Double? = nil,
        notes: String? = nil,
        useGps: Bool = true
    ) {
        self.id = id
        self.type = type
        self.statusRaw = status.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.totalPauseSeconds = totalPauseSeconds
        self.calories = calories
        self.distanceMeters = distanceMeters
        self.notes = notes
        self.useGps = useGps
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    var status: ActivitySessionStatus {
        get { ActivitySessionStatus(rawValue: statusRaw) ?? .recording }
        set {
            statusRaw = newValue.rawValue
            updatedAt = Date()
        }
    }
}

@Model
final class ActivitySample {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var measurementId: UUID?
    var kind: String
    var value: Double
    var unit: String
    var timestamp: Date
    var source: String
    var confidenceRaw: String
    
    init(
        id: UUID = UUID(),
        sessionId: UUID,
        measurementId: UUID? = nil,
        kind: String,
        value: Double,
        unit: String,
        timestamp: Date,
        source: String = "mock",
        confidence: DecodeConfidence = .known
    ) {
        self.id = id
        self.sessionId = sessionId
        self.measurementId = measurementId
        self.kind = kind
        self.value = value
        self.unit = unit
        self.timestamp = timestamp
        self.source = source
        self.confidenceRaw = confidence.rawValue
    }
}

/// One intraday activity bucket from a ring's history sync (e.g. a Colmi quarter-hour `0x43` sample).
/// Keyed by `startEpoch` (the bucket's unix start time) so re-syncing the same bucket **replaces** it
/// rather than accumulating — the daily total is then the sum of distinct buckets at read time. This
/// is the GadgetBridge model and the fix for daily totals drifting upward across repeated syncs.
@Model
final class ActivityBucketSample {
    /// Bucket start time in unix seconds — unique, so the same bucket upserts instead of duplicating.
    @Attribute(.unique) var startEpoch: Int
    var date: Date          // startOfDay for the bucket, for fast per-day queries
    var timestamp: Date     // bucket start instant
    var steps: Int
    var distanceMeters: Double
    var source: String
    var updatedAt: Date

    init(timestamp: Date, steps: Int, distanceMeters: Double, source: String = "ring_history") {
        self.startEpoch = Int(timestamp.timeIntervalSince1970)
        self.date = Calendar.current.startOfDay(for: timestamp)
        self.timestamp = timestamp
        self.steps = steps
        self.distanceMeters = distanceMeters
        self.source = source
        self.updatedAt = Date()
    }
}

@Model
final class ActivityGpsPoint {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    var horizontalAccuracy: Double?
    var speed: Double?
    var course: Double?
    var timestamp: Date
    // Whether this fix passed the route filter. Rejected points are persisted too so the
    // post-workout quality report can show coverage. Defaulted for additive migration.
    var accepted: Bool = true
    var rejectionReason: String?

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        speed: Double? = nil,
        course: Double? = nil,
        timestamp: Date = Date(),
        accepted: Bool = true,
        rejectionReason: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
        self.accepted = accepted
        self.rejectionReason = rejectionReason
    }
}

/// One sensor-poll attempt during a workout. Powers the recording-quality report and
/// makes the reverse-engineered ring's reliability transparent.
@Model
final class ActivitySensorPollEvent {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var timestamp: Date
    var kind: String    // "hr" | "spo2"
    var status: String  // "started" | "success" | "failed" | "skipped"
    var value: Double?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        timestamp: Date = Date(),
        kind: String,
        status: String,
        value: Double? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.kind = kind
        self.status = status
        self.value = value
        self.errorMessage = errorMessage
    }
}

@Model
final class ActivityEvent {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var kind: String
    var timestamp: Date
    var payloadJSON: String?
    
    init(id: UUID = UUID(), sessionId: UUID, kind: String, timestamp: Date = Date(), payloadJSON: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.timestamp = timestamp
        self.payloadJSON = payloadJSON
    }
}

@Model
final class CoachConversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    // Running token/cost totals across the conversation's turns. Defaults keep the
    // SwiftData migration lightweight for existing installs.
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var totalCostUSD: Double = 0

    init(id: UUID = UUID(), title: String = "Today check-in") {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class CoachMessage {
    @Attribute(.unique) var id: UUID
    var conversationId: UUID
    var role: String
    var body: String
    var cardsJSON: String?
    /// Encoded `PendingAction` awaiting a Confirm/Cancel tap (Milestone B).
    var pendingActionJSON: String? = nil
    /// Encoded `[CoachAttachmentRef]` for images attached to this message. The
    /// bytes live in `Documents/coach_attachments/`; this holds only the refs.
    /// Optional with a default keeps the SwiftData migration lightweight.
    var attachmentsJSON: String? = nil
    // Token/cost accounting for the turn that produced this message (assistant and
    // error rows carry it — failed turns burned tokens too). `costUSD` is the
    // provider-reported cost or a catalog estimate; nil when unavailable. Optional
    // with defaults keeps the SwiftData migration lightweight.
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var costUSD: Double? = nil
    var modelUsed: String? = nil
    var providerUsed: String? = nil
    /// Encoded `[UUID]` of activity sessions logged/edited by the turn that
    /// produced this message. Drives the in-chat workout card. Optional with a
    /// default keeps the SwiftData migration lightweight.
    var loggedActivityIdsJSON: String? = nil
    var createdAt: Date

    init(
        id: UUID = UUID(), conversationId: UUID, role: String, body: String, cardsJSON: String? = nil,
        pendingActionJSON: String? = nil, attachmentsJSON: String? = nil,
        inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil,
        modelUsed: String? = nil, providerUsed: String? = nil,
        loggedActivityIdsJSON: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.body = body
        self.cardsJSON = cardsJSON
        self.pendingActionJSON = pendingActionJSON
        self.attachmentsJSON = attachmentsJSON
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.modelUsed = modelUsed
        self.providerUsed = providerUsed
        self.loggedActivityIdsJSON = loggedActivityIdsJSON
        self.createdAt = createdAt
    }
}

@Model
final class CoachMemory {
    @Attribute(.unique) var id: UUID
    var key: String
    var value: String
    // Typed-memory fields (Milestone B). Defaults keep the SwiftData migration
    // lightweight for existing installs.
    var memoryType: String = "note"
    var importance: Int = 3
    var expiresAt: Date? = nil
    var sourceMessageId: UUID? = nil
    var isUserEditable: Bool = true
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        key: String,
        value: String,
        memoryType: String = "note",
        importance: Int = 3,
        expiresAt: Date? = nil,
        sourceMessageId: UUID? = nil,
        isUserEditable: Bool = true
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.memoryType = memoryType
        self.importance = importance
        self.expiresAt = expiresAt
        self.sourceMessageId = sourceMessageId
        self.isUserEditable = isUserEditable
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
final class CoachToolCall {
    @Attribute(.unique) var id: UUID
    var conversationId: UUID
    var messageId: UUID?
    var toolName: String
    var inputJSON: String?
    var outputJSON: String?
    // Friendly label ("Got HR data"), execution status ("success"/"error"), and
    // 0-based ordering within the turn. Defaults keep the SwiftData migration
    // lightweight; legacy rows fall back to a humanized `toolName` in the UI.
    var label: String = ""
    var statusRaw: String = "success"
    var sequence: Int = 0
    var createdAt: Date

    init(
        id: UUID = UUID(), conversationId: UUID, messageId: UUID? = nil, toolName: String,
        inputJSON: String? = nil, outputJSON: String? = nil,
        label: String = "", statusRaw: String = "success", sequence: Int = 0
    ) {
        self.id = id
        self.conversationId = conversationId
        self.messageId = messageId
        self.toolName = toolName
        self.inputJSON = inputJSON
        self.outputJSON = outputJSON
        self.label = label
        self.statusRaw = statusRaw
        self.sequence = sequence
        self.createdAt = Date()
    }
}
