import SwiftUI

/// Overnight signs of strain, shown on Today **only when there are any**.
///
/// This is the one card allowed onto an already-dense Today grid, because it is conditional rather
/// than permanent: a clear night renders nothing at all. A permanent "all clear" tile would be
/// exactly the clutter the rest of this work avoids — and would also train people to stop reading it.
struct HealthWatchCard: View {
    let result: HealthWatch.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(PulseFont.headline)
                    .foregroundStyle(accent)
                Text(result.status.rawValue)
                    .font(PulseFont.subheadline.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                Spacer(minLength: 4)
            }

            VStack(spacing: 8) {
                ForEach(result.flagged, id: \.signal) { reading in
                    HStack(spacing: 10) {
                        Circle().fill(accent).frame(width: 6, height: 6)
                        Text(reading.signal.title)
                            .font(PulseFont.caption.weight(.semibold))
                            .foregroundStyle(PulseColors.textPrimary)
                        Spacer(minLength: 8)
                        Text(reading.detail)
                            .font(PulseFont.caption.monospacedDigit())
                            .foregroundStyle(PulseColors.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            Text(disclaimer)
                .font(PulseFont.caption2.weight(.regular))
                .foregroundStyle(PulseColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous)
                .stroke(accent.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.status.rawValue). \(HealthWatch.facts(result))")
    }

    private var accent: Color {
        result.status == .major ? PulseColors.warning : PulseColors.textSecondary
    }

    /// Non-negotiable copy. The card must never read as a diagnosis, and must name the mundane
    /// explanations before the worrying one.
    private var disclaimer: String {
        "Signals compared with your own recent nights, from \(result.signalsAvailable) "
            + "measurement\(result.signalsAvailable == 1 ? "" : "s") your ring records. "
            + "This isn't a diagnosis — alcohol, a warm room, and a hard session the day before all "
            + "look like this."
    }
}
