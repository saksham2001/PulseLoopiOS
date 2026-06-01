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

    // Filtering thresholds.
    private let maxHorizontalAccuracy = 30.0   // metres; reject poorer/invalid fixes
    private let maxFixAge = 5.0                 // seconds; reject stale cached fixes
    private let minMoveMeters = 4.0            // de-duplicate near-stationary points
    private let maxSpeedMetersPerSec = 25.0    // ~90 km/h; reject impossible jumps

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func start(sessionId: UUID) {
        self.sessionId = sessionId
        lastAccepted = nil
        pointCount = 0
        manager.requestWhenInUseAuthorization()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation()
        isTracking = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        lastAccepted = nil
        sessionId = nil
        isTracking = false
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let sessionId else { return }
            for location in locations where accept(location) {
                lastAccepted = location
                pointCount += 1
                let lat = location.coordinate.latitude
                let lon = location.coordinate.longitude
                let ts = location.timestamp
                Task { await PulseEventBus.shared.publish(.gpsPoint(sessionId: sessionId, latitude: lat, longitude: lon, timestamp: ts)) }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient location errors are non-fatal; the next fix may succeed. Nothing to persist.
    }

    /// Accept a fix only if it is recent, accurate, a real move from the last point, and not an
    /// impossible jump.
    private func accept(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy > 0, location.horizontalAccuracy <= maxHorizontalAccuracy else { return false }
        guard abs(location.timestamp.timeIntervalSinceNow) <= maxFixAge else { return false }
        guard let last = lastAccepted else { return true }
        let distance = location.distance(from: last)
        guard distance >= minMoveMeters else { return false }
        let dt = location.timestamp.timeIntervalSince(last.timestamp)
        if dt > 0, distance / dt > maxSpeedMetersPerSec { return false }
        return true
    }
}
