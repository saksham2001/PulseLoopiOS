import Foundation

/// Token accounting for one model call (or a summed agent turn). Populated by
/// each `ResponsesClient` from the provider's usage block; `nil` fields mean the
/// provider didn't report that figure. `reportedCostUSD` is set only when the
/// provider returns an exact cost (OpenRouter) — otherwise the catalog estimates it.
struct CoachTokenUsage: Sendable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    /// Cached (prompt-cache-hit) input tokens, a subset of `inputTokens`. 0 when
    /// the provider doesn't report caching.
    var cachedInputTokens: Int
    /// Exact USD cost when the provider bills it back (OpenRouter). `nil` → estimate
    /// from the pricing catalog.
    var reportedCostUSD: Double?

    init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, reportedCostUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reportedCostUSD = reportedCostUSD
    }

    /// Sums another call's usage into this one. Costs add when both sides report
    /// one (or one side is nil → keep the present value); tokens always add.
    mutating func add(_ other: CoachTokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cachedInputTokens += other.cachedInputTokens
        switch (reportedCostUSD, other.reportedCostUSD) {
        case let (lhs?, rhs?): reportedCostUSD = lhs + rhs
        case (nil, let rhs?): reportedCostUSD = rhs
        default: break  // keep lhs (possibly nil)
        }
    }
}
