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
    var toolArgs: [String: Any] = [:]
    var result: String = ""
    var error: String = ""
    var metadata: [String: String] = [:]

    // Sendable workaround — toolArgs can't be Sendable as [String: Any]
    // In practice, we only read these values, never mutate across threads
    static func make(
        event: HookEvent,
        agentName: String = "",
        toolName: String = "",
        toolArgs: [String: Any] = [:],
        result: String = "",
        error: String = "",
        metadata: [String: String] = [:]
    ) -> HookContext {
        HookContext(
            event: event, agentName: agentName, toolName: toolName,
            toolArgs: toolArgs, result: result, error: error, metadata: metadata
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
