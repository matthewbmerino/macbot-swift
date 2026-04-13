import Foundation

/// Maps hardware capabilities to the best model configuration.
/// Runs once at first launch, persists the recommendation. The tier
/// table can be updated remotely (via model-tiers.json on GitHub)
/// without shipping a new binary — checked every 30 days.
enum HardwareScanner {

    // MARK: - Public API

    /// Returns a model config tuned for this Mac's hardware.
    /// First call: scans hardware + applies tier table + saves.
    /// Subsequent calls: returns the saved config (user's choices
    /// are never overwritten).
    static func recommendedConfig() -> ModelConfig {
        if ModelConfig.hasSetup, let saved = ModelConfig.load() {
            return saved
        }

        let hw = HardwareDetector.detect()
        let tier = bestTier(for: hw)

        var config = ModelConfig()
        config.general = tier.general
        config.coder = tier.coder
        config.reasoner = tier.reasoner
        config.vision = tier.vision
        config.router = tier.router
        config.embedding = tier.embedding
        config.save()

        Log.app.info("[hardware] \(hw.chipName), \(Int(hw.totalRAM))GB → tier '\(tier.name)': \(tier.general)")
        return config
    }

    /// Human-readable recommendation for display in onboarding/settings.
    static func recommendation() -> (profile: HardwareProfile, tier: ModelTier) {
        let hw = HardwareDetector.detect()
        let tier = bestTier(for: hw)
        return (hw, tier)
    }

    // MARK: - Tier Matching

    static func bestTier(for hw: HardwareProfile) -> ModelTier {
        let memGB = Int(hw.totalRAM)
        let table = currentTierTable()
        return table.first(where: { memGB >= $0.minMemoryGB })
            ?? table.last
            ?? .fallback
    }

    // MARK: - Tier Table (local + remote)

    private static func currentTierTable() -> [ModelTier] {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(TierTableCache.self, from: data),
           cached.fetchedAt.timeIntervalSinceNow > -maxAge {
            return cached.tiers
        }
        return bundledTiers
    }

    /// Background fetch of updated tier table. Called on every app launch,
    /// but only actually downloads if the cache is >30 days old.
    /// Never blocks UI, never fails loudly.
    static func refreshTierTableInBackground() {
        Task.detached(priority: .utility) {
            // Skip if cache is fresh
            if let data = UserDefaults.standard.data(forKey: cacheKey),
               let cached = try? JSONDecoder().decode(TierTableCache.self, from: data),
               cached.fetchedAt.timeIntervalSinceNow > -maxAge {
                return
            }

            guard let url = URL(string: remoteURL) else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let tiers = try JSONDecoder().decode([ModelTier].self, from: data)
                guard !tiers.isEmpty else { return }
                let cache = TierTableCache(tiers: tiers, fetchedAt: Date())
                let encoded = try JSONEncoder().encode(cache)
                UserDefaults.standard.set(encoded, forKey: cacheKey)
                Log.app.info("[hardware] refreshed tier table: \(tiers.count) tiers")
            } catch {
                Log.app.debug("[hardware] tier refresh skipped: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Constants

    private static let cacheKey = "com.macbot.tierTable"
    private static let maxAge: TimeInterval = 30 * 86_400
    private static let remoteURL =
        "https://raw.githubusercontent.com/matthewbmerino/macbot/main/model-tiers.json"

    // MARK: - Bundled Tiers (sorted by minMemoryGB descending)

    static let bundledTiers: [ModelTier] = [
        ModelTier(
            name: "ultra", minMemoryGB: 64,
            general: "gemma4:27b", coder: "gemma4:27b",
            reasoner: "gemma4:27b", vision: "gemma4:27b",
            router: "qwen3.5:0.8b", embedding: "qwen3-embedding:0.6b",
            contextSize: 32768,
            description: "Full-size models with massive context."
        ),
        ModelTier(
            name: "max", minMemoryGB: 48,
            general: "qwen3.5:27b", coder: "qwen3.5:27b",
            reasoner: "qwen3.5:27b", vision: "gemma4:12b",
            router: "qwen3.5:0.8b", embedding: "qwen3-embedding:0.6b",
            contextSize: 32768,
            description: "27B with dedicated 12B vision."
        ),
        ModelTier(
            name: "pro-xl", minMemoryGB: 32,
            general: "qwen3.5:27b", coder: "qwen3.5:27b",
            reasoner: "qwen3.5:27b", vision: "gemma4:e4b",
            router: "qwen3.5:0.8b", embedding: "qwen3-embedding:0.6b",
            contextSize: 16384,
            description: "27B model — major quality jump over 9B."
        ),
        ModelTier(
            name: "pro", minMemoryGB: 24,
            general: "qwen3.5:14b", coder: "qwen3.5:14b",
            reasoner: "qwen3.5:14b", vision: "gemma4:e4b",
            router: "qwen3.5:0.8b", embedding: "qwen3-embedding:0.6b",
            contextSize: 16384,
            description: "14B model with room for vision."
        ),
        ModelTier(
            name: "standard", minMemoryGB: 18,
            general: "qwen3.5:9b", coder: "qwen3.5:9b",
            reasoner: "qwen3.5:9b", vision: "gemma4:e4b",
            router: "qwen3.5:0.8b", embedding: "qwen3-embedding:0.6b",
            contextSize: 16384,
            description: "Best tool-calling model at 9B."
        ),
        ModelTier(
            name: "compact", minMemoryGB: 16,
            general: "qwen3.5:7b", coder: "qwen3.5:7b",
            reasoner: "qwen3.5:7b", vision: "gemma4:e4b",
            router: "qwen3.5:0.8b", embedding: "qwen3-embedding:0.6b",
            contextSize: 8192,
            description: "7B model with reduced context for 16GB."
        ),
        ModelTier(
            name: "lite", minMemoryGB: 8,
            general: "qwen3.5:4b", coder: "qwen3.5:4b",
            reasoner: "qwen3.5:4b", vision: "",
            router: "qwen3.5:0.8b", embedding: "qwen3-embedding:0.6b",
            contextSize: 4096,
            description: "Lightweight 4B. Limited but functional on 8GB."
        ),
    ]
}

// MARK: - Models

struct ModelTier: Codable {
    let name: String
    let minMemoryGB: Int
    let general: String
    let coder: String
    let reasoner: String
    let vision: String
    let router: String
    let embedding: String
    let contextSize: Int
    let description: String

    static let fallback = ModelTier(
        name: "fallback", minMemoryGB: 0,
        general: "qwen3.5:4b", coder: "qwen3.5:4b",
        reasoner: "qwen3.5:4b", vision: "",
        router: "qwen3.5:0.8b", embedding: "qwen3-embedding:0.6b",
        contextSize: 4096, description: "Minimal configuration."
    )
}

struct TierTableCache: Codable {
    let tiers: [ModelTier]
    let fetchedAt: Date
}
