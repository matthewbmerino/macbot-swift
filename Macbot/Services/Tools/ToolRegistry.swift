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
        "finance": (["stock", "price", "market", "ticker", "portfolio", "dow", "nasdaq"], ["get_stock_price", "get_stock_history", "get_market_summary"]),
        "browser": (["browse", "website", "visit", "go to", "http://", "https://"], ["browse_url", "browse_and_act", "screenshot_url"]),
        "web": (["search", "look up", "find out", "what is", "who is", "latest", "news"], ["web_search", "fetch_page"]),
        "files": (["file", "read", "write", "folder", "directory", "create file"], ["read_file", "write_file", "list_directory", "search_files"]),
        "chart": (["chart", "graph", "plot", "visualize", "diagram"], ["generate_chart"]),
        "macos": (["screenshot", "clipboard", "open app", "volume", "notification", "what apps", "running apps", "battery", "system info"], ["take_screenshot", "open_app", "open_url", "send_notification", "get_clipboard", "set_clipboard", "list_running_apps", "get_system_info"]),
        "code": (["run python", "execute", "script", "run code"], ["run_python", "run_command"]),
        "memory": (["remember", "memory", "recall", "forget", "what do you know"], ["memory_save", "memory_recall", "memory_search", "memory_forget"]),
        "knowledge": (["document", "knowledge", "ingest", "rag", "what does the doc", "from my files", "in my notes"], ["ingest_file", "ingest_directory", "knowledge_search"]),
    ]

    /// Filter tools to 3-5 relevant ones based on message content.
    func filteredSpecsAsJSON(for message: String, recentTools: [String] = []) -> [[String: Any]] {
        let lower = message.lowercased()
        var matchedNames = Set<String>()

        for (_, group) in Self.toolGroups {
            if group.keywords.contains(where: { lower.contains($0) }) {
                matchedNames.formUnion(group.tools)
            }
        }

        // Recency bias
        matchedNames.formUnion(recentTools)

        // Default fallback
        if matchedNames.isEmpty {
            matchedNames = ["web_search", "memory_recall", "run_command"]
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
            return (name, "Unknown tool: \(name)")
        }

        // Fire pre-tool hook
        await HookSystem.shared.fireAsync(HookContext.make(
            event: .toolStart, toolName: name, toolArgs: arguments
        ))

        do {
            let result = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await handler(arguments)
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

            return (name, result)
        } catch is ToolError {
            let err = "Error: tool '\(name)' timed out after \(Int(Self.toolTimeout))s"
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
