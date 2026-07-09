import SwiftUI

/// The app's single typographic scale, built on Apple's San Francisco system font.
///
/// Every text style flows through one of these tokens instead of an ad-hoc
/// `.system(size:weight:)`, so typography stays consistent and can be re-tuned in
/// one place. Tokens carry a size + sensible default weight (San Francisco text for
/// copy, SF Rounded for numerics/metrics). Override the weight at a call site with
/// the standard `.weight(_:)` when a specific line needs it:
///
///     Text("Title").font(PulseFont.headline)
///     Text("14").font(PulseFont.subheadline.weight(.semibold))
///     Text("8,401").font(PulseFont.numberXL)
///
/// Near-duplicate raw sizes from before the sweep are intentionally merged here
/// (e.g. 30/32/34 → `largeTitle`/`greeting`), which is where the scale gets its
/// consistency; nudge the mapping in this file rather than at call sites.
enum PulseFont {

    // MARK: Titles (San Francisco, default design)

    /// Onboarding / big hero titles. (was 34–38)
    static let largeTitle = Font.system(size: 34, weight: .semibold)
    /// Home greeting and screen-defining headers. (was 30–32)
    static let greeting   = Font.system(size: 30, weight: .semibold)
    /// Section-defining title. (was 26–28)
    static let title      = Font.system(size: 28, weight: .semibold)
    /// Secondary title. (was 22)
    static let title2     = Font.system(size: 22, weight: .semibold)
    /// Tertiary title / prominent card heading. (was 18–20)
    static let title3     = Font.system(size: 20, weight: .semibold)
    /// Standard heading, nav-bar title, list headline. (was 17)
    static let headline   = Font.system(size: 17, weight: .semibold)

    // MARK: Body & labels

    /// Emphasized body / row title. (was 16 semibold)
    static let bodyEmphasis = Font.system(size: 16, weight: .semibold)
    /// Body copy and list-row titles. (was 16 regular)
    static let body         = Font.system(size: 16, weight: .regular)
    /// Slightly smaller body / secondary action. (was 15)
    static let callout      = Font.system(size: 15, weight: .medium)
    /// Compact labels and secondary values. (was 14, default medium)
    static let subheadline  = Font.system(size: 14, weight: .medium)
    /// Footnotes, hints, trailing values. (was 13)
    static let footnote     = Font.system(size: 13, weight: .medium)
    /// Captions. (was 12)
    static let caption      = Font.system(size: 12, weight: .medium)
    /// Small captions and uppercase section headers. (was 11)
    static let caption2     = Font.system(size: 11, weight: .medium)
    /// Micro labels (axis ticks, chips). (was 10)
    static let micro        = Font.system(size: 10, weight: .medium)
    /// Smallest label. (was 8–9)
    static let nano         = Font.system(size: 9,  weight: .semibold)

    // MARK: Numerics (SF Rounded)

    /// Hero metric number. (was 38–60)
    static let numberHero = Font.system(size: 40, weight: .semibold, design: .rounded)
    /// Large metric number. (was 30–32)
    static let numberXL   = Font.system(size: 30, weight: .semibold, design: .rounded)
    /// Medium metric number. (was 22–28)
    static let numberL    = Font.system(size: 22, weight: .semibold, design: .rounded)
    /// Inline metric / stat. (was 17–20)
    static let numberM    = Font.system(size: 17, weight: .semibold, design: .rounded)

    /// Escape hatch for a rounded numeric at an exact size the scale doesn't name
    /// (rare very-large display digits, precisely-fitted gauges).
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
