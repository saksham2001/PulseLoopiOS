import SwiftUI

/// AI Coach detail screen. The existing `CoachSettingsSection` already emits bare section content
/// (no scroll container of its own), so it drops straight in here.
struct CoachSettingsDetailView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CoachSettingsSection()
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("AI Coach")
    }
}
