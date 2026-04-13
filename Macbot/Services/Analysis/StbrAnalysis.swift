import Foundation

// MARK: - STBR (Short Term Bubble Risk) Analysis
// Ported from the meridian project. Pure Swift, no dependencies.

enum StbrAnalysis {

    // MARK: - Types

    struct StbrResult {
        /// Raw STBR value: price / SMA(140)
        let value: Double
        /// Categorical risk classification
        let riskLevel: RiskLevel
        /// Hex color string matching meridian palette
        let color: String
        /// Z-score of current STBR vs rolling history
        let zScore: Double?
        /// Annualized rate of change of STBR
        let velocity: Double?
    }

    enum RiskLevel: String {
        case bearish = "Bearish"
        case mildBearish = "Mild Bearish"
        case neutral = "Neutral"
        case normal = "Normal"
        case heatingUp = "Heating Up"
        case risky = "Risky"
        case superRisky = "Super Risky"
        case bubblePop = "Bubble Pop"
    }

    // MARK: - Constants

    private static let smaPeriod = 140
    /// Rolling window for z-score calculation
    private static let zScoreWindow = 252
    /// Trading days per year (for annualizing velocity)
    private static let tradingDaysPerYear = 252.0

    // MARK: - Public API

    /// Calculate a single STBR result from the full closing price history.
    /// Requires at least `smaPeriod` data points.
    static func calculate(closes: [Double]) -> StbrResult? {
        guard closes.count >= smaPeriod else { return nil }
        let results = series(closes: closes)
        return results.last ?? nil
    }

    /// Compute the full STBR series for charting.
    /// Returns an array the same length as `closes`; entries before
    /// `smaPeriod - 1` are `nil`.
    static func series(closes: [Double]) -> [StbrResult?] {
        let count = closes.count
        guard count >= smaPeriod else {
            return Array(repeating: nil, count: count)
        }

        let smaValues = TechnicalIndicators.sma(closes, period: smaPeriod)

        // First pass: compute raw STBR values where SMA is available
        var stbrValues = [Double?](repeating: nil, count: count)
        for i in 0 ..< count {
            if let sma = smaValues[i], sma > 0 {
                stbrValues[i] = closes[i] / sma
            }
        }

        // Second pass: build results with z-score and velocity
        var results = [StbrResult?](repeating: nil, count: count)
        for i in 0 ..< count {
            guard let stbr = stbrValues[i] else { continue }

            let zScore = computeZScore(stbrValues: stbrValues, at: i)
            let velocity = computeVelocity(stbrValues: stbrValues, at: i)

            results[i] = StbrResult(
                value: stbr,
                riskLevel: riskLevel(stbr: stbr),
                color: riskColor(stbr: stbr),
                zScore: zScore,
                velocity: velocity
            )
        }

        return results
    }

    /// Map an STBR value to its risk level.
    static func riskLevel(stbr: Double) -> RiskLevel {
        switch stbr {
        case ..<0.50:           return .bearish
        case 0.50 ..< 0.75:    return .mildBearish
        case 0.75 ..< 1.00:    return .neutral
        case 1.00 ..< 1.25:    return .normal
        case 1.25 ..< 1.50:    return .heatingUp
        case 1.50 ..< 1.75:    return .risky
        case 1.75 ..< 2.00:    return .superRisky
        default:               return .bubblePop
        }
    }

    /// Map an STBR value to a hex color string (matches meridian exactly).
    static func riskColor(stbr: Double) -> String {
        switch stbr {
        case ..<0.50:           return "#3B82F6"  // Deep Blue
        case 0.50 ..< 0.75:    return "#60A5FA"  // Light Blue
        case 0.75 ..< 1.00:    return "#06B6D4"  // Cyan
        case 1.00 ..< 1.25:    return "#10B981"  // Green
        case 1.25 ..< 1.50:    return "#F59E0B"  // Amber
        case 1.50 ..< 1.75:    return "#F97316"  // Orange
        case 1.75 ..< 2.00:    return "#EF4444"  // Red
        default:               return "#DC2626"  // Deep Red
        }
    }

    // MARK: - Composite Scores

    /// Opportunity score: ((100 - RSI) / 100) * (1 / max(STBR, 0.3)) * 100
    /// Higher values = stronger buy opportunity (low RSI + low STBR).
    static func opportunityScore(rsi: Double, stbr: Double) -> Double {
        let rsiComponent = (100.0 - rsi) / 100.0
        let stbrComponent = 1.0 / max(stbr, 0.3)
        return rsiComponent * stbrComponent * 100.0
    }

    /// 6-component weighted composite signal score.
    ///
    /// Weights: RSI 25%, Trend(SMA) 20%, MACD 20%, Bollinger 15%, Volume 10%, Volatility 10%.
    ///
    /// Returns (score: 0-100, label: human-readable signal).
    static func compositeScore(
        rsi: Double,
        sma50: Double?,
        sma200: Double?,
        price: Double,
        macdHistogram: Double?,
        bollingerPercentB: Double?,
        volumeRatio: Double?,
        volatility: Double?
    ) -> (score: Double, label: String) {

        var totalWeight = 0.0
        var weightedSum = 0.0

        // 1. RSI component (25%)
        //    Score: 100 when RSI=0 (oversold), 0 when RSI=100 (overbought)
        let rsiScore = 100.0 - rsi
        weightedSum += rsiScore * 0.25
        totalWeight += 0.25

        // 2. Trend / SMA component (20%)
        //    Based on golden/death cross and price vs SMA200
        if let s50 = sma50, let s200 = sma200, s200 > 0 {
            var trendScore = 50.0 // neutral baseline
            // Golden cross bonus
            if s50 > s200 {
                trendScore += 25.0
            } else {
                trendScore -= 25.0
            }
            // Price above SMA200 bonus
            let priceRatio = price / s200
            trendScore += min(max((priceRatio - 1.0) * 100.0, -25.0), 25.0)
            trendScore = min(max(trendScore, 0), 100)
            weightedSum += trendScore * 0.20
            totalWeight += 0.20
        }

        // 3. MACD component (20%)
        //    Positive histogram = bullish momentum
        if let hist = macdHistogram {
            // Normalize: map histogram to 0-100 range (sigmoid-like)
            let macdScore = 50.0 + 50.0 * tanh(hist * 0.5)
            weightedSum += macdScore * 0.20
            totalWeight += 0.20
        }

        // 4. Bollinger %B component (15%)
        //    %B near 0 = oversold (high score), near 1 = overbought (low score)
        if let pctB = bollingerPercentB {
            let bbScore = (1.0 - min(max(pctB, 0), 1)) * 100.0
            weightedSum += bbScore * 0.15
            totalWeight += 0.15
        }

        // 5. Volume component (10%)
        //    Above-average volume on bullish signals amplifies score
        if let vr = volumeRatio {
            // Volume ratio of 1.0 = neutral (50), higher = more conviction
            let volScore = min(max(vr / 2.0 * 100.0, 0), 100)
            weightedSum += volScore * 0.10
            totalWeight += 0.10
        }

        // 6. Volatility component (10%)
        //    Lower volatility = slightly higher score (stability premium)
        if let vol = volatility {
            // Typical annualized vol: 0.15 = low, 0.50+ = high
            let volScore = max(100.0 - vol * 200.0, 0)
            weightedSum += volScore * 0.10
            totalWeight += 0.10
        }

        // Normalize if some components are missing
        let finalScore: Double
        if totalWeight > 0 {
            finalScore = min(max(weightedSum / totalWeight, 0), 100)
        } else {
            finalScore = 50.0
        }

        let label = signalLabel(score: finalScore)
        return (score: finalScore, label: label)
    }

    // MARK: - Private helpers

    /// Compute z-score of the STBR at index `i` over a rolling window.
    private static func computeZScore(stbrValues: [Double?], at i: Int) -> Double? {
        // Collect up to `zScoreWindow` prior non-nil STBR values
        let start = max(0, i - zScoreWindow + 1)
        var window = [Double]()
        window.reserveCapacity(zScoreWindow)
        for j in start ... i {
            if let v = stbrValues[j] {
                window.append(v)
            }
        }
        guard window.count >= 20 else { return nil } // need reasonable sample

        let mean = window.reduce(0, +) / Double(window.count)
        let variance = window.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count)
        let sd = sqrt(variance)
        guard sd > 1e-10 else { return nil }

        guard let current = stbrValues[i] else { return nil }
        return (current - mean) / sd
    }

    /// Compute annualized velocity (rate of change) of STBR at index `i`.
    /// Uses a 20-day lookback by default.
    private static func computeVelocity(stbrValues: [Double?], at i: Int, lookback: Int = 20) -> Double? {
        guard i >= lookback else { return nil }
        guard let current = stbrValues[i], let prior = stbrValues[i - lookback] else { return nil }
        guard prior > 1e-10 else { return nil }

        let periodReturn = (current - prior) / prior
        // Annualize: scale by trading days / lookback
        return periodReturn * (tradingDaysPerYear / Double(lookback))
    }

    /// Convert a composite score (0-100) to a human-readable label.
    private static func signalLabel(score: Double) -> String {
        switch score {
        case 0 ..< 20:     return "Strong Sell"
        case 20 ..< 40:    return "Sell"
        case 40 ..< 60:    return "Neutral"
        case 60 ..< 80:    return "Buy"
        default:            return "Strong Buy"
        }
    }
}
