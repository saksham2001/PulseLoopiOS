import Foundation
import SwiftData

/// Readiness retrieval. Read-only by design: a readiness score is derived from measurements the
/// user's ring took, so there is nothing for the model to write. Available whenever readiness is
/// enabled and shared with the coach.
///
/// Every row carries its contributor breakdown, which is the whole reason this tool exists. Without
/// it the model can see a 74 and would have to invent a reason for it; with it the model can say
/// "your HRV was 12% below your baseline" because that is what the app actually computed.
@MainActor
enum ReadinessTools {
    static var readTools: [AnyCoachTool] { [getReadiness] }

    /// A month is enough for "how has my recovery been lately" without flooding the context window.
    private static let maxDays = 31

    private struct RangeArgs: Decodable {
        let startDate: String?
        let endDate: String?
        enum CodingKeys: String, CodingKey {
            case startDate = "start_date"
            case endDate = "end_date"
        }
    }

    private struct ContributorPayload: Encodable {
        let signal: String
        let pointsEarned: Double
        let pointsPossible: Double
        let detail: String
    }

    private struct DayPayload: Encodable {
        let date: String
        let score: Int
        let band: String
        let coverage: Double
        let contributors: [ContributorPayload]
        let notMeasured: [String]
    }

    private struct Result: Encodable {
        let days: [DayPayload]
        let averageScore: Int?
        /// Pinned so a stored score is never reinterpreted under weights it wasn't computed with.
        let algorithmVersion: Int
        /// Present only when there is genuinely nothing to report, so the model says "no scores yet"
        /// rather than inferring poor recovery from an empty list.
        let note: String?
    }

    /// Parse a `YYYY-MM-DD` argument to the start of that local day. nil for absent or unparseable
    /// input, so the caller can fall back to its default window rather than erroring.
    private static func startOfDay(_ value: String?, calendar: Calendar) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        guard let parsed = CoachDataAccess.parseLocalDate(value) else { return nil }
        return calendar.startOfDay(for: parsed)
    }

    /// Flatten one stored row for the model. Split out of the tool body because the nested
    /// map-inside-initializer defeated the type checker.
    private static func payload(for row: ReadinessDaily) -> DayPayload {
        let snapshot = ReadinessSnapshot(row)
        let ranked = snapshot.contributors.sorted { $0.drag > $1.drag }
        var contributors: [ContributorPayload] = []
        contributors.reserveCapacity(ranked.count)
        for record in ranked {
            contributors.append(
                ContributorPayload(
                    signal: record.kind?.rawValue ?? record.kindRaw,
                    pointsEarned: record.earned,
                    pointsPossible: record.maxPoints,
                    detail: record.detail
                )
            )
        }
        return DayPayload(
            date: CoachDataAccess.localDateString(row.date),
            score: row.score,
            band: row.band.rawValue,
            coverage: snapshot.coverage,
            contributors: contributors,
            notMeasured: snapshot.missingKinds.map(\.rawValue)
        )
    }

    // MARK: get_readiness

    private static var getReadiness: AnyCoachTool {
        .make(
            name: "get_readiness",
            label: "Checking your readiness",
            description: "Get daily readiness (recovery) scores with the contributor breakdown that "
                + "produced each one. Readiness is 0–100 from overnight HRV, resting heart rate, "
                + "sleep, skin temperature, and the previous day's training load, each compared "
                + "against the user's own baseline. Use the contributors to explain a score — never "
                + "guess at a reason. Signals in not_measured were not captured and are excluded "
                + "from the score rather than counted as zero. Defaults to the last 7 days.",
            parameters: JSONSchema.object([
                "start_date": ["type": ["string", "null"]],
                "end_date": ["type": ["string", "null"]],
            ], required: ["start_date", "end_date"]),
            argsType: RangeArgs.self
        ) { args, ctx in
            guard ctx.flags.readinessContextEnabled else {
                return .error("readiness is not enabled or not shared with the coach")
            }

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())

            // Inlined rather than a nested func: a nested `func` inside this closure would not
            // inherit its main-actor isolation, and `CoachDataAccess` is main-actor bound.
            let parsedEnd: Date? = Self.startOfDay(args.endDate, calendar: calendar)
            let requestedEnd: Date = parsedEnd ?? today
            let defaultStart: Date = calendar.date(byAdding: .day, value: -6, to: requestedEnd) ?? requestedEnd
            let parsedStart: Date? = Self.startOfDay(args.startDate, calendar: calendar)
            let requestedStart: Date = parsedStart ?? defaultStart

            // Tolerate a reversed range rather than returning nothing — the model occasionally
            // swaps them, and an empty result would read as "no recovery data".
            let start = min(requestedStart, requestedEnd)
            let end = max(requestedStart, requestedEnd)

            // Clamp the window so a wide request can't blow the context budget.
            let earliest = calendar.date(byAdding: .day, value: -(maxDays - 1), to: end) ?? end
            let clampedStart = max(start, earliest)

            let rows = ReadinessRepository.rows(from: clampedStart, to: end, context: ctx.modelContext)
            let days = rows.map { payload(for: $0) }

            let average = days.isEmpty ? nil : days.reduce(0) { $0 + $1.score } / days.count
            return .encoding(
                Result(
                    days: days,
                    averageScore: average,
                    algorithmVersion: ReadinessScore.algorithmVersion,
                    note: days.isEmpty
                        ? "No readiness scores in this range. Readiness needs about a week of "
                            + "overnight wear before it can compare a night to the user's baseline."
                        : nil
                )
            )
        }
    }
}
