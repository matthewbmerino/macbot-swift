import CommonCrypto
import Foundation

/// Ingests documents into the RAG pipeline: reads files, chunks text,
/// generates embeddings, and stores in ChunkStore for retrieval.
///
/// Supports: .txt, .md, .swift, .py, .js, .ts, .json, .csv, .html, .xml, .yaml, .toml
/// Chunking strategy: semantic splitting by paragraphs/sections with overlap.
final class DocumentIngester {
    struct Config {
        var chunkSize: Int = 512         // Target tokens per chunk
        var chunkOverlap: Int = 64       // Token overlap between chunks
        var maxFileSize: Int = 10_000_000 // 10MB max file size
        var batchSize: Int = 16          // Embeddings per batch
        var supportedExtensions: Set<String> = [
            "txt", "md", "markdown", "swift", "py", "js", "ts", "tsx", "jsx",
            "json", "csv", "html", "xml", "yaml", "yml", "toml", "rs", "go",
            "java", "kt", "c", "cpp", "h", "hpp", "rb", "sh", "zsh", "bash",
            "sql", "r", "lua", "dockerfile", "makefile", "cmake",
        ]
    }

    private let client: any InferenceProvider
    private let embeddingModel: String
    private let chunkStore: ChunkStore
    private let config: Config

    init(
        client: any InferenceProvider,
        embeddingModel: String = "qwen3-embedding:0.6b",
        chunkStore: ChunkStore,
        config: Config = Config()
    ) {
        self.client = client
        self.embeddingModel = embeddingModel
        self.chunkStore = chunkStore
        self.config = config
    }

    // MARK: - Ingest

    /// Ingest a single file into the RAG store.
    @discardableResult
    func ingestFile(at path: String) async throws -> Int {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        guard config.supportedExtensions.contains(ext) else {
            throw IngestionError.unsupportedFormat(ext)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = attributes[.size] as? Int ?? 0
        guard fileSize <= config.maxFileSize else {
            throw IngestionError.fileTooLarge(path, fileSize)
        }

        // Read and hash the file
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let hash = sha256(content)

        // Check if re-ingestion needed
        guard chunkStore.needsIngestion(filePath: path, currentHash: hash) else {
            Log.app.info("[ingester] skipping \(url.lastPathComponent) (unchanged)")
            return 0
        }

        // Remove old chunks for this file
        chunkStore.removeFile(path)

        // Chunk the content
        let textChunks = chunk(content: content, fileExtension: ext)
        guard !textChunks.isEmpty else { return 0 }

        Log.app.info("[ingester] chunked \(url.lastPathComponent) into \(textChunks.count) chunks")

        // Generate embeddings in batches
        var chunksWithEmbeddings: [(content: String, embedding: [Float], metadata: String)] = []
        var totalTokens = 0

        for batchStart in stride(from: 0, to: textChunks.count, by: config.batchSize) {
            let batchEnd = min(batchStart + config.batchSize, textChunks.count)
            let batch = Array(textChunks[batchStart..<batchEnd])
            let texts = batch.map(\.content)

            let embeddings = try await client.embed(model: embeddingModel, text: texts)

            for (i, chunk) in batch.enumerated() {
                let embedding = i < embeddings.count ? embeddings[i] : []
                let metadata = """
                {"source": "\(url.lastPathComponent)", "section": "\(chunk.section)", "index": \(batchStart + i)}
                """
                chunksWithEmbeddings.append((chunk.content, embedding, metadata))
                totalTokens += TokenEstimator.estimate(chunk.content)
            }
        }

        // Store chunks
        chunkStore.insertChunks(chunksWithEmbeddings, sourceFile: path)
        chunkStore.recordIngestion(
            filePath: path, fileHash: hash,
            chunkCount: chunksWithEmbeddings.count,
            totalTokens: totalTokens
        )

        Log.app.info("[ingester] ingested \(url.lastPathComponent): \(chunksWithEmbeddings.count) chunks, ~\(totalTokens) tokens")
        return chunksWithEmbeddings.count
    }

    /// Ingest all supported files in a directory (recursive).
    func ingestDirectory(at path: String) async throws -> (files: Int, chunks: Int) {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw IngestionError.directoryNotFound(path)
        }

        var fileCount = 0
        var totalChunks = 0

        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            guard config.supportedExtensions.contains(ext) else { continue }

            do {
                let chunks = try await ingestFile(at: fileURL.path)
                if chunks > 0 {
                    fileCount += 1
                    totalChunks += chunks
                }
            } catch {
                Log.app.warning("[ingester] failed to ingest \(fileURL.lastPathComponent): \(error)")
            }
        }

        Log.app.info("[ingester] directory scan complete: \(fileCount) files, \(totalChunks) chunks")
        return (fileCount, totalChunks)
    }

    // MARK: - Chunking

    struct TextChunk {
        let content: String
        let section: String  // Section header or context label
    }

    /// Split content into overlapping chunks using semantic boundaries.
    func chunk(content: String, fileExtension: String) -> [TextChunk] {
        switch fileExtension {
        case "md", "markdown":
            return chunkMarkdown(content)
        case "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "rs", "go",
             "c", "cpp", "h", "hpp", "rb":
            return chunkCode(content, language: fileExtension)
        default:
            return chunkPlainText(content)
        }
    }

    /// Chunk markdown by headers and paragraphs.
    private func chunkMarkdown(_ content: String) -> [TextChunk] {
        let lines = content.components(separatedBy: "\n")
        var chunks: [TextChunk] = []
        var currentSection = "introduction"
        var currentChunk = ""
        var currentTokens = 0

        for line in lines {
            // Detect headers
            if line.hasPrefix("#") {
                // Flush current chunk
                if !currentChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append(TextChunk(content: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines), section: currentSection))
                }

                currentSection = line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
                currentChunk = line + "\n"
                currentTokens = TokenEstimator.estimate(line)
                continue
            }

            let lineTokens = TokenEstimator.estimate(line)

            if currentTokens + lineTokens > config.chunkSize {
                // Flush with overlap
                if !currentChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append(TextChunk(content: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines), section: currentSection))
                }

                // Keep overlap from end of previous chunk
                let overlapLines = currentChunk.components(separatedBy: "\n").suffix(3)
                currentChunk = overlapLines.joined(separator: "\n") + "\n"
                currentTokens = TokenEstimator.estimate(currentChunk)
            }

            currentChunk += line + "\n"
            currentTokens += lineTokens
        }

        // Final chunk
        let trimmed = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            chunks.append(TextChunk(content: trimmed, section: currentSection))
        }

        return chunks
    }

    /// Chunk code by function/class boundaries.
    private func chunkCode(_ content: String, language: String) -> [TextChunk] {
        let lines = content.components(separatedBy: "\n")
        var chunks: [TextChunk] = []
        var currentChunk = ""
        var currentTokens = 0
        var currentSection = "top-level"
        var braceDepth = 0

        // Patterns for function/class detection
        let funcPattern = try? NSRegularExpression(
            pattern: "^\\s*(func |def |function |class |struct |enum |impl |pub fn |async fn )",
            options: []
        )

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)

            // Detect section boundaries
            if let _ = funcPattern?.firstMatch(in: line, range: range) {
                if braceDepth == 0 && currentTokens > config.chunkSize / 4 {
                    // Flush at function boundary
                    let trimmed = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        chunks.append(TextChunk(content: trimmed, section: currentSection))
                    }
                    currentChunk = ""
                    currentTokens = 0
                }
                currentSection = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: "(").first ?? "function"
            }

            // Track brace depth for block boundaries
            braceDepth += line.filter({ $0 == "{" }).count
            braceDepth -= line.filter({ $0 == "}" }).count
            braceDepth = max(0, braceDepth)

            let lineTokens = TokenEstimator.estimate(line)

            if currentTokens + lineTokens > config.chunkSize && braceDepth == 0 {
                let trimmed = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunks.append(TextChunk(content: trimmed, section: currentSection))
                }

                let overlapLines = currentChunk.components(separatedBy: "\n").suffix(2)
                currentChunk = overlapLines.joined(separator: "\n") + "\n"
                currentTokens = TokenEstimator.estimate(currentChunk)
            }

            currentChunk += line + "\n"
            currentTokens += lineTokens
        }

        let trimmed = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            chunks.append(TextChunk(content: trimmed, section: currentSection))
        }

        return chunks
    }

    /// Chunk plain text by paragraphs.
    private func chunkPlainText(_ content: String) -> [TextChunk] {
        let paragraphs = content.components(separatedBy: "\n\n")
        var chunks: [TextChunk] = []
        var currentChunk = ""
        var currentTokens = 0

        for para in paragraphs {
            let paraTokens = TokenEstimator.estimate(para)

            if currentTokens + paraTokens > config.chunkSize && !currentChunk.isEmpty {
                chunks.append(TextChunk(
                    content: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines),
                    section: "text"
                ))

                // Overlap: keep last paragraph
                let lastPara = currentChunk.components(separatedBy: "\n\n").last ?? ""
                currentChunk = lastPara + "\n\n"
                currentTokens = TokenEstimator.estimate(currentChunk)
            }

            currentChunk += para + "\n\n"
            currentTokens += paraTokens
        }

        let trimmed = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            chunks.append(TextChunk(content: trimmed, section: "text"))
        }

        return chunks
    }

    // MARK: - Hashing

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

enum IngestionError: Error, LocalizedError {
    case unsupportedFormat(String)
    case fileTooLarge(String, Int)
    case directoryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): "Unsupported file format: .\(ext)"
        case .fileTooLarge(let path, let size): "File too large (\(size / 1_000_000)MB): \(path)"
        case .directoryNotFound(let path): "Directory not found: \(path)"
        }
    }
}
