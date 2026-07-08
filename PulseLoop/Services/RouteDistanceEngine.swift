import Foundation

/// Per-activity GPS tuning: how the recorder filters fixes and how the distance engine
/// judges segments. One table keyed by canonical `ActivityMeta` type so the live recorder,
/// distance totals, and splits all agree on what counts as movement.
struct ActivityTrackingProfile: Sendable, Equatable {
    /// Fastest plausible sustained speed; segments implying more are GPS jumps and are dropped.
    let maxSpeedMps: Double
    /// Minimum displacement for a fix to count as movement (stationary-jitter gate).
    let minMoveMeters: Double
    /// `CLLocationManager.distanceFilter` — how far to move before the OS reports a fix.
    let distanceFilterMeters: Double
    /// Minimum seconds between accepted stationary-ish fixes (keeps slow walks sampled).
    let minIntervalSeconds: Double
    /// Segments spanning more time than this (pause teleports, long signal loss) contribute
    /// neither distance nor moving time — bridging them with a straight line is what made
    /// mileage wrong.
    let gapSeconds: Double

    static let `default` = ActivityTrackingProfile(
        maxSpeedMps: 8, minMoveMeters: 4, distanceFilterMeters: 5, minIntervalSeconds: 6, gapSeconds: 30
    )

    private static let table: [String: ActivityTrackingProfile] = [
        "walk":  ActivityTrackingProfile(maxSpeedMps: 5, minMoveMeters: 3, distanceFilterMeters: 4, minIntervalSeconds: 6, gapSeconds: 30),
        "run":   ActivityTrackingProfile(maxSpeedMps: 8, minMoveMeters: 4, distanceFilterMeters: 5, minIntervalSeconds: 5, gapSeconds: 30),
        "hike":  ActivityTrackingProfile(maxSpeedMps: 6, minMoveMeters: 3, distanceFilterMeters: 4, minIntervalSeconds: 6, gapSeconds: 45),
        "cycle": ActivityTrackingProfile(maxSpeedMps: 25, minMoveMeters: 8, distanceFilterMeters: 8, minIntervalSeconds: 8, gapSeconds: 30),
        "sport": ActivityTrackingProfile(maxSpeedMps: 9, minMoveMeters: 3, distanceFilterMeters: 4, minIntervalSeconds: 4, gapSeconds: 30)
    ]

    static func profile(for activityType: String) -> ActivityTrackingProfile {
        table[ActivityMeta.meta(activityType).type] ?? .default
    }
}

/// Distance and splits for a recorded route. All callers (live tiles, Live Activity pushes,
/// finish summary, split strips) go through here so a workout never shows two different
/// mileages. Points are sorted and gap/speed-filtered identically everywhere.
enum RouteDistanceEngine {

    /// Completed splits plus the partial split in progress, in *moving* time (gap segments
    /// contribute neither distance nor seconds, so a mid-run pause doesn't wreck the pace).
    struct Splits {
        var completedSeconds: [Double] = []
        var partialMeters: Double = 0
        var partialSeconds: Double = 0
    }

    static func distanceMeters(_ points: [ActivityGpsPoint], profile: ActivityTrackingProfile) -> Double {
        let sorted = accepted(points)
        guard sorted.count >= 2 else { return 0 }
        return zip(sorted, sorted.dropFirst()).reduce(0) { total, pair in
            total + (segmentMeters(pair.0, pair.1, profile: profile) ?? 0)
        }
    }

    static func splits(_ points: [ActivityGpsPoint], splitMeters: Double, profile: ActivityTrackingProfile) -> Splits {
        var result = Splits()
        guard splitMeters > 0 else { return result }
        let sorted = accepted(points)
        guard sorted.count >= 2 else { return result }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            guard let meters = segmentMeters(a, b, profile: profile) else { continue }
            result.partialMeters += meters
            result.partialSeconds += b.timestamp.timeIntervalSince(a.timestamp)
            while result.partialMeters >= splitMeters {
                // The crossing segment's full time credits the completed split (matches the
                // previous mark-walking behaviour); the leftover distance rolls forward.
                result.completedSeconds.append(result.partialSeconds)
                result.partialMeters -= splitMeters
                result.partialSeconds = 0
            }
        }
        return result
    }

    /// Seconds per completed split — drop-in shape for the summary splits table.
    static func splitSeconds(_ points: [ActivityGpsPoint], splitMeters: Double, profile: ActivityTrackingProfile) -> [Double] {
        splits(points, splitMeters: splitMeters, profile: profile).completedSeconds
    }

    /// Incremental counterpart of `distanceMeters` + `splits` for the live screen: O(1) per GPS fix
    /// instead of re-walking the whole route every render. Applies the exact same gap/speed segment
    /// rules, so live totals always match the batch recompute at finish. Points must arrive in
    /// timestamp order (CoreLocation guarantees this); a stale out-of-order fix is skipped.
    struct Accumulator {
        let profile: ActivityTrackingProfile
        let splitMeters: Double
        private(set) var distanceMeters: Double = 0
        private(set) var splits = Splits()
        private var last: (lat: Double, lon: Double, ts: Date)?

        init(profile: ActivityTrackingProfile, splitMeters: Double) {
            self.profile = profile
            self.splitMeters = splitMeters
        }

        mutating func add(latitude: Double, longitude: Double, timestamp: Date) {
            guard let previous = last else {
                last = (latitude, longitude, timestamp)
                return
            }
            guard timestamp >= previous.ts else { return }   // out-of-order fix — skip
            if let meters = RouteDistanceEngine.segmentMeters(
                lat1: previous.lat, lon1: previous.lon, t1: previous.ts,
                lat2: latitude, lon2: longitude, t2: timestamp,
                profile: profile
            ) {
                distanceMeters += meters
                if splitMeters > 0 {
                    splits.partialMeters += meters
                    splits.partialSeconds += timestamp.timeIntervalSince(previous.ts)
                    while splits.partialMeters >= splitMeters {
                        // Same crossing rule as the batch `splits`: the crossing segment's full time
                        // credits the completed split; leftover distance rolls forward.
                        splits.completedSeconds.append(splits.partialSeconds)
                        splits.partialMeters -= splitMeters
                        splits.partialSeconds = 0
                    }
                }
            }
            last = (latitude, longitude, timestamp)
        }

        /// Replay a batch of already-persisted points (recovery seeding). Accepted points only.
        mutating func seed(_ points: [ActivityGpsPoint]) {
            for p in points.filter(\.accepted).sorted(by: { $0.timestamp < $1.timestamp }) {
                add(latitude: p.latitude, longitude: p.longitude, timestamp: p.timestamp)
            }
        }
    }

    static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dPhi = (lat2 - lat1) * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let h = sin(dPhi / 2) * sin(dPhi / 2) + cos(p1) * cos(p2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    // MARK: - Internals

    private static func accepted(_ points: [ActivityGpsPoint]) -> [ActivityGpsPoint] {
        points.filter(\.accepted).sorted { $0.timestamp < $1.timestamp }
    }

    /// Segment length, or nil when the segment must not count: spans longer than the gap
    /// threshold (pause/signal loss — dt is huge so implied speed looks plausible even for a
    /// cross-town teleport) or implying an impossible speed (GPS jump).
    private static func segmentMeters(_ a: ActivityGpsPoint, _ b: ActivityGpsPoint, profile: ActivityTrackingProfile) -> Double? {
        segmentMeters(
            lat1: a.latitude, lon1: a.longitude, t1: a.timestamp,
            lat2: b.latitude, lon2: b.longitude, t2: b.timestamp,
            profile: profile
        )
    }

    /// Raw-value form shared with `Accumulator` so live accumulation and batch recompute can never
    /// disagree on what counts as a valid segment.
    fileprivate static func segmentMeters(
        lat1: Double, lon1: Double, t1: Date,
        lat2: Double, lon2: Double, t2: Date,
        profile: ActivityTrackingProfile
    ) -> Double? {
        let dt = t2.timeIntervalSince(t1)
        guard dt >= 0, dt <= profile.gapSeconds else { return nil }
        let meters = haversineMeters(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
        if dt > 0, meters / dt > profile.maxSpeedMps { return nil }
        return meters
    }
}
