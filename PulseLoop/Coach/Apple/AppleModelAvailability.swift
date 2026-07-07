import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Friendly wrapper over Apple's on-device `SystemLanguageModel` availability so
/// the rest of the app can gate the `appleOnDevice` provider without importing
/// FoundationModels everywhere — and so the project still compiles on an SDK or
/// device where the framework is absent.
enum AppleOnDeviceAvailability: Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// Built against an SDK / running on an OS without FoundationModels.
    case frameworkUnavailable

    /// Current availability of the default system language model.
    static var current: AppleOnDeviceAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .modelNotReady
                }
            @unknown default:
                return .modelNotReady
            }
        } else {
            return .frameworkUnavailable
        }
        #else
        return .frameworkUnavailable
        #endif
    }

    var isAvailable: Bool { self == .available }

    /// One-line, user-facing status for the Settings UI.
    var statusMessage: String {
        switch self {
        case .available:
            return "Ready · runs entirely on your iPhone"
        case .deviceNotEligible:
            return "Not supported on this device — needs an Apple Intelligence-capable iPhone."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to enable on-device coaching."
        case .modelNotReady:
            return "On-device model is preparing — try again shortly."
        case .frameworkUnavailable:
            return "On-device AI requires iOS 26 or later."
        }
    }
}
