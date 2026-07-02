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
        // Advertise the full sensor suite so the demo surfaces every vital (stress/HRV/BP/fatigue/
        // glucose/temperature are capability-gated and stay hidden otherwise).
        context.insert(Device(
            advertisedName: "SMART_RING",
            bleAddressHint: "41:42:2e:c7:5b:6a",
            batteryPercent: 82,
            state: .connected,
            capabilities: [
                .heartRate, .spo2, .steps, .sleep, .battery, .remSleep,
                .stress, .hrv, .temperature, .bloodPressure, .bloodSugar, .fatigue
            ]
        ))

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

        seedVitals(context, now: now, calendar: calendar)

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
            seedWorkoutSamples(context, session: session, start: start, minutes: workout.minutes)
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

    /// Seeds every vital's measurement history for the demo. Each series is deterministic (no RNG) and
    /// deliberately walks through its threshold zones — including over-threshold extremes — so the
    /// zone-colored charts show their full color range. HR/SpO₂ are dense over the last 24h (the
    /// dashboard's window); the slow vitals span ~30 days so the detail screen's baseline/trend fills.
    @MainActor
    private static func seedVitals(_ context: ModelContext, now: Date, calendar: Calendar) {
        func add(_ kind: MeasurementKind, _ value: Double, _ ts: Date) {
            context.insert(Measurement(kind: kind, value: value, unit: kind.unit, timestamp: ts, source: .mock))
        }

        // Heart rate — dense 24h. Mostly 58–95, with a couple of high spikes into the red (≥150).
        for hour in stride(from: -24, through: 0, by: 1) {
            guard let ts = calendar.date(byAdding: .hour, value: hour, to: now) else { continue }
            var hr = 62 + (sin(Double(hour) * 0.7) + 1) * 15 + Double(abs(hour % 5))
            if hour == -8 { hr = 152 }            // afternoon spike → High (red)
            if hour == -2 { hr = 138 }            // recent effort → Elevated
            add(.heartRate, hr.rounded(), ts)
        }

        // SpO₂ — 24h, every 2h. Mostly 96–99 with a dip to Low (91, orange) and one Very low (88, red).
        for hour in stride(from: -24, through: 0, by: 2) {
            guard let ts = calendar.date(byAdding: .hour, value: hour, to: now) else { continue }
            var spo2 = 97.0 + Double(abs(hour) % 3 == 0 ? 2 : 0)
            if hour == -10 { spo2 = 91 }          // Low
            if hour == -16 { spo2 = 88 }          // Very low
            add(.spo2, Swift.min(100, spo2), ts)
        }

        // Slow vitals over ~30 days (a few readings/day where useful). Each walks its zones.
        for day in stride(from: -29, through: 0, by: 1) {
            guard let dayStart = calendar.date(byAdding: .day, value: day, to: now) else { continue }
            let phase = Double(day)

            // Stress — 3 readings/day. Calm→High; a hard day pushes into the red (≥76).
            for (h, base) in [(9, 22.0), (14, 48.0), (19, 66.0)] {
                let ts = calendar.date(bySettingHour: h, minute: 0, second: 0, of: dayStart) ?? dayStart
                var v = base + sin(phase * 0.5) * 12
                if day == -4 && h == 14 { v = 84 }          // High (red)
                add(.stress, Swift.max(3, Swift.min(99, v.rounded())), ts)
            }

            // Fatigue — 1 reading/day (evening). Fresh→High fatigue (≥75 red on a couple of days).
            let fatTs = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: dayStart) ?? dayStart
            var fatigue = 40 + sin(phase * 0.4) * 22
            if day == -3 || day == -12 { fatigue = 80 }     // High fatigue (red)
            add(.fatigue, Swift.max(5, Swift.min(98, fatigue.rounded())), fatTs)

            // HRV — 1 reading/day (overnight). ~55±18 so the 30-day baseline (mean±sd) forms and some
            // days fall below/above it (amber/green bands).
            let hrvTs = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: dayStart) ?? dayStart
            var hrv = 55 + sin(phase * 0.6) * 16 + Double(abs(day % 3)) * 3
            if day == -6 { hrv = 26 }                       // sharp dip → below baseline
            if day == -18 { hrv = 92 }                      // spike → above baseline
            add(.hrv, hrv.rounded(), hrvTs)

            // Blood pressure — 1 pair/day (morning). Normal→Stage 2; a couple of high days show red.
            let bpTs = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: dayStart) ?? dayStart
            var sys = 116 + sin(phase * 0.45) * 10
            var dia = 76 + sin(phase * 0.45) * 6
            if day == -2 || day == -15 { sys = 146; dia = 96 }   // Stage 2 (red)
            if day == -9 { sys = 132; dia = 86 }                 // Stage 1
            add(.bloodPressureSystolic, sys.rounded(), bpTs)
            add(.bloodPressureDiastolic, dia.rounded(), bpTs)

            // Glucose — 1 fasting reading/day (morning). Normal→High (≥126 red on a couple of days).
            let gluTs = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: dayStart) ?? dayStart
            var glucose = 92 + sin(phase * 0.5) * 12
            if day == -5 { glucose = 138 }                  // High (red)
            if day == -20 { glucose = 112 }                 // Elevated (amber)
            add(.bloodSugar, glucose.rounded(), gluTs)

            // Temperature — skin temp, 1 reading/day. Typical 33–35.5 with a warm spike (≥36 amber) and
            // a cool dip (<31 blue).
            let tempTs = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: dayStart) ?? dayStart
            var temp = 34.0 + sin(phase * 0.5) * 1.2
            if day == -7 { temp = 37.1 }                    // Warm
            if day == -22 { temp = 30.4 }                   // Cool
            add(.temperature, (temp * 10).rounded() / 10, tempTs)
        }
    }

    /// Per-workout HR (every minute) and SpO₂ (every 5 min) samples so the workout-detail graphs render.
    /// HR follows a warm-up → steady-effort (with a mid-workout push into the high zone) → cool-down
    /// curve so the zone-colored line shows multiple colors.
    @MainActor
    private static func seedWorkoutSamples(_ context: ModelContext, session: ActivitySession, start: Date, minutes: Int) {
        for minute in 0...minutes {
            let ts = start.addingTimeInterval(Double(minute) * 60)
            let progress = Double(minute) / Double(max(1, minutes))
            // Warm-up ramp, steady middle, brief peak ~70% through, then cool-down.
            var hr = 118 + sin(progress * .pi) * 34            // ~118 → ~152 → ~118 arc
            if progress > 0.62 && progress < 0.74 { hr = 168 } // interval push → High zone (red)
            if progress < 0.08 { hr = 96 + progress * 250 }    // early warm-up from ~96
            context.insert(ActivitySample(sessionId: session.id, kind: MeasurementKind.heartRate.rawValue, value: hr.rounded(), unit: "bpm", timestamp: ts))
            if minute % 5 == 0 {
                let spo2 = 97.0 - (progress > 0.6 ? 2 : 0)     // slight dip under peak effort
                context.insert(ActivitySample(sessionId: session.id, kind: MeasurementKind.spo2.rawValue, value: spo2, unit: "%", timestamp: ts))
            }
        }
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
        // Reference pattern (sums to 455m); scaled to the requested total. REM cycles get longer
        // later in the night, matching real sleep architecture.
        let pattern: [(SleepStage, Int)] = [
            (.light, 58), (.deep, 46), (.light, 70), (.rem, 22), (.awake, 12),
            (.deep, 71), (.light, 88), (.rem, 38), (.awake, 10), (.light, 40)
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
