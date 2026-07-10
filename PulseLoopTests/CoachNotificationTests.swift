import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

private func notificationJSON(title: String = "Good morning", body: String = "You slept well.") -> String {
    "{\"title\":\"\(title)\",\"body\":\"\(body)\"}"
}

// MARK: - Slot + schema (pure)

final class CoachNotificationSlotTests: XCTestCase {
    private func at(_ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    func testSlotWindows() {
        func slot(_ h: Int) -> CoachNotificationSlot? {
            CoachNotificationSlot.current(for: at(h), morningHour: 8, middayHour: 13, eveningHour: 19)
        }
        XCTAssertEqual(slot(8), .morning)
        XCTAssertEqual(slot(11), .morning)
        XCTAssertEqual(slot(13), .midday)
        XCTAssertEqual(slot(15), .midday)
        XCTAssertEqual(slot(19), .evening)
        XCTAssertEqual(slot(21), .evening)
        XCTAssertNil(slot(3))    // too early
        XCTAssertNil(slot(18))   // between midday and evening windows
    }

    func testNextWindowStartIsInFuture() {
        let now = at(15)  // inside midday window → next start is evening today
        let next = CoachNotificationSlot.nextWindowStart(after: now, morningHour: 8, middayHour: 13, eveningHour: 19)
        XCTAssertGreaterThan(next, now)
        XCTAssertEqual(Calendar.current.component(.hour, from: next), 19)
    }

    func testNotificationSchemaAndDecode() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(CoachNotificationSchema.jsonSchema))
        let n = CoachNotification.decode(fromJSON: "Here you go: \(notificationJSON()) thanks")
        XCTAssertEqual(n?.title, "Good morning")
    }

    func testScriptedFallbackIsGrounded() {
        // Build a minimal packet with steps to exercise the evening fallback.
        let packet = NotificationContextPacket(
            slot: "evening", generatedAt: "", timezone: "UTC", profileName: "Sam",
            goals: .init(stepsDaily: 10000, activeMinutesDaily: 45, sleepHours: 8, exerciseDaysWeekly: 4),
            today: .init(localDate: "2026-06-05", steps: 12000, calories: nil, distanceKm: nil, activeMinutes: nil, dataConfidence: "high"),
            latestSleep: nil,
            latestVitals: .init(latestHr: nil, latestHrAt: nil, latestSpo2: nil, latestSpo2At: nil, restingHrEstimate: nil, peakHrToday: nil),
            hrLast12h: .init(count: 0, avg: nil, min: nil, max: nil),
            spo2Last12h: .init(count: 0, avg: nil, min: nil, max: nil),
            recentWorkouts: [], memories: [], dataQualityWarnings: []
        )
        let n = CoachNotificationGenerator.scripted(slot: .evening, packet: packet)
        XCTAssertTrue(n.body.contains("12000"))
    }
}

// MARK: - Service (gates, generation, recording)

@MainActor
final class CoachNotificationServiceTests: XCTestCase {

    private func service(_ c: ModelContext, key: String? = "sk-test", client: ResponsesClient? = nil) -> CoachNotificationService {
        let store = CoachSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return CoachNotificationService(
            modelContext: c, coordinator: nil,
            keyStore: StubKeyStore(key: key), settingsStore: store,
            clientFactory: { _ in client ?? StubResponsesClient([
                OpenAIResponse(id: "n", outputItems: [.message(text: notificationJSON())])
            ]) }
        )
    }

    func testForceGeneratesRecordsAndWritesThread() async throws {
        let c = try TestSupport.makeContext()
        // Pin `now` to a morning hour: a forced run picks its slot from the wall clock
        // (< 14:00 → morning), and this test asserts the "Good morning" copy.
        let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
        let outcome = await service(c).runDueSlot(force: true, now: morning)
        if case .sent = outcome {} else { XCTFail("expected sent, got \(outcome)") }

        // A record exists + a fresh per-notification conversation was created.
        let records = (try? c.fetch(FetchDescriptor<CoachNotificationRecord>())) ?? []
        XCTAssertEqual(records.count, 1)
        let convos = (try? c.fetch(FetchDescriptor<CoachConversation>())) ?? []
        XCTAssertEqual(convos.count, 1)
        let messages = (try? c.fetch(FetchDescriptor<CoachMessage>())) ?? []
        XCTAssertTrue(messages.contains { $0.body.contains("Good morning") })
    }

    /// Two consecutive notifications must each get their own conversation —
    /// never funnel into one shared "Daily check-ins" log.
    func testEachNotificationGetsItsOwnConversation() async throws {
        let c = try TestSupport.makeContext()
        let svc = service(c)
        _ = await svc.runDueSlot(force: true)
        _ = await svc.runDueSlot(force: true)
        let convos = (try? c.fetch(FetchDescriptor<CoachConversation>())) ?? []
        XCTAssertEqual(convos.count, 2)
    }

    func testDuplicateSlotIsSkipped() async throws {
        let c = try TestSupport.makeContext()
        let now = Date()
        c.insert(CoachNotificationRecord(slot: .morning, dateKey: CoachNotificationRecord.dateKey(for: now), title: "x", body: "y"))
        try c.save()
        let svc = service(c)
        XCTAssertTrue(svc.isDuplicate(slot: .morning, now: now))
    }

    func testFreshnessFromRecentMeasurement() async throws {
        let c = try TestSupport.makeContext()
        let svc = service(c)
        XCTAssertFalse(svc.hasRecentData(now: Date()))
        TestSupport.insertMeasurement(kind: .heartRate, value: 70, timestamp: Date(), into: c)
        XCTAssertTrue(svc.hasRecentData(now: Date()))
    }

    func testContextBuilderKeepsLast12h() throws {
        let c = try TestSupport.makeContext()
        let now = Date()
        TestSupport.insertMeasurement(kind: .heartRate, value: 70, timestamp: now.addingTimeInterval(-1 * 3600), into: c)
        TestSupport.insertMeasurement(kind: .heartRate, value: 200, timestamp: now.addingTimeInterval(-20 * 3600), into: c)
        try c.save()

        let packet = NotificationContextBuilder.build(slot: .evening, context: c, now: now)
        XCTAssertEqual(packet.hrLast12h.count, 1)  // 20h-old sample excluded
    }
}

private struct StubKeyStore: APIKeyStore {
    let key: String?
    func readKey() throws -> String? { key }
    func saveKey(_ key: String) throws {}
    func deleteKey() throws {}
}

// MARK: - Sync gating (ensureFreshData)

/// A recording `RingSyncGating` fake. `onAwait` runs each time `awaitSyncCompletion` is called (e.g.
/// to insert a fresh measurement, simulating a sync landing data) and its return value is what the
/// method resolves to.
@MainActor
private final class FakeSyncGate: RingSyncGating {
    var isRingConnected: Bool
    var isSyncInFlight: Bool
    private(set) var beginSyncCalls = 0
    private(set) var awaitCalls = 0
    private(set) var connectAndSyncCalls = 0
    /// Ordered log of calls, so tests can assert beginSync happened *before* the wait.
    private(set) var callLog: [String] = []
    var onAwait: (() -> Bool)?

    init(connected: Bool = false, inFlight: Bool = false) {
        self.isRingConnected = connected
        self.isSyncInFlight = inFlight
    }

    func beginSync() { beginSyncCalls += 1; callLog.append("begin") }
    func connectAndSync() async { connectAndSyncCalls += 1; callLog.append("connect") }
    func awaitSyncCompletion(timeout: TimeInterval) async -> Bool {
        awaitCalls += 1
        callLog.append("await")
        return onAwait?() ?? true
    }
}

@MainActor
final class CoachNotificationSyncGatingTests: XCTestCase {

    /// A settings store with the coach master switch on so a non-forced `runDueSlot` reaches the
    /// freshness gate (provider `.userOpenAIKey` + a stub key ⇒ `coachEnabled`).
    private func enabledStore() -> CoachSettingsStore {
        let store = CoachSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.settings.coachMasterEnabled = true
        // Pin the keyed provider explicitly; the product default is now `.appleOnDevice`, which is
        // unavailable in CI and would gate the coach off.
        store.settings.providerMode = .userOpenAIKey
        return store
    }

    private func service(
        _ c: ModelContext,
        gate: RingSyncGating?,
        policy: CoachNotificationService.StaleDataPolicy = .sendWithLastKnown
    ) -> CoachNotificationService {
        CoachNotificationService(
            modelContext: c, coordinator: gate,
            keyStore: StubKeyStore(key: "sk-test"), settingsStore: enabledStore(),
            syncWaitTimeout: 1, staleDataPolicy: policy,
            clientFactory: { _ in StubResponsesClient([
                OpenAIResponse(id: "n", outputItems: [.message(text: notificationJSON())])
            ]) }
        )
    }

    private func morning() -> Date {
        Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    }

    /// Connected ring, no fresh data yet: the service starts a sync and waits; the wait lands a fresh
    /// HR sample, so the check-in sends. `beginSync` must precede the `await`.
    func testConnectedRingSyncsThenSends() async throws {
        let c = try TestSupport.makeContext()
        let gate = FakeSyncGate(connected: true)
        gate.onAwait = {
            TestSupport.insertMeasurement(kind: .heartRate, value: 72, timestamp: Date(), into: c)
            return true
        }
        let outcome = await service(c, gate: gate).runDueSlot(now: morning())
        if case .sent = outcome {} else { XCTFail("expected sent, got \(outcome)") }
        XCTAssertEqual(gate.beginSyncCalls, 1)
        XCTAssertEqual(gate.awaitCalls, 1)
        // beginSync before the wait.
        XCTAssertEqual(gate.callLog.firstIndex(of: "begin")!, gate.callLog.firstIndex(of: "await")! - 1)
    }

    /// A sync already in flight: the service just awaits it — it must NOT kick off a second sync.
    func testInFlightSyncIsAwaitedNotRestarted() async throws {
        let c = try TestSupport.makeContext()
        let gate = FakeSyncGate(connected: true, inFlight: true)
        gate.onAwait = {
            TestSupport.insertMeasurement(kind: .heartRate, value: 68, timestamp: Date(), into: c)
            return true
        }
        let outcome = await service(c, gate: gate).runDueSlot(now: morning())
        if case .sent = outcome {} else { XCTFail("expected sent, got \(outcome)") }
        XCTAssertEqual(gate.awaitCalls, 1)
        XCTAssertEqual(gate.beginSyncCalls, 0)
    }

    /// Gate times out (await returns false) but the store already holds an old-but-real measurement:
    /// sendWithLastKnown proceeds and sends.
    func testTimeoutWithLastKnownStillSends() async throws {
        let c = try TestSupport.makeContext()
        // A stale measurement (5h ago — outside the 3h freshness window) so the store isn't empty.
        TestSupport.insertMeasurement(kind: .heartRate, value: 60, timestamp: Date().addingTimeInterval(-5 * 3600), into: c)
        let gate = FakeSyncGate(connected: true)
        gate.onAwait = { false }   // sync never lands fresh data
        let outcome = await service(c, gate: gate, policy: .sendWithLastKnown).runDueSlot(now: morning())
        if case .sent = outcome {} else { XCTFail("expected sent, got \(outcome)") }
    }

    /// Same timeout, but `.skip` policy → skippedNoData.
    func testTimeoutWithSkipPolicySkips() async throws {
        let c = try TestSupport.makeContext()
        TestSupport.insertMeasurement(kind: .heartRate, value: 60, timestamp: Date().addingTimeInterval(-5 * 3600), into: c)
        let gate = FakeSyncGate(connected: true)
        gate.onAwait = { false }
        let outcome = await service(c, gate: gate, policy: .skip).runDueSlot(now: morning())
        XCTAssertEqual(outcome, .skippedNoData)
    }

    /// Timeout AND a truly empty store → skippedNoData even under sendWithLastKnown.
    func testTimeoutWithEmptyStoreSkips() async throws {
        let c = try TestSupport.makeContext()
        let gate = FakeSyncGate(connected: true)
        gate.onAwait = { false }
        let outcome = await service(c, gate: gate, policy: .sendWithLastKnown).runDueSlot(now: morning())
        XCTAssertEqual(outcome, .skippedNoData)
    }

    /// Disconnected + stale: the service tries to (re)connect and sync.
    func testDisconnectedTriesConnectAndSync() async throws {
        let c = try TestSupport.makeContext()
        let gate = FakeSyncGate(connected: false)
        gate.onAwait = {
            TestSupport.insertMeasurement(kind: .heartRate, value: 66, timestamp: Date(), into: c)
            return true
        }
        let outcome = await service(c, gate: gate).runDueSlot(now: morning())
        if case .sent = outcome {} else { XCTFail("expected sent, got \(outcome)") }
        XCTAssertEqual(gate.connectAndSyncCalls, 1)
        XCTAssertEqual(gate.beginSyncCalls, 0)
    }
}

// MARK: - Freshness gate (lastFullSyncAt) + persistence

@MainActor
final class CoachNotificationFreshnessTests: XCTestCase {

    private func service(_ c: ModelContext) -> CoachNotificationService {
        CoachNotificationService(
            modelContext: c, coordinator: nil,
            keyStore: StubKeyStore(key: "sk-test"),
            settingsStore: CoachSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
    }

    /// A Device with a fresh `lastSyncAt` (re-stamped on every connect) but nil `lastFullSyncAt` and
    /// no measurements must NOT count as recent — that was the stale-data bug.
    func testConnectStampAloneIsNotFresh() throws {
        let c = try TestSupport.makeContext()
        let device = Device()
        device.lastSyncAt = Date()
        device.lastFullSyncAt = nil
        c.insert(device)
        try c.save()
        XCTAssertFalse(service(c).hasRecentData(now: Date()))
    }

    /// A completed full sync (`lastFullSyncAt` = now) counts as recent.
    func testFullSyncStampIsFresh() throws {
        let c = try TestSupport.makeContext()
        let device = Device()
        device.lastFullSyncAt = Date()
        c.insert(device)
        try c.save()
        XCTAssertTrue(service(c).hasRecentData(now: Date()))
    }

    /// Applying `.syncProgress("done")` through the persistence subscriber stamps `lastFullSyncAt` on
    /// the Device row; a non-done stage leaves it nil.
    func testSyncProgressDoneStampsLastFullSyncAt() throws {
        let c = try TestSupport.makeContext()
        let device = Device()
        c.insert(device)
        try c.save()

        let subscriber = EventPersistenceSubscriber(context: c)
        subscriber.persist(.syncProgress(stage: "Syncing sleep…"))
        XCTAssertNil(DeviceRepository.current(context: c)?.lastFullSyncAt)

        subscriber.persist(.syncProgress(stage: "done"))
        XCTAssertNotNil(DeviceRepository.current(context: c)?.lastFullSyncAt)
    }
}
