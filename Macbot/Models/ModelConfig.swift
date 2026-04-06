import Foundation

// Defaults are tuned for an M3 Pro 18GB:
//   - macOS + apps baseline ≈ 5–6GB → realistic Ollama ceiling ≈ 9–11GB
//   - One shared 9B (qwen3.5) covers general/coder/reasoner/rag — specialization
//     comes from system prompts, not different weights. Saves ~9GB vs 14B+24B mix.
//   - Vision keeps its own model (only multimodal one).
//   - Router and embedding stay tiny so they're always-warm.
//   - Combined with keep_alive=5m and ~16k contexts, resting footprint is ~1.6GB
//     and active footprint ~8GB, leaving real headroom for the OS.
struct ModelConfig: Codable {
    var general: String = "qwen3.5:9b"
    var coder: String = "qwen3.5:9b"        // shared with general — coder agent specializes via prompt
    var vision: String = "qwen3-vl:8b"
    var reasoner: String = "qwen3.5:9b"     // shared with general — reasoner specializes via prompt
    var router: String = "qwen3.5:0.8b"
    var embedding: String = "qwen3-embedding:0.6b"

    /// Inference backend preference
    var backend: String = "hybrid"  // "ollama", "mlx", "hybrid"

    /// Whether speculative decoding is enabled
    var speculativeDecoding: Bool = true

    /// Whether the embedding router is preferred over LLM router
    var useEmbeddingRouter: Bool = true

    /// Whether ReAct reflection is enabled on agents
    var reflectionEnabled: Bool = true

    func model(for category: AgentCategory) -> String {
        switch category {
        case .general: general
        case .coder: coder
        case .vision: vision
        case .reasoner: reasoner
        case .rag: general
        }
    }

    var numCtx: [AgentCategory: Int] {
        // Tuned for 18GB: 16k is plenty for almost any chat/code interaction.
        // Larger contexts add ~3–4GB of KV cache per agent — not free on this Mac.
        [.general: 16384, .coder: 16384, .vision: 8192, .reasoner: 16384, .rag: 16384]
    }

    /// All model names that are configured (non-empty).
    var allModels: [String] {
        [router, embedding, general, coder, vision, reasoner].filter { !$0.isEmpty }
    }

    /// Roles that have no model assigned.
    var disabledRoles: [AgentCategory] {
        var disabled: [AgentCategory] = []
        if coder.isEmpty { disabled.append(.coder) }
        if vision.isEmpty { disabled.append(.vision) }
        if reasoner.isEmpty { disabled.append(.reasoner) }
        return disabled
    }

    // MARK: - Persistence

    private static let key = "com.macbot.modelConfig"

    static func load() -> ModelConfig? {
        guard let data = UserDefaults.standard.data(forKey: key),
              var config = try? JSONDecoder().decode(ModelConfig.self, from: data)
        else { return nil }

        // One-time migration: replace over-budget models from earlier defaults
        // with the M3 Pro 18GB-friendly choices. Saves ~9GB of resident weights.
        let oversized: Set<String> = [
            "devstral-small-2", "devstral-small-2:latest",
            "deepseek-r1:14b", "deepseek-r1:32b",
            "qwen2.5:14b", "qwen2.5:32b",
        ]
        var migrated = false
        if oversized.contains(config.coder) {
            config.coder = "qwen3.5:9b"
            migrated = true
        }
        if oversized.contains(config.reasoner) {
            config.reasoner = "qwen3.5:9b"
            migrated = true
        }
        if migrated {
            config.save()
            Log.app.info("[modelConfig] migrated oversized models to qwen3.5:9b for 18GB budget")
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static var hasSetup: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }
}
