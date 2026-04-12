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

    var tokenCount: Int = 0

    // Tool state tracking for PromptModules
    var lastToolUsed: String = ""
    var lastToolFailed: Bool = false

    // Learned tool hints from k-NN over the trace store. Set by Orchestrator
    // before each turn — gets merged into the tool filter as if it were
    // recency bias. Lets the learned router promote tools without overriding
    // the keyword router until eval shows it wins.
    var learnedToolHints: [String] = []

    // ReAct reflection — evaluate tool results before responding
    var reflectionEnabled: Bool = true
    private let reflectionThreshold = 3  // Reflect after this many tool calls

    /// Maximum tool-using iterations before forcing a synthesis. The 10th
    /// iteration always runs without tools so the model is forced to write a
    /// real answer from whatever it has gathered, instead of returning a
    /// dead-end "max iterations" string and discarding the work.
    private let maxIterations = 10

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
        "summarize_url": "summarizing page",
        "json_format": "formatting JSON",
        "encode_decode": "encoding/decoding",
        "regex_extract": "extracting pattern",
        "ping": "pinging host",
        "dns_lookup": "looking up DNS",
        "port_check": "checking port",
        "http_check": "checking HTTP",
        "git_status": "checking git status",
        "git_log": "reading git log",
        "git_diff": "reading git diff",
        "screen_ocr": "reading screen",
        "screen_region_ocr": "reading screen region",
        "calendar_today": "checking calendar",
        "calendar_create": "creating event",
        "calendar_week": "checking week",
        "reminder_create": "creating reminder",
        "email_draft": "drafting email",
        "email_read": "reading emails",
        "now_playing": "checking music",
        "media_control": "controlling music",
        "search_play": "searching music",
        "generate_qr": "generating QR code",
        "generate_image": "generating image",
    ]

    /// Universal anti-fabrication rule appended to every agent's system prompt.
    /// On a 9B model, the highest-leverage hallucination control is a strict
    /// "you may only cite what's in your context" rule. This phrasing has been
    /// validated empirically — vague variants ("be accurate", "don't make
    /// things up") don't work because the model sees them as soft suggestions.
    static let antiFabricationClause = """

    GROUNDING (read carefully):
    - You MUST only state facts that come from your tool outputs, retrieved
      memory, or the user's own message in this turn. If a piece of information
      is not present in any of those, you do not have it.
    - When a tool returns numbers, dates, prices, or quotes, copy them exactly.
      Do not round, paraphrase, or "improve" them.
    - If a tool result includes a "Data (single source of truth ...)" block,
      every numeric claim in your response must come verbatim from that block.
    - If asked something you have no grounding for, the only correct answers
      are: (a) call a tool to find out, or (b) say "I don't have that
      information" or "I'm not sure." Never invent plausible-sounding facts.
    - Do not hedge to disguise a guess. "Approximately", "around", and
      "roughly" are not licenses to fabricate.
    """

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
        self.systemPrompt = systemPrompt + Self.antiFabricationClause
        self.temperature = temperature
        self.numCtx = numCtx
        self.client = client
    }

    /// Concatenate every "tool" role message in the current history into a
    /// single haystack string. Used by the citation guard to know what
    /// numbers the model is allowed to cite this turn.
    func collectToolHistoryText() -> String {
        var parts: [String] = []
        for msg in history {
            guard let role = msg["role"] as? String, role == "tool" else { continue }
            if let content = msg["content"] as? String, !content.isEmpty {
                parts.append(content)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Sampling temperature to use for the next chat() call.
    ///
    /// Once any tool has been called this turn we have grounded data the model
    /// should be quoting verbatim — there's no upside to creative sampling and
    /// significant downside (the model "smooths" the numbers). We clamp to
    /// 0.2 in that case. Without tool calls, the agent's configured
    /// temperature stands.
    func adaptiveTemperature(toolCallCount: Int) -> Double {
        toolCallCount > 0 ? min(temperature, 0.2) : temperature
    }

    func clearHistory() {
        history.removeAll()
        tokenCount = 0
    }

    /// Replace this agent's history with `[systemPrompt] + transcript` so the
    /// agent sees the full canonical conversation regardless of which agent
    /// answered prior turns. Called by Orchestrator at the start of every turn
    /// to keep context coherent across routing changes.
    ///
    /// The Orchestrator owns the conversation transcript; agents are stateless
    /// borrowers from one turn to the next.
    func loadHistoryFromTranscript(_ transcript: [[String: Any]]) {
        history = [["role": "system", "content": systemPrompt]]
        history.append(contentsOf: transcript)
        tokenCount = TokenEstimator.estimate(messages: history)
    }

    func registerTool(_ spec: ToolSpec, handler: @escaping ToolHandler) {
        Task { await toolRegistry.register(spec, handler: handler) }
    }

    // MARK: - History Management

    func appendToHistory(_ msg: [String: Any]) {
        history.append(msg)
        tokenCount += TokenEstimator.estimate(messages: [msg])
    }

    // MARK: - Planning (uses primary model for quality)

    private func generatePlan(_ input: String) async -> String? {
        let prompt = """
        Break this task into 2-5 numbered steps. For each step, name the specific tool to use. \
        Format: 1. [action] — [tool_name] (~Xs)
        Output ONLY the numbered list, nothing else.

        Task: \(input)
        """

        do {
            let resp = try await client.chat(
                model: model,
                messages: [
                    ["role": "system", "content": prompt],
                    ["role": "user", "content": input],
                ],
                tools: nil,
                temperature: 0.2,
                numCtx: min(numCtx, 4096),
                timeout: 30
            )
            let plan = ThinkingStripper.strip(resp.content)
            if !plan.isEmpty {
                appendToHistory([
                    "role": "system",
                    "content": "Execute this plan step by step. After each tool call, state which step you completed and what you learned. Then proceed to the next step.\n\nPlan:\n\(plan)",
                ])
                Log.agents.info("[\(self.name)] plan generated")
            }
            return plan
        } catch {
            Log.agents.warning("[\(self.name)] planning failed: \(error)")
            return nil
        }
    }

    // MARK: - Tool Result Compression

    /// Compress large tool results to preserve context budget.
    private func compressToolResult(_ result: String, toolName: String) -> String {
        guard result.count > 2000 else { return result }

        // Keep full output for small results or structured data
        let structuredTools: Set = ["calculator", "unit_convert", "date_calc", "get_stock_price",
                                     "get_market_summary", "weather_lookup", "define_word",
                                     "git_status", "ping", "port_check", "dns_lookup"]
        if structuredTools.contains(toolName) { return result }

        // For large text outputs, truncate intelligently
        let lines = result.components(separatedBy: "\n")
        if lines.count > 50 {
            // Keep first 20 and last 10 lines
            let head = lines.prefix(20).joined(separator: "\n")
            let tail = lines.suffix(10).joined(separator: "\n")
            return "\(head)\n\n... (\(lines.count - 30) lines omitted) ...\n\n\(tail)"
        }

        // Simple truncation with notice
        return String(result.prefix(2000)) + "\n... (truncated from \(result.count) chars)"
    }

    // MARK: - Self-Verification

    /// Lightweight check: does the response actually answer the question?
    private func verify(response: String, originalQuery: String) async -> String? {
        // Skip verification for very short or tool-heavy responses
        guard response.count > 50 else { return nil }

        do {
            let resp = try await client.chat(
                model: "qwen3.5:0.8b",
                messages: [
                    ["role": "system", "content": "You are a response validator. Given a user question and an AI response, determine if the response ACTUALLY ANSWERS the question. Respond with ONLY one word: GOOD, INCOMPLETE, or WRONG. No other text."],
                    ["role": "user", "content": "Question: \(String(originalQuery.prefix(300)))\n\nResponse: \(String(response.prefix(500)))"],
                ],
                tools: nil,
                temperature: 0.0,
                numCtx: 1024,
                timeout: 8
            )

            let verdict = ThinkingStripper.strip(resp.content).uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if verdict.contains("INCOMPLETE") || verdict.contains("WRONG") {
                Log.agents.info("[\(self.name)] verification: \(verdict) — requesting retry")
                return verdict.contains("INCOMPLETE") ? "incomplete" : "wrong"
            }
            return nil  // GOOD — no retry needed
        } catch {
            return nil  // Verification failed — don't block the response
        }
    }

    // MARK: - Ambient context injection

    /// Injects a transient system message describing the user's current environment
    /// (active app, idle, battery, etc) before the next user turn. Lets the model
    /// reason about context without the user having to spell it out.
    func injectAmbientContext() async {
        let line = await AmbientMonitor.shared.promptLine()
        guard !line.isEmpty else { return }
        appendToHistory(["role": "system", "content": line])
    }

    // MARK: - Run (non-streaming)

    func run(_ input: String, images: [Data]? = nil, plan: Bool = false) async throws -> String {
        if history.isEmpty {
            appendToHistory(["role": "system", "content": systemPrompt])
        }

        await injectAmbientContext()

        var msg: [String: Any] = ["role": "user", "content": input]
        if let images {
            msg["images"] = images.map { $0.base64EncodedString() }
        }
        appendToHistory(msg)

        if plan { _ = await generatePlan(input) }

        // Pre-filter tools based on message content
        var recentTools: [String] = learnedToolHints
        var tools = await toolRegistry.filteredSpecsAsJSON(for: input, recentTools: recentTools)
        var toolCallCount = 0

        for iteration in 0..<maxIterations {
            if tokenCount > Int(Double(numCtx) * 0.75) {
                await trimHistory()
            }

            // Re-filter with recency bias so follow-up tool calls are available
            if !recentTools.isEmpty {
                tools = await toolRegistry.filteredSpecsAsJSON(for: input, recentTools: recentTools)
            }

            // On the final iteration, force a synthesis: no tools allowed,
            // strong nudge to answer from gathered data. This is the
            // anti-rabbit-hole guard. Without it the agent could spend all
            // 10 iterations calling tools and then return "Max tool
            // iterations reached" — throwing away the work.
            let isFinalIteration = iteration == maxIterations - 1
            if isFinalIteration {
                appendToHistory([
                    "role": "system",
                    "content": "Stop calling tools. Use ONLY the tool results already in this conversation to answer the user's original question now. If the results contain the answer, quote them verbatim. If they don't, say exactly what's missing — do not guess.",
                ])
            }

            let resp = try await client.chat(
                model: model,
                messages: history,
                tools: isFinalIteration ? nil : (tools.isEmpty ? nil : tools),
                temperature: adaptiveTemperature(toolCallCount: toolCallCount),
                numCtx: numCtx,
                timeout: 120
            )

            appendToHistory(["role": "assistant", "content": resp.content])

            // Final-iteration response is always returned as-is, even if the
            // model tried to call more tools (we ignore those calls).
            if isFinalIteration {
                return ThinkingStripper.strip(resp.content)
            }

            guard let toolCalls = resp.toolCalls, !toolCalls.isEmpty else {
                let response = ThinkingStripper.strip(resp.content)

                // Citation guard: deterministic check that every numeric
                // claim in the draft is supported by some tool result this
                // turn. Catches the fabrication-by-paraphrase failures
                // (rounding, smoothing, made-up percentages) without an
                // extra LLM call. Only runs when tools were actually
                // called this turn — otherwise the "tool history" is empty
                // and we have nothing to check against.
                if toolCallCount > 0 {
                    let toolHistoryText = collectToolHistoryText()
                    let result = CitationGuard.check(
                        draft: response,
                        toolHistory: toolHistoryText
                    )
                    if !result.isGrounded {
                        Log.agents.warning("[\(self.name)] citation guard fired: \(result.unsourced.map(\.original).joined(separator: ","))")
                        ActivityLog.shared.log(.inference, "Citation check failed — regenerating with tool-grounding nudge")
                        appendToHistory([
                            "role": "system",
                            "content": CitationGuard.regenerationNudge(for: result.unsourced),
                        ])
                        let regen = try await client.chat(
                            model: model, messages: history, tools: nil,
                            temperature: adaptiveTemperature(toolCallCount: toolCallCount),
                            numCtx: numCtx, timeout: 120
                        )
                        appendToHistory(["role": "assistant", "content": regen.content])
                        return ThinkingStripper.strip(regen.content)
                    }
                }

                // Self-verification: does this actually answer the question?
                if toolCallCount > 0, let issue = await verify(response: response, originalQuery: input) {
                    let nudge = issue == "incomplete"
                        ? "Your response was incomplete. Re-read the original question and make sure you address every part of it."
                        : "Your response didn't correctly answer the question. Re-read it carefully and try again."
                    appendToHistory(["role": "system", "content": nudge])
                    // One more iteration to fix it
                    let retry = try await client.chat(
                        model: model, messages: history, tools: nil,
                        temperature: adaptiveTemperature(toolCallCount: toolCallCount),
                        numCtx: numCtx, timeout: 120
                    )
                    appendToHistory(["role": "assistant", "content": retry.content])
                    return ThinkingStripper.strip(retry.content)
                }

                return response
            }

            // Log tool calls and track for recency bias
            let toolNames = toolCalls.compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            }
            recentTools = toolNames
            Log.agents.info("[\(self.name)] calling tools: \(toolNames.joined(separator: ", "))")

            // Execute tools in parallel, compress large results
            let results = await toolRegistry.executeAll(toolCalls)
            for (name, result) in results {
                let compressed = compressToolResult(result, toolName: name)
                appendToHistory(["role": "tool", "content": compressed])
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
                    appendToHistory([
                        "role": "system",
                        "content": "You have gathered enough information. Synthesize your findings and respond to the user's original question directly. Do not call more tools.",
                    ])
                }
            }
        }

        // Unreachable: the loop always returns on the final iteration above.
        // Kept as a defensive fallback so the function still type-checks.
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

                    await injectAmbientContext()

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

                    var recentTools: [String] = learnedToolHints
                    var tools = await toolRegistry.filteredSpecsAsJSON(for: input, recentTools: recentTools)
                    var stepCount = 0
                    var totalToolCalls = 0

                    for iteration in 0..<maxIterations {
                        if tokenCount > Int(Double(numCtx) * 0.75) {
                            await trimHistory()
                        }

                        if !recentTools.isEmpty {
                            tools = await toolRegistry.filteredSpecsAsJSON(for: input, recentTools: recentTools)
                        }

                        // See note on the non-streaming path: final iteration
                        // forces a synthesis with no tools so we never bail
                        // out with the dead-end "Max tool iterations" string.
                        let isFinalIteration = iteration == maxIterations - 1
                        if isFinalIteration {
                            continuation.yield(.status("Synthesizing answer from gathered data..."))
                            appendToHistory([
                                "role": "system",
                                "content": "Stop calling tools. Use ONLY the tool results already in this conversation to answer the user's original question now. If the results contain the answer, quote them verbatim. If they don't, say exactly what's missing — do not guess.",
                            ])
                        }

                        let resp = try await client.chat(
                            model: model,
                            messages: history,
                            tools: isFinalIteration ? nil : (tools.isEmpty ? nil : tools),
                            temperature: adaptiveTemperature(toolCallCount: totalToolCalls),
                            numCtx: numCtx,
                            timeout: 120
                        )

                        appendToHistory(["role": "assistant", "content": resp.content])

                        // Final iteration: emit whatever the model produced and stop.
                        if isFinalIteration {
                            let content = ThinkingStripper.strip(resp.content)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !content.isEmpty {
                                continuation.yield(.text(content))
                            }
                            continuation.finish()
                            return
                        }

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
                            let compressed = compressToolResult(result, toolName: name)
                            appendToHistory(["role": "tool", "content": compressed])
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

                    // Unreachable — the final iteration above always yields
                    // and finishes. Defensive fallback only.
                    continuation.yield(.text("Max tool iterations reached."))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
