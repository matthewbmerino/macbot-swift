import XCTest
@testable import Macbot

/// Wave 1 / Agent B: coverage for three `BaseAgent.runStream` branches that
/// the existing `BaseAgentStreamToolLoopTests` does not touch:
///
///  1. `learnedToolHints` recency-bias injection into the tool filter — i.e.
///     the Orchestrator-supplied k-NN tool hints must make it through to the
///     `tools` array passed to the model on turn 1 (and subsequent turns).
///  2. `[IMAGE:/abs/path]` marker extraction from **tool outputs** into
///     `.image` StreamEvents (the production path used by screenshot,
///     chart, QR, and image-generation tools).
///  3. The planning prelude triggered by `runStream(plan: true)` — an extra
///     pre-turn `chat` call is made to generate a numbered plan, the plan
///     is appended to history as a system message, and a `.status` event
///     is yielded summarising the estimated time.
///
/// These three features have never had unit coverage — only live-Ollama
/// integration exercise. This file locks the behaviour in fast, deterministic
/// tests using the same scripted-provider pattern as
/// `BaseAgentStreamToolLoopTests`. A local `ScriptedInferenceProvider` is
/// defined here on purpose to avoid coupling to the other file (which a
/// sibling agent is not permitted to edit).
final class BaseAgentHintsImagePlanTests: XCTestCase {

    // MARK: - Scripted inference provider (local copy)

    /// Replays a queue of canned `ChatResponse`s and captures every
    /// `messages` / `tools` argument pair it was handed, so tests can make
    /// per-turn assertions. Mirrors the one in
    /// `BaseAgentStreamToolLoopTests`, kept local because the two test files
    /// run independently and must not share mutable fixtures.
    private final class ScriptedInferenceProvider: InferenceProvider,
                                                   @unchecked Sendable {
        var queue: [ChatResponse] = []
        var capturedMessages: [[[String: Any]]] = []
        var capturedTools: [[[String: Any]]?] = []
        var chatCallCount: Int { capturedMessages.count }

        enum ScriptedError: Error { case empty }

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
            guard !queue.isEmpty else { throw ScriptedError.empty }
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

    private func finalResponse(_ text: String) -> ChatResponse {
        ChatResponse(content: text, toolCalls: nil)
    }

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
        // Reflection would siphon off extra scripted chat responses after 3
        // tool calls; keep it off so these tests isolate the branches under
        // test.
        agent.reflectionEnabled = false
        return agent
    }

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

    private func statuses(_ events: [StreamEvent]) -> [String] {
        events.compactMap { if case .status(let s) = $0 { return s } else { return nil } }
    }

    private func images(_ events: [StreamEvent]) -> [(Data, String)] {
        events.compactMap {
            if case let .image(data, name) = $0 { return (data, name) } else { return nil }
        }
    }

    /// Pull tool names out of a captured `tools` argument on a given turn.
    private func toolNames(in toolsArg: [[String: Any]]?) -> [String] {
        guard let tools = toolsArg else { return [] }
        return tools.compactMap { spec in
            (spec["function"] as? [String: Any])?["name"] as? String
        }
    }

    /// Write a 1x1 PNG-ish blob to a unique temp path so the `[IMAGE:...]`
    /// extraction branch sees a real file on disk. The production code
    /// `FileManager.default.fileExists(atPath:)`-gates the `.image` yield, so
    /// the file MUST exist for the test to observe the event.
    private func makeTempImageFile(payload: String = "fake-png-bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macbot-test-\(UUID().uuidString).png")
        try Data(payload.utf8).write(to: url)
        return url
    }

    // MARK: - 1. learnedToolHints → tool filter

    /// Non-nil `learnedToolHints` must be fed into
    /// `ToolRegistry.filteredSpecsAsJSON(..., recentTools:)` on turn 1 so
    /// the hinted tools appear in the `tools` array the scripted model
    /// receives — even though the user's input doesn't contain any keywords
    /// that would match those tool groups.
    ///
    /// Contract under test: hint strings are unioned into the filter's
    /// `matchedNames` set (ToolRegistry.swift ~line 132), so specs whose
    /// names match the hints are included in the turn-1 tools list.
    func testLearnedToolHintsAppearInTurn1ToolsList() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [finalResponse("ok")]
        let agent = makeAgent(provider: provider)

        // Register three tools with names that will never match any
        // keyword-based group in `ToolRegistry.toolGroups` — the only way
        // they can show up in the tool filter is via `recentTools`, which
        // is what `learnedToolHints` feeds.
        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "hinted_alpha", log: log) { _ in "A" }
        await registerFakeTool(on: agent, name: "hinted_beta",  log: log) { _ in "B" }
        await registerFakeTool(on: agent, name: "hinted_gamma", log: log) { _ in "G" }

        agent.learnedToolHints = ["hinted_alpha", "hinted_beta"]

        let (_, err) = await drain(agent.runStream("xyzzy"))
        XCTAssertNil(err)
        XCTAssertEqual(provider.chatCallCount, 1)

        let turn1Tools = toolNames(in: provider.capturedTools[0])
        XCTAssertTrue(turn1Tools.contains("hinted_alpha"),
            "hint 'hinted_alpha' must appear in turn-1 tool specs; got \(turn1Tools)")
        XCTAssertTrue(turn1Tools.contains("hinted_beta"),
            "hint 'hinted_beta' must appear in turn-1 tool specs; got \(turn1Tools)")
        XCTAssertFalse(turn1Tools.contains("hinted_gamma"),
            "unhinted tool must NOT be injected by recency bias; got \(turn1Tools)")
    }

    /// Empty `learnedToolHints` must NOT inject anything. The filter falls
    /// back to its hard-coded default set (`web_search`, `memory_recall`,
    /// `run_command`, `calculator`) and, since none of those are registered
    /// here, to `specs.prefix(5)`. Either way, no "hinted_*"-style tools
    /// leak in.
    ///
    /// This locks the contract that recency bias only acts when hints are
    /// actually supplied — a regression where `learnedToolHints` defaulted
    /// to a non-empty sentinel would fail this test.
    func testNoLearnedToolHintsLeavesToolFilterAtBaseline() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [finalResponse("ok")]
        let agent = makeAgent(provider: provider)

        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "hinted_alpha", log: log) { _ in "A" }
        await registerFakeTool(on: agent, name: "hinted_beta",  log: log) { _ in "B" }
        await registerFakeTool(on: agent, name: "hinted_gamma", log: log) { _ in "G" }

        // Default is []; do not set.
        XCTAssertTrue(agent.learnedToolHints.isEmpty)

        let (_, err) = await drain(agent.runStream("xyzzy"))
        XCTAssertNil(err)

        let turn1Tools = toolNames(in: provider.capturedTools[0])
        // No keyword in "xyzzy" matches any group, so `matchedNames` stays
        // empty, falls back to the hard-coded default names set, and then
        // — because none of those names are registered — to
        // `specs.prefix(5)`, which in this test is the three fake tools we
        // registered (in registration order). The contract we're locking
        // is just "recency bias did not *add* anything beyond the normal
        // filter path". Since we registered fewer than 5 tools, all three
        // leak through via the prefix(5) fallback — that's fine; the key
        // invariant is that the selection is identical with and without
        // an empty hints array.
        let providerB = ScriptedInferenceProvider()
        providerB.queue = [finalResponse("ok")]
        let agentB = makeAgent(provider: providerB)
        await registerFakeTool(on: agentB, name: "hinted_alpha", log: log) { _ in "A" }
        await registerFakeTool(on: agentB, name: "hinted_beta",  log: log) { _ in "B" }
        await registerFakeTool(on: agentB, name: "hinted_gamma", log: log) { _ in "G" }
        agentB.learnedToolHints = []
        _ = await drain(agentB.runStream("xyzzy"))
        let turn1ToolsB = toolNames(in: providerB.capturedTools[0])

        XCTAssertEqual(Set(turn1Tools), Set(turn1ToolsB),
            "empty hints array must produce the same tool set as the default")
    }

    // MARK: - 2. [IMAGE:...] extraction from tool outputs

    /// A tool result containing a single `[IMAGE:/abs/path]` marker pointing
    /// at a real file must cause exactly one `.image` StreamEvent, carrying
    /// the file's bytes and its lastPathComponent as the name. This is the
    /// happy path for screenshot / chart / QR / generate_image tools.
    func testSingleImageMarkerInToolOutputYieldsOneImageEvent() async throws {
        let fileURL = try makeTempImageFile(payload: "single-image-bytes")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let provider = ScriptedInferenceProvider()
        provider.queue = [
            toolCallResponse([(name: "fake_screenshot", args: [:])]),
            finalResponse("done"),
        ]
        let agent = makeAgent(provider: provider)

        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "fake_screenshot", log: log) { _ in
            "Here is your image: [IMAGE:\(fileURL.path)]"
        }

        let (events, err) = await drain(agent.runStream("snap it"))
        XCTAssertNil(err)

        let imgs = images(events)
        XCTAssertEqual(imgs.count, 1, "exactly one .image event expected")
        XCTAssertEqual(imgs.first?.1, fileURL.lastPathComponent,
            "image event's filename must be the lastPathComponent of the marker path")
        XCTAssertEqual(imgs.first?.0, Data("single-image-bytes".utf8),
            "image event's data must be the real bytes read from disk")

        // The marker was extracted from a *tool output*, not a final
        // assistant response, so the production code does NOT strip it
        // from the tool message in history. What matters is that the
        // final .text we yielded ("done") contains no marker.
        let allText = texts(events).joined(separator: " ")
        XCTAssertFalse(allText.contains("[IMAGE:"),
            "no text event should contain the raw marker; got: \(allText)")
    }

    /// Two `[IMAGE:...]` markers in a single tool output must yield two
    /// `.image` events, in the order the markers appear in the string.
    /// Locks the "for each match" loop at BaseAgent.swift ~line 673.
    func testMultipleImageMarkersYieldMultipleImageEventsInOrder() async throws {
        let file1 = try makeTempImageFile(payload: "first-bytes")
        let file2 = try makeTempImageFile(payload: "second-bytes")
        defer {
            try? FileManager.default.removeItem(at: file1)
            try? FileManager.default.removeItem(at: file2)
        }

        let provider = ScriptedInferenceProvider()
        provider.queue = [
            toolCallResponse([(name: "fake_multi", args: [:])]),
            finalResponse("two done"),
        ]
        let agent = makeAgent(provider: provider)

        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "fake_multi", log: log) { _ in
            "one [IMAGE:\(file1.path)] and two [IMAGE:\(file2.path)]"
        }

        let (events, err) = await drain(agent.runStream("make two images"))
        XCTAssertNil(err)

        let imgs = images(events)
        XCTAssertEqual(imgs.count, 2, "expected two .image events")
        XCTAssertEqual(imgs[0].1, file1.lastPathComponent,
            "first .image event must correspond to the first marker in source order")
        XCTAssertEqual(imgs[1].1, file2.lastPathComponent,
            "second .image event must correspond to the second marker in source order")
        XCTAssertEqual(imgs[0].0, Data("first-bytes".utf8))
        XCTAssertEqual(imgs[1].0, Data("second-bytes".utf8))
    }

    /// A tool output with no `[IMAGE:...]` marker must not produce any
    /// `.image` events. Regression guard: a future change that emits `.image`
    /// speculatively (e.g. for every tool run) would fail this.
    func testToolOutputWithoutImageMarkerEmitsNoImageEvent() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [
            toolCallResponse([(name: "fake_text", args: [:])]),
            finalResponse("all text"),
        ]
        let agent = makeAgent(provider: provider)

        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "fake_text", log: log) { _ in
            "plain text result, no markers here"
        }

        let (events, err) = await drain(agent.runStream("do text"))
        XCTAssertNil(err)
        XCTAssertTrue(images(events).isEmpty,
            ".image events must never fire without a marker")
        XCTAssertEqual(texts(events), ["all text"])
    }

    /// When the *final assistant response* itself contains `[IMAGE:/path]`
    /// (the Orchestrator Soul.md protocol: the model inlines markers in its
    /// text reply), the second extraction path at BaseAgent.swift ~line 623
    /// must yield a `.image` event for the file AND strip the raw marker
    /// out of the `.text` event. This locks the other of the two distinct
    /// `[IMAGE:...]` branches in `runStream`.
    func testImageMarkerInAssistantFinalResponseIsStrippedAndYielded() async throws {
        let fileURL = try makeTempImageFile(payload: "final-response-bytes")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let provider = ScriptedInferenceProvider()
        provider.queue = [
            finalResponse("Here's what you asked for: [IMAGE:\(fileURL.path)] enjoy."),
        ]
        let agent = makeAgent(provider: provider)
        // No tools needed — the marker lives in the assistant text, not a
        // tool output, so this exercises the tool-free-response branch.

        let (events, err) = await drain(agent.runStream("give me the picture"))
        XCTAssertNil(err)

        let imgs = images(events)
        XCTAssertEqual(imgs.count, 1, "assistant-text marker path must still yield one .image")
        XCTAssertEqual(imgs.first?.1, fileURL.lastPathComponent)
        XCTAssertEqual(imgs.first?.0, Data("final-response-bytes".utf8))

        let allText = texts(events).joined(separator: " ")
        XCTAssertFalse(allText.contains("[IMAGE:"),
            "raw marker must be stripped from the .text payload; got: \(allText)")
        XCTAssertTrue(allText.contains("Here's what you asked for:"),
            "surrounding text should be preserved when marker is stripped")
        XCTAssertTrue(allText.contains("enjoy."),
            "trailing text after the marker should also be preserved")
    }

    // MARK: - 3. plan: true prelude

    /// With `plan: true`, `BaseAgent.runStream` must:
    ///   - issue an extra `chat` call *before* the main tool loop begins,
    ///     whose system prompt contains the distinctive plan-generation
    ///     phrase from `generatePlan` ("Break this task into 2-5 numbered
    ///     steps");
    ///   - yield a `.status` event with the "Planning complete" preamble
    ///     reporting the estimated time parsed from the plan's `~Xs` tokens;
    ///   - then run the normal tool loop, which on a final-response turn
    ///     produces the answer.
    ///
    /// Exact chat-call count: 1 (plan) + 1 (main loop) = 2.
    func testPlanTrueAddsPrePlanChatCallAndYieldsPlanStatus() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [
            // Turn 0: the plan-generation call. generatePlan strips thinking
            // tags and then appends the result as a system message.
            // Two `~Ns` entries so the estimator adds them: 15 seconds.
            finalResponse("1. probe the thing — fake_probe (~5s)\n2. summarize — none (~10s)"),
            // Turn 1: the real loop's first (and only) model call. No tool
            // calls -> the loop exits with this text.
            finalResponse("plan executed, here is the answer"),
        ]
        let agent = makeAgent(provider: provider)

        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "fake_probe", log: log) { _ in "PROBED" }

        let (events, err) = await drain(agent.runStream("do the thing", plan: true))
        XCTAssertNil(err)
        XCTAssertEqual(provider.chatCallCount, 2,
            "plan:true must add exactly one extra chat call (plan + loop)")

        // Turn 0 = planning call. Its system prompt must include the
        // distinctive plan-generation phrase.
        let planTurnMessages = provider.capturedMessages[0]
        let planSystemContents = planTurnMessages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }
        XCTAssertTrue(
            planSystemContents.contains(where: { $0.contains("Break this task into 2-5 numbered steps") }),
            "plan-generation chat call must use the distinctive planning prompt; got: \(planSystemContents)"
        )

        // `generatePlan` passes `tools: nil` to its chat call — the
        // planning step must never be given tools to call.
        XCTAssertNil(provider.capturedTools[0] ?? nil,
            "plan-generation chat call must be made with tools == nil")

        // A .status event with "Planning complete" must have been yielded,
        // and it must mention the parsed ~15s estimate.
        let stats = statuses(events)
        XCTAssertTrue(
            stats.contains(where: { $0.hasPrefix("Planning complete.") }),
            "expected a 'Planning complete.' status event; got: \(stats)"
        )
        XCTAssertTrue(
            stats.contains(where: { $0.contains("15 seconds") }),
            "planning status must report the summed ~Xs estimate; got: \(stats)"
        )

        // Normal final text still reaches the consumer.
        XCTAssertEqual(texts(events), ["plan executed, here is the answer"])
    }

    /// Counterpart to the previous test: with `plan: false` the exact same
    /// user input should result in one fewer chat call (no plan prelude)
    /// and no "Planning complete." status event. This pins the delta at
    /// exactly one model call, which is what test 6 in the task spec asks.
    func testPlanFalseSkipsPrePlanChatCall() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [finalResponse("direct answer")]
        let agent = makeAgent(provider: provider)

        let (events, err) = await drain(agent.runStream("do the thing", plan: false))
        XCTAssertNil(err)
        XCTAssertEqual(provider.chatCallCount, 1,
            "plan:false must not issue the plan-generation chat call")

        let stats = statuses(events)
        XCTAssertFalse(
            stats.contains(where: { $0.hasPrefix("Planning complete.") }),
            "no plan status should appear when plan:false; got: \(stats)"
        )
        XCTAssertEqual(texts(events), ["direct answer"])
    }

    /// A successful plan must also be *prepended* to the agent's history
    /// as a system message — this is how the plan actually influences the
    /// subsequent tool loop (the model sees "Execute this plan step by
    /// step" + the numbered list as a system instruction on turn 1 of the
    /// real loop). If this contract ever silently broke (e.g. `generatePlan`
    /// stopped calling `appendToHistory`), the plan would visually appear
    /// in the status line but have no effect on the model — a subtle bug.
    ///
    /// Verified by inspecting the `messages` array passed into the **main
    /// loop's** chat call (turn index 1, since the plan call is turn 0).
    func testPlanTrueInjectsPlanAsSystemMessageIntoLoopHistory() async {
        let provider = ScriptedInferenceProvider()
        provider.queue = [
            finalResponse("1. step one — fake_probe (~3s)"),
            finalResponse("done"),
        ]
        let agent = makeAgent(provider: provider)

        let log = ToolCallLog()
        await registerFakeTool(on: agent, name: "fake_probe", log: log) { _ in "ok" }

        let (_, err) = await drain(agent.runStream("plan and act", plan: true))
        XCTAssertNil(err)
        XCTAssertEqual(provider.chatCallCount, 2)

        // Turn 1 is the real loop's first model call. Its messages array
        // should contain a system message that begins with the plan-
        // injection preamble.
        let loopMessages = provider.capturedMessages[1]
        let systemContents = loopMessages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }

        XCTAssertTrue(
            systemContents.contains(where: { $0.contains("Execute this plan step by step") }),
            "plan must be appended to history as a system message before the loop runs; got system contents: \(systemContents)"
        )
        XCTAssertTrue(
            systemContents.contains(where: { $0.contains("step one") }),
            "the generated plan text itself must appear in the injected system message"
        )
    }
}
