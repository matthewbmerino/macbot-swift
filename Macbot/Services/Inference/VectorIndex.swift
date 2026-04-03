import Accelerate
import Foundation

/// High-performance vector similarity search using Apple's Accelerate framework.
/// Uses vDSP for SIMD-optimized dot products and norms — runs on Apple's AMX coprocessor.
final class VectorIndex: @unchecked Sendable {
    struct Entry {
        let id: Int64
        let embedding: [Float]
        let norm: Float
    }

    private var entries: [Entry] = []
    private let lock = NSLock()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Insert

    func insert(id: Int64, embedding: [Float]) {
        let norm = Self.l2Norm(embedding)
        guard norm > 0 else { return }

        lock.lock()
        entries.append(Entry(id: id, embedding: embedding, norm: norm))
        lock.unlock()
    }

    func insertBatch(_ items: [(id: Int64, embedding: [Float])]) {
        let newEntries = items.compactMap { item -> Entry? in
            let norm = Self.l2Norm(item.embedding)
            guard norm > 0 else { return nil }
            return Entry(id: item.id, embedding: item.embedding, norm: norm)
        }

        lock.lock()
        entries.append(contentsOf: newEntries)
        lock.unlock()
    }

    func remove(id: Int64) {
        lock.lock()
        entries.removeAll { $0.id == id }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    // MARK: - Search

    /// Find the top-k most similar entries to the query embedding.
    /// Returns (id, similarity) pairs sorted by descending similarity.
    func search(query: [Float], topK: Int = 5, threshold: Float = 0.0) -> [(id: Int64, similarity: Float)] {
        let queryNorm = Self.l2Norm(query)
        guard queryNorm > 0 else { return [] }

        lock.lock()
        let snapshot = entries
        lock.unlock()

        guard !snapshot.isEmpty else { return [] }

        let dim = query.count
        var results: [(id: Int64, similarity: Float)] = []
        results.reserveCapacity(snapshot.count)

        for entry in snapshot {
            guard entry.embedding.count == dim else { continue }
            let similarity = Self.cosineSimilarity(query, queryNorm, entry.embedding, entry.norm)
            if similarity >= threshold {
                results.append((entry.id, similarity))
            }
        }

        results.sort { $0.similarity > $1.similarity }
        return Array(results.prefix(topK))
    }

    /// Batch search — run multiple queries in parallel.
    func batchSearch(queries: [[Float]], topK: Int = 5, threshold: Float = 0.0) -> [[(id: Int64, similarity: Float)]] {
        queries.map { search(query: $0, topK: topK, threshold: threshold) }
    }

    // MARK: - Accelerate SIMD Operations

    /// L2 norm using vDSP (SIMD-optimized on Apple Silicon AMX).
    static func l2Norm(_ vector: [Float]) -> Float {
        var result: Float = 0
        vDSP_svesq(vector, 1, &result, vDSP_Length(vector.count))
        return sqrt(result)
    }

    /// Cosine similarity using vDSP dot product.
    /// Pre-computed norms avoid redundant computation.
    static func cosineSimilarity(
        _ a: [Float], _ aNorm: Float,
        _ b: [Float], _ bNorm: Float
    ) -> Float {
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(min(a.count, b.count)))
        let denom = aNorm * bNorm
        return denom > 0 ? dot / denom : 0
    }

    /// Cosine similarity without pre-computed norms.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        cosineSimilarity(a, l2Norm(a), b, l2Norm(b))
    }

    /// Euclidean distance using vDSP.
    static func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        var diff = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &diff, 1, vDSP_Length(a.count))
        var sumSq: Float = 0
        vDSP_svesq(diff, 1, &sumSq, vDSP_Length(diff.count))
        return sqrt(sumSq)
    }
}
