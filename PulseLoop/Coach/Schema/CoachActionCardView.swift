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
                    .font(PulseFont.caption.weight(.regular))
                    .foregroundStyle(isDestructive ? PulseColors.danger : PulseColors.warning)
                Text("Confirm action")
                    .font(PulseFont.micro.weight(.semibold)).tracking(1.0)
                    .foregroundStyle(PulseColors.textMuted)
            }
            Text(action.summary)
                .font(PulseFont.footnote.weight(.regular))
                .foregroundStyle(PulseColors.textPrimary)

            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(PulseFont.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(PulseColors.textPrimary)
                        .pulseGlass(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                Button(action: onConfirm) {
                    Text(action.confirmLabel)
                        .font(PulseFont.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .pulseGlass(Capsule(), interactive: true,
                                    tint: isDestructive ? PulseColors.danger : PulseColors.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseGlass(RoundedRectangle(cornerRadius: 16, style: .continuous),
                    tint: isDestructive ? PulseColors.danger : PulseColors.warning)
    }
}
