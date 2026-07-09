import SwiftUI

/// One tappable Settings category. `id` is the title, which is unique within the Settings list.
struct SettingsRowItem: Identifiable {
    var id: String { title }
    let icon: String
    let tint: Color
    let title: String
    var trailingValue: String? = nil
    /// VoiceOver hint; defaults to "Opens <title>" since every current row pushes a detail screen.
    /// A future non-navigating row can override this.
    var accessibilityHint: String? = nil
    let action: () -> Void
}

/// An uppercase section header plus a rounded card wrapping its rows with hairline dividers.
/// Renders nothing when `rows` is empty, so a fully gated-off group leaves no empty header.
/// Where a row sits in its section — drives which corners its press highlight rounds.
enum RowPosition {
    case only, first, middle, last
}

struct SettingsSection: View {
    let title: String
    let rows: [SettingsRowItem]

    private func rowPosition(_ index: Int) -> RowPosition {
        if rows.count == 1 { return .only }
        if index == 0 { return .first }
        if index == rows.count - 1 { return .last }
        return .middle
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .textCase(.uppercase)
                    .font(PulseFont.footnote.weight(.semibold))
                    .tracking(1.0)
                    .foregroundStyle(PulseColors.textSecondary)
                    .padding(.leading, 16)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        SettingsRow(item: row, position: rowPosition(index))
                        if index < rows.count - 1 {
                            Rectangle()
                                .fill(PulseColors.borderSubtle)
                                .frame(height: 0.5)
                                .padding(.leading, 64) // align with the row's text column
                                .accessibilityHidden(true)
                        }
                    }
                }
                // iOS-Settings-style translucent grouped card: Liquid Glass on 26+,
                // Material/solid fallback below and under Reduce Transparency.
                .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                // Clip the row content (press highlights) to the rounded corners too —
                // glassEffect only clips its own material, so an unclipped highlight
                // rectangle would poke past the card's rounded corners.
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }
}

/// A single row: tinted icon, title, optional trailing value, chevron. No subtitle.
struct SettingsRow: View {
    let item: SettingsRowItem
    var position: RowPosition = .middle

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: 14) {
                Image(systemName: item.icon)
                    .font(PulseFont.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    // Neutral "white glass" tile (iOS Settings look): a light translucent
                    // fill with a top sheen — not glassEffect, which can't nest inside the
                    // glass section card. White glyph, no colour tint.
                    .background(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.07)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    )

                Text(item.title)
                    .font(PulseFont.body)
                    .foregroundStyle(PulseColors.textPrimary)

                Spacer(minLength: 8)

                if let trailingValue = item.trailingValue {
                    Text(trailingValue)
                        .font(PulseFont.subheadline.weight(.regular))
                        .foregroundStyle(PulseColors.textSecondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(PulseFont.footnote.weight(.semibold))
                    .foregroundStyle(PulseColors.textMuted)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle()) // whole row is tappable, not just the icon/text/chevron
        }
        .buttonStyle(SettingsRowButtonStyle(position: position))
        .accessibilityLabel(item.trailingValue.map { "\(item.title), \($0)" } ?? item.title)
        .accessibilityHint(item.accessibilityHint ?? "Opens \(item.title)")
    }
}

/// Press feedback for a settings row: the row background highlights while held. The enclosing
/// section card clips the corners, so first/last rows highlight cleanly.
struct SettingsRowButtonStyle: ButtonStyle {
    var position: RowPosition = .middle
    private let radius: CGFloat = 20 // matches the section card corner radius

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Translucent highlight clipped to a position-aware shape: rounds the
            // section's outer corners on the first/last row, square in between —
            // glassEffect doesn't clip the row content, so we shape the fill itself.
            .background(
                (configuration.isPressed ? Color.white.opacity(0.08) : Color.clear)
                    .clipShape(highlightShape)
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var highlightShape: UnevenRoundedRectangle {
        let top: CGFloat = (position == .first || position == .only) ? radius : 0
        let bottom: CGFloat = (position == .last || position == .only) ? radius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous
        )
    }
}
