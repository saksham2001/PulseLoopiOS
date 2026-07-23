import Foundation

/// Assembles the enabled tool set + OpenAI tool specs for a turn. Milestone A
/// exposes read-only tools (retrieval, charting, analysis); write/action and
/// live-measurement tools are layered in Milestone B behind `flags`.
@MainActor
struct ToolRegistry {
    let flags: CoachFeatureFlags
    private let tools: [String: AnyCoachTool]

    init(flags: CoachFeatureFlags) {
        self.flags = flags
        var all = RetrievalTools.all + ChartTools.all + AnalysisTools.all
        if flags.writeToolsEnabled {
            all += MemoryTools.all + ActionTools.writeTools
        }
        if flags.liveMeasurementsEnabled {
            all += ActionTools.measurementTools
        }
        if flags.nutritionContextEnabled {
            all += NutritionTools.readTools
        }
        if flags.nutritionWriteEnabled {
            all += NutritionTools.writeTools
        }
        self.tools = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }

    func tool(named name: String) -> AnyCoachTool? { tools[name] }

    var labels: [String: String] {
        Dictionary(uniqueKeysWithValues: tools.map { ($0.key, $0.value.publicLabel) })
    }

    /// Full `tools` array for a Responses API request (function specs + hosted
    /// web-search spec when enabled).
    var toolSpecs: [[String: Any]] {
        var specs = tools.values.map(\.toolSpec)
        // Stable order helps caching and trace readability.
        specs.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        if flags.webSearchEnabled {
            specs.append(WebSearchTool.spec)
        }
        return specs
    }
}
