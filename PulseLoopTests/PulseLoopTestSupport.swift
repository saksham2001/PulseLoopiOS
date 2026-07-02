import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// Shared helpers for the in-memory SwiftData test suite.
@MainActor
enum TestSupport {
    /// A fresh, isolated in-memory store per call.
    static func makeContext() throws -> ModelContext {
        let container = try ModelContainerFactory.make(inMemory: true)
        return ModelContext(container)
    }

    /// Coach settings with the master switch on, so `CoachFeatureFlags(... hasAPIKey: true)`
    /// resolves to an enabled coach. The product default is opt-out (`coachMasterEnabled == false`),
    /// which would otherwise route every turn to the scripted fallback.
    static func enabledCoachSettings() -> CoachSettings {
        var settings = CoachSettings.default
        settings.coachMasterEnabled = true
        return settings
    }

    static func day(_ offset: Int, from base: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: base)) ?? base
    }

    @discardableResult
    static func insertActivity(
        date: Date,
        steps: Int = 0,
        calories: Double = 0,
        distanceMeters: Double = 0,
        activeMinutes: Int = 0,
        source: String = "live",
        syncedAt: Date? = Date(),
        into context: ModelContext
    ) -> ActivityDaily {
        let row = ActivityDaily(date: date, steps: steps, calories: calories, distanceMeters: distanceMeters, activeMinutes: activeMinutes, source: source)
        row.syncedAt = syncedAt
        context.insert(row)
        try? context.save()
        return row
    }

    @discardableResult
    static func insertMeasurement(
        kind: MeasurementKind,
        value: Double,
        timestamp: Date,
        source: MeasurementSource = .live,
        into context: ModelContext
    ) -> PulseLoop.Measurement {
        // `Measurement` is qualified to disambiguate from Foundation.Measurement, which is
        // also in scope here via `import Foundation`/XCTest in the test module.
        let row = PulseLoop.Measurement(kind: kind, value: value, unit: kind == .heartRate ? "bpm" : "%", timestamp: timestamp, source: source)
        context.insert(row)
        try? context.save()
        return row
    }

    @discardableResult
    static func insertSleep(
        nightStart: Date,
        stages: [SleepStage],
        syncedAt: Date? = Date(),
        into context: ModelContext
    ) -> SleepSession {
        let end = Calendar.current.date(byAdding: .minute, value: stages.count, to: nightStart) ?? nightStart
        // Key the session on its waking day, mirroring production `persistSleepTimeline`: a night
        // starting before midnight belongs to the morning it ends on, not the calendar day it began.
        let date = Calendar.current.wakingDay(forSleepStart: nightStart)
        let session = SleepSession(date: date, startAt: nightStart, endAt: end, totalMinutes: stages.count, syncedAt: syncedAt)
        context.insert(session)
        for (index, stage) in stages.enumerated() {
            let blockStart = Calendar.current.date(byAdding: .minute, value: index, to: nightStart) ?? nightStart
            context.insert(SleepStageBlock(sessionId: session.id, startAt: blockStart, startMinute: index, durationMinutes: 1, stage: stage))
        }
        try? context.save()
        return session
    }
}
