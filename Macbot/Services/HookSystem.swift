import Foundation

// MARK: - Events

enum HookEvent: String, CaseIterable {
    // Tool lifecycle
    case toolStart
    case toolComplete
    case toolError

    // Message lifecycle
    case messageReceived
    case responseStart
    case responseComplete

    // Agent lifecycle
    case agentSelected
    case agentSwitch

    // Session lifecycle
    case sessionStart
    case sessionEnd

    // Planning
    case planGenerated
    case planStepStart
    case planStepComplete

    // Content
    case imageGenerated
    case statusUpdate
}

// MARK: - Context

struct HookContext: Sendable {
    let event: HookEvent
    var agentName: String = ""
    var toolName: String = ""
    /// JSON-encoded tool arguments. Stored as a `String` so the whole
    /// `HookContext` is cleanly `Sendable` under Swift 6 strict concurrency
    /// — `[String: Any]` cannot be, and wrapping the dictionary value in
    /// `any Sendable` still leaves the individual values untyped. Hook
    /// handlers that need the decoded form can call `toolArgsDict`.
    var toolArgsJSON: String = "{}"
    var result: String = ""
    var error: String = ""
    var metadata: [String: String] = [:]

    /// Best-effort decoded view of the tool arguments. Returns an empty
    /// dictionary if the JSON cannot be parsed. Handlers that need typed
    /// access should cast values as normal.
    var toolArgsDict: [String: Any] {
        guard let data = toolArgsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Factory that accepts a live `[String: Any]` args dict and serializes
    /// it to JSON at the `HookContext` boundary. Non-JSON-representable
    /// values (closures, class instances) are dropped on the floor — hook
    /// payloads are for logging, not state transfer, so this is intended.
    static func make(
        event: HookEvent,
        agentName: String = "",
        toolName: String = "",
        toolArgs: [String: Any] = [:],
        result: String = "",
        error: String = "",
        metadata: [String: String] = [:]
    ) -> HookContext {
        let json: String
        if toolArgs.isEmpty {
            json = "{}"
        } else if JSONSerialization.isValidJSONObject(toolArgs),
                  let data = try? JSONSerialization.data(withJSONObject: toolArgs, options: []),
                  let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            // Fallback: stringify each value so we at least preserve shape
            // for logging even when values aren't JSON-native.
            let stringified = toolArgs.mapValues { "\($0)" }
            if let data = try? JSONSerialization.data(withJSONObject: stringified, options: []),
               let str = String(data: data, encoding: .utf8) {
                json = str
            } else {
                json = "{}"
            }
        }
        return HookContext(
            event: event, agentName: agentName, toolName: toolName,
            toolArgsJSON: json, result: result, error: error, metadata: metadata
        )
    }
}

// MARK: - Hook System

typealias HookHandler = @Sendable (HookContext) -> Void
typealias AsyncHookHandler = @Sendable (HookContext) async -> Void

final class HookSystem: @unchecked Sendable {
    static let shared = HookSystem()

    private var syncHandlers: [HookEvent: [HookHandler]] = [:]
    private var asyncHandlers: [HookEvent: [AsyncHookHandler]] = [:]

    private init() {
        registerDefaults()
    }

    func on(_ event: HookEvent, handler: @escaping HookHandler) {
        if syncHandlers[event] == nil { syncHandlers[event] = [] }
        syncHandlers[event]?.append(handler)
    }

    func onAsync(_ event: HookEvent, handler: @escaping AsyncHookHandler) {
        if asyncHandlers[event] == nil { asyncHandlers[event] = [] }
        asyncHandlers[event]?.append(handler)
    }

    func fire(_ ctx: HookContext) {
        for handler in syncHandlers[ctx.event] ?? [] {
            handler(ctx)
        }
    }

    func fireAsync(_ ctx: HookContext) async {
        fire(ctx)
        for handler in asyncHandlers[ctx.event] ?? [] {
            await handler(ctx)
        }
    }

    // MARK: - Default Handlers

    private func registerDefaults() {
        on(.toolStart) { ctx in
            Log.tools.info("[\(ctx.agentName)] calling: \(ctx.toolName)")
        }
        on(.toolComplete) { ctx in
            let preview = String(ctx.result.prefix(100))
            Log.tools.info("[\(ctx.agentName)] result: \(ctx.toolName) -> \(preview)")
        }
        on(.toolError) { ctx in
            Log.tools.error("[\(ctx.agentName)] error: \(ctx.toolName) -> \(ctx.error)")
        }
        on(.agentSelected) { ctx in
            Log.agents.info("[orchestrator] -> \(ctx.agentName)")
        }
    }
}
