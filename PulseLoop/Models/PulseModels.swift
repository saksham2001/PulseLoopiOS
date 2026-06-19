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

    /// Display unit for a measurement of this kind.
    var unit: String {
        switch self {
        case .heartRate: return "bpm"
        case .spo2: return "%"
        case .stress: return ""
        case .hrv: return "ms"
        case .temperature: return "°C"
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
    var firmwareVersion: String?
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

@Model
final class UserProfile {
    @Attribute(.unique) var id: UUID
    var name: String?
    var age: Int?
    var sex: String?
    var heightCm: Double?
    var weightKg: Double?
    var onboardingCompleted: Bool
    var baselineCompleted: Bool
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String? = nil,
        age: Int? = nil,
        sex: String? = nil,
        heightCm: Double? = nil,
        weightKg: Double? = nil,
        onboardingCompleted: Bool = false,
        baselineCompleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.age = age
        self.sex = sex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.onboardingCompleted = onboardingCompleted
        self.baselineCompleted = baselineCompleted
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
    var updatedAt: Date
    
    init(id: UUID = UUID(), steps: Int = 10000, sleepMinutes: Int = 480, activeMinutes: Int = 45, workoutsPerWeek: Int = 4) {
        self.id = id
        self.steps = steps
        self.sleepMinutes = sleepMinutes
        self.activeMinutes = activeMinutes
        self.workoutsPerWeek = workoutsPerWeek
        self.updatedAt = Date()
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
    var createdAt: Date

    init(id: UUID = UUID(), conversationId: UUID, role: String, body: String, cardsJSON: String? = nil, pendingActionJSON: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.body = body
        self.cardsJSON = cardsJSON
        self.pendingActionJSON = pendingActionJSON
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
    var createdAt: Date
    
    init(id: UUID = UUID(), conversationId: UUID, messageId: UUID? = nil, toolName: String, inputJSON: String? = nil, outputJSON: String? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.messageId = messageId
        self.toolName = toolName
        self.inputJSON = inputJSON
        self.outputJSON = outputJSON
        self.createdAt = Date()
    }
}
