import Foundation

/// Wraps a tool's textual output with a consistent "single source of truth"
/// header so the LLM is steered to quote it verbatim instead of paraphrasing
/// or fabricating numbers.
///
/// This is the textual analogue of the `STATS:{json}` pattern used by
/// ChartTools — both establish that what's between the markers is
/// authoritative and not to be embellished. Empirical observation: small
/// models follow this preamble much more reliably than vague guidance like
/// "be accurate" because the phrasing is a syntactic forcing function.
enum GroundedResponse {

    /// Format options for the timestamp.
    enum TimePolicy {
        /// No timestamp (use for stable lookups like math results).
        case none
        /// ISO-8601 UTC timestamp suffix (use for time-sensitive data).
        case utc
    }

    /// Wraps `body` in a grounded-response envelope.
    ///
    /// - Parameters:
    ///   - source: Where the data came from. Becomes part of the "from <source>" line.
    ///     Examples: "Yahoo Finance", "DuckDuckGo", "wttr.in".
    ///   - timePolicy: Whether and how to add a freshness timestamp.
    ///   - body: The actual tool data, already formatted as the model should
    ///     see it. Numbers, names, prices — whatever is authoritative.
    ///   - now: Injectable clock for tests. Defaults to `Date()`.
    ///
    /// The result has a stable shape:
    ///
    /// ```
    /// Data from <source>[ at <ISO timestamp>] (use these exact values in your response):
    /// <body>
    /// ```
    static func format(
        source: String,
        timePolicy: TimePolicy = .utc,
        body: String,
        now: Date = Date()
    ) -> String {
        var header = "Data from \(source)"
        switch timePolicy {
        case .none:
            break
        case .utc:
            header += " at \(isoTimestamp(now))"
        }
        header += " (use these exact values in your response):"
        return "\(header)\n\(body)"
    }

    /// Wraps a search-style result list. Each entry's source URL is included
    /// inline next to its content so the model cannot fabricate a URL when
    /// citing — it can only copy one that's already in its context.
    ///
    /// - Parameters:
    ///   - source: The search engine name (e.g. "DuckDuckGo").
    ///   - query: The query that produced these results, echoed back so the
    ///     model knows what was actually asked.
    ///   - body: The pre-formatted result list. Each entry should already
    ///     include its URL inline.
    static func searchResults(
        source: String,
        query: String,
        body: String,
        now: Date = Date()
    ) -> String {
        let header = "Search results from \(source) for query: \"\(query)\" at \(isoTimestamp(now)).\n" +
                     "Only cite facts that appear in the snippets below. Only cite URLs that appear below — do not invent URLs."
        return "\(header)\n\n\(body)"
    }

    /// ISO-8601 UTC timestamp formatter (cached). Stable across the app.
    static func isoTimestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    // `nonisolated(unsafe)`: `ISO8601DateFormatter` is documented as
    // thread-safe in modern Foundation (its `string(from:)` / `date(from:)`
    // methods may be called from any thread), and this instance is fully
    // configured at initialisation and never mutated afterwards. The
    // declaration is a `let`, so all access is read-only. This is the
    // pragmatic escape hatch called out in the Wave 2B instructions for
    // immutable-after-init formatters.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
