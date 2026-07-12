import SwiftData
import Foundation

/// Seeds the readings behind "Explore without ring".
///
/// This exists so someone can see the app work before they own a ring, and it is deliberately *not*
/// silent: every row it writes is tagged `source: .mock`, which is what lets the charts and the coach
/// tell demo data apart from a real vital (`MetricsService.isDemo`).
///
/// It is reached only when **no ring has ever been paired**. A paired-but-disconnected ring is a
/// different situation entirely — that user thinks they are taking a real measurement, so the sheet
/// errors rather than inventing a number for them.
enum MeasurementDemoData {
    struct Reading {
        var value: Int?
        /// Diastolic, for blood pressure.
        var secondary: Int?
        /// Populated for the combined sweep.
        var vitals: RingSyncCoordinator.VitalsReading?
    }

    /// Persist the mock row(s) for `kind` and hand back what the sheet should display.
    @MainActor
    static func seed(_ kind: MeasurementSheet.Kind, context: ModelContext) -> Reading {
        func latest(_ k: MeasurementKind) -> Int? {
            MetricsService.fetchMeasurements(context)
                .first { $0.kind == k }
                .map { Int($0.value) }
        }

        switch kind {
        case .hr, .spo2, .hrv:
            let metric: MeasurementKind = kind == .hr ? .heartRate : (kind == .spo2 ? .spo2 : .hrv)
            MetricsService.insertMockMeasurement(kind: metric, context: context)
            return Reading(value: latest(metric))

        case .bloodPressure:
            // BP is stored as two rows so each trends independently — mock both.
            MetricsService.insertMockMeasurement(kind: .bloodPressureSystolic, context: context)
            MetricsService.insertMockMeasurement(kind: .bloodPressureDiastolic, context: context)
            return Reading(value: latest(.bloodPressureSystolic), secondary: latest(.bloodPressureDiastolic))

        case .vitals:
            // Mock the metrics the jring's combined packet actually carries.
            for metric in [MeasurementKind.heartRate, .spo2, .bloodPressureSystolic, .bloodPressureDiastolic] {
                MetricsService.insertMockMeasurement(kind: metric, context: context)
            }
            var bloodPressure: RingSyncCoordinator.BloodPressureReading?
            if let systolic = latest(.bloodPressureSystolic), let diastolic = latest(.bloodPressureDiastolic) {
                bloodPressure = .init(systolic: systolic, diastolic: diastolic)
            }
            return Reading(vitals: RingSyncCoordinator.VitalsReading(
                heartRate: latest(.heartRate),
                bloodPressure: bloodPressure,
                spo2: latest(.spo2)
            ))
        }
    }
}
