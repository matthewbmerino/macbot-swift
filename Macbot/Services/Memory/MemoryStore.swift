import Accelerate
import Foundation
import GRDB

struct Memory: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var category: String
    var content: String
    var metadata: String
    var embedding: Data?  // Serialized [Float] for vector search
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "memories"

    /// GRDB calls this after a successful insert so we can backfill the
    /// auto-assigned row id. Required — the previous PersistableRecord
    /// conformance left `id` nil, which broke MemoryStore.save() (always
    /// returned 0) and the embedding queue (UPDATE WHERE id = 0 never matched).
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Deserialize embedding vector.
    var embeddingVector: [Float]? {
        guard let data = embedding, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return nil }
            return Array(UnsafeBufferPointer(start: ptr, count: buffer.count / MemoryLayout<Float>.size))
        }
    }

    /// Serialize a Float array to Data.
    static func serializeEmbedding(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}

struct ConversationSummary: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var userId: String
    var summary: String
    var messageCount: Int
    var createdAt: Date

    static let databaseTableName = "conversations"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Serial queue actor that processes embedding requests one at a time,
/// preventing unbounded concurrent Ollama calls when many memories are saved rapidly.
private actor EmbeddingQueue {
    private var pending: [(id: Int64, content: String)] = []
    private var isProcessing = false

    /// The actual work closure, set once by MemoryStore.
    private let handler: @Sendable (Int64, String) async -> Void

    init(handler: @escaping @Sendable (Int64, String) async -> Void) {
        self.handler = handler
    }

    func enqueue(id: Int64, content: String) {
        pending.append((id: id, content: content))
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

/// Persistent memory store with semantic vector search.
///
/// Memories are stored in SQLite with GRDB, and their embeddings are
/// indexed in an in-memory VectorIndex for fast cosine similarity search.
/// Falls back to keyword search when embeddings are unavailable.
final class MemoryStore {
    private let db: DatabasePool
    private let vectorIndex = VectorIndex()
    private var embeddingQueue: EmbeddingQueue?

    /// Optional inference client for generating embeddings.
    /// Set after initialization to enable semantic search.
    var embeddingClient: (any InferenceProvider)?
    var embeddingModel: String = "qwen3-embedding:0.6b"

    init(db: DatabasePool = DatabaseManager.shared.dbPool) {
        self.db = db
        loadVectorIndex()
        // Initialize after self is fully formed to avoid capture-before-init
        self.embeddingQueue = EmbeddingQueue { [weak self] id, content in
            await self?.generateAndStoreEmbedding(id: id, content: content)
        }
    }

    /// Load all memory embeddings into the in-memory vector index.
    private func loadVectorIndex() {
        let memories: [Memory] = (try? db.read { db in
            try Memory.fetchAll(db)
        }) ?? []

        var loaded = 0
        for memory in memories {
            if let id = memory.id, let vec = memory.embeddingVector, !vec.isEmpty {
                vectorIndex.insert(id: id, embedding: vec)
                loaded += 1
            }
        }

        if loaded > 0 {
            Log.app.info("[memory] loaded \(loaded) embeddings into vector index")
        }
    }

    // MARK: - Save

    @discardableResult
    func save(category: String, content: String, metadata: String = "{}") -> Int64 {
        let now = Date()
        var memory = Memory(
            category: category, content: content, metadata: metadata,
            embedding: nil, createdAt: now, updatedAt: now
        )
        do {
            try db.write { db in
                try memory.insert(db)
            }
        } catch {
            Log.app.error("[memory] save failed: \(error)")
            return 0
        }

        guard let id = memory.id else { return 0 }

        // Enqueue embedding generation; the actor processes them serially
        // to avoid unbounded concurrent Ollama requests.
        Task {
            await embeddingQueue?.enqueue(id: id, content: content)
        }

        return id
    }

    /// Generate an embedding for a memory and store it.
    private func generateAndStoreEmbedding(id: Int64, content: String) async {
        guard let client = embeddingClient else { return }

        do {
            let embeddings = try await client.embed(model: embeddingModel, text: [content])
            guard let embedding = embeddings.first, !embedding.isEmpty else { return }

            let data = Memory.serializeEmbedding(embedding)
            try await db.write { db in
                try db.execute(
                    sql: "UPDATE memories SET embedding = ? WHERE id = ?",
                    arguments: [data, id]
                )
            }

            vectorIndex.insert(id: id, embedding: embedding)
        } catch {
            Log.app.warning("[memory] failed to embed memory \(id): \(error)")
        }
    }

    // MARK: - Recall

    func recall(category: String? = nil, limit: Int = 20) -> [Memory] {
        do {
            return try db.read { db in
                var query = Memory.order(Column("updatedAt").desc).limit(limit)
                if let category {
                    query = query.filter(Column("category") == category)
                }
                return try query.fetchAll(db)
            }
        } catch {
            Log.app.error("[memory] recall failed: \(error)")
            return []
        }
    }

    // MARK: - Search (Hybrid: Vector + Keyword)

    /// Semantic search using vector similarity, with keyword fallback.
    ///
    /// Previously this used a `DispatchSemaphore` to bridge the async
    /// `semanticSearch` call into a synchronous entry point. That pattern is
    /// rejected by Swift 6 strict concurrency (deadlock-prone when called
    /// from a serial executor) and the only caller is already async, so the
    /// function is now async end-to-end and the semaphore is gone.
    func search(query: String, limit: Int = 10) async -> [Memory] {
        // Try semantic search first.
        if let client = embeddingClient {
            let semanticResults = await semanticSearch(query: query, limit: limit, client: client)
            if !semanticResults.isEmpty {
                return semanticResults
            }
        }
        // Fallback to keyword search when semantic returns empty or when no
        // embedding client is configured.
        return keywordSearch(query: query, limit: limit)
    }

    /// Pure vector similarity search.
    func semanticSearch(query: String, limit: Int = 10, client: (any InferenceProvider)? = nil) async -> [Memory] {
        let provider = client ?? embeddingClient
        guard let provider else { return keywordSearch(query: query, limit: limit) }

        do {
            let embeddings = try await provider.embed(model: embeddingModel, text: [query])
            guard let queryEmb = embeddings.first, !queryEmb.isEmpty else {
                return keywordSearch(query: query, limit: limit)
            }

            let results = vectorIndex.search(query: queryEmb, topK: limit, threshold: 0.25)
            guard !results.isEmpty else { return keywordSearch(query: query, limit: limit) }

            let ids = results.map(\.id)
            return (try? await db.read { db in
                try Memory.filter(ids.contains(Column("id")))
                    .fetchAll(db)
                    .sorted { a, b in
                        let aIdx = ids.firstIndex(of: a.id ?? -1) ?? Int.max
                        let bIdx = ids.firstIndex(of: b.id ?? -1) ?? Int.max
                        return aIdx < bIdx
                    }
            }) ?? []
        } catch {
            Log.app.warning("[memory] semantic search failed: \(error)")
            return keywordSearch(query: query, limit: limit)
        }
    }

    /// Keyword-based search (original behavior, used as fallback).
    func keywordSearch(query: String, limit: Int = 10) -> [Memory] {
        do {
            return try db.read { db in
                try Memory
                    .filter(Column("content").like("%\(query)%"))
                    .order(Column("updatedAt").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[memory] keywordSearch failed: \(error)")
            return []
        }
    }

    // MARK: - Forget

    func forget(memoryId: Int64) -> Bool {
        vectorIndex.remove(id: memoryId)
        do {
            return try db.write { db in
                try Memory.deleteOne(db, id: memoryId)
            }
        } catch {
            Log.app.error("[memory] forget failed: \(error)")
            return false
        }
    }

    // MARK: - Conversations

    func saveConversationSummary(userId: String, summary: String, messageCount: Int) {
        var record = ConversationSummary(
            userId: userId, summary: summary,
            messageCount: messageCount, createdAt: Date()
        )
        do {
            try db.write { db in
                try record.insert(db)
            }
        } catch {
            Log.app.error("[memory] saveConversationSummary failed: \(error)")
        }
    }

    func getRecentConversations(userId: String, limit: Int = 3) -> [ConversationSummary] {
        do {
            return try db.read { db in
                try ConversationSummary
                    .filter(Column("userId") == userId)
                    .order(Column("createdAt").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[memory] getRecentConversations failed: \(error)")
            return []
        }
    }

    // MARK: - Prompt Formatting

    /// Date formatter for the inline `[YYYY-MM-DD]` timestamp prefix.
    /// Cached to avoid the per-call construction cost.
    private static let promptDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    func formatForPrompt(limit: Int = 15) -> String {
        let memories = recall(limit: limit)
        return Self.formatMemoriesForPrompt(memories)
    }

    /// Pure formatter for a list of memories. Each entry gets an inline
    /// `[YYYY-MM-DD]` timestamp so the model can discount stale facts on
    /// its own — "you told me this on 2026-01-12" carries more useful
    /// signal than just "you told me this." Extracted into a static so
    /// the formatting is testable without the database.
    static func formatMemoriesForPrompt(_ memories: [Memory]) -> String {
        guard !memories.isEmpty else { return "" }
        var lines = ["[Persistent Memory — facts the user has previously asked you to remember]"]
        for m in memories {
            let date = promptDateFormatter.string(from: m.updatedAt)
            lines.append("- [\(date)] [\(m.category)] \(m.content)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Backfill

    /// Generate embeddings for all memories that don't have one yet.
    func backfillEmbeddings() async {
        guard let client = embeddingClient else { return }

        let unembedded: [Memory] = (try? await db.read { db in
            try Memory.filter(Column("embedding") == nil).fetchAll(db)
        }) ?? []

        guard !unembedded.isEmpty else { return }
        Log.app.info("[memory] backfilling embeddings for \(unembedded.count) memories")

        for batch in stride(from: 0, to: unembedded.count, by: 16) {
            let end = min(batch + 16, unembedded.count)
            let slice = Array(unembedded[batch..<end])
            let texts = slice.map(\.content)

            do {
                let embeddings = try await client.embed(model: embeddingModel, text: texts)
                for (i, memory) in slice.enumerated() where i < embeddings.count {
                    guard let id = memory.id, !embeddings[i].isEmpty else { continue }
                    let data = Memory.serializeEmbedding(embeddings[i])
                    try? await db.write { db in
                        try db.execute(
                            sql: "UPDATE memories SET embedding = ? WHERE id = ?",
                            arguments: [data, id]
                        )
                    }
                    vectorIndex.insert(id: id, embedding: embeddings[i])
                }
            } catch {
                Log.app.warning("[memory] backfill batch failed: \(error)")
            }
        }

        Log.app.info("[memory] backfill complete")
    }
}
