import Foundation

enum RWfitInitializationState: Sendable, Equatable {
    case initializing
    case ready
    case failed(String)
}

enum RWfitSyncOutcome: Sendable, Equatable {
    case success(records: Int)
    case partial(records: Int, reason: String)
    case failed(reason: String)
    case cancelled
}

enum RWfitMeasurementOutcome: Sendable, Equatable {
    case failed(type: UInt8, reason: String)
    case completed(type: UInt8, receivedReading: Bool)
    case cancelled(type: UInt8)
}

enum RWfitSessionError: LocalizedError {
    case unavailable, timeout, cancelled, invalidResponse, authentication, persistence

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The ring is not ready. Reconnect and try again."
        case .timeout: return "The ring did not respond. Keep it nearby and try syncing again."
        case .cancelled: return "The ring operation was cancelled."
        case .invalidResponse: return "The ring returned an incomplete or unrecognized response."
        case .authentication: return "The ring rejected its default password. Check its password in RwFit and reconnect."
        case .persistence: return "History could not be saved. The ring's records have been preserved."
        }
    }
}

@MainActor
func rwfitDiagnostic(_ message: String, _ metadata: [String: String] = [:]) {
    Task { await PulseEventBus.shared.publish(.rwfitDiagnostic(message: message, metadata: metadata)) }
}
