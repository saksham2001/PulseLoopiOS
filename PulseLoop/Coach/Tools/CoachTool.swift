import Foundation
import SwiftData

/// Everything a tool handler needs. Extended in Milestone B (ring coordinator
/// for live measurements, write-tool gates).
@MainActor
final class ToolExecutionContext {
    let modelContext: ModelContext
    let flags: CoachFeatureFlags
    /// Optional coordinator for live ring measurements (Milestone B).
    let coordinator: RingSyncCoordinator?
    /// Risky writes proposed this turn, awaiting a Confirm/Cancel tap.
    var pendingActions: [PendingAction] = []
    /// Activity sessions created/edited during this turn (immediate writes, not
    /// confirmation-gated ones). Drives the in-chat workout card.
    var loggedActivityIds: [UUID] = []

    init(modelContext: ModelContext, flags: CoachFeatureFlags, coordinator: RingSyncCoordinator? = nil) {
        self.modelContext = modelContext
        self.flags = flags
        self.coordinator = coordinator
    }
}

/// JSON-safe result of a tool call. The orchestrator feeds `jsonString` back to
/// the model as `function_call_output`.
struct ToolResult {
    let jsonString: String
    let isError: Bool

    init(jsonString: String, isError: Bool = false) {
        self.jsonString = jsonString
        self.isError = isError
    }

    /// Build from a `[String: Any]` (must be JSON-serializable).
    static func object(_ dict: [String: Any]) -> ToolResult {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else {
            return .error("tool result was not JSON-serializable")
        }
        return ToolResult(jsonString: str)
    }

    /// Build from an `Encodable` (snake_case keys for model readability).
    static func encoding<T: Encodable>(_ value: T) -> ToolResult {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) else {
            return .error("tool result could not be encoded")
        }
        return ToolResult(jsonString: str)
    }

    static func error(_ message: String) -> ToolResult {
        let escaped = (try? JSONSerialization.data(withJSONObject: ["error": message]))
            .flatMap { String(data: $0, encoding: .utf8) }
        return ToolResult(jsonString: escaped ?? "{\"error\":\"tool failed\"}", isError: true)
    }

    /// Compact one-line summary for the transparency trace.
    var summary: String {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        if let err = obj["error"] as? String { return "error: \(err)".prefix(160).description }
        return obj.keys.sorted().joined(separator: ", ").prefix(160).description
    }
}

/// Type-erased tool: an OpenAI function spec plus a decode-and-run handler.
/// (Associated-type protocols are awkward to store heterogeneously in Swift, so
/// each concrete tool is built into this erased form.)
@MainActor
struct AnyCoachTool {
    let name: String
    let publicLabel: String
    let description: String
    let parameters: [String: Any]
    let strict: Bool
    let run: (Data, ToolExecutionContext) async throws -> ToolResult

    /// OpenAI Responses API function-tool spec.
    var toolSpec: [String: Any] {
        var spec: [String: Any] = [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": parameters,
        ]
        if strict { spec["strict"] = true }
        return spec
    }

    /// Build an erased tool from a `Decodable` argument type.
    static func make<Args: Decodable>(
        name: String,
        label: String,
        description: String,
        parameters: [String: Any],
        strict: Bool = true,
        argsType: Args.Type,
        handler: @escaping @MainActor (Args, ToolExecutionContext) async throws -> ToolResult
    ) -> AnyCoachTool {
        AnyCoachTool(
            name: name,
            publicLabel: label,
            description: description,
            parameters: parameters,
            strict: strict,
            run: { data, ctx in
                let payload = data.isEmpty ? Data("{}".utf8) : data
                let args: Args
                do {
                    args = try JSONDecoder().decode(Args.self, from: payload)
                } catch {
                    return .error("invalid arguments: \(error.localizedDescription)")
                }
                return try await handler(args, ctx)
            }
        )
    }
}

/// Empty argument payload for no-parameter tools.
struct NoArgs: Decodable {}

/// Small helpers for hand-writing strict JSON Schemas.
enum JSONSchema {
    static let string: [String: Any] = ["type": "string"]
    static let number: [String: Any] = ["type": "number"]
    static let boolean: [String: Any] = ["type": "boolean"]

    static func enumString(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }

    static func array(_ items: [String: Any]) -> [String: Any] {
        ["type": "array", "items": items]
    }

    static func object(
        _ properties: [String: Any],
        required: [String],
        additionalProperties: Bool = false
    ) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": additionalProperties,
        ]
    }

    static let empty: [String: Any] = object([:], required: [])
}
