import Foundation
import MLX
import MLXFast
import MLXNN
import MLXRandom

// MARK: - Gemma 4 MoE Model Architecture

/// Configuration for Gemma 4 26B A4B (Mixture of Experts).
struct GemmaConfig {
    let vocabSize: Int
    let hiddenSize: Int
    let intermediateSize: Int       // Dense FFN intermediate
    let moeIntermediateSize: Int    // Per-expert FFN intermediate
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let numExperts: Int             // 128 total experts
    let topKExperts: Int            // 8 active per token
    let rmsNormEps: Float
    let ropeTheta: Float            // 1M for global, 10K for sliding
    let slidingWindowSize: Int      // 1024
    let partialRotaryFactor: Float  // 0.25 for proportional RoPE

    /// Indices of full-attention layers (rest use sliding window).
    let fullAttentionLayers: Set<Int>

    static func from(json: [String: Any]) -> GemmaConfig {
        // Parse text_config if present (multimodal model structure)
        let textConfig = json["text_config"] as? [String: Any] ?? json

        let numLayers = textConfig["num_hidden_layers"] as? Int ?? 30

        // Full attention layer indices (typically every 6th layer + last)
        var fullLayers = Set<Int>()
        if let layerTypes = textConfig["layer_types"] as? [String] {
            for (i, t) in layerTypes.enumerated() {
                if t == "full_attention" || t == "global" { fullLayers.insert(i) }
            }
        }
        if fullLayers.isEmpty {
            // Default: layers 5, 11, 17, 23, 29
            fullLayers = Set(stride(from: 5, to: numLayers, by: 6))
        }

        return GemmaConfig(
            vocabSize: textConfig["vocab_size"] as? Int ?? 262144,
            hiddenSize: textConfig["hidden_size"] as? Int ?? 2816,
            intermediateSize: textConfig["intermediate_size"] as? Int ?? 2112,
            moeIntermediateSize: textConfig["moe_intermediate_size"] as? Int ?? 704,
            numHiddenLayers: numLayers,
            numAttentionHeads: textConfig["num_attention_heads"] as? Int ?? 16,
            numKeyValueHeads: textConfig["num_key_value_heads"] as? Int ?? 8,
            numExperts: textConfig["num_experts"] as? Int ?? 128,
            topKExperts: textConfig["top_k_experts"] as? Int ?? 8,
            rmsNormEps: (textConfig["rms_norm_eps"] as? Double).map { Float($0) } ?? 1e-6,
            ropeTheta: (textConfig["rope_theta"] as? Double).map { Float($0) } ?? 1_000_000,
            slidingWindowSize: textConfig["sliding_window_size"] as? Int ?? 1024,
            partialRotaryFactor: (textConfig["partial_rotary_factor"] as? Double).map { Float($0) } ?? 0.25,
            fullAttentionLayers: fullLayers
        )
    }

    var headDim: Int { hiddenSize / numAttentionHeads }
}

// MARK: - Gemma RMSNorm (with +1 offset)

/// Gemma uses RMSNorm with a +1 offset on the weight (1 + w instead of w).
class GemmaRMSNorm: Module, UnaryLayer {
    let weight: MLXArray
    let eps: Float

    init(dimensions: Int, eps: Float = 1e-6) {
        self.weight = MLXArray.zeros([dimensions])  // Stored as offset, applied as (1 + weight)
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: 1 + weight, eps: eps)
    }
}

// MARK: - Gemma Attention

/// Hybrid attention: sliding window (most layers) or full global (6 layers).
class GemmaAttention: Module {
    let qProj: Linear
    let kProj: Linear
    let vProj: Linear
    let oProj: Linear
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let scale: Float
    let isFullAttention: Bool
    let slidingWindowSize: Int
    let ropeTheta: Float
    let partialRotaryFactor: Float

    var keyCache: MLXArray?
    var valueCache: MLXArray?

    init(config: GemmaConfig, layerIndex: Int) {
        self.numHeads = config.numAttentionHeads
        self.numKVHeads = config.numKeyValueHeads
        self.headDim = config.headDim
        self.scale = 1.0 / sqrt(Float(headDim))
        self.isFullAttention = config.fullAttentionLayers.contains(layerIndex)
        self.slidingWindowSize = config.slidingWindowSize

        // Dual RoPE: global layers use 1M theta, sliding layers use 10K
        self.ropeTheta = isFullAttention ? config.ropeTheta : 10000.0
        self.partialRotaryFactor = isFullAttention ? config.partialRotaryFactor : 1.0

        self.qProj = Linear(config.hiddenSize, numHeads * headDim, bias: false)
        self.kProj = Linear(config.hiddenSize, numKVHeads * headDim, bias: false)
        self.vProj = Linear(config.hiddenSize, numKVHeads * headDim, bias: false)
        self.oProj = Linear(numHeads * headDim, config.hiddenSize, bias: false)

        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil, cacheOffset: Int = 0) -> MLXArray {
        let batchSize = x.dim(0)
        let seqLen = x.dim(1)

        var q = qProj(x).reshaped(batchSize, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        var k = kProj(x).reshaped(batchSize, seqLen, numKVHeads, headDim).transposed(0, 2, 1, 3)
        let v = vProj(x).reshaped(batchSize, seqLen, numKVHeads, headDim).transposed(0, 2, 1, 3)

        // RoPE — proportional layers only rotate partial dimensions
        let ropeDims = isFullAttention ? Int(Float(headDim) * partialRotaryFactor) : headDim
        q = MLXFast.RoPE(q, dimensions: ropeDims, traditional: false,
                         base: ropeTheta, scale: 1.0, offset: cacheOffset)
        k = MLXFast.RoPE(k, dimensions: ropeDims, traditional: false,
                         base: ropeTheta, scale: 1.0, offset: cacheOffset)

        // Update KV cache
        if let existingK = keyCache, let existingV = valueCache {
            keyCache = concatenated([existingK, k], axis: 2)
            valueCache = concatenated([existingV, v], axis: 2)
        } else {
            keyCache = k
            valueCache = v
        }

        var currentK = keyCache!
        var currentV = valueCache!

        // Sliding window: only keep last N tokens in cache for sliding layers
        if !isFullAttention && currentK.dim(2) > slidingWindowSize {
            let start = currentK.dim(2) - slidingWindowSize
            currentK = currentK[0..., 0..., start..., 0...]
            currentV = currentV[0..., 0..., start..., 0...]
            keyCache = currentK
            valueCache = currentV
        }

        // GQA: repeat KV heads
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

// MARK: - Gemma MLP (GELU with tanh approximation)

/// Dense feed-forward used in non-MoE layers or as the base FFN.
class GemmaMLP: Module {
    let gateProj: Linear
    let upProj: Linear
    let downProj: Linear

    init(hiddenSize: Int, intermediateSize: Int) {
        self.gateProj = Linear(hiddenSize, intermediateSize, bias: false)
        self.upProj = Linear(hiddenSize, intermediateSize, bias: false)
        self.downProj = Linear(intermediateSize, hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // GeGLU: gelu(gate) * up, then down-project
        downProj(gelu(gateProj(x)) * upProj(x))
    }
}

// MARK: - MoE Layer

/// Single expert in the Mixture of Experts layer.
class GemmaExpert: Module {
    let gateProj: Linear
    let upProj: Linear
    let downProj: Linear

    init(hiddenSize: Int, intermediateSize: Int) {
        self.gateProj = Linear(hiddenSize, intermediateSize, bias: false)
        self.upProj = Linear(hiddenSize, intermediateSize, bias: false)
        self.downProj = Linear(intermediateSize, hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(gelu(gateProj(x)) * upProj(x))
    }
}

/// Mixture of Experts routing layer.
/// Routes each token to its top-K experts via a learned gating network.
class GemmaMoELayer: Module {
    let gate: Linear          // [hidden_size, num_experts] — routing logits
    let experts: [GemmaExpert]
    let numExperts: Int
    let topK: Int

    init(config: GemmaConfig) {
        self.numExperts = config.numExperts
        self.topK = config.topKExperts

        self.gate = Linear(config.hiddenSize, config.numExperts, bias: false)
        self.experts = (0..<config.numExperts).map { _ in
            GemmaExpert(hiddenSize: config.hiddenSize, intermediateSize: config.moeIntermediateSize)
        }
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let batchSize = x.dim(0)
        let seqLen = x.dim(1)
        let hiddenSize = x.dim(2)

        // Flatten batch and sequence dimensions
        let flat = x.reshaped(-1, hiddenSize)  // [B*S, H]
        let numTokens = flat.dim(0)

        // Compute routing logits and select top-K experts per token
        let routerLogits = gate(flat)  // [B*S, num_experts]
        let sorted = argSort(routerLogits, axis: -1)
        let topKIndices = sorted[0..., (numExperts - topK)...]  // top-K indices
        let topKLogits = takeAlong(routerLogits, topKIndices, axis: -1)
        let topKWeights = softMax(topKLogits, axis: -1)  // [B*S, K]

        // Simple MoE: for each token, sum weighted expert outputs
        // This processes one token at a time for correctness
        var outputArrays: [MLXArray] = []

        for t in 0..<numTokens {
            let tokenInput = flat[t].reshaped(1, hiddenSize)
            var tokenOutput = MLXArray.zeros([1, hiddenSize])

            for k in 0..<topK {
                let expertIdx: Int = topKIndices[t, k].item(Int.self)
                let weight = topKWeights[t, k]

                guard expertIdx >= 0 && expertIdx < numExperts else { continue }
                let expertOutput = experts[expertIdx](tokenInput)
                tokenOutput = tokenOutput + expertOutput * weight
            }

            outputArrays.append(tokenOutput)
        }

        let output = concatenated(outputArrays, axis: 0)
        return output.reshaped(batchSize, seqLen, hiddenSize)
    }
}

// MARK: - Gemma Decoder Layer

/// Single transformer decoder layer — contains attention + MoE/Dense FFN.
class GemmaDecoderLayer: Module {
    let selfAttn: GemmaAttention
    let mlp: GemmaMLP              // Dense FFN (MoE layers use moeLayer instead)
    let moeLayer: GemmaMoELayer?   // Present only on MoE layers
    let inputLayernorm: GemmaRMSNorm
    let postAttentionLayernorm: GemmaRMSNorm
    let preFeedforwardLayernorm: GemmaRMSNorm
    let postFeedforwardLayernorm: GemmaRMSNorm
    let isMoE: Bool

    init(config: GemmaConfig, layerIndex: Int, useMoE: Bool) {
        self.selfAttn = GemmaAttention(config: config, layerIndex: layerIndex)
        self.isMoE = useMoE
        self.inputLayernorm = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self.postAttentionLayernorm = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self.preFeedforwardLayernorm = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self.postFeedforwardLayernorm = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)

        self.mlp = GemmaMLP(hiddenSize: config.hiddenSize, intermediateSize: config.intermediateSize)
        self.moeLayer = useMoE ? GemmaMoELayer(config: config) : nil

        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil, cacheOffset: Int = 0) -> MLXArray {
        // Pre-norm + attention + post-norm + residual
        let residual = x
        var h = inputLayernorm(x)
        h = selfAttn(h, mask: mask, cacheOffset: cacheOffset)
        h = postAttentionLayernorm(h)
        h = residual + h

        // Pre-norm + FFN/MoE + post-norm + residual
        let residual2 = h
        h = preFeedforwardLayernorm(h)
        if let moeLayer {
            h = moeLayer(h)
        } else {
            h = mlp(h)
        }
        h = postFeedforwardLayernorm(h)
        return residual2 + h
    }

    func clearCache() {
        selfAttn.clearCache()
    }
}

// MARK: - Full Gemma Model

/// Complete Gemma 4 decoder model with MoE support.
class GemmaModel: Module {
    let embedTokens: Embedding
    let layers: [GemmaDecoderLayer]
    let norm: GemmaRMSNorm
    let lmHead: Linear?  // Gemma ties embeddings to output if no separate lm_head
    let vocabSize: Int
    let hiddenSize: Int
    let tiedEmbeddings: Bool

    init(config: GemmaConfig) {
        self.vocabSize = config.vocabSize
        self.hiddenSize = config.hiddenSize
        self.embedTokens = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)

        // Build layers — all use MoE for Gemma 4 A4B
        self.layers = (0..<config.numHiddenLayers).map { i in
            GemmaDecoderLayer(config: config, layerIndex: i, useMoE: config.numExperts > 1)
        }

        self.norm = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)

        // Gemma typically ties embedding weights with output projection
        // Check if lm_head weights exist separately after loading
        self.tiedEmbeddings = true
        self.lmHead = nil

        super.init()
    }

    func callAsFunction(_ tokenIds: MLXArray, cacheOffset: Int = 0) -> MLXArray {
        // Gemma scales embeddings by sqrt(hidden_size)
        var h = embedTokens(tokenIds) * MLXArray(sqrt(Float(hiddenSize)))

        let seqLen = tokenIds.dim(1)
        let mask: MLXArray?
        if seqLen > 1 {
            mask = MultiHeadAttention.createAdditiveCausalMask(seqLen)
        } else {
            mask = nil
        }

        for layer in layers {
            h = layer(h, mask: mask, cacheOffset: cacheOffset)
        }

        h = norm(h)

        // Tied embeddings: use embedding weight as output projection
        if let lmHead {
            return lmHead(h)
        } else {
            // matmul with embedding weight transposed
            return matmul(h, embedTokens.weight.transposed())
        }
    }

    func clearCache() {
        for layer in layers { layer.clearCache() }
    }

    var cacheLength: Int {
        layers.first?.selfAttn.keyCache?.dim(2) ?? 0
    }
}
