import Accelerate
import Foundation
import os

/// Embedding-based router that classifies messages using cosine similarity
/// against pre-computed category centroids. Faster and more deterministic
/// than LLM-based routing — ~50ms vs ~500ms.
final class EmbeddingRouter: Sendable {
    private let client: any InferenceProvider
    private let embeddingModel: String

    /// Mutable state protected by an unfair lock. All accesses are short-held
    /// and never span `await`, so `OSAllocatedUnfairLock.withLock {}` is safe
    /// and avoids the Swift 6 strict-concurrency pitfalls of `NSLock` in async
    /// functions.
    private struct State {
        /// Pre-computed centroids for each agent category.
        /// Each centroid is the average embedding of representative queries.
        var centroids: [AgentCategory: [Float]] = [:]
        var centroidNorms: [AgentCategory: Float] = [:]
        var isCalibrated = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    // Representative queries per category — used to build centroids
    private static let seedQueries: [AgentCategory: [String]] = [
        .coder: [
            "write a python function to sort a list",
            "fix this bug in my code",
            "implement a REST API endpoint",
            "refactor this class to use dependency injection",
            "debug this segmentation fault",
            "create a dockerfile for this project",
            "write unit tests for the parser module",
            "optimize this SQL query performance",
            "how do I use async await in Swift",
            "explain this regex pattern",
        ],
        .reasoner: [
            "calculate the derivative of x^3 + 2x",
            "solve this system of equations",
            "prove that the square root of 2 is irrational",
            "what is the probability of drawing two aces",
            "if all A are B and some B are C then what follows",
            "analyze the time complexity of this algorithm",
            "solve this optimization problem using calculus",
            "what is the expected value of this distribution",
            "prove by induction that the sum formula holds",
            "explain the logic behind this proof",
        ],
        .vision: [
            "what do you see in this image",
            "describe this screenshot",
            "read the text in this photo",
            "analyze this chart image",
            "what objects are in this picture",
            "compare these two images",
            "identify the brand in this logo",
            "what color scheme is used in this design",
            "extract the data from this graph",
            "describe the layout of this UI mockup",
        ],
        .general: [
            "what is the weather like today",
            "summarize this article for me",
            "write an email to my team about the deadline",
            "what are the latest news about AI",
            "help me plan a trip to Japan",
            "take a screenshot of my desktop",
            "search the web for recent GPU benchmarks",
            "open the calculator app",
            "what files are in my documents folder",
            "remind me about the meeting tomorrow",
        ],
        .rag: [
            "what does the documentation say about authentication",
            "find the relevant section about deployment",
            "search my notes for the project timeline",
            "what did the report say about Q3 revenue",
            "look up the API specification for endpoints",
            "find information about the database schema",
            "what is the policy on remote work",
            "search the knowledge base for error codes",
            "what do my documents say about the migration plan",
            "find the design document for the new feature",
        ],
    ]

    init(client: any InferenceProvider, embeddingModel: String = "qwen3-embedding:0.6b") {
        self.client = client
        self.embeddingModel = embeddingModel
    }

    /// Calibrate the router by computing centroids from seed queries.
    /// Call once at startup after the embedding model is available.
    func calibrate() async {
        Log.agents.info("[embedding-router] calibrating with seed queries...")

        for (category, queries) in Self.seedQueries {
            do {
                let embeddings = try await client.embed(model: embeddingModel, text: queries)
                guard !embeddings.isEmpty else { continue }

                let centroid = Self.averageEmbedding(embeddings)
                let norm = VectorIndex.l2Norm(centroid)

                state.withLock { s in
                    s.centroids[category] = centroid
                    s.centroidNorms[category] = norm
                }

                Log.agents.info("[embedding-router] calibrated \(category.rawValue) with \(embeddings.count) embeddings (dim=\(centroid.count))")
            } catch {
                Log.agents.warning("[embedding-router] failed to calibrate \(category.rawValue): \(error)")
            }
        }

        let count = state.withLock { s -> Int in
            s.isCalibrated = !s.centroids.isEmpty
            return s.centroids.count
        }
        Log.agents.info("[embedding-router] calibration complete: \(count) categories")
    }

    /// Classify a message into an agent category.
    /// Returns the category with highest cosine similarity to the message embedding.
    func classify(message: String, hasImages: Bool = false) async -> AgentCategory {
        if hasImages { return .vision }

        let calibrated = state.withLock { $0.isCalibrated }

        guard calibrated else {
            Log.agents.warning("[embedding-router] not calibrated, defaulting to general")
            return .general
        }

        do {
            let embeddings = try await client.embed(model: embeddingModel, text: [message])
            guard let queryEmb = embeddings.first, !queryEmb.isEmpty else {
                return .general
            }

            let queryNorm = VectorIndex.l2Norm(queryEmb)
            guard queryNorm > 0 else { return .general }

            let (snapshotCentroids, snapshotNorms) = state.withLock { s in
                (s.centroids, s.centroidNorms)
            }

            var bestCategory: AgentCategory = .general
            var bestSimilarity: Float = -1

            for (category, centroid) in snapshotCentroids {
                guard let norm = snapshotNorms[category] else { continue }
                let sim = VectorIndex.cosineSimilarity(queryEmb, queryNorm, centroid, norm)
                if sim > bestSimilarity {
                    bestSimilarity = sim
                    bestCategory = category
                }
            }

            // Confidence threshold — if best similarity is low, default to general
            if bestSimilarity < 0.3 && bestCategory != .general {
                Log.agents.info("[embedding-router] low confidence (\(bestSimilarity)) for \(bestCategory.rawValue), defaulting to general")
                return .general
            }

            Log.agents.info("[embedding-router] classified as \(bestCategory.rawValue) (sim=\(String(format: "%.3f", bestSimilarity)))")
            return bestCategory
        } catch {
            Log.agents.warning("[embedding-router] embedding failed: \(error), defaulting to general")
            return .general
        }
    }

    /// Get similarity scores for all categories (for debugging/UI).
    func classifyWithScores(message: String) async -> [(AgentCategory, Float)] {
        let calibrated = state.withLock { $0.isCalibrated }

        guard calibrated else { return [] }

        do {
            let embeddings = try await client.embed(model: embeddingModel, text: [message])
            guard let queryEmb = embeddings.first else { return [] }

            let queryNorm = VectorIndex.l2Norm(queryEmb)
            guard queryNorm > 0 else { return [] }

            let (snapshotCentroids, snapshotNorms) = state.withLock { s in
                (s.centroids, s.centroidNorms)
            }

            var scores: [(AgentCategory, Float)] = []
            for (category, centroid) in snapshotCentroids {
                guard let norm = snapshotNorms[category] else { continue }
                let sim = VectorIndex.cosineSimilarity(queryEmb, queryNorm, centroid, norm)
                scores.append((category, sim))
            }

            return scores.sorted { $0.1 > $1.1 }
        } catch {
            return []
        }
    }

    // MARK: - Helpers

    /// Compute the average of multiple embeddings (centroid).
    private static func averageEmbedding(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)

        for emb in embeddings {
            guard emb.count == dim else { continue }
            vDSP_vadd(sum, 1, emb, 1, &sum, 1, vDSP_Length(dim))
        }

        var scale = Float(embeddings.count)
        vDSP_vsdiv(sum, 1, &scale, &sum, 1, vDSP_Length(dim))
        return sum
    }
}
