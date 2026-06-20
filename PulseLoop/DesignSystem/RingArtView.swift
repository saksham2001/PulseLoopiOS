import SwiftUI

/// A stylized, asset-free rendering of a smart ring for the pairing carousel: a thick gradient band
/// (torus) with a soft highlight and inner shadow, tinted per model. Pure SwiftUI so it ships without
/// product photos; a later swap to real images only replaces this view.
struct RingArtView: View {
    var tint: Color
    var size: CGFloat = 180

    var body: some View {
        let band = size * 0.16

        ZStack {
            // Soft glow behind the ring.
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: size * 0.95, height: size * 0.95)
                .blur(radius: size * 0.12)

            // Main band with an angular gradient so it reads as a 3D metal/silicone ring.
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            tint.opacity(0.55),
                            tint,
                            Color.white.opacity(0.85),
                            tint,
                            tint.opacity(0.55),
                        ],
                        center: .center
                    ),
                    lineWidth: band
                )
                .frame(width: size, height: size)

            // Inner edge shadow for depth.
            Circle()
                .strokeBorder(Color.black.opacity(0.35), lineWidth: band * 0.18)
                .frame(width: size - band * 0.9, height: size - band * 0.9)
                .blur(radius: 1)

            // Top highlight sweep.
            Circle()
                .trim(from: 0.55, to: 0.75)
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: band * 0.3, lineCap: .round))
                .frame(width: size - band * 0.4, height: size - band * 0.4)
                .blur(radius: 1.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
