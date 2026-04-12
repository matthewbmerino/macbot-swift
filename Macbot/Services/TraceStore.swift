import Accelerate
import Foundation
import GRDB

/// One row = one user→assistant turn. The atomic unit of replay, evaluation,
/// and learning. Every field needed to reconstruct what happened, why, and
/// how well it worked.
struct InteractionTrace: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var sessionId: String
    var userId: String
    var turnIndex: Int
    var userMessage: String
    var userMessageEmbedding: Data?
    var routedAgent: String
    var routeReason: String        // "embedding" / "llm" / "override" / "keyword" / "fallback"
    var modelUsed: String
    var toolCalls: String          // JSON: [{name, args, result, latencyMs, error}]
    var assistantResponse: String
    var responseTokens: Int
    var latencyMs: Int
    var error: String?
    var ambientSnapshot: String    // JSON
    var metadata: String           // JSON for extensions
    var createdAt: Date

    static let databaseTableName = "interaction_traces"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var embeddingVector: [Float]? {
        guard let data = userMessageEmbedding, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: Float.self) else { return nil }
            return Array(UnsafeBufferPointer(start: ptr, count: buf.count / MemoryLayout<Float>.size))
        }
    }

    /// Decoded tool-call list (best effort).
    var toolCallList: [[String: Any]] {
        guard let data = toolCalls.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr
    }
}

/// Mutable accumulator the orchestrator passes through a turn. Final state
/// gets handed to TraceStore.commit() once the turn finishes.
final class TraceBuilder {
    let sessionId: String
    let userId: String
    let turnIndex: Int
    let userMessage: String
    let startedAt: Date
    var routedAgent: String = ""
    var routeReason: String = ""
    var modelUsed: String = ""
    var toolCalls: [[String: Any]] = []
    var assistantResponse: String = ""
    var responseTokens: Int = 0
    var error: String?
    var ambientSnapshot: AmbientSnapshot?
    var extraMetadata: [String: String] = [:]

    init(sessionId: String, userId: String, turnIndex: Int, userMessage: String) {
        self.sessionId = sessionId
        self.userId = userId
        self.turnIndex = turnIndex
        self.userMessage = userMessage
        self.startedAt = Date()
    }

    func recordToolCall(name: String, args: [String: Any], result: String, latencyMs: Int, error: String? = nil) {
        toolCalls.append([
            "name": name,
            "args": args,
            "result": String(result.prefix(2000)),
            "latencyMs": latencyMs,
            "error": error ?? "",
        ])
    }
}

/// Persistent trace store. All writes are async-safe via GRDB's pool.
/// Foundation for the entire learning loop — every other Phase 2 system
/// reads from here.
final class TraceStore: Sendable {
    static let shared = TraceStore(dbPool: DatabaseManager.shared.dbPool)

    private let dbPool: DatabasePool

    /// Inject a database pool. Production uses `.shared`, which is wired
    /// to `DatabaseManager.shared.dbPool`. Tests use this initializer
    /// directly with `DatabaseManager.makeTestPool()` to get hermetic
    /// persistence coverage without the UUID-sentinel-and-poll workaround
    /// they previously needed to isolate from the shared singleton.
    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Write

    /// Convert a builder into a persisted row. Fire-and-forget on a detached
    /// task to keep the chat path off the DB write critical section.
    func commit(_ builder: TraceBuilder) {
        let endedAt = Date()
        let latencyMs = Int(endedAt.timeIntervalSince(builder.startedAt) * 1000)

        let toolJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: builder.toolCalls, options: []),
           let str = String(data: data, encoding: .utf8) {
            toolJSON = str
        } else {
            toolJSON = "[]"
        }

        var ambientDict: [String: Any] = [:]
        if let s = builder.ambientSnapshot {
            ambientDict = [
                "frontmostApp": s.frontmostApp,
                "frontmostBundleID": s.frontmostBundleID,
                "windowTitle": s.windowTitle,
                "idleSeconds": s.idleSeconds,
                "batteryPercent": s.batteryPercent,
                "isCharging": s.isCharging,
                "memoryUsedGB": s.memoryUsedGB,
                "memoryTotalGB": s.memoryTotalGB,
            ]
        }
        let ambientJSON = (try? JSONSerialization.data(withJSONObject: ambientDict))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let metaJSON = (try? JSONSerialization.data(withJSONObject: builder.extraMetadata))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let trace = InteractionTrace(
            id: nil,
            sessionId: builder.sessionId,
            userId: builder.userId,
            turnIndex: builder.turnIndex,
            userMessage: builder.userMessage,
            userMessageEmbedding: nil,
            routedAgent: builder.routedAgent.isEmpty ? "unknown" : builder.routedAgent,
            routeReason: builder.routeReason,
            modelUsed: builder.modelUsed,
            toolCalls: toolJSON,
            assistantResponse: builder.assistantResponse,
            responseTokens: builder.responseTokens,
            latencyMs: latencyMs,
            error: builder.error,
            ambientSnapshot: ambientJSON,
            metadata: metaJSON,
            createdAt: endedAt
        )

        Task.detached { [trace] in
            do {
                // Shadow the sendable-captured trace inside the closure so
                // didInsert's mutation stays local and Swift 6 is happy.
                try await self.dbPool.write { db in
                    var local = trace
                    try local.insert(db)
                }
            } catch {
                Log.app.error("[trace] insert failed: \(error)")
            }
        }
    }

    // MARK: - Read

    func recent(limit: Int = 50) -> [InteractionTrace] {
        do {
            return try dbPool.read { db in
                try InteractionTrace
                    .order(Column("createdAt").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[trace] recent failed: \(error)")
            return []
        }
    }

    func forSession(_ sessionId: String, limit: Int = 200) -> [InteractionTrace] {
        do {
            return try dbPool.read { db in
                try InteractionTrace
                    .filter(Column("sessionId") == sessionId)
                    .order(Column("turnIndex").asc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[trace] session query failed: \(error)")
            return []
        }
    }

    func count() -> Int {
        do {
            return try dbPool.read { db in
                try InteractionTrace.fetchCount(db)
            }
        } catch {
            return 0
        }
    }

    /// k-NN over user-message embeddings. Cosine similarity via vDSP.
    /// Used by the learned tool router and skill retrieval.
    func searchSimilar(embedding query: [Float], topK: Int = 10) -> [(InteractionTrace, Float)] {
        guard !query.isEmpty else { return [] }
        let normalizedQuery = Self.normalize(query)

        let traces: [InteractionTrace]
        do {
            traces = try dbPool.read { db in
                try InteractionTrace
                    .filter(Column("userMessageEmbedding") != nil)
                    .order(Column("createdAt").desc)
                    .limit(2000)   // search recent slice — full scan is fine at this size
                    .fetchAll(db)
            }
        } catch {
            return []
        }

        var scored: [(InteractionTrace, Float)] = []
        for trace in traces {
            guard let vec = trace.embeddingVector, vec.count == normalizedQuery.count else { continue }
            let normalized = Self.normalize(vec)
            var dot: Float = 0
            vDSP_dotpr(normalizedQuery, 1, normalized, 1, &dot, vDSP_Length(normalized.count))
            scored.append((trace, dot))
        }
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(topK))
    }

    /// Lazy embedding backfill — runs in background, fills userMessageEmbedding
    /// for any trace missing one. Called periodically by the orchestrator.
    func backfillEmbeddings(client: any InferenceProvider, model: String, batchSize: Int = 20) async {
        let pending: [InteractionTrace]
        do {
            pending = try await dbPool.read { db in
                try InteractionTrace
                    .filter(Column("userMessageEmbedding") == nil)
                    .order(Column("createdAt").desc)
                    .limit(batchSize)
                    .fetchAll(db)
            }
        } catch {
            return
        }
        guard !pending.isEmpty else { return }

        for trace in pending {
            do {
                let vecs = try await client.embed(model: model, text: [trace.userMessage])
                guard let vec = vecs.first else { continue }
                let data = vec.withUnsafeBufferPointer { Data(buffer: $0) }
                _ = try await dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE interaction_traces SET userMessageEmbedding = ? WHERE id = ?",
                        arguments: [data, trace.id]
                    )
                }
            } catch {
                continue
            }
        }
    }

    // MARK: - Export

    /// JSONL export — one row per line. Used by eval harness, replay tools,
    /// and any future training pipeline.
    @discardableResult
    func exportJSONL(to url: URL) -> Int {
        let traces: [InteractionTrace]
        do {
            traces = try dbPool.read { db in
                try InteractionTrace.order(Column("createdAt").asc).fetchAll(db)
            }
        } catch {
            return 0
        }

        var lines: [String] = []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for trace in traces {
            var copy = trace
            copy.userMessageEmbedding = nil  // strip embeddings — they bloat exports
            if let data = try? encoder.encode(copy),
               let str = String(data: data, encoding: .utf8) {
                lines.append(str)
            }
        }
        let payload = lines.joined(separator: "\n") + "\n"
        do {
            try payload.write(to: url, atomically: true, encoding: .utf8)
            return lines.count
        } catch {
            Log.app.error("[trace] export failed: \(error)")
            return 0
        }
    }

    // MARK: - Helpers

    private static func normalize(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return v }
        var divisor = norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }
}
