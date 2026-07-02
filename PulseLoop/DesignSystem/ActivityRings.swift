import SwiftUI

// Concentric activity rings, extracted from Components.swift so the widget extension can compile
// them without pulling in the rest of the design system (which reaches into UnitsFormatter and
// other app-only services). Shared between the app and PulseLoopWidgets targets.

// MARK: - Concentric activity rings (Daily activity summary)

/// One ring's inputs. `value == nil` means the metric is unavailable → track only (no arc).
struct ActivityRing {
    let value: Double?
    let goal: Double
    let color: Color

    /// Clamped 0…1 progress; safe against nil value and zero/negative goal.
    var progress: Double {
        guard let value, goal > 0 else { return 0 }
        return Swift.min(1, Swift.max(0, value / goal))
    }
}

/// Apple-Fitness-style concentric progress rings. Outer→inner in the order passed in. Each ring draws
/// a muted background track plus a rounded-cap progress arc starting at 12 o'clock, moving clockwise,
/// visually capped at a full circle (the numeric value elsewhere still shows real over-100% totals).
struct ActivityRingsView: View {
    /// Outer ring first. Typically [steps, distance, calories].
    let rings: [ActivityRing]
    var size: CGFloat = 116
    var stroke: CGFloat = 10
    /// Gap between concentric rings.
    var spacing: CGFloat = 5

    var body: some View {
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
                let inset = CGFloat(index) * (stroke + spacing)
                let ringSize = size - inset * 2
                ZStack {
                    Circle().stroke(PulseColors.elevated, lineWidth: stroke)
                    Circle()
                        .trim(from: 0, to: ring.progress)
                        .stroke(ring.color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: ringSize, height: ringSize)
            }
        }
        .frame(width: size, height: size)
    }
}
