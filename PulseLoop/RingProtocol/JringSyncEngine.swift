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

    /// The user's profile for the ring's 0x02 user-info command. `nil` ⇒ send neutral defaults so the
    /// ring's blood-sugar/calorie algorithms still have something to work with.
    private var userProfile: UserProfileValues?
    /// Reference BP calibration (mmHg). 0 ⇒ not calibrated, so we skip the 0x33 push.
    private var bpReferenceSystolic = 0
    private var bpReferenceDiastolic = 0

    init(writer: RingCommandWriter?) {
        self.writer = writer
    }

    func runStartup() {
        // Claim the ring first (0x48) so it streams to us even if another app held it, then push the
        // user profile (0x02) + any BP calibration (0x33) the ring needs for its on-device algorithms,
        // then the canonical status → time → locale → activity → history flow.
        writer?.enqueue(encoder.makeAppIdentifierCommand())
        writer?.enqueue(Data(userInfoCommand()))
        if bpReferenceSystolic > 0, bpReferenceDiastolic > 0 {
            writer?.enqueue(encoder.makeBPAdjustCommand(systolic: bpReferenceSystolic, diastolic: bpReferenceDiastolic))
        }
        writer?.enqueue(encoder.makeStatusCommand())
        writer?.enqueue(encoder.makeTimeSyncCommand())
        writer?.enqueue(encoder.makeLocaleCommand())
        writer?.enqueue(encoder.makeHistoryQueryCommand())
        writer?.enqueue(encoder.makeHistoryMeasurementQueryCommand())
    }

    func handle(_ event: RingDecodedEvent) {
        // Bind handshake is the one response-driven flow: the ring may initiate a claim on connect.
        if case let .bind(action, _) = event { respondToBind(action: action) }
    }

    // MARK: - User profile (0x02)

    func setUserProfile(_ profile: UserProfileValues) {
        userProfile = profile
    }

    func applyUserProfile(_ profile: UserProfileValues) {
        userProfile = profile
        writer?.enqueue(Data(userInfoCommand()))
    }

    /// Build the 0x02 command from the stored profile, falling back to the legacy hardcoded defaults
    /// (age 25, male, 184 cm, 90 kg) when no profile has been pushed yet.
    private func userInfoCommand() -> [UInt8] {
        guard let p = userProfile else {
            return [UInt8](encoder.makeUserInfoCommand(age: 25, isMale: true, heightCm: 184, weightKg: 90))
        }
        // jring encodes sex as a high bit on the age byte; `UserProfileValues.gender == 0x01` ⇒ male.
        return [UInt8](encoder.makeUserInfoCommand(
            age: Int(p.age), isMale: p.gender == 0x01, heightCm: Int(p.heightCm), weightKg: Int(p.weightKg)
        ))
    }

    // MARK: - Blood-pressure calibration (0x33)

    func setBloodPressureCalibration(systolic: Int, diastolic: Int) {
        bpReferenceSystolic = systolic
        bpReferenceDiastolic = diastolic
    }

    func applyBloodPressureCalibration(systolic: Int, diastolic: Int) {
        bpReferenceSystolic = systolic
        bpReferenceDiastolic = diastolic
        guard systolic > 0, diastolic > 0 else { return }
        writer?.enqueue(encoder.makeBPAdjustCommand(systolic: systolic, diastolic: diastolic))
    }

    // MARK: - Bind handshake (0x4B)

    /// Respond to the ring-driven bind handshake: INIT(0) → reply APP_START(1); ACK(2) → reply
    /// SUCCESS(4). Other actions (cancel/unbond) need no app reply here.
    private func respondToBind(action: UInt8) {
        switch action {
        case 0: writer?.enqueue(encoder.makeBindCommand(action: 1))   // INIT → APP_START
        case 2: writer?.enqueue(encoder.makeBindCommand(action: 4))   // ACK → SUCCESS
        default: break
        }
    }

    /// Release the ring on Forget: send UNBOND (0x4B action 5) so the ring re-advertises for other apps.
    func unbind() {
        writer?.enqueue(encoder.makeBindCommand(action: 5))
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
