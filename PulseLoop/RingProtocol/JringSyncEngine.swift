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
    /// Shared with the driver's `RingDecoder`: latched when we send 0x01, read back when decoding
    /// ring-stamped history timestamps.
    private let clock: JringClock

    /// The user's profile for the ring's 0x02 user-info command. `nil` ⇒ send neutral defaults so the
    /// ring's blood-sugar/calorie algorithms still have something to work with.
    private var userProfile: UserProfileValues?
    /// Reference BP calibration (mmHg). 0 ⇒ not calibrated, so we skip the 0x33 push.
    private var bpReferenceSystolic = 0
    private var bpReferenceDiastolic = 0
    /// All-day measurement config; drives the 0x19 cadence. Defaults match the vendor's own
    /// `initParam` values (enabled, 30-minute cadence) so a ring we've never configured still logs.
    private var measurementSettings = MeasurementSettings.jringDefault
    /// The ring's self-reported feature bits (0x20 reply), or `nil` if it never answered. Nothing
    /// branches on these yet — they exist so the offline-history sync chain can gate its extra
    /// per-day queries once the bit ordering is confirmed against real hardware.
    private(set) var bandCapabilities: JringBandCapabilities?

    init(writer: RingCommandWriter?, clock: JringClock) {
        self.writer = writer
        self.clock = clock
    }

    func runStartup() {
        // Claim the ring first (0x48) so it streams to us even if another app held it, then push the
        // user profile (0x02) + any BP calibration (0x33) the ring needs for its on-device algorithms,
        // then the canonical status → time → locale → monitoring → capabilities → history flow.
        //
        // Ordering is guaranteed by the serialized write queue (one `.withResponse` write at a time),
        // so no inter-command delays are needed.
        writer?.enqueue(encoder.makeAppIdentifierCommand())
        writer?.enqueue(Data(userInfoCommand()))
        if bpReferenceSystolic > 0, bpReferenceDiastolic > 0 {
            writer?.enqueue(encoder.makeBPAdjustCommand(systolic: bpReferenceSystolic, diastolic: bpReferenceDiastolic))
        }
        writer?.enqueue(encoder.makeStatusCommand())
        enqueueTimeSync()
        writer?.enqueue(encoder.makeLocaleCommand())
        // 0x19 arms the ring's continuous background sensor logging. The vendor app sends this on
        // every connect; without it the ring records almost nothing, which is why users previously
        // had to initialise with the vendor app first.
        enqueueMeasurementCommands(measurementSettings)
        writer?.enqueue(encoder.makeBandFunctionCommand())
        writer?.enqueue(encoder.makeHistoryQueryCommand())
        writer?.enqueue(encoder.makeHistoryMeasurementQueryCommand())
    }

    func handle(_ event: RingDecodedEvent) {
        switch event {
        // Bind handshake is the one response-driven flow: the ring may initiate a claim on connect.
        case let .bind(action, _):
            respondToBind(action: action)
        case let .bandFunction(caps):
            bandCapabilities = caps
        default:
            break
        }
    }

    // MARK: - Time (0x01)

    /// Latch the offset we're about to encode, then send it. The decoder subtracts the same value
    /// back off every ring-stamped timestamp — the two halves must always move together.
    private func enqueueTimeSync() {
        clock.capture()
        writer?.enqueue(encoder.makeTimeSyncCommand())
    }

    /// Re-push the clock after the phone's timezone or wall clock changes, so the ring's RTC keeps
    /// tracking local time (its sleep detection and day-indexed history depend on it).
    func resyncTime() {
        enqueueTimeSync()
    }

    // MARK: - All-day measurement config (0x19, 0x3E)

    /// Store without sending — `runStartup` will send it as part of the connect sequence.
    func setMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
    }

    /// Store *and* push immediately — the live "Save" path while connected.
    func applyMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
        enqueueMeasurementCommands(settings)
    }

    /// Translate the device-agnostic settings into jring commands. Only the HR cadence maps to a
    /// command: SpO₂/stress/HRV/temperature ride the 0x24 combined packet and the 0x19 background log,
    /// and this ring has no per-metric opcode to switch them off individually.
    private func enqueueMeasurementCommands(_ settings: MeasurementSettings) {
        writer?.enqueue(encoder.makeAutomaticHeartRateCommand(
            enabled: settings.hrEnabled,
            cadenceMinutes: settings.hrIntervalMinutes
        ))
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
        // Restore the user's background HR cadence after a live stream (a workout tightens it).
        writer?.enqueue(encoder.makeAutomaticHeartRateCommand(
            enabled: measurementSettings.hrEnabled,
            cadenceMinutes: measurementSettings.hrIntervalMinutes
        ))
    }

    /// Spot SpO₂ reading: mode 2 of the 0x23 selector, matching the vendor's `setSpoMode`.
    /// Mode 1 is *blood pressure* — sending `0x23 01` here silently runs a BP measurement instead,
    /// which is what this app used to do.
    ///
    /// The ring also has a dedicated 0x3E background blood-oxygen command (`makeBloodOxygenModeCommand`),
    /// but the vendor app never sends it — every SpO₂ reading goes through 0x23. We don't either.
    func startSpO2() {
        writer?.enqueue(encoder.makeSpO2StartCommand())
    }

    func stopSpO2() {
        writer?.enqueue(encoder.makeSpO2StopCommand())
    }

    /// Spot blood-pressure reading: mode 1 of the 0x23 selector. The reading comes back in the 0x24
    /// combined packet. Any on-device calibration pushed via 0x33 is already applied by the ring.
    func startBloodPressure() {
        writer?.enqueue(encoder.makeBloodPressureStartCommand())
    }

    func stopBloodPressure() {
        writer?.enqueue(encoder.makeBloodPressureStopCommand())
    }

    /// One PPG sweep, every vital. Confirmed on hardware: a `0x23 02` measurement returns a `0x24`
    /// packet carrying HR, systolic, diastolic, SpO₂ *and* fatigue together — the mode byte selects
    /// the ring's primary algorithm, not which sensor runs. This matches the vendor's own behaviour on
    /// firmware that reports `separateBloodOxygenMode == false` (where it hides its BP card entirely,
    /// because measuring oxygen already yields blood pressure).
    ///
    /// On separate-mode firmware (capability bit 65) the two are genuinely distinct measurements; we
    /// have not seen such a ring, so this still sends the SpO₂ mode and simply surfaces whatever the
    /// packet contains.
    func startCombinedVitals() {
        writer?.enqueue(encoder.makeSpO2StartCommand())
    }

    func stopCombinedVitals() {
        writer?.enqueue(encoder.makeSpO2StopCommand())
    }

    func findDevice() {
        writer?.enqueue(encoder.makeFindRingCommand())
    }

    /// Post-workout backfill: re-request the 0x16 measurement history stream (1-min HR blocks) so
    /// readings taken while the phone was away land in the just-finished session.
    func syncVitalsHistory() {
        writer?.enqueue(encoder.makeHistoryMeasurementQueryCommand())
    }

    func setGoal(steps: Int) {
        writer?.enqueue(encoder.makeGoalCommand(steps: steps))
    }
}
