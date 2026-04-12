import Foundation

// MARK: - History Compaction

extension BaseAgent {

    func trimHistory() async {
        guard history.count >= 3 else { return }

        let budget = Int(Double(numCtx) * 0.75)
        guard tokenCount > budget else { return }

        let systemMsg = history[0]
        let msgCount = history.count
        let middle = Array(history[1..<max(1, history.count - 4)])

        let summary = await summarizeHistory(middle)

        if let summary = summary, !summary.isEmpty, let memoryStore, let userId {
            memoryStore.saveConversationSummary(userId: userId, summary: summary, messageCount: msgCount)
        }

        let tail = Array(history.suffix(4))
        history = [systemMsg]

        if let summary, !summary.isEmpty {
            history.append([
                "role": "system",
                "content": "[Conversation summary so far]\n\(summary)",
            ])
        }

        history.append(contentsOf: tail)
        tokenCount = TokenEstimator.estimate(messages: history)

        Log.agents.info("[\(self.name)] trimmed history to ~\(self.tokenCount) tokens")
    }

    private func summarizeHistory(_ messages: [[String: Any]]) async -> String? {
        guard !messages.isEmpty else { return nil }

        var lines: [String] = []
        for msg in messages.suffix(20) {
            let role = msg["role"] as? String ?? "?"
            let content = msg["content"] as? String ?? ""
            if !content.isEmpty && role != "system" {
                lines.append("\(role): \(String(content.prefix(500)))")
            }
        }

        let transcript = lines.joined(separator: "\n")
        guard !transcript.isEmpty else { return nil }

        do {
            let resp = try await client.chat(
                model: "qwen3.5:0.8b",
                messages: [
                    ["role": "system", "content": "Summarize this conversation concisely. Keep key facts, decisions, and context. 2-4 sentences max. No thinking tags."],
                    ["role": "user", "content": transcript],
                ],
                tools: nil,
                temperature: 0.1,
                numCtx: 2048,
                timeout: 30
            )
            return ThinkingStripper.strip(resp.content)
        } catch {
            Log.agents.warning("[\(self.name)] summarization failed: \(error)")
            return nil
        }
    }
}
