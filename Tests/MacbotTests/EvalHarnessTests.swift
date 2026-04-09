import XCTest
@testable import Macbot

/// Locks the eval harness scoring logic so the harness itself is
/// regression-tested. The live `run` method needs Ollama, but the
/// scoring is pure — given a case definition + a synthetic "what
/// happened" tuple, we can verify pass/fail decisions deterministically.
final class EvalHarnessTests: XCTestCase {

    // MARK: - Pass cases

    func testCaseWithNoExpectationsAlwaysPasses() {
        let c = EvalCase(
            name: "noop",
            query: "anything",
            expectedAgent: nil,
            expectedTools: [],
            forbiddenTools: [],
            mustContain: [],
            mustNotContain: [],
            category: "test"
        )
        let result = EvalHarness.scoreCase(
            c,
            actualResponse: "whatever",
            actualAgent: "general",
            actualTools: []
        )
        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.routeOK)
        XCTAssertTrue(result.toolOK)
        XCTAssertTrue(result.containmentOK)
    }

    func testCorrectAgentAndContentPasses() {
        let c = EvalCase(
            name: "happy",
            query: "what's 2+2?",
            expectedAgent: "general",
            expectedTools: [],
            forbiddenTools: [],
            mustContain: ["4"],
            mustNotContain: [],
            category: "routing"
        )
        let result = EvalHarness.scoreCase(
            c,
            actualResponse: "The answer is 4",
            actualAgent: "general",
            actualTools: []
        )
        XCTAssertTrue(result.passed)
    }

    // MARK: - Routing failures

    func testWrongAgentFails() {
        let c = EvalCase(
            name: "route",
            query: "code please",
            expectedAgent: "coder",
            expectedTools: [],
            forbiddenTools: [],
            mustContain: [],
            mustNotContain: [],
            category: "routing"
        )
        let result = EvalHarness.scoreCase(
            c,
            actualResponse: "ok",
            actualAgent: "general",
            actualTools: []
        )
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.routeOK)
        XCTAssertTrue(result.failures.contains { $0.contains("route") })
    }

    // MARK: - Tool selection failures

    func testMissingExpectedToolFails() {
        let c = EvalCase(
            name: "tool",
            query: "calc",
            expectedAgent: nil,
            expectedTools: ["calculator"],
            forbiddenTools: [],
            mustContain: [],
            mustNotContain: [],
            category: "tools"
        )
        let result = EvalHarness.scoreCase(
            c,
            actualResponse: "5",
            actualAgent: "general",
            actualTools: []
        )
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.toolOK)
        XCTAssertTrue(result.failures.contains { $0.contains("missing tools") })
    }

    func testForbiddenToolUsedFails() {
        let c = EvalCase(
            name: "tool",
            query: "hi",
            expectedAgent: nil,
            expectedTools: [],
            forbiddenTools: ["run_python"],
            mustContain: [],
            mustNotContain: [],
            category: "tools"
        )
        let result = EvalHarness.scoreCase(
            c,
            actualResponse: "ok",
            actualAgent: "general",
            actualTools: ["run_python"]
        )
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.toolOK)
        XCTAssertTrue(result.failures.contains { $0.contains("forbidden tools") })
    }

    func testCorrectToolPasses() {
        let c = EvalCase(
            name: "tool",
            query: "calc",
            expectedAgent: nil,
            expectedTools: ["calculator"],
            forbiddenTools: ["run_python"],
            mustContain: [],
            mustNotContain: [],
            category: "tools"
        )
        let result = EvalHarness.scoreCase(
            c,
            actualResponse: "5",
            actualAgent: "general",
            actualTools: ["calculator"]
        )
        XCTAssertTrue(result.passed)
    }

    // MARK: - Containment

    func testMustContainCheckIsCaseInsensitive() {
        let c = EvalCase(
            name: "case",
            query: "x",
            expectedAgent: nil,
            expectedTools: [],
            forbiddenTools: [],
            mustContain: ["amazon"],
            mustNotContain: [],
            category: "test"
        )
        let result = EvalHarness.scoreCase(
            c,
            actualResponse: "Amazon stock rose today",
            actualAgent: "general",
            actualTools: []
        )
        XCTAssertTrue(result.passed)
    }

    func testMustNotContainCatchesForbiddenPhrase() {
        // The "essentially flat" anti-flat regression case.
        let c = EvalCase(
            name: "anti-flat",
            query: "how did Amazon do today",
            expectedAgent: nil,
            expectedTools: ["get_stock_price"],
            forbiddenTools: [],
            mustContain: [],
            mustNotContain: ["essentially flat"],
            category: "antihallucination"
        )
        let result = EvalHarness.scoreCase(
            c,
            actualResponse: "Amazon was essentially flat today, no change from the start.",
            actualAgent: "general",
            actualTools: ["get_stock_price"]
        )
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.containmentOK)
        XCTAssertTrue(result.failures.contains { $0.contains("contains forbidden") })
    }

    func testMissingRequiredPhraseFails() {
        let c = EvalCase(
            name: "missing",
            query: "calc 50 squared",
            expectedAgent: nil,
            expectedTools: [],
            forbiddenTools: [],
            mustContain: ["2500"],
            mustNotContain: [],
            category: "test"
        )
        let result = EvalHarness.scoreCase(
            c,
            actualResponse: "I'm not sure",
            actualAgent: "general",
            actualTools: []
        )
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains { $0.contains("missing") })
    }

    // MARK: - Error propagation

    func testErrorBecomesFailure() {
        let c = EvalCase(
            name: "err",
            query: "x",
            expectedAgent: nil,
            expectedTools: [],
            forbiddenTools: [],
            mustContain: [],
            mustNotContain: [],
            category: "test"
        )
        let result = EvalHarness.scoreCase(
            c,
            actualResponse: "",
            actualAgent: "unknown",
            actualTools: [],
            actualError: "network timeout"
        )
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failures.contains { $0.contains("error") })
    }

    // MARK: - Report aggregation

    func testReportAggregatesPerCategory() {
        let pass = EvalHarness.scoreCase(
            EvalCase(name: "p", query: "", expectedAgent: nil, expectedTools: [], forbiddenTools: [], mustContain: [], mustNotContain: [], category: "routing"),
            actualResponse: "", actualAgent: "general", actualTools: []
        )
        let fail = EvalHarness.scoreCase(
            EvalCase(name: "f", query: "", expectedAgent: "coder", expectedTools: [], forbiddenTools: [], mustContain: [], mustNotContain: [], category: "routing"),
            actualResponse: "", actualAgent: "general", actualTools: []
        )
        let report = EvalHarness.makeReport(results: [pass, fail], totalLatency: 1000)
        XCTAssertEqual(report.totalCases, 2)
        XCTAssertEqual(report.passed, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.perCategory["routing"]?.passed, 1)
        XCTAssertEqual(report.perCategory["routing"]?.total, 2)
        XCTAssertEqual(report.routeAccuracy, 0.5, accuracy: 0.001)
    }

    func testReportSummaryStringContainsHeaders() {
        let result = EvalHarness.scoreCase(
            EvalCase(name: "p", query: "", expectedAgent: nil, expectedTools: [], forbiddenTools: [], mustContain: [], mustNotContain: [], category: "tools"),
            actualResponse: "", actualAgent: "general", actualTools: []
        )
        let report = EvalHarness.makeReport(results: [result], totalLatency: 500)
        let summary = report.summary
        XCTAssertTrue(summary.contains("EVAL REPORT"))
        XCTAssertTrue(summary.contains("Pass:"))
        XCTAssertTrue(summary.contains("Route accuracy"))
        XCTAssertTrue(summary.contains("By category"))
    }

    // MARK: - Corpus integrity

    func testCorpusContainsRegressionCasesForFixedBugs() {
        // The cases I added in this commit that target specific bugs we
        // fixed: anti-flat for the AMZN summary, current_time for the
        // time fabrication, cross_agent_followup for the transcript fix.
        let names = Set(EvalHarness.cases.map(\.name))
        XCTAssertTrue(names.contains("tool_current_time"),
                      "current_time regression case must be in the corpus")
        XCTAssertTrue(names.contains("anti_flat_summary"),
                      "anti-flat regression case must be in the corpus")
        XCTAssertTrue(names.contains("cross_agent_followup"),
                      "cross-agent followup regression case must be in the corpus")
    }

    func testCorpusEveryCaseHasACategory() {
        for c in EvalHarness.cases {
            XCTAssertFalse(c.category.isEmpty, "case '\(c.name)' has empty category")
            XCTAssertFalse(c.name.isEmpty, "case has empty name")
            XCTAssertFalse(c.query.isEmpty, "case '\(c.name)' has empty query")
        }
    }
}
