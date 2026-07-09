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

// MARK: - Zoom navigation transitions (iOS 18+)

/// Shared zoom-transition namespace, published from the NavigationStack root so
/// source cards (deep in child views) and their pushed destinations can match.
private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Marks this card as the source of a zoom navigation transition. No-op until
    /// a `zoomNamespace` is published into the environment. Only wire a source when
    /// the matching destination also opts in, or the transition degrades badly.
    @ViewBuilder
    func pulseZoomSource(_ id: AnyHashable?, in namespace: Namespace.ID?) -> some View {
        if let id, let namespace {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Zooms this pushed destination out of the matching source card. Only apply
    /// when a matching `pulseZoomSource` exists — a sourceless zoom glitches.
    @ViewBuilder
    func pulseZoomDestination(_ id: AnyHashable, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
