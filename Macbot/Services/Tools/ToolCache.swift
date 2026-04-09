import Foundation

/// A tiny TTL cache for tool responses. Used by the network-bound tools
/// (weather, web search) to avoid hitting upstream APIs twice for the
/// same query inside a short window. Bounded so it can't leak memory.
///
/// Thread-safe via NSLock — this is intentionally simple. The performance
/// gain comes from skipping the round trip, not from the cache lookup
/// itself, so we don't need lock-free data structures.
final class ToolCache: @unchecked Sendable {
    struct Entry {
        let value: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int

    /// - Parameters:
    ///   - ttl: how long an entry is fresh before it's considered stale
    ///     and re-fetched. Pick this based on how time-sensitive the data
    ///     is — 5 min for weather, 10 min for web search.
    ///   - maxEntries: bound on the cache size. When exceeded, the oldest
    ///     entries by insertion order are evicted first.
    init(ttl: TimeInterval, maxEntries: Int = 64) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// Look up a cached value by key. Returns nil if absent or expired.
    func get(_ key: String, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        if entry.expiresAt <= now {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    /// Store a value under `key` with the configured TTL.
    func set(_ key: String, value: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = Entry(value: value, expiresAt: now.addingTimeInterval(ttl))
        if entries.count > maxEntries {
            // Evict the entry with the earliest expiry. This is O(n) but
            // n <= maxEntries which is small (default 64). Good enough.
            if let oldestKey = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                entries.removeValue(forKey: oldestKey)
            }
        }
    }

    /// Drop everything. Used by tests and by /clear command.
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    /// Number of currently-stored entries (including possibly-expired ones
    /// that haven't been read since they expired).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
