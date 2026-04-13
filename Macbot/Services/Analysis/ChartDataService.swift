import Foundation

// MARK: - Chart Data Models
// OHLCV, PricePoint, StbrBar, and ChartType are defined in
// FinancialChartView.swift (the WKWebView chart component).
// This service produces data in those formats.

/// Comprehensive technical signal report for a symbol.
struct SignalReport: Sendable {
    let symbol: String
    let price: Double
    let rsi: Double
    let stbr: Double
    let stbrRiskLevel: String
    let stbrColor: String
    let macdHistogram: Double
    let compositeScore: Double
    let compositeLabel: String  // BUY/NEUTRAL/SELL
    let sma50: Double?
    let sma200: Double?
    let bollingerPercentB: Double?
}

// MARK: - Chart Data Service

/// Fetches price history from Yahoo Finance and prepares chart-ready data.
/// Reuses the same Yahoo v8 chart API that FinanceTools uses.
enum ChartDataService {

    // MARK: - Date Formatting

    /// ISO-style date string for chart display (YYYY-MM-DD).
    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        return fmt
    }()

    private static func dateString(from timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp))
        return dateFormatter.string(from: date)
    }

    // MARK: - Yahoo Finance Fetcher (shared infrastructure)

    /// Fetch raw Yahoo v8 chart JSON for a symbol and period.
    /// Reuses the same URL pattern and headers as FinanceTools.
    private static func fetchYahooChart(symbol: String, period: String, interval: String = "1d") async throws -> [String: Any] {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=\(interval)&range=\(period)") else {
            throw ChartDataError.invalidSymbol(symbol)
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ChartDataError.httpError(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChartDataError.malformedResponse
        }
        return json
    }

    /// Extract the chart result dict from Yahoo JSON.
    private static func extractResult(from json: [String: Any]) throws -> [String: Any] {
        guard let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let result = results.first else {
            throw ChartDataError.noData
        }
        return result
    }

    // MARK: - Public API

    /// Fetch OHLCV data for a symbol from Yahoo Finance and return it in chart-ready format.
    static func fetchOHLCV(symbol: String, period: String = "1y") async throws -> [OHLCV] {
        let sym = symbol.uppercased().trimmingCharacters(in: .whitespaces)
        guard !sym.isEmpty else { throw ChartDataError.invalidSymbol(symbol) }

        let json = try await fetchYahooChart(symbol: sym, period: period)
        let result = try extractResult(from: json)

        guard let timestamps = result["timestamp"] as? [Int],
              let indicators = result["indicators"] as? [String: Any],
              let quotes = (indicators["quote"] as? [[String: Any]])?.first,
              let opens = quotes["open"] as? [Double?],
              let highs = quotes["high"] as? [Double?],
              let lows = quotes["low"] as? [Double?],
              let closes = quotes["close"] as? [Double?],
              let volumes = quotes["volume"] as? [Double?]
        else {
            throw ChartDataError.noData
        }

        var bars: [OHLCV] = []
        bars.reserveCapacity(timestamps.count)

        for i in 0 ..< timestamps.count {
            guard let o = opens[safe: i] ?? nil,
                  let h = highs[safe: i] ?? nil,
                  let l = lows[safe: i] ?? nil,
                  let c = closes[safe: i] ?? nil else { continue }
            let v = (volumes[safe: i] ?? nil) ?? 0
            let ds = dateString(from: timestamps[i])
            bars.append(OHLCV(date: ds, open: o, high: h, low: l, close: c, volume: v))
        }

        guard !bars.isEmpty else { throw ChartDataError.noData }
        return bars
    }

    /// Fetch and compute STBR series for a symbol.
    /// STBR = Standard Deviation to Bollinger Band Ratio — a risk/volatility metric.
    static func fetchStbrData(symbol: String) async throws -> (prices: [PricePoint], stbr: [StbrBar]) {
        let bars = try await fetchOHLCV(symbol: symbol, period: "1y")
        let closes = bars.map(\.close)

        // Compute Bollinger Bands
        let bb = TechnicalIndicators.bollingerBands(closes, period: 20, stdDev: 2.0)
        let hvol = TechnicalIndicators.historicalVolatility(closes, period: 30) ?? 0.2

        // STBR: ratio of current price position within Bollinger Bands
        // normalized by historical volatility
        var prices: [PricePoint] = []
        var stbrBars: [StbrBar] = []

        for i in 0 ..< bars.count {
            prices.append(PricePoint(date: bars[i].date, value: bars[i].close))

            guard let upper = bb.upper[i], let lower = bb.lower[i], let middle = bb.middle[i] else {
                continue
            }

            let bandwidth = upper - lower
            guard bandwidth > 0 else { continue }

            // STBR value: distance from middle as ratio of bandwidth, scaled by vol
            let deviation = abs(closes[i] - middle) / bandwidth
            let stbrValue = deviation * (hvol * 100)

            // Color based on risk level
            let color: String
            if stbrValue < 0.5 {
                color = "#22c55e"   // green
            } else if stbrValue < 1.0 {
                color = "#eab308"   // yellow
            } else if stbrValue < 1.5 {
                color = "#f97316"   // orange
            } else {
                color = "#ef4444"   // red
            }

            stbrBars.append(StbrBar(date: bars[i].date, value: stbrValue, color: color))
        }

        return (prices, stbrBars)
    }

    /// Compute technical signals for a symbol.
    static func fetchSignals(symbol: String) async throws -> SignalReport {
        let sym = symbol.uppercased().trimmingCharacters(in: .whitespaces)
        let bars = try await fetchOHLCV(symbol: sym, period: "1y")
        let closes = bars.map(\.close)

        guard let currentPrice = closes.last, closes.count > 50 else {
            throw ChartDataError.insufficientData
        }

        // RSI
        let rsiValues = TechnicalIndicators.rsi(closes, period: 14)
        let rsi: Double? = rsiValues.last ?? nil

        // MACD
        let macdResult = TechnicalIndicators.macd(closes)
        let macdHist: Double? = macdResult.histogram.last ?? nil

        // SMAs
        let sma50Values = TechnicalIndicators.sma(closes, period: 50)
        let sma200Values = TechnicalIndicators.sma(closes, period: 200)
        let sma50: Double? = sma50Values.last ?? nil
        let sma200: Double? = sma200Values.last ?? nil

        // Bollinger Bands %B
        let bb = TechnicalIndicators.bollingerBands(closes, period: 20, stdDev: 2.0)
        var bollingerPctB: Double? = nil
        if let upper = bb.upper.last ?? nil,
           let lower = bb.lower.last ?? nil,
           upper != lower {
            bollingerPctB = (currentPrice - lower) / (upper - lower)
        }

        // STBR
        let hvol = TechnicalIndicators.historicalVolatility(closes, period: 30) ?? 0.2
        var stbrValue = 0.0
        if let upper = bb.upper.last ?? nil,
           let lower = bb.lower.last ?? nil,
           let middle = bb.middle.last ?? nil {
            let bandwidth = upper - lower
            if bandwidth > 0 {
                let deviation = abs(currentPrice - middle) / bandwidth
                stbrValue = deviation * (hvol * 100)
            }
        }

        let stbrRiskLevel: String
        let stbrColor: String
        if stbrValue < 0.5 {
            stbrRiskLevel = "Low"
            stbrColor = "green"
        } else if stbrValue < 1.0 {
            stbrRiskLevel = "Normal"
            stbrColor = "green"
        } else if stbrValue < 1.5 {
            stbrRiskLevel = "Elevated"
            stbrColor = "yellow"
        } else {
            stbrRiskLevel = "High"
            stbrColor = "red"
        }

        // Composite score (0-100)
        var score = 50.0

        // RSI contribution (-20 to +20)
        if let r = rsi {
            if r < 30 { score += 15 }       // oversold = bullish
            else if r < 40 { score += 8 }
            else if r > 70 { score -= 15 }   // overbought = bearish
            else if r > 60 { score -= 5 }
        }

        // MACD contribution (-15 to +15)
        if let h = macdHist {
            if h > 0 { score += min(h * 10, 15) }
            else { score += max(h * 10, -15) }
        }

        // SMA trend (-15 to +15)
        if let s50 = sma50 {
            if currentPrice > s50 { score += 8 } else { score -= 8 }
        }
        if let s200 = sma200 {
            if currentPrice > s200 { score += 7 } else { score -= 7 }
        }

        score = max(0, min(100, score))

        let compositeLabel: String
        if score >= 65 { compositeLabel = "BUY" }
        else if score <= 35 { compositeLabel = "SELL" }
        else { compositeLabel = "NEUTRAL" }

        return SignalReport(
            symbol: sym,
            price: currentPrice,
            rsi: rsi ?? 50.0,
            stbr: stbrValue,
            stbrRiskLevel: stbrRiskLevel,
            stbrColor: stbrColor,
            macdHistogram: macdHist ?? 0.0,
            compositeScore: score,
            compositeLabel: compositeLabel,
            sma50: sma50,
            sma200: sma200,
            bollingerPercentB: bollingerPctB
        )
    }
}

// MARK: - Errors

enum ChartDataError: LocalizedError {
    case invalidSymbol(String)
    case httpError(Int)
    case malformedResponse
    case noData
    case insufficientData

    var errorDescription: String? {
        switch self {
        case .invalidSymbol(let s): return "Invalid symbol: \(s)"
        case .httpError(let code): return "Yahoo Finance returned HTTP \(code)"
        case .malformedResponse: return "Malformed response from Yahoo Finance"
        case .noData: return "No data available"
        case .insufficientData: return "Insufficient historical data for analysis"
        }
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
