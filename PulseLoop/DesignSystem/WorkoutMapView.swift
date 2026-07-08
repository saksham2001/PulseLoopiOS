import SwiftUI
import MapKit

/// Route map for a workout — a real MapKit basemap with the recorded GPS polyline and start/current
/// markers. During a live workout (`follow: true`) the camera reframes the full route as it grows and
/// offers a Recenter control; the pill shows whether auto-follow is engaged. Falls back to a
/// placeholder card when there's no usable route (non-GPS workout, denied permission, or fewer than
/// two points).
struct WorkoutMapView: View {
    let coordinates: [CLLocationCoordinate2D]
    private let latestAccuracy: Double?
    var unavailable: Bool
    var height: CGFloat
    var follow: Bool

    @State private var camera: MapCameraPosition = .automatic
    @State private var following = true
    @State private var suppressUnlock = false

    init(points: [ActivityGpsPoint], unavailable: Bool = false, height: CGFloat = 200, follow: Bool = false) {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        self.coordinates = sorted.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        self.latestAccuracy = sorted.last?.horizontalAccuracy
        self.unavailable = unavailable
        self.height = height
        self.follow = follow
    }

    /// Live-recording init: the caller (LiveWorkoutStats) already maintains a time-ordered,
    /// accepted-only coordinate array, so no per-render sort/rebuild happens here.
    init(coordinates: [CLLocationCoordinate2D], latestAccuracy: Double? = nil,
         unavailable: Bool = false, height: CGFloat = 200, follow: Bool = false) {
        self.coordinates = coordinates
        self.latestAccuracy = latestAccuracy
        self.unavailable = unavailable
        self.height = height
        self.follow = follow
    }

    var body: some View {
        if unavailable || coordinates.count < 2 {
            placeholder
        } else {
            Map(position: $camera, interactionModes: .all) {
                MapPolyline(coordinates: coordinates)
                    .stroke(routeGradient, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                if let start = coordinates.first {
                    Annotation("Start", coordinate: start) { marker(PulseColors.success) }
                }
                if let end = coordinates.last {
                    Annotation("", coordinate: end) { currentMarker }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .onEnd) { _ in
                if suppressUnlock { suppressUnlock = false }
                else if follow { following = false }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
            .overlay(alignment: .bottomLeading) { infoOverlay }
            .overlay(alignment: .topTrailing) { if follow { followControls } }
            .onAppear { recenter() }
            .onChange(of: coordinates.count) { _, _ in
                // Live (follow) mode tracks growth while auto-follow is engaged; static (summary)
                // mode always refits — its points can arrive after first render, and without this
                // the camera would stay frozen on the initial start/stop-only region.
                if follow ? following : true { reframe() }
            }
        }
    }

    private var routeGradient: LinearGradient {
        LinearGradient(colors: [PulseColors.accent, PulseColors.distance], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func marker(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white, lineWidth: 2)).shadow(radius: 2)
    }

    private var currentMarker: some View {
        Circle().fill(PulseColors.accent).frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .overlay(Circle().fill(PulseColors.accent).frame(width: 22, height: 22).opacity(0.25))
            .shadow(radius: 3)
    }

    private var infoOverlay: some View {
        let text = latestAccuracy.map { "±\(Int($0))m · \(coordinates.count) pts" } ?? "\(coordinates.count) pts"
        return Text(text)
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(PulseColors.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
    }

    private var followControls: some View {
        HStack(spacing: 6) {
            Text(following ? "Following" : "Map unlocked")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(following ? PulseColors.success : PulseColors.textMuted)
            Button { recenter() } label: {
                Image(systemName: "location.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PulseColors.accent)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(8)
    }

    private func recenter() {
        following = true
        reframe()
    }

    private func reframe() {
        suppressUnlock = true
        withAnimation(.easeInOut(duration: 0.4)) { camera = .region(region) }
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
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.003),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.003)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
