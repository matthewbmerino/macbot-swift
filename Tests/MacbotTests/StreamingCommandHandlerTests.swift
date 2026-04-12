import XCTest
@testable import Macbot

/// Coverage for `CommandHandler.handleStream`, added in 3a8d74b. The commit
/// wired a new streaming entry point for command-driven turns so /code,
/// /think, /chat etc. emit tokens as they're produced instead of waiting
/// for the whole response. It claimed "no test changes needed — streaming
/// command behavior would need an integration test against a live Ollama".
/// These tests close that gap without a live Ollama by scripting a fake
/// `BaseAgent.runStream` and asserting the forwarding, transcript
/// hydration, error-path capture, and synthetic-string wrapping invariants
/// the commit depends on.
final class StreamingCommandHandlerTests: XCTestCase {

    // MARK: - Scripted fake agent

    /// A BaseAgent subclass whose `runStream` plays back a canned sequence
    /// of events. Records the `history` state at the moment it is invoked
    /// (i.e. after the orchestrator's `prepareAgent` has hydrated it) so
    /// tests can assert on pre-yield state. Can optionally throw after N
    /// events to exercise the error path, and can append user/assistant
    /// messages to its own history to mimic what the real run loop does so
    /// `captureTurn` has something to fold back into the transcript.
    final class ScriptedAgent: BaseAgent {
        /// Events to yield in order before finishing (or throwing).
        var scripted: [StreamEvent] = []
        /// If set, `runStream` throws this error after yielding `scripted`.
        var errorAfterYield: Error?
        /// Messages to append to `history` at the start of `runStream`, so
        /// `captureTurn` sees a real user+assistant turn to fold back.
        var historyAppends: [[String: Any]] = []
        /// Snapshot of `history` captured the instant `runStream` is
        /// entered. Tests use this to prove the transcript was hydrated
        /// before any events were yielded.
        private(set) var historyAtStart: [[String: Any]] = []
        /// Count of times `runStream` was invoked.
        private(set) var runStreamCalls = 0
        /// Last `input` argument `runStream` was invoked with.
        private(set) var lastInput: String?
        /// Last `plan` flag `runStream` was invoked with. Lets tests prove
        /// that `/plan` reaches `runOnAgentStream` with plan=true while
        /// other commands leave it false.
        private(set) var lastPlan: Bool = false

        override func runStream(
            _ input: String, images: [Data]? = nil, plan: Bool = false
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            runStreamCalls += 1
            lastInput = input
            lastPlan = plan
            // Snapshot history BEFORE we yield anything. CommandHandler's
            // runOnAgentStream is documented to call prepareAgent before
            // entering the for-try-await, so the hydrated state must be
            // visible here.
            historyAtStart = history

            // Mimic the real run loop's side effect: append a user message
            // and an assistant message to history during the turn so
            // captureTurn has user-visible content to fold back into the
            // canonical transcript. Real BaseAgent.runStream does the same
            // via appendToHistory.
            for msg in historyAppends {
                history.append(msg)
            }

            let events = scripted
            let err = errorAfterYield
            return AsyncThrowingStream { continuation in
                Task {
                    for e in events {
                        continuation.yield(e)
                    }
                    if let err {
                        continuation.finish(throwing: err)
                    } else {
                        continuation.finish()
                    }
                }
            }
        }
    }

    // MARK: - Fixtures

    private func makeAgent(name: String, prompt: String) -> ScriptedAgent {
        ScriptedAgent(
            name: name,
            model: "m",
            systemPrompt: prompt,
            temperature: 0.5,
            numCtx: 4096,
            client: MockInferenceProvider()
        )
    }

    /// Build a ConversationState wired with the scripted fakes for every
    /// agent category CommandHandler.handleStream might dispatch to. Using
    /// distinct agents per category lets the cross-agent continuity test
    /// verify the shared transcript actually crosses agent boundaries.
    private func makeConv() -> (
        Orchestrator.ConversationState,
        general: ScriptedAgent,
        coder: ScriptedAgent,
        reasoner: ScriptedAgent,
        vision: ScriptedAgent,
        rag: ScriptedAgent
    ) {
        let general = makeAgent(name: "general", prompt: "SYS_GENERAL")
        let coder = makeAgent(name: "coder", prompt: "SYS_CODER")
        let reasoner = makeAgent(name: "reasoner", prompt: "SYS_REASONER")
        let vision = makeAgent(name: "vision", prompt: "SYS_VISION")
        let rag = makeAgent(name: "rag", prompt: "SYS_RAG")
        let conv = Orchestrator.ConversationState(agents: [
            .general: general,
            .coder: coder,
            .reasoner: reasoner,
            .vision: vision,
            .rag: rag,
        ])
        return (conv, general, coder, reasoner, vision, rag)
    }

    /// Drain an AsyncThrowingStream into an array (or throw). Avoids
    /// per-test boilerplate.
    private func collect(
        _ stream: AsyncThrowingStream<StreamEvent, Error>
    ) async throws -> [StreamEvent] {
        var out: [StreamEvent] = []
        for try await e in stream {
            out.append(e)
        }
        return out
    }

    // MARK: - Tests

    /// Invariant: for an agent-delegating command, every event the agent's
    /// runStream yields is forwarded verbatim, in order, to the consumer.
    /// This is the whole point of 3a8d74b — the earlier non-streaming path
    /// collapsed everything into a single final string. If forwarding were
    /// broken (dropped, reordered, or coalesced) tokens wouldn't reach the
    /// UI mid-stream and the feature would silently regress.
    func testThinkCommandForwardsAllTextEventsInOrder() async throws {
        let fx = makeConv()
        let orch = Orchestrator()
        fx.reasoner.scripted = [
            .text("Let "),
            .text("me "),
            .text("think "),
            .text("about that."),
        ]
        fx.reasoner.historyAppends = [
            ["role": "user", "content": "why is the sky blue?"],
            ["role": "assistant", "content": "Let me think about that."],
        ]

        let events = try await collect(
            CommandHandler.handleStream(
                command: "/think why is the sky blue?",
                conv: fx.0, orchestrator: orch
            )
        )

        // Four .text events, same order, same content.
        XCTAssertEqual(events.count, 4)
        let texts: [String] = events.compactMap {
            if case .text(let s) = $0 { return s } else { return nil }
        }
        XCTAssertEqual(texts, ["Let ", "me ", "think ", "about that."])
        XCTAssertEqual(fx.reasoner.runStreamCalls, 1)
        XCTAssertEqual(fx.reasoner.lastInput, "why is the sky blue?")
    }

    /// Invariant: `prepareAgent` hydrates the agent's `history` from the
    /// conversation transcript BEFORE the streaming loop is entered. The
    /// commit message specifically claims the new path preserves the
    /// cross-agent continuity fix from a4cc696 — that only works if the
    /// hydration happens ahead of runStream. We verify this by preloading
    /// the transcript with a prior turn and asserting the scripted agent
    /// sees it on entry.
    func testTranscriptIsHydratedBeforeFirstYieldAndCapturedAfter() async throws {
        let fx = makeConv()
        let orch = Orchestrator()

        // Prior turn, as if a previous /chat already ran.
        fx.0.transcript = [
            ["role": "user", "content": "remember the number 42"],
            ["role": "assistant", "content": "got it, 42"],
        ]

        fx.coder.scripted = [.text("ok, working on it")]
        fx.coder.historyAppends = [
            ["role": "user", "content": "write a fizzbuzz"],
            ["role": "assistant", "content": "ok, working on it"],
        ]

        let events = try await collect(
            CommandHandler.handleStream(
                command: "/code write a fizzbuzz",
                conv: fx.0, orchestrator: orch
            )
        )
        XCTAssertEqual(events.count, 1)

        // 1. Pre-yield state — hydration happened before runStream's body.
        let hydrated = fx.coder.historyAtStart
        // [system] + 2 prior transcript messages = 3
        XCTAssertEqual(hydrated.count, 3)
        XCTAssertEqual(hydrated[0]["role"] as? String, "system")
        XCTAssertTrue(
            (hydrated[0]["content"] as? String ?? "").contains("SYS_CODER"),
            "system prompt should be this agent's own, not a sibling's"
        )
        XCTAssertEqual(hydrated[1]["content"] as? String, "remember the number 42")
        XCTAssertEqual(hydrated[2]["content"] as? String, "got it, 42")

        // 2. Post-stream state — captureTurn appended the new turn's
        // user-visible messages to the canonical transcript.
        XCTAssertEqual(fx.0.transcript.count, 4)
        XCTAssertEqual(fx.0.transcript[2]["content"] as? String, "write a fizzbuzz")
        XCTAssertEqual(fx.0.transcript[3]["content"] as? String, "ok, working on it")

        // currentAgent should have been updated by the command dispatch.
        XCTAssertEqual(fx.0.currentAgent, .coder)
    }

    /// Invariant: when the underlying stream throws mid-turn, the error
    /// propagates AND `captureTurn` still runs so the partial turn lands in
    /// the transcript. The commit message says "captured when it ends (or
    /// on error)" — the catch block in runOnAgentStream is exactly this
    /// claim. Regression guard: if someone removes the catch-side
    /// captureTurn, partial user input disappears from history and the
    /// next turn's agent forgets what the user just said.
    func testErrorPathStillCapturesTurnAndRethrows() async throws {
        struct Boom: Error, Equatable {}
        let fx = makeConv()
        let orch = Orchestrator()

        fx.general.scripted = [.text("partial...")]
        fx.general.historyAppends = [
            ["role": "user", "content": "hello there"],
            ["role": "assistant", "content": "partial..."],
        ]
        fx.general.errorAfterYield = Boom()

        let stream = CommandHandler.handleStream(
            command: "/chat hello there", conv: fx.0, orchestrator: orch
        )

        var thrown: Error?
        var received: [StreamEvent] = []
        do {
            for try await e in stream {
                received.append(e)
            }
        } catch {
            thrown = error
        }

        // The partial text still reached the consumer.
        XCTAssertEqual(received.count, 1)
        // The error propagated.
        XCTAssertNotNil(thrown)
        XCTAssertTrue(thrown is Boom)
        // And the turn was captured despite the error — this is the
        // specific promise of the catch branch in runOnAgentStream.
        XCTAssertEqual(fx.0.transcript.count, 2)
        XCTAssertEqual(fx.0.transcript[0]["content"] as? String, "hello there")
        XCTAssertEqual(fx.0.transcript[1]["content"] as? String, "partial...")
    }

    /// Invariant: synthetic-string commands (those whose output is
    /// generated instantly from local state — /help, /status, /backend,
    /// /memories, /clear, /workflows, etc.) are wrapped as exactly ONE
    /// `.text` event whose content matches what the non-streaming `handle`
    /// returns for the same input. Using /help keeps this test hermetic —
    /// /help returns a private static string without touching the network,
    /// the DB, or the model registry.
    func testSyntheticCommandWrappedAsSingleTextEvent() async throws {
        let fx = makeConv()
        let orch = Orchestrator()

        let events = try await collect(
            CommandHandler.handleStream(
                command: "/help", conv: fx.0, orchestrator: orch
            )
        )
        let nonStreamResult = try await CommandHandler.handle(
            command: "/help", conv: fx.0, orchestrator: orch
        )

        // Exactly one event ...
        XCTAssertEqual(events.count, 1)
        // ... it's a .text ...
        guard case .text(let streamed) = events[0] else {
            return XCTFail("expected a single .text event for /help, got \(events[0])")
        }
        // ... and its payload matches the non-streaming path byte-for-byte.
        XCTAssertEqual(streamed, nonStreamResult)
        XCTAssertFalse(streamed.isEmpty)

        // None of the agent-delegating fakes should have been touched:
        // /help is a synthetic-string command.
        XCTAssertEqual(fx.general.runStreamCalls, 0)
        XCTAssertEqual(fx.reasoner.runStreamCalls, 0)
    }

    /// Invariant: the cross-agent shared-transcript fix (a4cc696 / 5360235)
    /// still works when commands are dispatched through the streaming
    /// path. Turn 1 goes through /chat (general agent), turn 2 goes through
    /// /think (reasoner). The reasoner must see the user's first message
    /// and the general agent's reply when its runStream is invoked. If
    /// prepareAgent were skipped in the streaming path, or captureTurn
    /// were dropped, the reasoner's `historyAtStart` snapshot would not
    /// contain turn 1.
    func testCrossAgentSharedTranscriptAcrossStreamingCommands() async throws {
        let fx = makeConv()
        let orch = Orchestrator()

        // Turn 1 — /chat on the general agent.
        fx.general.scripted = [.text("hi, nice to meet you")]
        fx.general.historyAppends = [
            ["role": "user", "content": "hello, I'm matthew"],
            ["role": "assistant", "content": "hi, nice to meet you"],
        ]
        _ = try await collect(
            CommandHandler.handleStream(
                command: "/chat hello, I'm matthew",
                conv: fx.0, orchestrator: orch
            )
        )

        // Sanity: turn 1 landed in the shared transcript.
        XCTAssertEqual(fx.0.transcript.count, 2)

        // Turn 2 — /think on the reasoner. It should already see turn 1.
        fx.reasoner.scripted = [.text("your name is matthew")]
        fx.reasoner.historyAppends = [
            ["role": "user", "content": "what's my name?"],
            ["role": "assistant", "content": "your name is matthew"],
        ]
        _ = try await collect(
            CommandHandler.handleStream(
                command: "/think what's my name?",
                conv: fx.0, orchestrator: orch
            )
        )

        // The reasoner's `runStream` was handed a pre-hydrated history
        // that contains turn 1's user + assistant messages, and its OWN
        // system prompt on top (not the general agent's).
        let hydrated = fx.reasoner.historyAtStart
        XCTAssertEqual(hydrated.count, 3, "system + 2 prior transcript messages")
        XCTAssertEqual(hydrated[0]["role"] as? String, "system")
        XCTAssertTrue(
            (hydrated[0]["content"] as? String ?? "").contains("SYS_REASONER"),
            "reasoner should see its own system prompt, not the general agent's"
        )
        XCTAssertEqual(hydrated[1]["content"] as? String, "hello, I'm matthew")
        XCTAssertEqual(hydrated[2]["content"] as? String, "hi, nice to meet you")

        // And after turn 2, the transcript contains all four messages in
        // order — cross-agent continuity held through two streaming
        // commands.
        XCTAssertEqual(fx.0.transcript.count, 4)
        XCTAssertEqual(fx.0.transcript[2]["content"] as? String, "what's my name?")
        XCTAssertEqual(fx.0.transcript[3]["content"] as? String, "your name is matthew")
    }

    // MARK: - Mixed event-type forwarding
    //
    // Everything above this line drives the scripted agent with `.text`
    // events only. That's enough to test the happy path for /think and
    // /code, but it means the forwarding of the OTHER StreamEvent cases
    // (`.status`, `.image`, `.agentSelected`) through
    // `CommandHandler.handleStream` → `runOnAgentStream` is only covered
    // transitively — a refactor that silently dropped `.image` events
    // would not fail any of the earlier tests. The tests below close that
    // gap with direct per-case assertions and add direct-dispatch coverage
    // for `/upgrade` and `/plan`, which were also previously only exercised
    // via the shared `runOnAgentStream` helper.

    /// Invariant: every case of `StreamEvent` the agent yields is forwarded
    /// verbatim to the consumer in order, regardless of mix. A scripted
    /// sequence that interleaves `.status`, `.text`, `.image`, and
    /// `.agentSelected` must reach the consumer as five separate events
    /// with exactly the same payloads, in the same order. This is the
    /// direct lock that was missing: forwarding is defined as "forward
    /// every StreamEvent", not "forward every .text".
    func testAllEventTypesForwardedVerbatimInOrder() async throws {
        let fx = makeConv()
        let orch = Orchestrator()

        let imgData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        fx.reasoner.scripted = [
            .status("thinking..."),
            .text("Hello"),
            .image(imgData, "foo.png"),
            .text(" world"),
            .agentSelected(.reasoner),
        ]
        fx.reasoner.historyAppends = [
            ["role": "user", "content": "mixed events please"],
            ["role": "assistant", "content": "Hello world"],
        ]

        let events = try await collect(
            CommandHandler.handleStream(
                command: "/think mixed events please",
                conv: fx.0, orchestrator: orch
            )
        )

        // Five events, same order, same shapes. StreamEvent isn't
        // Equatable so we destructure each one.
        XCTAssertEqual(events.count, 5)

        guard case .status(let s0) = events[0] else {
            return XCTFail("event[0] expected .status, got \(events[0])")
        }
        XCTAssertEqual(s0, "thinking...")

        guard case .text(let s1) = events[1] else {
            return XCTFail("event[1] expected .text, got \(events[1])")
        }
        XCTAssertEqual(s1, "Hello")

        guard case .image(let data2, let name2) = events[2] else {
            return XCTFail("event[2] expected .image, got \(events[2])")
        }
        XCTAssertEqual(data2, imgData)
        XCTAssertEqual(name2, "foo.png")

        guard case .text(let s3) = events[3] else {
            return XCTFail("event[3] expected .text, got \(events[3])")
        }
        XCTAssertEqual(s3, " world")

        guard case .agentSelected(let cat4) = events[4] else {
            return XCTFail("event[4] expected .agentSelected, got \(events[4])")
        }
        XCTAssertEqual(cat4, .reasoner)
    }

    /// Invariant: `.image` events are forwarded without any coercion,
    /// truncation, or replacement of their payload. The commit message
    /// claims `runStream` forwards text/status/image events — this test
    /// proves an image Data blob (binary, contains NULs and non-ASCII
    /// bytes) and a filename with spaces both survive the trip through
    /// `CommandHandler.handleStream` → `runOnAgentStream` unchanged. If
    /// something along the way re-encoded the Data or normalised the
    /// filename, this would catch it.
    func testImageEventPayloadSurvivesStreamUnchanged() async throws {
        let fx = makeConv()
        let orch = Orchestrator()

        // Deliberately nasty payload: embedded NUL, high bytes, full range.
        let imgData = Data([0x00, 0x01, 0xFF, 0x7F, 0x80, 0x00, 0xAB])
        let fname = "long path with spaces.png"
        fx.coder.scripted = [.image(imgData, fname)]
        fx.coder.historyAppends = [
            ["role": "user", "content": "render me something"],
            ["role": "assistant", "content": "<image>"],
        ]

        let events = try await collect(
            CommandHandler.handleStream(
                command: "/code render me something",
                conv: fx.0, orchestrator: orch
            )
        )

        XCTAssertEqual(events.count, 1)
        guard case .image(let data, let name) = events[0] else {
            return XCTFail("expected a single .image event, got \(events[0])")
        }
        // Byte-for-byte identical — no re-encoding, no base64 round-trip.
        XCTAssertEqual(data, imgData)
        XCTAssertEqual(data.count, 7)
        // Filename (with spaces!) comes through exactly.
        XCTAssertEqual(name, fname)
    }

    /// Invariant: `.status` and `.text` events are distinct events on the
    /// wire. A consumer that wants to render "thinking..." as an ephemeral
    /// status line and the answer as real content must see TWO events,
    /// not a single `.text("thinking...answer")`. Regression guard: if
    /// anyone coalesces status into the text buffer, this breaks.
    func testStatusEventNotCollapsedIntoTextBuffer() async throws {
        let fx = makeConv()
        let orch = Orchestrator()

        fx.coder.scripted = [
            .status("step 1"),
            .text("answer"),
        ]
        fx.coder.historyAppends = [
            ["role": "user", "content": "do the thing"],
            ["role": "assistant", "content": "answer"],
        ]

        let events = try await collect(
            CommandHandler.handleStream(
                command: "/code do the thing",
                conv: fx.0, orchestrator: orch
            )
        )

        XCTAssertEqual(events.count, 2, "status and text must not collapse into one event")
        guard case .status(let status) = events[0] else {
            return XCTFail("event[0] expected .status, got \(events[0])")
        }
        XCTAssertEqual(status, "step 1")
        guard case .text(let text) = events[1] else {
            return XCTFail("event[1] expected .text, got \(events[1])")
        }
        XCTAssertEqual(text, "answer")
    }

    /// Invariant: `/upgrade` streams through `runOnAgentStream` on the
    /// REASONER (the largest model), re-running the most recent user
    /// message from the canonical transcript. Mirror of /think's forward
    /// test, but with the /upgrade-specific wrinkle that the input comes
    /// from `conv.transcript` rather than the command's `rest`. Also
    /// locks in that `/upgrade` flips `currentAgent` to `.reasoner` and
    /// that `captureTurn` runs after the stream, just like /think does.
    func testUpgradeCommandStreamsThroughReasoner() async throws {
        let fx = makeConv()
        let orch = Orchestrator()

        // Seed the transcript with a prior turn whose user message is
        // what /upgrade should re-run.
        fx.0.transcript = [
            ["role": "user", "content": "explain entropy simply"],
            ["role": "assistant", "content": "it's disorder"],
        ]

        fx.reasoner.scripted = [
            .status("warming up"),
            .text("Entropy "),
            .text("is..."),
        ]
        fx.reasoner.historyAppends = [
            ["role": "user", "content": "explain entropy simply"],
            ["role": "assistant", "content": "Entropy is..."],
        ]

        let events = try await collect(
            CommandHandler.handleStream(
                command: "/upgrade",
                conv: fx.0, orchestrator: orch
            )
        )

        // 1. Reasoner was the target agent — not coder, not general.
        XCTAssertEqual(fx.reasoner.runStreamCalls, 1)
        XCTAssertEqual(fx.coder.runStreamCalls, 0)
        XCTAssertEqual(fx.general.runStreamCalls, 0)
        XCTAssertFalse(fx.reasoner.lastPlan, "/upgrade is not a planning command")

        // 2. runOnAgentStream pulled the LAST user message from the
        //    transcript and handed it to runStream as the input.
        XCTAssertEqual(fx.reasoner.lastInput, "explain entropy simply")

        // 3. All three events forwarded in order.
        XCTAssertEqual(events.count, 3)
        if case .status(let s) = events[0] {
            XCTAssertEqual(s, "warming up")
        } else {
            XCTFail("event[0] expected .status, got \(events[0])")
        }

        // 4. currentAgent flipped to reasoner, matching the non-streaming
        //    /upgrade branch in CommandHandler.handle.
        XCTAssertEqual(fx.0.currentAgent, .reasoner)

        // 5. captureTurn ran — the new turn is in the shared transcript.
        //    Old 2 + new 2 = 4 messages.
        XCTAssertEqual(fx.0.transcript.count, 4)
        XCTAssertEqual(fx.0.transcript[3]["content"] as? String, "Entropy is...")
    }

    /// Invariant: `/plan` streams through `runOnAgentStream` against the
    /// CURRENT agent (default general) with `plan=true`. This is the one
    /// command that exercises the plan flag on the streaming path, so
    /// it's the only way to verify the flag actually reaches
    /// `agent.runStream` rather than being dropped by `handleStream`.
    func testPlanCommandStreamsThroughCurrentAgentWithPlanFlag() async throws {
        let fx = makeConv()
        let orch = Orchestrator()

        // Default currentAgent is .general, so /plan should hit general.
        fx.general.scripted = [
            .text("Step 1: "),
            .text("do the thing"),
        ]
        fx.general.historyAppends = [
            ["role": "user", "content": "ship the feature"],
            ["role": "assistant", "content": "Step 1: do the thing"],
        ]

        let events = try await collect(
            CommandHandler.handleStream(
                command: "/plan ship the feature",
                conv: fx.0, orchestrator: orch
            )
        )

        // runStream was invoked on general with plan=true — this is the
        // whole point of /plan. Other agents untouched.
        XCTAssertEqual(fx.general.runStreamCalls, 1)
        XCTAssertEqual(fx.coder.runStreamCalls, 0)
        XCTAssertEqual(fx.reasoner.runStreamCalls, 0)
        XCTAssertEqual(fx.general.lastInput, "ship the feature")
        XCTAssertTrue(
            fx.general.lastPlan,
            "/plan must forward plan=true all the way to agent.runStream"
        )

        // Text events forwarded verbatim.
        XCTAssertEqual(events.count, 2)
        let texts: [String] = events.compactMap {
            if case .text(let s) = $0 { return s } else { return nil }
        }
        XCTAssertEqual(texts, ["Step 1: ", "do the thing"])

        // captureTurn ran after the stream: turn lands in the transcript.
        XCTAssertEqual(fx.0.transcript.count, 2)
        XCTAssertEqual(fx.0.transcript[0]["content"] as? String, "ship the feature")
        XCTAssertEqual(fx.0.transcript[1]["content"] as? String, "Step 1: do the thing")
    }
}
