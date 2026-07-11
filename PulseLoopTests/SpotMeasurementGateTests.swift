import XCTest
@testable import PulseLoop

/// The fast-fail rule for a **refused** spot measurement.
///
/// A YCBT ring answers `03 2f` with a verdict, and the owner's Colmi R99 uses it: it refuses the HRV
/// start (mode `0x0a` → status `0x01`) because it has no HRV sensor. `RingSyncCoordinator` used to poll
/// that ring — which had already said no — for the full 45-second window before reporting a generic
/// failure. It now aborts on the refusal.
///
/// The danger in aborting on a device-pushed signal is aborting the *wrong* thing, so the rule lives in
/// `SpotMeasurementGate`, a value type: a refusal may only ever cancel the measurement it names, while
/// that measurement is actually running. These are the cases that must never regress. (The coordinator
/// itself owns live BLE/SwiftData wiring and is not constructed in the unit suite; this is the piece of
/// it where the correctness lives.)
///
/// Ownership is by token because **spot measurements really do overlap**: a recording workout's
/// `WorkoutSensorPollingService` fires `measureHR()`/`measureSpO2()` on its own timer while the user can
/// start a BP or HRV reading from the Measurement modal, the calibration screen, or the coach's action
/// tools — and nothing serializes those flows against each other.
final class SpotMeasurementGateTests: XCTestCase {

    /// The R99's case: the ring refuses the measurement we are running, and the poll gives up at once.
    func testARefusalOfTheMeasurementInFlightAbortsIt() {
        var gate = SpotMeasurementGate()
        let hrv = gate.begin(mode: YCBTMeasurementMode.hrv)
        XCTAssertFalse(gate.isRejected(hrv))

        gate.noteRejected(mode: YCBTMeasurementMode.hrv)

        XCTAssertTrue(gate.isRejected(hrv))
    }

    /// **It must not cancel a measurement it doesn't name.** A refusal for one mode arriving while
    /// another is being polled (a late reply from a previous sweep; a workout HR restart that raced into
    /// the write queue mid-SpO₂) leaves the running measurement alone.
    func testARefusalOfADifferentModeCannotAbortTheOneInFlight() {
        var gate = SpotMeasurementGate()
        let spo2 = gate.begin(mode: YCBTMeasurementMode.spo2)

        gate.noteRejected(mode: YCBTMeasurementMode.hrv)
        gate.noteRejected(mode: YCBTMeasurementMode.heartRate)

        XCTAssertFalse(gate.isRejected(spo2), "only the measurement the ring actually named may be aborted")
    }

    /// Nothing in flight ⇒ nothing to abort. This is what keeps a stray refusal off a **workout HR
    /// stream**: streaming is not a spot measurement, it never arms the gate, and it must survive
    /// anything that happens to a spot reading.
    func testARefusalWithNoMeasurementInFlightIsIgnored() {
        var gate = SpotMeasurementGate()
        XCTAssertTrue(gate.modesInFlight.isEmpty)

        gate.noteRejected(mode: YCBTMeasurementMode.heartRate)

        XCTAssertTrue(gate.modesInFlight.isEmpty)
    }

    /// A refusal that lands after the window already closed cannot fail the *next* measurement: `end`
    /// retires the token, and a fresh `begin` hands out a new one that nothing has refused.
    func testARefusalCannotLeakIntoTheNextMeasurement() {
        var gate = SpotMeasurementGate()
        let hrv = gate.begin(mode: YCBTMeasurementMode.hrv)
        gate.noteRejected(mode: YCBTMeasurementMode.hrv)
        XCTAssertTrue(gate.isRejected(hrv))

        gate.end(hrv)
        gate.noteRejected(mode: YCBTMeasurementMode.hrv)   // a late duplicate, after we gave up
        XCTAssertFalse(gate.isRejected(hrv), "a retired measurement has no window left to cut short")

        let spo2 = gate.begin(mode: YCBTMeasurementMode.spo2)
        XCTAssertFalse(gate.isRejected(spo2), "a fresh measurement starts clean")
    }

    /// The ring accepting a start (`03 2f` → `0x00`) decodes to a plain ack, so nothing ever calls
    /// `noteRejected` — the measurement runs its window out, exactly as before. Belt and braces: even the
    /// mode we are running cannot abort us unless a refusal is actually reported.
    func testAnAcceptedMeasurementIsNeverAborted() {
        var gate = SpotMeasurementGate()
        let spo2 = gate.begin(mode: YCBTMeasurementMode.spo2)

        XCTAssertFalse(gate.isRejected(spo2))
        XCTAssertEqual(gate.modesInFlight, [YCBTMeasurementMode.spo2])
    }

    // MARK: - Concurrent measurements

    /// **The wrong-cancel.** A workout HR poll is in flight when the user's BP start is refused. With one
    /// shared `isRejected` flag the HR poll's abort closure — which never asked *whose* refusal it was —
    /// tripped too, and the workout lost an HR reading the ring had said nothing about. A refusal must
    /// abort exactly the measurement it names, and nothing else.
    func testARefusalAbortsOnlyTheMeasurementItNamesWhenTwoAreInFlight() {
        var gate = SpotMeasurementGate()
        let hr = gate.begin(mode: YCBTMeasurementMode.heartRate)          // the workout's timer poll
        let bp = gate.begin(mode: YCBTMeasurementMode.bloodPressure)      // the user's BP reading

        gate.noteRejected(mode: YCBTMeasurementMode.bloodPressure)

        XCTAssertTrue(gate.isRejected(bp))
        XCTAssertFalse(gate.isRejected(hr), "the ring refused BP — the workout's HR poll was never named")
    }

    /// **The missed abort.** The second measurement to start must not displace the first: with one slot,
    /// `begin(bp)` overwrote HR's mode, so HR's own refusal no longer matched anything and the poll spun
    /// its entire window — the very failure the fast-fail exists to prevent, reintroduced by an overlap.
    func testASecondMeasurementDoesNotDisplaceTheFirstsClaimOnItsMode() {
        var gate = SpotMeasurementGate()
        let hr = gate.begin(mode: YCBTMeasurementMode.heartRate)
        let bp = gate.begin(mode: YCBTMeasurementMode.bloodPressure)

        gate.noteRejected(mode: YCBTMeasurementMode.heartRate)

        XCTAssertTrue(gate.isRejected(hr), "HR is still in flight — its refusal must still reach it")
        XCTAssertFalse(gate.isRejected(bp))
    }

    /// **The premature disarm.** Whichever measurement finishes first used to call `end()` unconditionally,
    /// disarming the gate for the one still running: its refusal then arrived to an empty gate and was
    /// dropped. Retiring a token may only ever retire that token.
    func testEndingOneMeasurementLeavesTheOtherArmed() {
        var gate = SpotMeasurementGate()
        let hr = gate.begin(mode: YCBTMeasurementMode.heartRate)
        let bp = gate.begin(mode: YCBTMeasurementMode.bloodPressure)

        gate.end(bp)   // the BP reading returns first
        XCTAssertEqual(gate.modesInFlight, [YCBTMeasurementMode.heartRate])

        gate.noteRejected(mode: YCBTMeasurementMode.heartRate)
        XCTAssertTrue(gate.isRejected(hr), "HR was still mid-poll when the ring refused it")
    }
}
