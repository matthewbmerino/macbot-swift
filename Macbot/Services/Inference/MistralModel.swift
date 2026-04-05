import Foundation
import MLX
import MLXFast
import MLXNN
import MLXRandom

// MARK: - Mistral/Devstral Model Architecture

/// Configuration for Mistral-family models (Mistral, Devstral, Codestral).
struct MistralConfig {
    let vocabSize: Int
    let hiddenSize: Int
    let intermediateSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let rmsNormEps: Float
    let ropeTheta: Float
    let slidingWindowSize: Int?

    var headDim: Int { hiddenSize / numAttentionHeads }

    static func from(json: [String: Any]) -> MistralConfig {
        MistralConfig(
            vocabSize: json["vocab_size"] as? Int ?? 32768,
            hiddenSize: json["hidden_size"] as? Int ?? 4096,
            intermediateSize: json["intermediate_size"] as? Int ?? 14336,
            numHiddenLayers: json["num_hidden_layers"] as? Int ?? 32,
            numAttentionHeads: json["num_attention_heads"] as? Int ?? 32,
            numKeyValueHeads: json["num_key_value_heads"] as? Int ?? 8,
            rmsNormEps: (json["rms_norm_eps"] as? Double).map { Float($0) } ?? 1e-5,
            ropeTheta: (json["rope_theta"] as? Double).map { Float($0) } ?? 1_000_000,
            slidingWindowSize: json["sliding_window"] as? Int
        )
    }
}

// MARK: - Mistral Attention

class MistralAttention: Module {
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

    init(config: MistralConfig) {
        self.numHeads = config.numAttentionHeads
        self.numKVHeads = config.numKeyValueHeads
        self.headDim = config.headDim
        self.scale = 1.0 / sqrt(Float(headDim))
        self.ropeTheta = config.ropeTheta

        self._qProj.wrappedValue = Linear(config.hiddenSize, numHeads * headDim, bias: false)
        self._kProj.wrappedValue = Linear(config.hiddenSize, numKVHeads * headDim, bias: false)
        self._vProj.wrappedValue = Linear(config.hiddenSize, numKVHeads * headDim, bias: false)
        self._oProj.wrappedValue = Linear(numHeads * headDim, config.hiddenSize, bias: false)

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

        if let existingK = keyCache, let existingV = valueCache {
            keyCache = concatenated([existingK, k], axis: 2)
            valueCache = concatenated([existingV, v], axis: 2)
        } else {
            keyCache = k
            valueCache = v
        }

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

// MARK: - Mistral MLP (SwiGLU — same as Qwen/LLaMA)

class MistralMLP: Module {
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

// MARK: - Mistral Decoder Layer

class MistralDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: MistralAttention
    @ModuleInfo var mlp: MistralMLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNorm

    init(config: MistralConfig) {
        self._selfAttn.wrappedValue = MistralAttention(config: config)
        self._mlp.wrappedValue = MistralMLP(hiddenSize: config.hiddenSize, intermediateSize: config.intermediateSize)
        self._inputLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
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

// MARK: - Full Mistral Model

class MistralModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo var layers: [MistralDecoderLayer]
    @ModuleInfo var norm: RMSNorm
    @ModuleInfo(key: "lm_head") var lmHead: Linear
    let vocabSize: Int

    init(config: MistralConfig) {
        self.vocabSize = config.vocabSize
        self._embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        self._layers.wrappedValue = (0..<config.numHiddenLayers).map { _ in
            MistralDecoderLayer(config: config)
        }
        self._norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._lmHead.wrappedValue = Linear(config.hiddenSize, config.vocabSize, bias: false)
        super.init()
    }

    func callAsFunction(_ tokenIds: MLXArray, cacheOffset: Int = 0) -> MLXArray {
        var h = embedTokens(tokenIds)

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
        for layer in layers { layer.clearCache() }
    }

    var cacheLength: Int {
        layers.first?.selfAttn.keyCache?.dim(2) ?? 0
    }
}

extension MistralModel: MLXLanguageModel {
    func forward(_ tokenIds: MLXArray, cacheOffset: Int) -> MLXArray {
        callAsFunction(tokenIds, cacheOffset: cacheOffset)
    }
}
