import Foundation

/// jring sync engine. The connect handshake is fire-and-forget (every command is enqueued up front),
/// but the history that follows is a response-driven per-day loop, as in the vendor app: steps/sleep
/// (`10 dd`) then heart rate (`16 dd`) for each day from the oldest unsynced one down to today. See
/// "Per-day history" below.
@MainActor
final class JringSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let encoder = RingEncoder()
    /// Where each ring's last *finished* full history sync is remembered (see `lastSyncKey`).
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Quiet window that ends a `10 dd` transfer: vendor `h1 = 2000` ms (`bad.java:212`).
    private let activityQuietSeconds: TimeInterval
    /// Safety net for a step the ring never finishes. The vendor's own (`checkGetDataByDayTask`,
    /// `UPDATE_INTERVAL_IN_MILLISECONDS = 10000`) abandons the sync if no history arrives at all; we
    /// use the same 10 s per silent step, and also below the coordinator's 20 s stall timeout so the
    /// progress bar never drops mid-loop.
    private let stepWatchdogSeconds: TimeInterval
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

    init(writer: RingCommandWriter?, clock: JringClock,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() },
         activityQuietSeconds: TimeInterval = 2, stepWatchdogSeconds: TimeInterval = 10) {
        self.writer = writer
        self.clock = clock
        self.defaults = defaults
        self.now = now
        self.activityQuietSeconds = activityQuietSeconds
        self.stepWatchdogSeconds = stepWatchdogSeconds
    }

    /// Auto-reconnect reuses this engine: a loop from the dropped link must not survive into the new one.
    func connectionDidStart() {
        resetHistory()
    }

    /// The loop's timers would otherwise keep firing across the reconnect gap and enqueue `16 dd` /
    /// `10 dd` ahead of the next handshake.
    func connectionDidEnd() {
        resetHistory()
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
        startFullHistory()
    }

    func handle(_ event: RingDecodedEvent) {
        switch event {
        // The ring may initiate a claim on connect.
        case let .bind(action, _):
            respondToBind(action: action)
        case let .bandFunction(caps):
            bandCapabilities = caps
        case let .jringHistoryFrame(frame):
            handleHistoryFrame(frame)
        default:
            break
        }
    }

    // MARK: - Per-day history (10 dd → 16 dd → next day)

    /// One pass of the vendor's day loop. `DupMainActivity.autoSync` (:3172-3207) starts it at
    /// `iMax` = whole days since the last finished sync (capped at 6); FragmentMain chains each day's
    /// requests on the previous transfer's end (`fm.java:1074-1120`); `onGetMultipleSportData`
    /// (`DupMainActivity.java:1096-1127`) then steps `day -= 1`, and below 0 saves the sync-finish time.
    private struct HistoryRun {
        enum Phase { case activity, measurement }
        /// Saved as the ring's last-finished time when the run completes — the *start*, like the
        /// vendor's `timeSyncEnd`, so records logged while the loop ran are re-read next time.
        let startedAt: Date
        /// The post-workout `16 00` (`syncVitalsHistory`): reports "done" but is not a full sync.
        let vitalsOnly: Bool
        var day: Int
        var phase: Phase
        /// A step ended on the watchdog rather than the ring's own terminator: still move on, but don't
        /// record the run as finished, so the next sync re-reads the same days.
        var incomplete = false
        // `16 dd` end-by-count bookkeeping (vendor `a1`/`b1`/`c1`, `bad.java:3865-3884`).
        var segments: Int?
        var segment: Int?
        var segmentBlocks: Int?
    }

    private var history: HistoryRun?
    private var stepTimer: Task<Void, Never>?

    /// Start the loop at the oldest day this ring hasn't finished syncing. No-op while a loop is already
    /// running (a manual sync mid-loop): that loop still reaches today and reports "done".
    ///
    /// The vendor also skips a sync started under 300 s after the last one. We don't: `runStartup` only
    /// runs on connect or an explicit sync, which must end in "done" to clear the progress bar, and
    /// re-reading today is idempotent (buckets upsert by start time; history samples dedupe).
    private func startFullHistory() {
        guard history == nil else { return }
        let startedAt = now()
        history = HistoryRun(startedAt: startedAt, vitalsOnly: false,
                             day: daysToSync(asOf: startedAt), phase: .activity)
        requestCurrentStep()
    }

    /// `iMax` from `autoSync`: calendar days between the last finished sync and today, clamped to 0...6.
    /// A ring never synced here gets the full 6 (vendor default `"0"` → epoch → capped).
    private func daysToSync(asOf date: Date) -> Int {
        guard let key = lastSyncKey, let last = defaults.object(forKey: key) as? Date else { return 6 }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last),
                                           to: calendar.startOfDay(for: date)).day ?? 6
        return min(max(days, 0), 6)
    }

    /// Per ring: a different ring (or a re-pair after Forget) must not inherit another's sync point.
    private var lastSyncKey: String? {
        writer?.deviceIdentifier.map { "jring.lastHistorySyncFinishedAt.\($0)" }
    }

    private func requestCurrentStep() {
        guard let run = history else { return }
        switch run.phase {
        case .activity:
            emitProgress("activity", day: run.day)
            writer?.enqueue(encoder.makeHistoryQueryCommand(day: run.day))
        case .measurement:
            if !run.vitalsOnly { emitProgress("heart rate", day: run.day) }
            writer?.enqueue(encoder.makeHistoryMeasurementQueryCommand(day: run.day))
        }
        armStepTimer(seconds: stepWatchdogSeconds, timedOut: true)
    }

    /// Each step re-arms the coordinator's stall timeout, which only progress stages reset.
    private func emitProgress(_ what: String, day: Int) {
        let when: String
        switch day {
        case 0: when = "today"
        case 1: when = "yesterday"
        default: when = "\(day) days ago"
        }
        writer?.emit(.historySyncProgress(stage: "Syncing \(what) (\(when))…"))
    }

    private func handleHistoryFrame(_ frame: JringHistoryFrame) {
        guard let run = history else { return }
        switch (run.phase, frame) {
        case (.activity, .activity):
            armStepTimer(seconds: activityQuietSeconds, timedOut: false)
        case (.activity, .activityFailed), (.measurement, .measurementEnd), (.measurement, .measurementFailed):
            advanceHistory()
        case let (.measurement, .measurementHeader(segments)):
            history?.segments = segments
            armStepTimer(seconds: stepWatchdogSeconds, timedOut: true)
        case let (.measurement, .measurementSegment(index, blocks)):
            history?.segment = index
            history?.segmentBlocks = blocks
            armStepTimer(seconds: stepWatchdogSeconds, timedOut: true)
        case let (.measurement, .measurementBlock(index)):
            // Vendor end-by-count: the last segment's last block (`b1 == a1 && c1 == index + 1`).
            if let segments = run.segments, run.segment == segments, run.segmentBlocks == index + 1 {
                advanceHistory()
            } else {
                armStepTimer(seconds: stepWatchdogSeconds, timedOut: true)
            }
        default:
            // A late frame from the step before (e.g. an `FF` after an end-by-count) is not ours.
            break
        }
    }

    /// 10 dd → 16 dd of the same day → 10 dd of the next-newer day; after day 0's 16, finish.
    private func advanceHistory() {
        stepTimer?.cancel()
        stepTimer = nil
        guard var run = history else { return }
        switch run.phase {
        case .activity:
            run.phase = .measurement
        case .measurement:
            guard !run.vitalsOnly, run.day > 0 else { return finishHistory() }
            run.day -= 1
            run.phase = .activity
        }
        run.segments = nil
        run.segment = nil
        run.segmentBlocks = nil
        history = run
        requestCurrentStep()
    }

    /// The only place `.historySyncFinished` (→ "done") comes from, so it fires once per pass.
    private func finishHistory() {
        guard let run = history else { return }
        history = nil
        if !run.vitalsOnly, !run.incomplete, let key = lastSyncKey {
            defaults.set(run.startedAt, forKey: key)
        }
        writer?.emit(.historySyncFinished)
    }

    /// One timer per step: the quiet window that ends a `10 dd`, or the watchdog for a silent step.
    private func armStepTimer(seconds: TimeInterval, timedOut: Bool) {
        stepTimer?.cancel()
        stepTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if timedOut { self.history?.incomplete = true }
            self.advanceHistory()
        }
    }

    private func resetHistory() {
        stepTimer?.cancel()
        stepTimer = nil
        history = nil
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
    /// Its sync point goes too, so pairing it again re-reads the full week.
    func unbind() {
        writer?.enqueue(encoder.makeBindCommand(action: 5))
        if let key = lastSyncKey { defaults.removeObject(forKey: key) }
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

    /// Post-workout backfill: re-request today's 0x16 measurement history (`16 00`, 1-min HR blocks)
    /// so readings taken while the phone was away land in the just-finished session. Its end reports
    /// "done" (the coordinator waits on it) but is not a full sync. Skipped while a full loop runs —
    /// that loop reads today's heart rate anyway, and a second `16` would interleave with it.
    func syncVitalsHistory() {
        guard history == nil else { return }
        history = HistoryRun(startedAt: now(), vitalsOnly: true, day: 0, phase: .measurement)
        requestCurrentStep()
    }

    func setGoal(steps: Int) {
        writer?.enqueue(encoder.makeGoalCommand(steps: steps))
    }
}
