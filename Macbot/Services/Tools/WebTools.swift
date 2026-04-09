import Foundation

enum WebTools {
    static let searchSpec = ToolSpec(
        name: "web_search",
        description: "Search the web using DuckDuckGo. Use for current events, facts, or anything you don't know.",
        properties: ["query": .init(type: "string", description: "Search query")],
        required: ["query"]
    )

    static let fetchSpec = ToolSpec(
        name: "fetch_page",
        description: "Fetch a web page and return its text content (HTML stripped).",
        properties: ["url": .init(type: "string", description: "URL to fetch")],
        required: ["url"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(searchSpec) { args in
            let query = args["query"] as? String ?? ""
            return await webSearch(query: query)
        }
        await registry.register(fetchSpec) { args in
            let url = args["url"] as? String ?? ""
            return await fetchPage(url: url)
        }
    }

    /// One DuckDuckGo HTML result. Pure data — no formatting, no IO. The
    /// parser is unit-testable against stubbed HTML.
    struct DDGResult: Equatable {
        let title: String
        let snippet: String
        let url: String
    }

    /// Parse DuckDuckGo HTML results from a search response. Extracted into
    /// a pure function so the regex + URL-unwrapping logic can be locked
    /// against fixture HTML without hitting the network.
    static func parseDDGResults(html: String, limit: Int = 8) -> [DDGResult] {
        let pattern = #"class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>.*?class="result__snippet"[^>]*>(.*?)</span"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)

        var results: [DDGResult] = []
        for match in matches.prefix(limit) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let snippetRange = Range(match.range(at: 3), in: html)
            else { continue }
            let href = String(html[hrefRange])
            var title = String(html[titleRange])
            var snippet = String(html[snippetRange])
            title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            snippet = snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            results.append(DDGResult(
                title: title.trimmingCharacters(in: .whitespaces),
                snippet: snippet.trimmingCharacters(in: .whitespaces),
                url: unwrapDDGRedirect(href)
            ))
        }
        return results
    }

    /// DuckDuckGo wraps result URLs in a redirect of the form
    /// `//duckduckgo.com/l/?uddg=<encoded>&...`. Strip the wrapper and
    /// percent-decode so the model sees the real URL.
    static func unwrapDDGRedirect(_ href: String) -> String {
        guard href.contains("uddg="),
              let uddgRange = href.range(of: "uddg=")
        else { return href }
        let tail = href[uddgRange.upperBound...]
        let encoded: String
        if let ampRange = tail.range(of: "&") {
            encoded = String(tail[..<ampRange.lowerBound])
        } else {
            encoded = String(tail)
        }
        return encoded.removingPercentEncoding ?? encoded
    }

    static func formatDDGResults(_ results: [DDGResult]) -> String {
        results.map { "[\($0.title)]\n\($0.snippet)\n\($0.url)" }.joined(separator: "\n\n")
    }

    static func webSearch(query: String) async -> String {
        guard !query.isEmpty else { return "Error: empty query" }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return "Error: invalid query"
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, _) = try await URLSession.shared.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""
            let results = parseDDGResults(html: html)

            if results.isEmpty {
                return "No results found for: \(query)"
            }
            return GroundedResponse.searchResults(
                source: "DuckDuckGo",
                query: query,
                body: formatDDGResults(results)
            )
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }

    /// Strip HTML markup from a page body and collapse whitespace. Pure
    /// function — testable against fixture HTML without hitting the net.
    /// Returns text truncated to `maxChars` with a `... (truncated)` suffix.
    static func stripHTML(_ raw: String, maxChars: Int = 8000) -> String {
        var text = raw
        if let scriptRegex = try? NSRegularExpression(pattern: "<script[^>]*>[\\s\\S]*?</script>", options: .dotMatchesLineSeparators) {
            text = scriptRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        if let styleRegex = try? NSRegularExpression(pattern: "<style[^>]*>[\\s\\S]*?</style>", options: .dotMatchesLineSeparators) {
            text = styleRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if text.count > maxChars {
            text = String(text.prefix(maxChars)) + "\n... (truncated)"
        }
        return text
    }

    static func fetchPage(url urlString: String) async -> String {
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
            return "Error: URL must start with http:// or https://"
        }
        guard let url = URL(string: urlString) else { return "Error: invalid URL" }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, _) = try await URLSession.shared.data(for: request)
            let raw = String(data: data, encoding: .utf8) ?? ""
            let text = stripHTML(raw)

            if text.isEmpty {
                return "(empty page) — \(urlString)"
            }
            // Echo the source URL inline so the model cannot fabricate one
            // when quoting from this page later in its response.
            return GroundedResponse.format(
                source: "URL \(urlString)",
                body: text
            )
        } catch {
            return "Failed to fetch page: \(error.localizedDescription)"
        }
    }
}
