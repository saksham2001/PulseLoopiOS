import SwiftUI

/// The measurement sheet's ring: one circle that is both the progress indicator and the readout.
///
/// It is driven entirely by wall-clock time through `TimelineView(.animation)`, and that is the whole
/// point — the fill and the number advance on their own, so they keep moving under Reduce Motion. (The
/// arc this replaces was animated by a state flag that never flipped under Reduce Motion, so it froze
/// at a hardcoded half-turn and sat there for the length of the measurement.)
///
/// Reduce Motion gates only the decorative heartbeat and beat-rings. It never freezes, or substitutes a
/// literal for, a value the user is waiting on.
struct MeasurementRingView: View {
    let stage: MeasurementSheet.Stage
    let tint: Color
    let symbolName: String
    let unit: String
    /// The measurement's fixed duration, when it *has* one. Non-nil → a real countdown; nil → an
    /// indeterminate sweep, because we don't know when this measurement will land and won't pretend to.
    let countdownWindow: Double?
    let measureStart: Date?
    /// A live value to promote into the centre mid-measurement (HR's bpm, once a real one is on the
    /// wire). Nil for measurements that have nothing trustworthy to show until they finish.
    let liveValue: String?
    /// The settled reading, shown at `.result`. Blood pressure passes its pair here ("120/80").
    let resultText: String?
    /// SpO₂ breathes rather than beats.
    let slowBreathing: Bool

    let ringColor: Color
    let resultBounce: CGFloat
    let ambientPulse: Bool
    let beatPulse: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 56

    private var trackWidth: CGFloat { contrast == .increased ? 7 : 5 }

    /// The success recolour at result, once it has been applied.
    private func tinted(_ fallback: Color) -> Color {
        ringColor == .clear ? fallback : ringColor
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = measureStart.map { context.date.timeIntervalSince($0) } ?? 0

            ZStack {
                if !reduceMotion, stage == .searching || stage == .locking {
                    beatRings
                }

                // Ambient heartbeat / breathing fill. Decorative, so Reduce-Motion gated.
                Circle()
                    .fill(tinted(tint).opacity(0.10))
                    .frame(width: 220, height: 220)
                    .scaleEffect(ambientScale)
                    .animation(heartbeatAnimation, value: ambientPulse)
                    .allowsHitTesting(false)

                Circle()
                    .stroke(PulseColors.card, lineWidth: trackWidth)
                    .frame(width: 200, height: 200)
                    .allowsHitTesting(false)

                progressStroke(elapsed: elapsed)
                centerContent(elapsed: elapsed)
            }
        }
    }

    private var beatRings: some View {
        ForEach(0..<3, id: \.self) { i in
            Circle()
                .stroke(tinted(tint).opacity(0.5), lineWidth: 2)
                .frame(width: 200, height: 200)
                .scaleEffect(beatPulse ? 1.18 : 0.9)
                .opacity(beatPulse ? 0 : 0.55)
                .animation(
                    .easeOut(duration: 1.5).repeatForever(autoreverses: false).delay(Double(i) * 0.5),
                    value: beatPulse
                )
                .allowsHitTesting(false)
        }
    }

    /// Determinate: a real 0→1 fill off the measurement's own window. Indeterminate: a short arc
    /// sweeping at a constant rate — motion that says "working", never a fraction that implies a finish
    /// time we don't know.
    private func progressStroke(elapsed: TimeInterval) -> some View {
        let indeterminate = countdownWindow == nil && stage == .searching

        return Circle()
            .trim(from: 0, to: indeterminate ? 0.22 : trim(elapsed: elapsed))
            .stroke(strokeColor, style: StrokeStyle(lineWidth: trackWidth, lineCap: .round))
            // When the stage flips, the trim target becomes 1.0 and this runs the fill smoothly up from
            // wherever the countdown had reached.
            .animation(reduceMotion ? .linear(duration: 0.6) : PulseMotion.bouncy, value: stage)
            .frame(width: 200, height: 200)
            .rotationEffect(.degrees(-90 + (indeterminate ? elapsed * 140 : 0)))
            .allowsHitTesting(false)
    }

    private func trim(elapsed: TimeInterval) -> CGFloat {
        switch stage {
        case .preparing: return 0          // empty track — nothing has started yet
        case .searching:
            guard let window = countdownWindow, window > 0 else { return 0.22 }
            return CGFloat(min(max(elapsed / window, 0), 1))
        case .locking, .result: return 1
        case .error: return 0.75
        }
    }

    private var strokeColor: Color {
        switch stage {
        case .error: return PulseColors.danger
        case .result: return tinted(PulseColors.success)
        default: return tint
        }
    }

    // MARK: - Centre

    @ViewBuilder
    private func centerContent(elapsed: TimeInterval) -> some View {
        switch stage {
        case .preparing:
            glyph
                .scaleEffect(reduceMotion ? 1 : (ambientPulse ? 1.06 : 0.94))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                    value: ambientPulse
                )
        case .searching:
            if let liveValue {
                // A real reading is already on the wire: promote it, demote the countdown to a caption.
                hero(liveValue, unit: unit, caption: "MEASURING · \(clock(remaining(elapsed: elapsed)))")
            } else if countdownWindow != nil {
                hero("\(remaining(elapsed: elapsed))", unit: "SECONDS", size: timerSize)
            } else {
                // No known finish time, so count up. An honest "still working" beats a countdown we
                // would have to invent.
                hero(clock(Int(elapsed)), unit: "ELAPSED")
            }
        case .locking:
            if let liveValue { hero(liveValue, unit: unit) } else { glyph }
        case .result:
            if let resultText { hero(resultText, unit: unit, bounce: true) } else { glyph }
        case .error:
            EmptyView()
        }
    }

    private var glyph: some View {
        Image(systemName: symbolName)
            .font(PulseFont.numberL)
            .foregroundStyle(tint)
    }

    /// The centred number, with an optional caption above and a unit below. The scale factor keeps a
    /// pair like "120/80" on one line.
    private func hero(
        _ text: String,
        unit: String,
        caption: String? = nil,
        size: CGFloat? = nil,
        bounce: Bool = false
    ) -> some View {
        VStack(spacing: 4) {
            if let caption {
                Text(caption)
                    .font(PulseFont.footnote.monospacedDigit())
                    .foregroundStyle(PulseColors.textMuted)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            Group {
                if let size {
                    Text(text).font(.system(size: size, weight: .semibold, design: .rounded))
                } else {
                    Text(text).font(PulseFont.numberHero)
                }
            }
            .monospacedDigit()
            .foregroundStyle(PulseColors.textPrimary)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .scaleEffect(bounce ? resultBounce : 1)

            Text(unit)
                .font(PulseFont.caption.weight(.regular)).tracking(1.4)
                .foregroundStyle(PulseColors.textMuted)
        }
        // Bound the reading to the inner circle so `minimumScaleFactor` has something to shrink against
        // rather than overflowing the ring.
        .frame(maxWidth: 190)
    }

    private func remaining(elapsed: TimeInterval) -> Int {
        guard let window = countdownWindow else { return 0 }
        return max(0, Int(ceil(window - elapsed)))
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Ambient motion

    private var ambientScale: CGFloat {
        guard !reduceMotion else { return 1 }
        switch stage {
        case .preparing, .searching: return ambientPulse ? 1.0 : 0.94
        case .locking: return ambientPulse ? 1.05 : 1.0
        default: return 1
        }
    }

    private var heartbeatAnimation: Animation? {
        guard !reduceMotion else { return nil }
        switch stage {
        case .preparing, .searching, .locking:
            return .easeInOut(duration: slowBreathing ? 1.6 : 0.85).repeatForever(autoreverses: true)
        default:
            return nil
        }
    }
}
