import SwiftUI

/// About detail screen: a branded hero (logo + wordmark + tagline + a tappable version chip that
/// still hides the Android-style developer unlock), a short product description, and one grouped
/// Project section (source, license, community). Fits centered without scrolling on every iPhone;
/// accessibility Dynamic Type sizes fall back to a ScrollView.
struct AboutSettingsView: View {
    @Binding var path: NavigationPath
    /// Persisted developer unlock, surfaced as the Settings "Developer" row.
    @AppStorage("developerUnlocked") private var developerUnlocked = false
    @State private var versionTapCount = 0
    @State private var lastVersionTap: Date?
    @State private var toast: String?
    @State private var toastToken = 0
    /// Drives the slow breathing glow behind the logo medallion.
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Android-style: 7 quick taps on the version unlock Developer options.
    private let developerTapThreshold = 7

    /// 0…1 progress toward unlock, used to build an accent tint/border as taps accumulate.
    private var tapProgress: Double {
        guard !developerUnlocked else { return 0 }
        return Double(min(versionTapCount, developerTapThreshold - 1)) / Double(developerTapThreshold - 1)
    }

    private let repoURL = URL(string: "https://github.com/saksham2001/PulseLoopiOS")!
    private let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    private let discordURL = URL(string: "https://discord.gg/JWWcZaZeyG")!

    private var appVersionLabel: String { "v1.0.0-beta.2" }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Large accessibility type can't fit without scrolling — degrade gracefully.
                ScrollView {
                    content(s: 1.0)
                        .padding()
                }
            } else {
                GeometryReader { geo in
                    // Scale hero + spacings to the available height so the page fills, centered,
                    // without scrolling on small iPhones and without a dead gap on big ones.
                    let s = min(1.0, max(0.80, geo.size.height / 680))
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        content(s: s)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 24)
                }
            }
        }
        .background(PulseColors.background)
        .pageChrome("About")
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(PulseFont.footnote)
                    .foregroundStyle(PulseColors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .pulseGlass(Capsule())
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    @ViewBuilder
    private func content(s: CGFloat) -> some View {
        VStack(alignment: .center, spacing: (38 * s).rounded()) {
            brandHero(s: s)

            Text("PulseLoop turns an affordable Bluetooth smart ring into a private, conversational health companion — connecting directly to your ring over Bluetooth, with no vendor cloud and no account. An on-device AI coach reads the data that never leaves your phone.")
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 480)

            SettingsGroup(header: "Project") {
                linkRow(
                    icon: "curlybraces", tint: PulseColors.accent,
                    title: "Source on GitHub",
                    subtitle: "github.com/saksham2001/PulseLoopiOS",
                    url: repoURL
                )
                linkRow(
                    icon: "bubble.left.and.bubble.right.fill", tint: PulseColors.accent,
                    title: "Join the community",
                    subtitle: "Discord",
                    url: discordURL
                )
                linkRow(
                    icon: "checkmark.seal", tint: PulseColors.info,
                    title: "License",
                    subtitle: "CC BY 4.0",
                    url: licenseURL
                )
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Brand hero

    private func brandHero(s: CGFloat) -> some View {
        let medallion = (104 * s).rounded()
        let medallionShape = RoundedRectangle(cornerRadius: 26 * s, style: .continuous)
        return VStack(alignment: .center, spacing: 0) {
            // The logo art *is* the glass squircle: it fills the shape edge-to-edge, clipped to the
            // squircle with a glass rim on top, rather than sitting small inside a tinted tile.
            Image("pulseloop-logo")
                .resizable()
                .scaledToFill()
                .frame(width: medallion, height: medallion)
                .clipShape(medallionShape)
                .pulseGlass(medallionShape)
                .shadow(color: PulseColors.accent.opacity(0.4), radius: 22 * s, y: 8 * s)
            // Slow breathing aura behind the medallion — a soft accent radial that swells and fades.
            .background {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [PulseColors.accent.opacity(0.85), PulseColors.accent.opacity(0.0)],
                            center: .center, startRadius: 0, endRadius: 120 * s
                        )
                    )
                    .frame(width: 210 * s, height: 210 * s)
                    .blur(radius: 26 * s)
                    .scaleEffect(breathe ? 1.28 : 0.84)
                    .opacity(breathe ? 1.0 : 0.55)
            }
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }

            Text("PulseLoop")
                .font(s >= 0.92 ? PulseFont.title : PulseFont.title2)
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.top, (18 * s).rounded())

            Text("Your smart ring, made conversational.")
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            versionChip
                .padding(.top, (22 * s).rounded())
        }
        .frame(maxWidth: .infinity)
    }

    /// The version pill — stands on its own (no card nesting) and carries the full developer unlock.
    private var versionChip: some View {
        Button(action: registerVersionTap) {
            HStack(spacing: 6) {
                if developerUnlocked {
                    Image(systemName: "checkmark.seal.fill")
                        .font(PulseFont.caption2.weight(.semibold))
                        .foregroundStyle(PulseColors.success)
                }
                Text(appVersionLabel)
                    .font(PulseFont.caption.weight(.semibold))
                    .foregroundStyle(PulseColors.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(VersionRowButtonStyle())
        .pulseGlass(Capsule())
        .overlay {
            Capsule()
                .fill(PulseColors.accent.opacity(tapProgress * 0.22))
                .allowsHitTesting(false)
        }
        .overlay {
            Capsule()
                .strokeBorder(PulseColors.accent.opacity(tapProgress * 0.9), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: versionTapCount)
        .accessibilityHint("Tap repeatedly to unlock developer options.")
        .keyframeAnimator(initialValue: 1.0, trigger: versionTapCount) { content, value in
            content.scaleEffect(reduceMotion ? 1.0 : value)
        } keyframes: { _ in
            LinearKeyframe(0.96, duration: 0.08)
            SpringKeyframe(1.0, duration: 0.28, spring: .bouncy(extraBounce: 0.15))
        }
        .sensoryFeedback(trigger: versionTapCount) { _, count in
            guard count > 0 else { return nil }
            if count >= developerTapThreshold { return .success }
            return count > 3 ? .impact(weight: .medium) : .impact(weight: .light)
        }
    }

    // MARK: - Developer unlock (tap the version 7×, Android-style)

    private func registerVersionTap() {
        let now = Date()
        if let last = lastVersionTap, now.timeIntervalSince(last) > 2 { versionTapCount = 0 }
        lastVersionTap = now

        guard !developerUnlocked else {
            showToast("Developer options are already enabled.")
            return
        }

        versionTapCount += 1
        let remaining = developerTapThreshold - versionTapCount
        if remaining <= 0 {
            // Leave versionTapCount at the threshold so the trigger observes it (success haptic +
            // final bounce); the `developerUnlocked` guard stops any further counting.
            developerUnlocked = true
            showToast("You are now a developer!")
            path.append(AppRoute.debug)
        } else if remaining <= 3 {
            showToast("You're \(remaining) step\(remaining == 1 ? "" : "s") away from Developer options.")
        }
    }

    private func showToast(_ message: String) {
        toastToken += 1
        let token = toastToken
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token { toast = nil }
        }
    }

    // MARK: - Link rows (one coherent icon family; the app's external-link affordance)

    private func linkRow(icon: String, tint: Color, title: String, subtitle: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(PulseFont.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    // Neutral "white glass" tile matching the Settings rows: a light translucent
                    // fill + top sheen and a hairline rim. glassEffect can't nest inside the glass
                    // section card, so this gradient stands in for Liquid Glass. White glyph, no tint.
                    .background(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.07)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(PulseFont.callout.weight(.semibold))
                        .foregroundStyle(PulseColors.textPrimary)
                    Text(subtitle)
                        .font(PulseFont.caption.weight(.regular))
                        .foregroundStyle(PulseColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(PulseFont.caption.weight(.semibold))
                    .foregroundStyle(PulseColors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Press feedback for the version chip: dims briefly while held, marking it as tappable.
private struct VersionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}
