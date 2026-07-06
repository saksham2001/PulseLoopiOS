import SwiftUI

/// Renders a smart ring's product art on a light "platter" for the pairing carousel and the Settings
/// hero. Each `WearableModel` supplies its own `imageName`; a model (or connected device) without one
/// falls back to a generic Colmi-style ring — the de-facto look of these inexpensive rings.
struct RingArtView: View {
    /// Generic ring shown when no model-specific image is available.
    static let fallbackImage = "colmi-r09"

    var tint: Color
    var size: CGFloat = 180
    /// Asset-catalog image for this ring; when nil, `fallbackImage` is used. A non-nil value MUST be a
    /// registered imageset name (models add their art to `Assets.xcassets` keyed by their `id`); an
    /// unregistered name renders empty rather than falling back.
    var imageName: String? = nil

    var body: some View {
        ZStack {
            // Soft themed glow so the platter sits in the app's color world.
            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: size, height: size)
                .blur(radius: size * 0.13)
                .animation(.easeInOut(duration: 0.25), value: tint)

            // A light platter so black / gold / rose-gold rings all read on the dark theme, and the
            // inconsistent source images look unified.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(white: 0.88)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.18), radius: size * 0.05, y: size * 0.02)

            Image(imageName ?? Self.fallbackImage)
                .resizable()
                .scaledToFit()
                .padding(size * 0.08)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
