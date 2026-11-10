import XCTest
import SwiftData
@testable import PulseLoop

/// Android issue #103: hourly SpO₂ that a YCBT ring computes from heart rate is labelled as estimated.
/// Ports Android's `EstimatedSpo2Test` (11 cases) plus one store-backed case.
final class EstimatedSpO2Tests: XCTestCase {
    private typealias Sample = EstimatedSpO2.Sample

    private let hour: TimeInterval = 3600
    private let start = Date(timeIntervalSince1970: 1_757_000_000)

    /// The reporter's mapping, read off 304 combined (`05 09`) records: HR 48 → 88, 57 → 94, 67–92 → 98, 105 → 96.
    private func ringSpO2(_ hr: Int) -> Int {
        switch hr {
        case ...48: return 88
        case ...57: return 94
        case ...92: return 98
        default: return 96
        }
    }

    private let heartRates = [48, 57, 67, 75, 82, 92, 105, 70]

    /// `hours` hourly combined records, each logged ~34 s past the hour (the end of the ring's HR run).
    private func hourlyTimes(_ hours: Int) -> [Date] {
        (0..<hours).map { start.addingTimeInterval(Double($0) * hour + 34) }
    }

    private struct Ring {
        let spo2: [Sample]
        let respiratory: Set<Date>
        let hr: [Sample]
    }

    private func ring(hours: Int, spo2For: ((Int, Int) -> Int)? = nil) -> Ring {
        let times = hourlyTimes(hours)
        let hrs = times.indices.map { heartRates[$0 % heartRates.count] }
        let spo2For = spo2For ?? { _, hr in self.ringSpO2(hr) }
        return Ring(
            spo2: times.enumerated().map { i, t in Sample(timestamp: t, value: Double(spo2For(i, hrs[i]))) },
            respiratory: Set(times),
            // `05 15` logs the same hourly HR run; a few seconds' skew proves pairing is by proximity,
            // not by identical timestamps.
            hr: times.enumerated().map { i, t in Sample(timestamp: t.addingTimeInterval(-5), value: Double(hrs[i])) }
        )
    }

    private func estimated(_ r: Ring, spo2: [Sample]? = nil, hr: [Sample]? = nil) -> Set<Date> {
        let spo2 = spo2 ?? r.spo2
        return EstimatedSpO2.estimated(spo2: spo2, respiratoryTimestamps: r.respiratory,
                                       evidence: spo2, evidenceRespiratoryTimestamps: r.respiratory,
                                       evidenceHeartRate: hr ?? r.hr)
    }

    func testHourlySpO2ThatIsAFixedFunctionOfHeartRateIsLabelledEstimated() {
        let r = ring(hours: 48)
        XCTAssertEqual(estimated(r), Set(r.spo2.map(\.timestamp)))
    }

    func testSpotReadingIsNeverLabelledEvenBesideAnHourlyHRRow() {
        let r = ring(hours: 48)
        // Spot SpO₂ logged in the combined record with HR and respiration 0: an SpO₂ row and no respiratory row.
        // 90 s after an hourly HR row — inside the pairing window — so the respiratory sibling, not HR
        // proximity, is what decides hourly vs spot.
        let spot = Sample(timestamp: start.addingTimeInterval(10 * hour + 124), value: 99)
        let labelled = estimated(r, spo2: r.spo2 + [spot])
        XCTAssertFalse(labelled.contains(spot.timestamp))
        XCTAssertEqual(labelled.count, r.spo2.count)
    }

    func testRealOximeterDisagreeingWithItselfAtOneHeartRateLabelsNothing() {
        let r = ring(hours: 48) { i, _ in [97, 98, 99, 96, 98][i % 5] }
        XCTAssertTrue(estimated(r).isEmpty)
    }

    func testSingleExceptionToTheMappingWithholdsTheLabel() {
        let r = ring(hours: 48) { i, hr in i == 40 ? self.ringSpO2(hr) - 1 : self.ringSpO2(hr) }
        XCTAssertTrue(estimated(r).isEmpty)
    }

    func testTooLittleHistoryEarnsNoVerdict() {
        let r = ring(hours: EstimatedSpO2.minPairs - 1)
        XCTAssertTrue(estimated(r).isEmpty)
    }

    func testConstantReadingSaysNothingAboutWhereItCameFrom() {
        let r = ring(hours: 48) { _, _ in 98 }
        XCTAssertTrue(estimated(r).isEmpty)
    }

    func testHeartRatesThatNeverRepeatCannotTestTheMapping() {
        let times = hourlyTimes(30)
        let hrs = times.indices.map { 45 + $0 * 2 }   // 30 distinct heart rates
        let spo2 = times.enumerated().map { i, t in Sample(timestamp: t, value: Double(ringSpO2(hrs[i]))) }
        let hr = times.enumerated().map { i, t in Sample(timestamp: t, value: Double(hrs[i])) }
        let respiratory = Set(times)

        XCTAssertFalse(EstimatedSpO2.derivesFromHeartRate(EstimatedSpO2.pairs(hourly: spo2, heartRate: hr)))
        XCTAssertTrue(EstimatedSpO2.estimated(spo2: spo2, respiratoryTimestamps: respiratory,
                                              evidence: spo2, evidenceRespiratoryTimestamps: respiratory,
                                              evidenceHeartRate: hr).isEmpty)
    }

    func testWithoutHeartRateHistoryNothingIsLabelled() {
        let r = ring(hours: 48)
        XCTAssertTrue(estimated(r, hr: []).isEmpty)
    }

    func testPairingTakesTheNearestHeartRateAndIgnoresOneOutsideTheWindow() {
        let at = start.addingTimeInterval(34)
        let hourly = [Sample(timestamp: at, value: 94)]
        let hr = [
            Sample(timestamp: at.addingTimeInterval(-90), value: 70),
            Sample(timestamp: at.addingTimeInterval(20), value: 57),
            Sample(timestamp: at.addingTimeInterval(EstimatedSpO2.pairWindow + 60), value: 48),
        ]
        XCTAssertEqual(EstimatedSpO2.pairs(hourly: hourly, heartRate: hr), [EstimatedSpO2.Pair(heartRate: 57, spo2: 94)])
        let justOutside = [Sample(timestamp: at.addingTimeInterval(EstimatedSpO2.pairWindow + 0.001), value: 57)]
        XCTAssertTrue(EstimatedSpO2.pairs(hourly: hourly, heartRate: justOutside).isEmpty)
    }

    func testOnlyRowsWithARespiratorySiblingAtTheIdenticalTimestampAreHourly() {
        let a = Sample(timestamp: start, value: 98)
        let b = Sample(timestamp: start.addingTimeInterval(hour), value: 99)
        let respiratory: Set<Date> = [start, start.addingTimeInterval(hour + 0.001)]
        XCTAssertEqual(EstimatedSpO2.hourly([a, b], respiratoryTimestamps: respiratory), [a])
    }

    func testLabelsRowsOutsideTheEvidenceWindowOnceTheRingIsJudged() {
        let r = ring(hours: 48)
        // A month-view chart: an older hourly row the 7-day evidence doesn't include still gets the
        // label, because the verdict is about the ring — and a spot row beside it still doesn't.
        let oldHourly = Sample(timestamp: start.addingTimeInterval(-10 * 86_400), value: 94)
        let oldSpot = Sample(timestamp: oldHourly.timestamp.addingTimeInterval(600), value: 99)
        let labelled = EstimatedSpO2.estimated(
            spo2: [oldHourly, oldSpot], respiratoryTimestamps: [oldHourly.timestamp],
            evidence: r.spo2, evidenceRespiratoryTimestamps: r.respiratory, evidenceHeartRate: r.hr
        )
        XCTAssertEqual(labelled, [oldHourly.timestamp])
    }

    // MARK: - Over SwiftData

    /// The store glue reads only the ring's own history rows: a derived ring's hourly rows are labelled,
    /// a live spot reading beside them is not, and the 24h series reports itself as estimated.
    @MainActor
    func testStoreBackedVerdictLabelsHistoryHourlyRowsOnly() throws {
        let context = try TestSupport.makeContext()
        let now = Date()
        let hours = 30
        var hourlyTimes: [Date] = []
        for i in 0..<hours {
            let t = now.addingTimeInterval(-Double(hours - i) * hour + 34)
            hourlyTimes.append(t)
            let hr = heartRates[i % heartRates.count]
            insert(.spo2, Double(ringSpO2(hr)), t, .history, context)
            insert(.respiratoryRate, Double(hr) / 5, t, .history, context)
            insert(.heartRate, Double(hr), t.addingTimeInterval(-5), .history, context)
        }
        let spot = now.addingTimeInterval(-600)
        insert(.spo2, 99, spot, .live, context)
        try context.save()

        let labelled = EstimatedSpO2.estimatedTimestamps(from: now.addingTimeInterval(-86_400 * 2), to: now,
                                                         now: now, context: context)
        XCTAssertEqual(labelled, Set(hourlyTimes))
        XCTAssertFalse(labelled.contains(spot))
        XCTAssertTrue(MetricsService.spo2Series(range: .twentyFourHours, context: context).isEstimated)
    }

    @MainActor
    func testRingWithoutRespiratoryRowsIsNeverJudged() throws {
        let context = try TestSupport.makeContext()
        let now = Date()
        for i in 0..<30 {
            let t = now.addingTimeInterval(-Double(30 - i) * hour)
            let hr = heartRates[i % heartRates.count]
            insert(.spo2, Double(ringSpO2(hr)), t, .history, context)
            insert(.heartRate, Double(hr), t, .history, context)
        }
        try context.save()
        XCTAssertTrue(EstimatedSpO2.estimatedTimestamps(from: now.addingTimeInterval(-86_400 * 2), to: now,
                                                        now: now, context: context).isEmpty)
        XCTAssertFalse(MetricsService.spo2Series(range: .twentyFourHours, context: context).isEstimated)
    }

    @MainActor
    private func insert(_ kind: MeasurementKind, _ value: Double, _ at: Date,
                        _ source: MeasurementSource, _ context: ModelContext) {
        MeasurementRepository.insertMeasurement(kind: kind, value: value, unit: kind.unit, timestamp: at,
                                                source: source, context: context)
    }
}
