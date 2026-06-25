import Foundation
import SwiftData

/// Durable coach memory: save user-stated facts that matter for future coaching.
/// Gated by `enableWriteTools`. Ports the web app's `save_memory`/memory model.
@MainActor
enum MemoryTools {
    static let memoryTypes = [
        "goal", "routine", "preference", "constraint", "injury",
        "health_note", "coaching_style", "manual_correction", "lifestyle_context", "note",
    ]

    static var all: [AnyCoachTool] { [saveMemory] }

    private struct Args: Decodable {
        let memoryType: String
        let key: String
        let value: String
        let importance: Int
        let expiresInDays: Int?
        let reason: String
        enum CodingKeys: String, CodingKey {
            case memoryType = "memory_type", key, value, importance
            case expiresInDays = "expires_in_days", reason
        }
    }

    private static var saveMemory: AnyCoachTool {
        .make(
            name: "save_memory",
            label: "Saving this for future coaching",
            // swiftlint:disable:next line_length
            description: "Save an important durable user-stated fact, preference, routine, injury, goal, or constraint for future coaching. Use null expires_in_days for stable facts, 7–60 for temporary conditions (soreness, illness).",
            parameters: JSONSchema.object([
                "memory_type": JSONSchema.enumString(memoryTypes),
                "key": JSONSchema.string,
                "value": JSONSchema.string,
                "importance": ["type": "number", "minimum": 1, "maximum": 5],
                "expires_in_days": ["type": ["number", "null"]],
                "reason": JSONSchema.string,
            ], required: ["memory_type", "key", "value", "importance", "expires_in_days", "reason"]),
            argsType: Args.self
        ) { args, ctx in
            guard memoryTypes.contains(args.memoryType) else {
                return .error("invalid memory_type '\(args.memoryType)'")
            }
            let mem = save(
                context: ctx.modelContext,
                memoryType: args.memoryType,
                key: args.key,
                value: args.value,
                importance: args.importance,
                expiresInDays: args.expiresInDays
            )
            return .object(["ok": true, "memory_id": mem.id.uuidString,
                            "expires_at": mem.expiresAt.map(CoachDataAccess.isoString) as Any])
        }
    }

    /// Shared writer reused by `log_user_note` / `log_activity_correction`.
    @discardableResult
    static func save(
        context: ModelContext,
        memoryType: String,
        key: String,
        value: String,
        importance: Int = 3,
        expiresInDays: Int? = nil
    ) -> CoachMemory {
        let expiresAt = expiresInDays.flatMap {
            Calendar.current.date(byAdding: .day, value: $0, to: Date())
        }
        let mem = CoachMemory(
            key: key, value: value,
            memoryType: memoryType,
            importance: max(1, min(5, importance)),
            expiresAt: expiresAt
        )
        context.insert(mem)
        try? context.save()
        return mem
    }
}
