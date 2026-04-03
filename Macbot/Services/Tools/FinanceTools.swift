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

    private static func getStockPrice(ticker: String) async -> String {
        let symbol = ticker.uppercased().trimmingCharacters(in: .whitespaces)
        guard !symbol.isEmpty else { return "Error: empty ticker" }

        // Use Yahoo Finance v8 quote API
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=1d") else {
            return "Error: invalid ticker"
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let chart = json?["chart"] as? [String: Any],
                  let results = chart["result"] as? [[String: Any]],
                  let result = results.first,
                  let meta = result["meta"] as? [String: Any]
            else {
                return "Could not find data for: \(symbol)"
            }

            let price = meta["regularMarketPrice"] as? Double ?? 0
            let prevClose = meta["chartPreviousClose"] as? Double ?? meta["previousClose"] as? Double ?? 0
            let change = price - prevClose
            let changePct = prevClose > 0 ? (change / prevClose * 100) : 0
            let name = meta["shortName"] as? String ?? meta["symbol"] as? String ?? symbol
            let dayHigh = meta["regularMarketDayHigh"] as? Double ?? 0
            let dayLow = meta["regularMarketDayLow"] as? Double ?? 0

            let direction = change >= 0 ? "up" : "down"

            var result_str = """
            \(name) (\(symbol))
            Price: $\(String(format: "%.2f", price)) (\(direction) $\(String(format: "%.2f", abs(change))), \(String(format: "%+.2f", changePct))%)
            """

            if dayLow > 0 && dayHigh > 0 {
                result_str += "\nDay Range: $\(String(format: "%.2f", dayLow)) - $\(String(format: "%.2f", dayHigh))"
            }

            return result_str

        } catch {
            return "Error fetching stock data: \(error.localizedDescription)"
        }
    }

    private static func getStockHistory(ticker: String, period: String) async -> String {
        let symbol = ticker.uppercased().trimmingCharacters(in: .whitespaces)

        // Normalize period: handle "year to date", "year-to-date", etc.
        let normalizedPeriod: String
        let lowerPeriod = period.lowercased().trimmingCharacters(in: .whitespaces)
        if lowerPeriod == "ytd" || lowerPeriod.contains("year to date") || lowerPeriod.contains("year-to-date") {
            normalizedPeriod = "ytd"
        } else {
            normalizedPeriod = period
        }

        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=\(normalizedPeriod)") else {
            return "Error: invalid ticker"
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let chart = json?["chart"] as? [String: Any],
                  let results = chart["result"] as? [[String: Any]],
                  let result = results.first,
                  let meta = result["meta"] as? [String: Any],
                  let indicators = result["indicators"] as? [String: Any],
                  let quotes = (indicators["quote"] as? [[String: Any]])?.first,
                  let closes = quotes["close"] as? [Double?],
                  let highs = quotes["high"] as? [Double?],
                  let lows = quotes["low"] as? [Double?]
            else {
                return "No data for \(symbol) over \(normalizedPeriod)"
            }

            let validCloses = closes.compactMap { $0 }
            guard !validCloses.isEmpty else {
                return "No data for \(symbol)"
            }

            let currentPrice = meta["regularMarketPrice"] as? Double ?? validCloses.last ?? 0

            // For YTD: use chartPreviousClose (Dec 31 close) as the starting price
            // For other periods: use the first close in the range
            let startPrice: Double
            if normalizedPeriod == "ytd" {
                startPrice = meta["chartPreviousClose"] as? Double ?? validCloses.first ?? 0
            } else {
                startPrice = validCloses.first ?? 0
            }

            let high = highs.compactMap { $0 }.max() ?? 0
            let low = lows.compactMap { $0 }.min() ?? 0
            let change = currentPrice - startPrice
            let changePct = startPrice > 0 ? (change / startPrice * 100) : 0

            let periodLabel = normalizedPeriod == "ytd" ? "year-to-date" : normalizedPeriod

            return """
            \(symbol) — \(periodLabel) performance
            Start: $\(String(format: "%.2f", startPrice))
            Current: $\(String(format: "%.2f", currentPrice))
            Change: $\(String(format: "%+.2f", change)) (\(String(format: "%+.2f", changePct))%)
            Period High: $\(String(format: "%.2f", high))
            Period Low: $\(String(format: "%.2f", low))
            Trading Days: \(validCloses.count)
            """

        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private static func getMarketSummary() async -> String {
        let indices = [
            ("S&P 500", "^GSPC"),
            ("Nasdaq", "^IXIC"),
            ("Dow Jones", "^DJI"),
        ]

        var lines = ["Market Summary"]
        for (name, symbol) in indices {
            let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
            guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=1d") else {
                lines.append("  \(name): unavailable")
                continue
            }

            do {
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10

                let (data, _) = try await URLSession.shared.data(for: request)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                if let chart = json?["chart"] as? [String: Any],
                   let results = chart["result"] as? [[String: Any]],
                   let meta = results.first?["meta"] as? [String: Any] {
                    let price = meta["regularMarketPrice"] as? Double ?? 0
                    let prev = meta["chartPreviousClose"] as? Double ?? 0
                    let change = price - prev
                    let pct = prev > 0 ? (change / prev * 100) : 0
                    let sign = change >= 0 ? "+" : ""
                    lines.append("  \(name): \(String(format: "%,.2f", price)) (\(sign)\(String(format: "%.2f", change)), \(sign)\(String(format: "%.2f", pct))%)")
                } else {
                    lines.append("  \(name): unavailable")
                }
            } catch {
                lines.append("  \(name): unavailable")
            }
        }

        return lines.joined(separator: "\n")
    }
}
