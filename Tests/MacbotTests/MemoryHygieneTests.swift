import XCTest
import GRDB
@testable import Macbot

/// Locks the contracts for the memory-hygiene improvements:
/// 1. Inline `[YYYY-MM-DD]` timestamps in retrieved memories so the model
///    can discount stale facts ("you told me this on 2026-01-12" is more
///    useful signal than just the bare content).
/// 2. Episode pruning: drop episodes older than N days so the trace store
///    doesn't grow unbounded.
final class MemoryHygieneTests: XCTestCase {

    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        let made = try DatabaseManager.makeTestPool()
        pool = made.pool
        path = made.path
    }

    override func tearDownWithError() throws {
        pool = nil
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    // MARK: - Memory prompt formatting

    func testEmptyListProducesEmptyString() {
        XCTAssertEqual(MemoryStore.formatMemoriesForPrompt([]), "")
    }

    func testFormatIncludesInlineDateForEachMemory() {
        let now = Date()
        let memories = [
            Memory(
                id: 1, category: "fact", content: "the sky is blue",
                metadata: "{}", embedding: nil, createdAt: now, updatedAt: now
            ),
            Memory(
                id: 2, category: "preference", content: "user prefers dark mode",
                metadata: "{}", embedding: nil, createdAt: now, updatedAt: now
            ),
        ]
        let formatted = MemoryStore.formatMemoriesForPrompt(memories)
        XCTAssertTrue(formatted.contains("[Persistent Memory"))
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = .current
        let today = df.string(from: now)
        XCTAssertTrue(formatted.contains("[\(today)]"))
        XCTAssertTrue(formatted.contains("sky is blue"))
        XCTAssertTrue(formatted.contains("dark mode"))
        XCTAssertTrue(formatted.contains("[fact]"))
        XCTAssertTrue(formatted.contains("[preference]"))
    }

    func testFormatUsesUpdatedAtNotCreatedAt() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let memory = Memory(
            id: 1, category: "fact", content: "x",
            metadata: "{}", embedding: nil,
            createdAt: createdAt, updatedAt: updatedAt
        )
        let formatted = MemoryStore.formatMemoriesForPrompt([memory])
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = .current
        XCTAssertTrue(formatted.contains(df.string(from: updatedAt)),
                      "should show updatedAt, not createdAt")
        XCTAssertFalse(formatted.contains(df.string(from: createdAt)),
                       "should not show the older createdAt")
    }

    // MARK: - Episode pruning

    func testPruneRemovesEpisodesOlderThanCutoff() throws {
        let now = Date()
        let day: TimeInterval = 86_400
        let oldEp = makeEpisode(title: "old", startedAt: now.addingTimeInterval(-100 * day))
        let middleEp = makeEpisode(title: "middle", startedAt: now.addingTimeInterval(-50 * day))
        let newEp = makeEpisode(title: "new", startedAt: now)

        try pool.write { db in
            for ep in [oldEp, middleEp, newEp] {
                var local = ep
                try local.insert(db)
            }
        }

        // Prune anything older than 90 days. Only the 100-day-old one should go.
        // We use a local helper rather than EpisodicMemory.shared so the test
        // hits our temp pool, not the production database singleton.
        let deleted = pruneEpisodes(olderThanDays: 90)
        XCTAssertEqual(deleted, 1)

        let remaining = try pool.read { db in
            try Episode.fetchAll(db)
        }
        XCTAssertEqual(remaining.count, 2)
        let titles = Set(remaining.map(\.title))
        XCTAssertTrue(titles.contains("middle"))
        XCTAssertTrue(titles.contains("new"))
        XCTAssertFalse(titles.contains("old"))
    }

    func testPruneIsNoOpForFreshEpisodes() throws {
        let now = Date()
        let recent = makeEpisode(title: "recent", startedAt: now.addingTimeInterval(-3 * 86_400))
        try pool.write { db in
            var local = recent
            try local.insert(db)
        }

        let deleted = pruneEpisodes(olderThanDays: 90)
        XCTAssertEqual(deleted, 0)
        let count = try pool.read { db in try Episode.fetchCount(db) }
        XCTAssertEqual(count, 1)
    }

    func testPruneRejectsZeroOrNegativeDays() {
        XCTAssertEqual(pruneEpisodes(olderThanDays: 0), 0)
        XCTAssertEqual(pruneEpisodes(olderThanDays: -10), 0)
    }

    // MARK: - Helpers

    private func makeEpisode(title: String, startedAt: Date) -> Episode {
        Episode(
            id: nil,
            title: title,
            summary: "summary",
            topics: "[]",
            messageCount: 5,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(600),
            embedding: nil,
            createdAt: startedAt
        )
    }

    /// Mirrors EpisodicMemory.pruneOlderThan(days:) against the test pool.
    /// We can't use the real method here because it operates on the shared
    /// singleton's production database.
    private func pruneEpisodes(olderThanDays days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        do {
            return try pool.write { db in
                try Episode.filter(Column("startedAt") < cutoff).deleteAll(db)
            }
        } catch {
            return 0
        }
    }
}
