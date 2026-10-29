import Foundation
import SwiftData

/// Subscribes to `PulseEventBus` and records high-level connection / sync / battery / error events
/// into the structured `WearableLog` store. Mirrors the wiring of `EventPersistenceSubscriber`
/// (init with a `ModelContext`, `start()` spawns a task consuming the bus stream).
///
/// Deliberately records *events*, not packets — the raw byte trace stays in `RawPacketRow` (DEBUG).
@MainActor
final class DiagnosticsSubscriber {
    private let context: ModelContext
    private var task: Task<Void, Never>?
    private var activeDeviceType: RingDeviceType?

    init(context: ModelContext) {
        self.context = context
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            let stream = await PulseEventBus.shared.stream()
            for await event in stream {
                await MainActor.run { self.record(event) }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func record(_ event: PulseEvent) {
        switch event {
        case let .deviceStateChanged(state, _):
            log(.connection, .info, "Connection state: \(state.rawValue)")
        case let .deviceIdentified(deviceType, wearableModelID, _, capabilities):
            activeDeviceType = deviceType
            let displayName = WearableModel.model(id: wearableModelID)?.displayName ?? deviceType.displayName
            log(.connection, .info, "Identified \(displayName)",
                metadata: ["capabilities": capabilities.csv])
        case .deviceForgotten:
            log(.connection, .info, "Forgot wearable")
            activeDeviceType = nil
        case let .batteryLevel(percent):
            log(.battery, .info, "Battery \(percent)%")
        case let .syncProgress(stage):
            log(.sync, .info, "Sync: \(stage)")
        case let .rwfitDiagnostic(message, metadata):
            log(.sync, .info, message, metadata: metadata)
        case let .rwfitInitialization(state):
            log(.connection, .info, "RwFit initialization: \(state)")
        case let .rwfitMeasurement(type, status):
            log(.sync, .info, "RwFit measurement status", metadata: ["type": String(type), "status": String(status)])
        case let .rwfitMeasurementOutcome(outcome):
            log(.sync, .info, "RwFit measurement outcome: \(outcome)")
        case let .rwfitSyncOutcome(outcome):
            recordRWfitOutcome(outcome)
        case .heartRateComplete:
            log(.sync, .info, "Heart-rate measurement complete")
        case .spo2Complete:
            log(.sync, .info, "SpO₂ measurement complete")
        default:
            break
        }
    }

    private func recordRWfitOutcome(_ outcome: RWfitSyncOutcome) {
        switch outcome {
        case let .success(records):
            log(.sync, .info, "RwFit sync complete", metadata: ["importedRecords": String(records)])
        case let .partial(records, reason):
            log(.sync, .warn, "RwFit sync incomplete", metadata: ["importedRecords": String(records), "reason": reason])
        case let .failed(reason):
            log(.error, .error, "RwFit sync failed", metadata: ["reason": reason])
        case .cancelled:
            log(.sync, .info, "RwFit sync cancelled")
        }
    }

    private func log(_ category: WearableLogCategory, _ level: WearableLogLevel, _ message: String, metadata: [String: String]? = nil) {
        let json = metadata.flatMap { dict -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        context.insert(WearableLog(deviceType: activeDeviceType, category: category, level: level, message: message, metadataJSON: json))
        try? context.save()
    }
}
