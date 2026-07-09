import XCTest
@testable import PulseLoop

/// Pure crossing-engine tests for the ring low-battery alerts — no DB, no notifications. State is
/// threaded through consecutive `evaluate()` calls the way the monitor drives it on the sparse
/// battery stream.
final class BatteryAlertEngineTests: XCTestCase {
    private let today = "2026-07-08"

    /// Run a sequence of percents through the engine, returning the alert (if any) for each.
    @discardableResult
    private func run(_ percents: [Int], dateKey: String? = nil, from initial: BatteryAlertState = BatteryAlertState())
        -> (alerts: [BatteryAlertKind?], state: BatteryAlertState) {
        var state = initial
        var alerts: [BatteryAlertKind?] = []
        for p in percents {
            let (alert, next) = BatteryAlertEngine.evaluate(percent: p, state: state, dateKey: dateKey ?? today)
            alerts.append(alert)
            state = next
        }
        return (alerts, state)
    }

    func testLowFiresOnceOnCrossing() {
        let alerts = run([22, 18, 17]).alerts
        XCTAssertNil(alerts[0])                       // above threshold
        XCTAssertEqual(alerts[1], .low(percent: 18))  // first below-20
        XCTAssertNil(alerts[2])                       // still low → latched, no re-fire
    }

    func testStraightDropFiresOnlyCritical() {
        let alerts = run([25, 8, 15]).alerts
        XCTAssertNil(alerts[0])                            // above everything
        XCTAssertEqual(alerts[1], .critical(percent: 8))  // most-severe only, low latched too
        XCTAssertNil(alerts[2])                            // 15 < 20 but low stays latched
    }

    func testFirstEverSampleBelowThresholdFires() {
        // A fresh state whose first observed sample is already below 20 (jring "connected at 17%").
        let alerts = run([17]).alerts
        XCTAssertEqual(alerts[0], .low(percent: 17))
    }

    func testHysteresisReArmsOnRecharge() {
        let alerts = run([18, 22, 26, 19]).alerts
        XCTAssertEqual(alerts[0], .low(percent: 18))  // fires
        XCTAssertNil(alerts[1])                       // 22: still below re-arm band (25), stays latched
        XCTAssertNil(alerts[2])                       // 26: >= re-arm, clears latch (no alert on a rise)
        XCTAssertEqual(alerts[3], .low(percent: 19))  // re-armed → fires again
    }

    func testCriticalReArmsWhileLowStaysLatched() {
        // Fire critical at 8, then rise to 16 (>= criticalRearm 15 but < lowRearm 25): critical
        // re-arms, low stays latched, then drop back below 10 re-fires only critical.
        var (alerts, state) = run([8])
        XCTAssertEqual(alerts[0], .critical(percent: 8))
        XCTAssertTrue(state.firedLow)

        (alerts, state) = run([16], from: state)
        XCTAssertNil(alerts[0])
        XCTAssertFalse(state.firedCritical)  // critical re-armed
        XCTAssertTrue(state.firedLow)        // low still latched (16 < lowRearm 25)

        (alerts, state) = run([9], from: state)
        XCTAssertEqual(alerts[0], .critical(percent: 9))
    }

    func testNewDateKeyResetsBothLatches() {
        let first = run([8])   // fires critical, latches both
        XCTAssertEqual(first.alerts[0], .critical(percent: 8))

        // Same low reading on a new day → both latches reset, so it fires again.
        let (alert, state) = BatteryAlertEngine.evaluate(percent: 18, state: first.state, dateKey: "2026-07-09")
        XCTAssertEqual(alert, .low(percent: 18))
        XCTAssertEqual(state.dateKey, "2026-07-09")
    }

    func testPlaceholderAndOutOfRangeIgnored() {
        for bad in [0, -1, 101] {
            let state = BatteryAlertState(dateKey: today, firedLow: false, firedCritical: false)
            let (alert, next) = BatteryAlertEngine.evaluate(percent: bad, state: state, dateKey: today)
            XCTAssertNil(alert, "percent \(bad) should not alert")
            XCTAssertEqual(next, state, "percent \(bad) should not mutate state")
        }
    }

    func testThresholdBoundaries() {
        // Each from a fresh state: only strictly-below fires, and 10 is below-20 (low) not below-10.
        XCTAssertNil(run([20]).alerts[0])                       // 20: not below 20
        XCTAssertEqual(run([19]).alerts[0], .low(percent: 19))  // 19: below 20
        XCTAssertEqual(run([10]).alerts[0], .low(percent: 10))  // 10: below 20, not below 10
        XCTAssertEqual(run([9]).alerts[0], .critical(percent: 9))
    }
}
