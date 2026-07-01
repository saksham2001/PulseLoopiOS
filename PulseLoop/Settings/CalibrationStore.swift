import Foundation

/// User-entered calibration for the metrics the ring can't measure accurately on its own.
///
/// Two distinct mechanisms (both mirrored from the Android port):
/// - **Blood pressure** — the reference cuff systolic/diastolic are pushed to the ring (`0x33`) so it
///   applies an on-device offset, *and* a display offset is applied app-side before the UI.
/// - **Blood sugar** — the ring estimates glucose from the user's profile (no real sensor), so the
///   only calibration is an app-side offset: `glucoseOffsetMgdl = referenceMgdl - latestRawMgdl`.
///
/// Persisted as JSON in `UserDefaults`, mirroring `MetricPrefs` / `MetricPrefsStore`. Raw stored
/// measurements are never modified — offsets are applied only on the display read path.
struct Calibration: Codable, Equatable {
    /// Reference cuff readings (mmHg). 0 ⇒ not calibrated. These are both the values pushed to the
    /// ring via `0x33` and the basis for the app-side display offset.
    var bpReferenceSystolic: Int = 0
    var bpReferenceDiastolic: Int = 0
    /// App-side BP display offsets (mmHg), added to raw ring readings before display.
    var bpSystolicOffset: Int = 0
    var bpDiastolicOffset: Int = 0
    /// Blood-sugar app-side offset (mg/dL) and the last reference reading entered (persisted so the
    /// settings field can repopulate).
    var glucoseOffsetMgdl: Double = 0
    var glucoseRefMgdl: Double = 0

    static let `default` = Calibration()

    init() {}

    /// Tolerant decode: missing keys fall back to defaults instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Calibration.default
        bpReferenceSystolic = try c.decodeIfPresent(Int.self, forKey: .bpReferenceSystolic) ?? d.bpReferenceSystolic
        bpReferenceDiastolic = try c.decodeIfPresent(Int.self, forKey: .bpReferenceDiastolic) ?? d.bpReferenceDiastolic
        bpSystolicOffset = try c.decodeIfPresent(Int.self, forKey: .bpSystolicOffset) ?? d.bpSystolicOffset
        bpDiastolicOffset = try c.decodeIfPresent(Int.self, forKey: .bpDiastolicOffset) ?? d.bpDiastolicOffset
        glucoseOffsetMgdl = try c.decodeIfPresent(Double.self, forKey: .glucoseOffsetMgdl) ?? d.glucoseOffsetMgdl
        glucoseRefMgdl = try c.decodeIfPresent(Double.self, forKey: .glucoseRefMgdl) ?? d.glucoseRefMgdl
    }

    var hasBPReference: Bool { bpReferenceSystolic > 0 && bpReferenceDiastolic > 0 }
    var isGlucoseCalibrated: Bool { glucoseOffsetMgdl != 0 }

    /// Apply the stored display offset to a raw measurement value of the given kind. All other kinds
    /// pass through unchanged.
    func adjusted(_ value: Double, kind: MeasurementKind) -> Double {
        switch kind {
        case .bloodPressureSystolic: return value + Double(bpSystolicOffset)
        case .bloodPressureDiastolic: return value + Double(bpDiastolicOffset)
        case .bloodSugar: return value + glucoseOffsetMgdl
        default: return value
        }
    }
}

/// Observable, UserDefaults-backed store for `Calibration`. Mutating `settings` persists immediately;
/// a shared instance keeps Settings and every vitals view in sync (mirrors `MetricPrefsStore`).
@MainActor
@Observable
final class CalibrationStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = CalibrationStore()

    private static let storageKey = "pulseloop.calibration.v1"
    private let defaults: UserDefaults

    var settings: Calibration {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Calibration.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    /// Save a BP cuff reference (and derive the app-side display offset against the latest raw BP).
    func calibrateBloodPressure(referenceSystolic: Int, referenceDiastolic: Int, latestRawSystolic: Double?, latestRawDiastolic: Double?) {
        var s = settings
        s.bpReferenceSystolic = referenceSystolic
        s.bpReferenceDiastolic = referenceDiastolic
        if let raw = latestRawSystolic { s.bpSystolicOffset = referenceSystolic - Int(raw.rounded()) }
        if let raw = latestRawDiastolic { s.bpDiastolicOffset = referenceDiastolic - Int(raw.rounded()) }
        settings = s
    }

    /// Compute and store the glucose offset from a lab/meter reference and the latest raw reading:
    /// `offset = reference - latestRaw`.
    func calibrateGlucose(referenceMgdl: Double, latestRawMgdl: Double?) {
        var s = settings
        s.glucoseRefMgdl = referenceMgdl
        if let raw = latestRawMgdl { s.glucoseOffsetMgdl = referenceMgdl - raw }
        settings = s
    }

    func resetGlucose() {
        var s = settings
        s.glucoseOffsetMgdl = 0
        s.glucoseRefMgdl = 0
        settings = s
    }

    func resetBloodPressure() {
        var s = settings
        s.bpReferenceSystolic = 0
        s.bpReferenceDiastolic = 0
        s.bpSystolicOffset = 0
        s.bpDiastolicOffset = 0
        settings = s
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
