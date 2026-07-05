import SwiftUI

/// Reusable cards and controls ported from `frontend/src/components`. Visuals
/// (spacing, type, color) mirror the web Tailwind markup.

// MARK: - Hero insight card (Today)

enum ChipTone {
    case neutral, up, down, warn

    var foreground: Color {
        switch self {
        case .neutral: return PulseColors.textSecondary
        case .up: return PulseColors.success
        case .down: return PulseColors.danger
        case .warn: return PulseColors.warning
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Color.white.opacity(0.10)
        case .up: return PulseColors.success.opacity(0.15)
        case .down: return PulseColors.danger.opacity(0.15)
        case .warn: return PulseColors.warning.opacity(0.15)
        }
    }

    var border: Color {
        switch self {
        case .neutral: return PulseColors.borderSubtle
        case .up: return PulseColors.success.opacity(0.30)
        case .down: return PulseColors.danger.opacity(0.30)
        case .warn: return PulseColors.warning.opacity(0.30)
        }
    }
}

struct ToneChip: Identifiable {
    let id = UUID()
    let label: String
    let tone: ChipTone
}

struct HeroInsightCardView: View {
    let title: String
    let summary: String
    var chips: [ToneChip] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(PulseColors.textPrimary)
            Text(summary)
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(PulseColors.textSecondary)
                .padding(.top, 8)
            if !chips.isEmpty {
                FlowChips(chips: chips).padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(
                colors: [PulseColors.accent.opacity(0.18), PulseColors.spo2.opacity(0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

private struct FlowChips: View {
    let chips: [ToneChip]
    var body: some View {
        // Two-row wrap is plenty for the 3 hero chips; use an HStack that wraps.
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                Text(chip.label)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(chip.tone.foreground)
                    .background(chip.tone.background)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(chip.tone.border, lineWidth: 1))
            }
        }
    }
}

// MARK: - Coach message card (Today + Sleep)

struct CoachMessageCard: View {
    let headline: String
    let bodyText: String
    var chips: [String] = []

    init(headline: String, body: String, chips: [String] = []) {
        self.headline = headline
        self.bodyText = body
        self.chips = chips
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(PulseColors.accent).frame(width: 6, height: 6)
                    .shadow(color: PulseColors.accent.opacity(0.8), radius: 5)
                Text("COACH")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(PulseColors.textMuted)
            }
            Text(headline)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.top, 6)
            Text(bodyText)
                .font(.system(size: 14))
                .lineSpacing(5)
                .foregroundStyle(PulseColors.textSecondary)
                .padding(.top, 6)
            if !chips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 11))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(PulseColors.textSecondary)
                            .background(PulseColors.cardSoft)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
                    }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(PulseColors.accent).frame(width: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Tappable metric card with delta + sparkline (Today / Activity / Vitals)

struct MetricDelta {
    let value: Int
    let label: String
}

struct MetricCardButton: View {
    let metric: String
    let label: String
    let value: String
    var unit: String?
    var color: Color
    var delta: MetricDelta?
    var sparkline: [Double] = []
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                        .shadow(color: color.opacity(0.7), radius: 5)
                    Text(label.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(PulseColors.textMuted)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(PulseColors.textPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    if let unit {
                        Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                    }
                }
                if let delta {
                    let isUp = delta.value >= 0
                    HStack(spacing: 4) {
                        Image(systemName: isUp ? "arrow.up" : "arrow.down")
                        Text("\(isUp ? "+" : "")\(delta.value)").monospacedDigit()
                        Text(delta.label).foregroundStyle(PulseColors.textMuted)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isUp ? PulseColors.success : PulseColors.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((isUp ? PulseColors.success : PulseColors.danger).opacity(0.15))
                    .clipShape(Capsule())
                }
                Spacer(minLength: 0)
                if sparkline.count > 1 {
                    MiniSparkline(values: sparkline, color: color).frame(height: 30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .frame(height: 150)
            .background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
            // Non-tappable tiles should look identical to tappable ones — never dimmed.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(onTap != nil)
    }
}

// MARK: - Range toggles

struct RangeToggleView: View {
    @Binding var selection: MetricRange
    private let options: [(MetricRange, String)] = [(.sevenDays, "W"), (.thirtyDays, "M"), (.twelveMonths, "Y")]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let active = selection == option.0
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(active ? PulseColors.textPrimary : PulseColors.textMuted)
                        .frame(minWidth: 28)
                        .padding(.vertical, 3)
                        .background(active ? PulseColors.card : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(PulseColors.cardSoft.opacity(0.4))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

struct SleepRangeSelectorView: View {
    @Binding var selection: SleepRangeKey
    private let options: [(SleepRangeKey, String)] = [(.day, "Day"), (.week, "Week"), (.month, "Month"), (.year, "Year")]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { option in
                let active = selection == option.0
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(active ? PulseColors.textPrimary : PulseColors.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(active ? PulseColors.accent.opacity(0.15) : Color.clear)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(active ? PulseColors.accent.opacity(0.4) : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(PulseColors.cardSoft.opacity(0.4))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

// MARK: - Progress ring (Activity weekly goal)

struct ProgressRingView<Center: View>: View {
    let value: Double
    let max: Double
    var size: CGFloat = 84
    var stroke: CGFloat = 9
    var color: Color = PulseColors.steps
    @ViewBuilder var center: () -> Center

    private var progress: Double { max == 0 ? 0 : Swift.min(1, Swift.max(0, value / max)) }

    var body: some View {
        ZStack {
            Circle().stroke(PulseColors.elevated, lineWidth: stroke)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Weekly pill calendar (Activity weekly goal)

struct WeeklyDay: Identifiable {
    let id = UUID()
    let label: String
    let completed: Bool
    let isToday: Bool
}

struct WeeklyPillCalendarView: View {
    let days: [WeeklyDay]

    var body: some View {
        HStack {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    ZStack {
                        Capsule().fill(fill(day)).overlay(Capsule().stroke(border(day), lineWidth: 1))
                        Text(day.completed ? "✓" : day.isToday ? "•" : "")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(textColor(day))
                    }
                    .frame(width: 24, height: 40)
                    Text(day.label)
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(day.isToday ? PulseColors.textPrimary : PulseColors.textMuted)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func fill(_ day: WeeklyDay) -> Color {
        if day.completed { return PulseColors.success.opacity(0.20) }
        if day.isToday { return PulseColors.accent.opacity(0.20) }
        return PulseColors.cardSoft.opacity(0.4)
    }
    private func border(_ day: WeeklyDay) -> Color {
        if day.completed { return PulseColors.success.opacity(0.4) }
        if day.isToday { return PulseColors.accent }
        return PulseColors.borderSubtle
    }
    private func textColor(_ day: WeeklyDay) -> Color {
        if day.completed { return PulseColors.success }
        if day.isToday { return PulseColors.textPrimary }
        return PulseColors.textMuted
    }
}

// MARK: - Sleep hero + stage summary

struct SleepHeroCardView: View {
    let label: String
    let value: String
    var support: String?
    var score: Int?
    var scoreLabel: String?
    var noData: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(PulseColors.textMuted)
                Text(value)
                    .font(.system(size: noData ? 24 : 40, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                    .padding(.top, 4)
                if let support {
                    Text(support)
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(PulseColors.textSecondary)
                        .padding(.top, 8)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(score.map { "\($0)" } ?? "—")
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: "#8B7CFF"))
                if let scoreLabel, score != nil {
                    Text(scoreLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(PulseColors.textPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            PulseColors.card.overlay(
                RadialGradient(colors: [PulseColors.accent.opacity(0.16), .clear], center: .init(x: 0.82, y: 0), startRadius: 0, endRadius: 220)
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

struct SleepStageSummaryCardsView: View {
    var prefix: String = ""
    let deep: String
    let light: String
    let awake: String

    var body: some View {
        HStack(spacing: 12) {
            stat("\(prefix)Deep", deep, SleepStageColors.deep)
            stat("\(prefix)Light", light, SleepStageColors.light)
            stat("\(prefix)Awake", awake, SleepStageColors.awake)
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.7), radius: 5)
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(PulseColors.textMuted)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

// MARK: - Vitals detail card + small action button

struct DetailCard<Content: View>: View {
    let title: String
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.7), radius: 5)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.0)
                    .foregroundStyle(PulseColors.textMuted)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

struct QuickActionButton: View {
    let label: String
    var tone: ChipTone = .neutral
    var accent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(accent ? .white : PulseColors.textPrimary)
                .background(accent ? PulseColors.accent : PulseColors.card)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(accent ? Color.clear : PulseColors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Activity section card (chart with range toggle)

struct ActivitySectionCard<Content: View>: View {
    let title: String
    @Binding var range: MetricRange
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.0)
                    .foregroundStyle(PulseColors.textMuted)
                Spacer()
                RangeToggleView(selection: $range)
            }
            content.padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

// MARK: - Activity metadata (icon + label + helper by type)

/// Typed activity metadata, ported from `frontend/src/components/activity/activityMeta.ts`.
struct ActivityKind: Identifiable {
    let type: String
    let label: String
    let helper: String
    let symbol: String
    let gpsCapable: Bool
    var id: String { type }
}

enum ActivityMeta {
    /// Canonical types in display order (matches web `ACTIVITY_ORDER`).
    static let order = ["walk", "run", "cycle", "gym", "squash", "sport", "yoga", "dance", "hike", "other"]

    private static let table: [String: ActivityKind] = [
        "walk":   ActivityKind(type: "walk",   label: "Walk",   helper: "Outdoor or indoor walk",     symbol: "figure.walk",          gpsCapable: true),
        "run":    ActivityKind(type: "run",    label: "Run",    helper: "Road, treadmill, or intervals", symbol: "figure.run",        gpsCapable: true),
        "cycle":  ActivityKind(type: "cycle",  label: "Cycle",  helper: "Bike ride or stationary",    symbol: "figure.outdoor.cycle", gpsCapable: true),
        "gym":    ActivityKind(type: "gym",    label: "Gym",    helper: "Strength or machines",       symbol: "dumbbell.fill",        gpsCapable: false),
        "squash": ActivityKind(type: "squash", label: "Squash", helper: "Court session",              symbol: "figure.tennis",        gpsCapable: false),
        "sport":  ActivityKind(type: "sport",  label: "Sport",  helper: "General sport",              symbol: "figure.soccer",        gpsCapable: true),
        "yoga":   ActivityKind(type: "yoga",   label: "Yoga",   helper: "Mobility or stretching",     symbol: "figure.yoga",          gpsCapable: false),
        "dance":  ActivityKind(type: "dance",  label: "Dance",  helper: "Studio, cardio, or freestyle", symbol: "figure.dance",       gpsCapable: false),
        "hike":   ActivityKind(type: "hike",   label: "Hike",   helper: "Trail or long walk",         symbol: "figure.hiking",        gpsCapable: true),
        "other":  ActivityKind(type: "other",  label: "Other",  helper: "Custom activity",            symbol: "sparkles",             gpsCapable: false)
    ]

    /// Legacy seed/record names → canonical types.
    private static let aliases: [String: String] = [
        "outdoor_run": "run", "ride": "cycle", "cycling": "cycle", "strength": "gym"
    ]

    static func meta(_ type: String) -> ActivityKind {
        let canonical = aliases[type] ?? type
        return table[canonical] ?? ActivityKind(
            type: canonical,
            label: canonical.replacingOccurrences(of: "_", with: " ").capitalized,
            helper: "Custom activity",
            symbol: "sparkles",
            gpsCapable: false
        )
    }

    static var allKinds: [ActivityKind] { order.compactMap { table[$0] } }

    static func icon(_ type: String) -> String { meta(type).symbol }
    static func label(_ type: String) -> String { meta(type).label }

    /// H:MM:SS or M:SS.
    static func duration(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// Pace from distance + duration; nil when not meaningful. In the user's units (min/km or min/mi),
    /// defaulting to metric so existing callers compile unchanged.
    static func pace(distanceMeters: Double?, durationSeconds: Int?, units: UnitsPreference = .metric) -> String? {
        guard let distanceMeters, let durationSeconds, distanceMeters >= 50 else { return nil }
        let paceSecPerKm = Double(durationSeconds) / (distanceMeters / 1000)
        let paceSec = UnitsFormatter.paceSeconds(perKmSeconds: paceSecPerKm, units: units)
        // Round to whole seconds first, then split — otherwise a value like 299.85 renders
        // "4:00" (minute truncated, seconds rounded up to 60) instead of "5:00".
        let total = Int(paceSec.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d %@", m, s, UnitsFormatter.paceUnit(units))
    }
}

// MARK: - Workout row (today list + history)

struct ActivityWorkoutRow: View {
    let session: ActivitySession
    var units: UnitsPreference = .metric
    var onTap: (() -> Void)?

    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 12) {
                Image(systemName: ActivityMeta.icon(session.type))
                    .font(.system(size: 18))
                    .foregroundStyle(PulseColors.accent)
                    .frame(width: 44, height: 44)
                    .background(PulseColors.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(ActivityMeta.label(session.type))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PulseColors.textPrimary)
                        Spacer()
                        Text(SleepFormat.clockTime(session.startedAt))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(PulseColors.textMuted)
                    }
                    HStack(spacing: 12) {
                        Text(durationLabel).font(.system(size: 12).monospacedDigit())
                        if let distance = session.distanceMeters {
                            let d = UnitsFormatter.distance(meters: distance, units: units)
                            Text("\(d.value) \(d.unit)").font(.system(size: 12).monospacedDigit())
                        }
                        if let hr = session.avgHeartRate {
                            Text("\(Int(hr)) bpm avg").font(.system(size: 12).monospacedDigit())
                        }
                    }
                    .foregroundStyle(PulseColors.textMuted)
                }
                if session.useGps {
                    Image(systemName: "map").font(.system(size: 14)).foregroundStyle(PulseColors.textMuted)
                }
            }
            .padding(16)
            .background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    private var durationLabel: String {
        guard let ended = session.endedAt else { return "—" }
        let seconds = Int(ended.timeIntervalSince(session.startedAt) - session.totalPauseSeconds)
        let m = seconds / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}

// MARK: - Sync progress bar

/// A thin, full-width indeterminate progress bar shown under the app header while the ring is
/// syncing. We only have stage labels (not a percentage), so this is indeterminate: an accent
/// segment sweeps left→right over a recessed track. Under Reduce Motion it degrades to a steady
/// pulsing full-width fill (no horizontal travel). Visuals use the existing `PulseColors` tokens
/// and the `ConnectionStatusPill` animation idiom.
struct SyncProgressBar: View {
    /// Bar thickness in points — deliberately thin so it reads as a status accent, not a control.
    var height: CGFloat = 3
    /// Fraction of the track width the moving segment occupies.
    private let segmentFraction: CGFloat = 0.4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let segmentWidth = trackWidth * segmentFraction

            ZStack(alignment: .leading) {
                Rectangle().fill(PulseColors.elevated)

                if reduceMotion {
                    // No travel — a gentle opacity pulse on a full-width fill.
                    Rectangle()
                        .fill(PulseColors.accent)
                        .opacity(animate ? 0.55 : 1.0)
                } else {
                    Capsule()
                        .fill(PulseColors.accent)
                        .frame(width: segmentWidth)
                        // Sweep from just off the left edge to just off the right edge.
                        .offset(x: animate ? (trackWidth - segmentWidth) : 0)
                }
            }
            .frame(height: height)
            .clipped()
        }
        .frame(height: height)
        .onAppear {
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { animate = true }
            } else {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { animate = true }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Syncing")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
