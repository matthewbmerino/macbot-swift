import XCTest
import GRDB
@testable import Macbot

/// New coverage for `EpisodicMemory`, the auto-summarized conversation
/// history store. Per `TODO.md`, summarization trigger and retrieval were
/// untested; pruning is already locked down by `MemoryHygieneTests`, so we
/// stay out of that lane and focus on:
///   * `recordEpisode` guard conditions and LLM prompt shape
///   * `recent` and `search` query semantics (mirrored against a test pool
///     the same way `MemoryHygieneTests` does, because `EpisodicMemory` is
///     a singleton bound to the production on-disk database)
///   * `format(_:)` static prompt renderer
final class EpisodicMemoryTests: XCTestCase {

    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        let made = try DatabaseManager.makeTestPool()
        pool = made.pool
        path = made.path
    }

    override func tearDownWithError() throws {
        pool = nil
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    // MARK: - recordEpisode: summarization path

    /// Below the 200-char transcript threshold the method must bail out
    /// BEFORE issuing any LLM call. This is the cheap path for trivial
    /// sessions ("hi", "thanks") and it matters because summarization even
    /// against a tiny model is measurable latency at session-end.
    func testRecordEpisodeSkipsLLMForTrivialTranscript() async {
        let spy = RecordingInferenceProvider(responseContent: "{\"title\":\"x\",\"summary\":\"y\",\"topics\":[]}")
        let messages: [[String: Any]] = [
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "hello"],
        ]
        let result = await EpisodicMemory.shared.recordEpisode(
            messages: messages,
            startedAt: Date(),
            endedAt: Date(),
            client: spy,
            model: "mock-tiny"
        )
        XCTAssertNil(result, "trivial transcript should not produce an episode")
        XCTAssertEqual(spy.chatCallCount, 0, "no LLM call should be made below the 200-char threshold")
    }

    /// When the transcript crosses threshold, the method must invoke the
    /// LLM with a prompt that (a) excludes system messages, (b) preserves
    /// user/assistant role labels, and (c) embeds the raw contents. We use
    /// a deliberately malformed response so nothing gets written to any
    /// database — this test exercises only the request-side contract.
    func testRecordEpisodeFiltersSystemMessagesAndFormatsTranscript() async {
        let longUserText = String(repeating: "alpha ", count: 30)       // ~180 chars
        let longAssistantText = String(repeating: "beta ", count: 30)  // ~150 chars
        let spy = RecordingInferenceProvider(responseContent: "not json at all")

        let messages: [[String: Any]] = [
            ["role": "system", "content": "you are a helpful assistant do not leak this"],
            ["role": "user", "content": longUserText],
            ["role": "assistant", "content": longAssistantText],
        ]

        let result = await EpisodicMemory.shared.recordEpisode(
            messages: messages,
            startedAt: Date(),
            endedAt: Date(),
            client: spy,
            model: "mock-tiny"
        )

        XCTAssertNil(result, "malformed JSON response should produce nil, not crash")
        XCTAssertEqual(spy.chatCallCount, 1, "summarization should issue exactly one LLM call")
        let prompt = spy.lastPrompt ?? ""
        XCTAssertTrue(prompt.contains("user: \(longUserText)"),
                      "prompt should contain user line in 'role: content' format")
        XCTAssertTrue(prompt.contains("assistant: \(longAssistantText)"),
                      "prompt should contain assistant line in 'role: content' format")
        XCTAssertFalse(prompt.contains("you are a helpful assistant do not leak this"),
                       "system messages must be stripped before summarization")
        XCTAssertFalse(prompt.contains("system:"),
                       "no system role label should appear in the transcript")
    }

    /// Transcripts are hard-capped at 8000 chars before being sent to the
    /// LLM. A runaway conversation must never blow past that budget — if
    /// this ever regresses we'll pay for it in tokens.
    func testRecordEpisodeCapsTranscriptAtEightThousandChars() async {
        // One giant user message, well over the cap.
        let huge = String(repeating: "x", count: 20_000)
        let spy = RecordingInferenceProvider(responseContent: "garbage")
        let messages: [[String: Any]] = [
            ["role": "user", "content": huge],
        ]

        _ = await EpisodicMemory.shared.recordEpisode(
            messages: messages,
            startedAt: Date(),
            endedAt: Date(),
            client: spy,
            model: "mock-tiny"
        )

        XCTAssertEqual(spy.chatCallCount, 1)
        let prompt = spy.lastPrompt ?? ""
        // Count how many 'x' characters reached the LLM. Anything up to
        // 8000 is in-budget; anything near 20k means the cap vanished.
        let xCount = prompt.filter { $0 == "x" }.count
        XCTAssertLessThanOrEqual(xCount, 8000,
                                 "transcript payload must be capped at 8000 chars")
        XCTAssertGreaterThan(xCount, 0,
                             "some of the transcript must still be present")
    }

    // MARK: - Retrieval: recent

    /// `recent(limit:)` must return episodes newest-first and honour the
    /// limit. We mirror the query against the test pool because
    /// `EpisodicMemory.shared` is pinned to the production database (same
    /// pattern MemoryHygieneTests uses for its prune helper).
    func testRecentReturnsNewestFirstAndHonoursLimit() throws {
        // Empty store first: retrieval must not crash or return nil.
        let emptyResults = fetchRecentEpisodes(limit: 5)
        XCTAssertTrue(emptyResults.isEmpty,
                      "retrieval on an empty store should return an empty array")

        let now = Date()
        let day: TimeInterval = 86_400
        let episodes = [
            makeEpisode(title: "oldest", startedAt: now.addingTimeInterval(-3 * day)),
            makeEpisode(title: "middle", startedAt: now.addingTimeInterval(-1 * day)),
            makeEpisode(title: "newest", startedAt: now),
        ]
        try pool.write { db in
            for ep in episodes {
                var local = ep
                try local.insert(db)
            }
        }

        let all = fetchRecentEpisodes(limit: 10)
        XCTAssertEqual(all.map(\.title), ["newest", "middle", "oldest"],
                       "recent() must order by startedAt DESC")

        let top1 = fetchRecentEpisodes(limit: 1)
        XCTAssertEqual(top1.count, 1)
        XCTAssertEqual(top1.first?.title, "newest",
                       "limit must truncate the tail, keeping the newest")
    }

    // MARK: - Retrieval: search

    /// `search` is a case-insensitive LIKE match against title, summary, and
    /// the topics JSON blob. A hit in any of the three fields should count,
    /// and a query that matches nothing should return empty (not nil, not
    /// a crash).
    func testSearchMatchesAcrossTitleSummaryAndTopicsCaseInsensitive() throws {
        let now = Date()
        let titleMatch = Episode(
            id: nil,
            title: "Debugging the Rocket Launcher",
            summary: "misc talk",
            topics: "[\"space\"]",
            messageCount: 4,
            startedAt: now,
            endedAt: now.addingTimeInterval(60),
            embedding: nil,
            createdAt: now
        )
        let summaryMatch = Episode(
            id: nil,
            title: "Grocery run",
            summary: "we built a ROCKET out of spare parts",
            topics: "[\"errands\"]",
            messageCount: 2,
            startedAt: now.addingTimeInterval(-100),
            endedAt: now.addingTimeInterval(-40),
            embedding: nil,
            createdAt: now
        )
        let topicMatch = Episode(
            id: nil,
            title: "Weekend plans",
            summary: "vague plans",
            topics: "[\"rocket\", \"picnic\"]",
            messageCount: 3,
            startedAt: now.addingTimeInterval(-200),
            endedAt: now.addingTimeInterval(-140),
            embedding: nil,
            createdAt: now
        )
        let miss = Episode(
            id: nil,
            title: "Cookie recipe",
            summary: "butter and sugar",
            topics: "[\"baking\"]",
            messageCount: 1,
            startedAt: now.addingTimeInterval(-300),
            endedAt: now.addingTimeInterval(-240),
            embedding: nil,
            createdAt: now
        )
        try pool.write { db in
            for ep in [titleMatch, summaryMatch, topicMatch, miss] {
                var local = ep
                try local.insert(db)
            }
        }

        let hits = searchEpisodes(query: "rocket", limit: 10)
        let hitTitles = Set(hits.map(\.title))
        XCTAssertEqual(hitTitles, ["Debugging the Rocket Launcher", "Grocery run", "Weekend plans"],
                       "search must match title, summary, and topics (case-insensitive)")
        XCTAssertFalse(hitTitles.contains("Cookie recipe"),
                       "unrelated episodes must not leak into results")

        XCTAssertTrue(searchEpisodes(query: "zeppelin", limit: 10).isEmpty,
                      "no hits returns empty, not nil")
        XCTAssertTrue(searchEpisodes(query: "   ", limit: 10).isEmpty,
                      "whitespace-only query is treated as empty")
    }

    // MARK: - format(_:) prompt renderer

    /// `format(_:)` is the contract between episodic memory and the prompt
    /// builder: bullets, medium date, optional topics bracket, summary on
    /// the second line. Regressions here would silently corrupt the shape
    /// of the injected system context, so we pin it explicitly.
    func testFormatRendersBulletedEpisodesWithOptionalTopics() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let withTopics = Episode(
            id: 1,
            title: "Debug session",
            summary: "Fixed the flaky test harness.",
            topics: "[\"tests\", \"ci\"]",
            messageCount: 8,
            startedAt: when,
            endedAt: when.addingTimeInterval(600),
            embedding: nil,
            createdAt: when
        )
        let withoutTopics = Episode(
            id: 2,
            title: "Coffee break",
            summary: "Caught up on mail.",
            topics: "[]",
            messageCount: 1,
            startedAt: when.addingTimeInterval(-3600),
            endedAt: when.addingTimeInterval(-3000),
            embedding: nil,
            createdAt: when.addingTimeInterval(-3600)
        )

        let formatted = EpisodicMemory.format([withTopics, withoutTopics])

        XCTAssertTrue(formatted.contains("• "),
                      "each episode must be rendered as a bullet")
        XCTAssertTrue(formatted.contains("Debug session"))
        XCTAssertTrue(formatted.contains("Fixed the flaky test harness."))
        XCTAssertTrue(formatted.contains("[tests, ci]"),
                      "topics must be joined and bracketed when present")
        XCTAssertTrue(formatted.contains("Coffee break"))
        XCTAssertTrue(formatted.contains("Caught up on mail."))
        // An episode with no topics must not emit an empty "[]" bracket.
        XCTAssertFalse(formatted.contains("Coffee break []"),
                       "empty topics must produce no bracket")
        // Empty input produces an empty string — no crash, no stray bullet.
        XCTAssertEqual(EpisodicMemory.format([]), "")
    }

    // MARK: - End-to-end persistence via init(dbPool:) seam

    /// End-to-end coverage of `recordEpisode` — the one behavior the
    /// earlier pass had to leave uncovered because `EpisodicMemory.shared`
    /// was pinned to the production database. The `init(dbPool:)` seam
    /// lets us instantiate a hermetic instance backed by the test pool,
    /// feed it a real transcript, and then read the persisted episode
    /// back through the SAME instance's `recent()` / `search()` — proving
    /// the full write-then-read path, including the `Task.shadow`-style
    /// insert closure and `didInsert` rowid backfill.
    func testRecordEpisodeEndToEndPersistsAndIsRetrievable() async throws {
        let memory = EpisodicMemory(dbPool: pool)
        let json = """
        {
          "title": "Shipping the streaming handler",
          "summary": "We added handleStream and verified the transcript hydrates before the first yield.",
          "topics": ["streaming", "command-handler", "ux"]
        }
        """
        let spy = RecordingInferenceProvider(responseContent: json)

        // Build a transcript that clears the 200-char guard. One long
        // user message + one long assistant message is enough.
        let userText = String(repeating: "discussing the streaming path ", count: 6)
        let assistantText = String(repeating: "confirmed by a new regression test ", count: 6)
        let messages: [[String: Any]] = [
            ["role": "user", "content": userText],
            ["role": "assistant", "content": assistantText],
        ]

        let started = Date().addingTimeInterval(-3600)
        let ended = Date()

        let result = await memory.recordEpisode(
            messages: messages,
            startedAt: started,
            endedAt: ended,
            client: spy,
            model: "mock-tiny"
        )

        // 1. recordEpisode returned a non-nil Episode with the parsed fields.
        let saved = try XCTUnwrap(result, "valid transcript + valid JSON should yield a persisted Episode")
        XCTAssertEqual(saved.title, "Shipping the streaming handler")
        XCTAssertTrue(saved.summary.contains("handleStream"),
                      "parsed summary should contain the verbatim substring from the JSON response")
        XCTAssertEqual(saved.topicList, ["streaming", "command-handler", "ux"])
        XCTAssertEqual(saved.messageCount, 2)
        XCTAssertEqual(spy.chatCallCount, 1, "exactly one summarization call")

        // 2. didInsert backfilled a rowid.
        XCTAssertNotNil(saved.id, "didInsert must populate the rowid after insert")

        // 3. The episode is actually in the database — fetch via the same
        //    instance's recent() (not a mirror) to prove the full path.
        let recent = memory.recent(limit: 10)
        XCTAssertEqual(recent.count, 1, "exactly one episode persisted to the test pool")
        XCTAssertEqual(recent.first?.title, "Shipping the streaming handler")
        XCTAssertEqual(recent.first?.id, saved.id,
                       "recent() must return the same row that recordEpisode inserted")

        // 4. search() through the same instance hits the topic field.
        let topicHits = memory.search(query: "streaming", limit: 10)
        XCTAssertEqual(topicHits.count, 1)
        XCTAssertEqual(topicHits.first?.title, "Shipping the streaming handler")

        // 5. search() through the same instance hits the summary field.
        let summaryHits = memory.search(query: "handleStream".lowercased(), limit: 10)
        // Summary contains "handleStream" verbatim — LIKE search should find it.
        XCTAssertGreaterThanOrEqual(summaryHits.count, 1)
    }

    /// `pruneOlderThan` must work through the seam too. Inserts three
    /// episodes at different ages and confirms the cutoff boundary is
    /// respected: ≥ cutoff kept, < cutoff deleted.
    func testPruneOlderThanRespectsCutoffViaSeam() throws {
        let memory = EpisodicMemory(dbPool: pool)
        let now = Date()
        let day: TimeInterval = 86_400

        let episodes = [
            makeEpisode(title: "ancient",  startedAt: now.addingTimeInterval(-100 * day)),
            makeEpisode(title: "old",      startedAt: now.addingTimeInterval(-40 * day)),
            makeEpisode(title: "fresh",    startedAt: now.addingTimeInterval(-1 * day)),
        ]
        try pool.write { db in
            for ep in episodes {
                var local = ep
                try local.insert(db)
            }
        }

        let deleted = memory.pruneOlderThan(days: 30)
        XCTAssertEqual(deleted, 2, "ancient and old should be pruned, fresh kept")

        let remaining = memory.recent(limit: 10)
        XCTAssertEqual(remaining.map(\.title), ["fresh"],
                       "only the one episode inside the 30-day window survives")
    }

    // MARK: - Helpers

    private func makeEpisode(title: String, startedAt: Date) -> Episode {
        Episode(
            id: nil,
            title: title,
            summary: "summary of \(title)",
            topics: "[]",
            messageCount: 4,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(600),
            embedding: nil,
            createdAt: startedAt
        )
    }

    /// Mirrors `EpisodicMemory.recent(limit:)` against the test pool.
    /// We can't call the real method here because it is bound to the
    /// production singleton's on-disk database.
    private func fetchRecentEpisodes(limit: Int) -> [Episode] {
        do {
            return try pool.read { db in
                try Episode
                    .order(Column("startedAt").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            return []
        }
    }

    /// Mirrors `EpisodicMemory.search(query:limit:)` against the test pool.
    private func searchEpisodes(query: String, limit: Int) -> [Episode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%\(trimmed)%"
        do {
            return try pool.read { db in
                try Episode
                    .filter(
                        Column("title").lowercased.like(pattern) ||
                        Column("summary").lowercased.like(pattern) ||
                        Column("topics").lowercased.like(pattern)
                    )
                    .order(Column("startedAt").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            return []
        }
    }
}

// MARK: - Recording inference double

/// Minimal `InferenceProvider` spy that records the last prompt delivered to
/// `chat()`. Not a subclass of `MockInferenceProvider` so the argument
/// capture stays explicit and doesn't bleed into the shared mock used by
/// other tests.
private final class RecordingInferenceProvider: InferenceProvider, @unchecked Sendable {
    private(set) var chatCallCount = 0
    private(set) var lastPrompt: String?
    private let responseContent: String

    init(responseContent: String) {
        self.responseContent = responseContent
    }

    func chat(
        model: String,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        temperature: Double,
        numCtx: Int,
        timeout: TimeInterval?
    ) async throws -> ChatResponse {
        chatCallCount += 1
        // EpisodicMemory always sends a single-message prompt; capture its
        // content verbatim for assertions.
        if let first = messages.first, let content = first["content"] as? String {
            lastPrompt = content
        }
        return ChatResponse(content: responseContent, toolCalls: nil)
    }

    func chatStream(
        model: String,
        messages: [[String: Any]],
        temperature: Double,
        numCtx: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func embed(model: String, text: [String]) async throws -> [[Float]] { [] }
    func listModels() async throws -> [ModelInfo] { [] }
    func warmModel(_ model: String) async throws {}
}
