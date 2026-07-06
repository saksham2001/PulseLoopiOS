import SwiftUI

// MARK: - CapabilityChips

/// Displays a ring model's capability blurb as a horizontally-scrollable row of capsule chips.
/// The `blurb` string is split on `" · "` (space-middot-space) to produce individual chips.
struct CapabilityChips: View {
    let blurb: String

    private var chips: [String] {
        blurb.components(separatedBy: " · ")
    }

    var body: some View {
        let row = HStack(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChipTone.neutral.foreground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ChipTone.neutral.background, in: Capsule())
                    .overlay(Capsule().strokeBorder(ChipTone.neutral.border, lineWidth: 1))
            }
        }
        return ViewThatFits(in: .horizontal) {
            row                                                    // fits: shown at intrinsic width
            ScrollView(.horizontal, showsIndicators: false) { row } // too wide: scrolls horizontally
        }
        .frame(maxWidth: .infinity) // full width (default .center) so the chip row is centered + stable
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chips.joined(separator: ", ")) // avoid VoiceOver reading "middle dot"
    }
}

// MARK: - SignalStrengthDots

/// Three small circles indicating BLE signal strength for a discovered ring.
/// Mark `.accessibilityHidden(true)` at the call site — the row provides the spoken level.
struct SignalStrengthDots: View {
    let rssi: Int

    private var filledCount: Int {
        if rssi >= -65 { return 3 }
        if rssi >= -80 { return 2 }
        return 1
    }

    private var filledColor: Color {
        if rssi >= -65 { return PulseColors.success }
        if rssi >= -80 { return PulseColors.warning }
        return PulseColors.danger
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i < filledCount ? filledColor : PulseColors.elevated)
                    .frame(width: 6, height: 6)
            }
        }
    }
}
