import Foundation

/// RAG (Retrieval-Augmented Generation) agent that answers questions using
/// ingested documents. Retrieves relevant chunks via vector similarity,
/// re-ranks them, and injects context into the prompt.
final class RAGAgent: BaseAgent {
    let chunkStore: ChunkStore
    let ingester: DocumentIngester
    private let embeddingModel: String

    /// Maximum tokens of retrieved context to inject.
    private let maxContextTokens = 4096

    /// Minimum similarity threshold for retrieved chunks.
    private let similarityThreshold: Float = 0.25

    init(
        client: any InferenceProvider,
        model: String = "qwen3.5:9b",
        embeddingModel: String = "qwen3-embedding:0.6b",
        chunkStore: ChunkStore
    ) {
        self.chunkStore = chunkStore
        self.embeddingModel = embeddingModel
        self.ingester = DocumentIngester(
            client: client,
            embeddingModel: embeddingModel,
            chunkStore: chunkStore
        )

        super.init(
            name: "knowledge",
            model: model,
            systemPrompt: """
            You are a knowledge retrieval agent. You answer questions using information from the user's documents and files.

            When context is provided from retrieved documents:
            - Base your answers primarily on the provided context
            - Quote relevant passages when appropriate
            - If the context doesn't contain enough information, say so honestly
            - Cite the source file when referencing specific information

            When no context is available:
            - Use your general knowledge to answer
            - Recommend the user ingest relevant documents using /ingest <path>
            """,
            temperature: 0.3,
            numCtx: 32768,
            client: client
        )
    }

    // MARK: - Override run to inject RAG context

    override func run(_ input: String, images: [Data]? = nil, plan: Bool = false) async throws -> String {
        // Retrieve relevant context
        let context = try await retrieveContext(for: input)

        // Inject context into the conversation
        var augmentedInput = input
        if !context.isEmpty {
            augmentedInput = """
            [Retrieved Context]
            \(context)

            [User Question]
            \(input)
            """
        }

        return try await super.run(augmentedInput, images: images, plan: plan)
    }

    override func runStream(_ input: String, images: [Data]? = nil, plan: Bool = false) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(.status("Searching knowledge base..."))

                    let context = try await retrieveContext(for: input)

                    var augmentedInput = input
                    if !context.isEmpty {
                        let chunkCount = context.components(separatedBy: "\n---\n").count
                        continuation.yield(.status("Found \(chunkCount) relevant passages. Generating answer..."))

                        augmentedInput = """
                        [Retrieved Context]
                        \(context)

                        [User Question]
                        \(input)
                        """
                    } else {
                        continuation.yield(.status("No relevant documents found. Answering from general knowledge."))
                    }

                    for try await event in super.runStream(augmentedInput, images: images, plan: plan) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Retrieval

    /// Retrieve and format context from the chunk store.
    private func retrieveContext(for query: String) async throws -> String {
        guard chunkStore.totalChunkCount() > 0 else { return "" }

        // Embed the query
        let embeddings = try await client.embed(model: embeddingModel, text: [query])
        guard let queryEmbedding = embeddings.first, !queryEmbedding.isEmpty else { return "" }

        // Extract keywords for hybrid search
        let keywords = extractKeywords(from: query)

        // Hybrid search: vector + keyword
        let results = chunkStore.hybridSearch(
            queryEmbedding: queryEmbedding,
            keywords: keywords,
            topK: 8
        )

        guard !results.isEmpty else { return "" }

        // Re-rank: use the model to score relevance (if chunks > 3)
        let ranked: [(chunk: DocumentChunk, score: Float)]
        if results.count > 3 {
            ranked = await rerank(query: query, candidates: results)
        } else {
            ranked = results
        }

        // Build context string within token budget
        var contextParts: [String] = []
        var tokenBudget = maxContextTokens

        for result in ranked {
            let chunkText = formatChunk(result.chunk, similarity: result.score)
            let chunkTokens = TokenEstimator.estimate(chunkText)

            if tokenBudget - chunkTokens < 0 { break }
            contextParts.append(chunkText)
            tokenBudget -= chunkTokens
        }

        return contextParts.joined(separator: "\n---\n")
    }

    /// Re-rank candidates using the LLM for better relevance scoring.
    private func rerank(
        query: String,
        candidates: [(chunk: DocumentChunk, score: Float)]
    ) async -> [(chunk: DocumentChunk, score: Float)] {
        // Use a lightweight re-ranking prompt
        let candidateTexts = candidates.prefix(6).enumerated().map { (i, result) in
            "[\(i)] \(String(result.chunk.content.prefix(200)))"
        }.joined(separator: "\n")

        do {
            let resp = try await client.chat(
                model: "qwen3.5:0.8b",
                messages: [
                    ["role": "system", "content": "Rank these passages by relevance to the query. Output ONLY a comma-separated list of indices (e.g., 2,0,4,1,3). No other text."],
                    ["role": "user", "content": "Query: \(query)\n\nPassages:\n\(candidateTexts)"],
                ],
                tools: nil,
                temperature: 0.1,
                numCtx: 2048,
                timeout: 15
            )

            let content = ThinkingStripper.strip(resp.content)
            let indices = content.components(separatedBy: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 >= 0 && $0 < candidates.count }

            // Build re-ranked list
            var reranked: [(chunk: DocumentChunk, score: Float)] = []
            var seen = Set<Int>()
            for idx in indices where !seen.contains(idx) {
                seen.insert(idx)
                reranked.append(candidates[idx])
            }
            // Append any candidates not mentioned by the re-ranker
            for (i, c) in candidates.enumerated() where !seen.contains(i) {
                reranked.append(c)
            }

            return reranked
        } catch {
            Log.agents.warning("[rag] re-ranking failed: \(error)")
            return Array(candidates)
        }
    }

    /// Format a chunk for injection into the prompt.
    private func formatChunk(_ chunk: DocumentChunk, similarity: Float) -> String {
        let source = URL(fileURLWithPath: chunk.sourceFile).lastPathComponent
        return """
        Source: \(source) (section: \(chunk.metadata))
        Relevance: \(String(format: "%.0f%%", similarity * 100))
        \(chunk.content)
        """
    }

    /// Extract search keywords from a query.
    private func extractKeywords(from query: String) -> String {
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been",
            "being", "have", "has", "had", "do", "does", "did", "will",
            "would", "could", "should", "may", "might", "can", "shall",
            "to", "of", "in", "for", "on", "with", "at", "by", "from",
            "it", "its", "this", "that", "these", "those", "what", "which",
            "who", "whom", "how", "when", "where", "why", "and", "or",
            "not", "no", "but", "if", "then", "than", "so", "as", "about",
            "my", "your", "his", "her", "our", "their", "me", "you", "i",
        ]

        return query.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
            .prefix(5)
            .joined(separator: " ")
    }
}
