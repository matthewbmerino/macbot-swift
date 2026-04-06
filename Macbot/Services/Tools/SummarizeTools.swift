import Foundation

enum SummarizeTools {

    static let summarizeURLSpec = ToolSpec(
        name: "summarize_url",
        description: "Fetch a web page and return a structured, intelligent extraction of its content — title, key headings, and main text. Much better than fetch_page for long articles, docs, or blog posts. Use this when the user wants to understand what a page says.",
        properties: [
            "url": .init(type: "string", description: "URL to summarize"),
            "max_length": .init(type: "string", description: "Max characters to return (default: 12000)"),
        ],
        required: ["url"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(summarizeURLSpec) { args in
            await summarizeURL(
                url: args["url"] as? String ?? "",
                maxLength: Int(args["max_length"] as? String ?? "") ?? 12000
            )
        }
    }

    // MARK: - Smart Page Extraction

    static func summarizeURL(url urlString: String, maxLength: Int) async -> String {
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
            return "Error: URL must start with http:// or https://"
        }
        guard let url = URL(string: urlString) else { return "Error: invalid URL" }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20

            let (data, _) = try await URLSession.shared.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""

            guard !html.isEmpty else { return "Error: empty page" }

            // Use Python + BeautifulSoup for intelligent extraction
            let code = buildExtractionScript(html: html, maxLength: maxLength, url: urlString)
            let result = await ExecutorTools.runPython(code: code)

            if result.hasPrefix("Error:") || result.hasPrefix("STDERR:") {
                // Fallback: basic Swift extraction
                return fallbackExtract(html: html, maxLength: maxLength, url: urlString)
            }

            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Failed to fetch: \(error.localizedDescription)"
        }
    }

    private static func buildExtractionScript(html: String, maxLength: Int, url: String) -> String {
        // Write HTML to temp file to avoid string escaping issues
        let tmpPath = NSTemporaryDirectory() + "macbot_summarize_\(UUID().uuidString).html"
        try? html.write(toFile: tmpPath, atomically: true, encoding: .utf8)

        return """
        from bs4 import BeautifulSoup
        import re

        with open('\(tmpPath)', 'r', encoding='utf-8', errors='ignore') as f:
            html = f.read()

        import os
        os.remove('\(tmpPath)')

        soup = BeautifulSoup(html, 'html.parser')

        # Remove noise
        for tag in soup(['script', 'style', 'nav', 'footer', 'header', 'aside', 'iframe', 'noscript', 'form']):
            tag.decompose()

        # Extract title
        title = ''
        if soup.title:
            title = soup.title.get_text(strip=True)
        elif soup.find('h1'):
            title = soup.find('h1').get_text(strip=True)

        # Extract meta description
        meta_desc = ''
        meta = soup.find('meta', attrs={'name': 'description'})
        if meta and meta.get('content'):
            meta_desc = meta['content'].strip()

        # Extract headings with their content
        sections = []
        current_heading = None
        current_content = []

        # Try article/main first
        main = soup.find('article') or soup.find('main') or soup.find('div', class_=re.compile('content|article|post|entry'))
        body = main if main else soup.body or soup

        for element in body.find_all(['h1', 'h2', 'h3', 'h4', 'p', 'li', 'blockquote', 'pre', 'td']):
            text = element.get_text(strip=True)
            if not text or len(text) < 3:
                continue

            if element.name in ('h1', 'h2', 'h3', 'h4'):
                if current_heading or current_content:
                    sections.append((current_heading, '\\n'.join(current_content)))
                current_heading = f"## {text}"
                current_content = []
            else:
                # Skip very short fragments (nav items, buttons)
                if len(text) > 20 or element.name in ('pre', 'blockquote'):
                    current_content.append(text)

        if current_heading or current_content:
            sections.append((current_heading, '\\n'.join(current_content)))

        # Build output
        parts = []
        if title:
            parts.append(f"# {title}")
        if meta_desc:
            parts.append(f"> {meta_desc}")
        parts.append(f"Source: \(url)")
        parts.append("")

        char_count = sum(len(p) for p in parts)
        max_len = \(maxLength)

        for heading, content in sections:
            section_text = ""
            if heading:
                section_text += heading + "\\n"
            if content:
                section_text += content + "\\n"

            if char_count + len(section_text) > max_len:
                remaining = max_len - char_count - 20
                if remaining > 100:
                    parts.append(section_text[:remaining] + "\\n... (truncated)")
                break
            parts.append(section_text)
            char_count += len(section_text)

        output = '\\n'.join(parts)
        if not output.strip():
            # Fallback: just get all text
            text = soup.get_text(separator='\\n', strip=True)
            output = f"# {title}\\n\\n{text[:max_len]}"

        print(output)
        """
    }

    private static func fallbackExtract(html: String, maxLength: Int, url: String) -> String {
        var text = html

        // Strip scripts and styles
        let patterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<nav[^>]*>[\\s\\S]*?</nav>",
            "<footer[^>]*>[\\s\\S]*?</footer>",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
        }

        // Extract title
        var title = ""
        if let titleRegex = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: .dotMatchesLineSeparators),
           let match = titleRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            title = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip remaining tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\\n\\s*\\n\\s*", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = ""
        if !title.isEmpty { result += "# \(title)\n\n" }
        result += "Source: \(url)\n\n"

        let remaining = maxLength - result.count
        if text.count > remaining {
            result += String(text.prefix(remaining)) + "\n... (truncated)"
        } else {
            result += text
        }

        return result
    }
}
