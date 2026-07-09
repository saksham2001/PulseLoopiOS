import Foundation

/// How much context to pack into a turn. `.full` is the cloud default; `.compact`
/// trims the packet (and system prompt + history) for the tiny on-device Apple
/// model, whose context window is small and which is tool-less. The packet SHAPE
/// is identical between the two — only the contents are trimmed — so encoders and
/// tools are untouched.
enum CoachContextBudget {
    case full
    case compact

    /// Max durable memories embedded in the packet.
    var maxMemories: Int { self == .compact ? 3 : 8 }
    /// Max recent workouts embedded in the packet.
    var maxWorkouts: Int { self == .compact ? 2 : 8 }
    /// Max data-quality warnings embedded in the packet.
    var maxWarnings: Int { self == .compact ? 2 : Int.max }
    /// Character cap on each memory `value` (long notes are truncated).
    var memoryValueCap: Int { self == .compact ? 120 : Int.max }
    /// Character cap on the rolling conversation summary.
    var conversationSummaryCap: Int { self == .compact ? 400 : Int.max }
    /// Max prior conversation turns replayed to the model.
    var historyTurns: Int { self == .compact ? 4 : 10 }
}

extension CoachFeatureFlags {
    /// Compact on-device, full everywhere else. The tiny local model needs a
    /// smaller packet + prompt; cloud models don't.
    var contextBudget: CoachContextBudget {
        settings.providerMode == .appleOnDevice ? .compact : .full
    }
}
