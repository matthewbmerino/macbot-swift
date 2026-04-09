import XCTest
@testable import Macbot

/// Locks the contract for the simple TTL cache used by network-bound
/// tools to skip duplicate upstream requests inside a session.
final class ToolCacheTests: XCTestCase {

    func testGetMissReturnsNil() {
        let cache = ToolCache(ttl: 60)
        XCTAssertNil(cache.get("nope"))
    }

    func testSetThenGetReturnsValue() {
        let cache = ToolCache(ttl: 60)
        cache.set("k", value: "v")
        XCTAssertEqual(cache.get("k"), "v")
    }

    func testExpiredEntriesAreEvicted() {
        let cache = ToolCache(ttl: 60)
        let now = Date()
        cache.set("k", value: "v", now: now)
        // 61 seconds later: past the TTL.
        XCTAssertNil(cache.get("k", now: now.addingTimeInterval(61)))
        // The expired entry is also removed from the store, not just hidden.
        XCTAssertEqual(cache.count, 0)
    }

    func testExpiredCheckUsesGreaterThanOrEqual() {
        // Boundary condition: an entry that expires exactly at `now`
        // should be considered expired. This matters for the test
        // determinism more than for production correctness.
        let cache = ToolCache(ttl: 60)
        let now = Date()
        cache.set("k", value: "v", now: now)
        XCTAssertNil(cache.get("k", now: now.addingTimeInterval(60)))
    }

    func testFreshEntryIsReturnedBeforeExpiry() {
        let cache = ToolCache(ttl: 60)
        let now = Date()
        cache.set("k", value: "v", now: now)
        XCTAssertEqual(cache.get("k", now: now.addingTimeInterval(30)), "v")
    }

    func testMaxEntriesEvictsOldest() {
        let cache = ToolCache(ttl: 600, maxEntries: 3)
        let base = Date()
        cache.set("a", value: "1", now: base)
        cache.set("b", value: "2", now: base.addingTimeInterval(1))
        cache.set("c", value: "3", now: base.addingTimeInterval(2))
        cache.set("d", value: "4", now: base.addingTimeInterval(3))  // pushes a out
        XCTAssertEqual(cache.count, 3)
        // 'a' should be the oldest by expiresAt — it had the earliest insert
        // time and the same TTL, so it expires first.
        XCTAssertNil(cache.get("a"))
        XCTAssertEqual(cache.get("b"), "2")
        XCTAssertEqual(cache.get("c"), "3")
        XCTAssertEqual(cache.get("d"), "4")
    }

    func testClearAllRemovesEverything() {
        let cache = ToolCache(ttl: 60)
        cache.set("a", value: "1")
        cache.set("b", value: "2")
        cache.clearAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.get("a"))
        XCTAssertNil(cache.get("b"))
    }
}
