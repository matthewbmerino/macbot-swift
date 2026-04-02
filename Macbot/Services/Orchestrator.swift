import Foundation

@Observable
final class Orchestrator {
    let client: OllamaClient
    let router: Router
    let memoryStore: MemoryStore
    var modelConfig: ModelConfig
    var soulPrompt: String

    private var conversations: [String: ConversationState] = [:]
    private var userLocks: [String: NSLock] = [:]

    // Conversation eviction
    private let maxConversations = 20
    private let conversationTTL: TimeInterval = 3600 * 4

    // Router affinity
    private static let affinityMinMessages = 2
    private static let affinityTimeout: TimeInterval = 120
    private static let affinityResetGap: TimeInterval = 300

    // Fast routing patterns
    private static let codePattern = try! NSRegularExpression(
        pattern: "```|def\\s+\\w|function\\s+\\w|class\\s+\\w|import\\s+\\w|const\\s+\\w|npm\\s|pip\\s|git\\s",
        options: .caseInsensitive
    )
    private static let mathPattern = try! NSRegularExpression(
        pattern: "\\bcalculate\\b|\\bsolve\\b|\\bprove\\b|\\bderivative\\b|\\bintegral\\b|\\d+\\s*[+\\-*/^]\\s*\\d+",
        options: .caseInsensitive
    )
    private static let complexPattern = try! NSRegularExpression(
        pattern: "\\band\\b.*\\band\\b|\\bthen\\b|\\bstep.by.step\\b|\\bresearch\\b.*\\b(write|create|build|compare|summarize)\\b|\\bfind\\b.*\\b(and|then)\\b.*\\b(compare|summarize|write|create)\\b|\\banalyze\\b.*\\band\\b|\\bplan\\b",
        options: .caseInsensitive
    )

    class ConversationState {
        var agents: [AgentCategory: BaseAgent]
        var currentAgent: AgentCategory
        var lastActive: Date
        var consecutiveSameAgent: Int
        var lastMessageTime: Date

        init(agents: [AgentCategory: BaseAgent]) {
            self.agents = agents
            self.currentAgent = .general
            self.lastActive = Date()
            self.consecutiveSameAgent = 0
            self.lastMessageTime = .distantPast
        }
    }

    init(
        host: String = "http://localhost:11434",
        modelConfig: ModelConfig = ModelConfig(),
        soulPrompt: String? = nil
    ) {
        self.client = OllamaClient(host: host)
        self.router = Router(client: client, model: modelConfig.router)
        self.memoryStore = MemoryStore()
        self.modelConfig = modelConfig
        self.soulPrompt = soulPrompt ?? Self.defaultSoul
    }

    // MARK: - Public API

    func handleMessage(userId: String, message: String, images: [Data]? = nil) async throws -> String {
        let conv = getConversation(userId: userId)
        conv.lastActive = Date()

        if message.hasPrefix("/") {
            return try await handleCommand(conv: conv, message: message)
        }

        let hasImages = images != nil && !(images?.isEmpty ?? true)
        let category = await routeMessage(conv: conv, message: message, hasImages: hasImages)

        guard let agent = conv.agents[category] ?? conv.agents[.general] else {
            return "No agent available."
        }
        conv.currentAgent = category

        let plan = needsPlanning(message)
        Log.agents.info("[orchestrator] user=\(userId) -> \(agent.name)\(plan ? " [PLANNING]" : "")")

        return try await agent.run(message, images: images, plan: plan)
    }

    func handleMessageStream(
        userId: String, message: String, images: [Data]? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let conv = getConversation(userId: userId)
                    conv.lastActive = Date()

                    if message.hasPrefix("/") {
                        let result = try await handleCommand(conv: conv, message: message)
                        continuation.yield(.text(result))
                        continuation.finish()
                        return
                    }

                    let hasImages = images != nil && !(images?.isEmpty ?? true)
                    let category = await routeMessage(conv: conv, message: message, hasImages: hasImages)

                    guard let agent = conv.agents[category] ?? conv.agents[.general] else {
                        continuation.yield(.text("No agent available."))
                        continuation.finish()
                        return
                    }
                    conv.currentAgent = category
                    continuation.yield(.agentSelected(category))

                    let plan = needsPlanning(message)
                    Log.agents.info("[orchestrator] user=\(userId) -> \(agent.name)\(plan ? " [PLANNING]" : "")")

                    for try await event in agent.runStream(message, images: images, plan: plan) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func prewarm() async {
        do {
            async let w1: () = client.warmModel(modelConfig.router)
            async let w2: () = client.warmModel(modelConfig.general)
            _ = try? await (w1, w2)
        }
    }

    // MARK: - Routing

    private func routeMessage(conv: ConversationState, message: String, hasImages: Bool) async -> AgentCategory {
        if let skip = shouldSkipRouter(conv: conv, message: message, hasImages: hasImages) {
            Log.agents.info("[orchestrator] affinity skip -> \(skip.rawValue)")
            updateAffinity(conv: conv, category: skip)
            return skip
        }

        let category = await router.classify(message: message, hasImages: hasImages)
        updateAffinity(conv: conv, category: category)
        return category
    }

    private func shouldSkipRouter(conv: ConversationState, message: String, hasImages: Bool) -> AgentCategory? {
        if hasImages { return .vision }

        let gap = Date().timeIntervalSince(conv.lastMessageTime)
        if gap > Self.affinityResetGap { return nil }

        let range = NSRange(message.startIndex..., in: message)

        if Self.codePattern.firstMatch(in: message, range: range) != nil { return .coder }
        if Self.mathPattern.firstMatch(in: message, range: range) != nil { return .reasoner }

        if conv.consecutiveSameAgent >= Self.affinityMinMessages
            && gap < Self.affinityTimeout
            && conv.currentAgent != .general {
            return conv.currentAgent
        }

        return nil
    }

    private func updateAffinity(conv: ConversationState, category: AgentCategory) {
        if category == conv.currentAgent {
            conv.consecutiveSameAgent += 1
        } else {
            conv.consecutiveSameAgent = 1
        }
        conv.lastMessageTime = Date()
    }

    private func needsPlanning(_ message: String) -> Bool {
        let words = message.split(whereSeparator: \.isWhitespace).count
        guard words >= 6 else { return false }
        let range = NSRange(message.startIndex..., in: message)
        return Self.complexPattern.firstMatch(in: message, range: range) != nil
    }

    // MARK: - Conversations

    private func getConversation(userId: String) -> ConversationState {
        evictStaleConversations()

        if let existing = conversations[userId] { return existing }

        let conv = ConversationState(agents: [
            .general: GeneralAgent(client: client, model: modelConfig.general),
            .coder: CoderAgent(client: client, model: modelConfig.coder),
            .vision: VisionAgent(client: client, model: modelConfig.vision),
            .reasoner: ReasonerAgent(client: client, model: modelConfig.reasoner),
        ])

        // Build system prompts with soul + memory
        for (_, agent) in conv.agents {
            agent.systemPrompt = buildSystemPrompt(agent: agent, userId: userId)
            agent.userId = userId
            agent.memoryStore = memoryStore
        }

        // Register tools on general + coder (full tool set)
        for category in [AgentCategory.general, .coder] {
            if let agent = conv.agents[category] {
                registerMemoryTools(on: agent)
                Task {
                    await FileTools.register(on: agent.toolRegistry)
                    await WebTools.register(on: agent.toolRegistry)
                    await MacOSTools.register(on: agent.toolRegistry)
                    await ExecutorTools.register(on: agent.toolRegistry)
                }
            }
        }

        // Vision + reasoner get lighter tools
        for category in [AgentCategory.vision, .reasoner] {
            if let agent = conv.agents[category] {
                Task {
                    await WebTools.register(on: agent.toolRegistry)
                    await ExecutorTools.register(on: agent.toolRegistry)
                }
            }
        }

        conversations[userId] = conv
        return conv
    }

    private func evictStaleConversations() {
        let now = Date()
        let stale = conversations.filter { now.timeIntervalSince($0.value.lastActive) > conversationTTL }
        for key in stale.keys {
            conversations.removeValue(forKey: key)
            Log.agents.info("[orchestrator] evicted stale conversation for user=\(key)")
        }

        if conversations.count > maxConversations {
            let sorted = conversations.sorted { $0.value.lastActive < $1.value.lastActive }
            for (key, _) in sorted.prefix(conversations.count - maxConversations) {
                conversations.removeValue(forKey: key)
            }
        }
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(agent: BaseAgent, userId: String) -> String {
        var parts = [soulPrompt, agent.systemPrompt]

        let memoryContext = memoryStore.formatForPrompt()
        if !memoryContext.isEmpty { parts.append(memoryContext) }

        let recentConvos = memoryStore.getRecentConversations(userId: userId, limit: 3)
        if !recentConvos.isEmpty {
            let formatted = recentConvos.map { "- \($0.summary)" }.joined(separator: "\n")
            parts.append("[Recent Conversation History]\n\(formatted)")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Memory Tools

    private func registerMemoryTools(on agent: BaseAgent) {
        agent.registerTool(
            ToolSpec(
                name: "memory_save",
                description: "Save something to persistent memory for later recall.",
                properties: [
                    "category": .init(type: "string", description: "Category: preference, project, fact, note"),
                    "content": .init(type: "string", description: "What to remember"),
                ],
                required: ["category", "content"]
            )
        ) { [weak self] args in
            let category = args["category"] as? String ?? "note"
            let content = args["content"] as? String ?? ""
            let id = self?.memoryStore.save(category: category, content: content) ?? 0
            return "Saved to memory (id=\(id)): [\(category)] \(content)"
        }

        agent.registerTool(
            ToolSpec(
                name: "memory_recall",
                description: "Recall memories from persistent storage.",
                properties: [
                    "category": .init(type: "string", description: "Optional category filter"),
                ]
            )
        ) { [weak self] args in
            let category = args["category"] as? String
            let memories = self?.memoryStore.recall(category: category) ?? []
            if memories.isEmpty { return "No memories found." }
            return memories.map { "[id=\($0.id ?? 0)] [\($0.category)] \($0.content)" }.joined(separator: "\n")
        }

        agent.registerTool(
            ToolSpec(
                name: "memory_search",
                description: "Search persistent memory for a keyword.",
                properties: [
                    "query": .init(type: "string", description: "Search term"),
                ],
                required: ["query"]
            )
        ) { [weak self] args in
            let query = args["query"] as? String ?? ""
            let memories = self?.memoryStore.search(query: query) ?? []
            if memories.isEmpty { return "No memories matching '\(query)'." }
            return memories.map { "[id=\($0.id ?? 0)] [\($0.category)] \($0.content)" }.joined(separator: "\n")
        }
    }

    // MARK: - Commands

    private func handleCommand(conv: ConversationState, message: String) async throws -> String {
        let parts = message.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let cmd = String(parts[0]).lowercased()
        let rest = parts.count > 1 ? String(parts[1]) : ""

        switch cmd {
        case "/clear":
            for (_, agent) in conv.agents { agent.clearHistory() }
            return "Conversation cleared."

        case "/status":
            let models = try await client.listModels()
            let names = models.map(\.name).joined(separator: ", ")
            let memCount = memoryStore.recall(limit: 1000).count
            return "Models: \(names)\nAgent: \(conv.currentAgent.displayName)\nMemories: \(memCount)\nConversations: \(conversations.count)"

        case "/code", "/coder":
            conv.currentAgent = .coder
            guard !rest.isEmpty, let agent = conv.agents[.coder] else { return "Switched to coder." }
            return try await agent.run(rest)

        case "/think", "/reason":
            conv.currentAgent = .reasoner
            guard !rest.isEmpty, let agent = conv.agents[.reasoner] else { return "Switched to reasoner." }
            return try await agent.run(rest)

        case "/see", "/vision":
            conv.currentAgent = .vision
            guard !rest.isEmpty, let agent = conv.agents[.vision] else { return "Switched to vision." }
            return try await agent.run(rest)

        case "/chat":
            conv.currentAgent = .general
            guard !rest.isEmpty, let agent = conv.agents[.general] else { return "Switched to general." }
            return try await agent.run(rest)

        case "/plan":
            guard !rest.isEmpty else { return "Usage: /plan <task description>" }
            let agent = conv.agents[conv.currentAgent] ?? conv.agents[.general]!
            return try await agent.run(rest, plan: true)

        case "/remember":
            guard !rest.isEmpty else { return "Usage: /remember <text>" }
            let id = memoryStore.save(category: "note", content: rest)
            return "Remembered (id=\(id)): \(rest)"

        case "/memories":
            let memories = memoryStore.recall(category: rest.isEmpty ? nil : rest)
            if memories.isEmpty { return "No memories found." }
            return memories.map { "[id=\($0.id ?? 0)] [\($0.category)] \($0.content)" }.joined(separator: "\n")

        case "/help":
            return """
            Commands:
              /code <msg> — force coding agent
              /think <msg> — force reasoning agent
              /see <msg> — force vision agent
              /chat <msg> — force general agent
              /plan <task> — force planning mode
              /remember <text> — save to memory
              /memories [category] — list memories
              /clear — reset conversation
              /status — system info
            """

        default:
            return "Unknown command: \(cmd). Type /help for commands."
        }
    }

    // MARK: - Default Soul

    private static let defaultSoul = """
    You are a private local AI agent running entirely on this Mac.
    Everything you do stays on this machine. You never send data to external AI services.

    Communication style:
    - Write like a sharp, competent colleague. Professional but human.
    - Never use markdown formatting. Write in plain sentences and paragraphs.
    - Keep responses concise. One to three short paragraphs for most answers.
    - No filler phrases, no emojis, no exclamation marks.
    - Sound like a trusted advisor, not a chatbot.

    Boundaries:
    - Never execute destructive commands without explicit confirmation.
    - Never access or transmit credentials or secrets.
    - If a task seems beyond your capabilities, say so honestly.
    """
}
