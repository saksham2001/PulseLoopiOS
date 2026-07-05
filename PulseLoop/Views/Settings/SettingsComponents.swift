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
struct SettingsSection: View {
    let title: String
    let rows: [SettingsRowItem]

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(PulseColors.textSecondary)
                    .padding(.leading, 16)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        SettingsRow(item: row)
                        if index < rows.count - 1 {
                            Rectangle()
                                .fill(PulseColors.borderSubtle)
                                .frame(height: 0.5)
                                .padding(.leading, 64) // align with the row's text column
                                .accessibilityHidden(true)
                        }
                    }
                }
                .background(PulseColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
            }
        }
    }
}

/// A single row: tinted icon, title, optional trailing value, chevron. No subtitle.
struct SettingsRow: View {
    let item: SettingsRowItem

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: 14) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.tint)
                    .frame(width: 34, height: 34)
                    .background(item.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(item.title)
                    .font(.system(size: 16))
                    .foregroundStyle(PulseColors.textPrimary)

                Spacer(minLength: 8)

                if let trailingValue = item.trailingValue {
                    Text(trailingValue)
                        .font(.system(size: 14))
                        .foregroundStyle(PulseColors.textSecondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PulseColors.textMuted)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle()) // whole row is tappable, not just the icon/text/chevron
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityLabel(item.trailingValue.map { "\(item.title), \($0)" } ?? item.title)
        .accessibilityHint(item.accessibilityHint ?? "Opens \(item.title)")
    }
}

/// Press feedback for a settings row: the row background highlights while held. The enclosing
/// section card clips the corners, so first/last rows highlight cleanly.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? PulseColors.elevated : Color.clear)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
