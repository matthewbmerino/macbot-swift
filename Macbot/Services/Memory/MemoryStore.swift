import Accelerate
import Foundation
import GRDB

struct Memory: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var category: String
    var content: String
    var metadata: String
    var embedding: Data?  // Serialized [Float] for vector search
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "memories"

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

struct ConversationSummary: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var userId: String
    var summary: String
    var messageCount: Int
    var createdAt: Date

    static let databaseTableName = "conversations"
}

/// Persistent memory store with semantic vector search.
///
/// Memories are stored in SQLite with GRDB, and their embeddings are
/// indexed in an in-memory VectorIndex for fast cosine similarity search.
/// Falls back to keyword search when embeddings are unavailable.
final class MemoryStore {
    private let db: DatabasePool
    private let vectorIndex = VectorIndex()

    /// Optional inference client for generating embeddings.
    /// Set after initialization to enable semantic search.
    var embeddingClient: (any InferenceProvider)?
    var embeddingModel: String = "qwen3-embedding:0.6b"

    init(db: DatabasePool = DatabaseManager.shared.dbPool) {
        self.db = db
        loadVectorIndex()
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
        try! db.write { db in
            try memory.insert(db)
        }

        let id = memory.id!

        // Generate embedding asynchronously
        Task {
            await generateAndStoreEmbedding(id: id, content: content)
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
        try! db.read { db in
            var query = Memory.order(Column("updatedAt").desc).limit(limit)
            if let category {
                query = query.filter(Column("category") == category)
            }
            return try query.fetchAll(db)
        }
    }

    // MARK: - Search (Hybrid: Vector + Keyword)

    /// Semantic search using vector similarity, with keyword fallback.
    func search(query: String, limit: Int = 10) -> [Memory] {
        // Try semantic search first
        if let client = embeddingClient {
            let semaphore = DispatchSemaphore(value: 0)
            var semanticResults: [Memory]?

            Task {
                semanticResults = await semanticSearch(query: query, limit: limit, client: client)
                semaphore.signal()
            }

            if semaphore.wait(timeout: .now() + 5) == .success, let results = semanticResults, !results.isEmpty {
                return results
            }
        }

        // Fallback to keyword search
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
        try! db.read { db in
            try Memory
                .filter(Column("content").like("%\(query)%"))
                .order(Column("updatedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Forget

    func forget(memoryId: Int64) -> Bool {
        vectorIndex.remove(id: memoryId)
        return try! db.write { db in
            try Memory.deleteOne(db, id: memoryId)
        }
    }

    // MARK: - Conversations

    func saveConversationSummary(userId: String, summary: String, messageCount: Int) {
        var record = ConversationSummary(
            userId: userId, summary: summary,
            messageCount: messageCount, createdAt: Date()
        )
        try! db.write { db in
            try record.insert(db)
        }
    }

    func getRecentConversations(userId: String, limit: Int = 3) -> [ConversationSummary] {
        try! db.read { db in
            try ConversationSummary
                .filter(Column("userId") == userId)
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Prompt Formatting

    func formatForPrompt(limit: Int = 15) -> String {
        let memories = recall(limit: limit)
        guard !memories.isEmpty else { return "" }

        var lines = ["[Persistent Memory]"]
        for m in memories {
            lines.append("- [\(m.category)] \(m.content)")
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
