import Accelerate
import Foundation
import GRDB

/// Serial queue that embeds canvas nodes one at a time.
/// Mirrors the pattern used by `MemoryStore.EmbeddingQueue` so rapid edits
/// don't produce unbounded concurrent Ollama calls.
private actor CanvasEmbeddingQueue {
    private var pending: [(id: UUID, content: String)] = []
    private var isProcessing = false

    private let handler: @Sendable (UUID, String) async -> Void

    init(handler: @escaping @Sendable (UUID, String) async -> Void) {
        self.handler = handler
    }

    func enqueue(id: UUID, content: String) {
        pending.removeAll { $0.id == id }    // collapse re-edits
        pending.append((id, content))
        if !isProcessing {
            isProcessing = true
            Task { await processPending() }
        }
    }

    private func processPending() async {
        while !pending.isEmpty {
            let item = pending.removeFirst()
            await handler(item.id, item.content)
        }
        isProcessing = false
    }
}

/// Embeds canvas node text and serves semantic search over the corpus.
///
/// Node embeddings are stored on `canvas_nodes.embedding` (blob) and mirrored
/// into an in-memory `VectorIndex` for fast cosine search. The index is keyed
/// by Int64 derived from the node UUID's first 8 bytes; the reverse map lives
/// here in `idMap`.
final class CanvasEmbedder: @unchecked Sendable {
    private let db: DatabasePool
    private let vectorIndex = VectorIndex()

    private var idMap: [Int64: UUID] = [:]
    private let stateLock = NSLock()

    private var embeddingQueue: CanvasEmbeddingQueue?

    // Backing storage for the config below. All access goes through stateLock
    // because `embeddingClient` is assigned from MainActor in MacbotApp and
    // read from detached embed Tasks.
    private var _embeddingClient: (any InferenceProvider)?
    private var _embeddingModel: String = "qwen3-embedding:0.6b"

    /// Assigned at app startup once the orchestrator is ready. Nil until then;
    /// search falls back to keyword matching when nil.
    var embeddingClient: (any InferenceProvider)? {
        get { stateLock.withLock { _embeddingClient } }
        set { stateLock.withLock { _embeddingClient = newValue } }
    }

    var embeddingModel: String {
        get { stateLock.withLock { _embeddingModel } }
        set { stateLock.withLock { _embeddingModel = newValue } }
    }

    init(db: DatabasePool = DatabaseManager.shared.dbPool) {
        self.db = db
        loadIndex()
        self.embeddingQueue = CanvasEmbeddingQueue { [weak self] id, text in
            await self?.generateAndStore(nodeId: id, text: text)
        }
    }

    // MARK: - Index lifecycle

    private func loadIndex() {
        let rows: [Row] = (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, embedding FROM canvas_nodes WHERE embedding IS NOT NULL
            """)
        }) ?? []

        var loaded = 0
        for row in rows {
            let idString: String = row["id"]
            guard let uuid = UUID(uuidString: idString),
                  let data: Data = row["embedding"],
                  let vec = Self.deserializeEmbedding(data),
                  !vec.isEmpty else { continue }
            let vid = uuid.stableInt64
            vectorIndex.insert(id: vid, embedding: vec)
            stateLock.withLock { idMap[vid] = uuid }
            loaded += 1
        }
        if loaded > 0 {
            Log.app.info("[canvas] loaded \(loaded) node embeddings into vector index")
        }
    }

    // MARK: - Public API

    func enqueue(nodeId: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await embeddingQueue?.enqueue(id: nodeId, content: trimmed) }
    }

    func remove(nodeId: UUID) {
        let vid = nodeId.stableInt64
        vectorIndex.remove(id: vid)
        stateLock.withLock { idMap[vid] = nil }
    }

    /// Backfill embeddings for every canvas node whose embedding is null.
    /// Call after `saveCanvas` to catch freshly-edited nodes.
    func reconcile(canvasId: String? = nil) async {
        guard embeddingClient != nil else { return }

        let pending: [(UUID, String)] = (try? await db.read { db in
            let sql: String
            let args: StatementArguments
            if let canvasId {
                sql = """
                    SELECT id, text FROM canvas_nodes
                    WHERE canvasId = ? AND embedding IS NULL AND text != ''
                """
                args = [canvasId]
            } else {
                sql = """
                    SELECT id, text FROM canvas_nodes
                    WHERE embedding IS NULL AND text != ''
                """
                args = []
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.compactMap { row in
                let idStr: String = row["id"]
                let text: String = row["text"]
                guard let uuid = UUID(uuidString: idStr) else { return nil }
                return (uuid, text)
            }
        }) ?? []

        for (uuid, text) in pending {
            enqueue(nodeId: uuid, text: text)
        }
    }

    /// Pure vector similarity search. Returns an empty array if no embedding
    /// client is configured or the query fails to embed.
    func semanticSearch(query: String, limit: Int = 20, threshold: Float = 0.3)
        async -> [(nodeId: UUID, similarity: Float)]
    {
        guard let client = embeddingClient else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            let embeddings = try await client.embed(model: embeddingModel, text: [trimmed])
            guard let q = embeddings.first, !q.isEmpty else { return [] }
            let hits = vectorIndex.search(query: q, topK: limit, threshold: threshold)
            return stateLock.withLock {
                hits.compactMap { hit -> (nodeId: UUID, similarity: Float)? in
                    guard let uuid = idMap[hit.id] else { return nil }
                    return (uuid, hit.similarity)
                }
            }
        } catch {
            Log.app.warning("[canvas] semantic search failed: \(error)")
            return []
        }
    }

    // MARK: - Internal

    private func generateAndStore(nodeId: UUID, text: String) async {
        guard let client = embeddingClient else { return }
        do {
            let embeddings = try await client.embed(model: embeddingModel, text: [text])
            guard let vec = embeddings.first, !vec.isEmpty else { return }
            let data = Self.serializeEmbedding(vec)

            try await db.write { db in
                try db.execute(
                    sql: "UPDATE canvas_nodes SET embedding = ? WHERE id = ?",
                    arguments: [data, nodeId.uuidString]
                )
            }

            let vid = nodeId.stableInt64
            vectorIndex.insert(id: vid, embedding: vec)
            stateLock.withLock { idMap[vid] = nodeId }
        } catch {
            Log.app.warning("[canvas] failed to embed node \(nodeId): \(error)")
        }
    }

    // MARK: - Serialization

    static func serializeEmbedding(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func deserializeEmbedding(_ data: Data) -> [Float]? {
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return nil }
            return Array(UnsafeBufferPointer(
                start: ptr,
                count: buffer.count / MemoryLayout<Float>.size
            ))
        }
    }
}

// MARK: - UUID → Int64

extension UUID {
    /// First 8 bytes of the UUID reinterpreted as Int64. Stable across runs,
    /// used as a key into `VectorIndex` (which is Int64-keyed). Collision
    /// probability for N << 2^32 node UUIDs is negligible.
    fileprivate var stableInt64: Int64 {
        let b = self.uuid
        let high: UInt64 =
            (UInt64(b.0) << 56) | (UInt64(b.1) << 48) |
            (UInt64(b.2) << 40) | (UInt64(b.3) << 32) |
            (UInt64(b.4) << 24) | (UInt64(b.5) << 16) |
            (UInt64(b.6) << 8)  |  UInt64(b.7)
        return Int64(bitPattern: high)
    }
}
