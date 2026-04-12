import Foundation

struct PromptContext: Sendable {
    var agentCategory: AgentCategory = .general
    var frontmostApp: String = ""
    var lastTool: String = ""
    var lastToolFailed: Bool = false
    var messageCount: Int = 0
    var hasRecentImage: Bool = false
    var isPlanning: Bool = false
    var hasCodeKeywords: Bool = false
}

struct PromptModule: Sendable {
    let name: String
    let content: String
    let condition: @Sendable (PromptContext) -> Bool
    let priority: Int

    func shouldActivate(_ ctx: PromptContext) -> Bool {
        condition(ctx)
    }
}

enum PromptModules {
    private static let modules: [PromptModule] = [
        PromptModule(
            name: "coding_context",
            content: "The user appears to be working on code. Default to technical, precise responses. When showing code, write complete implementations.",
            condition: { $0.agentCategory == .coder || $0.hasCodeKeywords },
            priority: 50
        ),
        PromptModule(
            name: "writing_context",
            content: "The user is working on writing or communication. Focus on clarity, tone, and grammar. When rewriting, preserve the original meaning.",
            condition: { ["Mail", "Notes", "Pages", "TextEdit", "Messages"].contains($0.frontmostApp) },
            priority: 50
        ),
        PromptModule(
            name: "financial_data",
            content: "Financial data was retrieved. Be precise with numbers. Note prices are delayed. Do not make investment recommendations.",
            condition: { ["get_stock_price", "get_stock_history", "get_market_summary"].contains($0.lastTool) },
            priority: 40
        ),
        PromptModule(
            name: "tool_failure_retry",
            content: "A tool call just failed. Consider: Was the input correct? Try a different tool or adjust parameters before giving up.",
            condition: { $0.lastToolFailed },
            priority: 60
        ),
        PromptModule(
            name: "long_conversation",
            content: "This conversation is getting long. Be more concise. Summarize when possible rather than repeating context.",
            condition: { $0.messageCount > 20 },
            priority: 30
        ),
        PromptModule(
            name: "image_context",
            content: "An image was just analyzed or generated. You can reference the visual content in follow-up responses.",
            condition: { $0.hasRecentImage },
            priority: 40
        ),
        PromptModule(
            name: "chart_context",
            content: "A chart was just generated. If the user wants modifications, regenerate with updated code using generate_chart again.",
            condition: { $0.lastTool == "generate_chart" },
            priority: 40
        ),
        PromptModule(
            name: "browsing_context",
            content: "A web page was just browsed. Reference specific content from the page rather than making general statements.",
            condition: { ["browse_url", "browse_and_act", "fetch_page"].contains($0.lastTool) },
            priority: 40
        ),
        PromptModule(
            name: "planning_active",
            content: "You are executing a plan. After each step, briefly confirm what you did before moving to the next step. If a step fails, adapt.",
            condition: { $0.isPlanning },
            priority: 70
        ),
    ]

    static func activeModules(for context: PromptContext) -> [String] {
        modules
            .filter { $0.shouldActivate(context) }
            .sorted { $0.priority > $1.priority }
            .map(\.content)
    }
}
