import Foundation

/// Nights before today to pull once per connection. See `CRPSyncEngine.sendSleepBackfill`.
private let crpSleepBackfillDays = 6

/// Per-connection orchestration for a CRP ("crrepa") ring. Ported in spirit from the Moyoung
/// "Da Rings" connect flow (`d1/b.java` + `b1` package builders): after the link is up the app sets
/// the clock and pushes user anthropometrics, then the ring streams current steps (`fdd1`) on its own
/// and answers measurement commands.
///
/// Scope: clock + user-info handshake, spot HR + SpO2 (Measure button), all-day vital timing
/// enable/disable driven by `MeasurementSettings`, find-device. Steps and battery arrive as
/// autonomous pushes/reads (see `CRPDriver`). HRV / stress / temperature are all-day metrics — their
/// timing is enabled here and live results decode via `CRPDecoder`. Of the stored day timelines,
/// sleep (group-2/cmd-14) is decoded (`CRPDecoder.decodeSleep`, confirmed against a hardware
/// capture), and the group-2 all-day "timing" vital histories (HR/SpO2/HRV/stress) decode into
/// `.historyMeasurement` samples; their multi-frame replies reassemble via the next-frame follow-up
/// in `handle`.
///
/// Factory reset / power off: the CRP command (`CRPProtocol.factoryReset`, group 3 / cmd 0) is known,
/// but iOS's `RingSyncEngine` exposes no factory-reset/power-off hook (the Colmi encoder has the
/// opcodes too, with no invocation path), so there is nothing to wire it into here — which is why
/// `CRPCoordinator` doesn't claim `.factoryReset` even though the Android coordinator does.
@MainActor
final class CRPSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private var profile: UserProfileValues?
    private let historyWatchdogNanos: UInt64
    private let eventSink: @MainActor (PulseEvent) -> Void

    /// The four framed timing streams that have a protocol-defined terminal cursor. Sleep and
    /// temperature do not: sleep is a single reply (or silence), while temperature's reply layout is
    /// not capture-confirmed. Those silent streams are bounded by the watchdog below.
    private static let timingHistoryCommands: Set<Int> = [
        CRPCommands.cmdQueryTimingHR,
        CRPCommands.cmdQueryTimingHRV,
        CRPCommands.cmdQueryTimingSpO2,
        CRPCommands.cmdQueryTimingStress,
    ]
    private var pendingTimingHistoryCommands: Set<Int> = []
    private var historySyncInFlight = false
    private var historyCompletionTask: Task<Void, Never>?

    /// User-chosen all-day measurement config. Applied in the connect handshake and updatable
    /// live via `applyMeasurementSettings`. `nil` ⇒ the user has never saved one, and a fresh R11
    /// ships with every all-day monitor OFF, so it records nothing to sync. We therefore fall back to
    /// `MeasurementSettings.allOnDefault` (matching how `ColmiSyncEngine` force-enables on connect)
    /// so the day timeline actually accumulates.
    ///
    /// Note this is a *forced* default, not a read-back: `sendConnectionReadBacks` now asks the ring
    /// for each monitor's current interval, but the replies are only surfaced as diagnostics — we
    /// still impose a config rather than adopting the ring's. Matching the vendor here (query state,
    /// apply the saved config, leave the ring alone otherwise) is a known open divergence on both
    /// platforms; it needs the read-back replies confirmed against hardware first.
    private var measurementSettings: MeasurementSettings?

    /// One timing-history follow-up we've already asked for. Keyed on `day` as well as `cmd` —
    /// today's queries are all `day 0`, but this engine already issues multi-day requests for sleep,
    /// and a key without `day` would silently swallow day 1's frame-1 follow-up the moment the
    /// timing vitals get the same backfill treatment.
    private struct TimingFrameRequest: Hashable {
        let cmd: Int
        let day: Int
        let frameIndex: Int
    }

    /// Frame follow-ups already requested this poll pass, so a ring that re-sends the same frame
    /// can't trigger a request storm. Cleared at the start of every `queryAllHistory` pass so each
    /// sync re-pulls the full timeline.
    private var requestedTimingFrames: Set<TimingFrameRequest> = []

    init(
        writer: RingCommandWriter?,
        // Below RingSyncCoordinator's 20-second stall deadline so this engine's explicit `done` wins.
        historyWatchdogNanos: UInt64 = 15_000_000_000,
        eventSink: @escaping @MainActor (PulseEvent) -> Void = { event in
            Task { PulseEventBus.shared.publish(event) }
        }
    ) {
        self.writer = writer
        self.historyWatchdogNanos = historyWatchdogNanos
        self.eventSink = eventSink
    }

    // MARK: - Link lifecycle

    /// Auto-reconnect reuses this engine, but "once per connection" queries must be once per GATT
    /// link. The previous link may have dropped while those frames were still in RingBLEClient's
    /// queue, which is cleared on disconnect; retaining these flags would silently lose them forever.
    func connectionDidStart() {
        resetPerLinkState()
    }

    /// Cancel without publishing `done`: a disconnected transfer did not complete successfully.
    func connectionDidEnd() {
        resetPerLinkState()
    }

    private func resetPerLinkState() {
        cancelHistorySync()
        connectionQueriesSent = false
        sleepBackfillSent = false
        requestedTimingFrames.removeAll()
    }

    func runStartup() {
        // Set the device clock first (matches the vendor's connect handshake), then user info so
        // the ring's step/calorie algorithm has real inputs.
        send(CRPProtocol.setTime())
        if let profile { send(userInfoFrame(profile)) }
        sendConnectionQueries()
        // Enable all-day vital monitoring. A fresh ring has these OFF, so without this the ring
        // stores no HR/SpO2/HRV/stress/temperature history and every history query below returns an
        // empty reply (Android issue #29, zaggash's full-day capture). When the user has saved a
        // config we honour it exactly (interval included); until then we fall back to allOnDefault.
        applyTimingSettings(measurementSettings ?? .allOnDefault)
        // Pull the day's stored all-day timeline during startup. Later foreground/background
        // refreshes enter through syncHistory(). The ring only emits history replies once asked.
        startHistorySync(includeSleepBackfill: true)
    }

    /// Whether the self-description queries have been sent on this GATT link.
    ///
    /// The engine instance survives auto-reconnect, so `connectionDidStart`/`connectionDidEnd` reset
    /// this flag. That is necessary because the BLE client drops queued writes with the old link.
    private var connectionQueriesSent = false

    /// Ask the ring to describe itself, once per connection.
    ///
    /// Firmware version (`3/3`) answers with a UTF-8 string — `MOY-R1K3-2.1.6` on zaggash's R11. The
    /// 23-sends/0-replies in the 2026-07-25 capture were our fault, not the ring's: the old opcode was
    /// group 7 cmd 1, which the vendor SDK uses for `querySavedGomoreKey` (`b1/r.d`), not firmware.
    /// `querySupportSpO2Type` answers NOT_SUPPORT / SLEEP_OXYGEN / TIMING_OXYGEN; the timing-state
    /// queries report each all-day monitor's configured interval (0 = off). Together they are the
    /// evidence base for whether a silent history query means "the monitor is off" or "this ring
    /// lacks the sensor" — stress (`2/47`) and temperature (`2/22`) both went unanswered on zaggash's
    /// ring, and these replies are how we tell those apart next capture.
    ///
    /// Deliberately **not** part of the periodic poll pass. Neither a firmware string nor a sensor
    /// roster can change between syncs. Re-asking would add
    /// seven writes to every pass on a ring that funnels the handshake, timing config, history pull
    /// *and* on-demand measures through the single `fdd2` channel — and a spot SpO2 needs ~48 s of
    /// that channel to return a reading. (Firmware used to be sent unconditionally here, which
    /// contradicted that argument on the very next line.)
    ///
    /// **Call order matters: this must run BEFORE `applyTimingSettings`.** The state queries report
    /// each monitor's *current* interval, and `applyTimingSettings` force-enables everything moments
    /// later. Ask afterwards and every reply describes the state we just imposed, which answers
    /// nothing — the whole point is to learn whether stress and temperature were silent because their
    /// monitor was off. `CRPSyncEngineTests` pins the ordering; if that assertion ever fails, fix the
    /// call site rather than the expectation.
    private func sendConnectionQueries() {
        if connectionQueriesSent { return }
        connectionQueriesSent = true
        send(CRPProtocol.queryFirmwareVersion())
        send(CRPProtocol.querySupportSpO2Type())
        send(CRPProtocol.queryTimingHeartRateState())
        send(CRPProtocol.queryTimingHrvState())
        send(CRPProtocol.queryTimingSpO2State())
        send(CRPProtocol.queryTimingStressState())
        send(CRPProtocol.queryTimingTempState())
    }

    /// Request the stored all-day timelines the ring has accumulated: the group-2 "timing" vital
    /// timelines (HR/SpO2/HRV/stress), temperature, and sleep. Vendor `u3/g1.java` fires the same set
    /// on its sync pass. Each timing query pulls frame 0; the reply drives `handle` to pull the next
    /// frame until the day is complete.
    private func queryAllHistory(includeSleepBackfill: Bool) {
        requestedTimingFrames.removeAll()
        send(CRPProtocol.queryTimingHeartRateHistory())
        send(CRPProtocol.queryTimingSpO2History())
        send(CRPProtocol.queryTimingHrvHistory())
        send(CRPProtocol.queryTimingStressHistory())
        send(CRPProtocol.queryHistoryTemp())
        send(CRPProtocol.queryHistorySleep())
        if includeSleepBackfill { sendSleepBackfill() }
    }

    /// Start one standalone history pass. Periodic BLE wakeups can race the foreground timer, so a
    /// second kick while the first pass is awaiting frames is intentionally ignored.
    private func startHistorySync(includeSleepBackfill: Bool) {
        guard !historySyncInFlight else { return }
        historySyncInFlight = true
        pendingTimingHistoryCommands = Self.timingHistoryCommands
        eventSink(.syncProgress(stage: "Syncing ring history…"))
        queryAllHistory(includeSleepBackfill: includeSleepBackfill)
        armHistoryCompletionWatchdog()
    }

    /// CRP history is a standalone query set, so it participates in the coordinator's periodic and
    /// background top-up path without replaying clock/profile/timing configuration writes.
    func syncHistory() {
        startHistorySync(includeSleepBackfill: false)
    }

    private func armHistoryCompletionWatchdog() {
        historyCompletionTask?.cancel()
        let delay = historyWatchdogNanos
        historyCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            // Unsupported/disabled streams are allowed to stay silent. Reaching the bounded deadline
            // completes the poll with whatever the ring did return instead of wedging sync forever.
            self.finishHistorySync()
        }
    }

    private func finishHistorySync() {
        guard historySyncInFlight else { return }
        historySyncInFlight = false
        pendingTimingHistoryCommands.removeAll()
        requestedTimingFrames.removeAll()
        historyCompletionTask?.cancel()
        historyCompletionTask = nil
        eventSink(.syncProgress(stage: "done"))
    }

    private func cancelHistorySync() {
        historySyncInFlight = false
        pendingTimingHistoryCommands.removeAll()
        historyCompletionTask?.cancel()
        historyCompletionTask = nil
    }

    /// Whether older nights have already been backfilled on this GATT link.
    private var sleepBackfillSent = false

    /// Pull the nights *before* today, once per connection.
    ///
    /// The poll pass above only ever asks for `daysAgo = 0`, so the app's stored history could only
    /// ever grow one night at a time from whenever the user installed. Asking for the ring's own
    /// back-catalogue is what actually restores a user's history.
    ///
    /// Safe to send blind. Each reply is self-describing: `payload[0]` is the ring's own day index,
    /// so `CRPDecoder.decodeSleep` dates a night from the reply rather than from what we asked for,
    /// and a day the ring has no record of simply produces no reply — the same nothing we get today.
    ///
    /// Once per connection, and deliberately short of the decoder's 14-day ceiling. This ring
    /// funnels the handshake, timing config, history pull
    /// *and* on-demand measures through one `fdd2` channel (a spot SpO2 needs ~48 s of it). A week is
    /// the useful-recovery/quiet-channel trade; raise it once hardware shows the ring answers deeper.
    private func sendSleepBackfill() {
        if sleepBackfillSent { return }
        sleepBackfillSent = true
        // Half-open on purpose: `crpSleepBackfillDays` is documented as a knob to raise or lower, and
        // `1...0` would trap at runtime if it were ever turned down to "today only".
        for daysAgo in 1..<(crpSleepBackfillDays + 1) {
            send(CRPProtocol.queryHistorySleep(daysAgo: daysAgo))
        }
    }

    /// The last frame index each timing vital emits before its day is complete (vendor terminal
    /// index: HR/SpO2/stress finalize at frame 1 — two 144-slot frames; HRV at frame 3 — four
    /// 72-slot frames). A reply below this index triggers a pull of the next frame.
    private func terminalFrameIndex(cmd: Int) -> Int {
        cmd == CRPCommands.cmdQueryTimingHRV ? 3 : 1
    }

    /// Build the next-frame query for a timing vital, or `nil` for a non-timing cmd.
    private func timingQuery(cmd: Int, day: Int, frameIndex: Int) -> Data? {
        switch cmd {
        case CRPCommands.cmdQueryTimingHR:
            return CRPProtocol.queryTimingHeartRateHistory(day: day, frameIndex: frameIndex)
        case CRPCommands.cmdQueryTimingHRV:
            return CRPProtocol.queryTimingHrvHistory(day: day, frameIndex: frameIndex)
        case CRPCommands.cmdQueryTimingSpO2:
            return CRPProtocol.queryTimingSpO2History(day: day, frameIndex: frameIndex)
        case CRPCommands.cmdQueryTimingStress:
            return CRPProtocol.queryTimingStressHistory(day: day, frameIndex: frameIndex)
        default:
            return nil
        }
    }

    func handle(_ event: RingDecodedEvent) {
        // Steps/HR/battery are persisted by RingBLEClient via RingEventBridge. The one piece of
        // engine-side state is the all-day timeline's multi-frame pull: on each timing-history frame
        // the ring returns, request the next frame until the vital's terminal index — the vendor's
        // sequential `insertBleMessage(<query>.b(day, index + 1))` (`e1/{f,d,g,l}.java`). The samples
        // themselves are decoded + persisted via the bridge; this only advances the cursor.
        guard historySyncInFlight,
              case let .timingHistoryFrame(cmd, day, frameIndex) = event,
              Self.timingHistoryCommands.contains(cmd) else { return }
        if day == CRPCommands.historyDayToday,
           frameIndex >= terminalFrameIndex(cmd: cmd) {
            pendingTimingHistoryCommands.remove(cmd)
            if pendingTimingHistoryCommands.isEmpty {
                finishHistorySync()
            }
            return
        }
        if frameIndex >= terminalFrameIndex(cmd: cmd) { return }
        let nextIndex = frameIndex + 1
        // Guard against a ring that re-sends the same frame spamming duplicate follow-ups.
        let request = TimingFrameRequest(cmd: cmd, day: day, frameIndex: nextIndex)
        guard requestedTimingFrames.insert(request).inserted else { return }
        send(timingQuery(cmd: cmd, day: day, frameIndex: nextIndex))
    }

    // MARK: - Heart rate (standard 2a37 stream, started/stopped via the fdda command channel)
    func startHeartRate() { send(CRPProtocol.measureHeartRate(true)) }
    func stopHeartRate() { send(CRPProtocol.measureHeartRate(false)) }

    // MARK: - SpO2 (command verified; result parsing deferred, so capability isn't advertised)
    func startSpO2() { send(CRPProtocol.measureSpO2(true)) }
    func stopSpO2() { send(CRPProtocol.measureSpO2(false)) }

    func findDevice() { send(CRPProtocol.findDevice(true)) }

    func setGoal(steps: Int) {
        // Step-goal command layout not yet confirmed from the decompile; no-op for now.
    }

    // MARK: - User profile
    func setUserProfile(_ profile: UserProfileValues) { self.profile = profile }

    func applyUserProfile(_ profile: UserProfileValues) {
        self.profile = profile
        send(userInfoFrame(profile))
    }

    // MARK: - Measurement settings
    /// Takes a non-optional `MeasurementSettings` because that is `RingSyncEngine`'s requirement.
    /// It used to take `MeasurementSettings?`, which is a *different* signature — so it satisfied
    /// nothing, the protocol's no-op default extension supplied conformance instead, and every
    /// `RingSyncCoordinator` call landed there. The user's saved config was silently discarded and
    /// `runStartup` always fell back to `.allOnDefault`.
    func setMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
    }

    func applyMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
        applyTimingSettings(settings)
    }

    /// Send the all-day enable/disable command for every vital. The CRP protocol takes a single
    /// interval byte per enable, and `MeasurementSettings` carries only `hrIntervalMinutes` (no
    /// per-vital cadence), so the HR interval is shared across the board. Disabled vitals are
    /// explicitly turned off so a reconnect can't leave a previously-enabled monitor running.
    private func applyTimingSettings(_ settings: MeasurementSettings) {
        if settings.hrEnabled {
            send(CRPProtocol.enableTimingHeartRate(intervalMinutes: settings.hrIntervalMinutes))
        } else {
            send(CRPProtocol.disableTimingHeartRate())
        }
        if settings.hrvEnabled {
            send(CRPProtocol.enableTimingHRV(intervalMinutes: settings.hrIntervalMinutes))
        } else {
            send(CRPProtocol.disableTimingHRV())
        }
        if settings.stressEnabled {
            send(CRPProtocol.enableTimingStress(intervalMinutes: settings.hrIntervalMinutes))
        } else {
            send(CRPProtocol.disableTimingStress())
        }
        if settings.spo2Enabled {
            send(CRPProtocol.enableTimingSpO2(intervalMinutes: settings.hrIntervalMinutes))
        } else {
            send(CRPProtocol.disableTimingSpO2())
        }
        if settings.temperatureEnabled {
            send(CRPProtocol.enableTimingTemp())
        } else {
            send(CRPProtocol.disableTimingTemp())
        }
    }

    func resyncTime() { send(CRPProtocol.setTime()) }

    /// Map the app's `UserProfileValues` onto the CRP user-info payload. Stride length isn't carried
    /// by the profile, so estimate it from height (~0.43·height, a common default).
    private func userInfoFrame(_ p: UserProfileValues) -> Data {
        let heightCm = Int(p.heightCm)
        let strideCm = min(255, max(0, Int(Double(heightCm) * 0.43)))
        return CRPProtocol.setUserInfo(
            heightCm: heightCm,
            weightKg: Int(p.weightKg),
            ageYears: Int(p.age),
            gender: Int(p.gender),
            strideCm: strideCm
        )
    }

    private func send(_ frame: Data?) {
        if let frame { writer?.enqueue(frame) }
    }
}
