import SwiftUI

// Liquid Glass (iOS 26+) with graceful, accessibility-aware fallbacks.
//
// The app's deployment target is iOS 18, but `glassEffect(_:in:)` and friends are
// iOS 26 only. These wrappers apply real Liquid Glass on 26+, a `.ultraThinMaterial`
// look on iOS 18–25, and — when the user enables Reduce Transparency — a solid,
// fully-legible surface on every OS. Prefer these over calling `glassEffect` directly.

/// Backing modifier for `pulseGlass`. A `ViewModifier` (not a plain `@ViewBuilder`
/// helper) so it can read `accessibilityReduceTransparency` from the environment.
private struct PulseGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            // Honor Reduce Transparency: no blur, a solid card surface + hairline.
            content
                .background(PulseColors.card, in: shape)
                .overlay(shape.stroke(PulseColors.borderSubtle, lineWidth: 1))
        } else if #available(iOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// Applies Liquid Glass on iOS 26+, a `Material` fallback on older systems, and a
    /// solid surface when Reduce Transparency is on.
    /// - Parameters:
    ///   - shape: clip shape for the effect (default `Capsule`).
    ///   - interactive: opt into touch/pointer reactions (26+ only). Use on controls.
    func pulseGlass(_ shape: some Shape = Capsule(), interactive: Bool = false) -> some View {
        modifier(PulseGlassModifier(shape: shape, interactive: interactive))
    }

    /// Wraps sibling glass views in a `GlassEffectContainer` on iOS 26+ (enables
    /// morphing + better rendering); a no-op passthrough on older systems.
    /// Use this only when *two or more* glass surfaces coexist — a single glass
    /// view gains nothing from a container.
    @ViewBuilder
    func pulseGlassContainer(spacing: CGFloat = 20) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Liquid Glass button style on iOS 26+ (`.glass` / `.glassProminent`);
    /// falls back to `.plain` on older systems. Apply to a `Button`.
    @ViewBuilder
    func pulseGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) }
            else { self.buttonStyle(.glass) }
        } else {
            self.buttonStyle(.plain)
        }
    }

    /// Materialization: on iOS 26+ the view gets a glass surface that appears/disappears
    /// by modulating light-bending (`.glassEffectTransition(.materialize)`) — must sit
    /// inside a `pulseGlassContainer`. Falls back to a plain opacity transition below 26.
    @ViewBuilder
    func pulseMaterialize(_ shape: some Shape = Capsule()) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: shape).glassEffectTransition(.materialize)
        } else {
            self.transition(.opacity)
        }
    }

    /// Softens a `ScrollView`'s content where it meets the floating glass header and
    /// nav bar, so scrolled content dissolves under the glass (the iOS 26 look).
    /// No-op below iOS 26.
    @ViewBuilder
    func pulseScrollEdges(_ edges: Edge.Set = .all) -> some View {
        if #available(iOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}
