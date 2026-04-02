import Foundation

struct ModelConfig: Codable {
    var general: String = "qwen3.5:9b"
    var coder: String = "devstral-small-2"
    var vision: String = "qwen3-vl:8b"
    var reasoner: String = "deepseek-r1:14b"
    var router: String = "qwen3.5:0.8b"
    var embedding: String = "qwen3-embedding:0.6b"

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
        [.general: 32768, .coder: 65536, .vision: 16384, .reasoner: 32768]
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
              let config = try? JSONDecoder().decode(ModelConfig.self, from: data)
        else { return nil }
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
