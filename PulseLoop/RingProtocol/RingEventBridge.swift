import Foundation

/// Pure mapping from a decoded ring packet to the typed `PulseEvent`s that should be
/// published on the bus. The raw packet itself is published separately by `RingBLEClient`
/// (always, even for `.unknown`), so this bridge only produces the *typed* fan-out used by
/// the persistence subscriber and the sync coordinator.
///
/// Mirrors the typed fan-out in the Python reference
/// (`backend/app/ble/bleak_ring_client.py::_on_notify`), including its sanity gates:
/// HR zero/garbage frames are dropped, SpO2 is already range-gated in the decoder, and
/// sleep timelines with implausible timestamps are rejected so a corrupt frame can't
/// create a bogus "recent" sleep session.
enum RingEventBridge {
    /// Plausible instantaneous heart rate, in bpm. Drops 0-bpm warm-up frames and noise.
    static let hrRange: ClosedRange<Int> = 30...220
    /// Plausible stress score (Colmi reports 1–100; 0 = no sample).
    static let stressRange: ClosedRange<Int> = 1...100
    /// Plausible HRV, in milliseconds.
    static let hrvRange: ClosedRange<Int> = 1...300
    /// Plausible skin/body temperature, in °C.
    static let temperatureRange: ClosedRange<Double> = 30...45
    /// Plausible blood-pressure bounds (mmHg) — drops misframed 0x24 bytes.
    static let systolicRange: ClosedRange<Int> = 60...250
    static let diastolicRange: ClosedRange<Int> = 30...160
    /// Plausible fatigue score (0–100 scale; 0 = no sample).
    static let fatigueRange: ClosedRange<Int> = 1...100
    /// Plausible blood sugar, in mg/dL.
    static let bloodSugarRange: ClosedRange<Double> = 40...600
    /// Plausible SpO₂, in percent. The floor is the *display* floor of consumer oximetry hardware, not
    /// the 70 % where its accuracy spec stops: this gate exists to drop the ring's "no sample" fillers
    /// and misframed bytes, and it must not second-guess a genuinely hypoxemic night. A QRing-Colmi's
    /// all-day SpO₂ log reached persistence ungated before this gate existed, so anything a real sensor
    /// can report has to keep reaching it.
    static let spo2Range: ClosedRange<Int> = 35...100
    /// Plausible respiratory rate, in breaths per minute (newborn-to-panic bracket).
    static let respiratoryRateRange: ClosedRange<Int> = 4...60
    /// Plausible VO₂max, in mL/kg/min (sedentary floor to elite-athlete ceiling).
    static let vo2maxRange: ClosedRange<Int> = 10...90
    /// Sanity ceilings for one intraday activity bucket (~15 min): well above any human cadence so
    /// only clearly-misframed packets are rejected.
    static let maxBucketSteps = 5000
    static let maxBucketDistance: Double = 6000   // metres
    /// Sanity ceilings for a full day of cumulative activity: a live `.activityUpdate` beyond these is a
    /// misframed packet (e.g. a u24/u32 field read at the wrong offset), which — since it ratchets the
    /// daily row via `max` — would otherwise show as garbage until the next history-bucket recompute.
    static let maxDailySteps = 100_000
    static let maxDailyDistanceMeters: Double = 120_000   // metres
    static let maxDailyCalories: Double = 10_000          // kcal

    static func events(for decoded: RingDecodedEvent, now: Date = Date()) -> [PulseEvent] {
        switch decoded {
        case let .activityUpdate(timestamp, steps, distanceMeters, calories):
            // A live cumulative update ratchets the daily row via `max`, so a single misframed packet
            // permanently inflates the visible total until a history recompute. Drop (never clamp) any
            // update outside the daily ceilings or with an implausible ring-supplied timestamp.
            return isPlausibleDailyActivity(steps: steps, distanceMeters: distanceMeters, calories: calories, timestamp: timestamp, now: now)
                ? [.activityUpdate(timestamp: timestamp, steps: steps, distanceMeters: distanceMeters, calories: calories)]
                : []

        case let .activityBucket(timestamp, steps, distanceMeters):
            // Guard against a misframed history packet painting a wild total: a single 15-min bucket
            // can't realistically exceed these. Drop the bucket if it does.
            //
            // The timestamp needs the same window as every other history path: a bucket the ring logged
            // against an unset RTC decodes to 2000-01-01, and — unlike a live update, which only ratchets
            // today's row — a bucket *creates* an `ActivityDaily` at that date and re-upserts it on every
            // sync, so it never ages out. (A no-op for Colmi, whose decoder pre-gates the same window.)
            guard (0...maxBucketSteps).contains(steps), (0...maxBucketDistance).contains(distanceMeters),
                  isPlausibleActivityTimestamp(timestamp, now: now) else { return [] }
            return [.activityBucket(timestamp: timestamp, steps: steps, distanceMeters: distanceMeters)]

        case let .heartRateSample(bpm, timestamp):
            guard hrRange.contains(bpm) else { return [] }
            return [.heartRateSample(bpm: bpm, timestamp: timestamp)]

        case let .heartRateComplete(timestamp):
            return [.heartRateComplete(timestamp: timestamp)]

        case let .spo2Progress(percent, timestamp):
            return [.spo2Progress(percent: percent, timestamp: timestamp)]

        case let .spo2Result(value, timestamp):
            return [.spo2Result(value: value, timestamp: timestamp)]

        case let .spo2Complete(timestamp):
            return [.spo2Complete(timestamp: timestamp)]

        case let .historyMeasurement(kind, value, timestamp):
            return historyMeasurementEvents(kind: kind, value: value, timestamp: timestamp, now: now)

        case let .stressSample(value, timestamp):
            guard stressRange.contains(value) else { return [] }
            return [.stressSample(value: value, timestamp: timestamp)]

        case let .hrvSample(value, timestamp):
            guard hrvRange.contains(value) else { return [] }
            return [.hrvSample(value: value, timestamp: timestamp)]

        case let .temperatureSample(celsius, timestamp):
            guard temperatureRange.contains(celsius) else { return [] }
            return [.temperatureSample(celsius: celsius, timestamp: timestamp)]

        case let .historySyncProgress(stage):
            return [.syncProgress(stage: stage)]

        case .historySyncFinished:
            return [.syncProgress(stage: "done")]

        case let .sleepTimeline(timestamp, stages):
            guard isPlausibleSleepStart(timestamp, now: now), !stages.isEmpty else { return [] }
            return [.sleepTimeline(timestamp: timestamp, stages: stages)]

        case let .battery(percent):
            guard (0...100).contains(percent) else { return [] }
            return [.batteryLevel(percent: percent)]

        case let .status(address):
            // The status reply carries the ring's embedded address; surface it (and refresh
            // last-sync) by re-asserting the connected state with the address attached.
            return [.deviceStateChanged(state: .connected, address: address)]

        default:
            // Everything else: events with no typed fan-out here (timeSyncAck/commandAck/unknown, and
            // bind — advanced by the sync engine's `handle`), plus the jring/56ff 0x24 extras + firmware
            // which are split into `extraMetricEvents` to keep this switch's complexity in check.
            //
            // `.measurementRejected` belongs to that first group on purpose: it is the ring declining a
            // command, not a reading, so there is nothing to persist. `RingSyncCoordinator` reads it off
            // the raw-packet feed instead — the one consumer that has any business acting on it.
            return extraMetricEvents(for: decoded)
        }
    }

    /// Fan-out for the jring/56ff 0x24 extra metrics (BP, fatigue, blood sugar) and firmware, with the
    /// same plausibility gating as the main vitals. Split from `events` so neither switch grows past
    /// the project's cyclomatic-complexity limit.
    /// Gate a ring-supplied history sample before it reaches persistence.
    ///
    /// A ring's on-device log can still hold records stamped under a *previous* clock — e.g. a jring
    /// that logged against a UTC RTC before the app started setting it to local time. Those decode
    /// hours into the future. Drop anything outside the history horizon rather than persisting a
    /// sample that poisons "today", peak HR and the 24h trends.
    private static func historyMeasurementEvents(
        kind: MeasurementKind,
        value: Double,
        timestamp: Date,
        now: Date
    ) -> [PulseEvent] {
        guard isPlausible(kind: kind, value: value) else { return [] }
        guard isWithinHistoryWindow(timestamp, now: now) else { return [] }
        return [.historyMeasurement(kind: kind, value: value, timestamp: timestamp)]
    }

    /// Range gate for a history sample, by kind — the single place these bounds live (the record
    /// decoders only drop the ring's "no sample" fillers, never a range).
    ///
    /// This matters more for history than for live data: a ring replays its *entire* log on every sync
    /// and history rows upsert on (kind, timestamp), so one misdecoded record doesn't just flicker —
    /// it re-persists on every future sync until the ring forgets it.
    private static func isPlausible(kind: MeasurementKind, value: Double) -> Bool {
        switch kind {
        case .heartRate: return hrRange.contains(Int(value))
        case .spo2: return spo2Range.contains(Int(value))
        case .stress: return stressRange.contains(Int(value))
        case .hrv: return hrvRange.contains(Int(value))
        case .temperature: return temperatureRange.contains(value)
        case .bloodPressureSystolic: return systolicRange.contains(Int(value))
        case .bloodPressureDiastolic: return diastolicRange.contains(Int(value))
        case .fatigue: return fatigueRange.contains(Int(value))
        case .bloodSugar: return bloodSugarRange.contains(value)
        case .respiratoryRate: return respiratoryRateRange.contains(Int(value))
        case .vo2max: return vo2maxRange.contains(Int(value))
        }
    }

    private static func extraMetricEvents(for decoded: RingDecodedEvent) -> [PulseEvent] {
        switch decoded {
        case let .bloodPressureSample(systolic, diastolic, timestamp):
            guard systolicRange.contains(systolic), diastolicRange.contains(diastolic) else { return [] }
            return [.bloodPressureSample(systolic: systolic, diastolic: diastolic, timestamp: timestamp)]

        case let .fatigueSample(value, timestamp):
            guard fatigueRange.contains(value) else { return [] }
            return [.fatigueSample(value: value, timestamp: timestamp)]

        case let .bloodSugarSample(mgdl, timestamp):
            guard bloodSugarRange.contains(mgdl) else { return [] }
            return [.bloodSugarSample(mgdl: mgdl, timestamp: timestamp)]

        case let .firmware(version):
            return [.firmwareVersion(version)]

        default:
            return []
        }
    }

    /// A sleep session start is plausible if it falls within roughly the last week and is not in the
    /// future. The Colmi sleep big-data payload can carry several recent nights (day-indexed), so the
    /// window matches the ~8-day history horizon; a value outside it indicates a misdecoded frame.
    static func isPlausibleSleepStart(_ start: Date, now: Date = Date()) -> Bool {
        isWithinHistoryWindow(start, now: now)
    }

    /// A live activity update's ring-supplied timestamp is plausible within the same ~8-day history
    /// window as sleep. A garbage future timestamp is especially dangerous here because `buildTodaySummary`
    /// treats the max-dated row as "today", so a future date would permanently poison the visible day.
    static func isPlausibleActivityTimestamp(_ timestamp: Date, now: Date = Date()) -> Bool {
        isWithinHistoryWindow(timestamp, now: now)
    }

    /// True when a live cumulative update is within the daily ceilings and carries a plausible timestamp.
    private static func isPlausibleDailyActivity(steps: Int, distanceMeters: Double, calories: Double, timestamp: Date, now: Date) -> Bool {
        (0...maxDailySteps).contains(steps)
            && (0...maxDailyDistanceMeters).contains(distanceMeters)
            && (0...maxDailyCalories).contains(calories)
            && isPlausibleActivityTimestamp(timestamp, now: now)
    }

    /// Shared plausibility window: within the last ~8 days (the history horizon) and no more than an hour
    /// into the future. A timestamp outside it indicates a misdecoded frame.
    private static func isWithinHistoryWindow(_ date: Date, now: Date) -> Bool {
        let lower = now.addingTimeInterval(-8 * 24 * 3600)
        let upper = now.addingTimeInterval(3600)
        return date >= lower && date <= upper
    }
}
