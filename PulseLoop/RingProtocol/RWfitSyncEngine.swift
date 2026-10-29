import Foundation

/// RwFit initialization and business operations share one serialized transaction gate. Business
/// operations are unavailable until the device has answered its function menu and authentication.
@MainActor
final class RWfitSyncEngine: RingSyncEngine {
    nonisolated deinit {}
    private let gate: RWfitCommandGate
    private let historySync: RWfitHistorySync
    private let clock: RWfitClock
    private let framingProvider: () -> RWfitFraming
    private let selectFraming: (RWfitFraming) -> Void
    private let readiness: (Set<WearableCapability>?) -> Void
    private let deviceIdentifier: () -> String?
    private let encoder = RWfitEncoder()
    private var startupTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var measurementTask: Task<Void, Never>?
    private var measurementTimeout: Task<Void, Never>?
    private var measurementType: UInt8?
    private var measurementHasValue = false
    private var stopping = false
    private var measurementStarted = false
    private var measurementID = UUID()
    private var session = UUID()
    private var streams: [RWfitHistoryType] = []
    private var metadataPending = false
    private var capabilities: Set<WearableCapability> = []
    private(set) var isReady = false
    private var userProfile = UserProfileValues(metric: true, sex: nil, age: nil, heightCm: nil, weightKg: nil)
    private var goalSteps = 10_000

    init(gate: RWfitCommandGate, historySync: RWfitHistorySync, clock: RWfitClock,
         framingProvider: @escaping () -> RWfitFraming,
         selectFraming: @escaping (RWfitFraming) -> Void = { _ in },
         readiness: @escaping (Set<WearableCapability>?) -> Void = { _ in },
         deviceIdentifier: @escaping () -> String? = { nil }) {
        self.gate = gate
        self.historySync = historySync
        self.clock = clock
        self.framingProvider = framingProvider
        self.selectFraming = selectFraming
        self.readiness = readiness
        self.deviceIdentifier = deviceIdentifier
    }

    private var framing: RWfitFraming { framingProvider() }

    func cancel() {
        if let type = measurementType { publish(.rwfitMeasurementOutcome(.cancelled(type: type))) }
        session = UUID()
        startupTask?.cancel(); startupTask = nil
        historyTask?.cancel(); historyTask = nil
        measurementTask?.cancel(); measurementTask = nil
        measurementTimeout?.cancel(); measurementTimeout = nil
        measurementType = nil
        stopping = false
        historySync.cancel()
        gate.cancel()
        isReady = false
        capabilities = []
    }

    func runStartup() {
        guard startupTask == nil else { return }
        if isReady { syncHistory(); return }
        let token = session
        readiness(nil)
        publish(.rwfitInitialization(.initializing))
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.clock.capture()
                try await self.initialize()
                try self.check(token)
                self.isReady = true
                self.metadataPending = true
                self.readiness(self.capabilities)
                self.publish(.rwfitInitialization(.ready))
                self.startupTask = nil
                self.syncHistory()
            } catch {
                guard self.session == token, !Task.isCancelled else { return }
                self.startupTask = nil
                self.isReady = false
                self.readiness(nil)
                self.publish(.rwfitInitialization(.failed(error.localizedDescription)))
            }
        }
    }

    private func initialize() async throws {
        if framing == .legacy {
            var legacyIdentity: [UInt8]?
            do {
                let identity = try await gate.execute(encoder.deviceInfo(framing: .legacy))
                legacyIdentity = identity
            } catch { try Task.checkCancellation() }
            if let legacyIdentity {
                guard !legacyIdentity.isEmpty else { throw RWfitSessionError.invalidResponse }
                try await initializeLegacy()
                return
            }
            selectFraming(.jieli)
            gate.framing = .jieli
            historySync.framing = .jieli
            rwfitDiagnostic("Trying modern initialization after legacy identity probe")
        }
        try await initializeModern()
    }

    private func initializeModern() async throws {
        _ = try await gate.execute(encoder.sessionInitialize(), needsPayload: false)
        _ = try await gate.execute(encoder.timezone(offsetSeconds: Int(clock.offsetSeconds)), needsPayload: false)
        _ = try await gate.execute(encoder.setTime(framing: .jieli, components: clock.nowComponents()), needsPayload: false)
        let menuPayload = try await gate.execute(encoder.functionMenu())
        guard let menu = RWfitFunctionMenu(payload: menuPayload) else { throw RWfitSessionError.invalidResponse }
        if menu.requiresPassword {
            let auth = try await gate.execute(encoder.authenticate())
            guard auth.count > 3, auth[3] == 0 else { throw RWfitSessionError.authentication }
        }
        capabilities = menu.capabilities
        streams = RWfitHistorySync.catalog.filter { menu.historyTypes.contains($0) }
        // Modern readiness ends at the authenticated function menu (vendor SDK contract).
    }

    private func initializeLegacy() async throws {
        let binding = try await gate.execute(encoder.bindStatus(framing: .legacy))
        guard binding.count >= 2 else { throw RWfitSessionError.invalidResponse }
        if binding[0] == 0 {
            _ = try await gate.execute(encoder.bind(framing: .legacy), needsPayload: false)
            let verified = try await gate.execute(encoder.bindStatus(framing: .legacy))
            guard verified.count >= 2, verified[0] != 0 else { throw RWfitSessionError.invalidResponse }
        }
        _ = try await gate.execute(encoder.setTime(framing: .legacy, components: clock.nowComponents()), needsPayload: false)
        let features = try await gate.execute(encoder.features(framing: .legacy))
        guard !features.isEmpty else { throw RWfitSessionError.invalidResponse }
        capabilities = RWfitDecoder.capabilities(fromLegacyFeatures: features)
        let flags: [(UInt8, WearableCapability, RWfitHistoryType)] = [
            (0, .steps, .steps), (1, .sleep, .sleep), (2, .heartRate, .heartRate),
            (3, .bloodPressure, .bloodPressure), (4, .spo2, .spo2), (5, .temperature, .temperature),
        ]
        streams = []
        for (bit, capability, type) in flags where features[0] & (1 << bit) != 0 {
            capabilities.insert(capability)
            streams.append(type)
        }
        if capabilities.contains(.sleep) { capabilities.insert(.remSleep) }
        if features[0] & 0x80 != 0 { streams.append(.breathe) }
        try await configure(framing: .legacy)
    }

    private func configure(framing: RWfitFraming) async throws {
        _ = try await gate.execute(encoder.userProfile(framing: framing, profile: userProfile, goalSteps: goalSteps), needsPayload: false)
        _ = try await gate.execute(encoder.units(framing: framing, metric: userProfile.metric), needsPayload: false)
        _ = try await gate.execute(encoder.deviceInfo(framing: framing))
        _ = try await gate.execute(encoder.battery(framing: framing))
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard session == token else { throw CancellationError() }
    }

    func syncHistory() { startHistory(streams) }
    func syncVitalsHistory() { startHistory(streams.filter { RWfitHistorySync.vitalsTypes.contains($0) }) }

    private func startHistory(_ types: [RWfitHistoryType]) {
        guard isReady, historyTask == nil else { return }
        let token = session
        historySync.deviceIdentifier = deviceIdentifier()
        historyTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.historySync.run(types: types)
            if self.session == token, self.metadataPending, self.measurementType == nil {
                self.metadataPending = false
                // Optional profile/metadata reads must never prevent a compatible ring from
                // becoming ready or importing history. Units already ride modern profile 0206.
                for command in [self.encoder.deviceInfo(framing: self.framing),
                                self.encoder.battery(framing: self.framing),
                                self.encoder.userProfile(framing: self.framing, profile: self.userProfile,
                                                         goalSteps: self.goalSteps)] {
                    guard self.session == token, !Task.isCancelled, self.measurementType == nil else { break }
                    self.gate.submit(command)
                }
            }
            if self.session == token { self.historyTask = nil }
        }
    }

    func handle(_ event: RingDecodedEvent) {
        guard let type = measurementType else { return }
        switch event {
        case let .rwfitMeasurementStatus(reported, status) where reported == type:
            rwfitDiagnostic("Measurement status", ["type": String(type), "status": String(status)])
            if status == 0 {
                // Completion can precede the final sample notification; give queued notifications
                // a brief chance to arrive before reporting completion without a reading.
                measurementTimeout?.cancel()
                measurementTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled, let self, self.measurementType == type else { return }
                    self.publish(.rwfitMeasurementOutcome(.completed(type: type, receivedReading: self.measurementHasValue)))
                    if !self.measurementHasValue { self.reject(type) }
                    self.stop(type)
                }
            }
        case .heartRateSample where type == RWfitJLDataType.heartRate,
             .spo2Result where type == RWfitJLDataType.spo2,
             .hrvSample where type == RWfitJLDataType.hrv,
             .bloodPressureSample where type == RWfitJLDataType.bloodPressure:
            if !RingEventBridge.events(for: event).isEmpty { measurementHasValue = true }
        default: break
        }
    }

    func startHeartRate() { start(RWfitJLDataType.heartRate, capability: .manualHeartRate) }
    func stopHeartRate() { stop(RWfitJLDataType.heartRate) }
    func startSpO2() { start(RWfitJLDataType.spo2, capability: .manualSpo2) }
    func stopSpO2() { stop(RWfitJLDataType.spo2) }
    func startHRV() { start(RWfitJLDataType.hrv, capability: .manualHrv) }
    func stopHRV() { stop(RWfitJLDataType.hrv) }
    func startBloodPressure() { start(RWfitJLDataType.bloodPressure, capability: .manualBloodPressure) }
    func stopBloodPressure() { stop(RWfitJLDataType.bloodPressure) }

    private func start(_ type: UInt8, capability: WearableCapability) {
        guard isReady, framing == .jieli, capabilities.contains(capability) else { reject(type); return }
        if let measurementType {
            if measurementType != type { reject(type) }
            return
        }
        measurementID = UUID()
        let measurementToken = measurementID
        measurementType = type
        measurementHasValue = false
        measurementStarted = false
        historySync.isPaused = true
        let token = session
        measurementTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.historySync.waitUntilPaused()
                try self.check(token)
                guard self.measurementType == type, self.measurementID == measurementToken, !self.stopping else { return }
                _ = try await self.gate.execute(self.encoder.realtimeMeasure(type: type, on: true), needsPayload: false)
                try self.check(token)
                guard !self.stopping else { return }
                self.measurementStarted = true
                self.measurementTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 65_000_000_000)
                    guard !Task.isCancelled, let self, self.measurementType == type else { return }
                    if !self.measurementHasValue { self.reject(type) }
                    self.stop(type)
                }
            } catch {
                guard self.session == token, !Task.isCancelled else { return }
                self.reject(type)
                self.stop(type)
            }
        }
    }

    func awaitMeasurementStart(type: UInt8) async -> Bool {
        while measurementType == type && !stopping {
            if measurementStarted { return true }
            do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return false }
        }
        return false
    }

    private func stop(_ type: UInt8) {
        guard measurementType == type, !stopping else { return }
        stopping = true
        measurementID = UUID()
        measurementTimeout?.cancel(); measurementTimeout = nil
        let token = session
        measurementTask = Task { [weak self] in
            guard let self else { return }
            // Keep history paused until stop is acknowledged; a lost stop cannot silently resume
            // history while the optical measurement may still own the firmware's command channel.
            do {
                _ = try await self.gate.execute(self.encoder.realtimeMeasure(type: type, on: false), needsPayload: false)
                try self.check(token)
                self.measurementType = nil
                self.stopping = false
                self.measurementTask = nil
                self.historySync.isPaused = false
            } catch {
                guard self.session == token, !Task.isCancelled else { return }
                self.cancel()
                self.readiness(nil)
                self.publish(.rwfitInitialization(.failed(error.localizedDescription)))
            }
        }
    }

    private func reject(_ type: UInt8) {
        publish(.rwfitMeasurementOutcome(.failed(type: type,
                    reason: "The ring did not provide a reading. Keep it on your finger and try again.")))
    }
    private func publish(_ event: PulseEvent) { Task { await PulseEventBus.shared.publish(event) } }
    func findDevice() {}
    func setGoal(steps: Int) {
        goalSteps = steps
        if isReady { gate.submit(encoder.goal(framing: framing, steps: steps, profile: userProfile)) }
    }
    func resyncTime() {
        guard isReady else { return }
        clock.capture()
        if framing == .jieli { gate.submit(encoder.timezone(offsetSeconds: Int(clock.offsetSeconds))) }
        gate.submit(encoder.setTime(framing: framing, components: clock.nowComponents()))
    }
    func requestBattery() { if isReady { gate.submit(encoder.battery(framing: framing)) } }
    func setUserProfile(_ profile: UserProfileValues) { userProfile = profile }
    func applyUserProfile(_ profile: UserProfileValues) {
        userProfile = profile
        if isReady { gate.submit(encoder.userProfile(framing: framing, profile: profile, goalSteps: goalSteps)) }
    }
    func unbind() {
        if isReady { gate.submit(encoder.unbind(framing: framing)) }
    }
}
