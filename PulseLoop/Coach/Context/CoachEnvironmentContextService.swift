import Foundation
import UIKit
@preconcurrency import CoreLocation
import WeatherKit

/// Opt-in city-level location + weather for the coach. Produces a
/// `CoachContextPacket.EnvironmentContext` so coaching can ground practical advice
/// (outdoor vs indoor, hydration on hot days, planning around rain) without ever
/// exposing the user's precise location — only the reverse-geocoded city/region.
///
/// Privacy + resilience by design:
/// - Coarse one-shot location (`kCLLocationAccuracyThreeKilometers`), fetched only
///   when the app is active AND authorized; background (BGTask) callers use the
///   persisted cache so a fresh process never triggers a location prompt.
/// - Raw coordinates NEVER enter the packet — only city/region from `CLGeocoder`.
/// - Weather runs in do/catch; ANY failure (missing entitlement in forks, airplane
///   mode) degrades to city-only or a stale cached weather (≤3h). `snapshot` never throws.
@MainActor
final class CoachEnvironmentContextService: NSObject, CLLocationManagerDelegate {
    static let shared = CoachEnvironmentContextService()

    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private let manager = CLLocationManager()
    private let weather = WeatherService.shared
    private let defaults: UserDefaults
    private static let cacheKey = "pulseloop.coach.environment.v1"

    /// Weather is re-fetched after this; the city/coords are kept much longer.
    private let weatherTTL: TimeInterval = 30 * 60
    /// City + coordinates cache lifetime (people don't move cities minute-to-minute).
    private let locationTTL: TimeInterval = 6 * 3600
    /// Oldest weather we'll still surface when a fresh fetch fails.
    private let staleWeatherWindow: TimeInterval = 3 * 3600
    /// After a failed fetch, don't retry weather for this long — a persistent
    /// failure (e.g. WeatherKit not enabled on the App ID) would otherwise be
    /// re-attempted on every coach turn and summary refresh.
    private let weatherRetryCooldown: TimeInterval = 5 * 60

    private var cache: Cached?
    private var lastWeatherFailureAt: Date?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        cache = loadCache()
    }

    // MARK: - Public API

    /// Ask for When-In-Use authorization when the user enables the toggle. No-op
    /// once a decision exists (the OS won't re-prompt anyway).
    func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Build the environment context, or nil when the toggle is off. Never throws:
    /// weather failures degrade to city-only or a stale cached reading.
    func snapshot(now: Date = Date()) async -> CoachContextPacket.EnvironmentContext? {
        guard CoachSettingsStore.shared.settings.enableEnvironmentContext else { return nil }

        // Resolve a coordinate: a fresh coarse fix (foreground + authorized), else the cache.
        let coordinate = await resolveCoordinate(now: now)
        guard let coordinate else {
            // No usable location at all — surface a stale cache if we have one.
            return cache?.environment(now: now, staleWeatherWindow: staleWeatherWindow)
        }

        // City/region: reuse the cached geocode when the coordinate is close and fresh; else reverse-geocode.
        let place = await resolvePlace(for: coordinate, now: now)

        // Weather: reuse cached weather within TTL, else fetch; degrade to city-only / stale on error.
        if let cached = cache, cached.isWeatherFresh(now: now, ttl: weatherTTL) {
            return cached.environment(now: now, staleWeatherWindow: staleWeatherWindow, overridePlace: place)
        }
        if let failedAt = lastWeatherFailureAt, now.timeIntervalSince(failedAt) < weatherRetryCooldown {
            return degraded(place: place, now: now)
        }

        do {
            let weatherData = try await weather.weather(for: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), including: .current, .daily)
            let env = makeContext(place: place, current: weatherData.0, daily: weatherData.1, now: now)
            store(Cached(coordinate: coordinate, place: place, weather: env, weatherAt: now, locationAt: now), now: now)
            lastWeatherFailureAt = nil
            return env
        } catch {
            lastWeatherFailureAt = now
            return degraded(place: place, now: now)
        }
    }

    /// City-only, or a stale cached weather (≤3h) with the current city.
    private func degraded(place: Place?, now: Date) -> CoachContextPacket.EnvironmentContext? {
        cache?.environment(now: now, staleWeatherWindow: staleWeatherWindow, overridePlace: place)
            ?? CoachContextPacket.EnvironmentContext(city: place?.city, region: place?.region, asOf: CoachDataAccess.isoString(now))
    }

    // MARK: - Location

    private func resolveCoordinate(now: Date) async -> CLLocationCoordinate2D? {
        let authorized = manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
        // Only fetch fresh location when the app is active AND authorized. In the
        // background (BGTask path) use the persisted cache only.
        if authorized, UIApplication.shared.applicationState != .background {
            if let fix = await requestOneShotLocation() {
                return fix.coordinate
            }
        }
        if let cached = cache, now.timeIntervalSince(cached.locationAt) < locationTTL {
            return cached.coordinate
        }
        return nil
    }

    private func requestOneShotLocation() async -> CLLocation? {
        if let existing = locationContinuation {
            existing.resume(returning: nil)   // never leave a prior continuation dangling
            locationContinuation = nil
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    private func resolvePlace(for coordinate: CLLocationCoordinate2D, now: Date) async -> Place? {
        if let cached = cache, now.timeIntervalSince(cached.locationAt) < locationTTL,
           cached.coordinate.isNear(coordinate), let place = cached.place {
            return place
        }
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return cache?.place
        }
        return Place(city: placemark.locality, region: placemark.administrativeArea)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fix = locations.last
        MainActor.assumeIsolated {
            locationContinuation?.resume(returning: fix)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            locationContinuation?.resume(returning: nil)
            locationContinuation = nil
        }
    }

    // MARK: - Weather → context

    private func makeContext(place: Place?, current: CurrentWeather, daily: Forecast<DayWeather>, now: Date) -> CoachContextPacket.EnvironmentContext {
        let today = daily.forecast.first
        let iso = ISO8601DateFormatter()
        return CoachContextPacket.EnvironmentContext(
            city: place?.city,
            region: place?.region,
            tempC: current.temperature.converted(to: .celsius).value,
            condition: current.condition.description,
            highC: today?.highTemperature.converted(to: .celsius).value,
            lowC: today?.lowTemperature.converted(to: .celsius).value,
            precipitationChancePct: today.map { Int(($0.precipitationChance * 100).rounded()) },
            sunrise: today?.sun.sunrise.map { iso.string(from: $0) },
            sunset: today?.sun.sunset.map { iso.string(from: $0) },
            asOf: CoachDataAccess.isoString(now)
        )
    }

    // MARK: - Cache (in-memory + UserDefaults)

    private func store(_ cached: Cached, now: Date) {
        cache = cached
        if let data = try? JSONEncoder().encode(cached) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    private func loadCache() -> Cached? {
        guard let data = defaults.data(forKey: Self.cacheKey) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    // MARK: - Supporting types

    struct Place: Codable {
        var city: String?
        var region: String?
    }

    private struct Cached: Codable {
        var lat: Double
        var lon: Double
        var place: Place?
        var weather: CachedWeather?
        var weatherAt: Date
        var locationAt: Date

        init(coordinate: CLLocationCoordinate2D, place: Place?, weather env: CoachContextPacket.EnvironmentContext?, weatherAt: Date, locationAt: Date) {
            self.lat = coordinate.latitude
            self.lon = coordinate.longitude
            self.place = place
            self.weather = env.map(CachedWeather.init)
            self.weatherAt = weatherAt
            self.locationAt = locationAt
        }

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

        func isWeatherFresh(now: Date, ttl: TimeInterval) -> Bool {
            weather != nil && now.timeIntervalSince(weatherAt) < ttl
        }

        /// Rebuild the packet context from cache, dropping weather that's older than the stale window.
        func environment(now: Date, staleWeatherWindow: TimeInterval,
                         overridePlace: Place? = nil) -> CoachContextPacket.EnvironmentContext? {
            let place = overridePlace ?? place
            let weatherIsUsable = weather != nil && now.timeIntervalSince(weatherAt) <= staleWeatherWindow
            if let weather, weatherIsUsable {
                return weather.context(city: place?.city, region: place?.region, asOf: CoachDataAccess.isoString(weatherAt))
            }
            // No usable weather — city-only (or nil if we don't even have a city).
            guard place?.city != nil || place?.region != nil else { return nil }
            return CoachContextPacket.EnvironmentContext(city: place?.city, region: place?.region, asOf: CoachDataAccess.isoString(now))
        }
    }

    private struct CachedWeather: Codable {
        var tempC: Double?
        var condition: String?
        var highC: Double?
        var lowC: Double?
        var precipitationChancePct: Int?
        var sunrise: String?
        var sunset: String?

        init(_ env: CoachContextPacket.EnvironmentContext) {
            tempC = env.tempC; condition = env.condition
            highC = env.highC; lowC = env.lowC
            precipitationChancePct = env.precipitationChancePct
            sunrise = env.sunrise; sunset = env.sunset
        }

        func context(city: String?, region: String?, asOf: String) -> CoachContextPacket.EnvironmentContext {
            CoachContextPacket.EnvironmentContext(
                city: city, region: region, tempC: tempC, condition: condition,
                highC: highC, lowC: lowC, precipitationChancePct: precipitationChancePct,
                sunrise: sunrise, sunset: sunset, asOf: asOf
            )
        }
    }
}

private extension CLLocationCoordinate2D {
    /// Within ~1km — close enough to reuse the same city geocode.
    func isNear(_ other: CLLocationCoordinate2D) -> Bool {
        abs(latitude - other.latitude) < 0.01 && abs(longitude - other.longitude) < 0.01
    }
}
