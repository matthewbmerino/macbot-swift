import Foundation

enum RecallEpisodesTool {

    static let spec = ToolSpec(
        name: "recall_episodes",
        description: "Recall past conversation episodes (auto-summarized chat sessions). Use this when the user asks about previous conversations, what they discussed before, or 'last time we talked about X'. Returns matching episodes with their summaries.",
        properties: [
            "query": .init(type: "string", description: "Optional keyword/topic to search for. Leave empty to get most recent episodes."),
            "limit": .init(type: "string", description: "Max episodes to return (default 5)"),
        ]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { args in
            recallEpisodes(
                query: args["query"] as? String ?? "",
                limit: Int(args["limit"] as? String ?? "5") ?? 5
            )
        }
    }

    // MARK: - Recall Episodes

    static func recallEpisodes(query: String, limit: Int) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let episodes = q.isEmpty
            ? EpisodicMemory.shared.recent(limit: limit)
            : EpisodicMemory.shared.search(query: q, limit: limit)

        if episodes.isEmpty {
            return q.isEmpty ? "No past episodes recorded yet." : "No episodes found matching '\(q)'."
        }
        return EpisodicMemory.format(episodes)
    }
}
