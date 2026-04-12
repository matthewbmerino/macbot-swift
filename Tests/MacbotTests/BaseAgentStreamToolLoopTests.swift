import XCTest
@testable import Macbot

/// Coverage for `BaseAgent.runStream`'s multi-turn, ReAct-style tool loop.
///
/// `StreamingCommandHandlerTests` already covers the command handler's
/// *wrapping* of `runStream` — but it does so with a ScriptedAgent subclass
/// that overrides `runStream` wholesale, bypassing the real loop entirely.
/// Prior to this file, the only coverage of the actual loop was via a live
/// Ollama integration harness, which means every iteration of the real
/// parse-calls → execute-tools → feed-results-back → repeat state machine
/// was unverified in CI.
///
/// These tests drive the *real* `BaseAgent.runStream` implementation end
/// to end by injecting a scripted `InferenceProvider` fake that replays a
/// queue of canned `ChatResponse`s per turn, plus a fake tool registered
/// into the agent's own `ToolRegistry`. The loop's real logic executes
/// unmodified; only the inference provider and the tool handler are
/// stubbed. This is the right seam to lock in the contract.
final class BaseAgentStreamToolLoopTests: XCTestCase {

    // MARK: - Scripted inference provider

    /// Scripted replacement for `InferenceProvider.chat`. Each call pops a
    /// response off `queue`, captures the messages/tools it was handed so
    /// tests can assert on conversation state per turn, and optionally
    /// throws at a specific turn index.
    ///
    /// Kept local so we don't destabilize the shared `MockInferenceProvider`
    /// used by routers/memory tests.
    private final class ScriptedInferenceProvider: InferenceProvider,
                                                   @unchecked Sendable {
        /// Queue of canned responses for `chat(...)`. Popped front-to-back.
        var queue: [ChatResponse] = []
        /// Snapshots of the `messages` array passed to each `chat` call.
        var capturedMessages: [[[String: Any]]] = []
        /// Snapshots of the `tools` array passed to each `chat` call.
        var capturedTools: [[[String: Any]]?] = []
        /// Index into the sequence of chat calls. 0 = first call.
        var chatCallCount: Int { capturedMessages.count }
        /// If set, `chat` throws `throwError` on the turn whose index is in
        /// `throwOnTurn` (0-indexed).
        var throwOnTurn: Int?
        var throwError: Error = ScriptedError.boom

        enum ScriptedError: Error, Equatable { case boom, empty }

        func chat(
            model: String,
            messages: [[String: Any]],
            tools: [[String: Any]]?,
            temperature: Double,
            numCtx: Int,
            timeout: TimeInterval?
        ) async throws -> ChatResponse {
            capturedMessages.append(messages)
            capturedTools.append(tools)
            let turn = capturedMessages.count - 1
            if throwOnTurn == turn {
                throw throwError
            }
            guard !queue.isEmpty else {
                throw ScriptedError.empty
            }
            return queue.removeFirst()
        }

        func chatStream(
            model: String,
            messages: [[String: Any]],
            temperature: Double,
            numCtx: Int
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func embed(model: String, text: [String]) async throws -> [[Float]] {
            text.map { _ in [Float](repeating: 0, count: 8) }
        }

        func listModels() async throws -> [ModelInfo] { [] }
        func warmModel(_ model: String) async throws {}
    }

    // MARK: - Helpers

    /// Build a canned assistant response that requests one or more tool calls.
    private func toolCallResponse(
        _ calls: [(name: String, args: [String: Any])]
    ) -> ChatResponse {
        let callDicts: [[String: Any]] = calls.map { call in
            [
                "function": [
                    "name": call.name,
                    "arguments": call.args,
                ] as [String: Any]
            ]
        }
        return ChatResponse(content: "", toolCalls: callDicts)
    }

    /// Build a canned "final answer" response with no tool calls.
    private func finalResponse(_ text: String) -> ChatResponse {
        ChatResponse(content: text, toolCalls: nil)
    }

    /// Factory for a `BaseAgent` wired to the scripted provider, with
    /// reflection disabled so we don't need to script extra chat calls for
    /// the ReAct reflection sub-chat. Reflection is covered separately.
    private func makeAgent(
        provider: ScriptedInferenceProvider
    ) -> BaseAgent {
        let agent = BaseAgent(
            name: "TestAgent",
            model: "test-model",
            systemPrompt: "YOU ARE A TEST AGENT.",
            temperature: 0.5,
            numCtx: 4096,
            client: provider
        )
        // Reflection would call `client.chat` with a sub-model on the 3rd+
        // tool call and eat up our scripted queue. Turn it off so these
        // tests isolate the main loop.
        agent.reflectionEnabled = false
        return agent
    }

    /// Register a fake tool directly on the agent's `ToolRegistry`. Tracks
    /// invocations in the returned box so tests can assert on arg values
    /// and call ordering.
    private final class ToolCallLog: @unchecked Sendable {
        var calls: [(name: String, args: [String: Any])] = []
        var lock = NSLock()
        func record(_ name: String, _ args: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            calls.append((name, args))
        }
    }

    private func registerFakeTool(
        on agent: BaseAgent,
        name: String,
        log: ToolCallLog,
        result: @escaping (ToolArguments) throws -> String
    ) async {
        let spec = ToolSpec(name: name, description: "fake \(name)", properties: [:])
        await agent.toolRegistry.register(spec) { args in
            log.record(name, args)
            return try result(args)
        }
    }

    /// Drain a stream into (events, optional error).
    private func drain(
        _ stream: AsyncThrowingStream<StreamEvent, Error>
    ) async -> (events: [StreamEvent], error: Error?) {
        var out: [StreamEvent] = []
        do {
            for try await e in stream { out.append(e) }
            return (out, nil)
        } catch {
            return (out, error)
        }
    }

    /// Extract just the `.text` payloads from a stream's events.
    private func texts(_ events: [StreamEvent]) -> [String] {
        events.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
    }

    // MARK: - Tests

    /// 1. Zero-tool path. The fake model returns a final answer on the very
    /// first turn with no tool calls. The loop should yield that text
    /// exactly once, finish cleanly, and never call the tool handler.
    /// Regression guard against anything that would re-enter the loop on a
    /// tool-free response.
    func testFirstTurnFinalResponseYieldsTextAndExits() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [finalResponse("hello world")]
        let agent = makeAgent(provider: provider)

        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "fake_echo", log: log) { _ in "unused" }

        let (events, err) = await drain(agent.runStream("ping"))

        XCTAssertNil(err)
        XCTAssertEqual(texts(events), ["hello world"])
        XCTAssertEqual(provider.chatCallCount, 1,
            "a tool-free first turn should consume exactly one model call")
        XCTAssertTrue(log.calls.isEmpty,
            "no tool calls from the model → handler must not run")
    }

    /// 2. Single tool call → result → final response. Turn 1 emits a tool
    /// call; the loop must execute the tool, append its result to history
    /// as a "tool" role message, and feed it back into the next model call.
    /// Turn 2 emits the final answer. We verify the tool ran once with the
    /// right args and that the captured turn-2 messages include the tool
    /// result appended by the loop.
    func testSingleToolCallFeedsResultIntoNextModelCall() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [
            toolCallResponse([(name: "fake_lookup", args: ["q": "swift"])]),
            finalResponse("found: result-for-swift"),
        ]
        let agent = makeAgent(provider: provider)

        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "fake_lookup", log: log) { args in
            let q = (args["q"] as? String) ?? "?"
            return "result-for-\(q)"
        }

        let (events, err) = await drain(agent.runStream("look up swift"))

        XCTAssertNil(err)
        XCTAssertEqual(texts(events), ["found: result-for-swift"])
        XCTAssertEqual(provider.chatCallCount, 2,
            "two turns: one tool-call turn + one synthesis turn")
        XCTAssertEqual(log.calls.count, 1, "tool must have been invoked exactly once")
        XCTAssertEqual(log.calls.first?.name, "fake_lookup")
        XCTAssertEqual(log.calls.first?.args["q"] as? String, "swift")

        // The second chat call's `messages` array must include a tool-role
        // message whose content is the tool's output. That is the essence
        // of the ReAct loop: tool output must make it back into the prompt.
        let turn2Messages = provider.capturedMessages[1]
        let toolRoleMessages = turn2Messages.filter {
            ($0["role"] as? String) == "tool"
        }
        XCTAssertEqual(toolRoleMessages.count, 1,
            "turn 2 should see exactly one tool-role message fed back from turn 1")
        XCTAssertEqual(
            toolRoleMessages.first?["content"] as? String,
            "result-for-swift",
            "tool result must be fed back verbatim to the next model turn"
        )
    }

    /// 3. Multi-step tool chain. Tool A on turn 1 → tool B on turn 2 →
    /// final answer on turn 3. Verifies (a) both tools ran in order, (b)
    /// turn 3's messages contain both tool outputs, (c) the final text is
    /// yielded. This locks the sequencing contract — if the loop ever
    /// started batching or reordering tool turns, this test would fail.
    func testMultiStepToolChainOrdersToolsAndFeedsBothResults() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [
            toolCallResponse([(name: "tool_a", args: ["x": "1"])]),
            toolCallResponse([(name: "tool_b", args: ["y": "2"])]),
            finalResponse("combined answer"),
        ]
        let agent = makeAgent(provider: provider)

        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "tool_a", log: log) { _ in "A_RESULT" }
        await registerFakeTool(on: agent, name: "tool_b", log: log) { _ in "B_RESULT" }

        let (events, err) = await drain(agent.runStream("chain it"))

        XCTAssertNil(err)
        XCTAssertEqual(texts(events), ["combined answer"])
        XCTAssertEqual(provider.chatCallCount, 3)
        XCTAssertEqual(log.calls.map(\.name), ["tool_a", "tool_b"],
            "tools must execute in the order the model requested them")

        // Turn 3's prompt must have the A and B tool results present.
        let turn3Messages = provider.capturedMessages[2]
        let toolRoleContents = turn3Messages
            .filter { ($0["role"] as? String) == "tool" }
            .compactMap { $0["content"] as? String }
        XCTAssertEqual(toolRoleContents, ["A_RESULT", "B_RESULT"],
            "both tool outputs must be present, in call order, on turn 3")
    }

    /// 4. Forced final synthesis — the `45d433b` regression guard. If the
    /// model keeps requesting tool calls forever, the loop must cap at
    /// `maxIterations` iterations, force a final no-tools synthesis call
    /// on the last iteration, and yield WHATEVER the model produces — not
    /// the dead-end "Max tool iterations reached" fallback string.
    ///
    /// We script 9 tool-calling turns and a 10th "final synthesis" turn
    /// (maxIterations == 10 private constant in BaseAgent). The expected
    /// contract:
    ///   - exactly `maxIterations` model calls happen
    ///   - the final call is made with `tools == nil` (no tools allowed)
    ///   - the text we emitted on that final call reaches the consumer
    ///   - no "Max tool iterations reached" string is ever yielded
    func testForcedFinalSynthesisOnMaxIterationsYieldsRealAnswer() async {
        let maxIterations = 10
        let provider = ScriptedInferenceProvider()
        // Turns 0..8 (9 turns) each request another tool call.
        var queue: [ChatResponse] = (0..<(maxIterations - 1)).map { _ in
            toolCallResponse([(name: "runaway", args: [:])])
        }
        // Turn 9 is the forced final synthesis. With `tools: nil` the loop
        // passes an empty tools arg, so the model is expected to produce
        // a regular text response — scripted here as "FORCED_ANSWER".
        queue.append(finalResponse("FORCED_ANSWER"))
        provider.queue = queue

        let agent = makeAgent(provider: provider)
        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "runaway", log: log) { _ in "stub" }

        let (events, err) = await drain(agent.runStream("go forever"))

        XCTAssertNil(err)
        XCTAssertEqual(provider.chatCallCount, maxIterations,
            "loop must call the model exactly maxIterations times")
        XCTAssertEqual(log.calls.count, maxIterations - 1,
            "tool should run on every non-final iteration")

        // The final turn must be called WITHOUT tools. This is the
        // explicit contract from commit 45d433b: "no tools allowed" on the
        // last iteration so the model is forced to answer.
        XCTAssertNil(provider.capturedTools.last ?? nil,
            "final synthesis turn must be called with tools == nil")

        // Forced answer must reach the consumer. Critically, the fallback
        // "Max tool iterations reached." string must NEVER appear — that
        // was the old broken behavior.
        let allText = texts(events).joined(separator: " ")
        XCTAssertTrue(allText.contains("FORCED_ANSWER"),
            "forced final synthesis text must be yielded; got: \(allText)")
        XCTAssertFalse(allText.contains("Max tool iterations reached"),
            "45d433b regression: dead-end fallback must not be yielded")
    }

    /// 5. Tool execution error. The fake tool throws. The production
    /// contract (read from ToolRegistry.execute): errors are caught inside
    /// the registry and returned as a `"Error: ..."` string, which the
    /// loop then appends to history as a tool-role message and continues
    /// the loop. The model must see the error string on the next turn.
    /// This test locks that "loop survives tool failure, error becomes
    /// part of the conversation" contract.
    func testToolErrorIsCapturedAndLoopContinues() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [
            toolCallResponse([(name: "will_fail", args: [:])]),
            finalResponse("recovered after failure"),
        ]
        let agent = makeAgent(provider: provider)

        struct BoomTool: Error, LocalizedError {
            var errorDescription: String? { "tool blew up" }
        }
        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "will_fail", log: log) { _ in
            throw BoomTool()
        }

        let (events, err) = await drain(agent.runStream("try the bad tool"))

        XCTAssertNil(err,
            "tool failures must not escape the stream as thrown errors")
        XCTAssertEqual(texts(events), ["recovered after failure"])
        // Registry retries on non-timeout failures, so the handler may be
        // called more than once. What matters is that the loop still
        // advanced to turn 2.
        XCTAssertGreaterThanOrEqual(log.calls.count, 1)
        XCTAssertEqual(provider.chatCallCount, 2,
            "loop must run a second turn after the tool error")

        // The error string must be present in turn 2's prompt as a
        // tool-role message so the model can react to it.
        let turn2 = provider.capturedMessages[1]
        let toolMessages = turn2
            .filter { ($0["role"] as? String) == "tool" }
            .compactMap { $0["content"] as? String }
        XCTAssertEqual(toolMessages.count, 1,
            "turn 2 must see exactly one tool-role message containing the error")
        XCTAssertTrue(
            toolMessages.first?.hasPrefix("Error:") ?? false,
            "tool error should be surfaced with an 'Error:' prefix; got: \(toolMessages.first ?? "nil")"
        )
    }

    /// 6. Model throws mid-loop. The provider's `chat` succeeds on turn 1
    /// (tool call) but throws on turn 2 (after the tool has run). The
    /// loop's contract on provider errors — verified by reading runStream
    /// — is that the error propagates out of the AsyncThrowingStream via
    /// `continuation.finish(throwing:)`. No silent swallow, no crash, and
    /// the tool was still invoked.
    func testProviderErrorMidLoopPropagatesAsStreamFailure() async {
        let provider = ScriptedInferenceProvider()
        // Turn 0: tool call. Turn 1: would be the final response, but the
        // provider throws before returning.
        provider.queue = [toolCallResponse([(name: "just_once", args: [:])])]
        provider.throwOnTurn = 1
        provider.throwError = ScriptedInferenceProvider.ScriptedError.boom

        let agent = makeAgent(provider: provider)
        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "just_once", log: log) { _ in "OK" }

        let (events, err) = await drain(agent.runStream("will die on turn 2"))

        // Error propagated out of the stream.
        XCTAssertNotNil(err, "provider error must propagate through the stream")
        if let e = err as? ScriptedInferenceProvider.ScriptedError {
            XCTAssertEqual(e, .boom)
        } else {
            XCTFail("expected ScriptedError.boom, got \(String(describing: err))")
        }

        // The tool was still executed before the provider error hit.
        XCTAssertEqual(log.calls.count, 1,
            "turn-1 tool should run before the turn-2 provider error")
        XCTAssertEqual(provider.chatCallCount, 2,
            "both chat calls should have been attempted")

        // No final text should have been yielded — the loop died before
        // producing a synthesis.
        XCTAssertTrue(texts(events).isEmpty,
            "no final text should appear when the synthesis call itself failed")
    }

    /// 7. Text response after a tool call. Verifies the "graceful exit on
    /// first text after tools" path distinct from (2): here the model uses
    /// a tool, sees the result, and on the next turn emits plain text (no
    /// more tool calls). Prior test (2) is essentially this pattern, but
    /// this test additionally locks that the loop does NOT run a third
    /// model call just because it could — it must exit the instant a
    /// toolCalls-free response is seen.
    func testLoopExitsImmediatelyOnFirstToolFreeResponse() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [
            toolCallResponse([(name: "probe", args: [:])]),
            finalResponse("answer"),
            // Canary: if the loop runs an extra turn, it'll consume this
            // and the assertion on chatCallCount will fail.
            finalResponse("SHOULD NEVER BE CALLED"),
        ]
        let agent = makeAgent(provider: provider)
        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "probe", log: log) { _ in "probed" }

        let (events, err) = await drain(agent.runStream("probe please"))

        XCTAssertNil(err)
        XCTAssertEqual(texts(events), ["answer"])
        XCTAssertEqual(provider.chatCallCount, 2,
            "loop must stop after the first tool-free response; canary turn must not execute")
        XCTAssertEqual(log.calls.count, 1)
    }
}
