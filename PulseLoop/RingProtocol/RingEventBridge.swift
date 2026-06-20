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
    /// Sanity ceilings for one intraday activity bucket (~15 min): well above any human cadence so
    /// only clearly-misframed packets are rejected.
    static let maxBucketSteps = 5000
    static let maxBucketDistance: Double = 6000   // metres

    static func events(for decoded: RingDecodedEvent, now: Date = Date()) -> [PulseEvent] {
        switch decoded {
        case let .activityUpdate(timestamp, steps, distanceMeters, calories):
            return [.activityUpdate(timestamp: timestamp, steps: steps, distanceMeters: distanceMeters, calories: calories)]

        case let .activityBucket(timestamp, steps, distanceMeters):
            // Guard against a misframed history packet painting a wild total: a single 15-min bucket
            // can't realistically exceed these. Drop the bucket if it does.
            guard (0...maxBucketSteps).contains(steps), (0...maxBucketDistance).contains(distanceMeters) else { return [] }
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
            if kind == .heartRate, !hrRange.contains(Int(value)) { return [] }
            return [.historyMeasurement(kind: kind, value: value, timestamp: timestamp)]

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

        case .timeSyncAck, .commandAck, .unknown:
            // No typed measurement — the raw packet was already logged for the debug feed.
            return []
        }
    }

    /// A sleep session start is plausible if it falls within roughly the last week and is not in the
    /// future. The Colmi sleep big-data payload can carry several recent nights (day-indexed), so the
    /// window matches the ~8-day history horizon; a value outside it indicates a misdecoded frame.
    static func isPlausibleSleepStart(_ start: Date, now: Date = Date()) -> Bool {
        let lower = now.addingTimeInterval(-8 * 24 * 3600)
        let upper = now.addingTimeInterval(3600)
        return start >= lower && start <= upper
    }
}
