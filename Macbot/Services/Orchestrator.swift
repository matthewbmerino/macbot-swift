import Foundation

@Observable
final class Orchestrator {
    let client: OllamaClient
    // MLX client retained for future use — not in the inference path
    let router: Router
    let embeddingRouter: EmbeddingRouter
    let memoryStore: MemoryStore
    let chunkStore: ChunkStore
    let compositeToolStore: CompositeToolStore
    var modelConfig: ModelConfig
    var soulPrompt: String

    /// Ollama handles all inference. Its llama.cpp Metal backend is faster
    /// than our MLX implementation and battle-tested. MLX code remains for
    /// future development but is not in the generation path.
    var activeClient: any InferenceProvider { client }

    private var conversations: [String: ConversationState] = [:]
    private var userLocks: [String: NSLock] = [:]

    // Conversation eviction
    private let maxConversations = 20
    private let conversationTTL: TimeInterval = 3600 * 4

    // Router affinity
    private static let affinityMinMessages = 2
    private static let affinityTimeout: TimeInterval = 120
    private static let affinityResetGap: TimeInterval = 300

    // Parallel agent execution / Mixture of Agents
    var parallelAgentsEnabled: Bool = false
    var mixtureOfAgentsEnabled: Bool = false

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
    // Pattern for queries that benefit from multiple perspectives
    private static let parallelPattern = try! NSRegularExpression(
        pattern: "\\bcompare\\b|\\bversus\\b|\\bvs\\b|\\bpros and cons\\b|\\bdifference between\\b|\\btradeoffs?\\b|\\bwhich is better\\b",
        options: .caseInsensitive
    )

    class ConversationState {
        var agents: [AgentCategory: BaseAgent]
        var currentAgent: AgentCategory
        var lastActive: Date
        var consecutiveSameAgent: Int
        var lastMessageTime: Date
        var messageCount: Int = 0

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
        // MLX client available but not in hot path — all inference via Ollama
        self.router = Router(client: client, model: modelConfig.router)
        self.embeddingRouter = EmbeddingRouter(client: client, embeddingModel: modelConfig.embedding)
        self.memoryStore = MemoryStore()
        self.chunkStore = ChunkStore()
        self.compositeToolStore = CompositeToolStore()
        self.modelConfig = modelConfig
        self.soulPrompt = soulPrompt ?? Self.defaultSoul

        // Connect embedding client to memory store for semantic search
        memoryStore.embeddingClient = client
        memoryStore.embeddingModel = modelConfig.embedding
    }

    /// Validate that all configured models are installed in Ollama.
    /// Falls back to known-good defaults for any missing model.
    func validateModels() async {
        let fallbacks: [String: String] = [
            "general": "qwen3.5:9b",
            "coder": "qwen3.5:9b",
            "vision": "qwen3-vl:8b",
            "reasoner": "qwen3.5:9b",
            "router": "qwen3.5:0.8b",
            "embedding": "qwen3-embedding:0.6b",
        ]

        guard let models = try? await client.listModels() else { return }
        let installed = Set(models.map(\.name))

        let check = { (model: String) -> Bool in
            installed.contains(model) || installed.contains(model + ":latest")
        }

        if !check(self.modelConfig.general) {
            Log.app.warning("[orchestrator] \(self.modelConfig.general) not found, falling back")
            self.modelConfig.general = fallbacks["general"]!
        }
        if !check(self.modelConfig.coder) {
            Log.app.warning("[orchestrator] \(self.modelConfig.coder) not found, falling back")
            self.modelConfig.coder = fallbacks["coder"]!
        }
        if !check(self.modelConfig.vision) {
            Log.app.warning("[orchestrator] \(self.modelConfig.vision) not found, falling back")
            self.modelConfig.vision = fallbacks["vision"]!
        }
        if !check(self.modelConfig.reasoner) {
            Log.app.warning("[orchestrator] \(self.modelConfig.reasoner) not found, falling back")
            self.modelConfig.reasoner = fallbacks["reasoner"]!
        }

        // Persist the validated config so stale model names don't survive restarts
        modelConfig.save()

        Log.app.info("[orchestrator] models validated: general=\(self.modelConfig.general), coder=\(self.modelConfig.coder), vision=\(self.modelConfig.vision), reasoner=\(self.modelConfig.reasoner)")
    }

    // MARK: - Public API

    func handleMessage(userId: String, message: String, images: [Data]? = nil) async throws -> String {
        let conv = await getConversation(userId: userId)
        conv.lastActive = Date()

        if message.hasPrefix("/") {
            return try await handleCommand(conv: conv, message: message)
        }

        let hasImages = images != nil && !(images?.isEmpty ?? true)

        // Check for parallel/MoA execution
        if let parallelCategories = shouldRunParallel(message), !hasImages {
            if mixtureOfAgentsEnabled {
                Log.agents.info("[orchestrator] user=\(userId) -> MoA with \(parallelCategories.map(\.rawValue))")
                return try await mixtureOfAgents(conv: conv, message: message, categories: parallelCategories)
            } else if parallelAgentsEnabled {
                Log.agents.info("[orchestrator] user=\(userId) -> parallel with \(parallelCategories.map(\.rawValue))")
                let results = try await runParallelAgents(conv: conv, message: message, categories: parallelCategories)
                return results.map { "[\($0.0.displayName)]\n\($0.1)" }.joined(separator: "\n\n---\n\n")
            }
        }

        let category = await routeMessage(conv: conv, message: message, hasImages: hasImages)

        guard let agent = conv.agents[category] ?? conv.agents[.general] else {
            return "No agent available."
        }
        conv.currentAgent = category

        let plan = needsPlanning(message)
        Log.agents.info("[orchestrator] user=\(userId) -> \(agent.name)\(plan ? " [PLANNING]" : "")")
        ActivityLog.shared.log(.routing, "Routed to \(agent.name) agent\(plan ? " with planning" : "")")

        conv.messageCount += 1
        injectPromptModules(agent: agent, conv: conv, isPlanning: plan, message: message)

        return try await agent.run(message, images: images, plan: plan)
    }

    func handleMessageStream(
        userId: String, message: String, images: [Data]? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let conv = await getConversation(userId: userId)
                    conv.lastActive = Date()

                    if message.hasPrefix("/") {
                        let result = try await handleCommand(conv: conv, message: message)
                        continuation.yield(.text(result))
                        continuation.finish()
                        return
                    }

                    let hasImages = images != nil && !(images?.isEmpty ?? true)

                    // Check for Mixture of Agents
                    if !hasImages, let parallelCategories = shouldRunParallel(message) {
                        if mixtureOfAgentsEnabled {
                            continuation.yield(.status("Running Mixture of Agents..."))
                            let result = try await mixtureOfAgents(
                                conv: conv, message: message, categories: parallelCategories
                            )
                            continuation.yield(.text(result))
                            continuation.finish()
                            return
                        }
                    }

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
                    ActivityLog.shared.log(.routing, "Routed to \(agent.name) agent\(plan ? " with planning" : "")")

                    conv.messageCount += 1
                    injectPromptModules(agent: agent, conv: conv, isPlanning: plan, message: message)

                    for try await event in agent.runStream(message, images: images, plan: plan) {
                        // Log status events to the activity feed
                        if case .status(let status) = event {
                            ActivityLog.shared.log(.inference, status)
                        }
                        continuation.yield(event)
                    }
                    ActivityLog.shared.log(.inference, "Response complete")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func prewarm() async {
        // Warm models and calibrate embedding router in parallel
        async let w1: () = client.warmModel(modelConfig.router)
        async let w2: () = client.warmModel(modelConfig.general)
        async let w3: () = embeddingRouter.calibrate()
        async let w4: () = memoryStore.backfillEmbeddings()
        async let w5: () = chunkStore.loadVectorIndex()

        _ = try? await (w1, w2)
        await w3
        await w4
        await w5

        Log.app.info("[orchestrator] prewarm complete")
    }

    // MARK: - Routing

    private func routeMessage(conv: ConversationState, message: String, hasImages: Bool) async -> AgentCategory {
        if let skip = shouldSkipRouter(conv: conv, message: message, hasImages: hasImages) {
            Log.agents.info("[orchestrator] affinity skip -> \(skip.rawValue)")
            updateAffinity(conv: conv, category: skip)
            return skip
        }

        // Prefer embedding router (faster, more deterministic) with LLM fallback
        ActivityLog.shared.log(.routing, "Classifying message...")
        let category = await embeddingRouter.classify(message: message, hasImages: hasImages)

        // If embedding router has low confidence, cross-check with LLM router
        if category == .general {
            ActivityLog.shared.log(.routing, "Embedding → general, checking LLM router...")
            let llmCategory = await router.classify(message: message, hasImages: hasImages)
            if llmCategory != .general {
                Log.agents.info("[orchestrator] embedding->general, LLM->\(llmCategory.rawValue), using LLM")
                ActivityLog.shared.log(.routing, "LLM router → \(llmCategory.displayName)")
                updateAffinity(conv: conv, category: llmCategory)
                return llmCategory
            }
        }

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

    private func getConversation(userId: String) async -> ConversationState {
        evictStaleConversations()

        if let existing = conversations[userId] { return existing }

        let inference = activeClient

        let ragAgent = RAGAgent(
            client: inference,
            model: modelConfig.general,
            embeddingModel: modelConfig.embedding,
            chunkStore: chunkStore
        )

        let conv = ConversationState(agents: [
            .general: GeneralAgent(client: inference, model: modelConfig.general),
            .coder: CoderAgent(client: inference, model: modelConfig.coder),
            .vision: VisionAgent(client: inference, model: modelConfig.vision),
            .reasoner: ReasonerAgent(client: inference, model: modelConfig.reasoner),
            .rag: ragAgent,
        ])

        // Build system prompts with soul + memory
        for (_, agent) in conv.agents {
            agent.systemPrompt = buildSystemPrompt(agent: agent, userId: userId)
            agent.userId = userId
            agent.memoryStore = memoryStore
        }

        // Register tools on general + coder + rag (full tool set)
        for category in [AgentCategory.general, .coder, .rag] {
            if let agent = conv.agents[category] {
                registerMemoryTools(on: agent)
                registerRAGTools(on: agent)
                await compositeToolStore.registerTools(on: agent.toolRegistry, executor: compositeToolStore)
                await FileTools.register(on: agent.toolRegistry)
                await WebTools.register(on: agent.toolRegistry)
                await MacOSTools.register(on: agent.toolRegistry)
                await ExecutorTools.register(on: agent.toolRegistry)
                await FinanceTools.register(on: agent.toolRegistry)
                await ChartTools.register(on: agent.toolRegistry)
                await SkillTools.register(on: agent.toolRegistry)
            }
        }

        // Vision + reasoner get lighter tools + skills
        for category in [AgentCategory.vision, .reasoner] {
            if let agent = conv.agents[category] {
                await WebTools.register(on: agent.toolRegistry)
                await ExecutorTools.register(on: agent.toolRegistry)
                await SkillTools.register(on: agent.toolRegistry)
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
        // Current date/time so the model always knows "today"
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let timeZone = TimeZone.current.identifier

        let context = "Current date: \(dateFormatter.string(from: now)). Current time: \(timeFormatter.string(from: now)) (\(timeZone))."

        var parts = [soulPrompt, context, agent.systemPrompt]

        let memoryContext = memoryStore.formatForPrompt()
        if !memoryContext.isEmpty { parts.append(memoryContext) }

        let recentConvos = memoryStore.getRecentConversations(userId: userId, limit: 3)
        if !recentConvos.isEmpty {
            let formatted = recentConvos.map { "- \($0.summary)" }.joined(separator: "\n")
            parts.append("[Recent Conversation History]\n\(formatted)")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Prompt Modules

    private func injectPromptModules(agent: BaseAgent, conv: ConversationState, isPlanning: Bool, message: String) {
        let range = NSRange(message.startIndex..., in: message)
        let hasCodeKeywords = Self.codePattern.firstMatch(in: message, range: range) != nil

        let context = PromptContext(
            agentCategory: conv.currentAgent,
            lastTool: agent.lastToolUsed,
            lastToolFailed: agent.lastToolFailed,
            messageCount: conv.messageCount,
            isPlanning: isPlanning,
            hasCodeKeywords: hasCodeKeywords
        )

        let modules = PromptModules.activeModules(for: context)
        guard !modules.isEmpty else { return }

        let content = "[Active Context]\n" + modules.joined(separator: "\n")
        if agent.history.isEmpty {
            agent.history.append(["role": "system", "content": agent.systemPrompt])
        }
        agent.history.append(["role": "system", "content": content])
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

    // MARK: - RAG Tools

    private func registerRAGTools(on agent: BaseAgent) {
        agent.registerTool(
            ToolSpec(
                name: "ingest_file",
                description: "Ingest a file into the knowledge base for later retrieval.",
                properties: [
                    "path": .init(type: "string", description: "File path to ingest"),
                ],
                required: ["path"]
            )
        ) { [weak self] args in
            guard let self else { return "Orchestrator unavailable" }
            let path = args["path"] as? String ?? ""
            let ingester = DocumentIngester(
                client: self.activeClient,
                embeddingModel: self.modelConfig.embedding,
                chunkStore: self.chunkStore
            )
            let chunks = try await ingester.ingestFile(at: path)
            return "Ingested \(URL(fileURLWithPath: path).lastPathComponent): \(chunks) chunks added to knowledge base."
        }

        agent.registerTool(
            ToolSpec(
                name: "ingest_directory",
                description: "Ingest all supported files in a directory into the knowledge base.",
                properties: [
                    "path": .init(type: "string", description: "Directory path to scan"),
                ],
                required: ["path"]
            )
        ) { [weak self] args in
            guard let self else { return "Orchestrator unavailable" }
            let path = args["path"] as? String ?? ""
            let ingester = DocumentIngester(
                client: self.activeClient,
                embeddingModel: self.modelConfig.embedding,
                chunkStore: self.chunkStore
            )
            let result = try await ingester.ingestDirectory(at: path)
            return "Ingested \(result.files) files (\(result.chunks) chunks) from \(path)"
        }

        agent.registerTool(
            ToolSpec(
                name: "knowledge_search",
                description: "Search the knowledge base for information from ingested documents.",
                properties: [
                    "query": .init(type: "string", description: "Search query"),
                ],
                required: ["query"]
            )
        ) { [weak self] args in
            guard let self else { return "No knowledge base available" }
            let query = args["query"] as? String ?? ""

            guard self.chunkStore.totalChunkCount() > 0 else {
                return "Knowledge base is empty. Use ingest_file or ingest_directory to add documents."
            }

            let embeddings = try await self.activeClient.embed(
                model: self.modelConfig.embedding, text: [query]
            )
            guard let queryEmb = embeddings.first else { return "Failed to embed query" }

            let results = self.chunkStore.hybridSearch(
                queryEmbedding: queryEmb, keywords: query, topK: 5
            )

            if results.isEmpty { return "No relevant documents found for '\(query)'." }

            return results.enumerated().map { (i, r) in
                let source = URL(fileURLWithPath: r.chunk.sourceFile).lastPathComponent
                return "[\(i + 1)] (\(source), relevance: \(String(format: "%.0f%%", r.score * 100)))\n\(String(r.chunk.content.prefix(500)))"
            }.joined(separator: "\n---\n")
        }
    }

    // MARK: - Parallel Agent Execution

    /// Run multiple agents on the same query and merge results.
    /// Used for comparison queries or when Mixture of Agents is enabled.
    func runParallelAgents(
        conv: ConversationState,
        message: String,
        categories: [AgentCategory]
    ) async throws -> [(AgentCategory, String)] {
        try await withThrowingTaskGroup(of: (AgentCategory, String).self) { group in
            for category in categories {
                guard let agent = conv.agents[category] else { continue }
                group.addTask {
                    let result = try await agent.run(message)
                    return (category, result)
                }
            }

            var results: [(AgentCategory, String)] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }

    // MARK: - Mixture of Agents (MoA)

    /// Mixture of Agents: run multiple agents, then synthesize their outputs
    /// into a single superior response using a judge/synthesis model.
    func mixtureOfAgents(
        conv: ConversationState,
        message: String,
        categories: [AgentCategory]
    ) async throws -> String {
        let agentResults = try await runParallelAgents(
            conv: conv, message: message, categories: categories
        )

        guard agentResults.count > 1 else {
            return agentResults.first?.1 ?? "No agents available."
        }

        // Build synthesis prompt with all agent responses
        let responses = agentResults.map { (cat, result) in
            "[\(cat.displayName) Agent]\n\(result)"
        }.joined(separator: "\n\n---\n\n")

        let synthesisPrompt = """
        Multiple AI agents have answered the following question. Synthesize their responses \
        into a single, comprehensive answer that takes the best elements from each. \
        Be concise. Don't mention that multiple agents were used.

        Question: \(message)

        Agent Responses:
        \(responses)
        """

        let resp = try await activeClient.chat(
            model: modelConfig.general,
            messages: [
                ["role": "system", "content": "You synthesize multiple perspectives into one clear answer."],
                ["role": "user", "content": synthesisPrompt],
            ],
            tools: nil,
            temperature: 0.4,
            numCtx: 16384,
            timeout: 60
        )

        return ThinkingStripper.strip(resp.content)
    }

    /// Check if a message would benefit from parallel agent execution.
    private func shouldRunParallel(_ message: String) -> [AgentCategory]? {
        guard parallelAgentsEnabled || mixtureOfAgentsEnabled else { return nil }
        let range = NSRange(message.startIndex..., in: message)
        guard Self.parallelPattern.firstMatch(in: message, range: range) != nil else { return nil }
        return [.general, .coder, .reasoner]
    }

    // MARK: - Commands

    private func handleCommand(conv: ConversationState, message: String) async throws -> String {
        try await CommandHandler.handle(command: message, conv: conv, orchestrator: self)
    }

    // MARK: - Default Soul

    private static let defaultSoul = """
    You are a private local AI agent running entirely on this Mac.
    Everything you do stays on this machine. You never send data to external AI services.

    Core behavior:
    - ALWAYS use tools to find information before responding. Never say "I don't have access to"
      or "I can't look up" when you have web_search, fetch_page, or other tools available.
    - If the user asks about prices, weather, news, current events, or anything you don't know
      from training — search the web first. Do not refuse. Do not suggest the user look it up themselves.
    - Act, don't apologize. Use your tools. That is what they are for.

    Communication style:
    - Write like a sharp, competent colleague. Professional but human.
    - Never use markdown formatting. Write in plain sentences and paragraphs.
    - Keep responses concise. One to three short paragraphs for most answers.
    - No filler phrases, no emojis, no exclamation marks.
    - Sound like a trusted advisor, not a chatbot.

    Image and file capabilities:
    - When tools return images (screenshots, charts, web pages), they are displayed inline in the chat directly below your text response. You do NOT need to explain how to open the file.
    - Never say the image is "above" — it always appears below your text. Say "here is" or "attached below" or just describe what it shows.
    - When you take a screenshot or generate a chart, the user will see it directly in the conversation. Respond as if they can see the image.
    - Include [IMAGE:/path/to/file.png] in your response to display an image file inline.

    Boundaries:
    - Never execute destructive commands without explicit confirmation.
    - Never access or transmit credentials or secrets.
    """
}
