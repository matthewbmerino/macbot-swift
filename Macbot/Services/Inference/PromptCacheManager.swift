import Foundation

/// Manages pre-computed prompt token caches for agent system prompts.
/// When using MLX, system prompts can be pre-tokenized and their KV cache states
/// stored so subsequent turns skip re-encoding the system prefix.
///
/// For Ollama mode, this stores tokenized representations to avoid repeated
/// token estimation on static prompt segments.
actor PromptCacheManager {
    struct CacheEntry {
        let promptHash: Int
        let tokenCount: Int
        let cachedAt: Date
        var hitCount: Int = 0
    }

    private var cache: [String: CacheEntry] = [:]  // key: agent name
    private let maxEntries = 10
    private let ttl: TimeInterval = 3600  // 1 hour

    /// Register a system prompt for an agent. Returns the token count.
    func register(agentName: String, prompt: String, tokenCount: Int) -> CacheEntry {
        evictStale()

        let entry = CacheEntry(
            promptHash: prompt.hashValue,
            tokenCount: tokenCount,
            cachedAt: Date()
        )
        cache[agentName] = entry
        return entry
    }

    /// Check if a cached prompt is still valid (hasn't changed).
    func isValid(agentName: String, prompt: String) -> Bool {
        guard let entry = cache[agentName] else { return false }
        return entry.promptHash == prompt.hashValue
            && Date().timeIntervalSince(entry.cachedAt) < ttl
    }

    /// Record a cache hit for metrics.
    func recordHit(agentName: String) {
        cache[agentName]?.hitCount += 1
    }

    /// Get cached token count for an agent's system prompt.
    func tokenCount(for agentName: String) -> Int? {
        cache[agentName]?.tokenCount
    }

    /// Get cache stats for monitoring.
    func stats() -> [(agent: String, hits: Int, age: TimeInterval)] {
        let now = Date()
        return cache.map { ($0.key, $0.value.hitCount, now.timeIntervalSince($0.value.cachedAt)) }
    }

    func invalidate(agentName: String) {
        cache.removeValue(forKey: agentName)
    }

    func invalidateAll() {
        cache.removeAll()
    }

    private func evictStale() {
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.cachedAt) < ttl }

        if cache.count >= maxEntries {
            let sorted = cache.sorted { $0.value.hitCount < $1.value.hitCount }
            for key in sorted.prefix(cache.count - maxEntries + 1).map(\.key) {
                cache.removeValue(forKey: key)
            }
        }
    }
}
