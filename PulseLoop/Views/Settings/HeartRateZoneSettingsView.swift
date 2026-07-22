import SwiftUI
import SwiftData

/// Configure how the resting heart-rate zones are chosen: Standard (literature defaults), Auto
/// (personalized from the learned resting baseline — the default), or Custom (user-edited
/// boundaries). The preview and the read-only boundary rows always show the *effective* thresholds
/// from `VitalsThresholdEngine`, so the user sees exactly what Auto learned. Saving bumps
/// `UserProfile.updatedAt`, which the `VitalsStore` signature watches so every chart, gauge, and
/// card re-colors without a new measurement.
struct HeartRateZoneSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    @State private var mode: HRZoneMode = .auto
    @State private var lowUpper = 50
    @State private var athleticUpper = 60
    @State private var elevatedStart = 90
    @State private var highStart = 120
    @State private var loaded = false

    private var athleteMode: Bool { profiles.first?.athleteMode ?? false }

    /// The physiology profile as it would be after Save — saved profile + unsaved UI state — so the
    /// preview and boundary rows react live to the mode picker and steppers.
    private var draftProfile: UserPhysiologyProfile {
        var draft = UserPhysiologyProfile(profiles.first)
        draft.hrZoneMode = mode
        if mode == .custom {
            draft.hrCustomThresholds = HeartRateThresholds(
                lowUpper: Double(lowUpper),
                athleticUpper: athleteMode ? Double(athleticUpper) : nil,
                elevatedStart: Double(elevatedStart),
                highStart: Double(highStart)
            )
        }
        return draft
    }

    private var effective: (thresholds: HeartRateThresholds, isPersonalized: Bool) {
        VitalsThresholdEngine.heartRateThresholds(profile: draftProfile)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(header: "Zone mode", footer: modeFooter) {
                    FormField {
                        Picker("Zone mode", selection: $mode) {
                            ForEach(HRZoneMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                SettingsGroup(header: "Preview") {
                    FormField { zonePreview }
                }

                SettingsGroup(header: "Boundaries", footer: boundariesFooter) {
                    if mode == .custom {
                        stepperRow("Low ends below", value: $lowUpper,
                                   range: 30...((athleteMode ? athleticUpper : elevatedStart) - 5))
                        if athleteMode {
                            stepperRow("Athletic ends below", value: $athleticUpper,
                                       range: (lowUpper + 5)...(elevatedStart - 5))
                        }
                        stepperRow("Elevated starts at", value: $elevatedStart,
                                   range: ((athleteMode ? athleticUpper : lowUpper) + 5)...(highStart - 5))
                        stepperRow("High starts at", value: $highStart,
                                   range: (elevatedStart + 5)...220)
                    } else {
                        valueRow("Low ends below", Int(effective.thresholds.lowUpper))
                        if let athletic = effective.thresholds.athleticUpper {
                            valueRow("Athletic ends below", Int(athletic))
                        }
                        valueRow("Elevated starts at", Int(effective.thresholds.elevatedStart))
                        valueRow("High starts at", Int(effective.thresholds.highStart))
                    }
                }

                Text("Medical guidelines describe 60–100 bpm as a typical adult resting range, but "
                     + "large studies of healthy adults find most rest between 50 and 90 bpm. "
                     + "PulseLoop's standard zones use 50–90. These ranges are informational, not a diagnosis.")
                    .font(PulseFont.caption.weight(.regular))
                    .foregroundStyle(PulseColors.textMuted)
                    .padding(.horizontal, 16)

                PrimaryButton(title: "Save", systemImage: "checkmark") { save() }
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Heart Rate Zones")
        .onAppear(perform: loadIfNeeded)
        .onChange(of: mode) { _, newMode in
            // Entering Custom seeds the steppers from the currently-effective thresholds, so
            // customizing starts from what the user already sees (including what Auto learned).
            guard newMode == .custom else { return }
            seedDrafts(from: effective.thresholds)
        }
    }

    // MARK: - Preview

    /// Proportional zone bands over a fixed 30–160 bpm display window, with the same label + range
    /// rows the metric detail legend uses — driven by the exact zones the engine would render.
    private var zonePreview: some View {
        let zones = VitalsThresholdEngine.zones(for: .heartRate, profile: draftProfile)
        let domain = 30.0...160.0
        return VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(zones) { zone in
                        let lo = max(zone.lower ?? domain.lowerBound, domain.lowerBound)
                        let hi = min(zone.upper ?? domain.upperBound, domain.upperBound)
                        let fraction = max(0, hi - lo) / (domain.upperBound - domain.lowerBound)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(zone.color)
                            .frame(width: max(0, geo.size.width - CGFloat(zones.count - 1) * 2) * fraction)
                    }
                }
            }
            .frame(height: 10)
            ForEach(zones) { zone in
                HStack(spacing: 10) {
                    Circle().fill(zone.color).frame(width: 8, height: 8)
                    Text(zone.label).font(PulseFont.footnote).foregroundStyle(PulseColors.textPrimary)
                    Spacer()
                    Text(rangeText(zone)).font(PulseFont.caption.weight(.regular)).monospacedDigit()
                        .foregroundStyle(PulseColors.textMuted)
                }
            }
        }
    }

    private func rangeText(_ zone: MetricZone) -> String {
        switch (zone.lower, zone.upper) {
        case let (lo?, hi?): return "\(Int(lo))–\(Int(hi))"
        case let (lo?, nil): return "≥ \(Int(lo))"
        case let (nil, hi?): return "< \(Int(hi))"
        default: return ""
        }
    }

    // MARK: - Rows

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        FormValueRow(title: title) {
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue) bpm")
                    .font(PulseFont.body).monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
            }
            .fixedSize()
        }
    }

    private func valueRow(_ title: String, _ value: Int) -> some View {
        FormValueRow(title: title) {
            Text("\(value) bpm")
                .font(PulseFont.body).monospacedDigit()
                .foregroundStyle(PulseColors.textSecondary)
        }
    }

    // MARK: - Copy

    private var modeFooter: String {
        switch mode {
        case .standard:
            return "Literature-based defaults: most healthy adults rest between 50 and 90 bpm."
        case .auto:
            if let rest = profiles.first?.hrRestingBaseline {
                return "Personalized from your learned resting heart rate (currently \(Int(rest.rounded())) bpm). "
                     + "Updates as your baseline changes."
            }
            return "Still learning your resting heart rate — using standard zones until about a week of wear."
        case .custom:
            return "Set your own zone boundaries."
        }
    }

    private var boundariesFooter: String {
        mode == .custom
            ? "Boundaries keep a minimum 5 bpm gap so zones stay in order."
            : "The zone boundaries currently in effect. Switch to Custom to edit them."
    }

    // MARK: - Load / save

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let p = profiles.first else { return }
        mode = p.hrZoneMode
        if p.hrZoneMode == .custom {
            seedDrafts(from: VitalsThresholdEngine.heartRateThresholds(profile: UserPhysiologyProfile(p)).thresholds)
        } else {
            seedDrafts(from: effective.thresholds)
        }
    }

    private func seedDrafts(from thresholds: HeartRateThresholds) {
        lowUpper = Int(thresholds.lowUpper)
        athleticUpper = Int(thresholds.athleticUpper ?? 60)
        elevatedStart = Int(thresholds.elevatedStart)
        highStart = Int(thresholds.highStart)
    }

    private func save() {
        let profile = profiles.first ?? {
            let fresh = UserProfile()
            modelContext.insert(fresh)
            return fresh
        }()
        profile.hrZoneMode = mode
        if mode == .custom {
            profile.hrCustomLowUpper = Double(lowUpper)
            profile.hrCustomAthleticUpper = athleteMode ? Double(athleticUpper) : nil
            profile.hrCustomElevatedStart = Double(elevatedStart)
            profile.hrCustomHighStart = Double(highStart)
        }
        profile.updatedAt = Date()
        try? modelContext.save()
        dismiss()
    }
}
