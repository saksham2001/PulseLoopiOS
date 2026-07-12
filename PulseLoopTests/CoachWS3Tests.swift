import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

private struct WS3KeyStore: APIKeyStore {
    let key: String?
    func readKey() throws -> String? { key }
    func saveKey(_ key: String) throws {}
    func deleteKey() throws {}
}

private func ws3SummaryJSON(title: String = "Solid night", body: String = "Slept well.", chips: [String] = ["Why?"]) -> String {
    let chipsJSON = (try? String(data: JSONEncoder().encode(chips), encoding: .utf8)!) ?? "[]"
    return "{\"title\":\"\(title)\",\"body\":\"\(body)\",\"chips\":\(chipsJSON)}"
}

// MARK: - Variety hints (pure)

final class CoachVarietyHintsTests: XCTestCase {
    func testAngleIsDeterministicForSameSeed() {
        let a = CoachVarietyHints.angle(seed: "2026-07-08morning")
        let b = CoachVarietyHints.angle(seed: "2026-07-08morning")
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
        XCTAssertTrue(CoachVarietyHints.angles.contains(a))
    }

    func testDifferentSeedsRotateAngles() {
        // Across a spread of seeds we should touch more than one angle (rotation),
        // and every result must be a real angle.
        var seen = Set<String>()
        for i in 0..<40 {
            let angle = CoachVarietyHints.angle(seed: "seed-\(i)")
            XCTAssertTrue(CoachVarietyHints.angles.contains(angle))
            seen.insert(angle)
        }
        XCTAssertGreaterThan(seen.count, 1)
    }

    func testFnv1aIsStableAcrossCalls() {
        XCTAssertEqual(CoachVarietyHints.fnv1a("pulseloop"), CoachVarietyHints.fnv1a("pulseloop"))
        XCTAssertNotEqual(CoachVarietyHints.fnv1a("a"), CoachVarietyHints.fnv1a("b"))
    }
}

// MARK: - Sleep-sync gate + signature regeneration

@MainActor
final class CoachSleepGateTests: XCTestCase {
    private func service(_ c: ModelContext, json: String = ws3SummaryJSON()) -> CoachSummaryService {
        let store = CoachSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.settings.coachMasterEnabled = true
        // Pin the keyed provider (paired with the stub key) so the coach isn't gated off by the new
        // product default `.appleOnDevice`, which is unavailable in CI.
        store.settings.providerMode = .userOpenAIKey
        return CoachSummaryService(
            modelContext: c,
            keyStore: WS3KeyStore(key: "sk-test"),
            settingsStore: store,
            clientFactory: { _ in StubResponsesClient([OpenAIResponse(id: "s", outputItems: [.message(text: json)])]) }
        )
    }

    /// Insert a night that wakes at 06:00 today, spanning `minutes`; returns endAt.
    @discardableResult
    private func seedNight(_ c: ModelContext, minutes: Int, deep: Int) -> Date {
        let wake = Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: TestSupport.day(0)) ?? Date()
        let start = wake.addingTimeInterval(-Double(minutes) * 60)
        var stages: [SleepStage] = Array(repeating: .light, count: max(0, minutes - deep))
        stages += Array(repeating: .deep, count: deep)
        let session = TestSupport.insertSleep(nightStart: start, stages: stages, into: c)
        return session.endAt
    }

    private func sleepCount(_ c: ModelContext) throws -> Int {
        (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "sleep_day" }.count
    }

    private func setFullSync(_ c: ModelContext, at date: Date?) {
        let device = Device()
        device.lastFullSyncAt = date
        c.insert(device)
        try? c.save()
    }

    /// Streaming device (no full-sync stamp): gate falls back to now >= endAt + 2h.
    func testNoFullSyncStampFallsBackToTwoHours() async throws {
        let c = try TestSupport.makeContext()
        let end = seedNight(c, minutes: 420, deep: 90)   // ~7h night ending 06:00
        let svc = service(c)

        // Just after wake (30min < 2h fallback) → gated off.
        await svc.refreshSleepDayIfNeeded(now: end.addingTimeInterval(40 * 60))
        XCTAssertEqual(try sleepCount(c), 0)

        // 2h+ after wake → generates.
        await svc.refreshSleepDayIfNeeded(now: end.addingTimeInterval(2 * 3600 + 60))
        XCTAssertEqual(try sleepCount(c), 1)
    }

    /// Full-sync stamp BEFORE the night ended → mid-sync, gated off.
    func testFullSyncBeforeEndIsGated() async throws {
        let c = try TestSupport.makeContext()
        let end = seedNight(c, minutes: 420, deep: 90)
        setFullSync(c, at: end.addingTimeInterval(-30 * 60))   // stamped before wake
        let svc = service(c)

        await svc.refreshSleepDayIfNeeded(now: end.addingTimeInterval(3 * 3600))
        XCTAssertEqual(try sleepCount(c), 0)
    }

    /// Full-sync stamp AT/AFTER the night ended (and past the 30min floor) → generates.
    func testFullSyncAfterEndGenerates() async throws {
        let c = try TestSupport.makeContext()
        let end = seedNight(c, minutes: 420, deep: 90)
        setFullSync(c, at: end.addingTimeInterval(10 * 60))   // stamped after wake
        let svc = service(c)

        await svc.refreshSleepDayIfNeeded(now: end.addingTimeInterval(45 * 60))
        XCTAssertEqual(try sleepCount(c), 1)
    }

    /// now < endAt + 30min → gated off regardless of sync.
    func testBeforeThirtyMinuteFloorIsGated() async throws {
        let c = try TestSupport.makeContext()
        let end = seedNight(c, minutes: 420, deep: 90)
        setFullSync(c, at: end.addingTimeInterval(5 * 60))
        let svc = service(c)

        await svc.refreshSleepDayIfNeeded(now: end.addingTimeInterval(10 * 60))   // <30min
        XCTAssertEqual(try sleepCount(c), 0)
    }

    /// A late sync that grows the night (new signature) after the minInterval floor
    /// triggers exactly one corrective regeneration.
    func testSignatureRegenerationAfterGrowth() async throws {
        let c = try TestSupport.makeContext()
        let end = seedNight(c, minutes: 300, deep: 60)
        setFullSync(c, at: end.addingTimeInterval(10 * 60))
        let svc = service(c)

        let t0 = end.addingTimeInterval(45 * 60)
        await svc.refreshSleepDayIfNeeded(now: t0)
        var rows = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "sleep_day" }
        XCTAssertEqual(rows.count, 1)
        let firstSig = rows.first!.dataSignature

        // Same data again → no regeneration (signature unchanged, still one row).
        await svc.refreshSleepDayIfNeeded(now: t0.addingTimeInterval(3 * 3600))
        rows = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "sleep_day" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first!.dataSignature, firstSig)

        // Late sync grows the SAME night (same waking day) → new signature. Replace the
        // session so there's exactly one for the scope, then regenerate past the 2h floor.
        for s in SleepRepository.sessions(context: c) { c.delete(s) }
        try c.save()
        seedNight(c, minutes: 420, deep: 90)
        // Backdate the existing card so it's clearly past the 2h minInterval floor.
        rows.first!.updatedAt = t0.addingTimeInterval(-3 * 3600)
        try c.save()
        await svc.refreshSleepDayIfNeeded(now: t0.addingTimeInterval(3 * 3600))
        rows = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "sleep_day" }
        XCTAssertEqual(rows.count, 1)                              // corrective upsert, not a duplicate
        XCTAssertNotEqual(rows.first!.dataSignature, firstSig)     // regenerated with the grown night
    }
}

// MARK: - sleepDataSynced gate (morning notifications)

@MainActor
final class CoachSleepDataSyncedTests: XCTestCase {
    private func service(_ c: ModelContext) -> CoachNotificationService {
        CoachNotificationService(
            modelContext: c, coordinator: nil,
            keyStore: WS3KeyStore(key: "sk-test"),
            settingsStore: CoachSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
    }

    private func seedRecentNight(_ c: ModelContext, now: Date) -> Date {
        let start = now.addingTimeInterval(-8 * 3600)
        let session = TestSupport.insertSleep(nightStart: start, stages: Array(repeating: .light, count: 420), into: c)
        return session.endAt
    }

    /// No session at all → passes (nothing to wait on).
    func testNoSessionPasses() throws {
        let c = try TestSupport.makeContext()
        XCTAssertTrue(service(c).sleepDataSynced(now: Date()))
    }

    /// Recent night, no device/full-sync stamp → passes permissively.
    func testNoDeviceStampPasses() throws {
        let c = try TestSupport.makeContext()
        let now = Date()
        _ = seedRecentNight(c, now: now)
        XCTAssertTrue(service(c).sleepDataSynced(now: now))
    }

    /// Recent night, full sync BEFORE the night ended → fails (still syncing).
    func testFullSyncBeforeEndFails() throws {
        let c = try TestSupport.makeContext()
        let now = Date()
        let end = seedRecentNight(c, now: now)
        let device = Device()
        device.lastFullSyncAt = end.addingTimeInterval(-20 * 60)
        c.insert(device)
        try c.save()
        XCTAssertFalse(service(c).sleepDataSynced(now: now))
    }

    /// Recent night, full sync AT/AFTER the night ended → passes.
    func testFullSyncAfterEndPasses() throws {
        let c = try TestSupport.makeContext()
        let now = Date()
        let end = seedRecentNight(c, now: now)
        let device = Device()
        device.lastFullSyncAt = end.addingTimeInterval(30 * 60)
        c.insert(device)
        try c.save()
        XCTAssertTrue(service(c).sleepDataSynced(now: now))
    }
}
