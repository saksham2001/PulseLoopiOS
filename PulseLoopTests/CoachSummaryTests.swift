import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

private struct SummaryStubKeyStore: APIKeyStore {
    let key: String?
    func readKey() throws -> String? { key }
    func saveKey(_ key: String) throws {}
    func deleteKey() throws {}
}

private func summaryJSON(title: String = "Strong morning", body: String = "8,200 steps already.", chips: [String] = ["Why?"]) -> String {
    let chipsJSON = (try? String(data: JSONEncoder().encode(chips), encoding: .utf8)!) ?? "[]"
    return "{\"title\":\"\(title)\",\"body\":\"\(body)\",\"chips\":\(chipsJSON)}"
}

final class CoachSummaryContentTests: XCTestCase {
    func testSchemaAndDecode() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(CoachSummarySchema.jsonSchema))
        let c = CoachSummaryContent.decode(fromJSON: "noise \(summaryJSON()) tail")
        XCTAssertEqual(c?.title, "Strong morning")
        XCTAssertEqual(c?.chips, ["Why?"])
    }

    func testAsCoachResponseCarriesChips() {
        let c = CoachSummaryContent(title: "T", body: "B", chips: ["a", "b"])
        XCTAssertEqual(c.asCoachResponse().followUpChips, ["a", "b"])
    }
}

@MainActor
final class CoachSummaryServiceTests: XCTestCase {
    private func service(_ c: ModelContext, key: String? = "sk-test", json: String = summaryJSON()) -> CoachSummaryService {
        let store = CoachSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        // The coach is opt-out by default; turn the master switch on so summaries actually generate.
        store.settings.coachMasterEnabled = true
        return CoachSummaryService(
            modelContext: c,
            keyStore: SummaryStubKeyStore(key: key),
            settingsStore: store,
            clientFactory: { _ in StubResponsesClient([OpenAIResponse(id: "s", outputItems: [.message(text: json)])]) }
        )
    }

    private func seedToday(_ c: ModelContext, steps: Int) {
        TestSupport.insertActivity(date: Date(), steps: steps, calories: 300, into: c)
    }

    func testTodayGeneratesThenRespectsSignatureAndRateLimit() async throws {
        let c = try TestSupport.makeContext()
        seedToday(c, steps: 8200)
        let svc = service(c)

        await svc.refreshTodayIfNeeded()
        var todays = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "today" }
        XCTAssertEqual(todays.count, 1)
        XCTAssertEqual(todays.first?.title, "Strong morning")
        let sig1 = todays.first!.dataSignature
        let firstUpdated = todays.first!.updatedAt

        // Same data → no regeneration (signature unchanged).
        await svc.refreshTodayIfNeeded()
        todays = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "today" }
        XCTAssertEqual(todays.count, 1)
        XCTAssertEqual(todays.first!.updatedAt, firstUpdated)

        // New data but <2h since last → still skipped.
        seedToday(c, steps: 12000)
        await svc.refreshTodayIfNeeded()
        let after = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "today" }.first!
        XCTAssertEqual(after.updatedAt, firstUpdated)         // rate-limited
        XCTAssertEqual(after.dataSignature, sig1)             // unchanged
    }

    func testSleepDayGeneratesOncePerNight() async throws {
        let c = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: Calendar.current.startOfDay(for: Date()),
                                stages: Array(repeating: .light, count: 60) + Array(repeating: .deep, count: 30), into: c)
        let svc = service(c, json: summaryJSON(title: "Solid night", body: "1h30m tracked.", chips: ["Deep sleep?"]))
        // Pin `now` past the 4 AM day-reference flip so today's night is in the Day window
        // regardless of when the suite runs.
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: TestSupport.day(0)) ?? Date()

        await svc.refreshSleepDayIfNeeded(now: now)
        var sleeps = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "sleep_day" }
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps.first?.title, "Solid night")
        let updated = sleeps.first!.updatedAt

        // Second call same night → no new summary, no update (once per night).
        await svc.refreshSleepDayIfNeeded(now: now)
        sleeps = (try c.fetch(FetchDescriptor<CoachSummary>())).filter { $0.kind == "sleep_day" }
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps.first!.updatedAt, updated)
    }

    func testNoKeyUsesScriptedFallbackGroundedInData() async throws {
        let c = try TestSupport.makeContext()
        seedToday(c, steps: 9100)
        let svc = service(c, key: nil)  // disabled → scripted fallback (TodayInsights.deriveHero)
        await svc.refreshTodayIfNeeded()
        let today = (try c.fetch(FetchDescriptor<CoachSummary>())).first { $0.kind == "today" }
        XCTAssertNotNil(today)
        XCTAssertFalse(today!.title.isEmpty)
        XCTAssertFalse(today!.body.isEmpty)
    }

    func testOpenInChatSeedsConversationAndIsIdempotent() async throws {
        let c = try TestSupport.makeContext()
        seedToday(c, steps: 8200)
        let svc = service(c)
        await svc.refreshTodayIfNeeded()
        let summary = try XCTUnwrap((try c.fetch(FetchDescriptor<CoachSummary>())).first { $0.kind == "today" })

        svc.openInChat(summary)
        let convoId = try XCTUnwrap(summary.conversationId)
        // First message decodes to a CoachResponse carrying the chips.
        let messages = (try c.fetch(FetchDescriptor<CoachMessage>())).filter { $0.conversationId == convoId }
        XCTAssertEqual(messages.count, 1)
        let response = try XCTUnwrap(CoachResponse.decode(fromJSON: messages.first?.cardsJSON))
        XCTAssertEqual(response.followUpChips, ["Why?"])
        XCTAssertEqual(CoachNavigation.shared.requestedConversationId, convoId)

        // Re-tap reuses the same conversation (idempotent).
        svc.openInChat(summary)
        XCTAssertEqual(summary.conversationId, convoId)
        let convos = (try c.fetch(FetchDescriptor<CoachConversation>())).filter { $0.title == "Today recap" }
        XCTAssertEqual(convos.count, 1)
    }
}
