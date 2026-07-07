import SwiftUI
import SwiftData

// MARK: - Summary components

/// The full rich body of a finished workout — header, hero band, stat grid, map, splits, HR chart
/// + zones, SpO₂ chart, elevation profile, and the recording-quality card. Shared by the
/// post-record summary (`RecordSummaryView`) and the activity detail screen (`ActivityDetailView`)
/// so the two never drift apart. Read-only; each host supplies its own footer (editable
/// effort/notes + Done, or read-only notes + Delete).
struct WorkoutMetricsSections: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    let session: ActivitySession
    /// Shows the "WORKOUT SAVED" badge in the header (only meaningful right after recording).
    var savedBadge: Bool = false

    private var units: UnitsPreference { profiles.first?.units ?? .metric }

    var body: some View {
        let points = ActivityRepository.gpsPoints(sessionId: session.id, context: modelContext)
        let accepted = points.filter { $0.accepted }.sorted { $0.timestamp < $1.timestamp }
        let hr = sessionHRSamples(session.id, context: modelContext)
        let spo2 = sessionSpO2Samples(session.id, context: modelContext)
        let duration = session.endedAt.map { Int($0.timeIntervalSince(session.startedAt) - session.totalPauseSeconds) }
        let elevation = session.useGps ? routeElevation(accepted) : nil
        let altitudes = accepted.compactMap(\.altitude)

        VStack(spacing: 16) {
            header

            SummaryHeroBand(session: session, durationSeconds: duration, units: units)

            statsGrid(elevationGain: elevation?.gain)

            if session.useGps {
                WorkoutMapView(points: points)
                SplitsTable(points: accepted, units: units)
            }

            if hr.count > 1 {
                chartCard(title: "HEART RATE", footnote: hrFootnote) {
                    ActivityZoneLineChart(
                        samples: hr,
                        startAt: session.startedAt,
                        metric: .heartRate,
                        yDomain: hrDomain(hr),
                        thresholds: VitalsThresholdEngine.zoneThresholds(for: .heartRate, profile: physiology),
                        height: 120,
                        colorForValue: { VitalsThresholdEngine.colorToken(forValue: $0, metric: .heartRate, profile: physiology).color }
                    )
                }
                HRZonesCard(samples: hr, age: userAge)
            }

            if spo2.count > 1 {
                chartCard(title: "BLOOD OXYGEN", footnote: spo2Footnote) {
                    ActivityZoneLineChart(
                        samples: spo2,
                        startAt: session.startedAt,
                        metric: .spo2,
                        yDomain: 88...100,
                        referenceBands: [ReferenceBand(lower: 95, upper: 100, colorToken: .cyan)],
                        dashedRules: [92],
                        showPoints: true,
                        thresholds: VitalsThresholdEngine.zoneThresholds(for: .spo2, profile: physiology),
                        height: 110,
                        colorForValue: { VitalsThresholdEngine.colorToken(forValue: $0, metric: .spo2, profile: physiology).color }
                    )
                }
            }

            if let elevation, altitudes.count >= 3 {
                chartCard(title: "ELEVATION",
                          footnote: String(format: "↑ %.0f m   ↓ %.0f m", elevation.gain, elevation.loss)) {
                    ElevationAreaChart(altitudes: altitudes, height: 120)
                }
            }

            RecordingQualityCard(session: session)
        }
    }

    /// Age from the (single) user profile, used to estimate HRmax for the zones card.
    private var userAge: Int? {
        (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first?.age
    }

    /// Physiology profile driving the activity chart's zone coloring (same engine as vitals).
    private var physiology: UserPhysiologyProfile { UserPhysiologyProfile(profiles.first) }

    /// HR y-domain padded around the data and clamped to a sane range, like the vitals HR card.
    private func hrDomain(_ samples: [MetricSample]) -> ClosedRange<Double> {
        let values = samples.map(\.value).filter { $0 > 0 }
        guard let lo = values.min(), let hi = values.max() else { return 40...200 }
        let lower = max(40, min(lo - 8, 60))
        let upper = min(220, max(hi + 8, 120))
        return lower < upper ? lower...upper : 40...200
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: ActivityMeta.icon(session.type))
                .font(.system(size: 34)).foregroundStyle(PulseColors.accent)
                .frame(width: 72, height: 72).background(PulseColors.accentSoft, in: Circle())
            if savedBadge {
                Text("WORKOUT SAVED").font(.system(size: 11, weight: .medium)).tracking(1.8).foregroundStyle(PulseColors.accent)
            }
            Text(ActivityMeta.label(session.type)).font(.system(size: 24, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
            Text(dateRange).font(.system(size: 13)).foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// e.g. "Today · 7:32 – 8:05 AM" or "May 28 · 6:10 – 6:48 PM".
    private var dateRange: String {
        let time = DateFormatter(); time.dateFormat = "h:mm"
        let timeAmPm = DateFormatter(); timeAmPm.dateFormat = "h:mm a"
        let day: String
        if Calendar.current.isDateInToday(session.startedAt) {
            day = "Today"
        } else if Calendar.current.isDateInYesterday(session.startedAt) {
            day = "Yesterday"
        } else {
            let d = DateFormatter(); d.dateFormat = "MMM d"
            day = d.string(from: session.startedAt)
        }
        guard let ended = session.endedAt else { return day }
        return "\(day) · \(time.string(from: session.startedAt)) – \(timeAmPm.string(from: ended))"
    }

    @ViewBuilder
    private func chartCard<Content: View>(title: String, footnote: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                Spacer()
                if let footnote {
                    Text(footnote).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(PulseColors.textMuted)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private var hrFootnote: String? {
        guard let avg = session.avgHeartRate else { return nil }
        let mn = session.minHeartRate.map { Int($0) }
        let mx = session.maxHeartRate.map { Int($0) }
        if let mn, let mx { return "\(mn) · avg \(Int(avg)) · \(mx) bpm" }
        return "avg \(Int(avg)) bpm"
    }

    private var spo2Footnote: String? {
        session.avgSpO2.map { "avg \(Int($0))%" }
    }

    private func statsGrid(elevationGain: Double?) -> some View {
        // The hero band already shows the headline metrics (GPS: distance/duration/pace,
        // indoor: duration/active-min/calories), so the grid fills in the rest without repeating.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            if session.useGps {
                WorkoutStat(label: "Calories", value: session.calories.map { "\(Int($0))" } ?? "—")
            }
            WorkoutStat(label: "Avg HR", value: session.avgHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "Max HR", value: session.maxHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "Min HR", value: session.minHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "SpO₂", value: session.latestSpO2.map { "\(Int($0))%" } ?? "—")
            if session.useGps, let elevationGain {
                WorkoutStat(label: "Elev gain", value: String(format: "%.0f m", elevationGain))
            }
        }
    }
}

/// Three large headline stats in one card. Adapts to whether the workout used GPS:
/// outdoor → Distance · Duration · Pace; indoor → Duration · Active min · Calories.
private struct SummaryHeroBand: View {
    let session: ActivitySession
    let durationSeconds: Int?
    let units: UnitsPreference

    private struct Metric { let value: String; let label: String; let tint: Color }

    private var metrics: [Metric] {
        let dur = durationSeconds.map { ActivityMeta.duration($0) } ?? "—"
        if session.useGps {
            let d = session.distanceMeters.map { UnitsFormatter.distance(meters: $0, units: units) }
            let paceUnit = UnitsFormatter.paceUnit(units)
            let pace = ActivityMeta.pace(distanceMeters: session.distanceMeters, durationSeconds: durationSeconds, units: units)
            return [
                Metric(value: d?.value ?? "—", label: (d?.unit ?? "km").uppercased(), tint: PulseColors.distance),
                Metric(value: dur, label: "DURATION", tint: PulseColors.textPrimary),
                Metric(value: pace?.replacingOccurrences(of: " \(paceUnit)", with: "") ?? "—", label: "PACE \(paceUnit)", tint: PulseColors.accent)
            ]
        } else {
            let cals = session.calories.map { "\(Int($0))" } ?? "—"
            return [
                Metric(value: dur, label: "DURATION", tint: PulseColors.textPrimary),
                Metric(value: durationSeconds.map { "\($0 / 60)" } ?? "—", label: "ACTIVE MIN", tint: PulseColors.success),
                Metric(value: cals, label: "CALORIES", tint: PulseColors.calories)
            ]
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { index, m in
                VStack(spacing: 6) {
                    Text(m.value)
                        .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(m.tint)
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text(m.label)
                        .font(.system(size: 10, weight: .medium)).tracking(0.8)
                        .foregroundStyle(PulseColors.textMuted)
                }
                .frame(maxWidth: .infinity)
                if index != metrics.count - 1 {
                    Rectangle().fill(PulseColors.borderSubtle).frame(width: 1, height: 40)
                }
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

/// Per-kilometre splits with a relative pace bar; the fastest km is highlighted. Hidden when
/// there isn't at least one full completed kilometre.
private struct SplitsTable: View {
    let points: [ActivityGpsPoint]
    var units: UnitsPreference = .metric

    private var splitMeters: Double { units == .imperial ? 1609.344 : 1000 }
    private var splitLabel: String { units == .imperial ? "MI" : "KM" }
    private var paceUnit: String { units == .imperial ? "/mi" : "/km" }

    var body: some View {
        let splits = kmSplitSeconds(points, splitMeters: splitMeters)
        if splits.count >= 1 {
            let fastest = splits.min() ?? 0
            let slowest = splits.max() ?? 1
            VStack(alignment: .leading, spacing: 10) {
                Text("SPLITS").font(.system(size: 11, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                ForEach(Array(splits.enumerated()), id: \.offset) { index, seconds in
                    let isFastest = seconds == fastest
                    let frac = slowest > fastest ? (seconds - fastest) / (slowest - fastest) : 0
                    HStack(spacing: 12) {
                        Text("\(splitLabel) \(index + 1)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(PulseColors.textSecondary)
                            .frame(width: 44, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PulseColors.cardSoft)
                                Capsule().fill(isFastest ? PulseColors.accent : PulseColors.distance)
                                    // Faster = longer bar (invert the fraction).
                                    .frame(width: max(8, geo.size.width * (0.25 + 0.75 * (1 - frac))))
                            }
                        }
                        .frame(height: 8)
                        Text(paceLabel(seconds))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(isFastest ? PulseColors.accent : PulseColors.textPrimary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
    }

    private func paceLabel(_ secPerUnit: Double) -> String {
        // Round to whole seconds before splitting so a value like 299.85 shows 5:00, not 4:00.
        let total = Int(secPerUnit.rounded())
        return String(format: "%d:%02d %@", total / 60, total % 60, paceUnit)
    }
}

/// Time-in-zone breakdown derived from HR samples (zones by %HRmax). Hidden when no usable time
/// accrued in any zone.
private struct HRZonesCard: View {
    let samples: [MetricSample]
    let age: Int?

    var body: some View {
        let zones = hrZoneDurations(samples: samples, age: age)
        let total = zones.reduce(0) { $0 + $1.seconds }
        if total > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Text("HEART RATE ZONES").font(.system(size: 11, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                ForEach(zones.reversed()) { zone in
                    let frac = zone.seconds / total
                    let pctText = "\(Int((frac * 100).rounded()))%"
                    HStack(spacing: 10) {
                        Text(zone.name)
                            .font(.system(size: 12)).foregroundStyle(PulseColors.textSecondary)
                            .frame(width: 120, alignment: .leading).lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PulseColors.cardSoft)
                                Capsule().fill(zone.color)
                                    .frame(width: max(frac > 0 ? 6 : 0, geo.size.width * frac))
                            }
                        }
                        .frame(height: 8)
                        // Percentage of the workout spent in this zone.
                        Text(zone.seconds >= 1 ? pctText : "—")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(zone.seconds >= 1 ? PulseColors.textPrimary : PulseColors.textMuted)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
    }
}
