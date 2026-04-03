import Foundation

struct ModelCandidate {
    let name: String
    let params: Double  // Billions
    let mlxAvailable: Bool  // Whether an MLX-format version exists

    /// Estimated RAM for Q4_K_M quantization.
    var estimatedRAM: Double { params * 0.55 + 1.0 }

    /// Estimated RAM for a specific quantization level.
    func estimatedRAM(quantization: MLXModelSpec.MLXQuantization) -> Double {
        (params * quantization.bitsPerWeight / 8.0) + 0.5
    }

    init(name: String, params: Double, mlxAvailable: Bool = false) {
        self.name = name
        self.params = params
        self.mlxAvailable = mlxAvailable
    }
}

struct ModelRecommendation {
    var config: ModelConfig
    var totalEstimatedRAM: Double = 0
    var skippedRoles: [(AgentCategory, String)] = []
    var selectedModels: [(AgentCategory, String, Double)] = []  // (role, model, RAM)
    var recommendedBackend: String = "hybrid"
    var mlxCompatibleCount: Int = 0
}

enum ModelRecommender {
    // Model catalog — ordered by quality (best first) per role
    // mlxAvailable flag indicates if an MLX-community quantized version exists
    static let catalog: [AgentCategory: [ModelCandidate]] = [
        .general: [
            ModelCandidate(name: "qwen3.5:30b", params: 30, mlxAvailable: true),
            ModelCandidate(name: "qwen3.5:9b", params: 9, mlxAvailable: true),
            ModelCandidate(name: "qwen3.5:4b", params: 4, mlxAvailable: true),
        ],
        .coder: [
            ModelCandidate(name: "devstral-small-2", params: 24),
            ModelCandidate(name: "qwen2.5-coder:14b", params: 14, mlxAvailable: true),
            ModelCandidate(name: "qwen2.5-coder:7b", params: 7, mlxAvailable: true),
        ],
        .vision: [
            ModelCandidate(name: "qwen3-vl:8b", params: 8),
            ModelCandidate(name: "qwen3-vl:4b", params: 4),
        ],
        .reasoner: [
            ModelCandidate(name: "deepseek-r1:14b", params: 14, mlxAvailable: true),
            ModelCandidate(name: "deepseek-r1:8b", params: 8, mlxAvailable: true),
        ],
    ]

    static let routerModel = ModelCandidate(name: "qwen3.5:0.8b", params: 0.8, mlxAvailable: true)
    static let embeddingModel = ModelCandidate(name: "qwen3-embedding:0.6b", params: 0.6)

    /// Generate optimal model recommendations for a hardware profile.
    /// Now considers MLX availability and dynamic quantization options.
    static func recommend(for profile: HardwareProfile) -> ModelRecommendation {
        var budget = profile.availableForModels
        var config = ModelConfig()
        var rec = ModelRecommendation(config: config)

        // Router and embedding always fit
        config.router = routerModel.name
        config.embedding = embeddingModel.name
        let fixedCost = routerModel.estimatedRAM + embeddingModel.estimatedRAM
        budget -= fixedCost
        rec.totalEstimatedRAM += fixedCost

        // Determine optimal quantization based on available RAM
        let quantOptions = MLXClient.availableQuantizations(ramGB: profile.totalRAM)

        // Allocation order: general (most used) → coder → reasoner → vision
        let allocationOrder: [AgentCategory] = [.general, .coder, .reasoner, .vision]

        for role in allocationOrder {
            guard let candidates = catalog[role] else { continue }

            let maxForRole = budget * 0.7
            var picked = false

            for candidate in candidates {
                // Try default Q4 first
                if candidate.estimatedRAM <= maxForRole {
                    switch role {
                    case .general: config.general = candidate.name
                    case .coder: config.coder = candidate.name
                    case .vision: config.vision = candidate.name
                    case .reasoner: config.reasoner = candidate.name
                    case .rag: break
                    }
                    budget -= candidate.estimatedRAM
                    rec.totalEstimatedRAM += candidate.estimatedRAM
                    rec.selectedModels.append((role, candidate.name, candidate.estimatedRAM))
                    if candidate.mlxAvailable { rec.mlxCompatibleCount += 1 }
                    picked = true
                    break
                }

                // Try more aggressive quantization for MLX-available models
                if candidate.mlxAvailable && quantOptions.contains(.q2) {
                    let q2Ram = candidate.estimatedRAM(quantization: .q2)
                    if q2Ram <= maxForRole {
                        switch role {
                        case .general: config.general = candidate.name
                        case .coder: config.coder = candidate.name
                        case .vision: config.vision = candidate.name
                        case .reasoner: config.reasoner = candidate.name
                        case .rag: break
                        }
                        budget -= q2Ram
                        rec.totalEstimatedRAM += q2Ram
                        rec.selectedModels.append((role, "\(candidate.name) (q2)", q2Ram))
                        rec.mlxCompatibleCount += 1
                        picked = true
                        break
                    }
                }
            }

            if !picked {
                switch role {
                case .general: break
                case .coder: config.coder = ""
                case .vision: config.vision = ""
                case .reasoner: config.reasoner = ""
                case .rag: break
                }
                rec.skippedRoles.append((role, "Not enough memory (\(String(format: "%.1f", budget))GB remaining)"))

                if role == .general, let smallest = candidates.last {
                    config.general = smallest.name
                    budget -= smallest.estimatedRAM
                    rec.totalEstimatedRAM += smallest.estimatedRAM
                    rec.selectedModels.append((role, smallest.name, smallest.estimatedRAM))
                }
            }
        }

        // Recommend backend based on MLX compatibility
        if profile.isAppleSilicon && rec.mlxCompatibleCount > 0 {
            rec.recommendedBackend = "hybrid"
            config.backend = "hybrid"
            config.speculativeDecoding = profile.totalRAM >= 16
        } else {
            rec.recommendedBackend = "ollama"
            config.backend = "ollama"
            config.speculativeDecoding = false
        }

        // Enable embedding router on all platforms (only needs embedding model)
        config.useEmbeddingRouter = true

        rec.config = config
        return rec
    }

    /// Estimate RAM for a model by name (lookup in catalog).
    static func estimatedRAM(for modelName: String) -> Double? {
        for (_, candidates) in catalog {
            if let match = candidates.first(where: { $0.name == modelName }) {
                return match.estimatedRAM
            }
        }
        if modelName == routerModel.name { return routerModel.estimatedRAM }
        if modelName == embeddingModel.name { return embeddingModel.estimatedRAM }
        return nil
    }
}
