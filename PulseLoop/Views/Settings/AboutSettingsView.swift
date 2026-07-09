import SwiftUI

/// About detail screen: app version, a short description, and project/license info.
struct AboutSettingsView: View {
    @Binding var path: NavigationPath
    /// Persisted developer unlock, surfaced as the Settings "Developer" row.
    @AppStorage("developerUnlocked") private var developerUnlocked = false
    @State private var versionTapCount = 0
    @State private var lastVersionTap: Date?
    @State private var toast: String?
    @State private var toastToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Android-style: 7 quick taps on the version unlock Developer options.
    private let developerTapThreshold = 7

    /// 0…1 progress toward unlock, used to build an accent tint/border as taps accumulate.
    private var tapProgress: Double {
        guard !developerUnlocked else { return 0 }
        return Double(min(versionTapCount, developerTapThreshold - 1)) / Double(developerTapThreshold - 1)
    }

    private let repoURL = URL(string: "https://github.com/saksham2001/PulseLoopiOS")!

    private var appVersionLabel: String {
        "v1.0.0-beta.2"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(header: "App") {
                    FormField {
                        Button(action: registerVersionTap) {
                            StatusCopy(title: "Version", body: appVersionLabel)
                        }
                        .buttonStyle(VersionRowButtonStyle())
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(PulseColors.accent.opacity(tapProgress * 0.22))
                                .allowsHitTesting(false)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
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
                }
                StatusCopy(
                    title: "PulseLoop",
                    body: """
                    An LLM-native health app that turns a cheap Bluetooth smart ring into a real, \
                    conversational health tracker. It talks to the ring directly over Bluetooth — no \
                    vendor cloud, no account — and layers an AI coach on top of your own data.
                    """
                )

                SettingsGroup(header: "Project") {
                    linkCard(
                        icon: "chevron.left.forwardslash.chevron.right",
                        title: "Source on GitHub",
                        subtitle: "github.com/saksham2001/PulseLoopiOS",
                        url: repoURL
                    )
                }
                StatusCopy(
                    title: "License",
                    body: """
                    Creative Commons Attribution 4.0 International (CC BY 4.0). Free to share and \
                    adapt, including commercially, with appropriate credit: PulseLoop by Saksham Bhutani.
                    """
                )
            }
            .padding()
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

    private func linkCard(icon: String, title: String, subtitle: String, url: URL) -> some View {
        Link(destination: url) {
            FormField {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(PulseFont.callout.weight(.semibold))
                        .foregroundStyle(PulseColors.accent)
                        .frame(width: 36, height: 36)
                        .background(PulseColors.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(PulseFont.callout.weight(.semibold)).foregroundStyle(PulseColors.textPrimary)
                        Text(subtitle).font(PulseFont.caption.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(PulseFont.caption.weight(.semibold))
                        .foregroundStyle(PulseColors.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Press feedback for the version row: dims briefly while held, marking it as tappable.
private struct VersionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}
