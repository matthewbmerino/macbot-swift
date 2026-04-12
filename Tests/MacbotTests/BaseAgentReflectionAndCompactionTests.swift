import XCTest
@testable import Macbot

/// Coverage for two branches of `BaseAgent.runStream` that are NOT exercised
/// by `BaseAgentStreamToolLoopTests`:
///
/// 1. The ReAct reflection path (`reflectionEnabled == true`). After the
///    number of tool calls crosses `reflectionThreshold`, the agent makes an
///    extra `client.chat(...)` sub-call against the reflection model and
///    inspects the verdict ("CONTINUE" vs "SUFFICIENT"). On "SUFFICIENT"
///    (or on reflection failure) it injects a synthesis nudge as a system
///    message; on "CONTINUE" it injects nothing and the main loop continues
///    naturally. The existing stream loop tests disable reflection wholesale
///    (`agent.reflectionEnabled = false`) specifically to avoid this path —
///    which means the whole branch was unlocked in CI until now.
///
/// 2. The `trimHistory` / compaction branch. When `tokenCount` exceeds 75%
///    of `numCtx` on the next iteration, `runStream` calls `trimHistory()`,
///    which (a) summarizes the middle of the conversation via an extra
///    `client.chat(...)` sub-call to the small summarization model,
///    (b) keeps the system message first, and (c) keeps the last 4 messages
///    intact as the tail. The compaction path has never had a test — we
///    only knew it compiled.
///
/// Both paths are driven through the real `BaseAgent.runStream`
/// implementation by injecting a scripted `InferenceProvider` fake. This
/// mirrors the approach in `BaseAgentStreamToolLoopTests` but cannot reuse
/// its provider (the existing provider is private to that test file, and
/// we also need to capture the per-call `model` argument so we can
/// distinguish main-loop chats from reflection/summarization sub-chats).
final class BaseAgentReflectionAndCompactionTests: XCTestCase {

    // MARK: - Scripted inference provider

    /// Scripted fake for `InferenceProvider.chat`. Captures the model,
    /// messages and tools passed into every call so tests can assert on
    /// which sub-chat was made (main loop vs reflection vs summarization).
    ///
    /// This is a *local copy* of the pattern in
    /// `BaseAgentStreamToolLoopTests.ScriptedInferenceProvider`. It's
    /// intentionally duplicated because that type is file-private and
    /// these tests need extra capture hooks (model name, call count by
    /// model) that the other file doesn't.
    private final class ScriptedInferenceProvider: InferenceProvider,
                                                   @unchecked Sendable {
        /// Canned responses, popped front-to-back.
        var queue: [ChatResponse] = []
        /// Per-call captured `model` string.
        var capturedModels: [String] = []
        /// Per-call captured `messages` snapshot.
        var capturedMessages: [[[String: Any]]] = []
        /// Per-call captured `tools` snapshot.
        var capturedTools: [[[String: Any]]?] = []
        /// Throw on a specific call index (0-based). If nil, never throws.
        var throwOnCall: Int?
        /// Optional: throw only on calls whose `model` matches this string.
        /// Used by the "reflection throws" test so we can fail the
        /// reflection sub-chat without touching main-loop calls.
        var throwOnModelContains: String?
        var throwError: Error = ScriptedError.boom
        var chatCallCount: Int { capturedModels.count }

        enum ScriptedError: Error, Equatable { case boom, empty }

        func chat(
            model: String,
            messages: [[String: Any]],
            tools: [[String: Any]]?,
            temperature: Double,
            numCtx: Int,
            timeout: TimeInterval?
        ) async throws -> ChatResponse {
            capturedModels.append(model)
            capturedMessages.append(messages)
            capturedTools.append(tools)
            let idx = capturedModels.count - 1
            if let throwIdx = throwOnCall, throwIdx == idx {
                throw throwError
            }
            if let needle = throwOnModelContains, model.contains(needle) {
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

    private func toolCallResponse(
        _ calls: [(name: String, args: [String: Any])]
    ) -> ChatResponse {
        let dicts: [[String: Any]] = calls.map { call in
            [
                "function": [
                    "name": call.name,
                    "arguments": call.args,
                ] as [String: Any]
            ]
        }
        return ChatResponse(content: "", toolCalls: dicts)
    }

    private func finalResponse(_ text: String) -> ChatResponse {
        ChatResponse(content: text, toolCalls: nil)
    }

    /// Build a BaseAgent wired to the scripted provider. `reflectionEnabled`
    /// and `numCtx` can be overridden per-test.
    private func makeAgent(
        provider: ScriptedInferenceProvider,
        reflectionEnabled: Bool = true,
        numCtx: Int = 4096
    ) -> BaseAgent {
        let agent = BaseAgent(
            name: "ReflectCompactAgent",
            model: "test-model",
            systemPrompt: "YOU ARE A TEST AGENT.",
            temperature: 0.5,
            numCtx: numCtx,
            client: provider
        )
        agent.reflectionEnabled = reflectionEnabled
        return agent
    }

    /// Tracks tool invocations from the fake tool handlers.
    private final class ToolCallLog: @unchecked Sendable {
        var calls: [(name: String, args: [String: Any])] = []
        let lock = NSLock()
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

    private func texts(_ events: [StreamEvent]) -> [String] {
        events.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
    }

    /// Count of messages in `messages` that (a) have role == "system"
    /// and (b) contain `needle` in their content. Used to assert that the
    /// "you have gathered enough information" nudge injected by reflection
    /// is (or isn't) present in the next main-loop turn.
    private func countSystemMessagesContaining(
        _ messages: [[String: Any]],
        _ needle: String
    ) -> Int {
        messages.filter {
            ($0["role"] as? String) == "system"
                && (($0["content"] as? String) ?? "").contains(needle)
        }.count
    }

    // MARK: - Reflection path tests

    /// 1. Reflection fires and says SUFFICIENT. The model emits 3 tool calls
    /// in one response (which pushes totalToolCalls to the threshold of 3).
    /// After tool execution, the reflection sub-chat runs against the
    /// reflection model ("qwen3.5:0.8b"), returns "SUFFICIENT", and the
    /// production code appends a synthesis-nudge system message.
    ///
    /// Contract verified here:
    ///   - the reflection sub-chat IS actually issued (we see a call with
    ///     model containing "qwen")
    ///   - the "You have gathered enough information..." nudge lands in
    ///     history before the next main-loop chat call
    ///   - the loop still finishes cleanly and yields the final answer
    func testReflectionFiresOnSufficientVerdictAndInjectsNudge() async {
        let provider = ScriptedInferenceProvider()
        // Call order:
        //   [0] main iter 0: model asks for 3 tool calls
        //   [1] reflection sub-chat: "SUFFICIENT"
        //   [2] main iter 1: final answer
        provider.queue = [
            toolCallResponse([
                (name: "tool_a", args: [:]),
                (name: "tool_b", args: [:]),
                (name: "tool_c", args: [:]),
            ]),
            finalResponse("SUFFICIENT"),
            finalResponse("final synthesized answer"),
        ]

        let agent = makeAgent(provider: provider, reflectionEnabled: true)
        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "tool_a", log: log) { _ in "A_OUT" }
        await registerFakeTool(on: agent, name: "tool_b", log: log) { _ in "B_OUT" }
        await registerFakeTool(on: agent, name: "tool_c", log: log) { _ in "C_OUT" }

        let (events, err) = await drain(agent.runStream("hit threshold"))

        XCTAssertNil(err)
        XCTAssertEqual(texts(events), ["final synthesized answer"])
        XCTAssertEqual(provider.chatCallCount, 3,
            "main(0) + reflection + main(1) = 3 chat calls")
        XCTAssertEqual(log.calls.count, 3,
            "all three tools must have executed before reflection")

        // Assert call 1 was the reflection sub-chat. Production uses a
        // `qwen3.5:0.8b` model name for reflection — distinct from the main
        // agent model, so we can identify it positionally.
        XCTAssertTrue(
            provider.capturedModels[1].contains("qwen"),
            "second chat call must be the reflection sub-chat, got model=\(provider.capturedModels[1])"
        )
        // And main calls 0 and 2 use the agent's own model.
        XCTAssertEqual(provider.capturedModels[0], "test-model")
        XCTAssertEqual(provider.capturedModels[2], "test-model")

        // The synthesis nudge must have been injected into history before
        // the final main-loop chat. It's a system message whose content
        // contains "gathered enough information".
        let finalTurnMessages = provider.capturedMessages[2]
        XCTAssertEqual(
            countSystemMessagesContaining(finalTurnMessages, "gathered enough information"),
            1,
            "SUFFICIENT verdict must inject exactly one 'gathered enough information' nudge"
        )
    }

    /// 2. Reflection fires and says CONTINUE. Same scripted 3-tool-call
    /// setup as (1), but this time the reflection sub-chat replies
    /// "CONTINUE". Production contract:
    ///   - reflection IS still invoked
    ///   - no synthesis nudge is appended (production only appends on
    ///     `!shouldContinue`)
    ///   - the next main-loop call proceeds with unchanged system context
    ///     and can decide for itself whether to keep calling tools
    func testReflectionFiresOnContinueVerdictAndDoesNotInjectNudge() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [
            toolCallResponse([
                (name: "tool_a", args: [:]),
                (name: "tool_b", args: [:]),
                (name: "tool_c", args: [:]),
            ]),
            finalResponse("CONTINUE"),
            finalResponse("eventual answer"),
        ]

        let agent = makeAgent(provider: provider, reflectionEnabled: true)
        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "tool_a", log: log) { _ in "A_OUT" }
        await registerFakeTool(on: agent, name: "tool_b", log: log) { _ in "B_OUT" }
        await registerFakeTool(on: agent, name: "tool_c", log: log) { _ in "C_OUT" }

        let (events, err) = await drain(agent.runStream("hit threshold"))

        XCTAssertNil(err)
        XCTAssertEqual(texts(events), ["eventual answer"])
        XCTAssertEqual(provider.chatCallCount, 3)

        // Reflection sub-chat happened at call index 1.
        XCTAssertTrue(provider.capturedModels[1].contains("qwen"),
            "reflection must be invoked even on CONTINUE")

        // Crucially: no synthesis nudge gets appended on CONTINUE.
        let finalTurnMessages = provider.capturedMessages[2]
        XCTAssertEqual(
            countSystemMessagesContaining(finalTurnMessages, "gathered enough information"),
            0,
            "CONTINUE verdict must NOT inject the synthesis nudge"
        )
    }

    /// 3. Reflection disabled: the toggle actually gates the sub-call. Same
    /// scripted 3-tool-call turn, but with `reflectionEnabled = false`. The
    /// reflection sub-chat must NEVER be issued — only main-loop calls run.
    /// This proves the toggle gates the `client.chat` invocation itself,
    /// not just downstream logic.
    func testReflectionDisabledPreventsSubChatEntirely() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [
            toolCallResponse([
                (name: "tool_a", args: [:]),
                (name: "tool_b", args: [:]),
                (name: "tool_c", args: [:]),
            ]),
            finalResponse("direct answer"),
        ]

        let agent = makeAgent(provider: provider, reflectionEnabled: false)
        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "tool_a", log: log) { _ in "A_OUT" }
        await registerFakeTool(on: agent, name: "tool_b", log: log) { _ in "B_OUT" }
        await registerFakeTool(on: agent, name: "tool_c", log: log) { _ in "C_OUT" }

        let (events, err) = await drain(agent.runStream("no reflection please"))

        XCTAssertNil(err)
        XCTAssertEqual(texts(events), ["direct answer"])
        XCTAssertEqual(provider.chatCallCount, 2,
            "only main chat calls when reflection is disabled: main(0) + main(1)")
        // Both calls must use the primary model — no "qwen" sub-chat.
        for model in provider.capturedModels {
            XCTAssertFalse(model.contains("qwen"),
                "reflection-disabled run must never hit the reflection model, saw: \(model)")
        }
        // And no synthesis nudge ever gets injected.
        let finalTurnMessages = provider.capturedMessages[1]
        XCTAssertEqual(
            countSystemMessagesContaining(finalTurnMessages, "gathered enough information"),
            0
        )
    }

    /// 4. Reflection sub-chat throws. Production contract (read directly
    /// from `reflect(...)` in BaseAgent.swift): the throw is caught inside
    /// `reflect`, which logs a warning and returns `false` (i.e. "not
    /// shouldContinue"). The outer loop then treats this exactly like a
    /// SUFFICIENT verdict — it injects the synthesis nudge and keeps going.
    /// The failure must NOT propagate out of the stream.
    func testReflectionFailureIsSwallowedAndTreatedAsSufficient() async {
        let provider = ScriptedInferenceProvider()
        // Queue only has responses for main calls. The reflection call will
        // be rejected by `throwOnModelContains` before hitting the queue.
        provider.queue = [
            toolCallResponse([
                (name: "tool_a", args: [:]),
                (name: "tool_b", args: [:]),
                (name: "tool_c", args: [:]),
            ]),
            finalResponse("answer after reflection failure"),
        ]
        provider.throwOnModelContains = "qwen"

        let agent = makeAgent(provider: provider, reflectionEnabled: true)
        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "tool_a", log: log) { _ in "A_OUT" }
        await registerFakeTool(on: agent, name: "tool_b", log: log) { _ in "B_OUT" }
        await registerFakeTool(on: agent, name: "tool_c", log: log) { _ in "C_OUT" }

        let (events, err) = await drain(agent.runStream("reflection will blow up"))

        // No error escapes the stream.
        XCTAssertNil(err,
            "reflection sub-chat failure must be swallowed, not propagated")
        XCTAssertEqual(texts(events), ["answer after reflection failure"])

        // Three calls happened: main(0), failed-reflection, main(1).
        XCTAssertEqual(provider.chatCallCount, 3)
        XCTAssertTrue(provider.capturedModels[1].contains("qwen"),
            "the failed call should be the reflection sub-chat")

        // Failure is treated as "stop / synthesize" — same as SUFFICIENT —
        // so the nudge appears in the next main turn's prompt.
        let finalTurnMessages = provider.capturedMessages[2]
        XCTAssertEqual(
            countSystemMessagesContaining(finalTurnMessages, "gathered enough information"),
            1,
            "reflection failure should inject the synthesis nudge (defaults to shouldContinue=false)"
        )
    }

    // MARK: - History compaction tests

    /// Build a transcript with `turnCount` user/assistant pairs, each
    /// message padded enough that token estimation will exceed the budget
    /// for small numCtx values. Returned messages don't include a system
    /// prompt (BaseAgent's `loadHistoryFromTranscript` prepends its own).
    private func paddedTranscript(turnCount: Int) -> [[String: Any]] {
        var out: [[String: Any]] = []
        // Each message is ~80 words of prose, so TokenEstimator rates each
        // at roughly ~100 tokens. With numCtx=256 (budget ~192 tokens),
        // even two messages will blow past the budget.
        let padding = String(repeating: "lorem ipsum dolor sit amet ", count: 20)
        for i in 0..<turnCount {
            out.append([
                "role": "user",
                "content": "user turn \(i) \(padding)",
            ])
            out.append([
                "role": "assistant",
                "content": "assistant reply \(i) \(padding)",
            ])
        }
        return out
    }

    /// 5. Compaction fires at threshold. We pre-load a large transcript
    /// (12 user/asst messages) with a small numCtx (256) so the first
    /// iteration's token-count check trips the trim. Production contract:
    ///   - `trimHistory` is invoked, which calls `client.chat(...)` with
    ///     the summarization model (containing "qwen")
    ///   - the subsequent main-loop chat sees strictly FEWER messages
    ///     than the pre-trim history
    ///   - a summary system message ("Conversation summary so far") is
    ///     injected into the trimmed history when summarization succeeds
    func testCompactionFiresWhenTokenCountExceedsBudget() async {
        let provider = ScriptedInferenceProvider()
        // Call order (expected):
        //   [0] summarization sub-chat -> returns a short summary
        //   [1] main iter 0 -> final answer (no tools)
        provider.queue = [
            finalResponse("short conversation summary"),
            finalResponse("post-compaction answer"),
        ]

        // Small numCtx so 75% budget is ~192 tokens — easily exceeded by
        // the padded transcript below.
        let agent = makeAgent(
            provider: provider,
            reflectionEnabled: false,
            numCtx: 256
        )
        let transcript = paddedTranscript(turnCount: 6) // 12 messages
        agent.loadHistoryFromTranscript(transcript)
        let preUserHistoryCount = agent.history.count // = 1 system + 12 = 13

        let (events, err) = await drain(agent.runStream("final user query"))

        XCTAssertNil(err)
        XCTAssertEqual(texts(events), ["post-compaction answer"])

        // Two chat calls: summarization + main.
        XCTAssertEqual(provider.chatCallCount, 2,
            "compaction path: summarization sub-chat + main-loop chat")

        // Call 0 should be summarization (qwen model).
        XCTAssertTrue(provider.capturedModels[0].contains("qwen"),
            "first chat must be the summarization sub-chat, got \(provider.capturedModels[0])")
        // Call 1 should be the main-loop call.
        XCTAssertEqual(provider.capturedModels[1], "test-model")

        // The messages handed to the main-loop call must be strictly
        // smaller than the pre-trim history (original 13 + 1 new user
        // message = 14).
        let mainTurnMessages = provider.capturedMessages[1]
        XCTAssertLessThan(
            mainTurnMessages.count, preUserHistoryCount + 1,
            "post-compaction history must be shorter than pre-compaction history"
        )

        // And the summary line must be present as a system message.
        XCTAssertGreaterThanOrEqual(
            countSystemMessagesContaining(mainTurnMessages, "Conversation summary so far"),
            1,
            "a successful summarization must land as a 'Conversation summary so far' system message"
        )
    }

    /// 6. After compaction, the system prompt is still first, and the
    /// last 4 pre-trim messages are preserved verbatim as the tail.
    /// Production contract (from `trimHistory`):
    ///   new history = [systemMsg, optional summaryMsg, ...suffix(4)]
    /// So given pre-trim history `[sys, t1, ..., t12, user]` (14 msgs), the
    /// tail is `[t10, t11, t12, user]`.
    func testCompactionPreservesSystemPromptAndRecentTail() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [
            finalResponse("summary text"),
            finalResponse("final"),
        ]

        let agent = makeAgent(
            provider: provider,
            reflectionEnabled: false,
            numCtx: 256
        )

        // Build a transcript with distinctive markers in the LAST three
        // messages so we can verify they survive the trim.
        var transcript = paddedTranscript(turnCount: 5) // 10 messages
        transcript.append(["role": "user", "content": "KEEP_ME_SECOND_TO_LAST"])
        transcript.append(["role": "assistant", "content": "KEEP_ME_LAST"])
        agent.loadHistoryFromTranscript(transcript)

        let (_, err) = await drain(agent.runStream("KEEP_ME_USER_MESSAGE"))
        XCTAssertNil(err)
        XCTAssertEqual(provider.chatCallCount, 2)

        let mainTurnMessages = provider.capturedMessages[1]

        // System prompt (the real agent-configured systemPrompt, with the
        // anti-fabrication clause appended by init) must still be at index 0.
        XCTAssertEqual(
            mainTurnMessages.first?["role"] as? String, "system",
            "system message must still be first after compaction"
        )
        let firstContent = (mainTurnMessages.first?["content"] as? String) ?? ""
        XCTAssertTrue(firstContent.contains("TEST AGENT"),
            "the original agent system prompt must be preserved at index 0")

        // Collect all message contents into a single haystack.
        let allContents = mainTurnMessages
            .compactMap { $0["content"] as? String }
            .joined(separator: "\n")

        // The final user message (added by runStream right before the
        // first iteration) must survive the trim: it's part of suffix(4).
        XCTAssertTrue(allContents.contains("KEEP_ME_USER_MESSAGE"),
            "the current-turn user message must survive compaction")
        // And the last two transcript messages must also survive —
        // `suffix(4)` captures [t11, t12, ... last loaded msg, user_msg].
        XCTAssertTrue(allContents.contains("KEEP_ME_LAST"),
            "most-recent assistant message must be in the trimmed tail")
        XCTAssertTrue(allContents.contains("KEEP_ME_SECOND_TO_LAST"),
            "second-most-recent message must be in the trimmed tail")
    }

    /// 7. Below threshold → no compaction. With numCtx=4096 and a short
    /// transcript, `tokenCount` never approaches the 75% budget, so
    /// `trimHistory` must not fire. Production contract:
    ///   - no summarization sub-chat is issued
    ///   - the main-loop call sees every pre-loaded message intact
    func testCompactionDoesNotFireBelowThreshold() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [finalResponse("answer without compaction")]

        let agent = makeAgent(
            provider: provider,
            reflectionEnabled: false,
            numCtx: 4096
        )
        let transcript: [[String: Any]] = [
            ["role": "user", "content": "UNIQUE_MARKER_ONE"],
            ["role": "assistant", "content": "UNIQUE_MARKER_TWO"],
            ["role": "user", "content": "UNIQUE_MARKER_THREE"],
            ["role": "assistant", "content": "UNIQUE_MARKER_FOUR"],
        ]
        agent.loadHistoryFromTranscript(transcript)

        let (events, err) = await drain(agent.runStream("new query"))

        XCTAssertNil(err)
        XCTAssertEqual(texts(events), ["answer without compaction"])

        // Exactly one chat call — the main loop. No summarization.
        XCTAssertEqual(provider.chatCallCount, 1,
            "no compaction expected, so no summarization sub-chat should fire")
        XCTAssertEqual(provider.capturedModels[0], "test-model")

        // Every original marker must reach the main-loop chat unchanged.
        let mainTurnMessages = provider.capturedMessages[0]
        let allContents = mainTurnMessages
            .compactMap { $0["content"] as? String }
            .joined(separator: "\n")
        for marker in ["UNIQUE_MARKER_ONE", "UNIQUE_MARKER_TWO",
                       "UNIQUE_MARKER_THREE", "UNIQUE_MARKER_FOUR"] {
            XCTAssertTrue(allContents.contains(marker),
                "below-threshold runs must preserve every loaded message; missing \(marker)")
        }
        // And there must be no "Conversation summary so far" system message.
        XCTAssertEqual(
            countSystemMessagesContaining(mainTurnMessages, "Conversation summary so far"),
            0,
            "no summary system message should be present when compaction didn't fire"
        )
    }
}
