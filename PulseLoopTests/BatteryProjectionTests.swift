import XCTest
@testable import PulseLoop

/// Android issue #65: a runtime estimate from the ring's own battery history, and the chart grid behind
/// it. Ports Android's `BatteryProjectionTest`.
final class BatteryProjectionTests: XCTestCase {
    private typealias Sample = BatteryProjection.Sample

    private let t0 = Date(timeIntervalSince1970: 1_725_000_000)
    private func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }

    /// A steady drain: the slope is the drain rate and the projection is what's left over it.
    func testSteadyDischargeProjectsTheTimeToEmpty() throws {
        // 100 % falling 2 %/h for 10 hours → 80 % left, 40 h remaining.
        let samples = (0...10).map { Sample(timestamp: hours(Double($0)), percent: 100 - 2 * Double($0)) }
        let estimate = try XCTUnwrap(BatteryProjection.estimate(samples))
        XCTAssertEqual(estimate.percentPerHour, 2, accuracy: 0.001)
        XCTAssertEqual(estimate.hoursRemaining, 40, accuracy: 0.01)
        XCTAssertEqual(estimate.label, "1d 16h")
    }

    /// The case that makes a whole-window fit useless: a week almost always contains a charge, and a
    /// line through "falling, then 100 %, then falling" describes when the user plugged in.
    func testChargeStartsANewRunAndOnlyTheRunAfterItIsFitted() throws {
        let discharge = (0...10).map { Sample(timestamp: hours(Double($0)), percent: 60 - 2 * Double($0)) }
        let recharged = (0...10).map { Sample(timestamp: hours(11 + Double($0)), percent: 100 - Double($0)) }

        let run = BatteryProjection.currentDischargeRun(discharge + recharged)
        XCTAssertEqual(run.first?.percent, 100, "the run starts at the charge")
        XCTAssertEqual(run.count, 11)
        let estimate = try XCTUnwrap(BatteryProjection.estimate(discharge + recharged))
        XCTAssertEqual(estimate.percentPerHour, 1, accuracy: 0.001, "the post-charge rate, not the average of both")
    }

    /// Coarse reporting wobbles by a point or two at a plateau; that is not a charge.
    func testSmallWobbleDoesNotSplitTheDischargeRun() {
        let samples = [
            Sample(timestamp: hours(0), percent: 80),
            Sample(timestamp: hours(2), percent: 78),
            Sample(timestamp: hours(4), percent: 79),   // +1, noise
            Sample(timestamp: hours(6), percent: 76),
            Sample(timestamp: hours(8), percent: 74),
        ]
        XCTAssertEqual(BatteryProjection.currentDischargeRun(samples).count, 5)
        XCTAssertNotNil(BatteryProjection.estimate(samples))
    }

    func testNoEstimateFromTooFewSamplesTooShortASpanOrAFlatLine() {
        let tooFew = (0...2).map { Sample(timestamp: hours(Double($0)), percent: 90 - Double($0)) }
        XCTAssertNil(BatteryProjection.estimate(tooFew))

        let tooShort = (0...5).map { Sample(timestamp: hours(Double($0) * 0.1), percent: 90 - Double($0)) }
        XCTAssertNil(BatteryProjection.estimate(tooShort), "half an hour of readings is not a trend")

        let flat = (0...10).map { Sample(timestamp: hours(Double($0)), percent: 90) }
        XCTAssertNil(BatteryProjection.estimate(flat), "a flat line has nothing to project")
    }

    /// The sample/span/fall gates are about the run's shape and none bounds how slow it may be. 5 %-step
    /// firmware clears every one over a week and projects a runtime no ring has.
    func testNoEstimateFromADrainTooSlowToBeOne() {
        // 80 → 75 across a week: 4 samples, 168 h, a 5-point fall — and 0.03 %/h.
        let coarse = [80.0, 79, 77, 75].enumerated().map { Sample(timestamp: hours(Double($0.offset) * 56), percent: $0.element) }
        XCTAssertNil(BatteryProjection.estimate(coarse), "104 days of runtime is not an estimate")
    }

    /// While charging there is no depletion to project, and guessing one would be a lie.
    func testNoEstimateWhileTheBatteryIsRising() {
        let charging = (0...10).map { Sample(timestamp: hours(Double($0) * 0.5), percent: 40 + 2 * Double($0)) }
        XCTAssertNil(BatteryProjection.estimate(charging))
    }

    func testLabelShapes() {
        XCTAssertEqual(BatteryProjection.Estimate(percentPerHour: 1, hoursRemaining: 54).label, "2d 6h")
        XCTAssertEqual(BatteryProjection.Estimate(percentPerHour: 1, hoursRemaining: 18.5).label, "18h")
        XCTAssertEqual(BatteryProjection.Estimate(percentPerHour: 1, hoursRemaining: 0.75).label, "45m")
    }

    func testDayWindowGridsOnSixHourMarksAndWeekWindowOnMidnights() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let dayStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 3, minute: 20)))
        let dayEnd = dayStart.addingTimeInterval(24 * 3600)

        let hourly = BatteryProjection.gridlines(start: dayStart, end: dayEnd, calendar: calendar)
        XCTAssertFalse(hourly.isEmpty)
        for mark in hourly {
            XCTAssertEqual(calendar.component(.minute, from: mark), 0, "on the hour")
            XCTAssertEqual(calendar.component(.hour, from: mark) % 6, 0, "on a six-hour mark")
        }

        let weekEnd = dayStart.addingTimeInterval(7 * 24 * 3600)
        let daily = BatteryProjection.gridlines(start: dayStart, end: weekEnd, calendar: calendar)
        XCTAssertEqual(daily.count, 7)
        for mark in daily {
            XCTAssertEqual(calendar.component(.hour, from: mark), 0, "local midnight")
            XCTAssertEqual(calendar.component(.minute, from: mark), 0)
        }
    }

    /// Every mark must sit inside the plotted window, or it draws off the chart.
    func testGridlinesStayInsideTheWindow() {
        let end = t0.addingTimeInterval(24 * 3600)
        for mark in BatteryProjection.gridlines(start: t0, end: end) {
            XCTAssertTrue(mark > t0 && mark <= end)
        }
        XCTAssertEqual(BatteryProjection.gridlines(start: end, end: t0), [])
    }
}
