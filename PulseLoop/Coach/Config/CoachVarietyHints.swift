import Foundation

/// Prompt-only variety for the coach's repetitive surfaces (daily check-ins,
/// Today/Sleep cards). Picks a deterministic "coaching angle" from a seed so the
/// same context yields the same angle within a run (idempotent regeneration),
/// while different seeds rotate through fresh framings — avoiding the "every
/// notification opens the same way" fatigue.
///
/// The seed hash is a stable FNV-1a over the UTF-8 bytes — NOT Swift's
/// `hashValue`, which is per-launch randomized and would give a different angle
/// every process for the same seed.
enum CoachVarietyHints {
    /// ~8 distinct framings. Order is fixed so `angle(seed:)` is reproducible.
    static let angles: [String] = [
        "Compare today to yesterday — call out what changed and why it might matter.",
        "Notice a streak or milestone worth celebrating (consecutive active days, a personal best).",
        "Zoom in on a single metric and go one level deeper than usual (e.g. resting HR, deep sleep).",
        "Take a recovery lens — how rested is the body, and what would help it bounce back?",
        "Lead with a genuine question that invites the user to reflect, then ground it in a number.",
        "Lead with one concrete, immediately useful tip tied to today's data.",
        "If weather/location context is available, make the advice weather-aware (outdoor vs indoor, hydration, rain).",
        "Zoom out to the week's trend — is the direction improving, flat, or slipping?",
    ]

    /// Deterministic angle for a seed. Stable across launches (FNV-1a), so
    /// regenerating the same check-in doesn't reshuffle the framing.
    static func angle(seed: String) -> String {
        guard !angles.isEmpty else { return "" }
        let index = Int(fnv1a(seed) % UInt64(angles.count))
        return angles[index]
    }

    /// FNV-1a 64-bit over UTF-8 bytes — a small, stable, non-cryptographic hash.
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}
