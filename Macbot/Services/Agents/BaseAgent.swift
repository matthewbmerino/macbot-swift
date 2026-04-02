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

        let tools = await toolRegistry.specsAsJSON

        for _ in 0..<10 {
            if tokenCount > Int(Double(numCtx) * 0.75) {
                await trimHistory()
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

            // Log tool calls
            let toolNames = toolCalls.compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            }
            Log.agents.info("[\(self.name)] calling tools: \(toolNames.joined(separator: ", "))")

            // Execute tools in parallel
            let results = await toolRegistry.executeAll(toolCalls)
            for (_, result) in results {
                appendToHistory(["role": "tool", "content": result])
            }
        }

        return "Max tool iterations reached."
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
                            // Estimate time
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

                    let tools = await toolRegistry.specsAsJSON
                    var stepCount = 0

                    for _ in 0..<10 {
                        if tokenCount > Int(Double(numCtx) * 0.75) {
                            await trimHistory()
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
                            let content = ThinkingStripper.strip(resp.content)
                            if !content.isEmpty {
                                continuation.yield(.text(content))
                            }
                            continuation.finish()
                            return
                        }

                        // Status update before tool execution
                        stepCount += 1
                        let toolNames = toolCalls.compactMap {
                            ($0["function"] as? [String: Any])?["name"] as? String
                        }
                        let labels = toolNames.map { Self.toolLabels[$0] ?? $0 }
                        let stepLabel = labels.joined(separator: ", ")
                        continuation.yield(.status("Step \(stepCount): \(stepLabel)..."))

                        // Execute tools in parallel
                        let imagePattern = try? NSRegularExpression(pattern: "\\[IMAGE:(.*?)\\]")
                        let results = await toolRegistry.executeAll(toolCalls)
                        for (_, result) in results {
                            appendToHistory(["role": "tool", "content": result])

                            // Extract and yield images from tool results
                            if let regex = imagePattern {
                                let range = NSRange(result.startIndex..., in: result)
                                for match in regex.matches(in: result, range: range) {
                                    if let pathRange = Range(match.range(at: 1), in: result) {
                                        let path = String(result[pathRange])
                                        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                                            continuation.yield(.image(data, URL(fileURLWithPath: path).lastPathComponent))
                                        }
                                    }
                                }
                            }
                        }

                        // Status update after tool execution — model is now processing results
                        continuation.yield(.status("Step \(stepCount): \(stepLabel) — done. Thinking..."))
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
