import Foundation

/// One row in the eval set. Deterministic checks first; LLM-judge later.
struct EvalCase {
    let name: String
    let query: String
    let expectedAgent: String?         // e.g. "general", "coder" — nil = don't check
    let expectedTools: [String]        // tools that MUST be called (subset)
    let forbiddenTools: [String]       // tools that MUST NOT be called
    let mustContain: [String]          // case-insensitive substrings in response
    let mustNotContain: [String]       // ditto, negative
    let category: String               // for grouping in reports
}

struct EvalResult {
    let caseName: String
    let category: String
    let passed: Bool
    let routeOK: Bool
    let toolOK: Bool
    let containmentOK: Bool
    let actualAgent: String
    let actualTools: [String]
    let response: String
    let latencyMs: Int
    let failures: [String]
}

struct EvalReport {
    let totalCases: Int
    let passed: Int
    let failed: Int
    let totalLatencyMs: Int
    let perCategory: [String: (passed: Int, total: Int)]
    let routeAccuracy: Double
    let toolAccuracy: Double
    let containmentAccuracy: Double
    let results: [EvalResult]

    var summary: String {
        var lines: [String] = []
        let pct = totalCases > 0 ? Double(passed) / Double(totalCases) * 100 : 0
        lines.append("=== EVAL REPORT ===")
        lines.append("Pass: \(passed)/\(totalCases)  (\(String(format: "%.1f", pct))%)")
        lines.append("Route accuracy:       \(String(format: "%.1f", routeAccuracy * 100))%")
        lines.append("Tool accuracy:        \(String(format: "%.1f", toolAccuracy * 100))%")
        lines.append("Containment accuracy: \(String(format: "%.1f", containmentAccuracy * 100))%")
        lines.append("Total latency: \(totalLatencyMs / 1000)s  avg \(totalCases > 0 ? totalLatencyMs / totalCases : 0)ms")
        lines.append("")
        lines.append("By category:")
        for (cat, stat) in perCategory.sorted(by: { $0.key < $1.key }) {
            let p = stat.total > 0 ? Double(stat.passed) / Double(stat.total) * 100 : 0
            lines.append("  \(cat): \(stat.passed)/\(stat.total)  (\(String(format: "%.0f", p))%)")
        }
        let failures = results.filter { !$0.passed }
        if !failures.isEmpty {
            lines.append("")
            lines.append("Failures:")
            for r in failures {
                lines.append("  ✗ \(r.caseName) — \(r.failures.joined(separator: "; "))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Pure scoring helper, extracted from `run` so the harness can be
/// unit-tested without a live orchestrator. Takes the case definition
/// plus what actually happened (response text, routed agent, tool list,
/// optional error) and produces an EvalResult with the same scoring
/// rules the live harness uses.
extension EvalHarness {
    static func scoreCase(
        _ c: EvalCase,
        actualResponse: String,
        actualAgent: String,
        actualTools: [String],
        actualError: String? = nil,
        latencyMs: Int = 0
    ) -> EvalResult {
        var failures: [String] = []

        let routeOK: Bool
        if let expected = c.expectedAgent {
            routeOK = (actualAgent == expected)
            if !routeOK { failures.append("route: expected=\(expected) got=\(actualAgent)") }
        } else { routeOK = true }

        let toolSet = Set(actualTools)
        let missing = c.expectedTools.filter { !toolSet.contains($0) }
        let forbidden = c.forbiddenTools.filter { toolSet.contains($0) }
        if !missing.isEmpty { failures.append("missing tools: \(missing.joined(separator: ","))") }
        if !forbidden.isEmpty { failures.append("forbidden tools: \(forbidden.joined(separator: ","))") }
        let toolOK = missing.isEmpty && forbidden.isEmpty

        let lower = actualResponse.lowercased()
        let missingPhrases = c.mustContain.filter { !lower.contains($0.lowercased()) }
        let presentBad = c.mustNotContain.filter { lower.contains($0.lowercased()) }
        if !missingPhrases.isEmpty { failures.append("missing: \(missingPhrases.joined(separator: ","))") }
        if !presentBad.isEmpty { failures.append("contains forbidden: \(presentBad.joined(separator: ","))") }
        let containmentOK = missingPhrases.isEmpty && presentBad.isEmpty

        if let err = actualError { failures.append("error: \(err)") }

        return EvalResult(
            caseName: c.name,
            category: c.category,
            passed: failures.isEmpty,
            routeOK: routeOK,
            toolOK: toolOK,
            containmentOK: containmentOK,
            actualAgent: actualAgent,
            actualTools: actualTools,
            response: actualResponse,
            latencyMs: latencyMs,
            failures: failures
        )
    }

    /// Pure report builder. Public so the unit tests can validate
    /// aggregation logic without going through `run`.
    static func makeReport(results: [EvalResult], totalLatency: Int) -> EvalReport {
        buildReport(results: results, totalLatency: totalLatency)
    }
}

/// Held-out evaluation harness. Runs a frozen set of cases against the live
/// orchestrator and produces a numerical report. Designed to be cheap enough
/// to run nightly and surface regressions before they ship.
enum EvalHarness {

    /// The eval set. Keep this small (~30 cases), focused, and cover the
    /// dimensions that actually matter: routing, tool selection, refusal,
    /// multi-step, factuality.
    static let cases: [EvalCase] = [

        // ─── Routing: general agent ────────────────────────────────────
        .init(name: "route_greeting",
              query: "hi there", expectedAgent: "general",
              expectedTools: [], forbiddenTools: ["run_python", "run_command"],
              mustContain: [], mustNotContain: ["error", "tool"],
              category: "routing"),

        .init(name: "route_simple_question",
              query: "what's 2 + 2?", expectedAgent: "general",
              expectedTools: [], forbiddenTools: [],
              mustContain: ["4"], mustNotContain: [],
              category: "routing"),

        // ─── Routing: coder agent ──────────────────────────────────────
        .init(name: "route_code_request",
              query: "write a swift function that reverses a string",
              expectedAgent: "coder",
              expectedTools: [], forbiddenTools: [],
              mustContain: ["func"], mustNotContain: [],
              category: "routing"),

        // ─── Tool: web search ──────────────────────────────────────────
        .init(name: "tool_web_search_news",
              query: "what's the latest news about Apple",
              expectedAgent: nil,
              expectedTools: ["web_search"], forbiddenTools: [],
              mustContain: [], mustNotContain: ["I don't have access"],
              category: "tools"),

        // ─── Tool: calculator ──────────────────────────────────────────
        .init(name: "tool_calculator",
              query: "calculate 234 times 567",
              expectedAgent: nil,
              expectedTools: ["calculator"], forbiddenTools: [],
              mustContain: ["132678"], mustNotContain: [],
              category: "tools"),

        // ─── Tool: weather ─────────────────────────────────────────────
        .init(name: "tool_weather",
              query: "what's the weather in Tokyo",
              expectedAgent: nil,
              expectedTools: ["weather_lookup"], forbiddenTools: [],
              mustContain: [], mustNotContain: ["I don't"],
              category: "tools"),

        // ─── Tool: ambient context ─────────────────────────────────────
        .init(name: "tool_ambient_context",
              query: "what app am I currently using",
              expectedAgent: nil,
              expectedTools: ["ambient_context"], forbiddenTools: [],
              mustContain: [], mustNotContain: [],
              category: "tools"),

        // ─── Tool: episodic recall ─────────────────────────────────────
        .init(name: "tool_recall_episodes",
              query: "what did we talk about in previous chats",
              expectedAgent: nil,
              expectedTools: ["recall_episodes"], forbiddenTools: [],
              mustContain: [], mustNotContain: ["I don't have memory", "I don't have access"],
              category: "tools"),

        // ─── Tool: file ops ────────────────────────────────────────────
        .init(name: "tool_read_file",
              query: "read the file at /etc/hosts",
              expectedAgent: nil,
              expectedTools: ["read_file"], forbiddenTools: [],
              mustContain: ["localhost"], mustNotContain: [],
              category: "tools"),

        // ─── Tool: stock price ─────────────────────────────────────────
        .init(name: "tool_stock_price",
              query: "what's the current price of AAPL",
              expectedAgent: nil,
              expectedTools: ["get_stock_price"], forbiddenTools: [],
              mustContain: [], mustNotContain: ["I cannot provide"],
              category: "tools"),

        // ─── Tool: define word ─────────────────────────────────────────
        .init(name: "tool_define_word",
              query: "define the word ephemeral",
              expectedAgent: nil,
              expectedTools: ["define_word"], forbiddenTools: [],
              mustContain: [], mustNotContain: [],
              category: "tools"),

        // ─── Tool: unit convert ────────────────────────────────────────
        .init(name: "tool_unit_convert",
              query: "convert 100 kilometers to miles",
              expectedAgent: nil,
              expectedTools: ["unit_convert"], forbiddenTools: [],
              mustContain: ["62"], mustNotContain: [],
              category: "tools"),

        // ─── Anti-hallucination ────────────────────────────────────────
        .init(name: "anti_hallucinate_memory",
              query: "do you remember anything about me from before",
              expectedAgent: nil,
              expectedTools: [], forbiddenTools: [],
              mustContain: [], mustNotContain: ["I have no memory", "I don't retain"],
              category: "antihallucination"),

        .init(name: "anti_hallucinate_capability",
              query: "can you take a screenshot",
              expectedAgent: nil,
              expectedTools: [], forbiddenTools: [],
              mustContain: [], mustNotContain: ["I cannot", "I'm not able"],
              category: "antihallucination"),

        // ─── Multi-step ────────────────────────────────────────────────
        .init(name: "multi_step_calc_then_format",
              query: "calculate 50 squared and tell me the answer",
              expectedAgent: nil,
              expectedTools: ["calculator"], forbiddenTools: [],
              mustContain: ["2500"], mustNotContain: [],
              category: "multistep"),

        // ─── Refusal handling ──────────────────────────────────────────
        .init(name: "refusal_unknown_personal",
              query: "what's my mother's maiden name",
              expectedAgent: nil,
              expectedTools: [], forbiddenTools: [],
              mustContain: [], mustNotContain: ["Smith", "Jones"],
              category: "refusal"),

        // ─── Time of day must use the tool, not fabricate ───────────────
        .init(name: "tool_current_time",
              query: "what time is it",
              expectedAgent: nil,
              expectedTools: ["current_time"], forbiddenTools: [],
              mustContain: [], mustNotContain: ["I don't know", "I'm not sure"],
              category: "tools"),

        // ─── Stock price must include intraday or change %, never just "flat" ─
        .init(name: "anti_flat_summary",
              query: "how did Amazon do today",
              expectedAgent: nil,
              expectedTools: ["get_stock_price"], forbiddenTools: [],
              mustContain: [],
              mustNotContain: ["essentially flat", "no change from the start"],
              category: "antihallucination"),

        // ─── Cross-agent context survival (the regression we fixed) ─────
        .init(name: "cross_agent_followup",
              query: "what's 7 times 8",
              expectedAgent: nil,
              expectedTools: ["calculator"], forbiddenTools: [],
              mustContain: ["56"], mustNotContain: [],
              category: "multistep"),
    ]

    /// Run the full set against an orchestrator. Sequential to avoid cross-talk
    /// in agent histories. Each case gets a fresh user ID so traces stay clean.
    static func run(
        orchestrator: Orchestrator,
        only: [String]? = nil,
        progress: ((Int, Int, String) -> Void)? = nil
    ) async -> EvalReport {
        let target = only.map { names in cases.filter { names.contains($0.name) } } ?? cases
        var results: [EvalResult] = []
        var totalLatency = 0

        for (i, c) in target.enumerated() {
            progress?(i + 1, target.count, c.name)
            let userId = "eval-\(UUID().uuidString.prefix(8))"
            let started = Date()

            var actualResponse = ""
            var actualError: String?
            do {
                actualResponse = try await orchestrator.handleMessage(userId: userId, message: c.query)
            } catch {
                actualError = "\(error)"
            }

            let latency = Int(Date().timeIntervalSince(started) * 1000)
            totalLatency += latency

            // Pull the freshly-recorded trace to inspect routing + tools
            let traces = TraceStore.shared.recent(limit: 20)
            let trace = traces.first(where: { $0.userMessage == c.query })
            let actualAgent = trace?.routedAgent ?? "unknown"
            let actualTools = trace?.toolCallList.compactMap { $0["name"] as? String } ?? []

            // Score via the pure helper so the same logic runs in unit tests.
            results.append(scoreCase(
                c,
                actualResponse: actualResponse,
                actualAgent: actualAgent,
                actualTools: actualTools,
                actualError: actualError,
                latencyMs: latency
            ))
        }

        return buildReport(results: results, totalLatency: totalLatency)
    }

    private static func buildReport(results: [EvalResult], totalLatency: Int) -> EvalReport {
        let total = results.count
        let passed = results.filter(\.passed).count
        var perCategory: [String: (passed: Int, total: Int)] = [:]
        for r in results {
            var entry = perCategory[r.category] ?? (passed: 0, total: 0)
            entry.total += 1
            if r.passed { entry.passed += 1 }
            perCategory[r.category] = entry
        }
        let routeOK = results.filter(\.routeOK).count
        let toolOK = results.filter(\.toolOK).count
        let containOK = results.filter(\.containmentOK).count
        return EvalReport(
            totalCases: total,
            passed: passed,
            failed: total - passed,
            totalLatencyMs: totalLatency,
            perCategory: perCategory,
            routeAccuracy: total > 0 ? Double(routeOK) / Double(total) : 0,
            toolAccuracy: total > 0 ? Double(toolOK) / Double(total) : 0,
            containmentAccuracy: total > 0 ? Double(containOK) / Double(total) : 0,
            results: results
        )
    }
}
