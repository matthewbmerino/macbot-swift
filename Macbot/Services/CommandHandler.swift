import Foundation

/// Handles all slash commands, extracted from Orchestrator to reduce its size.
enum CommandHandler {

    static func handle(
        command: String,
        conv: Orchestrator.ConversationState,
        orchestrator: Orchestrator
    ) async throws -> String {
        let parts = command.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        // Defensive guard: empty / whitespace-only input yields an empty
        // parts array. Currently unreachable because Orchestrator.handleMessage
        // gates dispatch on hasPrefix("/"), but any future caller that hands
        // an empty string to handle() would crash on parts[0].
        guard let first = parts.first else { return "Empty command." }
        let cmd = String(first).lowercased()
        let rest = parts.count > 1 ? String(parts[1]) : ""

        switch cmd {
        case "/skills":
            let n = Int(rest.trimmingCharacters(in: .whitespaces)) ?? 20
            let skills = SkillStore.shared.recentSkills(limit: n)
            let total = SkillStore.shared.count()
            if skills.isEmpty { return "No skills learned yet. Have a few real conversations and try again." }
            let lines = skills.enumerated().map { (i, s) -> String in
                "\(i + 1). [\(s.useCount)x] \(s.promptLine)"
            }
            return "Learned skills (\(skills.count) of \(total) total):\n\n\(lines.joined(separator: "\n"))"

        case "/eval":
            // Run the held-out eval set against the live orchestrator.
            // Use sparingly — touches every model, takes a minute or two.
            let report = await EvalHarness.run(orchestrator: orchestrator)
            return report.summary

        case "/traces":
            let n = Int(rest.trimmingCharacters(in: .whitespaces)) ?? 10
            let traces = TraceStore.shared.recent(limit: n)
            if traces.isEmpty { return "No traces recorded yet." }
            let total = TraceStore.shared.count()
            let lines = traces.map { t -> String in
                let dur = "\(t.latencyMs)ms"
                let tools = t.toolCallList.map { $0["name"] as? String ?? "?" }.joined(separator: ",")
                let toolStr = tools.isEmpty ? "" : " [\(tools)]"
                let preview = t.userMessage.prefix(60)
                return "#\(t.id ?? 0) \(t.routedAgent) \(dur) \(t.modelUsed)\(toolStr)\n  > \(preview)"
            }
            return "Traces (\(traces.count) of \(total) total):\n\n\(lines.joined(separator: "\n"))"

        case "/inspect":
            guard let id = Int64(rest.trimmingCharacters(in: .whitespaces)) else {
                return "Usage: /inspect <trace_id>"
            }
            let recent = TraceStore.shared.recent(limit: 500)
            guard let t = recent.first(where: { $0.id == id }) else {
                return "Trace #\(id) not found in recent 500."
            }
            var out: [String] = []
            out.append("Trace #\(id)")
            out.append("Session: \(t.sessionId)  turn: \(t.turnIndex)")
            out.append("Agent: \(t.routedAgent) (\(t.routeReason))")
            out.append("Model: \(t.modelUsed)")
            out.append("Latency: \(t.latencyMs)ms  tokens: \(t.responseTokens)")
            if let err = t.error, !err.isEmpty { out.append("Error: \(err)") }
            out.append("")
            out.append("USER:")
            out.append(t.userMessage)
            out.append("")
            for (i, call) in t.toolCallList.enumerated() {
                let name = call["name"] as? String ?? "?"
                let result = (call["result"] as? String ?? "").prefix(200)
                out.append("TOOL \(i + 1) [\(name)]: \(result)")
            }
            out.append("")
            out.append("ASSISTANT:")
            out.append(t.assistantResponse)
            return out.joined(separator: "\n")

        case "/upgrade", "/big":
            // Re-run the most recent user message through the reasoner (largest model)
            // for a more thorough answer.
            guard let reasoner = conv.agents[.reasoner] else {
                return "Reasoner agent unavailable."
            }
            // Find the last user message in the canonical transcript
            var lastUser: String?
            for msg in conv.transcript.reversed() {
                if let role = msg["role"] as? String, role == "user",
                   let content = msg["content"] as? String, !content.isEmpty {
                    lastUser = content
                    break
                }
            }
            guard let prompt = lastUser else { return "No prior user message to upgrade." }
            conv.currentAgent = .reasoner
            return try await runOnAgent(reasoner, conv: conv, orchestrator: orchestrator, input: prompt)

        case "/clear":
            // Auto-record episode from the most active agent before clearing
            await recordEpisodeFromConversation(conv: conv, orchestrator: orchestrator)
            for (_, agent) in conv.agents { agent.clearHistory() }
            conv.transcript.removeAll()  // canonical history reset too
            conv.sessionStartedAt = Date()
            return "Conversation cleared."

        case "/status":
            return try await status(conv: conv, orchestrator: orchestrator)

        case "/perf":
            return perf(conv: conv, orchestrator: orchestrator)

        case "/code", "/coder":
            conv.currentAgent = .coder
            guard !rest.isEmpty, let agent = conv.agents[.coder] else { return "Switched to coder." }
            return try await runOnAgent(agent, conv: conv, orchestrator: orchestrator, input: rest)

        case "/think", "/reason":
            conv.currentAgent = .reasoner
            guard !rest.isEmpty, let agent = conv.agents[.reasoner] else { return "Switched to reasoner." }
            return try await runOnAgent(agent, conv: conv, orchestrator: orchestrator, input: rest)

        case "/see", "/vision":
            conv.currentAgent = .vision
            guard !rest.isEmpty, let agent = conv.agents[.vision] else { return "Switched to vision." }
            return try await runOnAgent(agent, conv: conv, orchestrator: orchestrator, input: rest)

        case "/chat":
            conv.currentAgent = .general
            guard !rest.isEmpty, let agent = conv.agents[.general] else { return "Switched to general." }
            return try await runOnAgent(agent, conv: conv, orchestrator: orchestrator, input: rest)

        case "/knowledge", "/rag":
            conv.currentAgent = .rag
            guard !rest.isEmpty, let agent = conv.agents[.rag] else { return "Switched to knowledge agent." }
            return try await runOnAgent(agent, conv: conv, orchestrator: orchestrator, input: rest)

        case "/plan":
            guard !rest.isEmpty else { return "Usage: /plan <task description>" }
            let agent = conv.agents[conv.currentAgent] ?? conv.agents[.general]!
            return try await runOnAgent(agent, conv: conv, orchestrator: orchestrator, input: rest, plan: true)

        case "/remember":
            guard !rest.isEmpty else { return "Usage: /remember <text>" }
            let id = orchestrator.memoryStore.save(category: "note", content: rest)
            return "Remembered (id=\(id)): \(rest)"

        case "/memories":
            let memories = orchestrator.memoryStore.recall(category: rest.isEmpty ? nil : rest)
            if memories.isEmpty { return "No memories found." }
            return memories.map { "[id=\($0.id ?? 0)] [\($0.category)] \($0.content)" }.joined(separator: "\n")

        case "/ingest":
            return try await ingest(path: rest, orchestrator: orchestrator)

        case "/backend":
            return "Backend: Ollama (llama.cpp Metal). All inference runs through Ollama for maximum performance."

        case "/parallel":
            orchestrator.parallelAgentsEnabled.toggle()
            return "Parallel agent execution: \(orchestrator.parallelAgentsEnabled ? "enabled" : "disabled")"

        case "/moa":
            orchestrator.mixtureOfAgentsEnabled.toggle()
            return "Mixture of Agents: \(orchestrator.mixtureOfAgentsEnabled ? "enabled" : "disabled")"

        case "/workflows":
            let tools = orchestrator.compositeToolStore.listAll()
            if tools.isEmpty { return "No learned workflows. Use /learn to create one." }
            return tools.map { "• \($0.name) — \($0.description) (\($0.decodedSteps.count) steps, used \($0.timesUsed)x)" }
                .joined(separator: "\n")

        case "/learn":
            return learn(rest: rest, orchestrator: orchestrator)

        case "/director":
            guard !rest.isEmpty else { return "Usage: /director <task description>" }
            // Open the Director window and pass the task.
            // The window is opened via notification; the actual streaming
            // happens inside DirectorViewModel.
            await MainActor.run {
                DirectorLauncher.shared.launch(task: rest)
            }
            return "Opening Director..."

        case "/overlay":
            await MainActor.run { OverlayController.shared.toggle() }
            let visible = await MainActor.run { OverlayController.shared.isVisible }
            return visible
                ? "Overlay activated. Draw a region or type a question. Press Esc to dismiss."
                : "Overlay dismissed."

        case "/companion":
            let state = await MainActor.run {
                CompanionController.shared.toggle()
                return CompanionController.shared.isVisible ? "on" : "off"
            }
            return "Desktop companion: \(state)"

        case "/ghost":
            return await ghost(rest: rest)

        case "/help":
            return helpText

        default:
            return "Unknown command: \(cmd). Type /help for commands."
        }
    }

    // MARK: - Helpers

    /// Run an agent with the canonical conversation transcript hydrated and
    /// the new turn captured back. Mirrors what handleMessage does for
    /// route-based turns so command-driven turns (/code, /think, /chat, ...)
    /// also benefit from cross-agent context preservation.
    private static func runOnAgent(
        _ agent: BaseAgent,
        conv: Orchestrator.ConversationState,
        orchestrator: Orchestrator,
        input: String,
        plan: Bool = false
    ) async throws -> String {
        let startCount = orchestrator.prepareAgent(agent, conv: conv)
        let response = try await agent.run(input, plan: plan)
        orchestrator.captureTurn(from: agent, into: conv, since: startCount)
        return response
    }

    // MARK: - Streaming entry point
    //
    // The non-streaming `handle` returns a final String, which means the
    // command-driven path used to wait for the entire response to generate
    // before the user saw anything. The streaming variant below preserves
    // the same behavior for synthetic-string commands (/clear, /status,
    // etc.) but uses agent.runStream for the agent-delegating commands so
    // the first token shows up in <1s instead of after the whole response
    // finishes.

    /// Streaming version of `handle`. Returns an AsyncThrowingStream of
    /// `StreamEvent` events. For synthetic-string commands the entire
    /// result is yielded as a single .text event then the stream finishes.
    /// For agent-delegating commands the agent's runStream events are
    /// forwarded directly so the user sees text/status/image events as
    /// they're produced.
    static func handleStream(
        command: String,
        conv: Orchestrator.ConversationState,
        orchestrator: Orchestrator
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let parts = command.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        // Defensive guard: empty / whitespace-only input yields an empty
        // parts array. Mirrors the guard in handle() above — see comment
        // there for context.
        guard let first = parts.first else { return oneShot("Empty command.") }
        let cmd = String(first).lowercased()
        let rest = parts.count > 1 ? String(parts[1]) : ""

        // The set of commands that delegate to an agent and benefit from
        // streaming. For everything else (synthetic strings, /status,
        // /clear, /memories, etc.) we fall through to the non-streaming
        // path and yield the result in one shot.
        switch cmd {
        case "/code", "/coder":
            conv.currentAgent = .coder
            guard !rest.isEmpty, let agent = conv.agents[.coder] else {
                return oneShot("Switched to coder.")
            }
            return runOnAgentStream(agent, conv: conv, orchestrator: orchestrator, input: rest)

        case "/think", "/reason":
            conv.currentAgent = .reasoner
            guard !rest.isEmpty, let agent = conv.agents[.reasoner] else {
                return oneShot("Switched to reasoner.")
            }
            return runOnAgentStream(agent, conv: conv, orchestrator: orchestrator, input: rest)

        case "/see", "/vision":
            conv.currentAgent = .vision
            guard !rest.isEmpty, let agent = conv.agents[.vision] else {
                return oneShot("Switched to vision.")
            }
            return runOnAgentStream(agent, conv: conv, orchestrator: orchestrator, input: rest)

        case "/chat":
            conv.currentAgent = .general
            guard !rest.isEmpty, let agent = conv.agents[.general] else {
                return oneShot("Switched to general.")
            }
            return runOnAgentStream(agent, conv: conv, orchestrator: orchestrator, input: rest)

        case "/knowledge", "/rag":
            conv.currentAgent = .rag
            guard !rest.isEmpty, let agent = conv.agents[.rag] else {
                return oneShot("Switched to knowledge agent.")
            }
            return runOnAgentStream(agent, conv: conv, orchestrator: orchestrator, input: rest)

        case "/plan":
            guard !rest.isEmpty else { return oneShot("Usage: /plan <task description>") }
            let agent = conv.agents[conv.currentAgent] ?? conv.agents[.general]!
            return runOnAgentStream(agent, conv: conv, orchestrator: orchestrator, input: rest, plan: true)

        case "/upgrade", "/big":
            guard let reasoner = conv.agents[.reasoner] else {
                return oneShot("Reasoner agent unavailable.")
            }
            var lastUser: String?
            for msg in conv.transcript.reversed() {
                if let role = msg["role"] as? String, role == "user",
                   let content = msg["content"] as? String, !content.isEmpty {
                    lastUser = content
                    break
                }
            }
            guard let prompt = lastUser else { return oneShot("No prior user message to upgrade.") }
            conv.currentAgent = .reasoner
            return runOnAgentStream(reasoner, conv: conv, orchestrator: orchestrator, input: prompt)

        default:
            // Synthetic-string commands: delegate to non-streaming handle
            // and yield the result in a single chunk. Same UX as before
            // for these because they generate their output instantly.
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let result = try await handle(command: command, conv: conv, orchestrator: orchestrator)
                        continuation.yield(.text(result))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Streaming agent runner. Hydrates the transcript, runs the agent's
    /// streaming loop, captures the new turn back into the transcript on
    /// completion. Forwards every StreamEvent the agent emits.
    private static func runOnAgentStream(
        _ agent: BaseAgent,
        conv: Orchestrator.ConversationState,
        orchestrator: Orchestrator,
        input: String,
        plan: Bool = false
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let startCount = orchestrator.prepareAgent(agent, conv: conv)
                do {
                    for try await event in agent.runStream(input, plan: plan) {
                        continuation.yield(event)
                    }
                    orchestrator.captureTurn(from: agent, into: conv, since: startCount)
                    continuation.finish()
                } catch {
                    orchestrator.captureTurn(from: agent, into: conv, since: startCount)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Build a one-shot stream that yields a single .text event and
    /// finishes. Used for synthetic-string commands and for the "no input
    /// provided" message paths.
    private static func oneShot(_ text: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.finish()
        }
    }

    // MARK: - Subcommands

    private static func status(conv: Orchestrator.ConversationState, orchestrator: Orchestrator) async throws -> String {
        let models = try await orchestrator.client.listModels()
        let names = models.map(\.name).joined(separator: ", ")
        let memCount = orchestrator.memoryStore.recall(limit: 1000).count
        let chunkCount = orchestrator.chunkStore.totalChunkCount()
        let ingestedFiles = orchestrator.chunkStore.ingestedFiles()
        return """
        Models: \(names)
        Agent: \(conv.currentAgent.displayName)
        Backend: Ollama (llama.cpp Metal)
        Memories: \(memCount) (vector-indexed)
        Knowledge base: \(chunkCount) chunks from \(ingestedFiles.count) files
        Parallel agents: \(orchestrator.parallelAgentsEnabled ? "on" : "off")
        Mixture of Agents: \(orchestrator.mixtureOfAgentsEnabled ? "on" : "off")
        """
    }

    private static func perf(conv: Orchestrator.ConversationState, orchestrator: Orchestrator) -> String {
        // RSS via mach_task_basic_info
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let rssMB: String
        if kr == KERN_SUCCESS {
            let mb = Double(info.resident_size) / (1024 * 1024)
            rssMB = String(format: "%.1f MB", mb)
        } else {
            rssMB = "unavailable"
        }

        let traceCount = TraceStore.shared.count()
        let episodeCount = EpisodicMemory.shared.count()
        let skillCount = SkillStore.shared.count()
        let model = orchestrator.modelConfig.general

        return """
        Performance:
          RSS memory: \(rssMB)
          Traces: \(traceCount)
          Episodes: \(episodeCount)
          Skills: \(skillCount)
          Model: \(model)
        """
    }

    private static func ingest(path: String, orchestrator: Orchestrator) async throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Usage: /ingest <file or directory path>" }

        let ingester = DocumentIngester(
            client: orchestrator.activeClient,
            embeddingModel: orchestrator.modelConfig.embedding,
            chunkStore: orchestrator.chunkStore
        )

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir) else {
            return "Path not found: \(trimmed)"
        }

        if isDir.boolValue {
            let result = try await ingester.ingestDirectory(at: trimmed)
            return "Ingested \(result.files) files (\(result.chunks) chunks) into knowledge base."
        } else {
            let chunks = try await ingester.ingestFile(at: trimmed)
            return "Ingested \(URL(fileURLWithPath: trimmed).lastPathComponent): \(chunks) chunks."
        }
    }

    private static func learn(rest: String, orchestrator: Orchestrator) -> String {
        guard !rest.isEmpty else {
            return """
            Usage: /learn <name> | <description> | <trigger phrase>
            Example: /learn deploy_app | Deploy the app to production | deploy the app
            """
        }
        let parts = rest.components(separatedBy: " | ")
        guard parts.count >= 3 else {
            return "Format: /learn <name> | <description> | <trigger phrase>"
        }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let desc = parts[1].trimmingCharacters(in: .whitespaces)
        let trigger = parts[2].trimmingCharacters(in: .whitespaces)

        let id = orchestrator.compositeToolStore.save(name: name, description: desc, steps: [], triggerPhrase: trigger)
        return "Created workflow '\(name)' (id=\(id)). Trigger: \"\(trigger)\""
    }

    // MARK: - Ghost Cursor

    private static func ghost(rest: String) async -> String {
        guard !rest.isEmpty else {
            return "Usage: /ghost <task>\nExample: /ghost open Safari and search for Swift tutorials"
        }

        let hasPermission = AccessibilityBridge.checkAccessibilityPermission()
        guard hasPermission else {
            AccessibilityBridge.requestAccessibilityPermission()
            return """
            Accessibility permission is required for Ghost Cursor.

            I've opened System Settings for you. Please:
            1. Go to Privacy & Security > Accessibility
            2. Enable Macbot in the list
            3. Try /ghost again after granting permission
            """
        }

        // Parse the task into steps. For MVP we use a simple heuristic parser.
        // A future version will send the task to the orchestrator for planning.
        let steps = GhostStepParser.parse(task: rest)

        guard !steps.isEmpty else {
            return "Could not break that task into UI actions. Try being more specific, e.g.:\n  /ghost open TextEdit and type Hello World"
        }

        // Show what will happen before doing it
        let preview = steps.enumerated().map { (i, s) in
            "  \(i + 1). \(s.description)"
        }.joined(separator: "\n")

        await MainActor.run {
            GhostCursorController.shared.start(steps: steps)
        }

        return "Ghost Cursor started (\(steps.count) steps):\n\(preview)\n\nPress Esc in the narration panel to cancel."
    }

    /// Pulls history from the most-active agent and asks the router model
    /// to summarize it into an Episode. Fire-and-forget — never blocks /clear.
    private static func recordEpisodeFromConversation(
        conv: Orchestrator.ConversationState,
        orchestrator: Orchestrator
    ) async {
        // Pick the agent with the longest history (most active)
        var bestAgent: BaseAgent?
        var bestCount = 0
        for (_, agent) in conv.agents where agent.history.count > bestCount {
            bestAgent = agent
            bestCount = agent.history.count
        }
        guard let agent = bestAgent, bestCount > 2 else { return }

        let messages = agent.history
        let started = conv.sessionStartedAt
        let ended = Date()
        let client = orchestrator.client
        let model = orchestrator.modelConfig.router  // tiny model for cheap summary

        Task.detached {
            await EpisodicMemory.shared.recordEpisode(
                messages: messages,
                startedAt: started,
                endedAt: ended,
                client: client,
                model: model
            )
        }
    }

    private static let helpText = """
    Commands:
      /code <msg> — force coding agent
      /think <msg> — force reasoning agent
      /see <msg> — force vision agent
      /chat <msg> — force general agent
      /knowledge <msg> — force knowledge/RAG agent
      /plan <task> — force planning mode
      /ingest <path> — ingest file/directory into knowledge base
      /remember <text> — save to memory
      /memories [category] — list memories
      /learn <name> | <desc> | <trigger> — create a reusable workflow
      /workflows — list learned workflows
      /backend — show inference backend info
      /parallel — toggle parallel agent execution
      /moa — toggle Mixture of Agents
      /director <task> — open Director window to watch macbot work step-by-step
      /overlay — toggle transparent screen overlay (Cmd+Shift+O)
      /companion — toggle desktop companion character
      /ghost <task> — ghost cursor takes over and performs UI actions
      /clear — reset conversation
      /status — system info
      /perf — performance stats (memory, traces, episodes, skills)
    """
}
