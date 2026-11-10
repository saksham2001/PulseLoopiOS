import Foundation
import SwiftData
import UIKit
import XCTest
@testable import PulseLoop

// MARK: - Row text (port of Android CoachHistoryTextTest)

final class CoachHistoryTextTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")
    private lazy var now = date(2026, 10, 21, 18, 0)

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 9, _ mi: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func when(_ d: Date) -> String {
        CoachHistoryText.whenText(d, now: now, calendar: calendar, locale: locale)
    }

    private func convo(_ updatedAt: Date, count: Int = 4) -> CoachConversationSummary {
        CoachConversationSummary(id: UUID(), updatedAt: updatedAt, firstQuestion: "How did I sleep?",
                                 storedTitle: "New chat", messageCount: count)
    }

    func testTitleIsTheFirstQuestionOnOneLine() {
        XCTAssertEqual(CoachHistoryText.title(firstQuestion: "  How did I sleep\n\nlast   night?  "),
                       "How did I sleep last night?")
    }

    func testMissingOrBlankQuestionGetsAPlaceholder() {
        XCTAssertEqual(CoachHistoryText.title(firstQuestion: nil), "Untitled conversation")
        XCTAssertEqual(CoachHistoryText.title(firstQuestion: " \n "), "Untitled conversation")
        XCTAssertEqual(CoachHistoryText.title(firstQuestion: nil, storedTitle: "New chat"), "Untitled conversation")
    }

    func testThreadWithoutAQuestionFallsBackToItsStoredTitle() {
        XCTAssertEqual(CoachHistoryText.title(firstQuestion: nil, storedTitle: "Sleep recap"), "Sleep recap")
        XCTAssertEqual(CoachHistoryText.title(firstQuestion: "Why?", storedTitle: "Sleep recap"), "Why?")
    }

    func testTodayAndYesterdayAreNamedWithTheTime() {
        XCTAssertTrue(when(date(2026, 10, 21, 14, 5)).hasPrefix("Today "))
        XCTAssertTrue(when(date(2026, 10, 21, 14, 5)).contains("2:05"))
        XCTAssertTrue(when(date(2026, 10, 20)).hasPrefix("Yesterday "))
    }

    func testOlderDatesShowTheYearOnlyWhenItDiffers() {
        XCTAssertEqual(when(date(2026, 10, 12)), "Oct 12")
        XCTAssertFalse(when(date(2026, 10, 12)).contains("2026"))
        XCTAssertTrue(when(date(2025, 12, 30)).contains("2025"))
    }

    func testSubtitleCountsMessages() {
        let at = date(2026, 10, 12)
        let d = when(at)
        XCTAssertEqual(CoachHistoryText.subtitle(convo(at, count: 1), now: now, calendar: calendar, locale: locale),
                       "\(d) · 1 message")
        XCTAssertEqual(CoachHistoryText.subtitle(convo(at), now: now, calendar: calendar, locale: locale),
                       "\(d) · 4 messages")
    }
}

// MARK: - Listing + deleting

private struct HistoryKeyStore: APIKeyStore {
    func readKey() throws -> String? { "sk-test" }
    func saveKey(_ key: String) throws {}
    func deleteKey() throws {}
}

/// Deletes the conversation while the "provider" is answering, then replies.
private actor DeletingMidTurnClient: ResponsesClient {
    let onSend: @MainActor () -> Void
    init(onSend: @escaping @MainActor () -> Void) { self.onSend = onSend }
    func send(requestBody: Data) async throws -> OpenAIResponse {
        await onSend()
        return OpenAIResponse(id: "r1", outputItems: [.message(text: """
            {"response_type":"insight","title":"Late","summary":"Too late.","bullets":[],\
            "chart":null,"safety_note":null,"data_quality_note":null,"sources":[],\
            "follow_up_chips":[],"actions_taken":[],"confidence":"high"}
            """)])
    }
}

@MainActor
final class CoachHistoryTests: XCTestCase {
    private func message(_ convo: UUID, _ role: String, _ body: String, at: Date, attachments: String? = nil) -> CoachMessage {
        CoachMessage(conversationId: convo, role: role, body: body, attachmentsJSON: attachments, createdAt: at)
    }

    func testSummariesHideEmptyThreadsAndListNewestFirst() throws {
        let c = try TestSupport.makeContext()
        let old = CoachConversation(title: "New chat")
        old.updatedAt = Date(timeIntervalSince1970: 1_000)
        let recent = CoachConversation(title: "Sleep recap")
        recent.updatedAt = Date(timeIntervalSince1970: 3_000)
        let empty = CoachConversation(title: "New chat")
        empty.updatedAt = Date(timeIntervalSince1970: 5_000)
        [old, recent, empty].forEach(c.insert)
        let t0 = Date(timeIntervalSince1970: 100)
        let messages = [
            message(old.id, "user", "Second?", at: t0.addingTimeInterval(20)),
            message(old.id, "user", "First\nquestion", at: t0),
            message(old.id, "assistant", "Answer", at: t0.addingTimeInterval(10)),
            message(recent.id, "assistant", "Sleep recap body", at: t0),
        ]

        let rows = CoachHistory.summaries(conversations: [old, recent, empty], messages: messages)

        XCTAssertEqual(rows.map(\.id), [recent.id, old.id])
        XCTAssertEqual(rows[0].title, "Sleep recap")
        XCTAssertEqual(rows[0].messageCount, 1)
        XCTAssertEqual(rows[1].title, "First question")
        XCTAssertEqual(rows[1].messageCount, 3)
    }

    func testDeleteRemovesMessagesToolCallsAndPhotosOfThatConversationOnly() throws {
        let c = try TestSupport.makeContext()
        let gone = CoachConversation(title: "a"), kept = CoachConversation(title: "b")
        c.insert(gone); c.insert(kept)
        let ref = try XCTUnwrap(CoachAttachmentStore.save(Self.image()))
        c.insert(message(gone.id, "user", "", at: Date(), attachments: CoachAttachmentRef.encode([ref])))
        c.insert(CoachToolCall(conversationId: gone.id, toolName: "get_daily_summary"))
        c.insert(message(kept.id, "user", "Hi", at: Date()))
        c.insert(CoachToolCall(conversationId: kept.id, toolName: "get_daily_summary"))
        try c.save()
        XCTAssertNotNil(CoachAttachmentStore.data(for: ref))

        CoachHistory.delete(gone.id, context: c)

        XCTAssertEqual(try c.fetch(FetchDescriptor<CoachConversation>()).map(\.id), [kept.id])
        XCTAssertEqual(try c.fetch(FetchDescriptor<CoachMessage>()).map(\.conversationId), [kept.id])
        XCTAssertEqual(try c.fetch(FetchDescriptor<CoachToolCall>()).map(\.conversationId), [kept.id])
        XCTAssertNil(CoachAttachmentStore.data(for: ref))
    }

    func testDeleteAllClearsEverything() throws {
        let c = try TestSupport.makeContext()
        let a = CoachConversation(title: "a"), b = CoachConversation(title: "b")
        c.insert(a); c.insert(b)
        let ref = try XCTUnwrap(CoachAttachmentStore.save(Self.image()))
        c.insert(message(a.id, "user", "Hi", at: Date(), attachments: CoachAttachmentRef.encode([ref])))
        c.insert(message(b.id, "user", "Yo", at: Date()))
        c.insert(CoachToolCall(conversationId: b.id, toolName: "get_daily_summary"))
        try c.save()

        CoachHistory.deleteAll(context: c)

        XCTAssertTrue(try c.fetch(FetchDescriptor<CoachConversation>()).isEmpty)
        XCTAssertTrue(try c.fetch(FetchDescriptor<CoachMessage>()).isEmpty)
        XCTAssertTrue(try c.fetch(FetchDescriptor<CoachToolCall>()).isEmpty)
        XCTAssertNil(CoachAttachmentStore.data(for: ref))
    }

    func testReplyToAConversationDeletedMidTurnDoesNotResurrectIt() async throws {
        let c = try TestSupport.makeContext()
        let convo = CoachConversation(title: "New chat")
        c.insert(convo)
        try c.save()
        let convoId = convo.id
        let settings = CoachSettingsStore(defaults: UserDefaults(suiteName: "coach-history-\(UUID())")!)
        settings.settings = TestSupport.enabledCoachSettings()
        let client = DeletingMidTurnClient { CoachHistory.delete(convoId, context: c) }
        let vm = CoachViewModel(keyStore: HistoryKeyStore(), settingsStore: settings, clientFactory: { _ in client })

        await vm.send("How did I sleep?", conversationId: convoId, context: c)

        XCTAssertTrue(try c.fetch(FetchDescriptor<CoachConversation>()).isEmpty)
        XCTAssertTrue(try c.fetch(FetchDescriptor<CoachMessage>()).isEmpty, "the late reply must be dropped")
        XCTAssertTrue(try c.fetch(FetchDescriptor<CoachToolCall>()).isEmpty)
        XCTAssertNil(vm.sendingConversationId)
    }

    private static func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}
