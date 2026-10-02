import XCTest
@testable import PulseLoop

/// Locks the hypnogram's shared lane geometry (the label/bar alignment fix) and the pure math
/// behind the press-and-hold scrubber: touch-x → minute, minute → block, and the readout text.
final class SleepHypnogramMathTests: XCTestCase {

    // MARK: Lane geometry

    func testLaneFractionsAreOrderedTopToBottom() {
        // Standard hypnogram ordering: awake on top, deep at the bottom.
        let awake = SleepHypnogramView.laneFraction(.awake)
        let rem = SleepHypnogramView.laneFraction(.rem)
        let light = SleepHypnogramView.laneFraction(.light)
        let deep = SleepHypnogramView.laneFraction(.deep)
        XCTAssertLessThan(awake, rem)
        XCTAssertLessThan(rem, light)
        XCTAssertLessThan(light, deep)
        XCTAssertGreaterThan(awake, 0)
        XCTAssertLessThan(deep, 1)
    }

    func testUnknownStageSharesTheLightLane() {
        XCTAssertEqual(SleepHypnogramView.laneFraction(.unknown), SleepHypnogramView.laneFraction(.light))
    }

    // MARK: Touch x → minute

    func testMinuteForXClampsToNight() {
        XCTAssertEqual(SleepHypnogramView.minute(forX: -50, plotWidth: 300, totalMin: 480), 0)
        XCTAssertEqual(SleepHypnogramView.minute(forX: 350, plotWidth: 300, totalMin: 480), 480)
    }

    func testMinuteForXGuardsDegenerateInputs() {
        XCTAssertEqual(SleepHypnogramView.minute(forX: 100, plotWidth: 0, totalMin: 480), 0)
        XCTAssertEqual(SleepHypnogramView.minute(forX: 100, plotWidth: 300, totalMin: 0), 0)
    }

    func testMinuteForXMidpointAndEdges() {
        XCTAssertEqual(SleepHypnogramView.minute(forX: 150, plotWidth: 300, totalMin: 480), 240)
        XCTAssertEqual(SleepHypnogramView.minute(forX: 0, plotWidth: 300, totalMin: 480), 0)
        XCTAssertEqual(SleepHypnogramView.minute(forX: 300, plotWidth: 300, totalMin: 480), 480)
    }

    // MARK: Minute → block

    private let blocks: [(start: Int, duration: Int)] = [
        (start: 0, duration: 58),     // light
        (start: 58, duration: 46),    // deep
        (start: 110, duration: 70),   // light — note the 6-minute seam after the deep block
        (start: 180, duration: 22),   // rem
    ]

    func testBlockIndexEmptyReturnsNil() {
        XCTAssertNil(SleepHypnogramView.blockIndex(atMinute: 10, in: []))
    }

    func testBlockIndexContainment() {
        XCTAssertEqual(SleepHypnogramView.blockIndex(atMinute: 0, in: blocks), 0)
        XCTAssertEqual(SleepHypnogramView.blockIndex(atMinute: 57, in: blocks), 0)
        XCTAssertEqual(SleepHypnogramView.blockIndex(atMinute: 58, in: blocks), 1, "block end is exclusive — minute 58 belongs to the next block")
        XCTAssertEqual(SleepHypnogramView.blockIndex(atMinute: 150, in: blocks), 2)
    }

    func testBlockIndexSnapsGapToNearestBlock() {
        // The 104–110 seam: 105 is closer to the deep block ending at 103, 109 to the light block at 110.
        XCTAssertEqual(SleepHypnogramView.blockIndex(atMinute: 105, in: blocks), 1)
        XCTAssertEqual(SleepHypnogramView.blockIndex(atMinute: 109, in: blocks), 2)
    }

    func testBlockIndexSnapsOutOfRangeToEnds() {
        XCTAssertEqual(SleepHypnogramView.blockIndex(atMinute: -5, in: blocks), 0)
        XCTAssertEqual(SleepHypnogramView.blockIndex(atMinute: 999, in: blocks), 3, "past the last block snaps to it (incl. minute == night end)")
    }

    // MARK: Readout text

    /// 2:15 AM local, matching the TestFlight screenshot's night.
    private var nightStart: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 9
        components.hour = 2; components.minute = 15
        return Calendar.current.date(from: components)!
    }

    /// Fixed locale so the expected AM/PM strings don't depend on the test host's region.
    private let posix = Locale(identifier: "en_US_POSIX")

    func testReadoutTextAbsoluteSameMeridiem() {
        // 50 → 96 min after 2:15 AM: 3:05 – 3:51, both AM, so only the end carries the meridiem.
        let text = SleepHypnogramView.readoutText(stage: .deep, startMinute: 50, durationMinutes: 46,
                                                  startTs: nightStart, locale: posix)
        XCTAssertEqual(text, "DEEP · 3:05 – 3:51 AM")
    }

    func testReadoutTextAbsoluteCrossesMeridiem() {
        // A block spanning 11:45 AM → 12:15 PM: both sides must carry their meridiem.
        let text = SleepHypnogramView.readoutText(stage: .light, startMinute: 570, durationMinutes: 30,
                                                  startTs: nightStart, locale: posix)
        XCTAssertEqual(text, "LIGHT · 11:45 AM – 12:15 PM")
    }

    func testReadoutTextRelativeWhenNoStartTimestamp() {
        // The Coach chart passes startTs == nil; times are offsets from sleep start.
        let text = SleepHypnogramView.readoutText(stage: .deep, startMinute: 58, durationMinutes: 46, startTs: nil)
        XCTAssertEqual(text, "DEEP · 0:58 – 1:44")
    }

    func testReadoutTextRelativeZeroPadsMinutes() {
        let text = SleepHypnogramView.readoutText(stage: .rem, startMinute: 120, durationMinutes: 5, startTs: nil)
        XCTAssertEqual(text, "REM · 2:00 – 2:05")
    }

    // MARK: Accessibility summary

    func testAccessibilitySummaryAggregatesSplitBlocksInLaneOrder() {
        let summary = SleepHypnogramView.accessibilitySummary(stages: [
            (stage: .light, minutes: 58), (stage: .deep, minutes: 46),
            (stage: .light, minutes: 70), (stage: .rem, minutes: 22),
            (stage: .deep, minutes: 29),
        ])
        XCTAssertEqual(summary, "Deep 1 hour 15 minutes, Light 2 hours 8 minutes, REM 22 minutes")
    }

    func testAccessibilitySummarySingularUnits() {
        let summary = SleepHypnogramView.accessibilitySummary(stages: [(stage: .deep, minutes: 61)])
        XCTAssertEqual(summary, "Deep 1 hour 1 minute")
    }

    func testAccessibilitySummaryEmpty() {
        XCTAssertEqual(SleepHypnogramView.accessibilitySummary(stages: []), "No stage data")
    }
}
