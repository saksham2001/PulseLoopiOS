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
        XCTAssertEqual(CoachNotificationSlot.current(for: at(8), morningHour: 8, eveningHour: 19), .morning)
        XCTAssertEqual(CoachNotificationSlot.current(for: at(11), morningHour: 8, eveningHour: 19), .morning)
        XCTAssertEqual(CoachNotificationSlot.current(for: at(19), morningHour: 8, eveningHour: 19), .evening)
        XCTAssertEqual(CoachNotificationSlot.current(for: at(21), morningHour: 8, eveningHour: 19), .evening)
        XCTAssertNil(CoachNotificationSlot.current(for: at(3), morningHour: 8, eveningHour: 19))   // too early
        XCTAssertNil(CoachNotificationSlot.current(for: at(15), morningHour: 8, eveningHour: 19))  // between windows
    }

    func testNextWindowStartIsInFuture() {
        let now = at(15)  // between windows → evening today
        let next = CoachNotificationSlot.nextWindowStart(after: now, morningHour: 8, eveningHour: 19)
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
