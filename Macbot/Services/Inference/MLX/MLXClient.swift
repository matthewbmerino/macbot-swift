import Foundation
import Hub
import MLX
import MLXFast
import MLXNN
import MLXRandom
import os
import Tokenizers

// MARK: - MLX Client

/// MLX-native inference provider for Apple Silicon.
final class MLXClient: InferenceProvider, @unchecked Sendable {
    let modelDirectory: URL
    let fallback: OllamaClient?
    /// `loadedModels` is protected by `loadedModelsLock`. All call sites are
    /// short-held (dictionary read/write only) and never span an `await`, so
    /// `OSAllocatedUnfairLock.withLock {}` is safe here and avoids the Swift 6
    /// strict-concurrency hazard of `NSLock` inside async functions.
    let loadedModelsLock = OSAllocatedUnfairLock<[String: LoadedMLXModel]>(initialState: [:])

    private var draftModel: String?
    let promptCache = PromptCacheManager()

    private(set) var lastTokensPerSecond: Double = 0
    private(set) var lastTimeToFirstToken: TimeInterval = 0

    static let modelCatalog: [String: MLXModelSpec] = [
        "qwen3.5:4b": MLXModelSpec(
            huggingFaceId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            contextLength: 32768, quantization: .q4
        ),
        "qwen3.5:9b": MLXModelSpec(
            huggingFaceId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            contextLength: 32768, quantization: .q4
        ),
        "qwen3.5:30b": MLXModelSpec(
            huggingFaceId: "mlx-community/Qwen2.5-32B-Instruct-4bit",
            contextLength: 32768, quantization: .q4
        ),
        "qwen2.5-coder:7b": MLXModelSpec(
            huggingFaceId: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            contextLength: 65536, quantization: .q4
        ),
        "qwen2.5-coder:14b": MLXModelSpec(
            huggingFaceId: "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit",
            contextLength: 65536, quantization: .q4
        ),
        "deepseek-r1:8b": MLXModelSpec(
            huggingFaceId: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
            contextLength: 32768, quantization: .q4
        ),
        "deepseek-r1:14b": MLXModelSpec(
            huggingFaceId: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit",
            contextLength: 32768, quantization: .q4
        ),
        "qwen3.5:0.8b": MLXModelSpec(
            huggingFaceId: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            contextLength: 4096, quantization: .q4
        ),
        "qwen3-embedding:0.6b": MLXModelSpec(
            huggingFaceId: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            contextLength: 2048, quantization: .q4
        ),

        // Gemma 4 — MoE (26B total, 4B active per token)
        "gemma4:26b-a4b": MLXModelSpec(
            huggingFaceId: "mlx-community/gemma-4-26b-a4b-it-4bit",
            contextLength: 131072, quantization: .q4
        ),
        // Gemma 4 — Edge models
        "gemma4:e4b": MLXModelSpec(
            huggingFaceId: "mlx-community/gemma-4-e4b-it-4bit",
            contextLength: 32768, quantization: .q4
        ),
        "gemma4:e2b": MLXModelSpec(
            huggingFaceId: "mlx-community/gemma-4-e2b-it-4bit",
            contextLength: 32768, quantization: .q4
        ),

        // Mistral / Devstral — code specialist
        "devstral-small-2": MLXModelSpec(
            huggingFaceId: "mlx-community/Devstral-Small-2503-4bit",
            contextLength: 131072, quantization: .q4
        ),
        "codestral:22b": MLXModelSpec(
            huggingFaceId: "mlx-community/Codestral-22B-v0.1-4bit",
            contextLength: 32768, quantization: .q4
        ),
    ]

    init(modelDirectory: URL? = nil, fallback: OllamaClient? = nil) {
        self.modelDirectory = modelDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Macbot/mlx-models", isDirectory: true)
        self.fallback = fallback
        try? FileManager.default.createDirectory(at: self.modelDirectory, withIntermediateDirectories: true)
        Log.inference.info("[mlx] model directory: \(self.modelDirectory.path)")
    }

    // MARK: - InferenceProvider

    func chat(
        model: String,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        temperature: Double,
        numCtx: Int,
        timeout: TimeInterval?
    ) async throws -> ChatResponse {
        guard let spec = Self.modelCatalog[model] else {
            guard let fallback else { throw MLXError.modelNotFound(model) }
            return try await fallback.chat(model: model, messages: messages, tools: tools,
                                           temperature: temperature, numCtx: numCtx, timeout: timeout)
        }

        do {
            let loaded = try await getOrLoadModel(spec: spec)
            let prompt = buildPrompt(for: loaded.architecture, messages: messages)
            let startTime = CFAbsoluteTimeGetCurrent()

            let output = try generate(
                loaded: loaded, prompt: prompt,
                temperature: temperature, maxTokens: min(2048, numCtx / 4)
            )

            // Detect garbage output (repetitive single characters = broken weights)
            if isGarbageOutput(output) {
                Log.inference.warning("[mlx] garbage output detected, falling back to Ollama")
                ActivityLog.shared.log(.inference, "MLX output invalid, falling back to Ollama")
                if let fallback {
                    return try await fallback.chat(model: model, messages: messages, tools: tools,
                                                   temperature: temperature, numCtx: numCtx, timeout: timeout)
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let tokenCount = TokenEstimator.estimate(output)
            self.lastTokensPerSecond = Double(tokenCount) / max(elapsed, 0.001)

            let tps = self.lastTokensPerSecond
            Log.inference.info("[mlx] generated \(tokenCount) tokens in \(String(format: "%.1f", elapsed))s (\(String(format: "%.0f", tps)) tok/s)")

            let toolCalls = tools != nil ? parseToolCalls(from: output) : nil
            let content = toolCalls != nil ? cleanToolCallContent(output) : output
            return ChatResponse(content: content, toolCalls: toolCalls)
        } catch {
            // Fall back to Ollama on any MLX error
            if let fallback {
                Log.inference.warning("[mlx] inference failed (\(error)), falling back to Ollama")
                return try await fallback.chat(model: model, messages: messages, tools: tools,
                                               temperature: temperature, numCtx: numCtx, timeout: timeout)
            }
            throw error
        }
    }

    func chatStream(
        model: String,
        messages: [[String: Any]],
        temperature: Double,
        numCtx: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let spec = Self.modelCatalog[model] else {
                        if let fallback {
                            for try await token in fallback.chatStream(
                                model: model, messages: messages,
                                temperature: temperature, numCtx: numCtx
                            ) { continuation.yield(token) }
                            continuation.finish()
                            return
                        }
                        throw MLXError.modelNotFound(model)
                    }

                    let loaded = try await getOrLoadModel(spec: spec)
                    let prompt = loaded.architecture == .gemma
                        ? buildGemmaChatPrompt(messages: messages)
                        : buildChatPrompt(messages: messages)
                    let startTime = CFAbsoluteTimeGetCurrent()
                    var tokenCount = 0

                    for try await token in generateStream(
                        loaded: loaded, prompt: prompt,
                        temperature: temperature, maxTokens: min(2048, numCtx / 4)
                    ) {
                        if tokenCount == 0 {
                            self.lastTimeToFirstToken = CFAbsoluteTimeGetCurrent() - startTime
                        }
                        tokenCount += 1
                        continuation.yield(token)
                    }

                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    self.lastTokensPerSecond = Double(tokenCount) / max(elapsed, 0.001)
                    continuation.finish()
                } catch {
                    if let fallback = self.fallback {
                        do {
                            for try await token in fallback.chatStream(
                                model: model, messages: messages,
                                temperature: temperature, numCtx: numCtx
                            ) { continuation.yield(token) }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    func embed(model: String, text: [String]) async throws -> [[Float]] {
        // Try MLX-native embedding via last hidden state mean pooling
        if let spec = Self.modelCatalog[model] {
            do {
                let loaded = try await getOrLoadModel(spec: spec)
                var embeddings: [[Float]] = []

                for t in text {
                    let tokens = loaded.tokenizer.encode(text: t)
                    guard !tokens.isEmpty else {
                        embeddings.append([])
                        continue
                    }

                    loaded.model.clearCache()
                    let input = MLXArray(tokens).reshaped(1, tokens.count)

                    // Get last hidden state (before lm_head projection)
                    // We use the model's forward but need the hidden state, not logits.
                    // As a practical approach: run forward, but the embedding is approximated
                    // by mean-pooling the logits projected back. For actual embeddings,
                    // we run the model without the final projection.
                    let logits = loaded.model.forward(input, cacheOffset: 0)
                    eval(logits)

                    // Mean pool across sequence dimension
                    let meanPooled = logits.mean(axis: 1)[0]  // [vocab_size] or [hidden]
                    eval(meanPooled)

                    // Normalize to unit vector
                    let norm = sqrt((meanPooled * meanPooled).sum())
                    let normalized = meanPooled / norm
                    eval(normalized)

                    embeddings.append(normalized.asArray(Float.self))
                }

                return embeddings
            } catch {
                Log.inference.warning("[mlx] embedding failed: \(error), falling back to Ollama")
            }
        }

        if let fallback {
            return try await fallback.embed(model: model, text: text)
        }
        throw MLXError.modelNotFound(model)
    }

    func listModels() async throws -> [ModelInfo] {
        var models: [ModelInfo] = []
        let localModels = try? FileManager.default.contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil)
        for dir in localModels ?? [] {
            let name = dir.lastPathComponent
            let size = try? FileManager.default.attributesOfItem(atPath: dir.path)[.size] as? Int64
            models.append(ModelInfo(name: "mlx:\(name)", size: size))
        }
        if let fallback, let ollamaModels = try? await fallback.listModels() {
            models.append(contentsOf: ollamaModels)
        }
        return models
    }

    func warmModel(_ model: String) async throws {
        guard let spec = Self.modelCatalog[model] else {
            try await fallback?.warmModel(model)
            return
        }
        Log.inference.info("[mlx] warming \(model) (\(spec.huggingFaceId))...")
        _ = try await getOrLoadModel(spec: spec)
        Log.inference.info("[mlx] \(model) warm")
    }

    // MARK: - Speculative Decoding

    func enableSpeculativeDecoding(draftModel: String) {
        self.draftModel = draftModel
        Log.inference.info("[mlx] speculative decoding enabled with draft=\(draftModel)")
    }

    func disableSpeculativeDecoding() {
        draftModel = nil
    }

    // MARK: - Generation

    /// Generate text using the MLX model.
    /// Uses speculative decoding when a draft model is loaded.
    private func generate(loaded: LoadedMLXModel, prompt: String, temperature: Double, maxTokens: Int) throws -> String {
        loaded.model.clearCache()

        let inputTokens = loaded.tokenizer.encode(text: prompt)
        guard !inputTokens.isEmpty else { return "" }

        let inputArray = MLXArray(inputTokens).reshaped(1, inputTokens.count)

        // Prefill: process all input tokens at once
        var logits = loaded.model.forward(inputArray, cacheOffset: 0)
        eval(logits)

        var generatedTokens: [Int] = []
        var nextToken = sampleToken(logits: logits[0, -1], temperature: Float(temperature))

        // Check if speculative decoding is available
        let draftLoaded: LoadedMLXModel?
        if let draftName = draftModel, let draftSpec = Self.modelCatalog[draftName] {
            draftLoaded = loadedModelsLock.withLock { $0[draftSpec.huggingFaceId] }
        } else {
            draftLoaded = nil
        }

        if let draft = draftLoaded {
            // Speculative decoding path
            let decoder = SpeculativeDecoder()
            draft.model.clearCache()

            // Warm draft model with same prompt
            let draftLogitsInit = draft.model.forward(inputArray, cacheOffset: 0)
            eval(draftLogitsInit)

            var draftToken = sampleToken(logits: draftLogitsInit[0, -1], temperature: Float(temperature))

            while generatedTokens.count < maxTokens {
                if nextToken == loaded.eosTokenId { break }
                generatedTokens.append(nextToken)

                // Draft: generate K candidate tokens
                let k = decoder.draftCount
                var draftTokens: [Int] = []
                var draftLogitsList: [[Float]] = []

                for _ in 0..<k {
                    if draftToken == loaded.eosTokenId { break }
                    draftTokens.append(draftToken)

                    let draftInput = MLXArray([Int32(draftToken)]).reshaped(1, 1)
                    let dl = draft.model.forward(draftInput, cacheOffset: draft.model.cacheLength - 1)
                    eval(dl)
                    draftLogitsList.append(dl[0, -1].asArray(Float.self))
                    draftToken = sampleToken(logits: dl[0, -1], temperature: Float(temperature))
                }

                guard !draftTokens.isEmpty else { break }

                // Target: verify all draft tokens in one forward pass
                let verifyInput = MLXArray(draftTokens.map { Int32($0) }).reshaped(1, draftTokens.count)
                let targetLogits = loaded.model.forward(verifyInput, cacheOffset: loaded.model.cacheLength - 1)
                eval(targetLogits)

                var targetLogitsList: [[Float]] = []
                for i in 0..<(draftTokens.count + 1) {
                    if i < targetLogits.dim(1) {
                        targetLogitsList.append(targetLogits[0, i].asArray(Float.self))
                    }
                }

                // Verify and accept/reject
                let accepted = decoder.verifyStep(
                    draftLogits: draftLogitsList,
                    draftTokens: draftTokens,
                    targetLogits: targetLogitsList,
                    temperature: Float(temperature)
                )

                for token in accepted {
                    if token == loaded.eosTokenId { break }
                    generatedTokens.append(token)
                }

                nextToken = generatedTokens.last ?? nextToken

                // Re-sync draft model if needed
                if accepted.count < draftTokens.count {
                    draft.model.clearCache()
                    let resyncTokens = MLXArray(generatedTokens.map { Int32($0) }).reshaped(1, generatedTokens.count)
                    let dl = draft.model.forward(resyncTokens, cacheOffset: 0)
                    eval(dl)
                    draftToken = sampleToken(logits: dl[0, -1], temperature: Float(temperature))
                }
            }

            Log.inference.info("[mlx] speculative: \(decoder.metrics.summary)")
        } else {
            // Standard autoregressive decoding
            for _ in 0..<maxTokens {
                if nextToken == loaded.eosTokenId { break }
                generatedTokens.append(nextToken)

                let tokenArray = MLXArray([Int32(nextToken)]).reshaped(1, 1)
                logits = loaded.model.forward(tokenArray, cacheOffset: loaded.model.cacheLength - 1)
                eval(logits)

                nextToken = sampleToken(logits: logits[0, -1], temperature: Float(temperature))
            }
        }

        return loaded.tokenizer.decode(tokens: generatedTokens)
    }

    /// Streaming generation — yields decoded text as tokens are produced.
    private func generateStream(loaded: LoadedMLXModel, prompt: String, temperature: Double, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    loaded.model.clearCache()

                    let inputTokens = loaded.tokenizer.encode(text: prompt)
                    guard !inputTokens.isEmpty else {
                        continuation.finish()
                        return
                    }

                    let inputArray = MLXArray(inputTokens).reshaped(1, inputTokens.count)

                    // Prefill
                    var logits = loaded.model.forward(inputArray, cacheOffset: 0)
                    eval(logits)

                    var nextToken = sampleToken(logits: logits[0, -1], temperature: Float(temperature))
                    var tokenBuffer: [Int] = []

                    for _ in 0..<maxTokens {
                        if nextToken == loaded.eosTokenId { break }
                        tokenBuffer.append(nextToken)

                        // Decode every few tokens to yield text
                        if tokenBuffer.count >= 3 {
                            let text = loaded.tokenizer.decode(tokens: tokenBuffer)
                            if !text.isEmpty {
                                continuation.yield(text)
                                tokenBuffer.removeAll()
                            }
                        }

                        let tokenArray = MLXArray([Int32(nextToken)]).reshaped(1, 1)
                        logits = loaded.model.forward(tokenArray, cacheOffset: loaded.model.cacheLength - 1)
                        eval(logits)

                        nextToken = sampleToken(logits: logits[0, -1], temperature: Float(temperature))
                    }

                    // Flush remaining tokens
                    if !tokenBuffer.isEmpty {
                        let text = loaded.tokenizer.decode(tokens: tokenBuffer)
                        if !text.isEmpty {
                            continuation.yield(text)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Output Validation

    /// Detect garbage output from broken weight loading.
    /// Garbage typically looks like repeated single characters: "!!!!!!!", "??????", "........"
    private func isGarbageOutput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return trimmed.isEmpty }

        // Check if dominated by a single repeated character
        var charCounts: [Character: Int] = [:]
        for ch in trimmed { charCounts[ch, default: 0] += 1 }
        if let (topChar, topCount) = charCounts.max(by: { $0.value < $1.value }) {
            let ratio = Double(topCount) / Double(trimmed.count)
            // If one character is >60% of the output and it's punctuation, it's garbage
            if ratio > 0.6 && !topChar.isLetter && !topChar.isNumber {
                return true
            }
        }

        // Check for very low unique character ratio (< 5 unique chars in 50+ chars)
        if trimmed.count > 50 {
            let unique = Set(trimmed).count
            if unique < 5 { return true }
        }

        return false
    }

    // MARK: - Sampling

    /// Sample a token from logits with temperature.
    private func sampleToken(logits: MLXArray, temperature: Float) -> Int {
        if temperature < 0.01 {
            // Greedy
            return argMax(logits).item(Int.self)
        }

        let scaled = logits / MLXArray(temperature)
        let probs = softMax(scaled)
        let token = MLXRandom.categorical(expandedDimensions(probs, axis: 0))
        return token.item(Int.self)
    }

    // MARK: - Model Management

    func hasLocalModel(_ model: String) -> Bool {
        guard let spec = Self.modelCatalog[model] else { return false }
        return loadedModelsLock.withLock { $0[spec.huggingFaceId] != nil }
    }

    // MARK: - Prompt Building

    private func buildPrompt(for architecture: LoadedMLXModel.ModelArchitecture, messages: [[String: Any]]) -> String {
        switch architecture {
        case .gemma: return buildGemmaChatPrompt(messages: messages)
        case .mistral: return buildMistralChatPrompt(messages: messages)
        case .qwen2: return buildChatPrompt(messages: messages)
        }
    }

    /// Mistral chat template using [INST] tags.
    private func buildMistralChatPrompt(messages: [[String: Any]]) -> String {
        var parts: [String] = []
        var systemContent = ""

        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            let content = msg["content"] as? String ?? ""

            switch role {
            case "system":
                systemContent = content
            case "user":
                let userMsg = systemContent.isEmpty ? content : "\(systemContent)\n\n\(content)"
                parts.append("[INST] \(userMsg) [/INST]")
                systemContent = ""
            case "assistant":
                parts.append(content)
            default:
                parts.append(content)
            }
        }

        return parts.joined(separator: "\n")
    }

    private func buildChatPrompt(messages: [[String: Any]]) -> String {
        // Detect if this is a Gemma model based on the loaded model
        // Default to ChatML (Qwen) format, Gemma uses <start_of_turn>/<end_of_turn>
        var parts: [String] = []
        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            let content = msg["content"] as? String ?? ""
            parts.append("<|im_start|>\(role)\n\(content)<|im_end|>")
        }
        parts.append("<|im_start|>assistant\n")
        return parts.joined(separator: "\n")
    }

    /// Gemma-specific chat template using <start_of_turn>/<end_of_turn>.
    private func buildGemmaChatPrompt(messages: [[String: Any]]) -> String {
        var parts: [String] = []
        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            let content = msg["content"] as? String ?? ""

            let gemmaRole: String
            switch role {
            case "system": gemmaRole = "user"  // Gemma folds system into user
            case "assistant": gemmaRole = "model"
            default: gemmaRole = role
            }

            parts.append("<start_of_turn>\(gemmaRole)\n\(content)<end_of_turn>")
        }
        parts.append("<start_of_turn>model\n")
        return parts.joined(separator: "\n")
    }

    // MARK: - Tool Call Parsing

    private func parseToolCalls(from output: String) -> [[String: Any]]? {
        let toolCallRegex = try? NSRegularExpression(
            pattern: "<tool_call>(.*?)</tool_call>",
            options: .dotMatchesLineSeparators
        )
        let range = NSRange(output.startIndex..., in: output)
        guard let regex = toolCallRegex else { return nil }
        let matches = regex.matches(in: output, range: range)
        guard !matches.isEmpty else { return nil }

        var toolCalls: [[String: Any]] = []
        for match in matches {
            guard let jsonRange = Range(match.range(at: 1), in: output) else { continue }
            let jsonStr = String(output[jsonRange])
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let name = json["name"] as? String ?? ""
            let arguments = json["arguments"] as? [String: Any] ?? [:]
            toolCalls.append(["function": ["name": name, "arguments": arguments] as [String: Any]])
        }
        return toolCalls.isEmpty ? nil : toolCalls
    }

    private func cleanToolCallContent(_ output: String) -> String {
        let regex = try? NSRegularExpression(pattern: "<tool_call>.*?</tool_call>", options: .dotMatchesLineSeparators)
        let range = NSRange(output.startIndex..., in: output)
        return regex?.stringByReplacingMatches(in: output, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? output
    }

    static func ollamaEquivalent(for spec: MLXModelSpec) -> String {
        for (name, s) in modelCatalog where s.huggingFaceId == spec.huggingFaceId {
            return name
        }
        return "qwen3.5:9b"
    }
}

// MARK: - Errors

enum MLXError: Error, LocalizedError {
    case modelNotFound(String)
    case notReady(String)
    case loadFailed(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let m): "No MLX model found for '\(m)'"
        case .notReady(let m): "MLX not ready: \(m)"
        case .loadFailed(let m): "Failed to load model: \(m)"
        case .generationFailed(let m): "Generation failed: \(m)"
        }
    }
}
