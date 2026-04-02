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
