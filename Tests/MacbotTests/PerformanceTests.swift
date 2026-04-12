import XCTest
@testable import Macbot
import Darwin

final class PerformanceTests: XCTestCase {

    // MARK: - Helpers

    /// Returns the current RSS (Resident Set Size) in bytes via mach_task_basic_info.
    private static func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    // MARK: - Memory budget: multi-turn conversation

    /// Runs a 10-turn scripted conversation through a BaseAgent backed by
    /// MockInferenceProvider and asserts that RSS growth stays under 50 MB.
    /// This catches regressions where conversation history or tool results
    /// accumulate unbounded memory.
    func testMultiTurnConversationMemoryBudget() async throws {
        let mock = MockInferenceProvider()
        let registry = ToolRegistry()

        // Register a handful of tools so the agent actually exercises
        // tool-call filtering each turn.
        let toolNames = [
            "get_stock_price", "web_search", "read_file", "run_command",
            "calculator", "memory_save", "memory_recall",
        ]
        for name in toolNames {
            let spec = ToolSpec(name: name, description: "\(name) tool", properties: [:])
            await registry.register(spec) { _ in "mock result for \(name)" }
        }

        let agent = GeneralAgent(client: mock, model: "mock-model")

        // Warm up: one turn to ensure lazy allocations are out of the way.
        _ = try await agent.run("warmup")

        let rssBefore = Self.currentRSSBytes()

        // 10-turn scripted conversation with varied prompts.
        let prompts = [
            "What is the weather like today?",
            "Show me the stock price of AAPL",
            "Read the file at /tmp/test.txt",
            "Calculate 1234 * 5678",
            "Search the web for Swift concurrency",
            "Save a note: remember to buy milk",
            "What did I save earlier?",
            "Run the command ls -la",
            "What is the stock price of GOOG?",
            "Summarize everything we discussed",
        ]

        for prompt in prompts {
            _ = try await agent.run(prompt)
        }

        let rssAfter = Self.currentRSSBytes()
        let deltaMB = Double(rssAfter - min(rssAfter, rssBefore)) / (1024 * 1024)

        // If rssAfter < rssBefore (GC reclaimed), delta is 0 which passes.
        // Otherwise assert growth stays under 50 MB.
        XCTAssertLessThan(
            deltaMB, 50.0,
            "RSS grew by \(String(format: "%.1f", deltaMB)) MB during 10-turn conversation — exceeds 50 MB budget"
        )
    }

    // MARK: - ToolRegistry filter latency

    /// Filtering the full registry for a query should complete in under 10 ms.
    func testToolRegistryFilterLatency() async {
        let registry = ToolRegistry()
        let toolNames = [
            "get_stock_price", "get_stock_history", "get_market_summary",
            "stock_chart", "generate_chart", "comparison_chart",
            "web_search", "fetch_page",
            "browse_url", "browse_and_act", "screenshot_url",
            "read_file", "write_file", "list_directory", "search_files",
            "take_screenshot", "open_app", "open_url", "send_notification",
            "get_clipboard", "set_clipboard", "list_running_apps",
            "get_system_info", "run_command",
            "memory_save", "memory_recall", "memory_search", "memory_forget",
            "recall_episodes",
            "weather_lookup", "calculator", "unit_convert", "date_calc",
            "define_word", "system_dashboard", "ambient_context",
            "git_status", "git_log", "git_diff",
            "ping", "dns_lookup", "port_check", "http_check",
            "calendar_today", "calendar_create", "calendar_week", "reminder_create",
            "generate_image",
        ]
        for name in toolNames {
            let spec = ToolSpec(name: name, description: "\(name) description", properties: [:])
            await registry.register(spec) { _ in "" }
        }

        // Warm up
        _ = await registry.filteredSpecsAsJSON(for: "warmup query")

        let start = CFAbsoluteTimeGetCurrent()
        _ = await registry.filteredSpecsAsJSON(for: "what's the stock price of AAPL")
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 // ms

        XCTAssertLessThan(
            elapsed, 10.0,
            "ToolRegistry filter took \(String(format: "%.2f", elapsed)) ms — exceeds 10 ms budget"
        )
    }

    // MARK: - VectorIndex search latency with 1000 entries

    /// Searching a VectorIndex with 1000 entries should complete in under 50 ms.
    func testVectorIndexSearchLatency1000Entries() {
        let index = VectorIndex()
        let dims = 8

        // Insert 1000 entries with pseudo-random embeddings.
        for i in 0..<1000 {
            var vec = [Float](repeating: 0, count: dims)
            for d in 0..<dims {
                // Deterministic pseudo-random: use sin to spread values
                vec[d] = sin(Float(i * 7 + d * 13))
            }
            index.insert(id: Int64(i), embedding: vec)
        }
        XCTAssertEqual(index.count, 1000)

        // Query vector
        let query: [Float] = [1.0, 0.5, -0.3, 0.8, -0.1, 0.2, 0.6, -0.4]

        // Warm up
        _ = index.search(query: query, topK: 10)

        let start = CFAbsoluteTimeGetCurrent()
        let results = index.search(query: query, topK: 10)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 // ms

        XCTAssertFalse(results.isEmpty, "Search should return results")
        XCTAssertLessThan(
            elapsed, 50.0,
            "VectorIndex search took \(String(format: "%.2f", elapsed)) ms — exceeds 50 ms budget"
        )
    }
}
