import Foundation

enum FinanceTools {
    static let stockPriceSpec = ToolSpec(
        name: "get_stock_price",
        description: "Get the current stock price and key financial data for a ticker symbol. Use this for any question about stock prices, market data, or company financials.",
        properties: ["ticker": .init(type: "string", description: "Stock ticker symbol (e.g., AMZN, AAPL, GOOGL, TSLA)")],
        required: ["ticker"]
    )

    static let stockHistorySpec = ToolSpec(
        name: "get_stock_history",
        description: "Get historical stock price data for a ticker. Use for price trends, performance over time, and YTD returns.",
        properties: [
            "ticker": .init(type: "string", description: "Stock ticker symbol"),
            "period": .init(type: "string", description: "Time period: 1d, 5d, 1mo, 3mo, 6mo, ytd, 1y, 5y. Use 'ytd' for year-to-date returns."),
        ],
        required: ["ticker"]
    )

    static let marketSummarySpec = ToolSpec(
        name: "get_market_summary",
        description: "Get a summary of major market indices (S&P 500, Nasdaq, Dow). Use for general market questions.",
        properties: [:]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(stockPriceSpec) { args in
            await getStockPrice(ticker: args["ticker"] as? String ?? "")
        }
        await registry.register(stockHistorySpec) { args in
            await getStockHistory(
                ticker: args["ticker"] as? String ?? "",
                period: args["period"] as? String ?? "1mo"
            )
        }
        await registry.register(marketSummarySpec) { _ in
            await getMarketSummary()
        }
    }

    // MARK: - Yahoo Finance via URL (no yfinance in Swift, use the JSON API)

    /// A parsed snapshot of a stock's current state. Pure data — no
    /// formatting, no IO — so the parsing logic is unit-testable against
    /// stubbed Yahoo JSON.
    ///
    /// We carry three independent "movement" signals so the formatter can
    /// always report SOMETHING concrete even when one source is unreliable:
    ///
    /// 1. **Day-over-day** (`change`/`changePct`): price vs yesterday's
    ///    close. The headline "is it up or down" number when prevClose is
    ///    trustworthy. Zero when prevClose isn't.
    /// 2. **Intraday** (`intradayChange`/`intradayChangePct`): price vs
    ///    today's open. Always available when the chart has a session bar.
    ///    This is what most people mean by "how's it doing today" anyway.
    /// 3. **Day range** (`dayRangePct`): (high - low) / low. A pure
    ///    volatility signal — proves the stock moved during the session
    ///    even if neither prev close nor open is reliable.
    struct StockSnapshot {
        let symbol: String
        let name: String
        let price: Double
        let prevClose: Double
        let dayOpen: Double
        let dayHigh: Double
        let dayLow: Double

        // Day-over-day (from yesterday's close)
        var change: Double { prevClose > 0 ? price - prevClose : 0 }
        var changePct: Double { prevClose > 0 ? (change / prevClose * 100) : 0 }

        // Intraday (from today's open)
        var intradayChange: Double { dayOpen > 0 ? price - dayOpen : 0 }
        var intradayChangePct: Double { dayOpen > 0 ? (intradayChange / dayOpen * 100) : 0 }

        // Day range volatility
        var dayRange: Double { (dayHigh > 0 && dayLow > 0) ? dayHigh - dayLow : 0 }
        var dayRangePct: Double { (dayHigh > 0 && dayLow > 0) ? (dayRange / dayLow * 100) : 0 }
    }

    /// Parse a Yahoo v8 chart response (with `interval=1d&range=5d` so the
    /// closes array contains yesterday's bar) into a snapshot.
    ///
    /// The previous-day close is read from `validCloses[count - 2]` — the
    /// second-to-last bar — instead of from `meta.chartPreviousClose`.
    /// `chartPreviousClose` is unreliable on intraday queries: it sometimes
    /// returns today's regular market open, which produces a +0.00% change
    /// when the user is asking what the stock did "today". Reading directly
    /// from the closes array is the only fix that's actually correct
    /// against today's session.
    static func parseStockSnapshot(json: [String: Any], symbol: String) -> StockSnapshot? {
        guard let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let result = results.first,
              let meta = result["meta"] as? [String: Any]
        else {
            return nil
        }

        let price = meta["regularMarketPrice"] as? Double ?? 0
        guard price > 0 else { return nil }

        let name = meta["shortName"] as? String ?? meta["symbol"] as? String ?? symbol
        let dayHigh = meta["regularMarketDayHigh"] as? Double ?? 0
        let dayLow = meta["regularMarketDayLow"] as? Double ?? 0

        // Today's open. Prefer meta.regularMarketOpen; fall back to the
        // open of the most recent bar in the indicators.quote.open array.
        // Always-available signal — the chart endpoint reliably reports
        // today's open even when previous-close fields are wonky.
        var dayOpen: Double = meta["regularMarketOpen"] as? Double ?? 0

        // Authoritative previous close: read the closes array from the chart
        // indicators. The last entry is today (or the most recent bar) and
        // the second-to-last is the previous trading day. This is the only
        // reliable way to get yesterday's close from the v8 chart endpoint.
        var prevClose: Double = 0
        if let indicators = result["indicators"] as? [String: Any],
           let quotes = (indicators["quote"] as? [[String: Any]])?.first {
            if let closes = quotes["close"] as? [Double?] {
                let validCloses = closes.compactMap { $0 }
                if validCloses.count >= 2 {
                    prevClose = validCloses[validCloses.count - 2]
                }
            }
            // Fallback path for dayOpen: last bar's open price.
            if dayOpen <= 0, let opens = quotes["open"] as? [Double?] {
                let validOpens = opens.compactMap { $0 }
                if let last = validOpens.last { dayOpen = last }
            }
        }

        // Fall back to meta fields only if the closes array was too short.
        // Prefer `previousClose` over `chartPreviousClose` because the
        // latter is the field that has the intraday-bug behavior.
        if prevClose <= 0 {
            prevClose = meta["previousClose"] as? Double
                     ?? meta["chartPreviousClose"] as? Double
                     ?? 0
        }

        // Final sanity check: if prevClose ended up exactly equal to price,
        // we're almost certainly looking at bad data (the chance of yesterday
        // closing at exactly today's current price to the cent is essentially
        // zero). Return prevClose = 0 so the formatter shows uncertainty
        // rather than a confident "+0.00%".
        if abs(prevClose - price) < 0.0001 {
            prevClose = 0
        }

        return StockSnapshot(
            symbol: symbol,
            name: name,
            price: price,
            prevClose: prevClose,
            dayOpen: dayOpen,
            dayHigh: dayHigh,
            dayLow: dayLow
        )
    }

    private static func getStockPrice(ticker: String) async -> String {
        let symbol = ticker.uppercased().trimmingCharacters(in: .whitespaces)
        guard !symbol.isEmpty else { return "Error: empty ticker" }

        // range=5d so the closes array contains yesterday's bar — needed
        // because chartPreviousClose is unreliable on intraday queries.
        // 5d covers weekends and at least one prior trading day reliably.
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=5d") else {
            return "Error: invalid ticker"
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return "Error fetching \(symbol): HTTP \(http.statusCode)"
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Error: malformed Yahoo response for \(symbol)"
            }
            guard let snapshot = parseStockSnapshot(json: json, symbol: symbol) else {
                return "Could not find data for: \(symbol)"
            }

            return GroundedResponse.format(
                source: "Yahoo Finance",
                body: formatStockSnapshot(snapshot)
            )

        } catch {
            return "Error fetching stock data: \(error.localizedDescription)"
        }
    }

    /// Format a `StockSnapshot` into the body string the model sees.
    ///
    /// Crucial design point: the formatter ALWAYS reports a concrete
    /// movement number for the session. The previous version emitted
    /// "Previous close: unavailable — change percent unknown" when
    /// yesterday's close was bad, and a small model interpreted that as
    /// "no change" / "essentially flat" and printed "+0.00%" or "stock
    /// was flat" — even when the day range was 4-5%. The fix: when
    /// day-over-day is unreliable, surface intraday change (vs today's
    /// open) and the day-range volatility instead, with explicit
    /// "session range:" labeling so the model has a number to quote.
    static func formatStockSnapshot(_ s: StockSnapshot) -> String {
        var lines: [String] = []
        lines.append("\(s.name) (\(s.symbol))")
        lines.append("Price: $\(String(format: "%.2f", s.price))")

        // Day-over-day, when reliable.
        if s.prevClose > 0 {
            let direction = s.change >= 0 ? "up" : "down"
            lines.append("Day-over-day vs previous close $\(String(format: "%.2f", s.prevClose)): \(direction) $\(String(format: "%.2f", abs(s.change))), \(String(format: "%+.2f", s.changePct))%")
        } else {
            lines.append("Day-over-day vs previous close: unavailable (yesterday's close could not be retrieved). Use the intraday and session-range numbers below for movement.")
        }

        // Intraday — always present when we have today's open.
        if s.dayOpen > 0 {
            let direction = s.intradayChange >= 0 ? "up" : "down"
            lines.append("Intraday vs today's open $\(String(format: "%.2f", s.dayOpen)): \(direction) $\(String(format: "%.2f", abs(s.intradayChange))), \(String(format: "%+.2f", s.intradayChangePct))%")
        }

        // Day range — pure volatility signal.
        if s.dayLow > 0 && s.dayHigh > 0 {
            lines.append("Session range: $\(String(format: "%.2f", s.dayLow)) - $\(String(format: "%.2f", s.dayHigh)) (\(String(format: "%.2f", s.dayRangePct))% spread, $\(String(format: "%.2f", s.dayRange)) absolute)")
        }

        // Anti-fabrication footer: this is the bug that produced the
        // "essentially flat" response. With non-zero range or non-zero
        // intraday change, the session is by definition NOT flat.
        if s.dayRangePct > 0.5 || abs(s.intradayChangePct) > 0.5 {
            lines.append("Note: this session is NOT flat — the range and/or intraday move are non-zero. Quote the numbers above; do not summarize as 'flat' or 'no change'.")
        }

        return lines.joined(separator: "\n")
    }

    /// A parsed historical-performance summary for a ticker over a period
    /// (1d, 5d, 1mo, ytd, 1y, etc.). Pure data — no formatting, no IO.
    struct StockHistorySummary {
        let symbol: String
        let period: String         // normalized period label
        let startPrice: Double
        let currentPrice: Double
        let high: Double
        let low: Double
        let tradingDays: Int

        var change: Double { currentPrice - startPrice }
        var changePct: Double { startPrice > 0 ? (change / startPrice * 100) : 0 }
    }

    /// Normalize a period string the way Yahoo expects ("year to date" →
    /// "ytd"). Public so the caller can use the same normalization that
    /// the parser will see.
    static func normalizeStockPeriod(_ period: String) -> String {
        let lower = period.lowercased().trimmingCharacters(in: .whitespaces)
        if lower == "ytd" || lower.contains("year to date") || lower.contains("year-to-date") {
            return "ytd"
        }
        return period
    }

    /// Parse a Yahoo v8 chart response for a historical-performance query
    /// into a StockHistorySummary. Pure function — testable against
    /// stubbed JSON without hitting the network.
    static func parseStockHistory(json: [String: Any], symbol: String, period: String) -> StockHistorySummary? {
        guard let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let result = results.first,
              let meta = result["meta"] as? [String: Any],
              let indicators = result["indicators"] as? [String: Any],
              let quotes = (indicators["quote"] as? [[String: Any]])?.first,
              let closes = quotes["close"] as? [Double?],
              let highs = quotes["high"] as? [Double?],
              let lows = quotes["low"] as? [Double?]
        else {
            return nil
        }

        let validCloses = closes.compactMap { $0 }
        guard !validCloses.isEmpty else { return nil }

        let currentPrice = meta["regularMarketPrice"] as? Double ?? validCloses.last ?? 0
        guard currentPrice > 0 else { return nil }

        // For YTD specifically: chartPreviousClose IS reliable here because
        // the chart's "previous close" is Dec 31 of last year, which is
        // exactly the YTD baseline we want. The intraday-bug pattern
        // doesn't apply to multi-day ranges.
        let startPrice: Double
        if period == "ytd" {
            startPrice = meta["chartPreviousClose"] as? Double ?? validCloses.first ?? 0
        } else {
            startPrice = validCloses.first ?? 0
        }

        let high = highs.compactMap { $0 }.max() ?? 0
        let low = lows.compactMap { $0 }.min() ?? 0

        return StockHistorySummary(
            symbol: symbol,
            period: period,
            startPrice: startPrice,
            currentPrice: currentPrice,
            high: high,
            low: low,
            tradingDays: validCloses.count
        )
    }

    /// Format a `StockHistorySummary` into the body string the model sees.
    static func formatStockHistory(_ h: StockHistorySummary) -> String {
        let periodLabel = h.period == "ytd" ? "year-to-date" : h.period
        return """
        \(h.symbol) — \(periodLabel) performance
        Start: $\(String(format: "%.2f", h.startPrice))
        Current: $\(String(format: "%.2f", h.currentPrice))
        Change: $\(String(format: "%+.2f", h.change)) (\(String(format: "%+.2f", h.changePct))%)
        Period high: $\(String(format: "%.2f", h.high))
        Period low: $\(String(format: "%.2f", h.low))
        Trading days: \(h.tradingDays)
        """
    }

    private static func getStockHistory(ticker: String, period: String) async -> String {
        let symbol = ticker.uppercased().trimmingCharacters(in: .whitespaces)
        let normalizedPeriod = normalizeStockPeriod(period)

        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=\(normalizedPeriod)") else {
            return "Error: invalid ticker"
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return "Error fetching \(symbol) history: HTTP \(http.statusCode)"
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Error: malformed Yahoo response for \(symbol)"
            }
            guard let summary = parseStockHistory(json: json, symbol: symbol, period: normalizedPeriod) else {
                return "No data for \(symbol) over \(normalizedPeriod)"
            }

            return GroundedResponse.format(source: "Yahoo Finance", body: formatStockHistory(summary))
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// One row of the market summary table.
    struct MarketIndexQuote {
        let displayName: String
        let symbol: String
        let price: Double
        let prevClose: Double

        var change: Double { price - prevClose }
        var changePct: Double { prevClose > 0 ? (change / prevClose * 100) : 0 }
    }

    /// Parse a Yahoo v8 chart response for a single market index. Reads
    /// previous-day close from the closes array (second-to-last bar) — same
    /// fix as parseStockSnapshot, since the chartPreviousClose intraday bug
    /// affects index queries too.
    static func parseMarketIndex(json: [String: Any], displayName: String, symbol: String) -> MarketIndexQuote? {
        guard let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let result = results.first,
              let meta = result["meta"] as? [String: Any]
        else {
            return nil
        }
        let price = meta["regularMarketPrice"] as? Double ?? 0
        guard price > 0 else { return nil }

        // Read prev close from the closes array, same logic as the snapshot
        // parser. Falls back to meta.previousClose then chartPreviousClose.
        var prevClose: Double = 0
        if let indicators = result["indicators"] as? [String: Any],
           let quotes = (indicators["quote"] as? [[String: Any]])?.first,
           let closes = quotes["close"] as? [Double?] {
            let valid = closes.compactMap { $0 }
            if valid.count >= 2 {
                prevClose = valid[valid.count - 2]
            }
        }
        if prevClose <= 0 {
            prevClose = meta["previousClose"] as? Double
                     ?? meta["chartPreviousClose"] as? Double
                     ?? 0
        }
        // Same sanity check: a price-equals-prevClose match is suspect.
        if abs(prevClose - price) < 0.0001 {
            prevClose = 0
        }

        return MarketIndexQuote(displayName: displayName, symbol: symbol, price: price, prevClose: prevClose)
    }

    /// Format a number with comma thousands separators and 2 decimal places.
    /// `String(format: "%,.2f", ...)` is NOT a valid Swift format — the
    /// `,` thousands flag is a GNU printf extension that Swift's
    /// `String(format:)` does not implement, and the previous code silently
    /// produced literal `,.2f` strings. This helper uses NumberFormatter
    /// for actual locale-correct grouping.
    static func formatGrouped(_ value: Double) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.groupingSeparator = ","
        nf.decimalSeparator = "."
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        nf.usesGroupingSeparator = true
        return nf.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// Format the market summary table from a list of parsed index quotes.
    static func formatMarketSummary(_ quotes: [(name: String, quote: MarketIndexQuote?)]) -> String {
        var lines: [String] = []
        for (name, quote) in quotes {
            guard let q = quote else {
                lines.append("  \(name): unavailable")
                continue
            }
            if q.prevClose > 0 {
                let sign = q.change >= 0 ? "+" : ""
                lines.append("  \(name): \(formatGrouped(q.price)) (\(sign)\(String(format: "%.2f", q.change)), \(sign)\(String(format: "%.2f", q.changePct))%)")
            } else {
                // Avoid the +0.00% fabrication path: if we can't compute a
                // change, just print the price and explicitly say so.
                lines.append("  \(name): \(formatGrouped(q.price)) (change unavailable for this session)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func getMarketSummary() async -> String {
        let indices = [
            ("S&P 500", "^GSPC"),
            ("Nasdaq", "^IXIC"),
            ("Dow Jones", "^DJI"),
        ]

        var quotes: [(name: String, quote: MarketIndexQuote?)] = []
        for (name, symbol) in indices {
            let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
            // range=5d so the closes array gives us yesterday's bar — same
            // reasoning as parseStockSnapshot.
            guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=5d") else {
                quotes.append((name, nil))
                continue
            }

            do {
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    quotes.append((name, nil))
                    continue
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    quotes.append((name, nil))
                    continue
                }
                quotes.append((name, parseMarketIndex(json: json, displayName: name, symbol: symbol)))
            } catch {
                quotes.append((name, nil))
            }
        }

        return GroundedResponse.format(
            source: "Yahoo Finance",
            body: formatMarketSummary(quotes)
        )
    }
}
