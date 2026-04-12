import Foundation

// MARK: - ReAct Reflection

extension BaseAgent {

    /// Evaluate whether tool results adequately address the user's query.
    /// Returns true if more tool calls are needed, false if ready to respond.
    func reflect(originalQuery: String, toolResults: [String]) async -> Bool {
        let combinedResults = toolResults.joined(separator: "\n---\n").prefix(2000)

        do {
            let resp = try await client.chat(
                model: "qwen3.5:0.8b",
                messages: [
                    ["role": "system", "content": "Given a user query and tool results, determine if MORE tool calls are needed. Respond with ONLY 'CONTINUE' or 'SUFFICIENT'. CONTINUE if information is clearly missing or wrong. SUFFICIENT if we can answer."],
                    ["role": "user", "content": "Query: \(originalQuery)\n\nResults:\n\(combinedResults)"],
                ],
                tools: nil,
                temperature: 0.1,
                numCtx: 1024,
                timeout: 10
            )

            let answer = ThinkingStripper.strip(resp.content).uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let needsMore = answer.contains("CONTINUE")
            Log.agents.info("[\(self.name)] reflection: \(needsMore ? "continue" : "sufficient")")
            return needsMore
        } catch {
            Log.agents.warning("[\(self.name)] reflection failed: \(error)")
            return false  // Default to stopping if reflection fails
        }
    }
}
