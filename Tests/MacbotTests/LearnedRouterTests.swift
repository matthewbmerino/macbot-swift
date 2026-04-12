import XCTest
import GRDB
@testable import Macbot

/// Locks the contract for the precomputed-embedding overload of
/// LearnedRouter.predict. This is the variant the speed pass added so the
/// orchestrator can embed the user query exactly once and feed both
/// SkillStore.retrieve and LearnedRouter.predict from the same vector —
/// instead of two independent Ollama round-trips on every turn.
///
/// The populated-store tests that exercise the real k-NN path share
/// `DatabaseManager.shared` with every other test in the suite. We use two
/// isolation tricks to keep them deterministic:
///
/// 1. **Dimension-keyed isolation.** `TraceStore.searchSimilar` skips any
///    stored embedding whose dimension differs from the query. Real
///    embedding models produce 384–1024-D vectors; our sentinel rows use
///    4-D vectors, so they live in a namespace no production row can reach.
///    Only our rows ever participate in the k-NN vote.
/// 2. **Sentinel tags + targeted cleanup.** Every inserted row uses a
///    unique `sessionId` and sentinel tool names (prefixed `learnedrtr_`),
///    and tearDown removes exactly the rows it created. Cleanup failures do
///    not leak into other tests because dimension isolation already hides
///    them.
final class LearnedRouterTests: XCTestCase {

    // Namespaced so tearDown only wipes this test run's rows.
    private var testSessionId: String = ""

    override func setUpWithError() throws {
        testSessionId = "learnedrtr-test-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        // Best-effort cleanup of any sentinel traces this test class inserted.
        // Filtering by sessionId keeps us from touching anything else.
        let sid = testSessionId
        _ = try? DatabaseManager.shared.dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM interaction_traces WHERE sessionId = ?",
                arguments: [sid]
            )
        }
    }

    // MARK: - Helpers

    /// Pack a [Float] into the Data blob layout TraceStore expects.
    private static func embeddingBlob(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Insert a sentinel trace row directly into the shared DB. Uses a 4-D
    /// embedding so the dimension-mismatch filter in `searchSimilar` hides
    /// it from — and hides real rows from — this test's queries.
    @discardableResult
    private func insertSentinelTrace(
        embedding: [Float],
        agent: String,
        tools: [String],
        turnIndex: Int = 0
    ) throws -> Int64 {
        XCTAssertEqual(
            embedding.count, 4,
            "sentinel embeddings must be 4-D so they never collide with real embeddings"
        )
        let toolCallArray: [[String: Any]] = tools.map { name in
            [
                "name": name,
                "args": [:] as [String: Any],
                "result": "",
                "latencyMs": 0,
                "error": "",
            ]
        }
        let toolJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: toolCallArray),
                  let s = String(data: data, encoding: .utf8) else { return "[]" }
            return s
        }()

        var trace = InteractionTrace(
            id: nil,
            sessionId: testSessionId,
            userId: "learnedrtr-test",
            turnIndex: turnIndex,
            userMessage: "sentinel",
            userMessageEmbedding: Self.embeddingBlob(embedding),
            routedAgent: agent,
            routeReason: "test",
            modelUsed: "test-model",
            toolCalls: toolJSON,
            assistantResponse: "",
            responseTokens: 0,
            latencyMs: 0,
            error: nil,
            ambientSnapshot: "{}",
            metadata: "{}",
            createdAt: Date()
        )

        return try DatabaseManager.shared.dbPool.write { db in
            try trace.insert(db)
            return trace.id ?? 0
        }
    }

    // MARK: - Existing degenerate-case tests (kept intact)

    func testPredictWithEmptyEmbeddingReturnsNil() {
        // Defensive: an empty vector means the embedder failed upstream.
        // The router must not crash and must not query the trace store.
        let result = LearnedRouter.predict(forQueryEmbedding: [], topK: 8, minSimilarity: 0.55)
        XCTAssertNil(result)
    }

    func testPredictWithNoTracesReturnsNil() {
        // With a fresh trace store there are no neighbors above the
        // similarity floor, so the router must return nil rather than
        // a fake-confident prediction.
        let result = LearnedRouter.predict(
            forQueryEmbedding: [0.1, 0.2, 0.3],
            topK: 8,
            minSimilarity: 0.55
        )
        // The shared TraceStore may or may not have rows depending on prior
        // test order, so we accept either nil or a non-nil result. The
        // important invariant is that the synchronous code path doesn't
        // throw or hang.
        _ = result
    }

    // MARK: - Populated k-NN path

    /// Insert a sentinel trace, query with an embedding that's a near-exact
    /// match, and verify the returned prediction carries that trace's
    /// sentinel agent + tool. This exercises the full k-NN code path rather
    /// than just the empty-store short-circuit.
    func testPredictReturnsNearestNeighborAgentAndTool() throws {
        let agent = "learnedrtr_agent_alpha"
        let tool = "learnedrtr_tool_alpha"

        try insertSentinelTrace(
            embedding: [1, 0, 0, 0],
            agent: agent,
            tools: [tool]
        )

        // Query is cos-sim 1.0 against the sentinel. Use an aggressive
        // minSimilarity so any real rows that somehow slip past the
        // 4-D dimension filter cannot pollute the vote.
        let result = LearnedRouter.predict(
            forQueryEmbedding: [1, 0, 0, 0],
            topK: 8,
            minSimilarity: 0.999
        )

        let pred = try XCTUnwrap(result, "expected a prediction from the single sentinel neighbor")
        XCTAssertEqual(pred.agent, agent)
        XCTAssertEqual(pred.tools, [tool])
        XCTAssertGreaterThanOrEqual(pred.neighborCount, 1)
        XCTAssertEqual(pred.topSimilarity, 1.0, accuracy: 1e-4)
        XCTAssertEqual(pred.agentConfidence, 1.0, accuracy: 1e-4)
    }

    /// If every reachable neighbor's similarity falls below `minSimilarity`,
    /// the router must return nil. We insert one sentinel aligned with axis
    /// 0 and query along axis 1: cosine similarity is 0, far below the
    /// floor, so there is no confident prediction.
    func testPredictEnforcesSimilarityFloor() throws {
        try insertSentinelTrace(
            embedding: [1, 0, 0, 0],
            agent: "learnedrtr_agent_beta",
            tools: ["learnedrtr_tool_beta"]
        )

        // Orthogonal query → cosine ≈ 0, well below the 0.55 floor.
        let result = LearnedRouter.predict(
            forQueryEmbedding: [0, 1, 0, 0],
            topK: 8,
            minSimilarity: 0.55
        )
        XCTAssertNil(result)
    }

    /// Orthogonal / opposite queries that exceed no similarity floor must
    /// produce nil no matter how high topK is.
    func testPredictReturnsNilForOppositeQuery() throws {
        try insertSentinelTrace(
            embedding: [1, 0, 0, 0],
            agent: "learnedrtr_agent_gamma",
            tools: ["learnedrtr_tool_gamma"]
        )

        // Opposite direction → cosine = -1. Nothing should pass a positive
        // similarity floor.
        let result = LearnedRouter.predict(
            forQueryEmbedding: [-1, 0, 0, 0],
            topK: 8,
            minSimilarity: 0.5
        )
        XCTAssertNil(result)
    }

    /// With fewer stored neighbors than requested topK the router must
    /// still succeed — not crash, not silently drop the prediction.
    func testPredictTopKGreaterThanNeighborCountStillPredicts() throws {
        let agent = "learnedrtr_agent_delta"
        let tool = "learnedrtr_tool_delta"
        try insertSentinelTrace(embedding: [1, 0, 0, 0], agent: agent, tools: [tool])
        try insertSentinelTrace(embedding: [0.99, 0.01, 0, 0], agent: agent, tools: [tool], turnIndex: 1)

        // topK way larger than the number of 4-D sentinels we inserted.
        let result = LearnedRouter.predict(
            forQueryEmbedding: [1, 0, 0, 0],
            topK: 64,
            minSimilarity: 0.9
        )
        let pred = try XCTUnwrap(result)
        XCTAssertEqual(pred.agent, agent)
        XCTAssertTrue(pred.tools.contains(tool))
        XCTAssertGreaterThanOrEqual(pred.neighborCount, 2)
    }

    /// Similarity-weighted voting: the closer neighbor should dominate when
    /// the topK set contains traces with different sentinel agents. The
    /// production code weights each neighbor's vote by its cosine
    /// similarity, so the closest neighbor's agent must win.
    func testPredictSimilarityWeightedVoteFavorsClosestNeighbor() throws {
        let winningAgent = "learnedrtr_agent_winner"
        let losingAgent = "learnedrtr_agent_loser"
        let winningTool = "learnedrtr_tool_winner"
        let losingTool = "learnedrtr_tool_loser"

        // Near-exact match for the query [1,0,0,0].
        try insertSentinelTrace(
            embedding: [1, 0, 0, 0],
            agent: winningAgent,
            tools: [winningTool],
            turnIndex: 0
        )
        // A weaker but still-above-floor match. Cosine ≈ 0.6 — passes the
        // 0.55 floor but is well below the winner's 1.0.
        try insertSentinelTrace(
            embedding: [0.6, 0.8, 0, 0],
            agent: losingAgent,
            tools: [losingTool],
            turnIndex: 1
        )

        let result = LearnedRouter.predict(
            forQueryEmbedding: [1, 0, 0, 0],
            topK: 8,
            minSimilarity: 0.55
        )
        let pred = try XCTUnwrap(result)
        XCTAssertEqual(pred.agent, winningAgent, "closest neighbor must win the weighted vote")
        XCTAssertTrue(pred.tools.contains(winningTool))
        XCTAssertGreaterThanOrEqual(pred.neighborCount, 2)
        // Confidence must be strictly greater than 0.5 because the winning
        // neighbor's similarity (≈1.0) is larger than the loser's (≈0.6).
        XCTAssertGreaterThan(pred.agentConfidence, 0.5)
    }

    /// Tool threshold: the router only surfaces tools whose weighted vote
    /// reaches 25% of total weight. A single rare tool seen in one of many
    /// neighbors must get pruned, while a tool that every neighbor used
    /// must be surfaced.
    func testPredictToolThresholdPrunesRareTools() throws {
        let agent = "learnedrtr_agent_tools"
        let commonTool = "learnedrtr_tool_common"
        let rareTool = "learnedrtr_tool_rare"

        // Four near-identical neighbors, all using the common tool. One of
        // them also used the rare tool. Rare-tool weight = ~1 out of ~4,
        // which is at the 0.25 boundary — to make the prune unambiguous
        // we give the rare-tool row a slightly lower similarity.
        try insertSentinelTrace(
            embedding: [1, 0, 0, 0],
            agent: agent,
            tools: [commonTool],
            turnIndex: 0
        )
        try insertSentinelTrace(
            embedding: [1, 0, 0, 0],
            agent: agent,
            tools: [commonTool],
            turnIndex: 1
        )
        try insertSentinelTrace(
            embedding: [1, 0, 0, 0],
            agent: agent,
            tools: [commonTool],
            turnIndex: 2
        )
        try insertSentinelTrace(
            embedding: [0.95, 0.31, 0, 0],  // cos ≈ 0.95, strictly less than 1.0
            agent: agent,
            tools: [commonTool, rareTool],
            turnIndex: 3
        )

        let result = LearnedRouter.predict(
            forQueryEmbedding: [1, 0, 0, 0],
            topK: 8,
            minSimilarity: 0.55
        )
        let pred = try XCTUnwrap(result)
        XCTAssertEqual(pred.agent, agent)
        XCTAssertTrue(
            pred.tools.contains(commonTool),
            "common tool should appear in every neighbor and pass the 25% threshold"
        )
        // Rare-tool weight ≈ 0.95 vs total ≈ 3.95 → ~24%, under the
        // 25% threshold. It must not appear in the predicted tool list.
        XCTAssertFalse(
            pred.tools.contains(rareTool),
            "rare tool below 25% weighted share must be pruned"
        )
    }

    // MARK: - Async overload (predict(query:client:embeddingModel:...))

    /// The async overload is thin — it embeds the query, then delegates to
    /// the sync overload. These tests lock the three ways that delegation
    /// can fail (empty embedding array, empty first vector, thrown error)
    /// plus the happy path where a real-shaped vector comes back and the
    /// sync k-NN path runs successfully.
    ///
    /// Using a local `StubEmbedProvider` keeps the test hermetic: no
    /// network, no Ollama, deterministic embeddings.

    /// Happy path: mock returns a 4-D vector that matches an inserted
    /// sentinel trace. The async overload must produce the same prediction
    /// the sync overload would for the same vector.
    func testAsyncPredictDelegatesToSyncWhenEmbedSucceeds() async throws {
        let agent = "learnedrtr_agent_async_ok"
        let tool = "learnedrtr_tool_async_ok"
        try insertSentinelTrace(
            embedding: [1, 0, 0, 0],
            agent: agent,
            tools: [tool]
        )

        let stub = StubEmbedProvider(embedding: [1, 0, 0, 0])
        let result = await LearnedRouter.predict(
            query: "anything — embedder stub ignores this",
            client: stub,
            embeddingModel: "stub-model",
            topK: 8,
            minSimilarity: 0.999
        )

        let pred = try XCTUnwrap(result, "valid embed response should produce a prediction")
        XCTAssertEqual(pred.agent, agent)
        XCTAssertEqual(pred.tools, [tool])
        XCTAssertEqual(stub.embedCallCount, 1, "async overload must issue exactly one embed call")
        XCTAssertEqual(stub.lastModel, "stub-model")
        XCTAssertEqual(stub.lastTexts, ["anything — embedder stub ignores this"],
                       "the query must be forwarded to the embedder verbatim")
    }

    /// Guard path 1: embedder returns an empty vecs array. The async
    /// overload must short-circuit to nil without touching the trace store.
    func testAsyncPredictReturnsNilWhenEmbedReturnsEmptyArray() async {
        let stub = StubEmbedProvider(returnEmptyArray: true)
        let result = await LearnedRouter.predict(
            query: "hello",
            client: stub,
            embeddingModel: "stub-model"
        )
        XCTAssertNil(result, "empty embed response must return nil")
        XCTAssertEqual(stub.embedCallCount, 1)
    }

    /// Guard path 2: embedder returns `[[]]` — one vector of zero
    /// dimensions. Also must return nil.
    func testAsyncPredictReturnsNilWhenFirstEmbeddingIsEmpty() async {
        let stub = StubEmbedProvider(embedding: [])
        let result = await LearnedRouter.predict(
            query: "hello",
            client: stub,
            embeddingModel: "stub-model"
        )
        XCTAssertNil(result, "zero-dimension embed response must return nil")
        XCTAssertEqual(stub.embedCallCount, 1)
    }

    /// Guard path 3: embedder throws. The async overload must catch and
    /// return nil so the orchestrator can fall back to keyword routing
    /// instead of propagating an error up through the chat hot path.
    func testAsyncPredictReturnsNilWhenEmbedThrows() async {
        let stub = StubEmbedProvider(throwOnEmbed: true)
        let result = await LearnedRouter.predict(
            query: "hello",
            client: stub,
            embeddingModel: "stub-model"
        )
        XCTAssertNil(result, "thrown embedder error must be swallowed, not propagated")
        XCTAssertEqual(stub.embedCallCount, 1)
    }
}

// MARK: - Test doubles

/// Minimal `InferenceProvider` stub that only exercises the `embed` path.
/// All other protocol methods are no-ops — `LearnedRouter.predict(query:...)`
/// never calls them, so any test reaching those branches is a red flag.
private final class StubEmbedProvider: InferenceProvider, @unchecked Sendable {
    private(set) var embedCallCount = 0
    private(set) var lastModel: String?
    private(set) var lastTexts: [String] = []

    private let embedding: [Float]
    private let returnEmptyArray: Bool
    private let throwOnEmbed: Bool

    init(
        embedding: [Float] = [],
        returnEmptyArray: Bool = false,
        throwOnEmbed: Bool = false
    ) {
        self.embedding = embedding
        self.returnEmptyArray = returnEmptyArray
        self.throwOnEmbed = throwOnEmbed
    }

    func embed(model: String, text: [String]) async throws -> [[Float]] {
        embedCallCount += 1
        lastModel = model
        lastTexts = text
        if throwOnEmbed {
            throw NSError(domain: "StubEmbedProvider", code: 1, userInfo: nil)
        }
        if returnEmptyArray { return [] }
        return [embedding]
    }

    func chat(
        model: String,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        temperature: Double,
        numCtx: Int,
        timeout: TimeInterval?
    ) async throws -> ChatResponse {
        XCTFail("LearnedRouter.predict(query:...) must not call chat()")
        return ChatResponse(content: "", toolCalls: nil)
    }

    func chatStream(
        model: String,
        messages: [[String: Any]],
        temperature: Double,
        numCtx: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func listModels() async throws -> [ModelInfo] { [] }
    func warmModel(_ model: String) async throws {}
}
