import Foundation
import MLX
import MLXFast
import MLXNN
import Tokenizers

// MARK: - MLX Language Model Protocol

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

// MARK: - Loaded Model Container

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
