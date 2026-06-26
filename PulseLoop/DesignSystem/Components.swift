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
        case .neutral: return PulseColors.chipFill
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

    /// Non-color cue so trend direction is legible for color-blind users.
    var symbol: String? {
        switch self {
        case .neutral: return nil
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .warn: return "exclamationmark"
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
            EyebrowLabel("Today's insight")
                .padding(.bottom, 10)
            Text(title)
                .font(PulseFont.titleSemibold(28))
                .foregroundStyle(PulseColors.textPrimary)
            Text(summary)
                .font(PulseFont.body(15))
                .lineSpacing(4)
                .foregroundStyle(PulseColors.textSecondary)
                .padding(.top, 8)
            if !chips.isEmpty {
                FlowChips(chips: chips).padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.xLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PulseRadius.xLarge, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
    }
}

private struct FlowChips: View {
    let chips: [ToneChip]
    var body: some View {
        // Two-row wrap is plenty for the 3 hero chips; use an HStack that wraps.
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                HStack(spacing: 3) {
                    if let symbol = chip.tone.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(chip.label)
                        .font(PulseFont.bodyMedium(12))
                }
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
                    .accessibilityHidden(true)
                Text("COACH")
                    .font(PulseFont.bodyMedium(10))
                    .tracking(1.8)
                    .foregroundStyle(PulseColors.textMuted)
            }
            Text(headline)
                .font(PulseFont.bodySemibold(14))
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.top, 6)
            Text(bodyText)
                .font(PulseFont.body(14))
                .lineSpacing(5)
                .foregroundStyle(PulseColors.textSecondary)
                .padding(.top, 6)
            if !chips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(PulseFont.body(11))
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

    private var accessibilityDescription: String {
        var parts = ["\(label): \(value)"]
        if let unit { parts.append(unit) }
        if let delta {
            let dir = delta.value >= 0 ? "up" : "down"
            parts.append("\(dir) \(abs(delta.value)) \(delta.label)")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button {
            HapticService.impact(.light)
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                        .shadow(color: color.opacity(0.7), radius: 5)
                        .accessibilityHidden(true)
                    Text(label.uppercased())
                        .font(PulseFont.bodyMedium(11))
                        .tracking(0.6)
                        .foregroundStyle(PulseColors.textMuted)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(PulseFont.titleSemibold(30))
                        .monospacedDigit()
                        .foregroundStyle(PulseColors.textPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    if let unit {
                        Text(unit).font(PulseFont.bodyMedium(12)).foregroundStyle(PulseColors.textMuted)
                    }
                }
                if let delta {
                    let isUp = delta.value >= 0
                    HStack(spacing: 4) {
                        Image(systemName: isUp ? "arrow.up" : "arrow.down")
                        Text("\(isUp ? "+" : "")\(delta.value)").monospacedDigit()
                        Text(delta.label).foregroundStyle(PulseColors.textMuted)
                    }
                    .font(PulseFont.bodyMedium(11))
                    .foregroundStyle(isUp ? PulseColors.success : PulseColors.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((isUp ? PulseColors.success : PulseColors.danger).opacity(0.15))
                    .clipShape(Capsule())
                }
                Spacer(minLength: 0)
                if sparkline.count > 1 {
                    MiniSparkline(values: sparkline, color: color).frame(height: 30)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            // Minimum height keeps the grid tidy but lets the card grow with larger text.
            .frame(minHeight: 150)
            .background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: PulseRadius.large, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PulseRadius.large, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
            // Non-tappable tiles should look identical to tappable ones  -  never dimmed.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(onTap != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(onTap != nil ? .isButton : [])
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
                Button {
                    if !active { HapticService.selection() }
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(PulseFont.bodySemibold(10))
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
                Button {
                    if !active { HapticService.selection() }
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(PulseFont.bodySemibold(12))
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
                        Group {
                            if day.completed {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            } else if day.isToday {
                                Circle().fill(textColor(day)).frame(width: 4, height: 4)
                            }
                        }
                        .foregroundStyle(textColor(day))
                    }
                    .frame(width: 24, height: 40)
                    Text(day.label)
                        .font(PulseFont.bodyMedium(10))
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
                    .font(PulseFont.bodyMedium(11))
                    .tracking(1.8)
                    .foregroundStyle(PulseColors.textMuted)
                Text(value)
                    .font(PulseFont.titleSemibold(noData ? 24 : 40))
                    .monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                    .padding(.top, 4)
                if let support {
                    Text(support)
                        .font(PulseFont.body(14).monospacedDigit())
                        .foregroundStyle(PulseColors.textSecondary)
                        .padding(.top, 8)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(score.map { "\($0)" } ?? " - ")
                    .font(PulseFont.titleSemibold(40))
                    .monospacedDigit()
                    .foregroundStyle(PulseColors.sleepScore)
                if let scoreLabel, score != nil {
                    Text(scoreLabel)
                        .font(PulseFont.bodyMedium(14))
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
                    .accessibilityHidden(true)
                Text(label.uppercased())
                    .font(PulseFont.bodyMedium(10))
                    .tracking(0.6)
                    .foregroundStyle(PulseColors.textMuted)
                    .lineLimit(1)
            }
            Text(value)
                .font(PulseFont.titleSemibold(22))
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
                    .accessibilityHidden(true)
                Text(title.uppercased())
                    .font(PulseFont.bodyMedium(11))
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
        Button {
            HapticService.impact(.light)
            action()
        } label: {
            Text(label)
                .font(PulseFont.bodySemibold(14))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(accent ? PulseColors.background : PulseColors.textPrimary)
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
                    .font(PulseFont.bodyMedium(11))
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
    static let order = ["walk", "run", "cycle", "gym", "squash", "sport", "yoga", "hike", "other"]

    private static let table: [String: ActivityKind] = [
        "walk":   ActivityKind(type: "walk",   label: "Walk",   helper: "Outdoor or indoor walk",     symbol: "figure.walk",          gpsCapable: true),
        "run":    ActivityKind(type: "run",    label: "Run",    helper: "Road, treadmill, or intervals", symbol: "figure.run",        gpsCapable: true),
        "cycle":  ActivityKind(type: "cycle",  label: "Cycle",  helper: "Bike ride or stationary",    symbol: "figure.outdoor.cycle", gpsCapable: true),
        "gym":    ActivityKind(type: "gym",    label: "Gym",    helper: "Strength or machines",       symbol: "dumbbell.fill",        gpsCapable: false),
        "squash": ActivityKind(type: "squash", label: "Squash", helper: "Court session",              symbol: "figure.tennis",        gpsCapable: false),
        "sport":  ActivityKind(type: "sport",  label: "Sport",  helper: "General sport",              symbol: "figure.soccer",        gpsCapable: true),
        "yoga":   ActivityKind(type: "yoga",   label: "Yoga",   helper: "Mobility or stretching",     symbol: "figure.yoga",          gpsCapable: false),
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

    /// Pace in min/km from distance + duration; nil when not meaningful.
    static func pace(distanceMeters: Double?, durationSeconds: Int?) -> String? {
        guard let distanceMeters, let durationSeconds, distanceMeters >= 50 else { return nil }
        let paceSecPerKm = Double(durationSeconds) / (distanceMeters / 1000)
        let m = Int(paceSecPerKm) / 60
        let s = Int(paceSecPerKm.rounded()) % 60
        return String(format: "%d:%02d /km", m, s)
    }
}

// MARK: - Hero Card (black "just one thing" next-action)

/// The canonical black hero card carrying a screen's single most-important next
/// action. Matches the Home "JUST THIS ONE THING" block: solid ink fill (the
/// monochrome `accent` token → #161616 light / white dark), inverse text, an
/// uppercase eyebrow, a Newsreader title, optional support line, and up to two
/// actions (filled = inverse-on-ink, quiet = outlined). Compose this instead of
/// re-drawing a black RoundedRectangle per screen.
struct HeroCard: View {
    let eyebrow: String
    let title: String
    var support: String?
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    /// Optional SF Symbol shown in the eyebrow row (e.g. checkmark when done).
    var eyebrowSymbol: String?
    /// When true the eyebrow dot/symbol uses the success tint (e.g. completed).
    var done: Bool = false

    /// Ink background and its inverse foreground, derived from the accent token so
    /// the card flips correctly in dark mode (white card, ink text).
    private var ink: Color { PulseColors.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let eyebrowSymbol {
                    Image(systemName: eyebrowSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(done ? PulseColors.success : PulseColors.background)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(done ? PulseColors.success : PulseColors.background)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(eyebrow)
                    .font(PulseFont.bodyMedium(11))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PulseColors.background.opacity(0.7))
            }

            Text(title)
                .font(PulseFont.titleMedium(24))
                .foregroundStyle(PulseColors.background)
                .fixedSize(horizontal: false, vertical: true)

            if let support {
                Text(support)
                    .font(PulseFont.body(14))
                    .foregroundStyle(PulseColors.background.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if primaryTitle != nil || secondaryTitle != nil {
                HStack(spacing: 8) {
                    if let primaryTitle, let primaryAction {
                        Button {
                            HapticService.impact(.medium)
                            primaryAction()
                        } label: {
                            Text(primaryTitle)
                                .font(PulseFont.bodySemibold(15))
                                .foregroundStyle(ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(PulseColors.background)
                                .clipShape(RoundedRectangle(cornerRadius: PulseRadius.medium, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button {
                            HapticService.impact(.light)
                            secondaryAction()
                        } label: {
                            Text(secondaryTitle)
                                .font(PulseFont.bodySemibold(15))
                                .foregroundStyle(PulseColors.background)
                                .padding(.horizontal, 18)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: PulseRadius.medium, style: .continuous)
                                        .stroke(PulseColors.background.opacity(0.32), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(ink)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.xLarge, style: .continuous))
    }
}

// MARK: - Icon Tile Row (leading SF-Symbol tile + title/subtitle + accessory)

/// The canonical list row: an SF Symbol in a `fillSubtle` rounded tile, a title +
/// optional subtitle, an optional trailing value, and a chevron when it drills in.
/// Use inside a `PulseCard`; stack rows with `IconTileRow.divider` between them.
struct IconTileRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var trailingText: String?
    var showsChevron: Bool = true
    var action: (() -> Void)?

    private var rowContent: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(PulseColors.textPrimary)
                .frame(width: 40, height: 40)
                .background(PulseColors.fillSubtle)
                .clipShape(RoundedRectangle(cornerRadius: PulseRadius.medium, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PulseFont.bodySemibold(15))
                    .foregroundStyle(PulseColors.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(PulseFont.body(13))
                        .foregroundStyle(PulseColors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let trailingText {
                Text(trailingText)
                    .font(PulseFont.bodyMedium(13))
                    .monospacedDigit()
                    .foregroundStyle(PulseColors.textSecondary)
            }
            if showsChevron && action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PulseColors.textFaint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: PulseLayout.minTapTarget)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let action {
            Button {
                HapticService.impact(.light)
                action()
            } label: { rowContent }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
        } else {
            rowContent
        }
    }

    /// Hairline divider to place between stacked rows inside a card.
    static var divider: some View {
        Rectangle().fill(PulseColors.borderHairline).frame(height: 1)
    }
}

// MARK: - Segmented Control (one shared monochrome control)

/// The single shared segmented control (Schedule/Protocol/Wellness, Category,
/// Timing, etc.): gray `fillSubtle` track, white selected pill with a soft shadow,
/// `PulseFont.bodySemibold`. Identical everywhere it appears. Generic over any
/// `Hashable` whose label is provided by `title`.
struct SegmentedControl<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    var title: (T) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    if !isSelected { HapticService.selection() }
                    withAnimation(.snappy(duration: 0.25)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(PulseFont.bodySemibold(14))
                        .foregroundStyle(isSelected ? PulseColors.textPrimary : PulseColors.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: PulseRadius.small, style: .continuous)
                                    .fill(PulseColors.background)
                                    .shadow(color: Color.black.opacity(0.06), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(PulseColors.fillSubtle)
        .clipShape(RoundedRectangle(cornerRadius: PulseRadius.medium, style: .continuous))
    }
}

// MARK: - Empty State Card (designed first-action invitation)

/// A designed empty state on the canonical card: a neutral icon tile, a Newsreader
/// title, a body line, and an optional black call-to-action. Use on any data
/// surface that can be empty instead of a bare "No data" label.
struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        PulseCard(padding: 24, radius: PulseRadius.large) {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(width: 56, height: 56)
                    .background(PulseColors.fillSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: PulseRadius.large, style: .continuous))
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(title)
                        .font(PulseFont.titleMedium(20))
                        .foregroundStyle(PulseColors.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(PulseFont.body(14))
                        .foregroundStyle(PulseColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                if let actionTitle, let action {
                    Button {
                        HapticService.impact(.light)
                        action()
                    } label: {
                        Text(actionTitle)
                            .font(PulseFont.bodySemibold(15))
                            .foregroundStyle(PulseColors.background)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(PulseColors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: PulseRadius.medium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Shared component previews

#Preview("Shared components") {
    ScrollView {
        VStack(spacing: 16) {
            HeroCard(
                eyebrow: "Just this one thing",
                title: "Take your evening stack",
                support: "2 items · 2 minutes · then you can wind down",
                primaryTitle: "Start", primaryAction: {},
                secondaryTitle: "Not now", secondaryAction: {}
            )
            PulseCard {
                VStack(spacing: 0) {
                    IconTileRow(icon: "pills.fill", title: "BPC-157 · Morning stack", subtitle: "Medication & supplements", trailingText: "7:30a", action: {})
                    IconTileRow.divider
                    IconTileRow(icon: "moon.fill", title: "Sleep", subtitle: "Last night's score", action: {})
                }
            }
            SegmentedControlPreview()
            EmptyStateCard(icon: "tray", title: "Nothing here yet", message: "Log your first entry to see it appear here.", actionTitle: "Add entry", action: {})
        }
        .padding(16)
    }
    .background(PulseColors.canvas)
}

private struct SegmentedControlPreview: View {
    @State private var sel = "Schedule"
    var body: some View {
        SegmentedControl(selection: $sel, options: ["Schedule", "Protocol", "Wellness"]) { $0 }
    }
}

// MARK: - Workout row (today list + history)

struct ActivityWorkoutRow: View {
    let session: ActivitySession
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            HapticService.impact(.light)
            onTap?()
        } label: {
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
                            .font(PulseFont.bodySemibold(14))
                            .foregroundStyle(PulseColors.textPrimary)
                        Spacer()
                        Text(SleepFormat.clockTime(session.startedAt))
                            .font(PulseFont.body(11).monospacedDigit())
                            .foregroundStyle(PulseColors.textMuted)
                    }
                    HStack(spacing: 12) {
                        Text(durationLabel).font(PulseFont.body(12).monospacedDigit())
                        if let distance = session.distanceMeters {
                            Text(String(format: "%.2f km", distance / 1000)).font(PulseFont.body(12).monospacedDigit())
                        }
                        if let hr = session.avgHeartRate {
                            Text("\(Int(hr)) bpm avg").font(PulseFont.body(12).monospacedDigit())
                        }
                    }
                    .foregroundStyle(PulseColors.textMuted)
                }
                if session.useGps {
                    Image(systemName: "map").font(.system(size: 14)).foregroundStyle(PulseColors.textMuted)
                        .accessibilityLabel("Has GPS route")
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
        guard let ended = session.endedAt else { return " - " }
        let seconds = Int(ended.timeIntervalSince(session.startedAt) - session.totalPauseSeconds)
        let m = seconds / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}
