import Foundation
import SwiftData

// The full-app export archive: a versioned, Codable snapshot of every SwiftData model plus the
// UserDefaults settings blobs and coach attachment images. One JSON file in, one JSON file out —
// plain JSON so users can analyze their data outside the app (jq / pandas / spreadsheets).
//
// Design rules (see `DataArchiveService` for the read/write side):
// - Every DTO mirrors its model's stored raw fields verbatim (`kindRaw`, `stateRaw`, `*JSON`
//   strings pass through opaquely) so unknown future enum values survive a round trip.
// - All UUIDs (ids and loose foreign keys) are preserved exactly — the models have no
//   `@Relationship` edges, so identity is the only thing holding the graphs together.
// - Import assigns every stored property directly instead of trusting model inits: several inits
//   re-derive fields from the *current* calendar/timezone (`ActivityDaily.date`,
//   `ActivityBucketSample.date`), which would corrupt cross-timezone restores.
// - When a model gains a stored property, mirror it here — the round-trip unit test only
//   guards fields that exist in the DTO.
// - Types are `nonisolated` (the project defaults to MainActor isolation) so encode/decode can run
//   off the main actor; the model-facing mappers are `@MainActor` because `@Model` classes are not.

// MARK: - Envelope

nonisolated struct PulseArchive: Codable, Sendable {
    /// Bumped to 2 when readiness scores joined the archive. `importArchive` refuses anything
    /// newer than this, which is the honest behaviour: an older build genuinely cannot restore a
    /// table it has no model for.
    static let currentFormatVersion = 2

    var formatVersion: Int
    var exportedAt: Date
    var appVersion: String
    /// Per-entity row counts — quick validation and an at-a-glance summary for external tools.
    var counts: [String: Int]

    var devices: [ArchiveDevice]
    var activityDailies: [ArchiveActivityDaily]
    var measurements: [ArchiveMeasurement]
    var batterySamples: [ArchiveBatterySample]
    var sleepSessions: [ArchiveSleepSession]
    var sleepStageBlocks: [ArchiveSleepStageBlock]
    /// Added in format version 2. **Optional on purpose**: `PulseArchive` uses the synthesized
    /// decoder, which has no notion of property defaults, so a non-optional array here would make
    /// every existing v1 archive fail to decode. Read it as `?? []`; a new export always writes it.
    /// Any future table added to this struct should follow the same pattern.
    var readinessDailies: [ArchiveReadinessDaily]?
    var rawPackets: [ArchiveRawPacket]
    var derivedUpdates: [ArchiveDerivedUpdate]
    var userProfiles: [ArchiveUserProfile]
    var userGoals: [ArchiveUserGoal]
    var deviceMeasurementConfigs: [ArchiveDeviceMeasurementConfig]
    var activitySessions: [ArchiveActivitySession]
    var activitySamples: [ArchiveActivitySample]
    var activityBucketSamples: [ArchiveActivityBucketSample]
    var activityGpsPoints: [ArchiveActivityGpsPoint]
    var activityEvents: [ArchiveActivityEvent]
    var activitySensorPollEvents: [ArchiveActivitySensorPollEvent]
    var coachConversations: [ArchiveCoachConversation]
    var coachMessages: [ArchiveCoachMessage]
    var coachMemories: [ArchiveCoachMemory]
    var coachToolCalls: [ArchiveCoachToolCall]
    var coachNotificationRecords: [ArchiveCoachNotificationRecord]
    var coachSummaries: [ArchiveCoachSummary]
    var wearableLogs: [ArchiveWearableLog]

    /// Raw UserDefaults JSON blobs keyed by their storage key (metric prefs, workout prefs,
    /// calibration, coach settings, Apple Health prefs). Opaque pass-through — never re-encoded.
    var settings: [String: String]
    /// `Documents/coach_attachments/*` image files, base64-encoded.
    var attachments: [ArchiveAttachment]
}

/// Minimal first-pass decode used to give a clear "newer app version" error before attempting the
/// full (and stricter) archive decode.
nonisolated struct ArchiveVersionProbe: Codable, Sendable {
    var formatVersion: Int
}

nonisolated struct ArchiveAttachment: Codable, Sendable {
    /// Filename within `coach_attachments/` (e.g. `<uuid>.jpg`) — referenced by
    /// `CoachMessage.attachmentsJSON`, so it must survive unchanged.
    var file: String
    var base64: String
}

// MARK: - JSON coding

/// Shared encoder/decoder configuration for the archive. ISO8601 with fractional seconds keeps the
/// file human-readable and externally parseable; the decoder also accepts plain ISO8601 (no
/// fraction) for tolerance.
nonisolated enum ArchiveCoding {
    // ISO8601DateFormatter is documented thread-safe, so sharing one instance across the detached
    // encode/decode tasks is sound.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFractional.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = isoFractional.date(from: string) ?? isoPlain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(string)")
        }
        return decoder
    }
}

// MARK: - Entity DTOs

nonisolated struct ArchiveDevice: Codable, Sendable {
    var id: UUID
    var name: String
    var advertisedName: String?
    var peripheralIdentifier: String?
    var bleAddressHint: String?
    var batteryPercent: Int?
    var stateRaw: String
    var lastConnectedAt: Date?
    var lastDisconnectedAt: Date?
    var lastSyncAt: Date?
    var lastFullSyncAt: Date?
    var firmwareVersion: String?
    var wearableModelID: String?
    var deviceTypeRaw: String
    var capabilitiesRaw: String
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: Device) {
        id = m.id
        name = m.name
        advertisedName = m.advertisedName
        peripheralIdentifier = m.peripheralIdentifier
        bleAddressHint = m.bleAddressHint
        batteryPercent = m.batteryPercent
        stateRaw = m.stateRaw
        lastConnectedAt = m.lastConnectedAt
        lastDisconnectedAt = m.lastDisconnectedAt
        lastSyncAt = m.lastSyncAt
        lastFullSyncAt = m.lastFullSyncAt
        firmwareVersion = m.firmwareVersion
        wearableModelID = m.wearableModelID
        deviceTypeRaw = m.deviceTypeRaw
        capabilitiesRaw = m.capabilitiesRaw
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = Device()
        m.id = id
        m.name = name
        m.advertisedName = advertisedName
        m.peripheralIdentifier = peripheralIdentifier
        m.bleAddressHint = bleAddressHint
        m.batteryPercent = batteryPercent
        m.stateRaw = stateRaw
        m.lastConnectedAt = lastConnectedAt
        m.lastDisconnectedAt = lastDisconnectedAt
        m.lastSyncAt = lastSyncAt
        m.lastFullSyncAt = lastFullSyncAt
        m.firmwareVersion = firmwareVersion
        m.wearableModelID = wearableModelID
        m.deviceTypeRaw = deviceTypeRaw
        m.capabilitiesRaw = capabilitiesRaw
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveActivityDaily: Codable, Sendable {
    var id: UUID
    var date: Date
    var steps: Int
    var calories: Double
    var distanceMeters: Double
    var activeMinutes: Int
    var source: String
    var syncedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: ActivityDaily) {
        id = m.id
        date = m.date
        steps = m.steps
        calories = m.calories
        distanceMeters = m.distanceMeters
        activeMinutes = m.activeMinutes
        source = m.source
        syncedAt = m.syncedAt
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivityDaily(date: date)
        m.id = id
        m.date = date   // init re-derives startOfDay in the local timezone; restore the exact value
        m.steps = steps
        m.calories = calories
        m.distanceMeters = distanceMeters
        m.activeMinutes = activeMinutes
        m.source = source
        m.syncedAt = syncedAt
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveMeasurement: Codable, Sendable {
    var id: UUID
    var kindRaw: String
    var value: Double
    var unit: String
    var timestamp: Date
    var sourceRaw: String
    var confidenceRaw: String
    var activitySessionId: UUID?
    var rawPacketId: UUID?
    var createdAt: Date

    @MainActor init(_ m: PulseLoop.Measurement) {
        id = m.id
        kindRaw = m.kindRaw
        value = m.value
        unit = m.unit
        timestamp = m.timestamp
        sourceRaw = m.sourceRaw
        confidenceRaw = m.confidenceRaw
        activitySessionId = m.activitySessionId
        rawPacketId = m.rawPacketId
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = PulseLoop.Measurement(kind: .heartRate, value: value, unit: unit, timestamp: timestamp)
        m.id = id
        m.kindRaw = kindRaw
        m.sourceRaw = sourceRaw
        m.confidenceRaw = confidenceRaw
        m.activitySessionId = activitySessionId
        m.rawPacketId = rawPacketId
        m.createdAt = createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveBatterySample: Codable, Sendable {
    var id: UUID
    var percent: Int
    var timestamp: Date
    var createdAt: Date

    @MainActor init(_ m: BatterySample) {
        id = m.id
        percent = m.percent
        timestamp = m.timestamp
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = BatterySample(percent: percent, timestamp: timestamp)
        m.id = id
        m.createdAt = createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveSleepSession: Codable, Sendable {
    var id: UUID
    var date: Date
    var startAt: Date
    var endAt: Date
    var totalMinutes: Int
    var score: Int?
    var syncedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: SleepSession) {
        id = m.id
        date = m.date
        startAt = m.startAt
        endAt = m.endAt
        totalMinutes = m.totalMinutes
        score = m.score
        syncedAt = m.syncedAt
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = SleepSession(date: date, startAt: startAt, endAt: endAt, totalMinutes: totalMinutes, score: score, syncedAt: syncedAt)
        m.id = id
        m.date = date   // init re-derives startOfDay in the local timezone; restore the exact value
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveSleepStageBlock: Codable, Sendable {
    var id: UUID
    var sessionId: UUID
    var startAt: Date
    var startMinute: Int
    var durationMinutes: Int
    var stageRaw: String

    @MainActor init(_ m: SleepStageBlock) {
        id = m.id
        sessionId = m.sessionId
        startAt = m.startAt
        startMinute = m.startMinute
        durationMinutes = m.durationMinutes
        stageRaw = m.stageRaw
    }

    @MainActor func insert(into context: ModelContext) {
        let m = SleepStageBlock(sessionId: sessionId, startAt: startAt, startMinute: startMinute, durationMinutes: durationMinutes, stage: .unknown)
        m.id = id
        m.stageRaw = stageRaw
        context.insert(m)
    }
}

nonisolated struct ArchiveRawPacket: Codable, Sendable {
    var id: UUID
    var timestamp: Date
    var directionRaw: String
    var commandId: Int
    var hexPayload: String
    var decodedKind: String?
    var decodedJSON: String?
    var confidenceRaw: String
    var createdAt: Date

    @MainActor init(_ m: RawPacketRow) {
        id = m.id
        timestamp = m.timestamp
        directionRaw = m.directionRaw
        commandId = m.commandId
        hexPayload = m.hexPayload
        decodedKind = m.decodedKind
        decodedJSON = m.decodedJSON
        confidenceRaw = m.confidenceRaw
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = RawPacketRow(timestamp: timestamp, direction: .incoming, commandId: commandId, hexPayload: hexPayload, decodedKind: decodedKind, decodedJSON: decodedJSON)
        m.id = id
        m.directionRaw = directionRaw
        m.confidenceRaw = confidenceRaw
        m.createdAt = createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveDerivedUpdate: Codable, Sendable {
    var id: UUID
    var timestamp: Date
    var kind: String
    var entityType: String
    var entityId: String
    var payloadJSON: String?

    @MainActor init(_ m: DerivedUpdateRow) {
        id = m.id
        timestamp = m.timestamp
        kind = m.kind
        entityType = m.entityType
        entityId = m.entityId
        payloadJSON = m.payloadJSON
    }

    @MainActor func insert(into context: ModelContext) {
        let m = DerivedUpdateRow(timestamp: timestamp, kind: kind, entityType: entityType, entityId: entityId, payloadJSON: payloadJSON)
        m.id = id
        context.insert(m)
    }
}

nonisolated struct ArchiveUserProfile: Codable, Sendable {
    var id: UUID
    var name: String?
    var age: Int?
    var sex: String?
    var heightCm: Double?
    var weightKg: Double?
    var unitsRaw: String
    var onboardingCompleted: Bool
    var baselineCompleted: Bool
    var athleteMode: Bool
    var altitudeMeters: Double?
    var usesBetaBlockers: Bool?
    var hasKnownLungCondition: Bool?
    var preferredGlucoseUnitRaw: String
    var hrZoneModeRaw: String
    var hrRestingBaseline: Double?
    var hrRestingBaselineUpdatedAt: Date?
    var hrCustomLowUpper: Double?
    var hrCustomAthleticUpper: Double?
    var hrCustomElevatedStart: Double?
    var hrCustomHighStart: Double?
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: UserProfile) {
        id = m.id
        name = m.name
        age = m.age
        sex = m.sex
        heightCm = m.heightCm
        weightKg = m.weightKg
        unitsRaw = m.unitsRaw
        onboardingCompleted = m.onboardingCompleted
        baselineCompleted = m.baselineCompleted
        athleteMode = m.athleteMode
        altitudeMeters = m.altitudeMeters
        usesBetaBlockers = m.usesBetaBlockers
        hasKnownLungCondition = m.hasKnownLungCondition
        preferredGlucoseUnitRaw = m.preferredGlucoseUnitRaw
        hrZoneModeRaw = m.hrZoneModeRaw
        hrRestingBaseline = m.hrRestingBaseline
        hrRestingBaselineUpdatedAt = m.hrRestingBaselineUpdatedAt
        hrCustomLowUpper = m.hrCustomLowUpper
        hrCustomAthleticUpper = m.hrCustomAthleticUpper
        hrCustomElevatedStart = m.hrCustomElevatedStart
        hrCustomHighStart = m.hrCustomHighStart
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = UserProfile()
        m.id = id
        m.name = name
        m.age = age
        m.sex = sex
        m.heightCm = heightCm
        m.weightKg = weightKg
        m.unitsRaw = unitsRaw
        m.onboardingCompleted = onboardingCompleted
        m.baselineCompleted = baselineCompleted
        m.athleteMode = athleteMode
        m.altitudeMeters = altitudeMeters
        m.usesBetaBlockers = usesBetaBlockers
        m.hasKnownLungCondition = hasKnownLungCondition
        m.preferredGlucoseUnitRaw = preferredGlucoseUnitRaw
        m.hrZoneModeRaw = hrZoneModeRaw
        m.hrRestingBaseline = hrRestingBaseline
        m.hrRestingBaselineUpdatedAt = hrRestingBaselineUpdatedAt
        m.hrCustomLowUpper = hrCustomLowUpper
        m.hrCustomAthleticUpper = hrCustomAthleticUpper
        m.hrCustomElevatedStart = hrCustomElevatedStart
        m.hrCustomHighStart = hrCustomHighStart
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveUserGoal: Codable, Sendable {
    var id: UUID
    var steps: Int
    var sleepMinutes: Int
    var activeMinutes: Int
    var workoutsPerWeek: Int
    var distanceMeters: Double
    var calories: Int
    var updatedAt: Date

    @MainActor init(_ m: UserGoal) {
        id = m.id
        steps = m.steps
        sleepMinutes = m.sleepMinutes
        activeMinutes = m.activeMinutes
        workoutsPerWeek = m.workoutsPerWeek
        distanceMeters = m.distanceMeters
        calories = m.calories
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = UserGoal(id: id, steps: steps, sleepMinutes: sleepMinutes, activeMinutes: activeMinutes, workoutsPerWeek: workoutsPerWeek, distanceMeters: distanceMeters, calories: calories)
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveDeviceMeasurementConfig: Codable, Sendable {
    var deviceId: UUID
    var hrIntervalMinutes: Int
    var hrEnabled: Bool
    var spo2Enabled: Bool
    var stressEnabled: Bool
    var hrvEnabled: Bool
    var temperatureEnabled: Bool
    var updatedAt: Date

    @MainActor init(_ m: DeviceMeasurementConfig) {
        deviceId = m.deviceId
        hrIntervalMinutes = m.hrIntervalMinutes
        hrEnabled = m.hrEnabled
        spo2Enabled = m.spo2Enabled
        stressEnabled = m.stressEnabled
        hrvEnabled = m.hrvEnabled
        temperatureEnabled = m.temperatureEnabled
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = DeviceMeasurementConfig(deviceId: deviceId)
        m.hrIntervalMinutes = hrIntervalMinutes
        m.hrEnabled = hrEnabled
        m.spo2Enabled = spo2Enabled
        m.stressEnabled = stressEnabled
        m.hrvEnabled = hrvEnabled
        m.temperatureEnabled = temperatureEnabled
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveActivitySession: Codable, Sendable {
    var id: UUID
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
    var gpsPointCount: Int
    var rejectedGpsPointCount: Int
    var hrPollCount: Int
    var hrPollFailureCount: Int
    var spo2PollCount: Int
    var spo2PollFailureCount: Int
    var liveActivityID: String?
    var lastSensorPollAt: Date?
    var lastGpsPointAt: Date?
    var vitalsModeRaw: String
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: ActivitySession) {
        id = m.id
        type = m.type
        statusRaw = m.statusRaw
        startedAt = m.startedAt
        endedAt = m.endedAt
        totalPauseSeconds = m.totalPauseSeconds
        calories = m.calories
        distanceMeters = m.distanceMeters
        avgHeartRate = m.avgHeartRate
        minHeartRate = m.minHeartRate
        maxHeartRate = m.maxHeartRate
        avgSpO2 = m.avgSpO2
        latestSpO2 = m.latestSpO2
        notes = m.notes
        useGps = m.useGps
        perceivedEffort = m.perceivedEffort
        gpsPointCount = m.gpsPointCount
        rejectedGpsPointCount = m.rejectedGpsPointCount
        hrPollCount = m.hrPollCount
        hrPollFailureCount = m.hrPollFailureCount
        spo2PollCount = m.spo2PollCount
        spo2PollFailureCount = m.spo2PollFailureCount
        liveActivityID = m.liveActivityID
        lastSensorPollAt = m.lastSensorPollAt
        lastGpsPointAt = m.lastGpsPointAt
        vitalsModeRaw = m.vitalsModeRaw
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivitySession(
            type: type, startedAt: startedAt, endedAt: endedAt, totalPauseSeconds: totalPauseSeconds,
            calories: calories, distanceMeters: distanceMeters, notes: notes, useGps: useGps
        )
        m.id = id
        m.statusRaw = statusRaw
        m.avgHeartRate = avgHeartRate
        m.minHeartRate = minHeartRate
        m.maxHeartRate = maxHeartRate
        m.avgSpO2 = avgSpO2
        m.latestSpO2 = latestSpO2
        m.perceivedEffort = perceivedEffort
        m.gpsPointCount = gpsPointCount
        m.rejectedGpsPointCount = rejectedGpsPointCount
        m.hrPollCount = hrPollCount
        m.hrPollFailureCount = hrPollFailureCount
        m.spo2PollCount = spo2PollCount
        m.spo2PollFailureCount = spo2PollFailureCount
        m.liveActivityID = liveActivityID
        m.lastSensorPollAt = lastSensorPollAt
        m.lastGpsPointAt = lastGpsPointAt
        m.vitalsModeRaw = vitalsModeRaw
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveActivitySample: Codable, Sendable {
    var id: UUID
    var sessionId: UUID
    var measurementId: UUID?
    var kind: String
    var value: Double
    var unit: String
    var timestamp: Date
    var source: String
    var confidenceRaw: String

    @MainActor init(_ m: ActivitySample) {
        id = m.id
        sessionId = m.sessionId
        measurementId = m.measurementId
        kind = m.kind
        value = m.value
        unit = m.unit
        timestamp = m.timestamp
        source = m.source
        confidenceRaw = m.confidenceRaw
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivitySample(sessionId: sessionId, measurementId: measurementId, kind: kind, value: value, unit: unit, timestamp: timestamp, source: source)
        m.id = id
        m.confidenceRaw = confidenceRaw
        context.insert(m)
    }
}

nonisolated struct ArchiveActivityBucketSample: Codable, Sendable {
    var startEpoch: Int
    var date: Date
    var timestamp: Date
    var steps: Int
    var distanceMeters: Double
    var source: String
    var updatedAt: Date

    @MainActor init(_ m: ActivityBucketSample) {
        startEpoch = m.startEpoch
        date = m.date
        timestamp = m.timestamp
        steps = m.steps
        distanceMeters = m.distanceMeters
        source = m.source
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivityBucketSample(timestamp: timestamp, steps: steps, distanceMeters: distanceMeters, source: source)
        // The init re-derives startEpoch/date from the local timezone; restore the exact stored
        // values — startEpoch is the unique upsert key.
        m.startEpoch = startEpoch
        m.date = date
        m.timestamp = timestamp
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveActivityGpsPoint: Codable, Sendable {
    var id: UUID
    var sessionId: UUID
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    var horizontalAccuracy: Double?
    var speed: Double?
    var course: Double?
    var timestamp: Date
    var accepted: Bool
    var rejectionReason: String?

    @MainActor init(_ m: ActivityGpsPoint) {
        id = m.id
        sessionId = m.sessionId
        latitude = m.latitude
        longitude = m.longitude
        altitude = m.altitude
        horizontalAccuracy = m.horizontalAccuracy
        speed = m.speed
        course = m.course
        timestamp = m.timestamp
        accepted = m.accepted
        rejectionReason = m.rejectionReason
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivityGpsPoint(
            id: id, sessionId: sessionId, latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, speed: speed, course: course, timestamp: timestamp,
            accepted: accepted, rejectionReason: rejectionReason
        )
        context.insert(m)
    }
}

nonisolated struct ArchiveActivityEvent: Codable, Sendable {
    var id: UUID
    var sessionId: UUID
    var kind: String
    var timestamp: Date
    var payloadJSON: String?

    @MainActor init(_ m: ActivityEvent) {
        id = m.id
        sessionId = m.sessionId
        kind = m.kind
        timestamp = m.timestamp
        payloadJSON = m.payloadJSON
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivityEvent(id: id, sessionId: sessionId, kind: kind, timestamp: timestamp, payloadJSON: payloadJSON)
        context.insert(m)
    }
}

nonisolated struct ArchiveActivitySensorPollEvent: Codable, Sendable {
    var id: UUID
    var sessionId: UUID
    var timestamp: Date
    var kind: String
    var status: String
    var value: Double?
    var errorMessage: String?

    @MainActor init(_ m: ActivitySensorPollEvent) {
        id = m.id
        sessionId = m.sessionId
        timestamp = m.timestamp
        kind = m.kind
        status = m.status
        value = m.value
        errorMessage = m.errorMessage
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivitySensorPollEvent(id: id, sessionId: sessionId, timestamp: timestamp, kind: kind, status: status, value: value, errorMessage: errorMessage)
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachConversation: Codable, Sendable {
    var id: UUID
    var title: String
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalCostUSD: Double
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: CoachConversation) {
        id = m.id
        title = m.title
        totalInputTokens = m.totalInputTokens
        totalOutputTokens = m.totalOutputTokens
        totalCostUSD = m.totalCostUSD
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachConversation(id: id, title: title)
        m.totalInputTokens = totalInputTokens
        m.totalOutputTokens = totalOutputTokens
        m.totalCostUSD = totalCostUSD
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachMessage: Codable, Sendable {
    var id: UUID
    var conversationId: UUID
    var role: String
    var body: String
    var cardsJSON: String?
    var pendingActionJSON: String?
    var attachmentsJSON: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var costUSD: Double?
    var modelUsed: String?
    var providerUsed: String?
    var loggedActivityIdsJSON: String?
    var createdAt: Date

    @MainActor init(_ m: CoachMessage) {
        id = m.id
        conversationId = m.conversationId
        role = m.role
        body = m.body
        cardsJSON = m.cardsJSON
        pendingActionJSON = m.pendingActionJSON
        attachmentsJSON = m.attachmentsJSON
        inputTokens = m.inputTokens
        outputTokens = m.outputTokens
        costUSD = m.costUSD
        modelUsed = m.modelUsed
        providerUsed = m.providerUsed
        loggedActivityIdsJSON = m.loggedActivityIdsJSON
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachMessage(
            id: id, conversationId: conversationId, role: role, body: body, cardsJSON: cardsJSON,
            pendingActionJSON: pendingActionJSON, attachmentsJSON: attachmentsJSON,
            inputTokens: inputTokens, outputTokens: outputTokens, costUSD: costUSD,
            modelUsed: modelUsed, providerUsed: providerUsed,
            loggedActivityIdsJSON: loggedActivityIdsJSON, createdAt: createdAt
        )
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachMemory: Codable, Sendable {
    var id: UUID
    var key: String
    var value: String
    var memoryType: String
    var importance: Int
    var expiresAt: Date?
    var sourceMessageId: UUID?
    var isUserEditable: Bool
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: CoachMemory) {
        id = m.id
        key = m.key
        value = m.value
        memoryType = m.memoryType
        importance = m.importance
        expiresAt = m.expiresAt
        sourceMessageId = m.sourceMessageId
        isUserEditable = m.isUserEditable
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachMemory(id: id, key: key, value: value, memoryType: memoryType, importance: importance, expiresAt: expiresAt, sourceMessageId: sourceMessageId, isUserEditable: isUserEditable)
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachToolCall: Codable, Sendable {
    var id: UUID
    var conversationId: UUID
    var messageId: UUID?
    var toolName: String
    var inputJSON: String?
    var outputJSON: String?
    var label: String
    var statusRaw: String
    var sequence: Int
    var createdAt: Date

    @MainActor init(_ m: CoachToolCall) {
        id = m.id
        conversationId = m.conversationId
        messageId = m.messageId
        toolName = m.toolName
        inputJSON = m.inputJSON
        outputJSON = m.outputJSON
        label = m.label
        statusRaw = m.statusRaw
        sequence = m.sequence
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachToolCall(
            id: id, conversationId: conversationId, messageId: messageId, toolName: toolName,
            inputJSON: inputJSON, outputJSON: outputJSON, label: label, statusRaw: statusRaw, sequence: sequence
        )
        m.createdAt = createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachNotificationRecord: Codable, Sendable {
    var id: UUID
    var slotRaw: String
    var dateKey: String
    var title: String
    var body: String
    var createdAt: Date

    @MainActor init(_ m: CoachNotificationRecord) {
        id = m.id
        slotRaw = m.slotRaw
        dateKey = m.dateKey
        title = m.title
        body = m.body
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachNotificationRecord(id: id, slotRaw: slotRaw, dateKey: dateKey, title: title, body: body)
        m.createdAt = createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachSummary: Codable, Sendable {
    var id: UUID
    var kind: String
    var scopeKey: String
    var title: String
    var body: String
    var chipsJSON: String?
    var conversationId: UUID?
    var dataSignature: String
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: CoachSummary) {
        id = m.id
        kind = m.kind
        scopeKey = m.scopeKey
        title = m.title
        body = m.body
        chipsJSON = m.chipsJSON
        conversationId = m.conversationId
        dataSignature = m.dataSignature
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachSummary(id: id, kind: kind, scopeKey: scopeKey, title: title, body: body, dataSignature: dataSignature)
        m.chipsJSON = chipsJSON
        m.conversationId = conversationId
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveWearableLog: Codable, Sendable {
    var id: UUID
    var timestamp: Date
    var deviceTypeRaw: String
    var categoryRaw: String
    var levelRaw: String
    var message: String
    var metadataJSON: String?

    @MainActor init(_ m: WearableLog) {
        id = m.id
        timestamp = m.timestamp
        deviceTypeRaw = m.deviceTypeRaw
        categoryRaw = m.categoryRaw
        levelRaw = m.levelRaw
        message = m.message
        metadataJSON = m.metadataJSON
    }

    @MainActor func insert(into context: ModelContext) {
        let m = WearableLog(id: id, timestamp: timestamp, category: .connection, level: .info, message: message, metadataJSON: metadataJSON)
        m.deviceTypeRaw = deviceTypeRaw
        m.categoryRaw = categoryRaw
        m.levelRaw = levelRaw
        context.insert(m)
    }
}
