import Foundation

/// jring sync engine. The jring is fire-and-forget: the startup sequence enqueues all commands up
/// front and the device streams replies, so `handle(_:)` is a no-op (no response-driven machine).
///
/// Command construction is lifted verbatim from the old `RingSyncCoordinator.runStartupSequence`
/// and the measurement helpers, via the existing `RingEncoder` — behavior is unchanged.
@MainActor
final class JringSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let encoder = RingEncoder()

    init(writer: RingCommandWriter?) {
        self.writer = writer
    }

    func runStartup() {
        // Canonical startup: status → time sync → locale → activity query → history → history measurements.
        writer?.enqueue(encoder.makeStatusCommand())
        writer?.enqueue(encoder.makeTimeSyncCommand())
        writer?.enqueue(encoder.makeLocaleCommand())
        writer?.enqueue(encoder.makeActivityQueryCommand())
        writer?.enqueue(encoder.makeHistoryQueryCommand())
        writer?.enqueue(encoder.makeHistoryMeasurementQueryCommand())
    }

    func handle(_ event: RingDecodedEvent) {
        // Fire-and-forget protocol — nothing to advance.
    }

    func startHeartRate() {
        writer?.enqueue(encoder.makeHeartRateStartCommand())
    }

    func stopHeartRate() {
        writer?.enqueue(encoder.makeHeartRateStopCommand())
        // Restore the ring's normal background HR cadence after a live stream.
        writer?.enqueue(encoder.makeAutomaticHeartRateCommand(enabled: true, cadenceMinutes: 30))
    }

    func startSpO2() {
        writer?.enqueue(encoder.makeSpO2StartCommand())
    }

    func stopSpO2() {
        writer?.enqueue(encoder.makeSpO2StopCommand())
    }

    func findDevice() {
        writer?.enqueue(encoder.makeFindRingCommand())
    }

    func setGoal(steps: Int) {
        writer?.enqueue(encoder.makeGoalCommand(steps: steps))
    }
}
