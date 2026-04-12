import Foundation

// MARK: - Learned-Routing Merge & Route Decision Logic

extension Orchestrator {

    func routeMessage(conv: ConversationState, message: String, hasImages: Bool) async -> AgentCategory {
        if let skip = shouldSkipRouter(conv: conv, message: message, hasImages: hasImages) {
            Log.agents.info("[orchestrator] affinity skip -> \(skip.rawValue)")
            updateAffinity(conv: conv, category: skip)
            return skip
        }

        // Embedding router is the single source of truth for routing.
        //
        // Previously this called the LLM router (qwen3.5:0.8b, ~500-800ms)
        // as a "rescue" whenever the embedding router returned `general`.
        // That paid the LLM cost on every general turn (the majority of
        // turns) to catch maybe 5% of misroutes — terrible ROI on the hot
        // path. Users with stronger routing intent have explicit overrides
        // via /code, /think, /see, /chat, /knowledge.
        ActivityLog.shared.log(.routing, "Classifying message...")
        let category = await embeddingRouter.classify(message: message, hasImages: hasImages)

        updateAffinity(conv: conv, category: category)
        return category
    }

    func shouldSkipRouter(conv: ConversationState, message: String, hasImages: Bool) -> AgentCategory? {
        if hasImages { return .vision }

        let range = NSRange(message.startIndex..., in: message)

        // Deterministic pattern matching — always fires, no affinity required
        if Self.codePattern.firstMatch(in: message, range: range) != nil { return .coder }
        if Self.mathPattern.firstMatch(in: message, range: range) != nil { return .reasoner }

        // Affinity: stick with current agent for follow-up messages
        let gap = Date().timeIntervalSince(conv.lastMessageTime)
        if gap < Self.affinityResetGap
            && conv.consecutiveSameAgent >= Self.affinityMinMessages
            && gap < Self.affinityTimeout
            && conv.currentAgent != .general {
            return conv.currentAgent
        }

        return nil
    }

    func updateAffinity(conv: ConversationState, category: AgentCategory) {
        if category == conv.currentAgent {
            conv.consecutiveSameAgent += 1
        } else {
            conv.consecutiveSameAgent = 1
        }
        conv.lastMessageTime = Date()
    }

    func needsPlanning(_ message: String) -> Bool {
        let words = message.split(whereSeparator: \.isWhitespace).count
        guard words >= 6 else { return false }
        let range = NSRange(message.startIndex..., in: message)
        return Self.complexPattern.firstMatch(in: message, range: range) != nil
    }

    /// Check if a message would benefit from parallel agent execution.
    func shouldRunParallel(_ message: String) -> [AgentCategory]? {
        guard parallelAgentsEnabled || mixtureOfAgentsEnabled else { return nil }
        let range = NSRange(message.startIndex..., in: message)
        guard Self.parallelPattern.firstMatch(in: message, range: range) != nil else { return nil }
        return [.general, .coder, .reasoner]
    }
}
