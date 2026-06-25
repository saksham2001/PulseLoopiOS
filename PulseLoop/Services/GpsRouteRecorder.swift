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
    private(set) var authorization: CLAuthorizationStatus
    private(set) var isTracking = false
    private(set) var pointCount = 0

    /// Surfaced to the view layer so SwiftUI never needs to import CoreLocation.
    var isPermissionDenied: Bool { authorization == .denied || authorization == .restricted }

    private let manager = CLLocationManager()
    private var sessionId: UUID?
    private var lastAccepted: CLLocation?
    private var activityType = "run"
    private var isCycling: Bool { activityType == "cycle" }

    // Filtering thresholds.
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
        self.activityType = activityType
        lastAccepted = nil
        pointCount = 0
        // Provisional When-In-Use still records in the foreground; also request Always so the
        // route keeps recording when the screen locks / the app backgrounds.
        manager.requestWhenInUseAuthorization()
        manager.requestAlwaysAuthorization()
        manager.desiredAccuracy = WorkoutPrefsStore.shared.settings.gpsAccuracy.clValue
        manager.distanceFilter = isCycling ? 8 : 5
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .fitness
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
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
        let maxSpeed = isCycling ? 25.0 : 8.0
        if dt > 0, distance / dt > maxSpeed { return "speed" }
        let minMove = isCycling ? 8.0 : 4.0
        if distance >= minMove { return nil }
        if last.course >= 0, location.course >= 0 {
            var courseDelta = location.course - last.course
            while courseDelta > 180 { courseDelta -= 360 }
            while courseDelta < -180 { courseDelta += 360 }
            if abs(courseDelta) > maxCourseDelta { return nil }
        }
        let minInterval = isCycling ? 8.0 : 6.0
        if location.timestamp.timeIntervalSince(last.timestamp) >= minInterval { return nil }
        return "stationary"
    }
}
