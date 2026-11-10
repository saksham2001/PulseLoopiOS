import Foundation
import SwiftData

/// One row of the coach history sheet: a past conversation, its title text and
/// how much is in it. Built from the SwiftData rows by `CoachHistory.summaries`.
struct CoachConversationSummary: Identifiable, Equatable {
    let id: UUID
    let updatedAt: Date
    /// The first thing the user asked; nil when the thread holds no typed question
    /// (a notification / summary thread, or an image-only first message).
    let firstQuestion: String?
    /// The stored conversation title, used when there's no question to show.
    let storedTitle: String
    let messageCount: Int

    var title: String { CoachHistoryText.title(firstQuestion: firstQuestion, storedTitle: storedTitle) }
}

/// Listing and deleting past coach conversations.
@MainActor
enum CoachHistory {
    /// Past conversations, newest first. Threads without a message are left out:
    /// "+" persists its thread up front, so an unused one would list as a blank row.
    static func summaries(conversations: [CoachConversation], messages: [CoachMessage]) -> [CoachConversationSummary] {
        let byConversation = Dictionary(grouping: messages, by: \.conversationId)
        return conversations.compactMap { convo -> CoachConversationSummary? in
            guard let rows = byConversation[convo.id], !rows.isEmpty else { return nil }
            let firstQuestion = rows
                .filter { $0.role == "user" && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .min { $0.createdAt < $1.createdAt }?
                .body
            return CoachConversationSummary(
                id: convo.id, updatedAt: convo.updatedAt, firstQuestion: firstQuestion,
                storedTitle: convo.title, messageCount: rows.count)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Delete one conversation with its messages, tool-call trace and attached
    /// photo files. `CoachMessage`/`CoachToolCall` only hold the conversation's id
    /// (no relationship), so each is cleared explicitly.
    static func delete(_ id: UUID, context: ModelContext) {
        let messages = (try? context.fetch(FetchDescriptor<CoachMessage>(
            predicate: #Predicate { $0.conversationId == id }))) ?? []
        let toolCalls = (try? context.fetch(FetchDescriptor<CoachToolCall>(
            predicate: #Predicate { $0.conversationId == id }))) ?? []
        let conversations = (try? context.fetch(FetchDescriptor<CoachConversation>(
            predicate: #Predicate { $0.id == id }))) ?? []
        remove(messages: messages, toolCalls: toolCalls, conversations: conversations, context: context)
    }

    /// Delete every conversation, message, tool-call record and attached photo.
    static func deleteAll(context: ModelContext) {
        remove(
            messages: (try? context.fetch(FetchDescriptor<CoachMessage>())) ?? [],
            toolCalls: (try? context.fetch(FetchDescriptor<CoachToolCall>())) ?? [],
            conversations: (try? context.fetch(FetchDescriptor<CoachConversation>())) ?? [],
            context: context)
    }

    private static func remove(
        messages: [CoachMessage], toolCalls: [CoachToolCall], conversations: [CoachConversation], context: ModelContext
    ) {
        let attachments = messages.flatMap { CoachAttachmentRef.decode(fromJSON: $0.attachmentsJSON) }
        toolCalls.forEach(context.delete)
        messages.forEach(context.delete)
        conversations.forEach(context.delete)
        try? context.save()
        // Files go last, once the rows that point at them are gone.
        attachments.forEach(CoachAttachmentStore.delete)
    }
}

/// The history row's text, kept out of the view so it can be unit-tested.
enum CoachHistoryText {
    static let untitled = "Untitled conversation"
    /// Placeholder titles a thread gets before its first question.
    private static let placeholderTitles: Set<String> = ["New chat", "Today check-in"]

    /// The first question on one line; else the stored title (notification and
    /// summary threads are titled meaningfully); else a placeholder.
    static func title(firstQuestion: String?, storedTitle: String? = nil) -> String {
        if let question = oneLine(firstQuestion) { return question }
        if let stored = oneLine(storedTitle), !placeholderTitles.contains(stored) { return stored }
        return untitled
    }

    /// "Today 14:05 · 4 messages".
    static func subtitle(
        _ convo: CoachConversationSummary, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let count = convo.messageCount == 1 ? "1 message" : "\(convo.messageCount) messages"
        return "\(whenText(convo.updatedAt, now: now, calendar: calendar, locale: locale)) · \(count)"
    }

    /// "Today 14:05", "Yesterday 09:15", "Oct 12", or "Dec 30, 2025" when the year differs.
    static func whenText(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.timeStyle = .short
            return "Today " + formatter.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.timeStyle = .short
            return "Yesterday " + formatter.string(from: date)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return formatter.string(from: date)
    }

    private static func oneLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
