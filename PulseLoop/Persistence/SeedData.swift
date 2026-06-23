import Foundation
import SwiftData

enum SeedData {
    /// One synthetic finished workout for the demo seed. `origin` seeds a GPS loop
    /// so the route map renders in the Simulator (which has no real GPS).
    private struct SeedWorkout {
        let offset: Int
        let type: String
        let minutes: Int
        let distance: Double
        let calories: Double
        let origin: (Double, Double)?
    }

    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        let descriptor = FetchDescriptor<Device>()
        let count = (try? context.fetchCount(descriptor)) ?? 0
        guard count == 0 else { return }
        seedDemo(context, completeOnboarding: true)
    }
    
    @MainActor
    static func seedDemo(_ context: ModelContext, completeOnboarding: Bool = false) {
        let calendar = Calendar.current
        let now = Date()
        
        let profile = UserProfile(
            name: "Saksham",
            age: 25,
            sex: "not set",
            heightCm: 178,
            weightKg: 73,
            onboardingCompleted: completeOnboarding,
            baselineCompleted: false
        )
        context.insert(profile)
        context.insert(UserGoal(steps: 10000, sleepMinutes: 480, activeMinutes: 45, workoutsPerWeek: 4))
        context.insert(Device(advertisedName: "SMART_RING", bleAddressHint: "41:42:2e:c7:5b:6a", batteryPercent: 82, state: .connected))

        // ~90 days of daily activity so Week/Month/Year range graphs render fully.
        for offset in stride(from: -89, through: 0, by: 1) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            let isWeekend = weekday == 1 || weekday == 7
            // Weekly rhythm + slow upward trend + deterministic wobble.
            let base = 7600.0 + Double(offset + 89) * 9
            let wobble = sin(Double(offset) * 0.9) * 1400 + Double((abs(offset) * 37) % 900)
            let steps = max(2600, Int(base + wobble - (isWeekend ? 1500 : 0)))
            context.insert(
                ActivityDaily(
                    date: date,
                    steps: steps,
                    calories: Double(steps) * 0.045 + 120,
                    distanceMeters: Double(steps) * 0.72,
                    activeMinutes: max(8, steps / 230)
                )
            )
        }

        // Dense recent HR/SpO2 samples for the Vitals charts.
        for hour in stride(from: -24, through: 0, by: 1) {
            guard let ts = calendar.date(byAdding: .hour, value: hour, to: now) else { continue }
            let hr = 60 + Int((sin(Double(hour) * 0.7) + 1) * 14) + abs(hour % 5)
            context.insert(Measurement(kind: .heartRate, value: Double(hr), unit: "bpm", timestamp: ts, source: .mock))
        }
        for hour in stride(from: -22, through: 0, by: 3) {
            guard let ts = calendar.date(byAdding: .hour, value: hour, to: now) else { continue }
            context.insert(Measurement(kind: .spo2, value: Double(96 + abs(hour % 4 == 0 ? 3 : abs(hour) % 3)), unit: "%", timestamp: ts, source: .mock))
        }

        // ~30 nights of sleep with stage blocks + per-night scores.
        for i in 0..<30 {
            guard let dayDate = calendar.date(byAdding: .day, value: -i, to: calendar.startOfDay(for: now)) else { continue }
            let totalMin = 360 + Int((sin(Double(i) * 0.8) + 1) * 70) + (i % 3 == 0 ? -25 : 15)
            let wake = calendar.date(bySettingHour: 7, minute: 10, second: 0, of: dayDate) ?? dayDate
            let startAt = calendar.date(byAdding: .minute, value: -totalMin, to: wake) ?? dayDate
            let blocks = stageBlocks(total: totalMin, start: startAt)
            let light = blocks.filter { $0.stage == .light }.reduce(0) { $0 + $1.durationMinutes }
            let deep = blocks.filter { $0.stage == .deep }.reduce(0) { $0 + $1.durationMinutes }
            let awake = blocks.filter { $0.stage == .awake }.reduce(0) { $0 + $1.durationMinutes }
            let summary = SleepSummary(
                session: SleepSession(date: dayDate, startAt: startAt, endAt: wake, totalMinutes: totalMin),
                lightMinutes: light, deepMinutes: deep, awakeMinutes: awake, blocks: blocks
            )
            let score = SleepScore.calculate(summary)
            let session = SleepSession(date: dayDate, startAt: startAt, endAt: wake, totalMinutes: totalMin, score: score.score, syncedAt: wake)
            context.insert(session)
            for block in blocks {
                context.insert(SleepStageBlock(sessionId: session.id, startAt: block.startAt, startMinute: block.startMinute, durationMinutes: block.durationMinutes, stage: block.stage))
            }
        }

        // Several finished workouts across recent days (one today).
        let workouts: [SeedWorkout] = [
            SeedWorkout(offset: 0,   type: "run",   minutes: 38, distance: 6100,  calories: 330, origin: (40.4443, -79.9436)),  // CMU / Pittsburgh
            SeedWorkout(offset: -1,  type: "walk",  minutes: 52, distance: 4200,  calories: 210, origin: (40.4406, -79.9959)),
            SeedWorkout(offset: -3,  type: "cycle", minutes: 64, distance: 18400, calories: 460, origin: (40.4612, -79.9249)),
            SeedWorkout(offset: -6,  type: "gym",   minutes: 45, distance: 0,     calories: 280, origin: nil),
            SeedWorkout(offset: -10, type: "run",   minutes: 41, distance: 7300,  calories: 372, origin: (40.4280, -79.9420))
        ]
        for workout in workouts {
            let dayStart = calendar.date(byAdding: .day, value: workout.offset, to: now) ?? now
            let start = calendar.date(bySettingHour: 18, minute: 5, second: 0, of: dayStart) ?? dayStart
            let end = calendar.date(byAdding: .minute, value: workout.minutes, to: start)
            let useGps = workout.origin != nil
            let session = ActivitySession(
                type: workout.type,
                status: .finished,
                startedAt: start,
                endedAt: end,
                calories: workout.calories,
                distanceMeters: workout.distance > 0 ? workout.distance : nil,
                notes: nil,
                useGps: useGps
            )
            session.avgHeartRate = 132 + Double(abs(workout.offset) % 12)
            session.minHeartRate = 108
            session.maxHeartRate = 158 + Double(abs(workout.offset) % 8)
            session.avgSpO2 = 97
            session.latestSpO2 = 97
            session.perceivedEffort = "moderate"
            context.insert(session)
            context.insert(ActivityEvent(sessionId: session.id, kind: "finished"))
            if let origin = workout.origin {
                seedRoute(context, sessionId: session.id, start: start, durationMinutes: workout.minutes, origin: origin)
            }
        }
        
        let conversation = CoachConversation(title: "Recovery check")
        context.insert(conversation)
        context.insert(CoachMessage(
            conversationId: conversation.id,
            role: "assistant",
            body: "Your sleep is synced and activity is trending above baseline. Keep today's effort steady unless your HR stays elevated."
        ))
        
        context.insert(RawPacketRow(
            direction: .incoming,
            commandId: 0x03,
            hexPayload: "03112233447e240000a51a000064010000000000",
            decodedKind: "activity",
            decodedJSON: #"{"steps":9342}"#,
            confidence: .known
        ))
        context.insert(RawPacketRow(direction: .outgoing, commandId: 0x0c, hexPayload: "0c00000000000000000000000000000000000000", decodedKind: "status_command", confidence: .known))
        context.insert(DerivedUpdateRow(kind: "seed", entityType: "database", entityId: "demo", payloadJSON: #"{"source":"SeedData"}"#))
        
        try? context.save()
    }
    
    @MainActor
    static func clearAll(_ context: ModelContext) {
        deleteAll(Device.self, context)
        deleteAll(ActivityDaily.self, context)
        deleteAll(Measurement.self, context)
        deleteAll(SleepSession.self, context)
        deleteAll(SleepStageBlock.self, context)
        deleteAll(RawPacketRow.self, context)
        deleteAll(DerivedUpdateRow.self, context)
        deleteAll(UserProfile.self, context)
        deleteAll(UserGoal.self, context)
        deleteAll(ActivitySession.self, context)
        deleteAll(ActivitySample.self, context)
        deleteAll(ActivityBucketSample.self, context)
        deleteAll(ActivityGpsPoint.self, context)
        deleteAll(ActivityEvent.self, context)
        deleteAll(CoachConversation.self, context)
        deleteAll(CoachMessage.self, context)
        deleteAll(CoachMemory.self, context)
        deleteAll(CoachToolCall.self, context)
        try? context.save()
    }
    
    /// Builds a plausible hypnogram for a night, scaled to `total` minutes. The
    /// returned blocks carry a placeholder sessionId; callers re-key them to the
    /// real session when persisting.
    private static func stageBlocks(total: Int, start: Date) -> [SleepStageBlock] {
        // Reference pattern (sums to 455m); scaled to the requested total.
        let pattern: [(SleepStage, Int)] = [
            (.light, 58), (.deep, 46), (.light, 92), (.awake, 12),
            (.deep, 71), (.light, 126), (.awake, 10), (.light, 40)
        ]
        let referenceTotal = pattern.reduce(0) { $0 + $1.1 }
        let scale = Double(total) / Double(referenceTotal)
        let placeholder = UUID()
        var cursor = start
        var minute = 0
        var blocks: [SleepStageBlock] = []
        for (index, item) in pattern.enumerated() {
            let duration = index == pattern.count - 1
                ? max(1, total - minute) // absorb rounding into the last block
                : max(1, Int((Double(item.1) * scale).rounded()))
            blocks.append(SleepStageBlock(sessionId: placeholder, startAt: cursor, startMinute: minute, durationMinutes: duration, stage: item.0))
            cursor = Calendar.current.date(byAdding: .minute, value: duration, to: cursor) ?? cursor
            minute += duration
        }
        return blocks
    }
    
    /// Inserts a synthetic GPS loop (~60 points) around `origin` so the route map has data to draw
    /// in the Simulator. The path is a gently wobbling closed loop, not a real recording.
    private static func seedRoute(_ context: ModelContext, sessionId: UUID, start: Date, durationMinutes: Int, origin: (Double, Double)) {
        let count = 60
        let radius = 0.006 // ~600 m
        for i in 0..<count {
            let t = Double(i) / Double(count) * 2 * Double.pi
            let wobble = 0.0012 * sin(t * 5)
            let lat = origin.0 + (radius + wobble) * sin(t)
            let lon = origin.1 + (radius + wobble) * cos(t) * 1.3
            let ts = start.addingTimeInterval(Double(durationMinutes) * 60 * Double(i) / Double(count))
            context.insert(ActivityGpsPoint(sessionId: sessionId, latitude: lat, longitude: lon, horizontalAccuracy: 5, timestamp: ts))
        }
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) {
        let rows = (try? context.fetch(FetchDescriptor<T>())) ?? []
        for row in rows {
            context.delete(row)
        }
    }
}
