import SwiftUI

/// Apple Health detail screen. `HealthSettingsSection` emits bare section content (no scroll
/// container of its own), so it drops straight in here — matching the `CoachSettingsDetailView` idiom.
struct HealthSettingsDetailView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HealthSettingsSection()
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Apple Health")
    }
}
