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
                    .font(PulseFont.caption2)
                    .foregroundStyle(ChipTone.neutral.foreground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .pulseGlass(Capsule())
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

// MARK: - SupportBadge

/// A "Limited support" pill for experimental ring families. Warn-toned rather than glass, because a
/// tinted glass capsule reads as a *selected control* everywhere else in this app. Renders nothing
/// for `.full` families, so call sites can place it unconditionally.
struct SupportBadge: View {
    let level: WearableSupportLevel

    var body: some View {
        if let label = level.badgeLabel {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(label)
            }
            .font(PulseFont.caption2.weight(.semibold))
            .foregroundStyle(ChipTone.warn.foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(ChipTone.warn.background, in: Capsule())
            .overlay(Capsule().stroke(ChipTone.warn.border, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
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

    var body: some View {
        // One filled white dot per strength level (1/2/3), no empty dots. Glass at 6pt
        // reads too faint here, so use a solid white fill.
        HStack(spacing: 3) {
            ForEach(0..<filledCount, id: \.self) { _ in
                Circle()
                    .fill(.white)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - GlassScrollIndicator

/// A liquid-glass "scroll bar" page indicator: a faint glass track with an accent
/// glass thumb sized to `1/count` of the width. The thumb slides to the selected
/// index and the track can be dragged to scrub between models. Replaces a per-model
/// dot row so it scales to any catalog size without clipping.
struct GlassScrollIndicator: View {
    let count: Int
    @Binding var index: Int
    var onScrub: () -> Void = {}

    private let trackHeight: CGFloat = 8
    private var slide: Animation { .spring(response: 0.34, dampingFraction: 0.85) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let thumbW = max(w / CGFloat(max(count, 1)), 34) // min thumb so it stays grabbable
            let maxX = max(w - thumbW, 0)
            let x = count > 1 ? maxX * CGFloat(index) / CGFloat(count - 1) : 0

            ZStack(alignment: .leading) {
                // Faint glass track.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: trackHeight)
                    .pulseGlass(Capsule())
                    .opacity(0.5)
                // Accent glass thumb.
                Color.clear
                    .frame(width: thumbW, height: trackHeight)
                    .pulseGlass(Capsule(), interactive: true, tint: PulseColors.accent)
                    .offset(x: x)
                    .animation(slide, value: index)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard count > 1, w > 0 else { return }
                        let ratio = min(max(value.location.x / w, 0), 1)
                        let newIndex = Int((ratio * CGFloat(count - 1)).rounded())
                        if newIndex != index {
                            withAnimation(slide) { index = newIndex }
                            onScrub()
                        }
                    }
            )
        }
        .frame(height: 44)
    }
}
