import Foundation

class BaseAgent {
    let name: String
    var model: String
    var systemPrompt: String
    let temperature: Double
    let numCtx: Int

    let client: any InferenceProvider
    let toolRegistry = ToolRegistry()
    var history: [[String: Any]] = []
    var userId: String?
    var memoryStore: MemoryStore?

    private var tokenCount: Int = 0

    // Tool state tracking for PromptModules
    var lastToolUsed: String = ""
    var lastToolFailed: Bool = false

    // ReAct reflection — evaluate tool results before responding
    var reflectionEnabled: Bool = true
    private let reflectionThreshold = 5  // Reflect after this many tool calls

    // Human-readable tool labels for status updates
    static let toolLabels: [String: String] = [
        "web_search": "searching the web",
        "fetch_page": "reading a web page",
        "browse_url": "browsing a page",
        "browse_and_act": "interacting with a page",
        "screenshot_url": "taking a screenshot",
        "run_python": "running code",
        "run_command": "running a command",
        "read_file": "reading a file",
        "write_file": "writing a file",
        "list_directory": "listing files",
        "search_files": "searching files",
        "memory_save": "saving to memory",
        "memory_recall": "recalling memories",
        "memory_search": "searching memory",
        "ingest_file": "ingesting document",
        "ingest_directory": "scanning directory",
        "knowledge_search": "searching knowledge base",
        "generate_chart": "creating chart",
        "stock_chart": "generating stock chart",
        "comparison_chart": "comparing stocks",
        "get_stock_price": "checking stock price",
        "get_stock_history": "fetching stock history",
        "get_market_summary": "checking market summary",
        "weather_lookup": "checking weather",
        "calculator": "calculating",
        "unit_convert": "converting units",
        "date_calc": "calculating dates",
        "define_word": "looking up definition",
        "system_dashboard": "checking system health",
    ]

    init(
        name: String,
        model: String,
        systemPrompt: String,
        temperature: Double,
        numCtx: Int,
        client: any InferenceProvider
    ) {
        self.name = name
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.numCtx = numCtx
        self.client = client
    }

    func clearHistory() {
        history.removeAll()
        tokenCount = 0
    }

    func registerTool(_ spec: ToolSpec, handler: @escaping ToolHandler) {
        Task { await toolRegistry.register(spec, handler: handler) }
    }

    // MARK: - History Management

    private func appendToHistory(_ msg: [String: Any]) {
        history.append(msg)
        tokenCount += TokenEstimator.estimate(messages: [msg])
    }

    private func trimHistory() async {
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

    // MARK: - Planning

    private func generatePlan(_ input: String) async -> String? {
        let prompt = """
        You are planning a task. Output ONLY a numbered list of 2-5 steps. \
        Each step should be one short sentence naming the specific action. \
        After each step, estimate the time in seconds (5-30s for tool calls, 10-60s for browsing). \
        Format: 1. [action] (~Xs)
        Do not include any other text. Do not execute anything.

        Task: \(input)
        """

        do {
            let resp = try await client.chat(
                model: "qwen3.5:0.8b",
                messages: [
                    ["role": "system", "content": prompt],
                    ["role": "user", "content": input],
                ],
                tools: nil,
                temperature: 0.2,
                numCtx: 2048,
                timeout: 30
            )
            let plan = ThinkingStripper.strip(resp.content)
            if !plan.isEmpty {
                appendToHistory([
                    "role": "system",
                    "content": "Execute this plan step by step. After each tool call, briefly note which step you just completed before moving on.\n\nPlan:\n\(plan)",
                ])
                Log.agents.info("[\(self.name)] plan generated")
            }
            return plan
        } catch {
            Log.agents.warning("[\(self.name)] planning failed: \(error)")
            return nil
        }
    }

    // MARK: - Run (non-streaming)

    func run(_ input: String, images: [Data]? = nil, plan: Bool = false) async throws -> String {
        if history.isEmpty {
            appendToHistory(["role": "system", "content": systemPrompt])
        }

        var msg: [String: Any] = ["role": "user", "content": input]
        if let images {
            msg["images"] = images.map { $0.base64EncodedString() }
        }
        appendToHistory(msg)

        if plan { _ = await generatePlan(input) }

        // Pre-filter tools based on message content
        var recentTools: [String] = []
        var tools = await toolRegistry.filteredSpecsAsJSON(for: input, recentTools: recentTools)
        var toolCallCount = 0

        for _ in 0..<10 {
            if tokenCount > Int(Double(numCtx) * 0.75) {
                await trimHistory()
            }

            // Re-filter with recency bias so follow-up tool calls are available
            if !recentTools.isEmpty {
                tools = await toolRegistry.filteredSpecsAsJSON(for: input, recentTools: recentTools)
            }

            let resp = try await client.chat(
                model: model,
                messages: history,
                tools: tools.isEmpty ? nil : tools,
                temperature: temperature,
                numCtx: numCtx,
                timeout: 120
            )

            appendToHistory(["role": "assistant", "content": resp.content])

            guard let toolCalls = resp.toolCalls, !toolCalls.isEmpty else {
                return ThinkingStripper.strip(resp.content)
            }

            // Log tool calls and track for recency bias
            let toolNames = toolCalls.compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            }
            recentTools = toolNames
            Log.agents.info("[\(self.name)] calling tools: \(toolNames.joined(separator: ", "))")

            // Execute tools in parallel
            let results = await toolRegistry.executeAll(toolCalls)
            for (name, result) in results {
                appendToHistory(["role": "tool", "content": result])
                lastToolUsed = name
                lastToolFailed = result.hasPrefix("Error:")
            }

            toolCallCount += toolCalls.count

            // ReAct reflection: after multiple tool calls, evaluate if we have enough
            // information to answer, or if the approach needs adjustment
            if reflectionEnabled && toolCallCount >= reflectionThreshold {
                let shouldContinue = await reflect(
                    originalQuery: input,
                    toolResults: results.map(\.1)
                )
                if !shouldContinue {
                    // Inject a reflection nudge to help the model synthesize
                    appendToHistory([
                        "role": "system",
                        "content": "You have gathered enough information. Synthesize your findings and respond to the user's original question directly. Do not call more tools.",
                    ])
                }
            }
        }

        return "Max tool iterations reached."
    }

    // MARK: - ReAct Reflection

    /// Evaluate whether tool results adequately address the user's query.
    /// Returns true if more tool calls are needed, false if ready to respond.
    private func reflect(originalQuery: String, toolResults: [String]) async -> Bool {
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

    // MARK: - Run (streaming)

    func runStream(_ input: String, images: [Data]? = nil, plan: Bool = false) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if history.isEmpty {
                        appendToHistory(["role": "system", "content": systemPrompt])
                    }

                    var msg: [String: Any] = ["role": "user", "content": input]
                    if let images {
                        msg["images"] = images.map { $0.base64EncodedString() }
                    }
                    appendToHistory(msg)

                    if plan {
                        if let planText = await generatePlan(input) {
                            let regex = try? NSRegularExpression(pattern: "~(\\d+)s")
                            let matches = regex?.matches(in: planText, range: NSRange(planText.startIndex..., in: planText)) ?? []
                            let totalEst = matches.compactMap { match -> Int? in
                                guard let range = Range(match.range(at: 1), in: planText) else { return nil }
                                return Int(planText[range])
                            }.reduce(0, +)
                            let timeStr = totalEst < 60 ? "\(totalEst) seconds" : "\(totalEst / 60) minute\(totalEst >= 120 ? "s" : "")"
                            continuation.yield(.status("Planning complete. Estimated time: about \(timeStr). Working on it now."))
                        }
                    }

                    var recentTools: [String] = []
                    var tools = await toolRegistry.filteredSpecsAsJSON(for: input, recentTools: recentTools)
                    var stepCount = 0
                    var totalToolCalls = 0

                    for _ in 0..<10 {
                        if tokenCount > Int(Double(numCtx) * 0.75) {
                            await trimHistory()
                        }

                        if !recentTools.isEmpty {
                            tools = await toolRegistry.filteredSpecsAsJSON(for: input, recentTools: recentTools)
                        }

                        let resp = try await client.chat(
                            model: model,
                            messages: history,
                            tools: tools.isEmpty ? nil : tools,
                            temperature: temperature,
                            numCtx: numCtx,
                            timeout: 120
                        )

                        appendToHistory(["role": "assistant", "content": resp.content])

                        guard let toolCalls = resp.toolCalls, !toolCalls.isEmpty else {
                            var content = ThinkingStripper.strip(resp.content)

                            let imgRegex = try? NSRegularExpression(pattern: "\\[IMAGE:(.*?)\\]")
                            if let regex = imgRegex {
                                let range = NSRange(content.startIndex..., in: content)
                                for match in regex.matches(in: content, range: range).reversed() {
                                    if let pathRange = Range(match.range(at: 1), in: content) {
                                        let imgPath = String(content[pathRange])
                                        if let data = try? Data(contentsOf: URL(fileURLWithPath: imgPath)) {
                                            continuation.yield(.image(data, URL(fileURLWithPath: imgPath).lastPathComponent))
                                        }
                                    }
                                    if let fullRange = Range(match.range, in: content) {
                                        content.removeSubrange(fullRange)
                                    }
                                }
                            }

                            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !cleaned.isEmpty {
                                continuation.yield(.text(cleaned))
                            }
                            continuation.finish()
                            return
                        }

                        stepCount += 1
                        totalToolCalls += toolCalls.count
                        let toolNames = toolCalls.compactMap {
                            ($0["function"] as? [String: Any])?["name"] as? String
                        }
                        recentTools = toolNames
                        let labels = toolNames.map { Self.toolLabels[$0] ?? $0 }
                        let stepLabel = labels.joined(separator: ", ")

                        // Clean status: capitalize first label, no "Step N" for single-step tasks
                        let statusText = stepCount == 1
                            ? "\(stepLabel.prefix(1).uppercased())\(stepLabel.dropFirst())..."
                            : "Step \(stepCount): \(stepLabel)..."
                        continuation.yield(.status(statusText))

                        let imagePattern = try? NSRegularExpression(pattern: "\\[IMAGE:(.*?)\\]")
                        let results = await toolRegistry.executeAll(toolCalls)
                        for (name, result) in results {
                            appendToHistory(["role": "tool", "content": result])
                            lastToolUsed = name
                            lastToolFailed = result.hasPrefix("Error:")

                            if let regex = imagePattern {
                                let range = NSRange(result.startIndex..., in: result)
                                let matches = regex.matches(in: result, range: range)
                                for match in matches {
                                    if let pathRange = Range(match.range(at: 1), in: result) {
                                        let path = String(result[pathRange])
                                        Log.tools.info("Found image in tool result: \(path)")
                                        if FileManager.default.fileExists(atPath: path) {
                                            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                                                Log.tools.info("Yielding image: \(data.count) bytes")
                                                continuation.yield(.image(data, URL(fileURLWithPath: path).lastPathComponent))
                                            } else {
                                                Log.tools.error("Failed to read image file: \(path)")
                                            }
                                        } else {
                                            Log.tools.error("Image file not found: \(path)")
                                        }
                                    }
                                }
                            }
                        }

                        // Only show "Thinking..." if no images were produced
                        // (if images were yielded, the user already sees the result)
                        let producedImages = results.contains { $0.1.contains("[IMAGE:") }
                        if !producedImages {
                            continuation.yield(.status("Step \(stepCount): \(stepLabel) — done. Thinking..."))
                        }

                        // ReAct reflection after multiple tool calls
                        if reflectionEnabled && totalToolCalls >= reflectionThreshold {
                            let shouldContinue = await reflect(
                                originalQuery: input,
                                toolResults: results.map(\.1)
                            )
                            if !shouldContinue {
                                continuation.yield(.status("Synthesizing findings..."))
                                appendToHistory([
                                    "role": "system",
                                    "content": "You have gathered enough information. Synthesize your findings and respond to the user's original question directly. Do not call more tools.",
                                ])
                            }
                        }
                    }

                    continuation.yield(.text("Max tool iterations reached."))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
