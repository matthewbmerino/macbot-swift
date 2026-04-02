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

            // Parse DuckDuckGo HTML results
            let pattern = #"class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>.*?class="result__snippet"[^>]*>(.*?)</span"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
                return "No results found for: \(query)"
            }

            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, range: range)

            var results: [String] = []
            for match in matches.prefix(8) {
                let href = String(html[Range(match.range(at: 1), in: html)!])
                var title = String(html[Range(match.range(at: 2), in: html)!])
                var snippet = String(html[Range(match.range(at: 3), in: html)!])

                // Strip HTML tags
                title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                snippet = snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

                // Unwrap DuckDuckGo redirect URL
                var finalURL = href
                if href.contains("uddg="),
                   let uddgRange = href.range(of: "uddg="),
                   let ampRange = href[uddgRange.upperBound...].range(of: "&") {
                    let encoded = String(href[uddgRange.upperBound..<ampRange.lowerBound])
                    finalURL = encoded.removingPercentEncoding ?? encoded
                } else if href.contains("uddg=") {
                    let encoded = String(href[href.range(of: "uddg=")!.upperBound...])
                    finalURL = encoded.removingPercentEncoding ?? encoded
                }

                results.append("[\(title.trimmingCharacters(in: .whitespaces))]\n\(snippet.trimmingCharacters(in: .whitespaces))\n\(finalURL)")
            }

            return results.isEmpty ? "No results found for: \(query)" : results.joined(separator: "\n\n")
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
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
            var text = String(data: data, encoding: .utf8) ?? ""

            // Strip scripts, styles, and HTML tags
            if let scriptRegex = try? NSRegularExpression(pattern: "<script[^>]*>[\\s\\S]*?</script>", options: .dotMatchesLineSeparators) {
                text = scriptRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
            if let styleRegex = try? NSRegularExpression(pattern: "<style[^>]*>[\\s\\S]*?</style>", options: .dotMatchesLineSeparators) {
                text = styleRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
            text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)

            if text.count > 8000 {
                text = String(text.prefix(8000)) + "\n... (truncated)"
            }

            return text.isEmpty ? "(empty page)" : text
        } catch {
            return "Failed to fetch page: \(error.localizedDescription)"
        }
    }
}
