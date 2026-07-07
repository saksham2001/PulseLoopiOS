import Foundation
import CoreLocation

/// Where the live HR tile's value came from — the realtime stream, or the ring's own 5-min log
/// (backfill shown as a fallback when the stream has nothing fresh).
enum LiveHRSource: Sendable {
    case live
    case ringLog
}

/// Rolling stats for the workout currently recording, maintained incrementally from `PulseEventBus`
/// events so the live screen and Live Activity read O(1) values instead of re-fetching and
/// re-walking the whole route every second. Owned by `LiveWorkoutManager`: created at start,
/// seeded from the store on recovery, torn down at finish/cancel.
@MainActor
@Observable
final class LiveWorkoutStats {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    let sessionId: UUID
    let startedAt: Date
    let useGps: Bool

    private(set) var distanceMeters: Double = 0
    private(set) var splits = RouteDistanceEngine.Splits()
    /// Accepted route fixes, append-only — feeds the map without per-render sort/rebuild.
    private(set) var coordinates: [CLLocationCoordinate2D] = []
    private(set) var latestAccuracy: Double?
    private(set) var acceptedPointCount = 0

    private(set) var lastHR: (value: Int, at: Date, source: LiveHRSource)?
    private(set) var lastSpO2: (value: Int, at: Date)?
    /// Set while the workout is paused so the on-screen clock can freeze at the pause instant.
    private(set) var pausedAt: Date?

    /// A live HR older than this counts as stale, letting a newer ring-log sample take the tile.
    private let liveHRStaleSeconds: TimeInterval = 120

    private var accumulator: RouteDistanceEngine.Accumulator

    init(sessionId: UUID, startedAt: Date, activityType: String, useGps: Bool, splitMeters: Double) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.useGps = useGps
        self.accumulator = RouteDistanceEngine.Accumulator(
            profile: .profile(for: activityType),
            splitMeters: splitMeters
        )
    }

    // MARK: - Feeding (one call per event — all O(1))

    func addFix(latitude: Double, longitude: Double, horizontalAccuracy: Double?, timestamp: Date) {
        accumulator.add(latitude: latitude, longitude: longitude, timestamp: timestamp)
        distanceMeters = accumulator.distanceMeters
        splits = accumulator.splits
        coordinates.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        if let horizontalAccuracy { latestAccuracy = horizontalAccuracy }
        acceptedPointCount += 1
    }

    func recordHR(_ bpm: Int, at timestamp: Date, source: LiveHRSource) {
        switch source {
        case .live:
            lastHR = (bpm, timestamp, .live)
        case .ringLog:
            // Ring-log samples only fill in when the stream has nothing fresh — a working live
            // stream must never be overwritten by the coarse 5-min log.
            if let current = lastHR, current.source == .live,
               Date().timeIntervalSince(current.at) < liveHRStaleSeconds {
                return
            }
            if let current = lastHR, timestamp <= current.at { return }
            lastHR = (bpm, timestamp, .ringLog)
        }
    }

    func recordSpO2(_ value: Int, at timestamp: Date) {
        if let current = lastSpO2, timestamp < current.at { return }
        lastSpO2 = (value, timestamp)
    }

    func setPaused(_ date: Date?) {
        pausedAt = date
    }

    // MARK: - Recovery seeding (single scoped fetch, replayed through the accumulator)

    /// Rebuild the incremental state from persisted rows after an app relaunch mid-workout.
    func seed(points: [ActivityGpsPoint], lastHRSample: ActivitySample?, lastSpO2Sample: ActivitySample?) {
        let accepted = points.filter(\.accepted).sorted { $0.timestamp < $1.timestamp }
        for p in accepted {
            accumulator.add(latitude: p.latitude, longitude: p.longitude, timestamp: p.timestamp)
        }
        distanceMeters = accumulator.distanceMeters
        splits = accumulator.splits
        coordinates = accepted.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        latestAccuracy = accepted.last?.horizontalAccuracy
        acceptedPointCount = accepted.count
        if let hr = lastHRSample, hr.value > 0 {
            let source: LiveHRSource = hr.source == MeasurementSource.live.rawValue ? .live : .ringLog
            lastHR = (Int(hr.value), hr.timestamp, source)
        }
        if let spo2 = lastSpO2Sample, spo2.value > 0 {
            lastSpO2 = (Int(spo2.value), spo2.timestamp)
        }
    }

    /// Seed the SpO₂ tile for ring-log devices (Colmi): the newest all-day log value, which may
    /// predate the workout — matches the previous `MetricsRepository.latestMeasurement` behaviour
    /// without the per-render fetch.
    func seedSpO2(value: Int, at timestamp: Date) {
        recordSpO2(value, at: timestamp)
    }
}
