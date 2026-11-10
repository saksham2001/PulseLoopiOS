import SwiftUI

/// The ‹ older · label · newer › stepper Sleep's Day view introduced, shared by the Activity screen
/// and the vitals detail screen (issues #76 / #102). Glass chevrons that mute at a bound, a two-line
/// label (relative + absolute) that never changes height, and an optional tap on the label (a date
/// picker on Activity).
struct PeriodNavigationHeader: View {
    let labels: PeriodNavLabels.Labels
    let canGoOlder: Bool
    let canGoNewer: Bool
    var olderLabel = "Previous day"
    var newerLabel = "Next day"
    var onOlder: () -> Void
    var onNewer: () -> Void
    /// When set, the label is a button (with a ▾ glyph) — e.g. opens a date picker.
    var onLabelTap: (() -> Void)?
    /// Drives the label's cross-fade when the shown period changes.
    var animationValue: AnyHashable = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            chevron("chevron.left", enabled: canGoOlder, label: olderLabel,
                    disabledHint: "Earliest recorded data", action: onOlder)
            Spacer(minLength: 4)
            Group {
                if let onLabelTap {
                    Button(action: onLabelTap) { label }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens a date picker to choose a day")
                } else {
                    label   // Not a disabled Button: that would dim the label.
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(labels.spoken)
            Spacer(minLength: 4)
            chevron("chevron.right", enabled: canGoNewer, label: newerLabel,
                    disabledHint: "You're viewing the most recent period", action: onNewer)
        }
        .frame(maxWidth: .infinity)
    }

    private var label: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text(labels.primary)
                    .font(PulseFont.headline)
                    .foregroundStyle(PulseColors.textPrimary)
                    .contentTransition(.opacity)
                if onLabelTap != nil {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PulseColors.textMuted)
                }
            }
            // Always render the subtitle line (a space when empty) so the content below never
            // shifts vertically as the label crosses Today/Yesterday/weekday bounds.
            Text(labels.secondary.isEmpty ? " " : labels.secondary)
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)
                .contentTransition(.opacity)
        }
        .frame(minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : PulseMotion.spring, value: animationValue)
    }

    /// A ≥44pt tappable chevron; glass disc only while enabled, muted glyph when at a bound.
    private func chevron(_ system: String, enabled: Bool, label: String,
                         disabledHint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(PulseFont.headline.weight(.semibold))
                .foregroundStyle(enabled ? PulseColors.textPrimary : PulseColors.textMuted)
                .frame(width: 44, height: 44)
                .background {
                    if enabled {
                        Circle().fill(Color.clear).frame(width: 36, height: 36).pulseGlass(Circle(), interactive: true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.pulseTap)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityHint(enabled ? "" : disabledHint)
    }
}

/// Header strings for a shown day / week / month. Pure: `now` and the calendar are injected.
enum PeriodNavLabels {
    struct Labels: Equatable {
        /// Relative where it helps ("Today", "Yesterday", "This week").
        let primary: String
        /// The absolute date(s), or empty.
        let secondary: String
        /// Full, unabbreviated phrase for VoiceOver.
        let spoken: String
    }

    static func labels(_ period: VitalPeriod, anchor: Date, now: Date = Date(),
                       calendar: Calendar = .current) -> Labels {
        switch period {
        case .day: return day(anchor, now: now, calendar: calendar)
        case .week: return week(anchor, now: now, calendar: calendar)
        case .month: return month(anchor, now: now, calendar: calendar)
        }
    }

    /// Mirrors Sleep's Day header: Today / Yesterday / weekday (within a week) / date.
    static func day(_ shownDay: Date, now: Date = Date(), calendar: Calendar = .current) -> Labels {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: shownDay)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        let absolute = format(day, .dateTime.weekday(.abbreviated).month(.abbreviated).day(), calendar)
        let full = format(day, .dateTime.weekday(.wide).month(.wide).day(), calendar)
        let spokenFull = sameYear ? full : format(day, .dateTime.weekday(.wide).month(.wide).day().year(), calendar)
        switch daysAgo {
        case 0: return Labels(primary: "Today", secondary: absolute, spoken: "Today, \(full)")
        case 1: return Labels(primary: "Yesterday", secondary: absolute, spoken: "Yesterday, \(full)")
        case 2..<7:
            return Labels(primary: format(day, .dateTime.weekday(.wide), calendar),
                          secondary: format(day, .dateTime.month(.abbreviated).day(), calendar),
                          spoken: spokenFull)
        default:
            let primary = sameYear ? absolute : format(day, .dateTime.month(.abbreviated).day().year(), calendar)
            return Labels(primary: primary, secondary: "", spoken: spokenFull)
        }
    }

    static func week(_ anchor: Date, now: Date = Date(), calendar: Calendar = .current) -> Labels {
        let window = VitalPeriods.window(.week, anchor: anchor, calendar: calendar)
        let last = calendar.date(byAdding: .day, value: -1, to: window.end) ?? window.start
        let short = Date.FormatStyle.dateTime.month(.abbreviated).day()
        let span = "\(format(window.start, short, calendar)) – \(format(last, short, calendar))"
        let spokenSpan = "\(format(window.start, .dateTime.month(.wide).day(), calendar)) to \(format(last, .dateTime.month(.wide).day(), calendar))"
        if window.start == VitalPeriods.latestAnchor(.week, now: now, calendar: calendar) {
            return Labels(primary: "Last 7 days", secondary: span, spoken: "Last 7 days, \(spokenSpan)")
        }
        let sameYear = calendar.component(.year, from: last) == calendar.component(.year, from: now)
        return Labels(primary: span, secondary: sameYear ? "" : format(last, .dateTime.year(), calendar), spoken: spokenSpan)
    }

    static func month(_ anchor: Date, now: Date = Date(), calendar: Calendar = .current) -> Labels {
        let name = format(anchor, .dateTime.month(.wide).year(), calendar)
        if anchor == VitalPeriods.latestAnchor(.month, now: now, calendar: calendar) {
            return Labels(primary: "This month", secondary: name, spoken: "This month, \(name)")
        }
        return Labels(primary: name, secondary: "", spoken: name)
    }

    private static func format(_ date: Date, _ style: Date.FormatStyle, _ calendar: Calendar) -> String {
        var style = style
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
