import XCTest
@testable import Macbot

/// Locks the contracts for the parsers extracted from FinanceTools and
/// WebTools during the parser sweep. Each of these used to be inline
/// inside an async function with no test coverage; the same shape
/// (fetch JSON or HTML, parse, format) was where the +0.00% bug, the
/// "essentially flat" bug, and the missing-fields bugs lived. Pulling
/// the parsers out and locking them with tests is the systemic fix.
final class ToolParserSweepTests: XCTestCase {

    // MARK: - FinanceTools.parseStockHistory

    func testHistoryParserHappyPath() throws {
        let json: [String: Any] = [
            "chart": [
                "result": [[
                    "meta": [
                        "regularMarketPrice": 233.65,
                        "chartPreviousClose": 200.00,  // Dec 31 baseline for ytd
                    ],
                    "indicators": [
                        "quote": [[
                            "close": [210.0, 215.0, 220.0, 233.65],
                            "high": [212.0, 218.0, 225.0, 234.0],
                            "low": [205.0, 213.0, 218.0, 223.0],
                        ]],
                    ],
                ]],
            ],
        ]
        let h = try XCTUnwrap(FinanceTools.parseStockHistory(json: json, symbol: "AMZN", period: "ytd"))
        XCTAssertEqual(h.symbol, "AMZN")
        XCTAssertEqual(h.period, "ytd")
        XCTAssertEqual(h.startPrice, 200.00, accuracy: 0.001)
        XCTAssertEqual(h.currentPrice, 233.65, accuracy: 0.001)
        XCTAssertEqual(h.high, 234.0, accuracy: 0.001)
        XCTAssertEqual(h.low, 205.0, accuracy: 0.001)
        XCTAssertEqual(h.tradingDays, 4)
        XCTAssertEqual(h.changePct, 16.825, accuracy: 0.01)
    }

    func testHistoryParserNonYTDPeriodUsesFirstClose() throws {
        // For non-ytd ranges (1mo, 5d, etc.), the start price is the first
        // close in the array, NOT chartPreviousClose.
        let json: [String: Any] = [
            "chart": [
                "result": [[
                    "meta": [
                        "regularMarketPrice": 110.0,
                        "chartPreviousClose": 50.0,  // ignored for non-ytd
                    ],
                    "indicators": [
                        "quote": [[
                            "close": [100.0, 105.0, 110.0],
                            "high": [101.0, 106.0, 111.0],
                            "low": [99.0, 104.0, 109.0],
                        ]],
                    ],
                ]],
            ],
        ]
        let h = try XCTUnwrap(FinanceTools.parseStockHistory(json: json, symbol: "TEST", period: "1mo"))
        XCTAssertEqual(h.startPrice, 100.0, accuracy: 0.001)
        XCTAssertEqual(h.currentPrice, 110.0, accuracy: 0.001)
        XCTAssertEqual(h.changePct, 10.0, accuracy: 0.01)
    }

    func testHistoryParserReturnsNilForEmptyCloses() {
        let json: [String: Any] = [
            "chart": [
                "result": [[
                    "meta": ["regularMarketPrice": 100.0],
                    "indicators": [
                        "quote": [[
                            "close": [Any](),
                            "high": [Any](),
                            "low": [Any](),
                        ]],
                    ],
                ]],
            ],
        ]
        XCTAssertNil(FinanceTools.parseStockHistory(json: json, symbol: "X", period: "1d"))
    }

    func testNormalizeStockPeriod() {
        XCTAssertEqual(FinanceTools.normalizeStockPeriod("ytd"), "ytd")
        XCTAssertEqual(FinanceTools.normalizeStockPeriod("YTD"), "ytd")
        XCTAssertEqual(FinanceTools.normalizeStockPeriod("year to date"), "ytd")
        XCTAssertEqual(FinanceTools.normalizeStockPeriod("year-to-date"), "ytd")
        XCTAssertEqual(FinanceTools.normalizeStockPeriod("1mo"), "1mo")
        XCTAssertEqual(FinanceTools.normalizeStockPeriod("5d"), "5d")
    }

    // MARK: - FinanceTools.parseMarketIndex

    func testMarketIndexParserUsesClosesArrayNotChartPreviousClose() throws {
        // Same intraday-bug pattern as parseStockSnapshot. Yahoo's
        // chartPreviousClose for an index can equal regularMarketPrice
        // when intraday data is partial. The parser must use the
        // second-to-last bar from the closes array instead.
        let json: [String: Any] = [
            "chart": [
                "result": [[
                    "meta": [
                        "regularMarketPrice": 5800.0,
                        "chartPreviousClose": 5800.0,  // bad
                    ],
                    "indicators": [
                        "quote": [[
                            "close": [5750.0, 5800.0],  // [yesterday, today]
                        ]],
                    ],
                ]],
            ],
        ]
        let q = try XCTUnwrap(FinanceTools.parseMarketIndex(json: json, displayName: "S&P 500", symbol: "^GSPC"))
        XCTAssertEqual(q.price, 5800.0, accuracy: 0.001)
        XCTAssertEqual(q.prevClose, 5750.0, accuracy: 0.001)
        XCTAssertEqual(q.change, 50.0, accuracy: 0.001)
    }

    func testMarketIndexParserZeroesOutMatchingPrevClose() throws {
        // Final sanity guard: if every fallback gives prevClose == price,
        // mark it as unknown so the formatter doesn't print +0.00%.
        let json: [String: Any] = [
            "chart": [
                "result": [[
                    "meta": [
                        "regularMarketPrice": 5800.0,
                        "previousClose": 5800.0,
                        "chartPreviousClose": 5800.0,
                    ],
                    "indicators": [
                        "quote": [[
                            "close": [5800.0, 5800.0],
                        ]],
                    ],
                ]],
            ],
        ]
        let q = try XCTUnwrap(FinanceTools.parseMarketIndex(json: json, displayName: "S&P 500", symbol: "^GSPC"))
        XCTAssertEqual(q.prevClose, 0)
        XCTAssertEqual(q.changePct, 0)
    }

    func testMarketSummaryFormatterAvoidsZeroChangeFabrication() {
        // When prevClose is 0 (unknown), the formatter must NOT print
        // a confident "+0.00%" — that's the bug class. Instead it
        // surfaces "change unavailable for this session".
        let quotes: [(name: String, quote: FinanceTools.MarketIndexQuote?)] = [
            (
                "S&P 500",
                FinanceTools.MarketIndexQuote(
                    displayName: "S&P 500",
                    symbol: "^GSPC",
                    price: 5800.0,
                    prevClose: 0
                )
            ),
        ]
        let body = FinanceTools.formatMarketSummary(quotes)
        XCTAssertTrue(body.contains("5,800.00"))
        XCTAssertTrue(body.contains("change unavailable"))
        XCTAssertFalse(body.contains("+0.00%"),
                       "must not print +0.00% when prev close is unknown")
    }

    // MARK: - WebTools.parseDDGResults

    func testDDGParserExtractsTitleSnippetURL() {
        // Synthetic DDG HTML in the same shape the live site emits.
        let html = """
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Ffoo&rut=abc">Example Title</a>
        <span class="result__snippet">An example snippet for testing.</span>
        """
        let results = WebTools.parseDDGResults(html: html)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Example Title")
        XCTAssertEqual(results[0].snippet, "An example snippet for testing.")
        XCTAssertEqual(results[0].url, "https://example.com/foo")
    }

    func testDDGParserStripsInlineHTMLFromSnippet() {
        let html = """
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.test">A title with <b>bold</b></a>
        <span class="result__snippet">Has <em>italic</em> markup</span>
        """
        let results = WebTools.parseDDGResults(html: html)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "A title with bold")
        XCTAssertEqual(results[0].snippet, "Has italic markup")
    }

    func testDDGParserHandlesMultipleResultsAndLimit() {
        var html = ""
        for i in 1...5 {
            html += """
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fa\(i).test">Title \(i)</a>
            <span class="result__snippet">Snippet \(i).</span>

            """
        }
        let results = WebTools.parseDDGResults(html: html, limit: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].title, "Title 1")
        XCTAssertEqual(results[2].title, "Title 3")
    }

    func testDDGUnwrapHandlesNoRedirect() {
        XCTAssertEqual(WebTools.unwrapDDGRedirect("https://example.com/foo"), "https://example.com/foo")
    }

    func testDDGUnwrapHandlesUddgWithoutAmpersand() {
        let href = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fbar"
        XCTAssertEqual(WebTools.unwrapDDGRedirect(href), "https://example.com/bar")
    }

    func testDDGParserReturnsEmptyForNoMatches() {
        XCTAssertEqual(WebTools.parseDDGResults(html: "<div>nothing here</div>").count, 0)
    }

    // MARK: - WebTools.stripHTML

    func testStripHTMLRemovesScriptsStylesAndTags() {
        let raw = """
        <html>
        <head>
            <style>body { color: red; }</style>
            <script>alert('xss')</script>
        </head>
        <body>
            <h1>Title</h1>
            <p>Content paragraph.</p>
        </body>
        </html>
        """
        let cleaned = WebTools.stripHTML(raw)
        XCTAssertFalse(cleaned.contains("alert"))
        XCTAssertFalse(cleaned.contains("color: red"))
        XCTAssertFalse(cleaned.contains("<"))
        XCTAssertTrue(cleaned.contains("Title"))
        XCTAssertTrue(cleaned.contains("Content paragraph"))
    }

    func testStripHTMLCollapsesWhitespace() {
        let raw = "<p>one</p>\n\n\n<p>two</p>     <p>three</p>"
        let cleaned = WebTools.stripHTML(raw)
        XCTAssertFalse(cleaned.contains("\n\n"))
        XCTAssertFalse(cleaned.contains("    "))
    }

    func testStripHTMLTruncatesAtMaxChars() {
        let raw = String(repeating: "a", count: 10_000)
        let cleaned = WebTools.stripHTML(raw, maxChars: 100)
        XCTAssertTrue(cleaned.hasSuffix("(truncated)"))
        XCTAssertLessThan(cleaned.count, 10_000)
    }
}
