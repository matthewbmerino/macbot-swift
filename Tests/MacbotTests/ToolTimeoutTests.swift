import XCTest
@testable import Macbot

/// Locks the per-category tool timeout map. The previous 30s blanket
/// made every tool wait the full slow-tier budget on a hang —
/// `current_time` should not take 30s to surface a hang.
final class ToolTimeoutTests: XCTestCase {

    func testFastToolsGetFastTimeout() {
        for name in ["current_time", "calculator", "get_clipboard", "git_status", "memory_recall"] {
            XCTAssertEqual(ToolRegistry.timeout(for: name), ToolRegistry.fastTimeout,
                           "\(name) should be in the fast tier")
        }
    }

    func testMediumToolsGetMediumTimeout() {
        for name in ["weather_lookup", "get_stock_price", "web_search", "fetch_page", "calendar_today"] {
            XCTAssertEqual(ToolRegistry.timeout(for: name), ToolRegistry.mediumTimeout,
                           "\(name) should be in the medium tier")
        }
    }

    func testSlowToolsGetSlowTimeout() {
        for name in ["run_python", "run_command", "ingest_directory", "stock_chart", "generate_image"] {
            XCTAssertEqual(ToolRegistry.timeout(for: name), ToolRegistry.slowTimeout,
                           "\(name) should be in the slow tier")
        }
    }

    func testUnknownToolGetsMediumDefault() {
        // Defensive default: a tool not in any list (e.g. a brand-new tool
        // someone forgot to categorize) should get medium, not fast or slow.
        XCTAssertEqual(ToolRegistry.timeout(for: "future_unregistered_tool"), ToolRegistry.mediumTimeout)
    }

    func testTierBudgetsHaveSensibleOrdering() {
        XCTAssertLessThan(ToolRegistry.fastTimeout, ToolRegistry.mediumTimeout)
        XCTAssertLessThan(ToolRegistry.mediumTimeout, ToolRegistry.slowTimeout)
    }

    func testToolTimeoutBackCompatEqualsSlowTier() {
        // Legacy callers can still reference toolTimeout. Keep it as the
        // slow tier so the meaning ("the maximum any tool will wait") is
        // preserved.
        XCTAssertEqual(ToolRegistry.toolTimeout, ToolRegistry.slowTimeout)
    }
}
