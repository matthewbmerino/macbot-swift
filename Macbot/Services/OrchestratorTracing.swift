import Foundation

// MARK: - Trace Building & Tool-Call Extraction

extension Orchestrator {

    /// Fire-and-forget skill distillation. Runs on a detached task with the
    /// router model so it never blocks the chat path.
    func scheduleSkillDistillation(trace: TraceBuilder) {
        // Snapshot the trace data we need — the builder is mutable
        let snapshotTrace = InteractionTrace(
            id: nil,
            sessionId: trace.sessionId,
            userId: trace.userId,
            turnIndex: trace.turnIndex,
            userMessage: trace.userMessage,
            userMessageEmbedding: nil,
            routedAgent: trace.routedAgent,
            routeReason: trace.routeReason,
            modelUsed: trace.modelUsed,
            toolCalls: (try? JSONSerialization.data(withJSONObject: trace.toolCalls))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
            assistantResponse: trace.assistantResponse,
            responseTokens: trace.responseTokens,
            latencyMs: 0,
            error: trace.error,
            ambientSnapshot: "{}",
            metadata: "{}",
            createdAt: Date()
        )
        let client = self.client
        let routerModel = self.modelConfig.router
        let embModel = self.modelConfig.embedding
        Task.detached {
            await SkillStore.shared.distill(
                from: snapshotTrace,
                client: client,
                model: routerModel,
                embeddingModel: embModel
            )
        }
    }

    /// Stable session identifier for trace correlation. Reset on /clear via
    /// ConversationState.sessionStartedAt.
    func sessionId(for conv: ConversationState, userId: String) -> String {
        let ts = Int(conv.sessionStartedAt.timeIntervalSince1970)
        return "\(userId)-\(ts)"
    }

    /// Walk the agent's history added during this turn and pull out tool calls
    /// + their results into the trace builder.
    func extractToolCalls(from agent: BaseAgent, since startCount: Int, into trace: TraceBuilder) {
        guard agent.history.count > startCount else { return }
        let new = agent.history[startCount...]
        var pendingByName: [String: [String: Any]] = [:]
        var startTime = Date()
        for msg in new {
            guard let role = msg["role"] as? String else { continue }
            if role == "assistant", let calls = msg["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String
                    else { continue }
                    let args = function["arguments"] as? [String: Any] ?? [:]
                    pendingByName[name] = args
                    startTime = Date()
                }
            } else if role == "tool" {
                let name = msg["name"] as? String ?? ""
                let result = msg["content"] as? String ?? ""
                let args = pendingByName.removeValue(forKey: name) ?? [:]
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                trace.recordToolCall(name: name, args: args, result: result, latencyMs: elapsed)
            }
        }
    }

    /// Returns the resolved model name for an agent category.
    func modelName(for category: AgentCategory) -> String {
        switch category {
        case .general: return modelConfig.general
        case .coder:   return modelConfig.coder
        case .vision:  return modelConfig.vision
        case .reasoner: return modelConfig.reasoner
        case .rag:     return modelConfig.general
        }
    }
}
