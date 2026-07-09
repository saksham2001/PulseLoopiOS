import Foundation

/// What a connected wearable can actually do. The active device's `Set<WearableCapability>` is the
/// single source the product UI consults to decide which metric cards / actions to render — a jring
/// hides HRV/Stress/Temperature because it never declares them, a Colmi R02 shows them.
///
/// Borrowed (in spirit) from GadgetBridge's `DeviceCoordinator.supportsX()` capability queries, but
/// collapsed into one enum so capabilities can be persisted as a CSV on `Device` and gated in SwiftUI
/// without a per-feature boolean sprawl.
///
/// Raw values are persisted (see `Device.capabilitiesRaw`); **append cases, never rename/reorder.**
enum WearableCapability: String, CaseIterable, Codable, Sendable {
    // Shared by jring + Colmi
    case heartRate
    case spo2
    case steps
    case sleep
    case battery

    // Colmi R02 (today): richer metrics jring lacks
    case remSleep
    case stress
    case hrv
    case temperature

    // jring/56ff (today): metrics from the 0x24 combined-sensor packet that Colmi lacks. Colmi must
    // NOT declare these — it has no BP/blood-sugar sensor.
    case bloodPressure
    case bloodSugar
    case fatigue

    // Interaction capabilities
    case manualHeartRate      // single-shot on-demand HR
    case manualSpo2           // single-shot on-demand SpO2 (jring; Colmi has no instant SpO2)
    case manualHrv            // single-shot on-demand HRV (TK5: rides the same live stream as HR)
    case realtimeHeartRate    // live HR stream
    case realtimeSteps        // live activity stream
    case findDevice
    case powerOff
    case factoryReset

    // Configurable all-day measurement: the device exposes a settable HR sampling interval and
    // per-vital monitoring toggles (Colmi `0x16` + prefs). The generic jring has no such control, so
    // it never surfaces it and the Measurement settings screen stays hidden for it.
    case measurementInterval

    // The device records all-day SpO2 on-ring and the app can read that log back (Colmi big-data
    // `0xbc 0x2a`). Drives the workout vitals plan: a device with no `manualSpo2` but with this
    // capability shows the latest logged value instead of pretending it can spot-measure.
    case spo2History
}

extension Set where Element == WearableCapability {
    /// Serialize to a stable comma-separated string for SwiftData storage.
    var csv: String {
        WearableCapability.allCases
            .filter { contains($0) }   // deterministic order
            .map(\.rawValue)
            .joined(separator: ",")
    }

    /// Parse from the CSV form. Unknown tokens are ignored so older/newer stores stay forward-compatible.
    init(csv: String) {
        let parsed = csv
            .split(separator: ",")
            .compactMap { WearableCapability(rawValue: String($0)) }
        self = Set(parsed)
    }
}
