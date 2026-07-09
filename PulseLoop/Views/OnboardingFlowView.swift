import SwiftUI
import SwiftData

struct OnboardingFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    @State private var path = OnboardingProgressStore().loadPath()

    let onFinished: () -> Void
    private let progressStore = OnboardingProgressStore()
    private var step: OnboardingStep { path.last ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingTopBar(
                step: step,
                canGoBack: path.count > 1,
                showsSkip: step == .profile,
                onBack: goBack,
                onSkip: { push(.goals) }
            )

            Group {
                switch step {
                case .welcome:
                    OnboardingWelcomeView(
                        getStarted: { push(.ring) },
                        exploreWithoutRing: { push(.profile) }
                    )
                case .ring:
                    OnboardingPairView(
                        connected: advanceAfterConnection,
                        skipped: { push(.profile) }
                    )
                case .profile:
                    OnboardingProfileView(next: { push(.goals) })
                case .goals:
                    OnboardingGoalsView(next: { push(.baseline) })
                case .baseline:
                    OnboardingBaselineView(finish: finish)
                }
            }
            .id(step)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .animation(.snappy(duration: 0.3), value: step)
        .background(PulseColors.background.ignoresSafeArea())
        .navigationBarBackButtonHidden()
    }

    private func push(_ next: OnboardingStep) {
        guard step != next else { return }
        path.append(next)
        progressStore.savePath(path)
    }

    private func goBack() {
        guard path.count > 1 else { return }
        path.removeLast()
        progressStore.savePath(path)
    }

    private func advanceAfterConnection() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard step == .ring else { return }
            push(.profile)
        }
    }

    private func finish() {
        let profile: UserProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = UserProfile(units: ProfileDraft.preferredUnits(for: .current))
            modelContext.insert(profile)
        }
        profile.onboardingCompleted = true
        profile.baselineCompleted = true
        profile.updatedAt = Date()
        try? modelContext.save()
        progressStore.clear()
        onFinished()
    }
}

private struct OnboardingTopBar: View {
    let step: OnboardingStep
    let canGoBack: Bool
    let showsSkip: Bool
    let onBack: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                topBarSlot {
                    if canGoBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(PulseFont.callout.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Back")
                    }
                }
                Spacer()
                Text("Step \(step.index + 1) of \(OnboardingStep.allCases.count)")
                    .font(PulseFont.caption.weight(.semibold))
                    .foregroundStyle(PulseColors.textMuted)
                    .monospacedDigit()
                Spacer()
                topBarSlot {
                    if showsSkip {
                        Button("Skip", action: onSkip)
                            .font(PulseFont.subheadline.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
            }
            .foregroundStyle(PulseColors.textSecondary)

            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases) { item in
                    Capsule()
                        .fill(item.index <= step.index ? PulseColors.accent : PulseColors.cardSoft)
                        .frame(height: 4)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Onboarding progress")
            .accessibilityValue("Step \(step.index + 1) of \(OnboardingStep.allCases.count)")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private func topBarSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            content()
        }
        .frame(width: 60, height: 44)
    }
}

struct OnboardingWelcomeView: View {
    let getStarted: () -> Void
    let exploreWithoutRing: () -> Void

    private let features = [
        ("dollarsign.circle.fill", "No subscription", "Own your ring data", PulseColors.success),
        ("lock.shield.fill", "Privacy first", "Data stays on device", PulseColors.info),
        ("sparkles", "AI health coach", "Learns your baseline", PulseColors.accent),
        ("waveform.path.ecg", "See your vitals", "HR, SpO₂, HRV & stress", PulseColors.heartRate),
        ("moon.stars.fill", "Sleep tracking", "Stages and trends", PulseColors.sleep),
        ("figure.run", "Activity recording", "Live workout tracking", PulseColors.steps),
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("pulseloop-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: PulseColors.accent.opacity(0.22), radius: 18)
                    .accessibilityHidden(true)

                CompactOnboardingHeader(
                    title: "Set up PulseLoop"
                )

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(features, id: \.1) { feature in
                        VStack(spacing: 8) {
                            Image(systemName: feature.0)
                                .font(PulseFont.title3)
                                .foregroundStyle(feature.3)
                                .frame(width: 38, height: 38)
                                .background(feature.3.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
                            Text(feature.1)
                                .font(PulseFont.headline)
                                .foregroundStyle(PulseColors.textPrimary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            Text(feature.2)
                                .font(PulseFont.footnote.weight(.regular))
                                .foregroundStyle(PulseColors.textMuted)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 118, alignment: .center)
                        .padding(.horizontal, 13)
                        .pulseGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }

            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter {
                VStack(spacing: 10) {
                    PrimaryButton(title: "Get started", systemImage: "arrow.right", action: getStarted)
                    SecondaryButton(
                        title: "Explore without ring",
                        systemImage: "square.grid.2x2",
                        action: exploreWithoutRing
                    )
                }
            }
        }
    }
}

struct OnboardingProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var profiles: [UserProfile]
    @State private var draft = ProfileDraft()
    @State private var loaded = false

    let next: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                CompactOnboardingHeader(
                    title: "Profile",
                    subtitle: "Used to tune calories, activity goals, and summaries."
                )
                ProfileEditorView(draft: $draft)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: loadIfNeeded)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter {
                PrimaryButton(title: "Continue", systemImage: "arrow.right", action: saveAndContinue)
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        draft = ProfileDraft(profile: profiles.first)
    }

    private func saveAndContinue() {
        let profile: UserProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = UserProfile()
            modelContext.insert(profile)
        }
        draft.apply(to: profile)
        try? modelContext.save()
        coordinator.applyUserProfile()
        next()
    }
}

struct OnboardingGoalsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var goals: [UserGoal]
    @Query private var profiles: [UserProfile]
    @State private var draft = GoalDraft(units: .metric)
    @State private var loaded = false

    let next: () -> Void
    private var units: UnitsPreference { profiles.first?.units ?? ProfileDraft.preferredUnits(for: .current) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                CompactOnboardingHeader(
                    title: "Daily goals",
                    subtitle: "Start with recommended targets. You can change these anytime."
                )
                GoalEditorView(draft: $draft, units: units, includeWeeklyWorkouts: false)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: loadIfNeeded)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter {
                PrimaryButton(title: "Save goals", systemImage: "checkmark", action: saveAndContinue)
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        draft = GoalDraft(goal: goals.first, units: units)
    }

    private func saveAndContinue() {
        let goal: UserGoal
        if let existing = goals.first {
            goal = existing
        } else {
            goal = UserGoal()
            modelContext.insert(goal)
        }
        draft.apply(to: goal, units: units, includeWeeklyWorkouts: false)
        try? modelContext.save()
        coordinator.setGoal(steps: Int(draft.steps))
        next()
    }
}

struct OnboardingBaselineView: View {
    let finish: () -> Void

    private let milestones = [
        ("1", "Day 1", "Basic activity and vitals", PulseColors.info),
        ("moon.fill", "After sleep", "Sleep trends", PulseColors.sleep),
        ("chart.line.uptrend.xyaxis", "After 3–7 days", "Personalized baseline", PulseColors.success),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CompactOnboardingHeader(
                    title: "You're ready",
                    subtitle: "A little context before your first day with PulseLoop."
                )

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PulseLoop learns your baseline over time")
                            .font(PulseFont.numberM)
                            .foregroundStyle(PulseColors.textPrimary)
                        Text("Wear your ring during the day and sync after sleep. Trends become more personal after a few days.")
                            .font(PulseFont.subheadline.weight(.regular))
                            .foregroundStyle(PulseColors.textSecondary)
                            .lineSpacing(4)
                    }

                    ForEach(milestones, id: \.1) { milestone in
                        HStack(spacing: 12) {
                            Group {
                                if milestone.0 == "1" {
                                    Text("1").font(PulseFont.footnote.weight(.bold))
                                } else {
                                    Image(systemName: milestone.0).font(PulseFont.footnote.weight(.semibold))
                                }
                            }
                            .foregroundStyle(milestone.3)
                            .frame(width: 34, height: 34)
                            .background(milestone.3.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(milestone.1)
                                    .font(PulseFont.subheadline.weight(.semibold))
                                    .foregroundStyle(PulseColors.textPrimary)
                                Text(milestone.2)
                                    .font(PulseFont.footnote.weight(.regular))
                                    .foregroundStyle(PulseColors.textMuted)
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(20)
                .background(
                    LinearGradient(
                        colors: [PulseColors.accent.opacity(0.14), PulseColors.card],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(PulseColors.borderSubtle, lineWidth: 1)
                )

            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter {
                PrimaryButton(title: "Go to app", systemImage: "arrow.right", action: finish)
            }
        }
    }
}

struct OnboardingPairView: View {
    let connected: () -> Void
    let skipped: () -> Void

    var body: some View {
        PairingView(onConnected: connected, onSkip: skipped)
    }
}

private struct CompactOnboardingHeader: View {
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

struct OnboardingActionFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // Transparent footer: the glass button floats over the content (iOS 26 look),
        // no silver glass bar behind it. Content dissolves under the button when scrolled.
        content
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
    }
}
