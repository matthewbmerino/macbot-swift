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
    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
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
        self.ropeTheta = isFullAttention ? config.ropeTheta : 10000.0
        self.partialRotaryFactor = isFullAttention ? config.partialRotaryFactor : 1.0

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
        // GeGLU: gelu(gate) * up, then down-project
        downProj(gelu(gateProj(x)) * upProj(x))
    }
}

// MARK: - MoE Layer

/// Single expert in the Mixture of Experts layer.
class GemmaExpert: Module {
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
        downProj(gelu(gateProj(x)) * upProj(x))
    }
}

/// Mixture of Experts routing layer.
/// Routes each token to its top-K experts via a learned gating network.
class GemmaMoELayer: Module {
    @ModuleInfo var gate: Linear
    @ModuleInfo var experts: [GemmaExpert]
    // gate and experts match HF keys directly
    let numExperts: Int
    let topK: Int

    init(config: GemmaConfig) {
        self.numExperts = config.numExperts
        self.topK = config.topKExperts

        self._gate.wrappedValue = Linear(config.hiddenSize, config.numExperts, bias: false)
        self._experts.wrappedValue = (0..<config.numExperts).map { _ in
            GemmaExpert(hiddenSize: config.hiddenSize, intermediateSize: config.moeIntermediateSize)
        }
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let batchSize = x.dim(0)
        let seqLen = x.dim(1)
        let hiddenSize = x.dim(2)

        let flat = x.reshaped(-1, hiddenSize)  // [B*S, H]
        let numTokens = flat.dim(0)

        // Compute routing logits and select top-K experts per token
        let routerLogits = gate(flat)  // [B*S, num_experts]
        let sorted = argSort(routerLogits, axis: -1)
        let topKIndices = sorted[0..., (numExperts - topK)...]
        let topKLogits = takeAlong(routerLogits, topKIndices, axis: -1)
        let topKWeights = softMax(topKLogits, axis: -1)  // [B*S, K]

        // Batched expert execution — group all tokens assigned to each expert,
        // run them through the expert in one matmul, then scatter back.
        // This is O(num_active_experts) forward passes instead of O(num_tokens * K).
        var output = MLXArray.zeros([numTokens, hiddenSize])

        // Build assignment matrix: for each expert, which (token, slot) pairs use it
        var expertAssignments: [Int: [(token: Int, slot: Int)]] = [:]
        eval(topKIndices)  // Materialize so we can read indices

        for t in 0..<numTokens {
            for k in 0..<topK {
                let expertIdx: Int = topKIndices[t, k].item(Int.self)
                guard expertIdx >= 0 && expertIdx < numExperts else { continue }
                expertAssignments[expertIdx, default: []].append((t, k))
            }
        }

        // Process each active expert with its full batch
        for (expertIdx, assignments) in expertAssignments {
            guard !assignments.isEmpty else { continue }

            // Gather all tokens for this expert
            let tokenIndices = MLXArray(assignments.map { Int32($0.token) })
            let expertInput = take(flat, tokenIndices, axis: 0)  // [N_expert, H]

            // Single batched forward pass through the expert
            let expertOutput = experts[expertIdx](expertInput)  // [N_expert, H]

            // Gather the routing weights for these tokens at their respective slots
            for (i, assignment) in assignments.enumerated() {
                let weight = topKWeights[assignment.token, assignment.slot]
                let weighted = expertOutput[i] * weight
                // Accumulate into output
                let current = output[assignment.token]
                output[assignment.token] = current + weighted
            }
        }

        return output.reshaped(batchSize, seqLen, hiddenSize)
    }
}

// MARK: - Gemma Decoder Layer

/// Single transformer decoder layer — contains attention + MoE/Dense FFN.
class GemmaDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: GemmaAttention
    @ModuleInfo var mlp: GemmaMLP
    @ModuleInfo(key: "block_sparse_moe") var moeLayer: GemmaMoELayer?
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: GemmaRMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: GemmaRMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardLayernorm: GemmaRMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardLayernorm: GemmaRMSNorm
    let isMoE: Bool

    init(config: GemmaConfig, layerIndex: Int, useMoE: Bool) {
        self.isMoE = useMoE
        self._selfAttn.wrappedValue = GemmaAttention(config: config, layerIndex: layerIndex)
        self._inputLayernorm.wrappedValue = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayernorm.wrappedValue = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._preFeedforwardLayernorm.wrappedValue = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postFeedforwardLayernorm.wrappedValue = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._mlp.wrappedValue = GemmaMLP(hiddenSize: config.hiddenSize, intermediateSize: config.intermediateSize)
        self._moeLayer.wrappedValue = useMoE ? GemmaMoELayer(config: config) : nil

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
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo var layers: [GemmaDecoderLayer]
    @ModuleInfo var norm: GemmaRMSNorm
    @ModuleInfo(key: "lm_head") var lmHead: Linear?
    let vocabSize: Int
    let hiddenSize: Int
    let tiedEmbeddings: Bool

    init(config: GemmaConfig) {
        self.vocabSize = config.vocabSize
        self.hiddenSize = config.hiddenSize
        self._embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)

        // Build layers — all use MoE for Gemma 4 A4B
        self._layers.wrappedValue = (0..<config.numHiddenLayers).map { i in
            GemmaDecoderLayer(config: config, layerIndex: i, useMoE: config.numExperts > 1)
        }

        self._norm.wrappedValue = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)

        self.tiedEmbeddings = true
        self._lmHead.wrappedValue = nil

        super.init()
    }

    func callAsFunction(_ tokenIds: MLXArray, cacheOffset: Int = 0) -> MLXArray {
        // Gemma scales embeddings by sqrt(hidden_size)
        var h = embedTokens(tokenIds) * MLXArray(sqrt(Float(hiddenSize)))

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
