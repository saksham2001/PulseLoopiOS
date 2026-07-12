import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Live measurement sheet ported from `frontend/src/components/measurement/MeasurementModal.tsx`.
/// Drives the `RingSyncCoordinator` measure flow. A disconnected ring surfaces an error — it never
/// fabricates a reading, because a fake vital saved to history is indistinguishable from a real one.
///
/// THE RING IS ONE CLOCK, and it only ever tells the truth about time:
///
///  * `.hr` is the single measurement with a genuinely fixed duration — it samples its whole window
///    (see `RingSyncCoordinator.measureHR`), so the ring fills 0→full while a countdown ticks to zero.
///    The window is read from the coordinator, never copied, so the fill can't desync from the measure.
///  * every other kind returns the instant its value lands, at a time nobody can predict. They get an
///    indeterminate sweep and a count-*up*: an honest "still working", not a promise we can't keep.
///
/// Both are derived from wall-clock time via `TimelineView(.animation)`, so they keep moving under
/// Reduce Motion (a TimelineView tick is not accessibility "motion"). Reduce Motion gates only the
/// decorative heartbeat and beat-rings; it never freezes a value the user is waiting on.
struct MeasurementSheet: View {
    /// `.vitals` is one sweep that returns every metric the ring computes (jring's `0x24` packet);
    /// the rest are single-metric spot readings on devices that measure one thing at a time.
    enum Kind: Hashable { case hr, spo2, hrv, bloodPressure, vitals }

    /// The measurement lifecycle. `searching` is the working state — counting down (HR) or up (rest).
    enum Stage { case preparing, searching, locking, result, error }

    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    /// Only the demo path writes through this — a real reading is persisted by the coordinator's event
    /// subscriber as its samples arrive.
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: State
    @State private var stage: Stage = .preparing
    @State private var value: Int?
    /// Diastolic, for blood pressure — the only single reading that is a pair.
    @State private var secondaryValue: Int?
    /// Populated for `.vitals`: every metric the sweep returned.
    @State private var vitals: RingSyncCoordinator.VitalsReading?
    /// Wall-clock anchor for the ring. `TimelineView` derives fill + elapsed/remaining from it.
    @State private var measureStart: Date?
    /// Bumping this cancels the in-flight `.task` and starts a fresh run — that's the whole retry
    /// mechanism, and why there's no hand-rolled `Task` handle to leak or double-cancel.
    @State private var attempt = 0
    /// Coarse elapsed clock (0.5s), used only for copy swaps and the throttled VoiceOver bucket —
    /// never for the ring, which is time-derived.
    @State private var elapsed: TimeInterval = 0
    @State private var announcedStillWorking = false
    /// One-shot so the "reading acquired" haptic fires once per measurement.
    @State private var acquiredHaptic = false
    @AccessibilityFocusState private var errorFocus: Bool

    // MARK: Animation drivers (the ONLY Reduce-Motion gates)
    @State private var ambientPulse = false
    @State private var beatPulse = false
    @State private var ringColor: Color = .clear
    @State private var resultBounce: CGFloat = 1

    #if canImport(UIKit)
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private let notify = UINotificationFeedbackGenerator()
    #endif

    private let elapsedTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // MARK: - Per-kind tokens
    //
    // `Kind` answers everything that depends only on which metric this is — see
    // `MeasurementKindPresentation`. The sheet keeps only what depends on the measurement's *state*.

    private var color: Color { kind.tint }
    private var name: String { kind.title }
    private var unit: String { kind.unit }
    private var instruction: String { kind.instruction }

    /// The one measurement with a fixed, known duration — so the only one we can honestly count down.
    /// Sourced from the coordinator: copying the literal is how the ring and the measurement desync.
    /// Nil in demo mode too — no 30s window is running there, so a countdown would be pure theatre.
    private var countdownWindow: Double? {
        guard kind == .hr, ble.state == .connected else { return nil }
        return Double(coordinator.hrMeasureSeconds)
    }

    /// The big number in the ring. Blood pressure shows the systolic/diastolic pair.
    private var readingText: String? {
        guard let value else { return nil }
        if kind == .bloodPressure, let secondaryValue { return "\(value)/\(secondaryValue)" }
        return "\(value)"
    }

    /// Explicit Done (vs auto-dismiss) is required under VoiceOver or Switch Control — and for the
    /// combined sweep, which has several numbers to read.
    private var needsExplicitDone: Bool {
        if kind == .vitals { return true }
        #if canImport(UIKit)
        return UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(24)

            // The combined sweep returns a whole grid rather than one number, so at result it replaces
            // the ring entirely (see `VitalsResultsView`). Every other kind keeps the ring.
            if stage == .result, kind == .vitals, let vitals {
                VitalsResultsView(vitals: vitals)
                Spacer(minLength: 0)
            } else {
                measuringContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PulseColors.background.ignoresSafeArea())
        .pulseGlassContainer()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Measuring \(name)")
        .overlay(alignment: .bottom) { statusElement }
        .onReceive(elapsedTimer) { _ in tickElapsed() }
        // A real bpm landed mid-window (HR runs the full window regardless, so this doesn't advance the
        // stage — it just gives the moment a tactile beat and lets the live value take over the centre).
        .onChange(of: coordinator.measurementReceivedReading) { _, received in
            guard kind == .hr, received, !acquiredHaptic else { return }
            acquiredHaptic = true
            #if canImport(UIKit)
            softImpact.impactOccurred(intensity: 0.7)
            #endif
        }
        .task(id: attempt) { await run() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.eyebrow(isCombinedSweep: kind == .vitals))
                    .font(PulseFont.micro).tracking(1.8)
                    .foregroundStyle(stage.eyebrowColor(tint: color))
                    .contentTransition(.opacity)
                Text(name).font(PulseFont.title3).foregroundStyle(PulseColors.textPrimary)
            }
            Spacer()
            controlButton
        }
    }

    /// Cancel while working, Done at result.
    private var controlButton: some View {
        Group {
            switch stage {
            case .preparing, .searching, .locking:
                // Dismissing tears down the `.task`, which cancels the measurement and stops the ring's
                // stream — no separate cancel plumbing to keep in sync.
                Button("Cancel") { dismiss() }
                    .accessibilityHint("Stops measuring and closes without saving.")
            case .result:
                Button("Done") { dismiss() }
            case .error:
                EmptyView()
            }
        }
        .font(PulseFont.footnote)
        .foregroundStyle(PulseColors.textPrimary)
        .padding(.horizontal, 14)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Capsule())
        .pulseGlass(Capsule(), interactive: true)
    }

    // MARK: - Measuring content (ring + copy), vertically centred

    @ViewBuilder
    private var measuringContent: some View {
        VStack(spacing: 0) {
            Spacer()

            if stage == .error {
                errorState
                    .transition(.opacity)
            } else {
                ring
                    .frame(height: 260)
                    .accessibilityHidden(true)

                copyLine
                    .padding(.top, 24)
                    .padding(.horizontal, 24)
            }

            Spacer()

            if stage == .result {
                Text("Saved")
                    .font(PulseFont.subheadline.weight(.semibold))
                    .foregroundStyle(PulseColors.success)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .pulseMaterialize(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - The ring

    private var ring: some View {
        MeasurementRingView(
            stage: stage,
            tint: color,
            symbolName: kind.symbolName,
            unit: unit.uppercased(),
            countdownWindow: countdownWindow,
            measureStart: measureStart,
            liveValue: liveValue,
            resultText: readingText,
            slowBreathing: kind.slowBreathing,
            ringColor: ringColor,
            resultBounce: resultBounce,
            ambientPulse: ambientPulse,
            beatPulse: beatPulse
        )
    }

    /// A value worth putting in the centre of the ring *during* the measurement. Only HR has one: it
    /// streams a real bpm mid-window. The rest have nothing trustworthy to show until they land — SpO₂
    /// in particular reports progress percentages through the same channel as its result, so a "live"
    /// SpO₂ number would sometimes just be a progress bar wearing a percent sign.
    private var liveValue: String? {
        guard kind == .hr, coordinator.measurementReceivedReading, let bpm = coordinator.latestHRValue else {
            return nil
        }
        return "\(bpm)"
    }

    // MARK: - Copy under the ring

    private var copyLine: some View {
        Text(copyText)
            .font(PulseFont.subheadline.weight(.regular))
            .foregroundStyle(PulseColors.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)
            .contentTransition(.opacity)
    }

    private var copyText: String {
        switch stage {
        case .preparing: return instruction
        case .searching:
            if elapsed >= 20 { return "Just a few seconds more…" }
            if elapsed >= 12 {
                return kind == .hr ? "Still working — hold steady." : "Still working — stay still."
            }
            return kind.workingCopy
        case .locking: return kind == .hr ? "Locking it in…" : "Locking in your reading…"
        case .result: return "Saved to your history."
        case .error: return ""
        }
    }

    // MARK: - Error

    private var errorState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark")
                .font(PulseFont.title.weight(.bold))
                .foregroundStyle(PulseColors.danger)
                .frame(width: 80, height: 80)
                .background(PulseColors.danger.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(PulseColors.danger.opacity(0.3), lineWidth: 1))
                .accessibilityHidden(true)

            Text(errorMessage)
                .font(PulseFont.subheadline.weight(.regular))
                .foregroundStyle(PulseColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            HStack(spacing: 12) {
                Button("Try again") { retry() }
                    .pulseGlassButton(prominent: true)
                    .accessibilityFocused($errorFocus)

                Button("Close") { dismiss() }
                    .font(PulseFont.subheadline.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                    .padding(.horizontal, 20)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Capsule())
                    .pulseGlass(Capsule(), interactive: true)
            }
            .padding(.top, 4)
        }
    }

    private var errorMessage: String {
        guard ble.state == .connected else {
            return "Your ring isn't connected. Reconnect it and try again."
        }
        return kind.failureMessage
    }

    // MARK: - VoiceOver status

    private var statusElement: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("\(name) measurement")
            .accessibilityValue(statusValue)
            .accessibilityAddTraits(isBusy ? .updatesFrequently : [])
    }

    private var isBusy: Bool { stage == .preparing || stage == .searching || stage == .locking }

    /// Bucketed to ~10s while working — never a per-second string, which VoiceOver would spam.
    private var statusValue: String {
        switch stage {
        case .preparing: return "Preparing"
        case .searching:
            guard let window = countdownWindow else { return "Measuring \(name)" }
            let bucket = max(0, Int((window - elapsed) / 10) * 10)
            return bucket > 0 ? "Measuring \(name), about \(bucket) seconds" : "Measuring \(name)"
        case .locking: return "Locking in your reading"
        case .result:
            if kind == .vitals {
                let count = vitals.map { VitalsResultsView.tiles(for: $0).count } ?? 0
                return "Reading complete. \(count) results. Saved."
            }
            guard let readingText else { return "Complete" }
            return "\(readingText) \(unit). Saved."
        case .error: return errorMessage
        }
    }

    // MARK: - Stage transitions

    private func enterSearching() {
        withAnimation(.easeInOut(duration: 0.25)) { stage = .searching }
        measureStart = Date()
        elapsed = 0
        announcedStillWorking = false
        ambientPulse = true
        beatPulse = true
        #if canImport(UIKit)
        lightImpact.impactOccurred()
        #endif
        announce("Measuring \(name)")
    }

    private func enterLocking() {
        guard stage == .searching else { return }
        withAnimation(reduceMotion ? .none : PulseMotion.bouncy) { stage = .locking }
    }

    private func enterResult() {
        withAnimation(.easeInOut(duration: 0.25)) { stage = .result }
        withAnimation(.easeInOut(duration: 0.3)) { ringColor = PulseColors.success }
        #if canImport(UIKit)
        notify.notificationOccurred(.success)
        #endif
        if !reduceMotion {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { resultBounce = 1.06 }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(0.18)) { resultBounce = 1.0 }
        }
        announce(statusValue)
    }

    private func enterError() {
        withAnimation(.easeInOut(duration: 0.25)) { stage = .error }
        #if canImport(UIKit)
        notify.notificationOccurred(.error)
        #endif
        announce(errorMessage)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.4))
            errorFocus = true
        }
    }

    private func tickElapsed() {
        guard stage == .searching, let start = measureStart else { return }
        elapsed = Date().timeIntervalSince(start)
        if !announcedStillWorking, elapsed >= 12 {
            announcedStillWorking = true
            announce("Still working, keep still")
        }
    }

    private func announce(_ message: String) {
        #if canImport(UIKit)
        guard UIAccessibility.isVoiceOverRunning else { return }
        AccessibilityNotification.Announcement(message).post()
        #endif
    }

    /// Bumping `attempt` cancels the running `.task` (which stops the ring's stream) and starts a
    /// clean one.
    private func retry() {
        stage = .preparing
        value = nil
        secondaryValue = nil
        vitals = nil
        measureStart = nil
        elapsed = 0
        ringColor = .clear
        ambientPulse = false
        beatPulse = false
        resultBounce = 1
        acquiredHaptic = false
        announcedStillWorking = false
        attempt += 1
    }

    // MARK: - Driver

    @MainActor
    private func run() async {
        #if canImport(UIKit)
        lightImpact.prepare()
        softImpact.prepare()
        notify.prepare()
        #endif

        stage = .preparing
        try? await Task.sleep(for: .seconds(3.0))   // instruction hold
        if Task.isCancelled { return }

        // A ring that isn't connected splits two ways, and conflating them was the bug: the sheet used
        // to fabricate a reading for BOTH.
        //
        //  * Nobody has ever paired a ring → this is the "Explore without ring" visitor. The demo
        //    reading is the point, and it is tagged `source: .mock`, which the charts and the coach
        //    both key off (`isDemo`). Keep it.
        //  * A ring IS paired, it just isn't connected right now → the user believes they are taking a
        //    real measurement. Handing them an invented number here is indefensible. Error instead.
        guard ble.state == .connected else {
            if MetricsService.fetchDevices(modelContext).isEmpty {
                await runDemoMeasurement()
            } else {
                enterError()
            }
            return
        }

        enterSearching()

        if kind == .vitals {
            await runCombinedVitals()
            return
        }

        let result: Int?
        switch kind {
        case .hr: result = await coordinator.measureHR()
        case .spo2: result = await coordinator.measureSpO2()
        case .hrv: result = await coordinator.measureHRV()
        case .bloodPressure:
            let reading = await coordinator.measureBloodPressure()
            secondaryValue = reading?.diastolic
            result = reading?.systolic
        case .vitals: return   // handled above
        }
        if Task.isCancelled { return }

        await reveal(result)
    }

    /// One sweep, every metric.
    @MainActor
    private func runCombinedVitals() async {
        vitals = await coordinator.measureVitals()
        if Task.isCancelled { return }
        await revealVitals()
    }

    /// The "Explore without ring" path — see `MeasurementDemoData`, which owns the seeding and the
    /// `source: .mock` tagging. The sheet just runs its usual window so the demo feels like the real one.
    @MainActor
    private func runDemoMeasurement() async {
        enterSearching()
        try? await Task.sleep(for: .seconds(kind == .hr ? 2.2 : 3.0))
        if Task.isCancelled { return }

        let demo = MeasurementDemoData.seed(kind, context: modelContext)
        secondaryValue = demo.secondary
        vitals = demo.vitals
        if kind == .vitals {
            await revealVitals()
        } else {
            await reveal(demo.value)
        }
    }

    /// The combined sweep succeeds on *any* metric — the ring populates whatever it can, so this never
    /// hangs its success on one number the way a single-metric reading does. Always waits for "Done".
    @MainActor
    private func revealVitals() async {
        if Task.isCancelled { return }
        guard let vitals, !vitals.isEmpty else { enterError(); return }
        enterLocking()
        try? await Task.sleep(for: .seconds(0.5))
        if Task.isCancelled { return }
        enterResult()
    }

    /// Land a finished single-metric reading: fill the ring, show the number, and (unless the user is
    /// on VoiceOver) close the sheet behind them.
    @MainActor
    private func reveal(_ result: Int?) async {
        if Task.isCancelled { return }
        guard let result else { enterError(); return }
        // A BP reading without its diastolic half is not a usable reading.
        if kind == .bloodPressure, secondaryValue == nil { enterError(); return }

        enterLocking()
        value = result
        // Let the ring visibly finish its fill before the number lands.
        try? await Task.sleep(for: .seconds(0.5))
        if Task.isCancelled { return }
        enterResult()

        guard !needsExplicitDone else { return }
        try? await Task.sleep(for: .seconds(1.3))
        if Task.isCancelled { return }
        dismiss()
    }
}
