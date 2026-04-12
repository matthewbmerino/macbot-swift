import Foundation
import Hub
import MLX
import MLXNN
import os
import Tokenizers

// MARK: - Model Loading

extension MLXClient {

    /// Get a loaded model or download + load it from HuggingFace.
    func getOrLoadModel(spec: MLXModelSpec) async throws -> LoadedMLXModel {
        if let existing = loadedModelsLock.withLock({ $0[spec.huggingFaceId] }) {
            return existing
        }

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

        loadedModelsLock.withLock { $0[spec.huggingFaceId] = loaded }

        return loaded
    }

    /// Map HuggingFace weight keys to our Module parameter paths.
    func mapWeightKey(_ key: String) -> String {
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

    /// Map Mistral/Devstral HuggingFace weight keys to our Module parameter paths.
    func mapMistralWeightKey(_ key: String) -> String {
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
    func mapGemmaWeightKey(_ key: String) -> String {
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
}
