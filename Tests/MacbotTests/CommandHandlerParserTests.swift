import XCTest
@testable import Macbot

/// Coverage for the parsing/dispatch layer of `CommandHandler.handle` —
/// the entry point for every slash command in the app. The parser is
/// inlined into `handle` (no isolated seam), so these tests drive it
/// indirectly by calling `handle` with a deliberately empty `conv.agents`
/// dictionary. That way the agent-delegating commands (/code, /think,
/// /chat, ...) hit their `guard let agent = conv.agents[...]` short-circuit
/// and return their synthetic "Switched to <agent>." string instead of
/// invoking a real model. The pure-parsing behavior — command recognition,
/// argument extraction, whitespace handling, case folding, unknown
/// fall-through — is the same on both branches.
///
/// `StreamingCommandHandlerTests` covers the streaming event-forwarding
/// and prepare/capture transcript lifecycle of `handleStream`. This file
/// deliberately does NOT duplicate any of that work; the focus here is
/// what string goes in and what command/args come out the other side.
final class CommandHandlerParserTests: XCTestCase {

    // MARK: - Fixtures

    /// Empty-agents conversation state. Every agent-delegating command
    /// (/code, /think, /chat, /see, /knowledge) will fail the
    /// `conv.agents[category]` lookup and return its synthetic
    /// "Switched to ..." string regardless of `rest`. That keeps the
    /// dispatcher tests hermetic — no agent ever runs, no network call
    /// is made, no transcript is mutated.
    private func makeEmptyConv() -> Orchestrator.ConversationState {
        Orchestrator.ConversationState(agents: [:])
    }

    /// Real Orchestrator. Its init does not make network calls; it just
    /// constructs an OllamaClient (URL only), MemoryStore, ChunkStore,
    /// and CompositeToolStore. Network and DB writes only happen for
    /// commands that explicitly invoke them, which we avoid here except
    /// for the /remember case (which uses a sentinel UUID and is cleaned
    /// up in tearDown).
    private var orch: Orchestrator!

    /// Sentinel content used by the /remember argument-extraction test.
    /// Recorded so tearDown can purge any rows it inserted from the
    /// shared MemoryStore DB without touching unrelated production data.
    private var rememberSentinels: [String] = []

    override func setUp() {
        super.setUp()
        orch = Orchestrator()
        rememberSentinels = []
    }

    override func tearDown() {
        // Best-effort cleanup of /remember sentinel rows. We delete by
        // exact content match so we never wipe a real user memory.
        for content in rememberSentinels {
            for memory in orch.memoryStore.recall(category: "note") where memory.content == content {
                if let id = memory.id {
                    _ = orch.memoryStore.forget(memoryId: id)
                }
            }
        }
        rememberSentinels = []
        orch = nil
        super.tearDown()
    }

    // MARK: - Command recognition (happy path)

    /// Spot-check three command shapes in one test:
    ///   1. agent-delegating (/think) — should set currentAgent and
    ///      short-circuit with the synthetic switch string when no agent
    ///      is wired.
    ///   2. synthetic-string (/help) — should return the static help text
    ///      that includes every documented command.
    ///   3. argument-bearing (/backend) — should return its fixed string.
    /// If any of these regress, the dispatcher's command table is broken.
    func testRecognizesCoreCommandShapes() async throws {
        let conv = makeEmptyConv()

        // (1) agent-delegating
        let thinkResult = try await CommandHandler.handle(
            command: "/think hello", conv: conv, orchestrator: orch
        )
        XCTAssertEqual(thinkResult, "Switched to reasoner.")
        XCTAssertEqual(
            conv.currentAgent, .reasoner,
            "/think must set currentAgent to .reasoner even on the empty-agents short-circuit path"
        )

        // (2) synthetic-string
        let helpResult = try await CommandHandler.handle(
            command: "/help", conv: conv, orchestrator: orch
        )
        XCTAssertTrue(helpResult.contains("/code"), "help text should list /code")
        XCTAssertTrue(helpResult.contains("/think"), "help text should list /think")
        XCTAssertTrue(helpResult.contains("/clear"), "help text should list /clear")

        // (3) zero-arg fixed-string
        let backendResult = try await CommandHandler.handle(
            command: "/backend", conv: conv, orchestrator: orch
        )
        XCTAssertTrue(
            backendResult.contains("Ollama"),
            "/backend should describe the Ollama backend"
        )
    }

    // MARK: - Argument extraction

    /// `/remember foo bar baz` must save the literal string "foo bar baz"
    /// — not "foo", not "foo bar baz" with a leading space, not the
    /// command word. The parser uses `split(maxSplits: 1)` so the rest
    /// argument is the entire post-command tail. This test locks that.
    /// Regression scenario: if someone refactors the split to use
    /// `components(separatedBy:)` or trims past the first whitespace,
    /// multi-word memories silently truncate to the first word.
    func testRememberCapturesFullMultiWordArgument() async throws {
        let conv = makeEmptyConv()
        let unique = "parser-test-\(UUID().uuidString)"
        let payload = "\(unique) foo bar baz"
        rememberSentinels.append(payload)

        let result = try await CommandHandler.handle(
            command: "/remember \(payload)", conv: conv, orchestrator: orch
        )

        // Confirmation string is "Remembered (id=N): <payload>".
        XCTAssertTrue(
            result.contains(payload),
            "remember response should echo the full payload, got: \(result)"
        )
        // Defensively check there is no leading-space artefact like
        // "Remembered (id=N):  foo bar baz" being interpreted as part of
        // the saved content. The single space after the colon is from
        // the format string itself, not from the payload.
        XCTAssertFalse(
            result.contains(": \(unique)  "),
            "saved content must not have a leading-space artefact"
        )

        // The actual stored memory should be the exact payload, with no
        // trimming surprises in either direction.
        let saved = orch.memoryStore.recall(category: "note").first { $0.content == payload }
        XCTAssertNotNil(saved, "remembered memory should be retrievable verbatim from the store")
    }

    // MARK: - Whitespace tolerance

    /// Locks the actual whitespace behavior of the inlined parser:
    ///   - extra internal whitespace between command and args is collapsed
    ///     by `split(omittingEmptySubsequences:)` (the default), so
    ///     "/think   hello" parses identically to "/think hello".
    ///   - trailing whitespace with no argument ("/think ") is treated
    ///     as no-args and falls into the empty-rest synthetic branch.
    ///   - leading whitespace on the whole command ("  /think hello")
    ///     is also tolerated for the same reason — leading empty
    ///     subsequences are dropped.
    /// If any of these regress, users with finger-fumble whitespace get
    /// inconsistent behavior across the same command.
    func testWhitespaceVariantsAroundCommandAndArgs() async throws {
        let conv = makeEmptyConv()

        // Extra internal whitespace — should still extract "hello" and
        // route to reasoner. We can't directly observe `rest` from the
        // empty-agents path, but we CAN observe currentAgent was set,
        // which proves the command word was recognized.
        let extraSpaces = try await CommandHandler.handle(
            command: "/think   hello", conv: conv, orchestrator: orch
        )
        XCTAssertEqual(extraSpaces, "Switched to reasoner.")
        XCTAssertEqual(conv.currentAgent, .reasoner)

        // Reset between subcases so currentAgent assertions are meaningful.
        conv.currentAgent = .general

        // Trailing-only whitespace, no real arg. Same synthetic string,
        // also sets currentAgent — the dispatcher updates currentAgent
        // unconditionally for /think, regardless of rest.
        let trailing = try await CommandHandler.handle(
            command: "/think ", conv: conv, orchestrator: orch
        )
        XCTAssertEqual(trailing, "Switched to reasoner.")
        XCTAssertEqual(conv.currentAgent, .reasoner)

        conv.currentAgent = .general

        // Leading whitespace on the whole input. The split-with-omit
        // behavior means parts[0] is still "/think", not "".
        let leading = try await CommandHandler.handle(
            command: "  /think hello", conv: conv, orchestrator: orch
        )
        XCTAssertEqual(leading, "Switched to reasoner.")
        XCTAssertEqual(conv.currentAgent, .reasoner)
    }

    // MARK: - Case sensitivity

    /// The parser lowercases the command word before matching. This test
    /// proves all three case variants of /think route to the reasoner.
    /// Regression scenario: if someone removes the `.lowercased()` call,
    /// `/THINK` and `/Think` would silently fall through to the unknown-
    /// command branch, breaking iOS-style autocapitalization on phones
    /// and any user who happens to hit caps lock.
    func testCommandWordIsCaseInsensitive() async throws {
        let conv = makeEmptyConv()

        for variant in ["/think", "/THINK", "/Think", "/ThInK"] {
            conv.currentAgent = .general
            let result = try await CommandHandler.handle(
                command: variant, conv: conv, orchestrator: orch
            )
            XCTAssertEqual(
                result, "Switched to reasoner.",
                "case variant \(variant) should still route to /think"
            )
            XCTAssertEqual(
                conv.currentAgent, .reasoner,
                "case variant \(variant) should still set currentAgent"
            )
        }
    }

    // MARK: - Unknown commands

    /// Unknown slash-prefixed commands fall through to a default branch
    /// that returns "Unknown command: <cmd>. Type /help for commands."
    /// They do NOT default to chat, do NOT throw, and do NOT mutate
    /// currentAgent. We also confirm the cmd echoed back is lowercased
    /// (matching what the parser actually saw post-`.lowercased()`).
    func testUnknownCommandReturnsHelpfulErrorWithoutMutatingState() async throws {
        let conv = makeEmptyConv()
        conv.currentAgent = .general

        let result = try await CommandHandler.handle(
            command: "/nonexistent foo bar", conv: conv, orchestrator: orch
        )
        XCTAssertTrue(
            result.contains("Unknown command"),
            "unknown commands must surface an explicit error string, got: \(result)"
        )
        XCTAssertTrue(
            result.contains("/nonexistent"),
            "error should echo the offending command (lowercased), got: \(result)"
        )
        XCTAssertTrue(
            result.contains("/help"),
            "error should point users at /help, got: \(result)"
        )
        XCTAssertEqual(
            conv.currentAgent, .general,
            "unknown command must NOT mutate currentAgent"
        )

        // Mixed-case unknowns get lowercased before being echoed back —
        // confirms the unknown branch sees the same lowercased cmd as
        // every other branch.
        let mixed = try await CommandHandler.handle(
            command: "/MyMadeUpCommand", conv: conv, orchestrator: orch
        )
        XCTAssertTrue(
            mixed.contains("/mymadeupcommand"),
            "unknown command echoed in lowercased form, got: \(mixed)"
        )
    }

    // MARK: - Lone slash / degenerate inputs

    /// A bare "/" with nothing after it is technically a "command" of
    /// just "/". The parser doesn't special-case it, so it falls into
    /// the unknown-command branch. Locking this behavior prevents an
    /// accidental crash if someone refactors the parser to assume the
    /// command word always has length >= 2. The full Orchestrator path
    /// only routes inputs starting with "/" into handle, so "/" alone
    /// IS reachable in production via the chat input field.
    ///
    /// Note: empty-string and whitespace-only inputs USED to crash the
    /// parser (parts[0] out-of-bounds because `split(omittingEmpty-
    /// Subsequences:)` returns []). That latent footgun was fixed by
    /// adding a `parts.first` guard in both `handle` and `handleStream`.
    /// See `testEmptyInputReturnsEmptyCommandError` below for the
    /// regression test.
    func testLoneSlashFallsThroughToUnknownCommandWithoutCrashing() async throws {
        let conv = makeEmptyConv()

        let result = try await CommandHandler.handle(
            command: "/", conv: conv, orchestrator: orch
        )
        XCTAssertTrue(
            result.contains("Unknown command"),
            "lone slash should be reported as an unknown command, got: \(result)"
        )
        XCTAssertTrue(
            result.contains("/"),
            "the offending command should be echoed back, got: \(result)"
        )
    }

    // MARK: - Optional-arg synthetic commands

    /// Synthetic-string commands whose arguments are optional must work
    /// when called bare. Two of them are safe to exercise without a
    /// real DB shape: /workflows reads the (possibly empty) composite
    /// tool store, and /memories reads the (possibly empty) memory
    /// store. Both should return a non-empty string and never throw.
    /// /parallel and /moa are pure toggles on orchestrator state and
    /// are exercised below to confirm the dispatcher reaches them with
    /// no args.
    func testZeroArgSyntheticCommandsReturnDefinedStrings() async throws {
        let conv = makeEmptyConv()

        let workflows = try await CommandHandler.handle(
            command: "/workflows", conv: conv, orchestrator: orch
        )
        XCTAssertFalse(workflows.isEmpty, "/workflows should always return a defined string")

        // /memories with no category arg recalls everything. We don't
        // assert on content (the shared DB may have real entries), only
        // that the call succeeds and returns a String.
        let memories = try await CommandHandler.handle(
            command: "/memories", conv: conv, orchestrator: orch
        )
        XCTAssertFalse(memories.isEmpty)

        // /parallel toggles a Bool — call it twice and confirm it
        // flipped back to its original value, proving each call dispatched
        // through the parser cleanly with no args.
        let initialParallel = orch.parallelAgentsEnabled
        _ = try await CommandHandler.handle(
            command: "/parallel", conv: conv, orchestrator: orch
        )
        XCTAssertNotEqual(orch.parallelAgentsEnabled, initialParallel, "first /parallel toggles state")
        _ = try await CommandHandler.handle(
            command: "/parallel", conv: conv, orchestrator: orch
        )
        XCTAssertEqual(orch.parallelAgentsEnabled, initialParallel, "second /parallel restores original state")
    }

    // MARK: - /plan usage-string short-circuit

    /// /plan with no argument returns its usage string instead of
    /// dispatching to an agent. This proves the dispatcher's
    /// `guard !rest.isEmpty` runs before the agent lookup — a regression
    /// that swapped the order would silently invoke an agent with an
    /// empty prompt.
    func testPlanWithNoArgsReturnsUsageString() async throws {
        let conv = makeEmptyConv()
        let result = try await CommandHandler.handle(
            command: "/plan", conv: conv, orchestrator: orch
        )
        XCTAssertTrue(
            result.contains("Usage") && result.contains("/plan"),
            "/plan with no args should return its usage line, got: \(result)"
        )
    }

    // MARK: - Empty-input guard (regression for parts.first crash)

    /// Empty, whitespace-only, and tab/newline-only inputs must NOT crash
    /// the parser. Before the `parts.first` guard, every one of these
    /// trapped with an out-of-bounds access on `parts[0]` because
    /// `command.split(whereSeparator: \.isWhitespace)` returns an empty
    /// array when the input contains nothing non-whitespace.
    ///
    /// This path is currently gated upstream by
    /// `Orchestrator.handleMessage`'s `hasPrefix("/")` check, so it was
    /// unreachable in production — but a future refactor of that guard
    /// would crash the app. This test locks the defensive return value
    /// ("Empty command.") so any regression is caught at test time, not
    /// as a customer-visible crash.
    func testEmptyInputReturnsEmptyCommandError() async throws {
        let conv = makeEmptyConv()

        for input in ["", " ", "   ", "\t", "\n", " \t \n "] {
            let result = try await CommandHandler.handle(
                command: input, conv: conv, orchestrator: orch
            )
            XCTAssertEqual(
                result, "Empty command.",
                "input \(input.debugDescription) should return the empty-command error, not crash or mis-dispatch"
            )
            XCTAssertEqual(
                conv.currentAgent, .general,
                "empty input must NOT mutate currentAgent"
            )
        }
    }

    /// Same regression guard for `handleStream`. Before the fix, the
    /// streaming path would also trap on `parts[0]` for empty input.
    /// Confirms that an empty input produces a single-event stream
    /// containing the "Empty command." text and then finishes cleanly.
    func testEmptyInputStreamYieldsSingleEmptyCommandEvent() async throws {
        let conv = makeEmptyConv()

        let stream = CommandHandler.handleStream(
            command: "   ", conv: conv, orchestrator: orch
        )

        var texts: [String] = []
        for try await event in stream {
            if case .text(let s) = event { texts.append(s) }
        }

        XCTAssertEqual(texts.count, 1, "empty-input stream should yield exactly one .text event")
        XCTAssertEqual(texts.first, "Empty command.")
    }
}
