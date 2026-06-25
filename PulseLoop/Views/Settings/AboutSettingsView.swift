import SwiftUI

/// About detail screen: app version, a short description, and project/license info.
struct AboutSettingsView: View {
    private let repoURL = URL(string: "https://github.com/sakshambhutani/PulseLoop")!

    private var appVersionLabel: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "App", action: nil)
                StatusCopy(title: "Version", body: appVersionLabel)
                StatusCopy(
                    title: "PulseLoop",
                    body: """
                    An LLM-native health app that turns a cheap Bluetooth smart ring into a real, \
                    conversational health tracker. It talks to the ring directly over Bluetooth — no \
                    vendor cloud, no account — and layers an AI coach on top of your own data.
                    """
                )

                SectionHeader(title: "Project", action: nil)
                linkCard(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Source on GitHub",
                    subtitle: "github.com/sakshambhutani/PulseLoop",
                    url: repoURL
                )
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
        .navigationTitle("About")
    }

    private func linkCard(icon: String, title: String, subtitle: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PulseColors.accent)
                    .frame(width: 36, height: 36)
                    .background(PulseColors.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(PulseColors.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PulseColors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
