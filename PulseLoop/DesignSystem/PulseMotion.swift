import SwiftUI

// Shared motion tokens so glass interactions feel coordinated across the app,
// instead of each call site inventing its own duration/curve.
enum PulseMotion {
    /// Standard interactive spring — tab switches, card taps, selection moves.
    static let spring: Animation = .snappy(duration: 0.3)
    /// Fast press feedback for buttons and tappable controls.
    static let press: Animation = .snappy(duration: 0.18)
    /// Playful spring for prominent / delightful actions (e.g. the coach bubble).
    static let bouncy: Animation = .bouncy(duration: 0.4)
    /// Gentle fade/insert for glass surfaces materializing in and out.
    static let materialize: Animation = .easeOut(duration: 0.28)
}

/// Uniform press-scale feedback for tappable cards and controls. As a ButtonStyle
/// (not a gesture) it consumes the touch — no tap-through — and keeps the glass-era
/// press feel consistent everywhere it's applied.
struct PulseTapStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(PulseMotion.press, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PulseTapStyle {
    /// `.buttonStyle(.pulseTap)` — consistent press-scale for cards/controls.
    static var pulseTap: PulseTapStyle { PulseTapStyle() }
}
