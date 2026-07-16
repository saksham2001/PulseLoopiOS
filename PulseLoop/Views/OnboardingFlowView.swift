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

/// One icon + title + one-line detail + tint, shared by the Welcome feature tiles and the Baseline
/// timeline. A named struct rather than a 4-tuple (SwiftLint `large_tuple`) — `title` is the identity.
struct OnboardingItem: Identifiable {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    var id: String { title }
}

struct OnboardingWelcomeView: View {
    let getStarted: () -> Void
    let exploreWithoutRing: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let features = [
        OnboardingItem(icon: "dollarsign.circle.fill", title: "No subscription", detail: "Own your ring data", tint: PulseColors.success),
        OnboardingItem(icon: "lock.shield.fill", title: "Privacy first", detail: "Stays on your device", tint: PulseColors.info),
        OnboardingItem(icon: "sparkles", title: "AI coach", detail: "Learns your baseline", tint: PulseColors.accent),
        OnboardingItem(icon: "waveform.path.ecg", title: "Your vitals", detail: "HR, SpO₂, HRV, stress", tint: PulseColors.heartRate),
        OnboardingItem(icon: "moon.stars.fill", title: "Sleep tracking", detail: "Stages & trends", tint: PulseColors.sleep),
        OnboardingItem(icon: "figure.run", title: "Workouts", detail: "Live activity tracking", tint: PulseColors.steps),
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private let headerSubtitle = "Your health, on your terms — no subscription, no cloud."

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityBody
            } else {
                fittedBody
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter { footer }
        }
    }

    // Fitted, no-scroll layout for standard Dynamic Type sizes.
    private var fittedBody: some View {
        OnboardingFittedBand { s in
            VStack(spacing: 0) {
                logo(size: (78 * s).rounded())

                Spacer().frame(height: (14 * s).rounded())

                FittedOnboardingHeader(title: "Set up PulseLoop", subtitle: headerSubtitle, s: s)

                Spacer().frame(height: (16 * s).rounded())

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(features) { feature in
                        tile(feature, s: s)
                    }
                }
            }
        }
    }

    // Accessibility fallback: keep the scrolling body so large type never clips.
    private var accessibilityBody: some View {
        ScrollView {
            VStack(spacing: 18) {
                logo(size: 92)
                CompactOnboardingHeader(title: "Set up PulseLoop", subtitle: headerSubtitle)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(features) { feature in
                        VStack(spacing: 8) {
                            tileIcon(feature, s: 1)
                            Text(feature.title)
                                .font(PulseFont.headline)
                                .foregroundStyle(PulseColors.textPrimary)
                                .multilineTextAlignment(.center)
                            Text(feature.detail)
                                .font(PulseFont.footnote.weight(.regular))
                                .foregroundStyle(PulseColors.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
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
    }

    private func logo(size: CGFloat) -> some View {
        Image("pulseloop-logo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: PulseColors.accent.opacity(0.22), radius: 16)
            .accessibilityHidden(true)
    }

    private func tileIcon(_ feature: OnboardingItem, s: CGFloat) -> some View {
        Image(systemName: feature.icon)
            .font(.system(size: (18 * s).rounded()))
            .foregroundStyle(feature.tint)
            .frame(width: (34 * s).rounded(), height: (34 * s).rounded())
            .background(feature.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private func tile(_ feature: OnboardingItem, s: CGFloat) -> some View {
        VStack(spacing: 6) {
            tileIcon(feature, s: s)
            Text(feature.title)
                .font(PulseFont.subheadline.weight(.semibold))
                .foregroundStyle(PulseColors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(feature.detail)
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .frame(maxWidth: .infinity)
        .frame(height: (92 * s).rounded(), alignment: .center)
        .padding(.horizontal, 13)
        .pulseGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            PrimaryButton(title: "Get started", systemImage: "arrow.right", action: getStarted)
            Button("Explore without ring", action: exploreWithoutRing)
                .font(PulseFont.subheadline.weight(.semibold))
                .foregroundStyle(PulseColors.textSecondary)
                .frame(height: 44)
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Drives the medallion (rings + checkmark) and staggered timeline reveal.
    @State private var appeared = false

    // icon / title / one-line description / node tint. "1" renders as a numbered chip.
    private let milestones = [
        OnboardingItem(
            icon: "1", title: "Today",
            detail: "Activity and live vitals, right away", tint: PulseColors.info
        ),
        OnboardingItem(
            icon: "moon.fill", title: "First sync",
            detail: "Sleep stages and nightly trends", tint: PulseColors.sleep
        ),
        OnboardingItem(
            icon: "chart.line.uptrend.xyaxis", title: "Days 3–7",
            detail: "Your personalized baseline unlocks", tint: PulseColors.success
        ),
    ]

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityBody
            } else {
                fittedBody
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter {
                PrimaryButton(title: "Start using PulseLoop", systemImage: "arrow.right", action: finish)
            }
        }
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(PulseMotion.bouncy) { appeared = true }
            }
        }
    }

    private var fittedBody: some View {
        OnboardingFittedBand { s in
            VStack(spacing: 0) {
                medallion(s: s)

                Spacer().frame(height: (16 * s).rounded())

                eyebrow

                VStack(spacing: 6) {
                    Text("You're all set")
                        .font(PulseFont.largeTitle)
                        .foregroundStyle(PulseColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Wear your ring today. Your baseline builds from here.")
                        .font(PulseFont.callout)
                        .foregroundStyle(PulseColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.top, 4)

                Spacer().frame(height: (20 * s).rounded())

                timeline(s: s)
            }
        }
    }

    // Accessibility fallback: linear scrolling layout, no scale, no motion gating needed
    // (the .onAppear still sets `appeared = true` so nothing stays hidden).
    private var accessibilityBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                medallion(s: 1)
                eyebrow
                VStack(spacing: 6) {
                    Text("You're all set")
                        .font(PulseFont.largeTitle)
                        .foregroundStyle(PulseColors.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Wear your ring today. Your baseline builds from here.")
                        .font(PulseFont.callout)
                        .foregroundStyle(PulseColors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                timeline(s: 1)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Tier 1: animated success medallion

    private func medallion(s: CGFloat) -> some View {
        ZStack {
            // Outer concentric ring.
            Circle()
                .stroke(PulseColors.accent.opacity(0.12), lineWidth: 2)
                .frame(width: (140 * s).rounded(), height: (140 * s).rounded())
                .scaleEffect(appeared ? 1.0 : 0.7)
                .opacity(appeared ? 1.0 : 0.0)
            // Inner concentric ring (staggered).
            Circle()
                .stroke(PulseColors.accent.opacity(0.25), lineWidth: 2)
                .frame(width: (104 * s).rounded(), height: (104 * s).rounded())
                .scaleEffect(appeared ? 1.0 : 0.7)
                .opacity(appeared ? 1.0 : 0.0)
                .animation(reduceMotion ? nil : PulseMotion.bouncy.delay(0.06), value: appeared)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: (72 * s).rounded()))
                .foregroundStyle(PulseColors.accent)
                .padding((14 * s).rounded())
                .pulseGlass(Circle())
                .scaleEffect(appeared ? 1.0 : 0.3)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: appeared)
        }
        .pulseGlassContainer()
        .accessibilityHidden(true)
    }

    private var eyebrow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(PulseFont.caption)
            Text("Setup complete")
                .font(PulseFont.caption.weight(.semibold))
        }
        .foregroundStyle(PulseColors.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .pulseGlass(Capsule(), tint: PulseColors.accent.opacity(0.16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Setup complete")
    }

    // MARK: - Tier 3: connected vertical glass timeline

    private func timeline(s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: (18 * s).rounded()) {
            ForEach(Array(milestones.enumerated()), id: \.element.id) { index, milestone in
                milestoneRow(milestone, index: index, s: s, isLast: index == milestones.count - 1)
            }
        }
        .padding((20 * s).rounded())
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [PulseColors.accent.opacity(0.14), PulseColors.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: (22 * s).rounded(), style: .continuous)
        )
        .pulseGlass(RoundedRectangle(cornerRadius: (22 * s).rounded(), style: .continuous))
    }

    private func milestoneRow(
        _ milestone: OnboardingItem,
        index: Int,
        s: CGFloat,
        isLast: Bool
    ) -> some View {
        let node = (40 * s).rounded()
        return HStack(alignment: .top, spacing: 12) {
            // Glass node + connecting line to the next node.
            VStack(spacing: 0) {
                Group {
                    if milestone.icon == "1" {
                        Text("1").font(PulseFont.footnote.weight(.bold))
                    } else {
                        Image(systemName: milestone.icon).font(PulseFont.footnote.weight(.semibold))
                    }
                }
                .foregroundStyle(milestone.tint)
                .frame(width: node, height: node)
                .pulseGlass(Circle(), tint: milestone.tint.opacity(0.18))

                if !isLast {
                    Rectangle()
                        .fill(milestone.tint.opacity(0.35))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: node)

            VStack(alignment: .leading, spacing: 2) {
                Text(milestone.title)
                    .font(PulseFont.subheadline.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                Text(milestone.detail)
                    .font(PulseFont.footnote.weight(.regular))
                    .foregroundStyle(PulseColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, (node - 26) / 2) // vertically center title against the node
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(appeared ? 1.0 : 0.0)
        .offset(y: appeared ? 0 : 8)
        .animation(reduceMotion ? nil : PulseMotion.materialize.delay(0.12 * Double(index)), value: appeared)
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingPairView: View {
    let connected: () -> Void
    let skipped: () -> Void

    var body: some View {
        PairingView(onConnected: connected, onSkip: skipped)
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
