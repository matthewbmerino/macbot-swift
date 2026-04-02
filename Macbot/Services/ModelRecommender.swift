import Foundation

struct ModelCandidate {
    let name: String
    let params: Double  // Billions
    var estimatedRAM: Double { params * 0.55 + 1.0 }  // Q4_K_M estimate in GB
}

struct ModelRecommendation {
    var config: ModelConfig
    var totalEstimatedRAM: Double = 0
    var skippedRoles: [(AgentCategory, String)] = []  // (role, reason)
    var selectedModels: [(AgentCategory, String, Double)] = []  // (role, model, RAM)
}

enum ModelRecommender {
    // Model catalog — ordered by quality (best first) per role
    static let catalog: [AgentCategory: [ModelCandidate]] = [
        .general: [
            ModelCandidate(name: "qwen3.5:30b", params: 30),
            ModelCandidate(name: "qwen3.5:9b", params: 9),
            ModelCandidate(name: "qwen3.5:4b", params: 4),
        ],
        .coder: [
            ModelCandidate(name: "devstral-small-2", params: 24),
            ModelCandidate(name: "qwen2.5-coder:14b", params: 14),
            ModelCandidate(name: "qwen2.5-coder:7b", params: 7),
        ],
        .vision: [
            ModelCandidate(name: "qwen3-vl:8b", params: 8),
            ModelCandidate(name: "qwen3-vl:4b", params: 4),
        ],
        .reasoner: [
            ModelCandidate(name: "deepseek-r1:14b", params: 14),
            ModelCandidate(name: "deepseek-r1:8b", params: 8),
        ],
    ]

    // Always included — tiny models that fit on any hardware
    static let routerModel = ModelCandidate(name: "qwen3.5:0.8b", params: 0.8)
    static let embeddingModel = ModelCandidate(name: "qwen3-embedding:0.6b", params: 0.6)

    /// Generate optimal model recommendations for a hardware profile.
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

        // Allocation order: general (most used) → coder → reasoner → vision
        let allocationOrder: [AgentCategory] = [.general, .coder, .reasoner, .vision]

        for role in allocationOrder {
            guard let candidates = catalog[role] else { continue }

            // Pick the largest model that fits within 70% of remaining budget
            // (leave room for concurrent loading)
            let maxForRole = budget * 0.7
            var picked = false

            for candidate in candidates {
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
                    picked = true
                    break
                }
            }

            if !picked {
                // Clear the role — not enough memory
                switch role {
                case .general: break // General is required, keep the smallest
                case .coder: config.coder = ""
                case .vision: config.vision = ""
                case .reasoner: config.reasoner = ""
                case .rag: break
                }
                rec.skippedRoles.append((role, "Not enough memory (\(String(format: "%.1f", budget))GB remaining)"))

                // If general didn't fit with any candidate, force the smallest
                if role == .general {
                    if let smallest = candidates.last {
                        config.general = smallest.name
                        budget -= smallest.estimatedRAM
                        rec.totalEstimatedRAM += smallest.estimatedRAM
                        rec.selectedModels.append((role, smallest.name, smallest.estimatedRAM))
                    }
                }
            }
        }

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
