import Foundation

/// Hand-written strict JSON Schema for the `coach_response` structured output,
/// ported verbatim from `backend/app/schemas/coach.py::COACH_RESPONSE_JSON_SCHEMA`.
/// Every property is required and `additionalProperties` is false everywhere —
/// the exact shape OpenAI Structured Outputs strict mode expects.
///
/// `cards` is intentionally NOT in this schema for Milestone A (read-only); the
/// Swift `CoachResponse` type tolerates it for forward compatibility.
enum CoachResponseSchema {
    static let name = "coach_response"

    /// Plain-language description of the exact `coach_response` shape, for
    /// providers that **can't enforce** the JSON schema out-of-band (OpenRouter
    /// sends no `response_format` because several models in its catalog reject
    /// this app's schema). Native OpenAI/Gemini enforce `jsonSchema` directly and
    /// don't need this. Keep in sync with `jsonSchema` / `CoachResponse`.
    static let promptInstruction = """
    Your final answer MUST be a single JSON object (no Markdown, no code fences, \
    no prose before or after) matching this exact `coach_response` schema. Use \
    these exact snake_case keys — all are required:
    {
      "response_type": one of "insight" | "insight_with_chart" | "question" | "action_confirmation" | "data_missing" | "safety_guidance" | "error_recovery",
      "title": string (≤ 90 chars),
      "summary": string (≤ 900 chars) — put the main answer here, not in a "message" field,
      "bullets": array of strings (≤ 5 items, each ≤ 220 chars),
      "chart": null, or a chart object (only when response_type is "insight_with_chart"),
      "safety_note": string or null,
      "data_quality_note": string or null,
      "sources": array of { "title": string, "url": string, "publisher": string } (use [] if none),
      "follow_up_chips": array of strings (≤ 4 items, each ≤ 60 chars),
      "actions_taken": array of strings (use [] if none),
      "confidence": one of "low" | "medium" | "high"
    }
    Do NOT use a "message" key. Do NOT wrap the JSON in ``` fences. Put your \
    formatted text inside "summary" and "bullets".
    """

    /// The `text.format` object for a Responses API request.
    static var textFormat: [String: Any] {
        [
            "type": "json_schema",
            "name": name,
            "schema": jsonSchema,
            "strict": true,
        ]
    }

    static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "response_type": [
                    "type": "string",
                    "enum": [
                        "insight", "insight_with_chart", "question",
                        "action_confirmation", "data_missing",
                        "safety_guidance", "error_recovery",
                    ],
                ],
                "title": ["type": "string", "maxLength": 90],
                "summary": ["type": "string", "maxLength": 900],
                "bullets": [
                    "type": "array",
                    "items": ["type": "string", "maxLength": 220],
                    "maxItems": 5,
                ],
                "chart": chartSchema,
                "safety_note": ["type": ["string", "null"], "maxLength": 350],
                "data_quality_note": ["type": ["string", "null"], "maxLength": 350],
                "sources": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "url": ["type": "string"],
                            "publisher": ["type": "string"],
                        ],
                        "required": ["title", "url", "publisher"],
                        "additionalProperties": false,
                    ],
                ],
                "follow_up_chips": [
                    "type": "array",
                    "items": ["type": "string", "maxLength": 60],
                    "maxItems": 4,
                ],
                "actions_taken": ["type": "array", "items": ["type": "string"]],
                "confidence": ["type": "string", "enum": ["low", "medium", "high"]],
            ],
            "required": [
                "response_type", "title", "summary", "bullets", "chart",
                "safety_note", "data_quality_note", "sources",
                "follow_up_chips", "actions_taken", "confidence",
            ],
            "additionalProperties": false,
        ]
    }

    private static var chartSchema: [String: Any] {
        [
            "type": ["object", "null"],
            "properties": [
                "chart_type": [
                    "type": "string",
                    "enum": ["line", "bar", "dot", "sleep_stage", "sparkline"],
                ],
                "title": ["type": "string"],
                "metric": [
                    "type": "string",
                    "enum": ["steps", "hr", "spo2", "sleep", "active_minutes", "calories", "distance"],
                ],
                "range": [
                    "type": "object",
                    "properties": [
                        "start": ["type": "string"],
                        "end": ["type": "string"],
                    ],
                    "required": ["start", "end"],
                    "additionalProperties": false,
                ],
                "data": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "x": ["type": "string"],
                            "y": ["type": "number"],
                            "series": ["type": ["string", "null"]],
                        ],
                        "required": ["x", "y", "series"],
                        "additionalProperties": false,
                    ],
                ],
                "annotations": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "x": ["type": "string"],
                            "label": ["type": "string"],
                        ],
                        "required": ["x", "label"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["chart_type", "title", "metric", "range", "data", "annotations"],
            "additionalProperties": false,
        ]
    }
}
