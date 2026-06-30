import SwiftUI

// Custom gauges for vitals: a 270° open-bottom arc (gap at the bottom) with the metric's zones drawn
// as colored arc segments, a value arc, and a marker centered on the stroke. Built on `Shape` rather
// than SwiftUI `Gauge` because the multi-zone track and the BP dual ring need bespoke rendering.
// Colors resolve through `VitalColorToken`/zones so a gauge matches its chart and legend exactly.

/// Shared gauge geometry: a 270° sweep starting bottom-left, leaving a 90° gap centered at the
/// bottom. `0°` is at 3 o'clock and angles increase clockwise (SwiftUI convention).
private enum GaugeGeometry {
    /// Start at 135° (bottom-left); sweep 270° clockwise to 405° (bottom-right).
    static let startAngle: Double = 135
    static let sweep: Double = 270

    /// The on-screen angle for a 0…1 fraction along the arc.
    static func angle(for fraction: Double) -> Angle {
        .degrees(startAngle + sweep * max(0, min(1, fraction)))
    }
}

// MARK: - Arc shape

/// An arc spanning `startFraction…endFraction` of the 270° gauge sweep. `inset` shrinks the radius so
/// concentric rings (BP systolic/diastolic) don't overlap. Fractions are clamped to [0, 1].
struct RingSegment: Shape {
    let startFraction: Double
    let endFraction: Double
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2 - inset
        guard radius > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: GaugeGeometry.angle(for: startFraction),
            endAngle: GaugeGeometry.angle(for: endFraction),
            clockwise: false
        )
        return path
    }
}

/// The top half of a disc (a semicircle filling the upper half of its bounding box, flat edge along
/// the horizontal center line). Rotate to orient; used as a rounded arc tip that only bulges one way.
struct HalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // Semicircle across the top: from the right of the diameter, sweeping up to the left.
        path.move(to: CGPoint(x: center.x + radius, y: center.y))
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        path.closeSubpath()
        return path
    }
}

// MARK: - Single-value gauge

/// A 270° gauge: muted zone arcs in the track, a bright value arc, a marker dot centered on the
/// stroke, and a center stack (value / unit / status). The value lives only here (the card chrome
/// does not repeat it).
struct VitalRingGauge: View {
    let value: Double
    let domain: ClosedRange<Double>
    let zones: [MetricZone]
    let valueColor: Color
    let centerValue: String
    var centerUnit: String?
    var centerStatus: String?
    var subtitle: String?
    var size: CGFloat = 200
    var lineWidth: CGFloat = 16

    private func fraction(_ v: Double) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0 }
        return max(0, min(1, (v - domain.lowerBound) / span))
    }

    /// Inset the arc radius by half the stroke so the stroke fits inside the frame (no clipped ends),
    /// and so the marker can sit on the exact same centerline.
    private var strokeInset: CGFloat { lineWidth / 2 }

    var body: some View {
        ZStack {
            // Track (the full 270° arc), rounded so both sweep ends read as rounded under the zones.
            RingSegment(startFraction: 0, endFraction: 1, inset: strokeInset)
                .stroke(PulseColors.elevated, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Muted zone arcs — every zone is butt-capped at its exact boundaries so interior joins are
            // clean straight edges (orange meets red with no rounding between them).
            ForEach(zones) { zone in
                let lower = fraction(zone.lower ?? domain.lowerBound)
                let upper = fraction(zone.upper ?? domain.upperBound)
                if upper > lower {
                    RingSegment(startFraction: lower, endFraction: upper, inset: strokeInset)
                        .stroke(zone.color.opacity(0.32), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                }
            }

            // Rounded outer tips ONLY at the two sweep ends, so the colored track has rounded ends to
            // match the track without rounding any interior boundary. A zero-length round-capped stroke
            // renders as a filled semicircular tip.
            roundTip(at: 0, color: zones.first?.color)
            roundTip(at: 1, color: zones.last?.color)

            // Value arc from the start up to the current value (rounded leading tip looks intentional).
            RingSegment(startFraction: 0, endFraction: fraction(value), inset: strokeInset)
                .stroke(valueColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            markerDot

            VStack(spacing: 2) {
                Text(centerValue)
                    .font(.system(size: size * 0.30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                    .contentTransition(.numericText())
                if let centerUnit {
                    Text(centerUnit).font(.system(size: size * 0.08, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                }
                if let centerStatus {
                    Text(centerStatus.uppercased())
                        .font(.system(size: size * 0.08, weight: .semibold)).tracking(1.0)
                        .foregroundStyle(valueColor)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: size * 0.065)).foregroundStyle(PulseColors.textMuted)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// A rounded tip at a sweep end (fraction 0 or 1): a semicircle whose flat edge sits exactly on
    /// the zone's butt end and bulges only *outward* (tangentially past the end), so it rounds the end
    /// without overlapping back into the zone. `outward` flips the bulge direction for the start tip.
    @ViewBuilder
    private func roundTip(at fraction: Double, color: Color?) -> some View {
        if let color {
            let angle = GaugeGeometry.angle(for: fraction)
            let r = size / 2 - strokeInset
            // Bulge along the tangent: +90° past the end (fraction 1), −90° before the start (0).
            let bulge = fraction >= 0.5 ? angle.degrees + 90 : angle.degrees - 90
            HalfDisc()
                .fill(color.opacity(0.32))
                .frame(width: lineWidth, height: lineWidth)
                .rotationEffect(.degrees(bulge - 90))   // HalfDisc bulges "up" by default
                .offset(x: r * cos(angle.radians), y: r * sin(angle.radians))
        }
    }

    /// Marker on the arc stroke centerline — the SAME radius the inset `RingSegment` arcs are drawn at
    /// (`size/2 - strokeInset`), at the same angle basis. Matching the inset is what puts it dead-center
    /// on the line instead of slightly inside.
    private var markerDot: some View {
        let angle = GaugeGeometry.angle(for: fraction(value))
        let r = size / 2 - strokeInset
        return Circle()
            .fill(PulseColors.textPrimary)
            .frame(width: lineWidth * 0.55, height: lineWidth * 0.55)
            .offset(x: r * cos(angle.radians), y: r * sin(angle.radians))
    }
}

// MARK: - Dual-ring gauge (blood pressure)

/// Two concentric 270° gauges: outer = systolic, inner = diastolic, each on its own domain and zones.
/// Center shows `122/78` and the worse-of-the-two category. Each ring carries a marker.
struct DualVitalRingGauge: View {
    let systolic: Double
    let diastolic: Double
    let systolicDomain: ClosedRange<Double>
    let diastolicDomain: ClosedRange<Double>
    let systolicZones: [MetricZone]
    let diastolicZones: [MetricZone]
    let statusLabel: String
    let statusColor: Color
    var size: CGFloat = 220
    var lineWidth: CGFloat = 14

    private func fraction(_ v: Double, _ domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0 }
        return max(0, min(1, (v - domain.lowerBound) / span))
    }

    private var innerInset: CGFloat { lineWidth + 8 }

    var body: some View {
        ZStack {
            // Outer ring = systolic.
            ring(zones: systolicZones, domain: systolicDomain, value: systolic, inset: 0,
                 valueColor: PulseColors.bloodPressure)
            marker(fraction: fraction(systolic, systolicDomain), inset: 0)

            // Inner ring = diastolic.
            ring(zones: diastolicZones, domain: diastolicDomain, value: diastolic, inset: innerInset,
                 valueColor: PulseColors.bloodPressure.opacity(0.7))
            marker(fraction: fraction(diastolic, diastolicDomain), inset: innerInset)

            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(systolic))").font(.system(size: size * 0.20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("/").font(.system(size: size * 0.13, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                    Text("\(Int(diastolic))").font(.system(size: size * 0.20, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .foregroundStyle(PulseColors.textPrimary)
                Text("mmHg").font(.system(size: size * 0.06, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                Text(statusLabel.uppercased())
                    .font(.system(size: size * 0.06, weight: .semibold)).tracking(1.0)
                    .foregroundStyle(statusColor)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func ring(zones: [MetricZone], domain: ClosedRange<Double>, value: Double,
                      inset: CGFloat, valueColor: Color) -> some View {
        // `inset + lineWidth/2` keeps the stroke inside its band (no clipped outer ring) and aligns
        // the arc centerline with the marker (`size/2 - inset - lineWidth/2`).
        let arcInset = inset + lineWidth / 2
        let r = size / 2 - arcInset
        RingSegment(startFraction: 0, endFraction: 1, inset: arcInset)
            .stroke(PulseColors.elevated, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        // Butt-capped zones → clean straight interior joins.
        ForEach(zones) { zone in
            let lower = fraction(zone.lower ?? domain.lowerBound, domain)
            let upper = fraction(zone.upper ?? domain.upperBound, domain)
            if upper > lower {
                RingSegment(startFraction: lower, endFraction: upper, inset: arcInset)
                    .stroke(zone.color.opacity(0.30), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
        // Rounded outer tips only at the two sweep ends.
        tip(at: 0, radius: r, color: zones.first?.color)
        tip(at: 1, radius: r, color: zones.last?.color)
        RingSegment(startFraction: 0, endFraction: fraction(value, domain), inset: arcInset)
            .stroke(valueColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    /// A rounded semicircular tip at a sweep end, bulging only outward (tangentially) so it doesn't
    /// overlap back into the butt-capped end zone.
    @ViewBuilder
    private func tip(at fraction: Double, radius: CGFloat, color: Color?) -> some View {
        if let color {
            let angle = GaugeGeometry.angle(for: fraction)
            let bulge = fraction >= 0.5 ? angle.degrees + 90 : angle.degrees - 90
            HalfDisc()
                .fill(color.opacity(0.30))
                .frame(width: lineWidth, height: lineWidth)
                .rotationEffect(.degrees(bulge - 90))
                .offset(x: radius * cos(angle.radians), y: radius * sin(angle.radians))
        }
    }

    private func marker(fraction: Double, inset: CGFloat) -> some View {
        let angle = GaugeGeometry.angle(for: fraction)
        let r = size / 2 - inset - lineWidth / 2
        return Circle()
            .fill(PulseColors.textPrimary)
            .frame(width: lineWidth * 0.5, height: lineWidth * 0.5)
            .offset(x: r * cos(angle.radians), y: r * sin(angle.radians))
    }
}
