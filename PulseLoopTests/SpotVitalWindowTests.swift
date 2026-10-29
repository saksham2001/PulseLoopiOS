import XCTest
@testable import PulseLoop

/// `SpotVitalWindow` settles an on-demand HRV / stress / temperature run the way QRing does: on the last
/// plausible value, one second after the ring stops streaming.
final class SpotVitalWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testSettlesOnTheLastValueOneSecondAfterTheRingGoesQuiet() {
        var window = SpotVitalWindow()
        window.begin(.hrv)
        for (i, ms) in [41.0, 44, 43].enumerated() {
            window.collect(.hrv, value: ms, at: t0.addingTimeInterval(Double(i) * 0.5))
        }
        let last = t0.addingTimeInterval(1)
        XCTAssertFalse(window.isSettled(at: last.addingTimeInterval(0.9)))
        XCTAssertTrue(window.isSettled(at: last.addingTimeInterval(1)))
        XCTAssertEqual(window.settled, 43)
    }

    func testNothingSettlesBeforeAValueArrives() {
        var window = SpotVitalWindow()
        window.begin(.stress)
        XCTAssertFalse(window.isSettled(at: t0.addingTimeInterval(60)))
        XCTAssertNil(window.settled)
        XCTAssertFalse(window.receivedReading)
    }

    func testDropsImplausibleValuesAndValuesFromAnotherVital() {
        var window = SpotVitalWindow()
        window.begin(.temperature)
        XCTAssertFalse(window.collect(.temperature, value: 20, at: t0))   // raw 0 would decode to 20 °C
        XCTAssertFalse(window.collect(.hrv, value: 36.8, at: t0))
        XCTAssertFalse(window.receivedReading)
        XCTAssertTrue(window.collect(.temperature, value: 36.8, at: t0))
        XCTAssertEqual(window.settled, 36.8)
    }

    func testBeginClearsThePreviousRun() {
        var window = SpotVitalWindow()
        window.begin(.stress)
        window.collect(.stress, value: 43, at: t0)
        window.begin(.stress)
        XCTAssertNil(window.settled)
        XCTAssertFalse(window.isSettled(at: t0.addingTimeInterval(10)))
    }
}
