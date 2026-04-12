import XCTest
import GRDB
@testable import Macbot

/// Locks the TraceStore write/read round trip — the storage contract that
/// the eval harness, the `/traces` inspection command, and `LearnedRouter`
/// all depend on. A broken trace layer silently degrades every one of those
/// systems, so the round trip itself needs to be pinned even though higher
/// layers are tested elsewhere.
///
/// Isolation strategy:
/// - Record-level tests (happy path, ordering, empty store, schema sanity,
///   field edge cases, session filtering) run against a fresh test pool
///   built from `DatabaseManager.makeTestPool()`, the same seam every other
///   store test uses. These validate the persistence contract end-to-end
///   without touching the user's real on-disk database.
/// - The one test that exercises the actual `TraceStore.shared.commit()`
///   public entrypoint uses a UUID sentinel session id and polls for the
///   detached write, matching the sentinel approach LearnedRouterTests
///   documents for shared global state.
final class TraceStoreTests: XCTestCase {

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
        path = nil
    }

    // MARK: - Helpers

    private func makeTrace(
        sessionId: String = "sess-A",
        userId: String = "local",
        turnIndex: Int = 0,
        userMessage: String = "hello",
        routedAgent: String = "general",
        routeReason: String = "embedding",
        modelUsed: String = "qwen2.5",
        toolCalls: String = "[]",
        assistantResponse: String = "hi",
        responseTokens: Int = 3,
        latencyMs: Int = 42,
        error: String? = nil,
        ambientSnapshot: String = "{}",
        metadata: String = "{}",
        createdAt: Date = Date()
    ) -> InteractionTrace {
        InteractionTrace(
            id: nil,
            sessionId: sessionId,
            userId: userId,
            turnIndex: turnIndex,
            userMessage: userMessage,
            userMessageEmbedding: nil,
            routedAgent: routedAgent,
            routeReason: routeReason,
            modelUsed: modelUsed,
            toolCalls: toolCalls,
            assistantResponse: assistantResponse,
            responseTokens: responseTokens,
            latencyMs: latencyMs,
            error: error,
            ambientSnapshot: ambientSnapshot,
            metadata: metadata,
            createdAt: createdAt
        )
    }

    @discardableResult
    private func insert(_ trace: InteractionTrace) throws -> InteractionTrace {
        try pool.write { db in
            var local = trace
            try local.insert(db)
            return local
        }
    }

    // MARK: - 1. Happy-path round trip (every field)

    func testHappyPathRoundTripPreservesEveryField() throws {
        let toolJSON = #"[{"name":"calculator","args":{"x":2},"result":"4","latencyMs":12,"error":""}]"#
        let ambientJSON = #"{"frontmostApp":"Xcode","idleSeconds":3}"#
        let metaJSON = #"{"reason":"regression-case"}"#
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let original = makeTrace(
            sessionId: "sess-happy",
            userId: "matthew",
            turnIndex: 7,
            userMessage: "what's 2+2?",
            routedAgent: "general",
            routeReason: "llm",
            modelUsed: "qwen2.5:7b",
            toolCalls: toolJSON,
            assistantResponse: "The answer is 4.",
            responseTokens: 12,
            latencyMs: 345,
            error: nil,
            ambientSnapshot: ambientJSON,
            metadata: metaJSON,
            createdAt: createdAt
        )

        let inserted = try insert(original)
        XCTAssertNotNil(inserted.id, "didInsert must backfill the auto-assigned rowid")
        XCTAssertGreaterThan(inserted.id ?? 0, 0)

        let fetched = try pool.read { db in
            try InteractionTrace.fetchOne(db, key: inserted.id)
        }
        let row = try XCTUnwrap(fetched)

        XCTAssertEqual(row.sessionId, "sess-happy")
        XCTAssertEqual(row.userId, "matthew")
        XCTAssertEqual(row.turnIndex, 7)
        XCTAssertEqual(row.userMessage, "what's 2+2?")
        XCTAssertEqual(row.routedAgent, "general")
        XCTAssertEqual(row.routeReason, "llm")
        XCTAssertEqual(row.modelUsed, "qwen2.5:7b")
        XCTAssertEqual(row.toolCalls, toolJSON)
        XCTAssertEqual(row.assistantResponse, "The answer is 4.")
        XCTAssertEqual(row.responseTokens, 12)
        XCTAssertEqual(row.latencyMs, 345)
        XCTAssertNil(row.error)
        XCTAssertEqual(row.ambientSnapshot, ambientJSON)
        XCTAssertEqual(row.metadata, metaJSON)
        XCTAssertEqual(
            row.createdAt.timeIntervalSince1970,
            createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )

        // The decoded tool-call accessor — which is the shape the eval
        // harness and /traces reader both consume — must survive the
        // round trip as a real array, not a silent empty fallback.
        let decoded = row.toolCallList
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?["name"] as? String, "calculator")
        XCTAssertEqual(decoded.first?["result"] as? String, "4")
    }

    // MARK: - 2. Multiple writes + ordering contracts

    func testRecentReturnsNewestFirstAndForSessionReturnsOldestTurnFirst() throws {
        // Three traces in the same session, written out of turn order, with
        // increasing createdAt timestamps. `recent()` and `forSession()` use
        // different orderings (createdAt DESC vs turnIndex ASC), so this
        // locks both contracts in one test.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try insert(makeTrace(
            sessionId: "sess-order",
            turnIndex: 2,
            userMessage: "third-turn",
            createdAt: base.addingTimeInterval(2)
        ))
        try insert(makeTrace(
            sessionId: "sess-order",
            turnIndex: 0,
            userMessage: "first-turn",
            createdAt: base.addingTimeInterval(0)
        ))
        try insert(makeTrace(
            sessionId: "sess-order",
            turnIndex: 1,
            userMessage: "second-turn",
            createdAt: base.addingTimeInterval(1)
        ))

        // recent: createdAt DESC
        let recent = try pool.read { db in
            try InteractionTrace
                .order(Column("createdAt").desc)
                .limit(50)
                .fetchAll(db)
        }
        XCTAssertEqual(recent.map(\.userMessage), ["third-turn", "second-turn", "first-turn"])

        // forSession: turnIndex ASC
        let bySession = try pool.read { db in
            try InteractionTrace
                .filter(Column("sessionId") == "sess-order")
                .order(Column("turnIndex").asc)
                .fetchAll(db)
        }
        XCTAssertEqual(bySession.map(\.turnIndex), [0, 1, 2])
        XCTAssertEqual(bySession.map(\.userMessage), ["first-turn", "second-turn", "third-turn"])
    }

    // MARK: - 3. Empty store

    func testEmptyStoreReadsReturnEmptyCollectionsNotCrash() throws {
        let count = try pool.read { db in try InteractionTrace.fetchCount(db) }
        XCTAssertEqual(count, 0)

        let recent = try pool.read { db in
            try InteractionTrace.order(Column("createdAt").desc).limit(50).fetchAll(db)
        }
        XCTAssertEqual(recent.count, 0)

        let bySession = try pool.read { db in
            try InteractionTrace
                .filter(Column("sessionId") == "nobody")
                .fetchAll(db)
        }
        XCTAssertTrue(bySession.isEmpty)

        let missing = try pool.read { db in
            try InteractionTrace.fetchOne(db, key: 99_999)
        }
        XCTAssertNil(missing, "fetching a nonexistent id must return nil, not crash")
    }

    // MARK: - 4. Field edge cases

    func testFieldEdgeCasesSurviveRoundTrip() throws {
        // Edge cases that actually occur in production traces:
        //  - empty assistantResponse when an error aborted the turn
        //  - error string populated
        //  - unicode in the user message
        //  - a very long "tool output" pasted into the toolCalls JSON
        //  - an explicit empty tool call list "[]"
        let longResult = String(repeating: "x", count: 5000)
        let toolJSON = #"[{"name":"read_file","args":{"path":"/etc/hosts"},"result":"\#(longResult)","latencyMs":1,"error":""}]"#
        let unicodeMessage = "hello 世界 — café ☕️ 🚀"

        let original = makeTrace(
            sessionId: "sess-edge",
            userMessage: unicodeMessage,
            routedAgent: "general",
            toolCalls: toolJSON,
            assistantResponse: "",
            responseTokens: 0,
            latencyMs: 0,
            error: "network timeout"
        )
        let inserted = try insert(original)
        let row = try XCTUnwrap(
            try pool.read { db in try InteractionTrace.fetchOne(db, key: inserted.id) }
        )

        XCTAssertEqual(row.userMessage, unicodeMessage, "unicode must survive the text column round trip")
        XCTAssertEqual(row.assistantResponse, "")
        XCTAssertEqual(row.error, "network timeout")
        XCTAssertEqual(row.toolCalls.count, toolJSON.count,
                       "long tool output must not be truncated at the storage layer")
        XCTAssertEqual(row.toolCalls, toolJSON)

        // The empty-tool-calls path (which the learned router treats as
        // "no tools were used") must decode to an empty array, not nil.
        let emptyToolsTrace = try insert(makeTrace(
            sessionId: "sess-edge",
            turnIndex: 1,
            toolCalls: "[]"
        ))
        let emptyRow = try XCTUnwrap(
            try pool.read { db in try InteractionTrace.fetchOne(db, key: emptyToolsTrace.id) }
        )
        XCTAssertEqual(emptyRow.toolCallList.count, 0)
    }

    // MARK: - 5. Query by id — present + missing

    func testFetchByIdReturnsRowOrNil() throws {
        let inserted = try insert(makeTrace(sessionId: "sess-id-probe"))
        let id = try XCTUnwrap(inserted.id)

        let hit = try pool.read { db in try InteractionTrace.fetchOne(db, key: id) }
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.sessionId, "sess-id-probe")

        let miss = try pool.read { db in try InteractionTrace.fetchOne(db, key: id + 10_000) }
        XCTAssertNil(miss, "fetching an unknown id must return nil")
    }

    // MARK: - 6. TraceStore.shared.commit() end-to-end

    func testSharedStoreCommitAndReadRoundTrip() throws {
        // Exercise the actual TraceStore.commit() -> recent()/forSession()/count()
        // public path, not just the GRDB record. Because TraceStore.shared is
        // a process-wide singleton backed by the real on-disk DB, this test
        // uses a UUID sentinel session id so it can identify its own row
        // regardless of leftover state from other tests — same pattern the
        // LearnedRouterTests comment documents. commit() is fire-and-forget
        // via Task.detached, so we poll until the row lands (or time out).
        let sentinel = "tracestoretests-\(UUID().uuidString)"
        let builder = TraceBuilder(
            sessionId: sentinel,
            userId: "tracestoretests",
            turnIndex: 0,
            userMessage: "sentinel-query-\(sentinel)"
        )
        builder.routedAgent = "general"
        builder.routeReason = "embedding"
        builder.modelUsed = "test-model"
        builder.assistantResponse = "sentinel-response"
        builder.responseTokens = 4
        builder.recordToolCall(
            name: "calculator",
            args: ["x": 2, "y": 3],
            result: "5",
            latencyMs: 7
        )
        builder.extraMetadata["probe"] = sentinel

        let before = TraceStore.shared.count()
        TraceStore.shared.commit(builder)

        // Poll for the detached write. 2s is generous for a single insert.
        let deadline = Date().addingTimeInterval(2.0)
        var landed: [InteractionTrace] = []
        while Date() < deadline {
            landed = TraceStore.shared.forSession(sentinel)
            if !landed.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        guard let row = landed.first else {
            XCTFail("commit() did not persist a row for sentinel session \(sentinel) within 2s")
            return
        }

        XCTAssertEqual(row.sessionId, sentinel)
        XCTAssertEqual(row.userMessage, "sentinel-query-\(sentinel)")
        XCTAssertEqual(row.routedAgent, "general")
        XCTAssertEqual(row.routeReason, "embedding")
        XCTAssertEqual(row.modelUsed, "test-model")
        XCTAssertEqual(row.assistantResponse, "sentinel-response")
        XCTAssertEqual(row.responseTokens, 4)
        XCTAssertGreaterThanOrEqual(row.latencyMs, 0,
                                    "commit() must compute latencyMs from builder.startedAt")

        let tools = row.toolCallList
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["name"] as? String, "calculator")
        XCTAssertEqual(tools.first?["result"] as? String, "5")

        // count() must have observed the new row. Use >= because other
        // tests running in the same process can insert concurrently.
        XCTAssertGreaterThanOrEqual(TraceStore.shared.count(), before + 1)

        // recent() must surface the sentinel row in its newest-first slice.
        let recent = TraceStore.shared.recent(limit: 200)
        XCTAssertTrue(
            recent.contains { $0.sessionId == sentinel },
            "recent() must include the just-committed sentinel row"
        )
    }

    // MARK: - 7. searchSimilar via init(dbPool:) seam

    /// Pack a `[Float]` into the `Data` blob layout `searchSimilar` expects.
    private static func embeddingBlob(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Insert a trace with a known embedding directly into the test pool,
    /// then query it through a hermetic `TraceStore(dbPool:)` instance that
    /// shares that pool. This exercises the real `searchSimilar` vDSP code
    /// path — previously uncovered because the shared singleton made
    /// hermetic testing of k-NN impractical without the dimension-isolation
    /// hack `LearnedRouterTests` had to invent.
    func testSearchSimilarRanksByCosineSimilarityViaSeam() throws {
        // Insert three 4-D traces:
        //  * aligned with the query    → cosine ≈ 1.0
        //  * 45° off the query         → cosine ≈ 0.707
        //  * orthogonal to the query   → cosine = 0
        let aligned = makeTraceWithEmbedding(
            sessionId: "ss-aligned",
            userMessage: "aligned",
            embedding: [1, 0, 0, 0]
        )
        let halfway = makeTraceWithEmbedding(
            sessionId: "ss-halfway",
            userMessage: "halfway",
            embedding: [1, 1, 0, 0]
        )
        let orthogonal = makeTraceWithEmbedding(
            sessionId: "ss-orthogonal",
            userMessage: "orthogonal",
            embedding: [0, 0, 1, 0]
        )
        try insert(aligned)
        try insert(halfway)
        try insert(orthogonal)

        let store = TraceStore(dbPool: pool)
        let results = store.searchSimilar(embedding: [1, 0, 0, 0], topK: 10)

        XCTAssertEqual(results.count, 3, "all three matching-dim traces should score")
        XCTAssertEqual(results[0].0.userMessage, "aligned",
                       "closest match (cos ≈ 1.0) must rank first")
        XCTAssertEqual(results[0].1, 1.0, accuracy: 1e-4)
        XCTAssertEqual(results[1].0.userMessage, "halfway")
        XCTAssertEqual(results[1].1, 0.707, accuracy: 0.01,
                       "45° vector must have cosine ≈ √2/2")
        XCTAssertEqual(results[2].0.userMessage, "orthogonal")
        XCTAssertEqual(results[2].1, 0.0, accuracy: 1e-4,
                       "orthogonal vector must have cosine = 0")
    }

    /// Dimension-mismatched traces must be silently skipped, not crash
    /// `vDSP_dotpr`. This is the invariant that `LearnedRouterTests` relies
    /// on for its 4-D sentinel isolation trick — locking it here makes the
    /// contract explicit.
    func testSearchSimilarSkipsDimensionMismatchedTraces() throws {
        try insert(makeTraceWithEmbedding(
            sessionId: "ss-4d",
            userMessage: "four-dim",
            embedding: [1, 0, 0, 0]
        ))
        try insert(makeTraceWithEmbedding(
            sessionId: "ss-3d",
            userMessage: "three-dim",
            embedding: [1, 0, 0]          // different dimension
        ))
        try insert(makeTraceWithEmbedding(
            sessionId: "ss-5d",
            userMessage: "five-dim",
            embedding: [1, 0, 0, 0, 0]    // different dimension
        ))

        let store = TraceStore(dbPool: pool)
        let results = store.searchSimilar(embedding: [1, 0, 0, 0], topK: 10)

        XCTAssertEqual(results.count, 1,
                       "only the 4-D trace should score against a 4-D query")
        XCTAssertEqual(results[0].0.userMessage, "four-dim")
    }

    /// Traces without any embedding at all (userMessageEmbedding == nil) —
    /// the common case for older rows written before embeddings were wired
    /// in — must be filtered out by the `filter(Column("userMessageEmbedding")
    /// != nil)` pre-fetch and never participate in the cosine vote.
    func testSearchSimilarIgnoresTracesWithoutEmbeddings() throws {
        try insert(makeTraceWithEmbedding(
            sessionId: "ss-with",
            userMessage: "has-embedding",
            embedding: [1, 0, 0, 0]
        ))
        // A second trace with nil embedding. The helper defaults to nil
        // so we just use `makeTrace`, not `makeTraceWithEmbedding`.
        try insert(makeTrace(
            sessionId: "ss-without",
            userMessage: "no-embedding"
        ))

        let store = TraceStore(dbPool: pool)
        let results = store.searchSimilar(embedding: [1, 0, 0, 0], topK: 10)

        XCTAssertEqual(results.count, 1,
                       "null-embedding rows must be filtered before scoring")
        XCTAssertEqual(results[0].0.userMessage, "has-embedding")
    }

    /// Empty query vector → empty results, no crash. This is the first
    /// guard in `searchSimilar`.
    func testSearchSimilarReturnsEmptyForEmptyQuery() throws {
        try insert(makeTraceWithEmbedding(
            sessionId: "ss-any",
            userMessage: "x",
            embedding: [1, 0, 0, 0]
        ))

        let store = TraceStore(dbPool: pool)
        let results = store.searchSimilar(embedding: [], topK: 10)
        XCTAssertTrue(results.isEmpty, "empty query must short-circuit to []")
    }

    /// `topK` must truncate the result set. With five matches and topK = 2,
    /// only the two highest-scoring neighbors should come back.
    func testSearchSimilarTopKTruncatesResults() throws {
        // Five 4-D embeddings on the unit circle in the first quadrant,
        // each rotated a bit further from the query [1,0,0,0] — the one at
        // angle 0 is closest, the one at angle ~80° is farthest.
        let angles: [Float] = [0.0, 0.2, 0.4, 0.8, 1.4]
        for (i, theta) in angles.enumerated() {
            try insert(makeTraceWithEmbedding(
                sessionId: "ss-top-\(i)",
                userMessage: "angle-\(theta)",
                embedding: [cosf(theta), sinf(theta), 0, 0]
            ))
        }

        let store = TraceStore(dbPool: pool)
        let results = store.searchSimilar(embedding: [1, 0, 0, 0], topK: 2)

        XCTAssertEqual(results.count, 2, "topK must truncate to exactly 2")
        XCTAssertEqual(results[0].0.userMessage, "angle-0.0",
                       "the 0° neighbor must rank first")
        XCTAssertEqual(results[1].0.userMessage, "angle-0.2",
                       "the 0.2-rad neighbor must rank second")
    }

    /// Magnitude invariance: the production `normalize` + `vDSP_dotpr`
    /// pipeline treats `[2, 0, 0, 0]` and `[1, 0, 0, 0]` as the same
    /// direction, so their cosine similarity must be ≈ 1.0 regardless of
    /// the raw vector magnitudes. Proves the normalization step is
    /// actually wired in — a regression that forgot to normalize would
    /// show a similarity > 1 here.
    func testSearchSimilarIsMagnitudeInvariant() throws {
        try insert(makeTraceWithEmbedding(
            sessionId: "ss-mag",
            userMessage: "unit",
            embedding: [1, 0, 0, 0]
        ))

        let store = TraceStore(dbPool: pool)
        let results = store.searchSimilar(embedding: [2, 0, 0, 0], topK: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].1, 1.0, accuracy: 1e-4,
                       "same direction, different magnitude must normalize to cosine = 1.0")
    }

    // MARK: - 8. commit() through the seam (no polling required)

    /// Verify `commit()` works through the seam too. The seam doesn't
    /// eliminate the `Task.detached` write — that's still fire-and-forget —
    /// but the test pool is hermetic, so we can poll without needing a
    /// UUID sentinel to identify OUR row in a sea of other test rows.
    /// This is the cleaner pattern future tests should prefer.
    func testCommitThroughSeamPersistsToHermeticPool() throws {
        let store = TraceStore(dbPool: pool)

        let builder = TraceBuilder(
            sessionId: "seam-commit-test",
            userId: "seam-test-user",
            turnIndex: 0,
            userMessage: "through-seam"
        )
        builder.routedAgent = "general"
        builder.routeReason = "llm"
        builder.modelUsed = "seam-model"
        builder.assistantResponse = "ok"
        builder.responseTokens = 1
        builder.recordToolCall(
            name: "calculator",
            args: ["x": 1],
            result: "1",
            latencyMs: 0
        )

        store.commit(builder)

        // Poll for the detached write against the hermetic pool. No
        // sentinel needed — there's no other source of writes into this
        // pool, so count() > 0 is sufficient.
        let deadline = Date().addingTimeInterval(2.0)
        var rows: [InteractionTrace] = []
        while Date() < deadline {
            rows = try pool.read { db in
                try InteractionTrace.order(Column("createdAt").desc).fetchAll(db)
            }
            if !rows.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        guard let row = rows.first else {
            XCTFail("commit() through seam did not persist to the hermetic pool within 2s")
            return
        }
        XCTAssertEqual(row.sessionId, "seam-commit-test")
        XCTAssertEqual(row.userMessage, "through-seam")
        XCTAssertEqual(row.routedAgent, "general")
        XCTAssertEqual(row.assistantResponse, "ok")
        XCTAssertEqual(row.toolCallList.count, 1)
        XCTAssertEqual(row.toolCallList.first?["name"] as? String, "calculator")
    }

    // MARK: - Helpers (embedding-aware)

    private func makeTraceWithEmbedding(
        sessionId: String,
        userMessage: String,
        embedding: [Float],
        routedAgent: String = "general",
        turnIndex: Int = 0
    ) -> InteractionTrace {
        InteractionTrace(
            id: nil,
            sessionId: sessionId,
            userId: "seam-test",
            turnIndex: turnIndex,
            userMessage: userMessage,
            userMessageEmbedding: Self.embeddingBlob(embedding),
            routedAgent: routedAgent,
            routeReason: "test",
            modelUsed: "test-model",
            toolCalls: "[]",
            assistantResponse: "",
            responseTokens: 0,
            latencyMs: 0,
            error: nil,
            ambientSnapshot: "{}",
            metadata: "{}",
            createdAt: Date()
        )
    }
}
