import Foundation
import Observation
@preconcurrency import CoreLocation

/// Captures a GPS route during an outdoor workout and publishes accepted fixes as
/// `PulseEvent.gpsPoint`, which `EventPersistenceSubscriber` persists as `ActivityGpsPoint` rows.
/// Distance is derived later from those rows by `ActivityService.gpsDistance`.
///
/// CoreLocation only delivers real fixes on a physical device; in the Simulator it stays idle
/// (or uses a simulated location), which is fine — the rest of the workout flow still works.
///
/// Concurrency mirrors `RingBLEClient`: the manager is created on the main actor so its delegate
/// callbacks arrive on the main run loop; the delegate methods are `nonisolated` and re-enter the
/// main actor via `MainActor.assumeIsolated`.
@MainActor
@Observable
final class GpsRouteRecorder: NSObject, CLLocationManagerDelegate {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private(set) var authorization: CLAuthorizationStatus
    private(set) var isTracking = false
    private(set) var pointCount = 0

    /// Surfaced to the view layer so SwiftUI never needs to import CoreLocation.
    var isPermissionDenied: Bool { authorization == .denied || authorization == .restricted }
    /// Without Always, iOS silently stops delivering fixes when the screen locks — the live screen
    /// warns so the user knows the route will have gaps.
    var hasAlwaysAuthorization: Bool { authorization == .authorizedAlways }

    private let manager = CLLocationManager()
    private var sessionId: UUID?
    private var lastAccepted: CLLocation?
    private var profile: ActivityTrackingProfile = .default

    // Filtering thresholds shared by all activity types; per-type speed/movement thresholds
    // come from `ActivityTrackingProfile`.
    private let maxHorizontalAccuracy = 30.0   // metres; reject poorer/invalid fixes
    private let maxFixAge = 5.0                 // seconds; reject stale cached fixes
    private let maxCourseDelta = 25.0           // degrees; turn detection keeps cornering detail

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func start(sessionId: UUID, activityType: String = "run") {
        self.sessionId = sessionId
        self.profile = .profile(for: activityType)
        lastAccepted = nil
        pointCount = 0
        // Provisional When-In-Use still records in the foreground; also request Always so the
        // route keeps recording when the screen locks / the app backgrounds.
        manager.requestWhenInUseAuthorization()
        manager.requestAlwaysAuthorization()
        manager.desiredAccuracy = WorkoutPrefsStore.shared.settings.gpsAccuracy.clValue
        manager.distanceFilter = profile.distanceFilterMeters
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .fitness
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            // Blue indicator while recording in background — the honest, Strava-like signal that
            // the route is still being tracked.
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        isTracking = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        lastAccepted = nil
        sessionId = nil
        isTracking = false
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let sessionId else { return }
            for location in locations {
                let reason = rejectionReason(for: location)
                let accepted = reason == nil
                let lat = location.coordinate.latitude
                let lon = location.coordinate.longitude
                let altitude = location.altitude
                let horizontalAccuracy = location.horizontalAccuracy
                let speed = location.speed >= 0 ? location.speed : nil
                let course = location.course >= 0 ? location.course : nil
                let ts = location.timestamp
                if accepted {
                    lastAccepted = location
                    pointCount += 1
                }
                Task {
                    await PulseEventBus.shared.publish(.gpsPoint(
                        sessionId: sessionId,
                        latitude: lat,
                        longitude: lon,
                        altitude: altitude,
                        horizontalAccuracy: horizontalAccuracy,
                        speed: speed,
                        course: course,
                        accepted: accepted,
                        rejectionReason: reason,
                        timestamp: ts
                    ))
                }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            // The "Always" grant typically arrives *after* start() (iOS shows the When-In-Use
            // prompt first, then escalates). Enable background updates the moment we have Always
            // while a workout is tracking — otherwise location pauses on background, the app
            // suspends, and sensor polling freezes.
            if status == .authorizedAlways, isTracking {
                manager.allowsBackgroundLocationUpdates = true
                manager.showsBackgroundLocationIndicator = true
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient location errors are non-fatal; the next fix may succeed. Nothing to persist.
    }

    /// Returns a rejection reason for a fix, or nil if it should be accepted. Rejected fixes are
    /// still persisted (with the reason) so the post-workout quality report can show coverage.
    private func rejectionReason(for location: CLLocation) -> String? {
        guard location.horizontalAccuracy > 0, location.horizontalAccuracy <= maxHorizontalAccuracy else { return "accuracy" }
        guard abs(location.timestamp.timeIntervalSinceNow) <= maxFixAge else { return "stale" }
        guard let last = lastAccepted else { return nil }
        let distance = location.distance(from: last)
        let dt = location.timestamp.timeIntervalSince(last.timestamp)
        if dt > 0, distance / dt > profile.maxSpeedMps { return "speed" }
        if distance >= profile.minMoveMeters { return nil }
        if last.course >= 0, location.course >= 0 {
            var courseDelta = location.course - last.course
            while courseDelta > 180 { courseDelta -= 360 }
            while courseDelta < -180 { courseDelta += 360 }
            if abs(courseDelta) > maxCourseDelta { return nil }
        }
        if dt >= profile.minIntervalSeconds { return nil }
        return "stationary"
    }
}
