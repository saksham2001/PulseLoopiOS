import SwiftUI
import MapKit

/// Route map for a workout — a real MapKit basemap with the recorded GPS polyline and start/end
/// markers, fit to the route's bounds. Falls back to a placeholder card when there's no usable
/// route (non-GPS workout, denied permission, or fewer than two points), mirroring the web
/// `WorkoutMapCard`.
struct WorkoutMapView: View {
    let coordinates: [CLLocationCoordinate2D]
    var unavailable: Bool
    var height: CGFloat

    init(points: [ActivityGpsPoint], unavailable: Bool = false, height: CGFloat = 200) {
        self.coordinates = points
            .sorted { $0.timestamp < $1.timestamp }
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        self.unavailable = unavailable
        self.height = height
    }

    var body: some View {
        if unavailable || coordinates.count < 2 {
            placeholder
        } else {
            Map(initialPosition: .region(region), interactionModes: []) {
                MapPolyline(coordinates: coordinates)
                    .stroke(PulseColors.distance, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                if let start = coordinates.first {
                    Annotation("Start", coordinate: start) { marker(PulseColors.success) }
                }
                if let end = coordinates.last {
                    Annotation("End", coordinate: end) { marker(PulseColors.distance) }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
    }

    private func marker(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "map")
                .font(.system(size: 24))
                .foregroundStyle(PulseColors.textMuted)
            Text(unavailable ? "GPS route unavailable" : "No route yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PulseColors.textPrimary)
            Text(unavailable
                 ? "Distance uses the ring/app estimate where possible."
                 : "Move outdoors to start tracking your route.")
                .font(.system(size: 12))
                .foregroundStyle(PulseColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(PulseColors.cardSoft.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private var region: MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.003),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.003)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
