import Foundation
import SwiftData

// Readiness rows in the portable archive. Split out of `DataArchive.swift` purely to keep that file
// under SwiftLint's `file_length` error threshold — the DTO contract is identical to the others.

nonisolated struct ArchiveReadinessDaily: Codable, Sendable {
    var id: UUID
    var date: Date
    var score: Int
    var bandRaw: String
    var availablePoints: Double
    var contributorsJSON: String
    var algorithmVersion: Int
    var computedAt: Date
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: ReadinessDaily) {
        id = m.id
        date = m.date
        score = m.score
        bandRaw = m.bandRaw
        availablePoints = m.availablePoints
        contributorsJSON = m.contributorsJSON
        algorithmVersion = m.algorithmVersion
        computedAt = m.computedAt
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ReadinessDaily(
            date: date,
            score: score,
            band: ReadinessBand(rawValue: bandRaw) ?? .moderate,
            availablePoints: availablePoints,
            contributorsJSON: contributorsJSON,
            algorithmVersion: algorithmVersion,
            computedAt: computedAt
        )
        m.id = id
        m.date = date   // init re-derives startOfDay in the local timezone; restore the exact value
        m.bandRaw = bandRaw   // preserve an unknown band verbatim rather than collapsing it
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}
