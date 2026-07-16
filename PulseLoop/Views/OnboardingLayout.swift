import SwiftUI

/// Shared responsive primitive for the "fit-to-viewport" onboarding screens (steps 1, 2, 5).
///
/// The problem it solves: steps 1/2/5 used to be wrapped in a `ScrollView` sized for a Pro Max, so
/// on smaller iPhones (SE/mini) the content overflowed and tiles clipped behind the footer. Instead
/// of scrolling, `OnboardingFittedBand` measures the available height, derives a scale `s`, and hands
/// it to the content so every dimension compresses proportionally — the screen fits centered with no
/// scroll on every iPhone. Accessibility Dynamic Type sizes fall back to the old ScrollView body
/// (handled at each call site), because compressing type past the user's chosen size is user-hostile.
enum OnboardingLayout {
    /// Reference content-band height (a comfortable Pro). Below → compress, above → cap.
    static let referenceContentHeight: CGFloat = 560
    /// Clamp so small phones compress to ~0.80 and large never exceed 1.06.
    static func scale(for contentHeight: CGFloat) -> CGFloat {
        min(1.06, max(0.80, contentHeight / referenceContentHeight))
    }
}

/// Non-scrolling content band: measures available height, hands a scale `s` to content, and
/// centers it vertically (Spacer pair) so tall phones get balanced breathing room, not dead gaps.
struct OnboardingFittedBand<Content: View>: View {
    @ViewBuilder var content: (_ s: CGFloat) -> Content
    var body: some View {
        GeometryReader { geo in
            let s = OnboardingLayout.scale(for: geo.size.height)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content(s)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
        }
    }
}

/// Onboarding header whose type tier follows the fitted scale `s`: at generous heights it reads big
/// and confident; when compressed it steps down so the title never wraps or crowds the content below.
/// Used by the fitted screens; the non-fitted (form) steps keep the plain `CompactOnboardingHeader`.
struct FittedOnboardingHeader: View {
    let title: String
    let subtitle: String?
    let s: CGFloat

    init(title: String, subtitle: String? = nil, s: CGFloat) {
        self.title = title
        self.subtitle = subtitle
        self.s = s
    }

    private var titleFont: Font { s >= 0.92 ? PulseFont.numberXL : PulseFont.numberL }
    private var subtitleFont: Font {
        s >= 0.92 ? PulseFont.callout.weight(.regular) : PulseFont.subheadline.weight(.regular)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(PulseColors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let subtitle {
                Text(subtitle)
                    .font(subtitleFont)
                    .foregroundStyle(PulseColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Plain, non-scaling onboarding header used by the accessibility ScrollView fallbacks and the
/// form steps (Profile/Goals). Kept as a shared component so all onboarding headers match.
struct CompactOnboardingHeader: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(PulseFont.numberXL)
                .foregroundStyle(PulseColors.textPrimary)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(PulseFont.callout.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
