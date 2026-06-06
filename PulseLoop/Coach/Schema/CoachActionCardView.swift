import SwiftUI

/// Confirm/Cancel card for a `PendingAction` the coach proposed but hasn't run.
/// Tapping Confirm executes the real mutation; Cancel dismisses it.
struct CoachActionCardView: View {
    let action: PendingAction
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var isDestructive: Bool { action.kind == .deleteActivitySession }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isDestructive ? PulseColors.danger : PulseColors.warning)
                Text("Confirm action")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.0)
                    .foregroundStyle(PulseColors.textMuted)
            }
            Text(action.summary)
                .font(.system(size: 13))
                .foregroundStyle(PulseColors.textPrimary)

            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(PulseColors.textPrimary)
                        .background(PulseColors.cardSoft, in: Capsule())
                        .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button(action: onConfirm) {
                    Text(action.confirmLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(isDestructive ? PulseColors.danger : PulseColors.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background((isDestructive ? PulseColors.danger : PulseColors.warning).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke((isDestructive ? PulseColors.danger : PulseColors.warning).opacity(0.3), lineWidth: 1))
    }
}
