import Foundation
import GRDB

/// A chunk of a document, with its embedding for vector search.
struct DocumentChunk: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var sourceFile: String        // Original file path
    var chunkIndex: Int           // Position within the document
    var content: String           // The text content
    var embedding: Data           // Serialized [Float] embedding
    var tokenCount: Int           // Estimated tokens in this chunk
    var metadata: String          // JSON metadata (title, section, etc.)
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "document_chunks"

    /// Deserialize embedding from stored Data.
    var embeddingVector: [Float] {
        embedding.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return [] }
            return Array(UnsafeBufferPointer(start: ptr, count: buffer.count / MemoryLayout<Float>.size))
        }
    }

    /// Serialize a Float array to Data for storage.
    static func serializeEmbedding(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}

/// Tracks which files have been ingested and their state.
struct IngestedFile: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var filePath: String
    var fileHash: String       // SHA256 of file contents for change detection
    var chunkCount: Int
    var totalTokens: Int
    var ingestedAt: Date
    var modifiedAt: Date       // File modification date at time of ingestion

    static let databaseTableName = "ingested_files"
}

/// Storage layer for RAG document chunks with vector search capability.
final class ChunkStore {
    private let db: DatabasePool
    private let vectorIndex = VectorIndex()

    init(db: DatabasePool = DatabaseManager.shared.dbPool) {
        self.db = db
    }

    // MARK: - Setup

    /// Load all embeddings from DB into the in-memory vector index.
    func loadVectorIndex() {
        let chunks: [DocumentChunk] = (try? db.read { db in
            try DocumentChunk.fetchAll(db)
        }) ?? []

        let items = chunks.compactMap { chunk -> (id: Int64, embedding: [Float])? in
            guard let id = chunk.id else { return nil }
            let vec = chunk.embeddingVector
            guard !vec.isEmpty else { return nil }
            return (id, vec)
        }

        vectorIndex.insertBatch(items)
        Log.app.info("[chunk-store] loaded \(items.count) embeddings into vector index")
    }

    // MARK: - Insert

    @discardableResult
    func insertChunks(_ chunks: [(content: String, embedding: [Float], metadata: String)],
                       sourceFile: String) -> [Int64] {
        let now = Date()
        var ids: [Int64] = []

        try! db.write { db in
            for (index, chunk) in chunks.enumerated() {
                var record = DocumentChunk(
                    sourceFile: sourceFile,
                    chunkIndex: index,
                    content: chunk.content,
                    embedding: DocumentChunk.serializeEmbedding(chunk.embedding),
                    tokenCount: TokenEstimator.estimate(chunk.content),
                    metadata: chunk.metadata,
                    createdAt: now,
                    updatedAt: now
                )
                try record.insert(db)
                if let id = record.id {
                    ids.append(id)
                    vectorIndex.insert(id: id, embedding: chunk.embedding)
                }
            }
        }

        return ids
    }

    /// Record a file as ingested.
    func recordIngestion(filePath: String, fileHash: String, chunkCount: Int, totalTokens: Int) {
        let now = Date()
        var record = IngestedFile(
            filePath: filePath,
            fileHash: fileHash,
            chunkCount: chunkCount,
            totalTokens: totalTokens,
            ingestedAt: now,
            modifiedAt: now
        )
        try! db.write { db in
            // Delete existing record for this path
            try IngestedFile.filter(Column("filePath") == filePath).deleteAll(db)
            try record.insert(db)
        }
    }

    // MARK: - Search

    /// Semantic search: find chunks most similar to the query embedding.
    func search(queryEmbedding: [Float], topK: Int = 5, threshold: Float = 0.3) -> [(chunk: DocumentChunk, similarity: Float)] {
        let results = vectorIndex.search(query: queryEmbedding, topK: topK, threshold: threshold)
        guard !results.isEmpty else { return [] }

        let ids = results.map(\.id)
        let chunks: [DocumentChunk] = (try? db.read { db in
            try DocumentChunk.filter(ids.contains(Column("id"))).fetchAll(db)
        }) ?? []

        let chunkById = Dictionary(uniqueKeysWithValues: chunks.compactMap { c in
            c.id.map { ($0, c) }
        })

        return results.compactMap { result in
            guard let chunk = chunkById[result.id] else { return nil }
            return (chunk, result.similarity)
        }
    }

    /// Hybrid search: vector similarity + keyword matching.
    func hybridSearch(queryEmbedding: [Float], keywords: String, topK: Int = 5) -> [(chunk: DocumentChunk, score: Float)] {
        // Vector results
        let vectorResults = search(queryEmbedding: queryEmbedding, topK: topK * 2, threshold: 0.2)

        // Keyword results
        let keywordChunks: [DocumentChunk] = (try? db.read { db in
            try DocumentChunk
                .filter(Column("content").like("%\(keywords)%"))
                .limit(topK * 2)
                .fetchAll(db)
        }) ?? []

        // Merge with reciprocal rank fusion
        var scores: [Int64: Float] = [:]

        for (rank, result) in vectorResults.enumerated() {
            guard let id = result.chunk.id else { continue }
            scores[id, default: 0] += 1.0 / Float(rank + 60)  // RRF constant = 60
            scores[id, default: 0] += result.similarity * 0.5  // Boost by similarity
        }

        for (rank, chunk) in keywordChunks.enumerated() {
            guard let id = chunk.id else { continue }
            scores[id, default: 0] += 1.0 / Float(rank + 60)
        }

        // Get all unique chunks
        var allChunks: [Int64: DocumentChunk] = [:]
        for result in vectorResults {
            if let id = result.chunk.id { allChunks[id] = result.chunk }
        }
        for chunk in keywordChunks {
            if let id = chunk.id { allChunks[id] = chunk }
        }

        let ranked = scores.sorted { $0.value > $1.value }.prefix(topK)
        return ranked.compactMap { (id, score) in
            guard let chunk = allChunks[id] else { return nil }
            return (chunk, score)
        }
    }

    // MARK: - Management

    /// Remove all chunks for a source file.
    func removeFile(_ filePath: String) {
        let chunks: [DocumentChunk] = (try? db.read { db in
            try DocumentChunk.filter(Column("sourceFile") == filePath).fetchAll(db)
        }) ?? []

        for chunk in chunks {
            if let id = chunk.id { vectorIndex.remove(id: id) }
        }

        try! db.write { db in
            try DocumentChunk.filter(Column("sourceFile") == filePath).deleteAll(db)
            try IngestedFile.filter(Column("filePath") == filePath).deleteAll(db)
        }
    }

    /// Check if a file needs re-ingestion (hash changed).
    func needsIngestion(filePath: String, currentHash: String) -> Bool {
        let existing: IngestedFile? = try? db.read { db in
            try IngestedFile.filter(Column("filePath") == filePath).fetchOne(db)
        }
        return existing?.fileHash != currentHash
    }

    /// Get all ingested files.
    func ingestedFiles() -> [IngestedFile] {
        (try? db.read { db in
            try IngestedFile.order(Column("ingestedAt").desc).fetchAll(db)
        }) ?? []
    }

    /// Total chunks across all documents.
    func totalChunkCount() -> Int {
        vectorIndex.count
    }
}
