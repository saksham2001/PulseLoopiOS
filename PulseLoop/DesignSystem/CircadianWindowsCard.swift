import SwiftUI

/// Timing guidance hung off the user's own sleep schedule.
///
/// Lives on the **Sleep** tab: every window is derived from bedtime and wake, so it belongs beside
/// the nights it was learned from rather than on an already-dense Today grid. The reasons are
/// disclosed on tap — four times with no explanation would be instructions, not guidance.
struct CircadianWindowsCard: View {
    let windows: CircadianWindows

    @State private var expandedKind: CircadianWindows.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("YOUR DAY, TIMED")
                    .font(PulseFont.caption2.weight(.semibold)).tracking(1.0)
                    .foregroundStyle(PulseColors.textMuted)
                Text("Built from your usual \(SleepFormat.clockTime(windows.usualBedtime)) bedtime")
                    .font(PulseFont.caption.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
            }

            VStack(spacing: 0) {
                ForEach(windows.entries()) { entry in
                    row(entry)
                    if entry.kind != CircadianWindows.Kind.allCases.last {
                        Divider().overlay(PulseColors.borderSubtle)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    @ViewBuilder
    private func row(_ entry: CircadianWindows.Entry) -> some View {
        let isExpanded = expandedKind == entry.kind
        Button {
            withAnimation(.snappy) { expandedKind = isExpanded ? nil : entry.kind }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: entry.kind.symbol)
                        .font(PulseFont.footnote)
                        .foregroundStyle(PulseColors.accent)
                        .frame(width: 22)
                    Text(entry.kind.title)
                        .font(PulseFont.caption.weight(.semibold))
                        .foregroundStyle(PulseColors.textPrimary)
                    Spacer(minLength: 8)
                    Text(SleepFormat.clockTime(entry.time))
                        .font(PulseFont.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(PulseColors.textPrimary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(PulseFont.caption2.weight(.semibold))
                        .foregroundStyle(PulseColors.textMuted)
                }
                if isExpanded {
                    Text(entry.kind.reason)
                        .font(PulseFont.caption2.weight(.regular))
                        .foregroundStyle(PulseColors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 34)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.kind.title) \(SleepFormat.clockTime(entry.time)). \(entry.kind.reason)")
    }
}
