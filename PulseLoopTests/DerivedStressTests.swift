import XCTest
import SwiftData
@testable import PulseLoop

/// Stress derived from HRV for rings that never report stress (issue #67): person-relative scoring,
/// labelled estimated, and never standing in for a ring's own stress.
@MainActor
final class DerivedStressTests: XCTestCase {
    private let baseline: [Double] = [40, 42, 44, 46, 48, 50, 50, 52, 54, 56, 58, 60]   // median 50, MAD 5

    func testThinBaselineScoresNothing() {
        XCTAssertNil(DerivedStress.score(hrv: 40, baseline: Array(baseline.prefix(11))))
        XCTAssertNil(DerivedStress.score(hrv: 0, baseline: baseline))
    }

    func testScoreIsRelativeToThePersonsOwnHRV() {
        XCTAssertEqual(DerivedStress.score(hrv: 50, baseline: baseline), 50, "at their own median")
        XCTAssertEqual(DerivedStress.score(hrv: 45, baseline: baseline), 75, "one spread below normal")
        XCTAssertEqual(DerivedStress.score(hrv: 55, baseline: baseline), 25, "one spread above normal")
        XCTAssertEqual(DerivedStress.score(hrv: 20, baseline: baseline), 100, "clamped")
        XCTAssertEqual(DerivedStress.score(hrv: 90, baseline: baseline), 0, "clamped")
        // Same reading, a person whose normal is far higher: reads as much more stressed.
        XCTAssertEqual(DerivedStress.score(hrv: 50, baseline: baseline.map { $0 * 2 }), 100)
    }

    func testFlatBaselineFallsBackToAProportionOfTheMedian() {
        let flat = Array(repeating: 50.0, count: 12)
        XCTAssertEqual(DerivedStress.score(hrv: 45, baseline: flat), 75)   // spread = 5 (10% of median)
    }

    func testScoredSeriesKeepsTheSourceIndex() {
        let series = baseline + [45, 55]
        let scored = DerivedStress.scored(series)
        XCTAssertEqual(scored.map(\.index), [12, 13], "the first 12 readings have too thin a baseline")
        XCTAssertEqual(scored.first?.score, 75)
    }

    // MARK: - Where it's used

    private func seedHRVOnlyRing(_ context: ModelContext, now: Date = Date()) {
        context.insert(Device(advertisedName: "R100", state: .connected,
                              capabilities: [.heartRate, .spo2, .steps, .battery, .hrv, .stress]))
        for (i, value) in (baseline + [35]).enumerated() {
            TestSupport.insertMeasurement(kind: .hrv, value: value,
                                          timestamp: now.addingTimeInterval(Double(i - 12) * 1800), into: context)
        }
        try? context.save()
    }

    func testVitalsCardDerivesAndLabelsStressForAnHRVOnlyRing() throws {
        let context = try TestSupport.makeContext()
        seedHRVOnlyRing(context)
        let store = VitalsStore(modelContext: context)
        XCTAssertTrue(store.stressIsDerived)
        let card = try XCTUnwrap(store.cards[.stress])
        XCTAssertTrue(card.isEstimated, "a derived figure is never shown as a measurement")
        XCTAssertFalse(card.isEmpty)
        XCTAssertEqual(card.subtitleText, "Estimated from HRV")
    }

    func testRingsOwnStressIsNeverOverridden() throws {
        let context = try TestSupport.makeContext()
        seedHRVOnlyRing(context)
        // One stress reading, days old — the ring measures stress, it just didn't today.
        TestSupport.insertMeasurement(kind: .stress, value: 30, timestamp: Date().addingTimeInterval(-5 * 86_400), into: context)
        let store = VitalsStore(modelContext: context)
        XCTAssertFalse(store.stressIsDerived)
        XCTAssertFalse(store.cards[.stress]?.isEstimated ?? true)
        XCTAssertFalse(MetricsService.mayDeriveStress(context: context))
    }

    func testDetailWindowDerivesFromThatWindowsHRV() throws {
        let context = try TestSupport.makeContext()
        let now = Date()
        seedHRVOnlyRing(context, now: now)
        let derived = MetricsService.derivedStress(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(1), context: context)
        XCTAssertEqual(derived.count, 1)
        XCTAssertEqual(derived.first?.value, 100, "HRV of 35 against a median of 50")
        XCTAssertEqual(derived.first?.timestamp.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001,
                       "placed at the time of the HRV reading it came from")
        XCTAssertTrue(MetricsService.derivedStress(start: now.addingTimeInterval(60), end: now.addingTimeInterval(120), context: context).isEmpty)
    }
}
