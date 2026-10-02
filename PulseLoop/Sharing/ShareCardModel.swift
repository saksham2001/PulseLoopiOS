import SwiftUI
import SwiftData

// MARK: - Share card model

/// Export format for the workout share card. `pointSize` is the SwiftUI layout size;
/// the renderer multiplies by `scale` for a crisp bitmap (1080×1920 / 1080×1080 px).
enum ShareCardFormat: String, CaseIterable {
    case story
    case square

    var pointSize: CGSize {
        switch self {
        case .story: return CGSize(width: 360, height: 640)
        case .square: return CGSize(width: 360, height: 360)
        }
    }

    var scale: CGFloat { 3 }

    var pixelSize: CGSize {
        CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }
}

/// One formatted stat on the card ("PACE" / "5:12" / "/km"). `unit` is nil for unitless
/// values (duration) and for missing ("—") stats.
struct ShareCardStat: Equatable {
    let label: String
    let value: String
    let unit: String?
}

/// Route coordinate as a plain Equatable value so `[ShareRouteCoordinate]` arrays compare
/// (CLLocationCoordinate2D isn't Equatable, and tuples don't synthesize it).
struct ShareRouteCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

/// One normalized slice of the HR-zone bar (fractions across a card sum to 1).
struct ShareZoneSegment: Equatable {
    let color: Color
    let fraction: Double
}

/// Everything the share-card view needs, fully formatted up front — the renderer does zero
/// math or unit logic, so the card stays trivially snapshot-testable.
struct ShareCardModel {
    let activityLabel: String
    let symbol: String
    let accent: Color
    /// e.g. "SAT · JUL 26 · 7:32 AM"
    let dateHeadline: String
    /// e.g. "July 26, 2026"
    let dateFooter: String
    let heroStat: ShareCardStat
    let statRows: [[ShareCardStat]]
    let routeCoordinates: [ShareRouteCoordinate]
    let zoneSegments: [ShareZoneSegment]
    /// e.g. "AVG 152 · MAX 171 BPM"; nil when the session has no HR summary.
    let hrCaption: String?
    let hasRoute: Bool

    static func build(session: ActivitySession, data: WorkoutSummaryData, units: UnitsPreference, age: Int?) -> ShareCardModel {
        let meta = ActivityMeta.meta(session.type)
        // Same honesty rule as the summary hero: a session edited to a GPS type without a
        // recorded route keeps the indoor treatment.
        let coordinates = (session.useGps && meta.gpsCapable)
            ? data.accepted.map { ShareRouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            : []
        let hero: ShareCardStat
        if session.useGps, meta.gpsCapable, let meters = session.distanceMeters {
            let d = UnitsFormatter.distance(meters: meters, units: units)
            hero = ShareCardStat(label: "DISTANCE", value: d.value, unit: d.unit)
        } else {
            hero = stat("DURATION", data.durationSeconds.map(ActivityMeta.duration))
        }
        return ShareCardModel(
            activityLabel: meta.label.uppercased(),
            symbol: meta.symbol,
            accent: accent(for: session.type),
            dateHeadline: dateHeadline(session.startedAt),
            dateFooter: dateFooter(session.startedAt),
            heroStat: hero,
            statRows: statRows(session: session, data: data, units: units),
            routeCoordinates: coordinates,
            zoneSegments: zoneSegments(hr: data.hr, age: age),
            hrCaption: hrCaption(session),
            hasRoute: coordinates.count >= 2
        )
    }

    /// Per-type accent, reusing existing palette tokens (no new hex values).
    static func accent(for type: String) -> Color {
        switch ActivityMeta.meta(type).type {
        case "run": return PulseColors.heartRate
        case "walk": return PulseColors.success
        case "cycle": return PulseColors.distance
        case "hike": return PulseColors.warning
        case "gym": return PulseColors.accent
        case "yoga": return PulseColors.temperature
        case "dance": return PulseColors.fatigue
        case "squash": return PulseColors.calories
        case "sport": return PulseColors.info
        default: return PulseColors.accent
        }
    }

    // MARK: - Stat rows

    private static func statRows(session: ActivitySession, data: WorkoutSummaryData, units: UnitsPreference) -> [[ShareCardStat]] {
        let set = ActivityMetricSet.set(for: session.type)
        let duration = stat("DURATION", data.durationSeconds.map(ActivityMeta.duration))
        let avgHR = stat("AVG HR", session.avgHeartRate.map { "\(Int($0))" }, unit: "BPM")
        let maxHR = stat("MAX HR", session.maxHeartRate.map { "\(Int($0))" }, unit: "BPM")
        let calories = stat("CALORIES", session.calories.map { "\(Int($0))" }, unit: "KCAL")
        let rows: [[ShareCardStat]]
        switch ActivityMeta.meta(session.type).type {
        case "run", "walk", "hike":
            var second = [calories]
            // Elevation slot only when the type surfaces it AND the route produced a gain
            // (matches the summary stats grid).
            if set.showsElevation, let gain = data.elevation?.gain {
                second.append(ShareCardStat(label: "ELEV GAIN", value: String(format: "%.0f", gain), unit: "M"))
            }
            second.append(maxHR)
            rows = [[duration, paceStat(session: session, data: data, units: units), avgHR], second]
        case "cycle":
            var second = [calories]
            if set.showsElevation, let gain = data.elevation?.gain {
                second.append(ShareCardStat(label: "ELEV GAIN", value: String(format: "%.0f", gain), unit: "M"))
            }
            second.append(maxHR)
            rows = [[duration, speedStat(session: session, data: data, units: units), avgHR], second]
        default:
            rows = [[calories, avgHR, maxHR]]
        }
        // A row of nothing but placeholders is visual noise — drop it.
        return rows.filter { row in row.contains { $0.value != "—" } }
    }

    private static func paceStat(session: ActivitySession, data: WorkoutSummaryData, units: UnitsPreference) -> ShareCardStat {
        let paceUnit = UnitsFormatter.paceUnit(units)
        let pace = ActivityMeta.pace(distanceMeters: session.distanceMeters, durationSeconds: data.durationSeconds, units: units)
        return stat("PACE", pace?.replacingOccurrences(of: " \(paceUnit)", with: ""), unit: paceUnit)
    }

    private static func speedStat(session: ActivitySession, data: WorkoutSummaryData, units: UnitsPreference) -> ShareCardStat {
        var value: String?
        if let meters = session.distanceMeters, let seconds = data.durationSeconds, seconds > 0, meters >= 50 {
            let mps = meters / Double(seconds)
            value = String(format: "%.1f", units == .imperial ? mps * 2.23694 : mps * 3.6)
        }
        return stat("AVG SPEED", value, unit: units == .imperial ? "MPH" : "KM/H")
    }

    private static func stat(_ label: String, _ value: String?, unit: String? = nil) -> ShareCardStat {
        ShareCardStat(label: label, value: value ?? "—", unit: value == nil ? nil : unit)
    }

    // MARK: - HR zones + caption

    private static func zoneSegments(hr: [MetricSample], age: Int?) -> [ShareZoneSegment] {
        guard !hr.isEmpty else { return [] }
        let zones = hrZoneDurations(samples: hr, age: age)
        let total = zones.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return [] }
        return zones.filter { $0.seconds > 0 }
            .map { ShareZoneSegment(color: $0.color, fraction: $0.seconds / total) }
    }

    private static func hrCaption(_ session: ActivitySession) -> String? {
        switch (session.avgHeartRate, session.maxHeartRate) {
        case let (avg?, max?): return "AVG \(Int(avg)) · MAX \(Int(max)) BPM"
        case let (avg?, nil): return "AVG \(Int(avg)) BPM"
        case let (nil, max?): return "MAX \(Int(max)) BPM"
        default: return nil
        }
    }

    // MARK: - Dates

    private static func dateHeadline(_ date: Date) -> String {
        let dow = DateFormatter.localizedTemplate("EEE")
        let monthDay = DateFormatter.localizedTemplate("MMMd")
        let time = DateFormatter.localizedTemplate("jmm")
        return "\(dow.string(from: date).uppercased()) · \(monthDay.string(from: date).uppercased()) · \(time.string(from: date))"
    }

    private static func dateFooter(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }
}
