import Foundation
import SwiftData

/// Owns the prepared state for `TodayView` so the SwiftUI `body` is a cheap projection rather than
/// a query engine. `MetricsService.buildTodaySummary` is expensive (it aggregates the day's metrics);
/// previously it ran on every `body` evaluation. This store computes it once and reuses the result,
/// rebuilding only when a cheap data-signature changes (or when explicitly invalidated).
///
/// Beyond the dashboard summary it also prepares the per-metric vitals card view-models the Today
/// grid now renders (gauges for stress/fatigue/glucose/BP, zone charts for HR/SpO₂/HRV/temperature).
/// These are built with the SAME `VitalsCardFactory` the Vitals page uses — but with the **Today**
/// preference scope — so coloring/labels match while visibility and chart detail stay independent.
///
/// Refresh is driven from the view's `.task`; a cheap signature short-circuits no-op rebuilds. It is
/// also invalidated from the coalesced "today data changed" sync signal.
@MainActor
@Observable
final class TodayStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// The cached dashboard summary + its cheap derivations, recomputed together.
    private(set) var summary: TodaySummary
    private(set) var hero: TodayInsights.Hero
    private(set) var capabilities: Set<WearableCapability>
    /// Which metric tiles are visible on Today (capability + user-hidden, Today scope), computed once
    /// per rebuild so the view never calls `isVisible` (a device fetch each) per render.
    private(set) var visibleMetrics: Set<MetricKey>
    /// Fully-prepared vitals card view-models keyed by `MetricKind`, built off the `body` path. The
    /// grid reads these directly instead of re-interpreting raw samples during layout.
    private(set) var cards: [MetricKind: VitalCardViewModel] = [:]
    /// Latest BP series values for the dual-gauge tile.
    private(set) var systolicSamples: [MetricSample]
    private(set) var diastolicSamples: [MetricSample]
    /// HRV samples kept so the HRV chart tile can compute a personal baseline (mirrors Vitals).
    private(set) var hrvSamples: [MetricSample]
    /// The HRV personal baseline, derived once per rebuild. The chart tile used to compute this in
    /// `body`, which meant a full pass over the samples on every re-render (including every frame of
    /// a card drag).
    private(set) var hrvBaseline: BaselineStats?
    /// Bumped whenever `cards` and the sample series are rebuilt. The reorder grid keys cell equality
    /// on this so dragging a card doesn't re-render every Swift Charts tile — see `ReorderCell`.
    private(set) var revision: Int = 0

    private let modelContext: ModelContext
    /// Snapshot of the physiology profile used for thresholds; refreshed each rebuild.
    private var profile: UserProfile?
    /// Signature of the inputs behind the current state; a mismatch triggers a rebuild.
    private var signature: String = ""

    init(modelContext: ModelContext, profile: UserProfile? = nil) {
        self.modelContext = modelContext
        self.profile = profile
        let built = MetricsService.buildTodaySummary(context: modelContext, scope: .today)
        self.summary = built
        self.hero = TodayInsights.deriveHero(built)
        self.capabilities = MetricsService.deviceCapabilities(modelContext)
        self.visibleMetrics = Self.computeVisible(context: modelContext)
        self.systolicSamples = []
        self.diastolicSamples = []
        self.hrvSamples = []
        self.signature = Self.currentSignature(context: modelContext, profile: profile)
        rebuildCards()
    }

    /// Update the physiology profile snapshot used for thresholds. The view passes the latest
    /// `@Query` profile in; a change here invalidates the signature so cards re-interpret.
    func updateProfile(_ profile: UserProfile?) {
        self.profile = profile
        refreshIfNeeded()
    }

    /// Rebuild only if the underlying data changed since the last build. Cheap to call every appear.
    func refreshIfNeeded() {
        let sig = Self.currentSignature(context: modelContext, profile: profile)
        guard sig != signature else { return }
        rebuild(signature: sig)
    }

    /// Force a rebuild regardless of signature (used by the coalesced sync-changed signal).
    func invalidate() {
        rebuild(signature: Self.currentSignature(context: modelContext, profile: profile))
    }

    private func rebuild(signature sig: String) {
        let built = MetricsService.buildTodaySummary(context: modelContext, scope: .today)
        summary = built
        hero = TodayInsights.deriveHero(built)
        capabilities = MetricsService.deviceCapabilities(modelContext)
        visibleMetrics = Self.computeVisible(context: modelContext)
        rebuildCards()
        signature = sig
    }

    /// Fetch the vitals series (Today scope, so its own chart-detail applies) and assemble the card
    /// view-models via the shared factory. Runs once per rebuild, never on the `body` path.
    private func rebuildCards() {
        func series(_ metric: MetricKey) -> [MetricSample] {
            MetricsService.metricRange(metric: metric, range: .twentyFourHours, context: modelContext, scope: .today)
        }
        let hr = series(.heartRate)
        let spo2 = series(.spo2)
        let hrv = series(.hrv)
        let stress = series(.stress)
        let fatigue = series(.fatigue)
        let temperature = series(.temperature)
        let systolic = series(.bloodPressureSystolic)
        let diastolic = series(.bloodPressureDiastolic)
        let glucose = series(.bloodSugar)

        systolicSamples = systolic
        diastolicSamples = diastolic
        hrvSamples = hrv
        hrvBaseline = BaselineStats.compute(hrv)

        let physiology = UserPhysiologyProfile(profile)
        let calibration = CalibrationStore.shared.settings
        let inputs = VitalsCardFactory.Inputs(
            hr: hr, spo2: spo2, hrv: hrv,
            stress: stress, fatigue: fatigue, temperature: temperature,
            systolic: systolic, diastolic: diastolic, glucose: glucose,
            summary: summary, range: .twentyFourHours, units: profile?.units ?? .metric
        )
        var result: [MetricKind: VitalCardViewModel] = [:]
        for metric in MetricKind.allCases {
            result[metric] = VitalsCardFactory.card(metric, inputs: inputs, profile: physiology, calibration: calibration)
        }
        cards = result
        // Sole mutator of `cards` + the series, so "revision changed" is exactly "a tile's data changed".
        revision &+= 1
    }

    /// The Today-scope visible metric set (device capability gate + user Today-scope hidden set).
    private static func computeVisible(context: ModelContext) -> Set<MetricKey> {
        var set: Set<MetricKey> = []
        let candidates: [MetricKey] = [.steps, .heartRate, .spo2, .stress, .hrv, .temperature,
                                       .bloodPressureSystolic, .bloodSugar, .fatigue, .sleep, .calories]
        for metric in candidates where MetricsService.isVisible(metric, context: context, scope: .today) {
            set.insert(metric)
        }
        return set
    }

    /// A cheap fingerprint of everything that can change the Today dashboard, assembled from
    /// `fetchLimit:1`-style probes rather than a full summary build. If this is unchanged, the
    /// summary + every card is unchanged, so we skip the expensive rebuild. Includes the vitals
    /// metrics the grid now shows plus the interpretation inputs (physiology profile, calibration).
    private static func currentSignature(context: ModelContext, profile: UserProfile?) -> String {
        func latest(_ kind: MeasurementKind) -> String {
            guard let m = MetricsRepository.latestMeasurement(kind: kind, context: context) else { return "·" }
            return "\(Int(m.value))@\(Int(m.timestamp.timeIntervalSince1970))"
        }
        let activity = MetricsRepository.latestActivity(context: context)
        let sleep = SleepRepository.latestSession(context: context)
        let device = DeviceRepository.current(context: context)
        let cal = CalibrationStore.shared.settings
        let calSig = "\(cal.bpSystolicOffset)/\(cal.bpDiastolicOffset)/\(cal.glucoseOffsetMgdl)/\(cal.hasBPReference)/\(cal.isGlucoseCalibrated)"
        let profileSig = profile.map { "\(Int($0.updatedAt.timeIntervalSince1970))" } ?? "·"

        func stamp(_ date: Date?) -> String { date.map { String(Int($0.timeIntervalSince1970)) } ?? "·" }

        return [
            latest(.heartRate), latest(.spo2), latest(.stress), latest(.hrv), latest(.temperature),
            latest(.bloodPressureSystolic), latest(.bloodPressureDiastolic), latest(.bloodSugar), latest(.fatigue),
            activity.map { "\($0.steps)/\(Int($0.distanceMeters))/\($0.activeMinutes)@\(stamp($0.syncedAt))" } ?? "·",
            sleep.map { "\($0.totalMinutes)@\(stamp($0.syncedAt))" } ?? "·",
            device.map { "\($0.batteryPercent)/\($0.state.rawValue)@\(stamp($0.lastSyncAt))" } ?? "·",
            calSig, profileSig,
        ].joined(separator: "|")
    }
}
