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
        case .heartRateComplete:
            log(.sync, .info, "Heart-rate measurement complete")
        case .spo2Complete:
            log(.sync, .info, "SpO₂ measurement complete")
        default:
            break
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
