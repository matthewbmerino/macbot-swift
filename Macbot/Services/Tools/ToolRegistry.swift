import Foundation

actor ToolRegistry {
    private var specs: [ToolSpec] = []
    private var handlers: [String: ToolHandler] = [:]

    static let toolTimeout: TimeInterval = 60

    func register(_ spec: ToolSpec, handler: @escaping ToolHandler) {
        specs.append(spec)
        handlers[spec.function.name] = handler
    }

    var allSpecs: [ToolSpec] { specs }

    // Tool groups for deterministic pre-filtering
    private static let toolGroups: [String: (keywords: [String], tools: [String])] = [
        "finance": (["stock", "price", "market", "ticker", "portfolio", "dow", "nasdaq", "s&p", "spy", "aapl", "goog", "msft", "tsla", "amzn", "nvda", "returns", "shares", "equity", "etf"], ["get_stock_price", "get_stock_history", "get_market_summary", "stock_chart", "comparison_chart"]),
        "browser": (["browse", "website", "visit", "go to", "http://", "https://"], ["browse_url", "browse_and_act", "screenshot_url"]),
        "web": (["search", "look up", "find out", "what is", "who is", "latest", "news", "current", "today", "right now", "how much", "price of", "cost of", "bitcoin", "btc", "crypto", "ethereum", "eth"], ["web_search", "fetch_page"]),
        "files": (["file", "read", "write", "folder", "directory", "create file"], ["read_file", "write_file", "list_directory", "search_files"]),
        "chart": (["chart", "graph", "plot", "visualize", "diagram", "show me", "display", "trend", "performance", "over time", "history", "historical", "ytd", "year to date", "monthly", "weekly", "daily", "compare stocks", "compare tickers", "versus", " vs "], ["stock_chart", "generate_chart", "comparison_chart"]),
        "macos": (["screenshot", "clipboard", "open app", "open safari", "open terminal", "open chrome", "open xcode", "launch", "quit", "close app", "volume", "notification", "what apps", "running apps", "battery", "system info", "process", "pid", "memory usage", "cpu usage", "port", "server", "listening", "top processes", "what's running", "resource", "which app", "how much memory", "how much ram", "what's using", "dark mode", "focus", "bring to front", "activate", "switch to"], ["take_screenshot", "open_app", "open_url", "send_notification", "get_clipboard", "set_clipboard", "list_running_apps", "get_system_info", "get_process_details", "get_top_processes", "get_listening_ports", "quit_app", "run_applescript", "run_command", "set_volume", "toggle_dark_mode", "focus_app"]),
        "code": (["run python", "execute", "script", "run code", "pip", "install"], ["run_python", "run_command"]),
        "memory": (["remember", "memory", "recall", "forget", "what do you know"], ["memory_save", "memory_recall", "memory_search", "memory_forget"]),
        "knowledge": (["document", "knowledge", "ingest", "rag", "what does the doc", "from my files", "in my notes"], ["ingest_file", "ingest_directory", "knowledge_search"]),
        "skills": (["weather", "forecast", "temperature outside", "calculate", "math", "what is", "how many", "convert", "units", "how many days", "days until", "days between", "date", "define", "definition", "meaning of", "dashboard", "system health"], ["weather_lookup", "calculator", "unit_convert", "date_calc", "define_word", "system_dashboard"]),
    ]

    // Groups that commonly need each other — if one matches, include the other
    private static let cooccurringGroups: [(String, String)] = [
        ("finance", "chart"),   // Stock queries almost always need visualization
        ("chart", "finance"),   // Chart requests about stocks need data
        ("browser", "web"),     // Browsing often involves search
    ]

    /// Filter tools to relevant ones based on message content.
    func filteredSpecsAsJSON(for message: String, recentTools: [String] = []) -> [[String: Any]] {
        let lower = message.lowercased()
        var matchedGroups = Set<String>()
        var matchedNames = Set<String>()

        for (groupName, group) in Self.toolGroups {
            if group.keywords.contains(where: { lower.contains($0) }) {
                matchedGroups.insert(groupName)
                matchedNames.formUnion(group.tools)
            }
        }

        // Pull in co-occurring groups
        for (from, to) in Self.cooccurringGroups {
            if matchedGroups.contains(from), !matchedGroups.contains(to) {
                if let group = Self.toolGroups[to] {
                    matchedNames.formUnion(group.tools)
                }
            }
        }

        // Recency bias
        matchedNames.formUnion(recentTools)

        // Default fallback
        if matchedNames.isEmpty {
            matchedNames = ["web_search", "memory_recall", "run_command", "calculator"]
        }

        let filtered = specs.filter { matchedNames.contains($0.function.name) }
        let toEncode = filtered.isEmpty ? Array(specs.prefix(5)) : filtered

        return toEncode.compactMap { spec in
            guard let data = try? JSONEncoder().encode(spec),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return json
        }
    }

    /// Specs as Ollama-compatible JSON array.
    var specsAsJSON: [[String: Any]] {
        specs.compactMap { spec in
            guard let data = try? JSONEncoder().encode(spec),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return json
        }
    }

    func execute(name: String, arguments: ToolArguments) async -> (String, String) {
        guard let handler = handlers[name] else {
            ActivityLog.shared.log(.tool, "Unknown tool: \(name)")
            return (name, "Unknown tool: \(name)")
        }

        let argsPreview = arguments.keys.joined(separator: ", ")
        ActivityLog.shared.log(.tool, "Calling \(name)(\(argsPreview))...")

        // Fire pre-tool hook
        await HookSystem.shared.fireAsync(HookContext.make(
            event: .toolStart, toolName: name, toolArgs: arguments
        ))

        do {
            let result = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.executeWithRetry(handler: handler, arguments: arguments, name: name)
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(Self.toolTimeout))
                    throw ToolError.timeout(name, Self.toolTimeout)
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            // Fire post-tool hook
            await HookSystem.shared.fireAsync(HookContext.make(
                event: .toolComplete, toolName: name, result: result
            ))

            let preview = String(result.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            ActivityLog.shared.log(.tool, "\(name) → \(preview)")
            return (name, result)
        } catch is ToolError {
            let err = "Error: tool '\(name)' timed out after \(Int(Self.toolTimeout))s"
            ActivityLog.shared.log(.tool, err)
            await HookSystem.shared.fireAsync(HookContext.make(
                event: .toolError, toolName: name, error: err
            ))
            return (name, err)
        } catch {
            let err = "Error: \(error.localizedDescription)"
            await HookSystem.shared.fireAsync(HookContext.make(
                event: .toolError, toolName: name, error: err
            ))
            return (name, err)
        }
    }

    /// Retry handler up to 2 times on non-timeout errors with exponential backoff.
    private func executeWithRetry(handler: ToolHandler, arguments: ToolArguments, name: String, maxRetries: Int = 2) async throws -> String {
        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay = Double(attempt)  // 1s, 2s
                try await Task.sleep(for: .seconds(delay))
                ActivityLog.shared.log(.tool, "Retrying \(name) (attempt \(attempt + 1)/\(maxRetries + 1))")
            }
            do {
                return try await handler(arguments)
            } catch {
                lastError = error
            }
        }
        throw lastError!
    }

    /// Execute multiple tool calls in parallel.
    func executeAll(_ calls: [[String: Any]]) async -> [(String, String)] {
        await withTaskGroup(of: (String, String).self) { group in
            for call in calls {
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let args = function["arguments"] as? [String: Any]
                else { continue }

                group.addTask {
                    await self.execute(name: name, arguments: args)
                }
            }

            var results: [(String, String)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
}

enum ToolError: Error {
    case timeout(String, TimeInterval)
}
