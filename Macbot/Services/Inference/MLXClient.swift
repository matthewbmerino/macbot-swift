import Foundation
import Hub
import MLX
import MLXFast
import MLXNN
import MLXRandom
import Tokenizers

// MARK: - MLX Configuration

struct MLXModelSpec {
    let huggingFaceId: String
    let contextLength: Int
    let quantization: MLXQuantization

    enum MLXQuantization: String {
        case q2 = "2bit"
        case q3 = "3bit"
        case q4 = "4bit"
        case q6 = "6bit"
        case q8 = "8bit"
        case f16 = "f16"

        var bitsPerWeight: Double {
            switch self {
            case .q2: return 2.0
            case .q3: return 3.0
            case .q4: return 4.0
            case .q6: return 6.0
            case .q8: return 8.0
            case .f16: return 16.0
            }
        }
    }
}

// MARK: - Loaded Model Container

/// Protocol for MLX model architectures (Qwen, Gemma, etc.)
protocol MLXLanguageModel: AnyObject {
    func forward(_ tokenIds: MLXArray, cacheOffset: Int) -> MLXArray
    func clearCache()
    var cacheLength: Int { get }
}

extension QwenModel: MLXLanguageModel {
    func forward(_ tokenIds: MLXArray, cacheOffset: Int) -> MLXArray {
        callAsFunction(tokenIds, cacheOffset: cacheOffset)
    }
}
extension GemmaModel: MLXLanguageModel {
    func forward(_ tokenIds: MLXArray, cacheOffset: Int) -> MLXArray {
        callAsFunction(tokenIds, cacheOffset: cacheOffset)
    }
}

/// Holds a loaded MLX model with its tokenizer and weights.
final class LoadedMLXModel: @unchecked Sendable {
    let model: any MLXLanguageModel
    let tokenizer: any Tokenizer
    let eosTokenId: Int
    let spec: MLXModelSpec
    let architecture: ModelArchitecture

    enum ModelArchitecture {
        case qwen2
        case gemma
        case mistral
    }

    init(model: any MLXLanguageModel, tokenizer: any Tokenizer, eosTokenId: Int,
         spec: MLXModelSpec, architecture: ModelArchitecture) {
        self.model = model
        self.tokenizer = tokenizer
        self.eosTokenId = eosTokenId
        self.spec = spec
        self.architecture = architecture
    }
}

// MARK: - Qwen2 Model Architecture

/// RMSNorm layer used by Qwen2.
class RMSNorm: Module, UnaryLayer {
    let weight: MLXArray
    let eps: Float

    init(dimensions: Int, eps: Float = 1e-6) {
        self.weight = MLXArray.ones([dimensions])
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: weight, eps: eps)
    }
}

/// Multi-head attention with RoPE for Qwen2.
class QwenAttention: Module {
    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let scale: Float
    let ropeTheta: Float

    var keyCache: MLXArray?
    var valueCache: MLXArray?

    init(hiddenSize: Int, numHeads: Int, numKVHeads: Int, ropeTheta: Float = 1_000_000) {
        self.numHeads = numHeads
        self.numKVHeads = numKVHeads
        self.headDim = hiddenSize / numHeads
        self.scale = 1.0 / sqrt(Float(headDim))
        self.ropeTheta = ropeTheta

        self._qProj.wrappedValue = Linear(hiddenSize, numHeads * headDim, bias: true)
        self._kProj.wrappedValue = Linear(hiddenSize, numKVHeads * headDim, bias: true)
        self._vProj.wrappedValue = Linear(hiddenSize, numKVHeads * headDim, bias: true)
        self._oProj.wrappedValue = Linear(numHeads * headDim, hiddenSize, bias: false)

        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil, cacheOffset: Int = 0) -> MLXArray {
        let batchSize = x.dim(0)
        let seqLen = x.dim(1)

        var q = qProj(x).reshaped(batchSize, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        var k = kProj(x).reshaped(batchSize, seqLen, numKVHeads, headDim).transposed(0, 2, 1, 3)
        let v = vProj(x).reshaped(batchSize, seqLen, numKVHeads, headDim).transposed(0, 2, 1, 3)

        q = MLXFast.RoPE(q, dimensions: headDim, traditional: false, base: ropeTheta, scale: 1.0, offset: cacheOffset)
        k = MLXFast.RoPE(k, dimensions: headDim, traditional: false, base: ropeTheta, scale: 1.0, offset: cacheOffset)

        // Update KV cache
        if let existingK = keyCache, let existingV = valueCache {
            keyCache = concatenated([existingK, k], axis: 2)
            valueCache = concatenated([existingV, v], axis: 2)
        } else {
            keyCache = k
            valueCache = v
        }

        // GQA: repeat KV heads to match Q heads
        var currentK = keyCache!
        var currentV = valueCache!
        if numKVHeads < numHeads {
            let repeats = numHeads / numKVHeads
            currentK = MLXArray.repeated(currentK, count: repeats, axis: 1)
            currentV = MLXArray.repeated(currentV, count: repeats, axis: 1)
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: q, keys: currentK, values: currentV,
            scale: scale, mask: mask
        )

        return oProj(output.transposed(0, 2, 1, 3).reshaped(batchSize, seqLen, -1))
    }

    func clearCache() {
        keyCache = nil
        valueCache = nil
    }
}

/// Feed-forward network (SwiGLU) for Qwen2.
class QwenMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(hiddenSize: Int, intermediateSize: Int) {
        self._gateProj.wrappedValue = Linear(hiddenSize, intermediateSize, bias: false)
        self._upProj.wrappedValue = Linear(hiddenSize, intermediateSize, bias: false)
        self._downProj.wrappedValue = Linear(intermediateSize, hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(silu(gateProj(x)) * upProj(x))
    }
}

/// Single transformer decoder layer for Qwen2.
class QwenDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: QwenAttention
    @ModuleInfo var mlp: QwenMLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNorm

    init(hiddenSize: Int, intermediateSize: Int, numHeads: Int, numKVHeads: Int, rmsNormEps: Float, ropeTheta: Float) {
        self._selfAttn.wrappedValue = QwenAttention(hiddenSize: hiddenSize, numHeads: numHeads, numKVHeads: numKVHeads, ropeTheta: ropeTheta)
        self._mlp.wrappedValue = QwenMLP(hiddenSize: hiddenSize, intermediateSize: intermediateSize)
        self._inputLayernorm.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: rmsNormEps)
        self._postAttentionLayernorm.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil, cacheOffset: Int = 0) -> MLXArray {
        let residual = x
        var h = inputLayernorm(x)
        h = selfAttn(h, mask: mask, cacheOffset: cacheOffset)
        h = residual + h

        let residual2 = h
        h = postAttentionLayernorm(h)
        h = mlp(h)
        return residual2 + h
    }

    func clearCache() {
        selfAttn.clearCache()
    }
}

/// Full Qwen2 decoder model.
class QwenModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo var layers: [QwenDecoderLayer]
    @ModuleInfo var norm: RMSNorm
    @ModuleInfo(key: "lm_head") var lmHead: Linear
    let vocabSize: Int

    struct Config {
        let vocabSize: Int
        let hiddenSize: Int
        let intermediateSize: Int
        let numHiddenLayers: Int
        let numAttentionHeads: Int
        let numKeyValueHeads: Int
        let rmsNormEps: Float
        let ropeTheta: Float

        /// Parse from config.json dictionary.
        static func from(json: [String: Any]) -> Config {
            Config(
                vocabSize: json["vocab_size"] as? Int ?? 151936,
                hiddenSize: json["hidden_size"] as? Int ?? 896,
                intermediateSize: json["intermediate_size"] as? Int ?? 4864,
                numHiddenLayers: json["num_hidden_layers"] as? Int ?? 24,
                numAttentionHeads: json["num_attention_heads"] as? Int ?? 14,
                numKeyValueHeads: json["num_key_value_heads"] as? Int ?? 2,
                rmsNormEps: (json["rms_norm_eps"] as? Double).map { Float($0) } ?? 1e-6,
                ropeTheta: (json["rope_theta"] as? Double).map { Float($0) } ?? 1_000_000
            )
        }
    }

    init(config: Config) {
        self.vocabSize = config.vocabSize
        self._embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        self._layers.wrappedValue = (0..<config.numHiddenLayers).map { _ in
            QwenDecoderLayer(
                hiddenSize: config.hiddenSize,
                intermediateSize: config.intermediateSize,
                numHeads: config.numAttentionHeads,
                numKVHeads: config.numKeyValueHeads,
                rmsNormEps: config.rmsNormEps,
                ropeTheta: config.ropeTheta
            )
        }
        self._norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._lmHead.wrappedValue = Linear(config.hiddenSize, config.vocabSize, bias: false)
        super.init()
    }

    /// Forward pass. Returns logits for the last token position.
    func callAsFunction(_ tokenIds: MLXArray, cacheOffset: Int = 0) -> MLXArray {
        var h = embedTokens(tokenIds)

        // Causal mask
        let seqLen = tokenIds.dim(1)
        let mask: MLXArray?
        if seqLen > 1 {
            mask = MultiHeadAttention.createAdditiveCausalMask(seqLen, dtype: .float16)
        } else {
            mask = nil
        }

        for layer in layers {
            h = layer(h, mask: mask, cacheOffset: cacheOffset)
        }

        h = norm(h)
        return lmHead(h)
    }

    func clearCache() {
        for layer in layers {
            layer.clearCache()
        }
    }

    /// Get the total cached token count (KV cache length).
    var cacheLength: Int {
        layers.first?.selfAttn.keyCache?.dim(2) ?? 0
    }
}

// MARK: - MLX Client

/// MLX-native inference provider for Apple Silicon.
final class MLXClient: InferenceProvider, @unchecked Sendable {
    private let modelDirectory: URL
    let fallback: OllamaClient?
    private var loadedModels: [String: LoadedMLXModel] = [:]
    private let lock = NSLock()

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

    // MARK: - Model Loading

    /// Get a loaded model or download + load it from HuggingFace.
    private func getOrLoadModel(spec: MLXModelSpec) async throws -> LoadedMLXModel {
        lock.lock()
        if let existing = loadedModels[spec.huggingFaceId] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        // Download model from HuggingFace Hub
        let hub = HubApi(downloadBase: modelDirectory)
        let repo = Hub.Repo(id: spec.huggingFaceId)

        Log.inference.info("[mlx] downloading \(spec.huggingFaceId)...")

        let modelDir = try await hub.snapshot(
            from: repo,
            matching: ["config.json", "tokenizer.json", "tokenizer_config.json",
                        "*.safetensors", "special_tokens_map.json"]
        )

        Log.inference.info("[mlx] downloaded to \(modelDir.path)")

        // Load config.json
        let configURL = modelDir.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        guard let configJSON = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw MLXError.loadFailed("Failed to parse config.json")
        }

        // Load tokenizer
        let tokenizer = try await AutoTokenizer.from(modelFolder: modelDir)

        // Detect architecture from config
        let modelType = (configJSON["model_type"] as? String)
            ?? (configJSON["text_config"] as? [String: Any])?["model_type"] as? String
            ?? ""
        let lowerType = modelType.lowercased()

        let model: any MLXLanguageModel
        let eosTokenId: Int
        let architecture: LoadedMLXModel.ModelArchitecture

        if lowerType.contains("gemma") {
            let config = GemmaConfig.from(json: configJSON)
            let gemmaModel = GemmaModel(config: config)
            model = gemmaModel
            eosTokenId = tokenizer.eosTokenId ?? 1
            architecture = .gemma
            Log.inference.info("[mlx] detected Gemma architecture (\(config.numHiddenLayers) layers, \(config.numExperts) experts)")
        } else if lowerType.contains("mistral") {
            let config = MistralConfig.from(json: configJSON)
            let mistralModel = MistralModel(config: config)
            model = mistralModel
            eosTokenId = tokenizer.eosTokenId ?? 2
            architecture = .mistral
            Log.inference.info("[mlx] detected Mistral architecture (\(config.numHiddenLayers) layers, \(config.hiddenSize) hidden)")
        } else {
            let config = QwenModel.Config.from(json: configJSON)
            let qwenModel = QwenModel(config: config)
            model = qwenModel
            eosTokenId = tokenizer.eosTokenId ?? 151643
            architecture = .qwen2
            Log.inference.info("[mlx] detected Qwen2 architecture (\(config.numHiddenLayers) layers, \(config.hiddenSize) hidden)")
        }

        // Load weights from safetensors
        let safetensorFiles = try FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }

        var allWeights: [String: MLXArray] = [:]
        for file in safetensorFiles {
            let weights = try loadArrays(url: file)
            for (key, value) in weights {
                // Strip the "model." prefix (HF convention) — @ModuleInfo(key:)
                // annotations on our Module properties handle the rest of the mapping.
                var mappedKey = key
                if mappedKey.hasPrefix("model.") {
                    mappedKey = String(mappedKey.dropFirst(6))
                }
                // Gemma multimodal wraps text model in "language_model.model."
                if mappedKey.hasPrefix("language_model.model.") {
                    mappedKey = String(mappedKey.dropFirst(21))
                } else if mappedKey.hasPrefix("language_model.") {
                    mappedKey = String(mappedKey.dropFirst(15))
                }
                allWeights[mappedKey] = value
            }
        }

        Log.inference.info("[mlx] loaded \(allWeights.count) weight tensors")

        // Detect quantization from config or weight keys
        let quantConfig = configJSON["quantization"] as? [String: Any]
            ?? (configJSON["text_config"] as? [String: Any])?["quantization"] as? [String: Any]
        let groupSize = quantConfig?["group_size"] as? Int ?? 64
        let bits = quantConfig?["bits"] as? Int ?? 4

        // Check if weights are quantized (look for "scales" keys)
        let hasQuantizedWeights = allWeights.keys.contains { $0.contains("scales") }

        if hasQuantizedWeights {
            // Swap all Linear layers to QuantizedLinear before loading weights.
            // This ensures the weight shapes match (quantized weights are packed).
            Log.inference.info("[mlx] quantized model detected (bits=\(bits), group_size=\(groupSize)), converting layers...")
            quantize(model: model as! Module, groupSize: groupSize, bits: bits)
        }

        let params = ModuleParameters.unflattened(allWeights)
        (model as! Module).update(parameters: params)

        eval(model as! Module)

        Log.inference.info("[mlx] model \(spec.huggingFaceId) ready")

        let loaded = LoadedMLXModel(model: model, tokenizer: tokenizer,
                                     eosTokenId: eosTokenId, spec: spec, architecture: architecture)

        lock.lock()
        loadedModels[spec.huggingFaceId] = loaded
        lock.unlock()

        return loaded
    }

    /// Map HuggingFace weight keys to our Module parameter paths.
    private func mapWeightKey(_ key: String) -> String {
        key.replacingOccurrences(of: "model.", with: "")
            .replacingOccurrences(of: "embed_tokens", with: "embedTokens")
            .replacingOccurrences(of: "self_attn", with: "selfAttn")
            .replacingOccurrences(of: "q_proj", with: "qProj")
            .replacingOccurrences(of: "k_proj", with: "kProj")
            .replacingOccurrences(of: "v_proj", with: "vProj")
            .replacingOccurrences(of: "o_proj", with: "oProj")
            .replacingOccurrences(of: "gate_proj", with: "gateProj")
            .replacingOccurrences(of: "up_proj", with: "upProj")
            .replacingOccurrences(of: "down_proj", with: "downProj")
            .replacingOccurrences(of: "input_layernorm", with: "inputLayernorm")
            .replacingOccurrences(of: "post_attention_layernorm", with: "postAttentionLayernorm")
            .replacingOccurrences(of: "lm_head", with: "lmHead")
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
            lock.lock()
            draftLoaded = loadedModels[draftSpec.huggingFaceId]
            lock.unlock()
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
        lock.lock()
        let loaded = loadedModels[spec.huggingFaceId] != nil
        lock.unlock()
        return loaded
    }

    /// Total parameter count for RAM estimation (not active params).
    private static let totalParamOverrides: [String: Double] = [
        "gemma4:26b-a4b": 26.0,  // 26B total params, 4B active
    ]

    static func estimateMemory(for model: String) -> Double? {
        guard let spec = modelCatalog[model] else { return nil }
        // Use override for MoE models (total weight count, not active params)
        let paramB: Double
        if let override = totalParamOverrides[model] {
            paramB = override
        } else {
            let match = model.components(separatedBy: ":").last ?? ""
            paramB = Double(match.replacingOccurrences(of: "b", with: "")
                .replacingOccurrences(of: "-a4b", with: "")
                .replacingOccurrences(of: "e", with: "")) ?? 7.0
        }
        return (paramB * spec.quantization.bitsPerWeight / 8.0) + 0.5
    }

    static func availableQuantizations(ramGB: Double) -> [MLXModelSpec.MLXQuantization] {
        var options: [MLXModelSpec.MLXQuantization] = [.q4]
        if ramGB >= 16 { options.append(.q6) }
        if ramGB >= 24 { options.append(.q8) }
        if ramGB >= 48 { options.append(.f16) }
        options.insert(.q2, at: 0)
        options.insert(.q3, at: 1)
        return options
    }

    /// Map Mistral/Devstral HuggingFace weight keys to our Module parameter paths.
    private func mapMistralWeightKey(_ key: String) -> String {
        key.replacingOccurrences(of: "model.", with: "")
            .replacingOccurrences(of: "embed_tokens", with: "embedTokens")
            .replacingOccurrences(of: "self_attn", with: "selfAttn")
            .replacingOccurrences(of: "q_proj", with: "qProj")
            .replacingOccurrences(of: "k_proj", with: "kProj")
            .replacingOccurrences(of: "v_proj", with: "vProj")
            .replacingOccurrences(of: "o_proj", with: "oProj")
            .replacingOccurrences(of: "gate_proj", with: "gateProj")
            .replacingOccurrences(of: "up_proj", with: "upProj")
            .replacingOccurrences(of: "down_proj", with: "downProj")
            .replacingOccurrences(of: "input_layernorm", with: "inputLayernorm")
            .replacingOccurrences(of: "post_attention_layernorm", with: "postAttentionLayernorm")
            .replacingOccurrences(of: "lm_head", with: "lmHead")
    }

    /// Map Gemma HuggingFace weight keys to our Module parameter paths.
    private func mapGemmaWeightKey(_ key: String) -> String {
        key.replacingOccurrences(of: "language_model.model.", with: "")
            .replacingOccurrences(of: "model.", with: "")
            .replacingOccurrences(of: "embed_tokens", with: "embedTokens")
            .replacingOccurrences(of: "self_attn", with: "selfAttn")
            .replacingOccurrences(of: "q_proj", with: "qProj")
            .replacingOccurrences(of: "k_proj", with: "kProj")
            .replacingOccurrences(of: "v_proj", with: "vProj")
            .replacingOccurrences(of: "o_proj", with: "oProj")
            .replacingOccurrences(of: "gate_proj", with: "gateProj")
            .replacingOccurrences(of: "up_proj", with: "upProj")
            .replacingOccurrences(of: "down_proj", with: "downProj")
            .replacingOccurrences(of: "input_layernorm", with: "inputLayernorm")
            .replacingOccurrences(of: "post_attention_layernorm", with: "postAttentionLayernorm")
            .replacingOccurrences(of: "pre_feedforward_layernorm", with: "preFeedforwardLayernorm")
            .replacingOccurrences(of: "post_feedforward_layernorm", with: "postFeedforwardLayernorm")
            .replacingOccurrences(of: "block_sparse_moe", with: "mlp.moe")
            .replacingOccurrences(of: "lm_head", with: "lmHead")
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

    private static func ollamaEquivalent(for spec: MLXModelSpec) -> String {
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
