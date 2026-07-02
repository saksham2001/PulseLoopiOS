import Foundation
import SwiftData

/// Owns the prepared state for `VitalsView`. Previously `body` ran `buildTodaySummary` plus five
/// `metricRange` queries on every render (six aggregations per frame). This store computes them
/// once and reuses the result, rebuilding only when a cheap data-signature changes.
@MainActor
@Observable
final class VitalsStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private(set) var summary: TodaySummary
    private(set) var hrSamples: [MetricSample]
    private(set) var spo2Samples: [MetricSample]
    private(set) var stressSamples: [MetricSample]
    private(set) var hrvSamples: [MetricSample]
    private(set) var tempSamples: [MetricSample]
    // jring/56ff metrics (calibration offsets already applied by `metricRange`).
    private(set) var systolicSamples: [MetricSample]
    private(set) var diastolicSamples: [MetricSample]
    private(set) var bloodSugarSamples: [MetricSample]
    private(set) var fatigueSamples: [MetricSample]
    private(set) var capabilities: Set<WearableCapability>
    /// Which metric cards are visible (capability + user-hidden), computed once per rebuild so the
    /// view doesn't call `isVisible` (a device fetch each) five times per render.
    private(set) var visibleMetrics: Set<MetricKey>
    /// Fully-prepared card view-models keyed by `MetricKind`, computed off the `body` path. Views read
    /// these directly instead of re-interpreting raw samples on every render.
    private(set) var cards: [MetricKind: VitalCardViewModel] = [:]

    private let modelContext: ModelContext
    /// Snapshot of the physiology profile used for thresholds; refreshed each rebuild.
    private var profile: UserProfile?
    private var signature: String = ""

    init(modelContext: ModelContext, profile: UserProfile? = nil) {
        self.modelContext = modelContext
        self.profile = profile
        self.summary = MetricsService.buildTodaySummary(context: modelContext)
        self.hrSamples = MetricsService.metricRange(metric: .heartRate, range: .twentyFourHours, context: modelContext)
        self.spo2Samples = MetricsService.metricRange(metric: .spo2, range: .twentyFourHours, context: modelContext)
        self.stressSamples = MetricsService.metricRange(metric: .stress, range: .twentyFourHours, context: modelContext)
        self.hrvSamples = MetricsService.metricRange(metric: .hrv, range: .twentyFourHours, context: modelContext)
        self.tempSamples = MetricsService.metricRange(metric: .temperature, range: .twentyFourHours, context: modelContext)
        self.systolicSamples = MetricsService.metricRange(metric: .bloodPressureSystolic, range: .twentyFourHours, context: modelContext)
        self.diastolicSamples = MetricsService.metricRange(metric: .bloodPressureDiastolic, range: .twentyFourHours, context: modelContext)
        self.bloodSugarSamples = MetricsService.metricRange(metric: .bloodSugar, range: .twentyFourHours, context: modelContext)
        self.fatigueSamples = MetricsService.metricRange(metric: .fatigue, range: .twentyFourHours, context: modelContext)
        self.capabilities = MetricsService.deviceCapabilities(modelContext)
        self.visibleMetrics = Self.computeVisible(context: modelContext)
        self.cards = [:]
        self.signature = Self.currentSignature(context: modelContext, profile: profile)
        self.cards = buildCards()
    }

    /// Update the physiology profile snapshot used for thresholds. The view passes the latest
    /// `@Query` profile in; a change here invalidates the signature so cards re-interpret.
    func updateProfile(_ profile: UserProfile?) {
        self.profile = profile
        refreshIfNeeded()
    }

    func refreshIfNeeded() {
        let sig = Self.currentSignature(context: modelContext, profile: profile)
        guard sig != signature else { return }
        rebuild(signature: sig)
    }

    func invalidate() {
        rebuild(signature: Self.currentSignature(context: modelContext, profile: profile))
    }

    private func rebuild(signature sig: String) {
        summary = MetricsService.buildTodaySummary(context: modelContext)
        hrSamples = MetricsService.metricRange(metric: .heartRate, range: .twentyFourHours, context: modelContext)
        spo2Samples = MetricsService.metricRange(metric: .spo2, range: .twentyFourHours, context: modelContext)
        stressSamples = MetricsService.metricRange(metric: .stress, range: .twentyFourHours, context: modelContext)
        hrvSamples = MetricsService.metricRange(metric: .hrv, range: .twentyFourHours, context: modelContext)
        tempSamples = MetricsService.metricRange(metric: .temperature, range: .twentyFourHours, context: modelContext)
        systolicSamples = MetricsService.metricRange(metric: .bloodPressureSystolic, range: .twentyFourHours, context: modelContext)
        diastolicSamples = MetricsService.metricRange(metric: .bloodPressureDiastolic, range: .twentyFourHours, context: modelContext)
        bloodSugarSamples = MetricsService.metricRange(metric: .bloodSugar, range: .twentyFourHours, context: modelContext)
        fatigueSamples = MetricsService.metricRange(metric: .fatigue, range: .twentyFourHours, context: modelContext)
        capabilities = MetricsService.deviceCapabilities(modelContext)
        visibleMetrics = Self.computeVisible(context: modelContext)
        cards = buildCards()
        signature = sig
    }

    /// Assemble every card view-model from the current sample arrays + profile. Runs once per rebuild.
    private func buildCards() -> [MetricKind: VitalCardViewModel] {
        let physiology = UserPhysiologyProfile(profile)
        let calibration = CalibrationStore.shared.settings
        let inputs = VitalsCardFactory.Inputs(
            hr: hrSamples, spo2: spo2Samples, hrv: hrvSamples,
            stress: stressSamples, fatigue: fatigueSamples, temperature: tempSamples,
            systolic: systolicSamples, diastolic: diastolicSamples, glucose: bloodSugarSamples,
            summary: summary, range: .twentyFourHours
        )
        var result: [MetricKind: VitalCardViewModel] = [:]
        for metric in MetricKind.allCases {
            result[metric] = VitalsCardFactory.card(metric, inputs: inputs, profile: physiology, calibration: calibration)
        }
        return result
    }

    private static func computeVisible(context: ModelContext) -> Set<MetricKey> {
        var set: Set<MetricKey> = []
        let candidates: [MetricKey] = [.heartRate, .spo2, .stress, .hrv, .temperature,
                                       .bloodPressureSystolic, .bloodSugar, .fatigue]
        for metric in candidates where MetricsService.isVisible(metric, context: context) {
            set.insert(metric)
        }
        return set
    }

    /// Cheap fingerprint of the latest reading of every vitals metric + device state + the inputs that
    /// affect interpretation (physiology profile, calibration offsets). A change here means at least
    /// one chart/value/zone changed, so we rebuild; otherwise we skip the aggregations. Including
    /// profile + calibration means toggling athlete mode or calibrating BP recolors cards immediately,
    /// without waiting for a new measurement.
    private static func currentSignature(context: ModelContext, profile: UserProfile?) -> String {
        func latest(_ kind: MeasurementKind) -> String {
            guard let m = MetricsRepository.latestMeasurement(kind: kind, context: context) else { return "·" }
            return "\(Int(m.value))@\(Int(m.timestamp.timeIntervalSince1970))"
        }
        let device = DeviceRepository.current(context: context)
        let cal = CalibrationStore.shared.settings
        let calSig = "\(cal.bpSystolicOffset)/\(cal.bpDiastolicOffset)/\(cal.glucoseOffsetMgdl)/\(cal.hasBPReference)/\(cal.isGlucoseCalibrated)"
        let profileSig = profile.map { "\(Int($0.updatedAt.timeIntervalSince1970))" } ?? "·"
        return [
            latest(.heartRate), latest(.spo2), latest(.stress), latest(.hrv), latest(.temperature),
            latest(.bloodPressureSystolic), latest(.bloodPressureDiastolic), latest(.bloodSugar), latest(.fatigue),
            device.map { "\($0.batteryPercent)/\($0.state.rawValue)" } ?? "·",
            calSig, profileSig,
        ].joined(separator: "|")
    }
}
