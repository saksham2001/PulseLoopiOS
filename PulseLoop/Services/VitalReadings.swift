import Foundation
import SwiftData

/// One stored reading as the detail screen's READINGS list shows it (issue #60). Values are in
/// canonical units (°C, mg/dL) with the calibration offset applied — the same values the chart plots.
struct VitalReading: Identifiable, Equatable {
    /// The primary row's id (the systolic row for blood pressure) — what a delete resolves.
    let id: UUID
    let timestamp: Date
    let value: Double
    /// The diastolic half of a blood-pressure reading; nil for every other metric.
    let secondary: Double?
    /// Ring-estimated metrics (blood pressure, glucose) and hourly SpO₂ a ring computed from heart rate
    /// (`EstimatedSpO2`) are never shown unlabelled.
    let isEstimated: Bool
}

/// Reads and deletes the individual rows behind a vital's detail window. Raw rows, never the
/// display-downsampled chart series — a bucket average isn't something a user can delete.
@MainActor
enum VitalReadings {

    /// The stored kind a detail metric lists (systolic stands for a blood-pressure reading).
    static func primaryKind(for metric: MetricKind) -> MeasurementKind {
        switch metric {
        case .heartRate: return .heartRate
        case .spo2: return .spo2
        case .hrv: return .hrv
        case .bloodPressure: return .bloodPressureSystolic
        case .stress: return .stress
        case .fatigue: return .fatigue
        case .glucose: return .bloodSugar
        case .temperature: return .temperature
        }
    }

    static func isEstimated(_ metric: MetricKind) -> Bool {
        metric == .bloodPressure || metric == .glucose
    }

    /// The window's readings, newest first. `[start, end)`. Estimated hourly SpO₂ follows the chart's
    /// rule: dropped while "Hide estimated SpO₂" is on (the default), tagged "Estimated" when it's off.
    static func load(metric: MetricKind, start: Date, end: Date, limit: Int = 10_000,
                     calibration: Calibration? = nil, hideEstimatedSpO2: Bool? = nil,
                     context: ModelContext) -> [VitalReading] {
        let calibration = calibration ?? CalibrationStore.shared.settings
        let kind = primaryKind(for: metric)
        var rows = fetch(kind: kind, start: start, end: end, limit: limit, context: context)
        var estimatedSpO2: Set<Date> = []
        if metric == .spo2, let newest = rows.first?.timestamp, let oldest = rows.last?.timestamp {
            estimatedSpO2 = EstimatedSpO2.estimatedTimestamps(from: oldest, to: newest, context: context)
            if !estimatedSpO2.isEmpty, hideEstimatedSpO2 ?? MetricPrefsStore.shared.settings.hideEstimatedSpO2 {
                rows.removeAll { estimatedSpO2.contains($0.timestamp) }
                estimatedSpO2 = []
            }
        }
        var diastolic: [Date: Double] = [:]
        if metric == .bloodPressure {
            for row in fetch(kind: .bloodPressureDiastolic, start: start, end: end, limit: limit, context: context) {
                diastolic[row.timestamp] = diastolic[row.timestamp] ?? row.value
            }
        }
        let estimated = isEstimated(metric)
        return rows.map { row in
            VitalReading(
                id: row.id,
                timestamp: row.timestamp,
                value: calibration.adjusted(row.value, kind: kind),
                secondary: diastolic[row.timestamp].map { calibration.adjusted($0, kind: .bloodPressureDiastolic) },
                isEstimated: estimated || estimatedSpO2.contains(row.timestamp)
            )
        }
    }

    /// Delete one listed reading (both halves for blood pressure), tombstoned against re-sync.
    @discardableResult
    static func delete(_ reading: VitalReading, context: ModelContext) -> Int {
        let id = reading.id
        var descriptor = FetchDescriptor<Measurement>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return 0 }
        return MeasurementDeletionService.deleteReading(row, context: context)
    }

    private static func fetch(kind: MeasurementKind, start: Date, end: Date, limit: Int,
                              context: ModelContext) -> [Measurement] {
        let raw = kind.rawValue
        var descriptor = FetchDescriptor<Measurement>(
            predicate: #Predicate { $0.kindRaw == raw && $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}
