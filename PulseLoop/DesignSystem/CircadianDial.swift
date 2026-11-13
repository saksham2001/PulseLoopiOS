import SwiftUI

/// The circadian dial: a thick track for the day, a node at each event's usual time, and a gold
/// bar from each node showing how far the selected period drifted (outward = later, inward =
/// earlier, length = minutes). Workouts are a green band at the time they happened.
///
/// One view draws both shapes — the Sleep-page tile's semicircle and the detail sheet's full
/// 24-hour circle — from the same layout. Everything scales with the width it is given, so it
/// holds its proportions from the narrowest to the widest iPhone.
struct CircadianDial: View {
    let snapshot: CircadianSnapshot
    var shape: CircadianDialGeometry.Shape = .semicircle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 → 1 as the drift bars and their labels draw in.
    @State private var reveal: CGFloat = 0

    private var aspectRatio: CGFloat {
        shape == .semicircle
            ? CircadianDialLayout.semicircleSize.width / CircadianDialLayout.semicircleSize.height
            : CircadianDialLayout.fullSize.width / CircadianDialLayout.fullSize.height
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = CircadianDialLayout(width: proxy.size.width, shape: shape, snapshot: snapshot)
            ZStack {
                track(layout)
                ForEach(Array(layout.night.enumerated()), id: \.offset) { _, piece in
                    arc(layout, piece)
                        .stroke(PulseColors.accent.opacity(0.65), style: StrokeStyle(lineWidth: layout.trackWidth, lineCap: .round))
                }
                ForEach(layout.spans) { span in
                    ForEach(Array(span.arcs.enumerated()), id: \.offset) { _, piece in
                        arc(layout, piece)
                            .stroke(PulseColors.success, style: StrokeStyle(lineWidth: layout.trackWidth, lineCap: .butt))
                    }
                }
                ForEach(layout.hourLabels, id: \.text) { label in
                    Text(label.text)
                        .font(PulseFont.micro)
                        .foregroundStyle(PulseColors.textMuted)
                        .position(label.position)
                }
                ForEach(layout.markers) { marker in
                    if let start = marker.barStart, let end = marker.barEnd {
                        Path { path in
                            path.move(to: start)
                            path.addLine(to: end)
                        }
                        .trim(from: 0, to: reveal)
                        .stroke(PulseColors.rhythm, style: StrokeStyle(lineWidth: layout.barWidth, lineCap: .round))
                        .shadow(color: PulseColors.rhythm.opacity(0.5), radius: 4 * layout.scale)
                    }
                }
                ForEach(layout.markers) { marker in
                    node(marker, layout)
                }
                ForEach(layout.spans) { span in
                    Image(systemName: span.workout.category.symbol)
                        .font(.system(size: 11 * layout.scale, weight: .semibold))
                        .foregroundStyle(PulseColors.success)
                        .position(span.iconPosition)
                }
                ForEach(layout.markers) { marker in
                    if let label = marker.label {
                        Text(label)
                            .font(.system(size: layout.labelFontSize, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(PulseColors.rhythm)
                            .fixedSize()
                            .position(marker.labelPosition)
                            .opacity(reveal)
                    }
                }
                summary(layout)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .onAppear {
            if reduceMotion {
                reveal = 1
            } else {
                withAnimation(.snappy(duration: 0.55).delay(0.15)) { reveal = 1 }
            }
        }
        // The card or sheet that hosts the dial describes it in words.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func track(_ layout: CircadianDialLayout) -> some View {
        let style = StrokeStyle(lineWidth: layout.trackWidth, lineCap: .round)
        if shape == .semicircle {
            arc(layout, (startAngle: .pi, sweep: .pi)).stroke(PulseColors.elevated, style: style)
        } else {
            arc(layout, (startAngle: 0, sweep: 2 * .pi)).stroke(PulseColors.elevated, style: style)
        }
    }

    /// An arc going forward in time. SwiftUI's y-down space makes `clockwise: false` the
    /// direction of increasing angle, which is clockwise on screen.
    private func arc(_ layout: CircadianDialLayout, _ piece: (startAngle: Double, sweep: Double)) -> Path {
        Path { path in
            path.addArc(
                center: layout.center, radius: layout.radius,
                startAngle: .radians(piece.startAngle), endAngle: .radians(piece.startAngle + piece.sweep),
                clockwise: false)
        }
    }

    private func node(_ marker: CircadianDialLayout.Marker, _ layout: CircadianDialLayout) -> some View {
        Circle()
            .fill(PulseColors.cardSoft)
            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
            .overlay(
                Image(systemName: marker.anchor.kind.symbol)
                    .font(.system(size: layout.nodeRadius * 1.02, weight: .semibold))
                    .foregroundStyle(marker.anchor.kind.isMeal ? PulseColors.textPrimary.opacity(0.85) : PulseColors.sleep)
            )
            .frame(width: layout.nodeRadius * 2, height: layout.nodeRadius * 2)
            .position(marker.position)
    }

    private func summary(_ layout: CircadianDialLayout) -> some View {
        VStack(spacing: 2) {
            Text(snapshot.headline)
                .font(PulseFont.number(20 * min(layout.scale, 1.1)))
                .foregroundStyle(PulseColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !snapshot.subline.isEmpty {
                Text(snapshot.subline)
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: layout.summaryWidth)
        .position(layout.summaryCenter)
    }
}

/// Everything the dial draws, resolved to points for a given width. Pure layout — no drawing —
/// so the placement rules (spreading close nodes, dropping overlapping labels, keeping a
/// workout icon clear of a drift bar) live in one place.
struct CircadianDialLayout {
    /// The proportions the dial was designed at; every measure scales from these.
    static let semicircleSize = CGSize(width: 326, height: 168)
    static let fullSize = CGSize(width: 358, height: 340)

    /// Points of drift bar per minute off usual, and the longest a bar grows (about an hour).
    static let barPointsPerMinute: CGFloat = 0.36
    static let maxBarLength: CGFloat = 22
    /// Below this the event was on time: no bar at all.
    static let minBarMinutes: Double = 5

    struct Marker: Identifiable {
        let anchor: CircadianAnchor
        let position: CGPoint
        let barStart: CGPoint?
        let barEnd: CGPoint?
        var label: String?
        let labelPosition: CGPoint
        var id: String { anchor.id }
    }

    struct Span: Identifiable {
        let workout: CircadianWorkout
        let arcs: [(startAngle: Double, sweep: Double)]
        let iconPosition: CGPoint
        var id: Int { workout.id }
    }

    let scale: CGFloat
    let center: CGPoint
    let radius: CGFloat
    let trackWidth: CGFloat
    let nodeRadius: CGFloat
    let barWidth: CGFloat
    let labelFontSize: CGFloat
    let summaryCenter: CGPoint
    let summaryWidth: CGFloat
    private(set) var markers: [Marker] = []
    private(set) var spans: [Span] = []
    private(set) var night: [(startAngle: Double, sweep: Double)] = []
    private(set) var hourLabels: [(text: String, position: CGPoint)] = []

    init(width: CGFloat, shape: CircadianDialGeometry.Shape, snapshot: CircadianSnapshot) {
        let geometry = CircadianDialGeometry(shape: shape)
        let semicircle = shape == .semicircle
        let s = width / (semicircle ? Self.semicircleSize.width : Self.fullSize.width)
        scale = s
        center = CGPoint(x: width / 2, y: (semicircle ? 160 : 170) * s)
        radius = (semicircle ? 110 : 112) * s
        trackWidth = (semicircle ? 12 : 14) * s
        nodeRadius = (semicircle ? 9 : 10) * s
        barWidth = 4.5 * s
        labelFontSize = 11 * min(max(s, 1), 1.15)
        summaryCenter = semicircle ? CGPoint(x: width / 2, y: center.y - 24 * s) : center
        summaryWidth = (semicircle ? 148 : 136) * s

        let pointsPerMinute = radius * CGFloat(geometry.sweepPerMinute)
        let c = center, r = radius
        func point(_ minutes: Double, _ distance: CGFloat) -> CGPoint {
            geometry.point(minutes, radius: distance, center: c)
        }

        if let window = snapshot.sleepWindow {
            night = geometry.arcs(from: window.bed, to: window.wake)
        }

        // Nodes, nudged apart where two events sit too close to read.
        let minGap = Double((nodeRadius * 2 + 3 * s) / pointsPerMinute)
        let placed = CircadianDialGeometry.spread(snapshot.anchors.map(\.displayMinutes), minGap: minGap)
        let barGap = nodeRadius + 3 * s
        var built: [Marker] = []
        for (anchor, minutes) in zip(snapshot.anchors, placed) {
            var barStart: CGPoint?, barEnd: CGPoint?, label: String?
            var outward: CGFloat = 0
            if let delta = anchor.deltaMinutes, abs(delta) >= Self.minBarMinutes {
                let length = min(max(CGFloat(abs(delta)) * Self.barPointsPerMinute, 3), Self.maxBarLength) * s
                let sign: CGFloat = delta > 0 ? 1 : -1
                barStart = point(minutes, r + sign * barGap)
                barEnd = point(minutes, r + sign * (barGap + length))
                if delta > 0 { outward = length }
                // The tile keeps labels to what matters; the full dial has room for all of them.
                let threshold: Double = (semicircle && anchor.kind.isMeal) ? CircadianEngine.driftThreshold : 10
                if abs(delta) >= threshold { label = CircadianFormat.signed(delta) }
            }
            // Labels always sit outside the track, so the middle stays clear for the headline.
            // Text is wider than it is tall, so it needs more room where the bar runs sideways.
            let angle = geometry.screenAngle(minutes)
            let clearance = (5 + 17 * CGFloat(abs(cos(angle))) + 8 * CGFloat(abs(sin(angle)))) * s
            var labelPoint = point(minutes, r + barGap + outward + clearance)
            labelPoint.x = min(max(labelPoint.x, 18 * s), width - 18 * s)
            labelPoint.y = max(labelPoint.y, 8 * s)
            built.append(Marker(anchor: anchor, position: point(minutes, r), barStart: barStart, barEnd: barEnd,
                                label: label, labelPosition: labelPoint))
        }
        // Drop labels that would collide: wake and bed win, then the biggest drift.
        let priority = built.indices
            .filter { built[$0].label != nil }
            .sorted { a, b in
                let (x, y) = (built[a].anchor, built[b].anchor)
                if x.kind.isMeal != y.kind.isMeal { return !x.kind.isMeal }
                return abs(x.deltaMinutes ?? 0) > abs(y.deltaMinutes ?? 0)
            }
        let labelSize = CGSize(width: 38 * s, height: 16 * s)
        let rects = priority.map { index in
            let p = built[index].labelPosition
            return CGRect(x: p.x - labelSize.width / 2, y: p.y - labelSize.height / 2, width: labelSize.width, height: labelSize.height)
        }
        for (index, keep) in zip(priority, CircadianDialGeometry.keepLabels(rects)) where !keep {
            built[index].label = nil
        }
        markers = built

        // Workout bands, each wide enough to see, with the icon on whichever side is clear.
        let minSpanMinutes = Double(6 * s / pointsPerMinute)
        let outerOffset = trackWidth / 2 + 11 * s
        spans = snapshot.workouts.map { workout in
            let duration = max(workout.durationMinutes, minSpanMinutes)
            let middle = workout.startMinutes + duration / 2
            let outside = point(middle, r + outerOffset)
            let inside = point(middle, r - outerOffset)
            func crowded(_ candidate: CGPoint, outwardSide: Bool) -> Bool {
                zip(snapshot.anchors, built).contains { anchor, marker in
                    guard let delta = anchor.deltaMinutes, let end = marker.barEnd, (delta > 0) == outwardSide else { return false }
                    return hypot(end.x - candidate.x, end.y - candidate.y) < 20 * s
                        || hypot(marker.labelPosition.x - candidate.x, marker.labelPosition.y - candidate.y) < 20 * s && marker.label != nil
                }
            }
            let useInside = crowded(outside, outwardSide: true) && !crowded(inside, outwardSide: false)
            return Span(
                workout: workout,
                arcs: geometry.arcs(from: workout.startMinutes, to: workout.startMinutes + duration),
                iconPosition: useInside ? inside : outside)
        }

        if !semicircle {
            let labelRadius = r - trackWidth / 2 - 21 * s
            hourLabels = [("12 PM", 720.0), ("6 PM", 1080.0), ("12 AM", 0.0), ("6 AM", 360.0)]
                .map { text, minutes in (text: text, position: point(minutes, labelRadius)) }
                // An inward drift bar or a workout icon can land on an hour label; they win.
                .filter { label in
                    let taken = built.compactMap(\.barEnd) + spans.map(\.iconPosition)
                    return !taken.contains { hypot($0.x - label.position.x, $0.y - label.position.y) < 24 * s }
                }
        }
    }
}
