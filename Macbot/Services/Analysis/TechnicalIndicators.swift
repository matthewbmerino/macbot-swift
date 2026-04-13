import Foundation

// MARK: - Technical Indicators Engine
// Pure Swift math for financial chart analysis. No UI, no external dependencies.

enum TechnicalIndicators {

    // MARK: - Simple Moving Average

    /// Returns an array the same length as `values`.
    /// Positions 0 ..< period-1 are `nil` (insufficient data).
    static func sma(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        var result = [Double?](repeating: nil, count: values.count)
        var windowSum = values[0 ..< period].reduce(0, +)
        result[period - 1] = windowSum / Double(period)
        for i in period ..< values.count {
            windowSum += values[i] - values[i - period]
            result[i] = windowSum / Double(period)
        }
        return result
    }

    // MARK: - Exponential Moving Average

    /// EMA seeded from the first SMA value.
    /// Multiplier = 2 / (period + 1).
    static func ema(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        var result = [Double?](repeating: nil, count: values.count)
        let multiplier = 2.0 / Double(period + 1)

        // Seed: SMA of first `period` values
        let seed = values[0 ..< period].reduce(0, +) / Double(period)
        result[period - 1] = seed

        var prev = seed
        for i in period ..< values.count {
            let current = (values[i] - prev) * multiplier + prev
            result[i] = current
            prev = current
        }
        return result
    }

    // MARK: - Relative Strength Index (Wilder smoothing)

    /// RSI using Wilder's smoothing method.
    /// First RSI uses simple average of gains/losses over `period`.
    /// Subsequent values use exponential smoothing with alpha = 1/period.
    static func rsi(_ closes: [Double], period: Int = 14) -> [Double?] {
        guard period > 0, closes.count > period else {
            return Array(repeating: nil, count: closes.count)
        }
        var result = [Double?](repeating: nil, count: closes.count)

        // Calculate price changes
        var gains = [Double]()
        var losses = [Double]()
        for i in 1 ..< closes.count {
            let change = closes[i] - closes[i - 1]
            gains.append(max(change, 0))
            losses.append(max(-change, 0))
        }

        // First average gain / loss (simple average)
        var avgGain = gains[0 ..< period].reduce(0, +) / Double(period)
        var avgLoss = losses[0 ..< period].reduce(0, +) / Double(period)

        let rsiValue: (Double, Double) -> Double = { ag, al in
            if al == 0 { return 100.0 }
            let rs = ag / al
            return 100.0 - (100.0 / (1.0 + rs))
        }

        // The first RSI value corresponds to index `period` in the original array
        result[period] = rsiValue(avgGain, avgLoss)

        // Wilder smoothing for the rest
        for i in period ..< gains.count {
            avgGain = (avgGain * Double(period - 1) + gains[i]) / Double(period)
            avgLoss = (avgLoss * Double(period - 1) + losses[i]) / Double(period)
            result[i + 1] = rsiValue(avgGain, avgLoss)
        }

        return result
    }

    // MARK: - MACD

    /// MACD = EMA(fast) - EMA(slow). Signal = EMA(signal) of MACD line.
    /// Histogram = MACD - Signal.
    static func macd(
        _ closes: [Double],
        fast: Int = 12,
        slow: Int = 26,
        signal signalPeriod: Int = 9
    ) -> (macd: [Double?], signal: [Double?], histogram: [Double?]) {
        let count = closes.count
        let emaFast = ema(closes, period: fast)
        let emaSlow = ema(closes, period: slow)

        // MACD line
        var macdLine = [Double?](repeating: nil, count: count)
        for i in 0 ..< count {
            if let f = emaFast[i], let s = emaSlow[i] {
                macdLine[i] = f - s
            }
        }

        // Signal line = EMA of the non-nil MACD values
        // Collect contiguous MACD values starting from the first non-nil
        let firstMacdIdx = macdLine.firstIndex(where: { $0 != nil }) ?? count
        let macdValues = macdLine[firstMacdIdx...].map { $0 ?? 0 }

        let signalEma = ema(Array(macdValues), period: signalPeriod)

        var signalLine = [Double?](repeating: nil, count: count)
        var histogram = [Double?](repeating: nil, count: count)

        for (j, i) in (firstMacdIdx ..< count).enumerated() {
            signalLine[i] = signalEma[j]
            if let m = macdLine[i], let s = signalEma[j] {
                histogram[i] = m - s
            }
        }

        return (macdLine, signalLine, histogram)
    }

    // MARK: - Bollinger Bands

    /// Middle = SMA(period), Upper/Lower = Middle +/- stdDev * rolling std deviation.
    static func bollingerBands(
        _ closes: [Double],
        period: Int = 20,
        stdDev: Double = 2.0
    ) -> (upper: [Double?], middle: [Double?], lower: [Double?]) {
        let count = closes.count
        let middle = sma(closes, period: period)

        var upper = [Double?](repeating: nil, count: count)
        var lower = [Double?](repeating: nil, count: count)

        for i in (period - 1) ..< count {
            guard let mid = middle[i] else { continue }
            let window = Array(closes[(i - period + 1) ... i])
            let mean = mid
            let variance = window.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(period)
            let sd = sqrt(variance)
            upper[i] = mid + stdDev * sd
            lower[i] = mid - stdDev * sd
        }

        return (upper, middle, lower)
    }

    // MARK: - Historical Volatility

    /// Annualized historical volatility from log returns over `period` trading days.
    /// Returns `nil` if insufficient data.
    static func historicalVolatility(_ closes: [Double], period: Int = 30) -> Double? {
        guard closes.count > period else { return nil }

        // Use the most recent `period` log returns
        let startIdx = closes.count - period
        var logReturns = [Double]()
        logReturns.reserveCapacity(period)
        for i in startIdx ..< closes.count {
            guard closes[i - 1] > 0, closes[i] > 0 else { return nil }
            logReturns.append(log(closes[i] / closes[i - 1]))
        }

        let mean = logReturns.reduce(0, +) / Double(period)
        let variance = logReturns.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(period - 1)
        let dailyVol = sqrt(variance)

        // Annualize: sqrt(252 trading days)
        return dailyVol * sqrt(252.0)
    }

    // MARK: - Volume Ratio

    /// Current volume divided by the average of the last `period` volumes.
    /// Returns `nil` if insufficient data.
    static func volumeRatio(currentVolume: Double, volumes: [Double], period: Int = 20) -> Double? {
        guard volumes.count >= period, period > 0 else { return nil }
        let recentAvg = volumes.suffix(period).reduce(0, +) / Double(period)
        guard recentAvg > 0 else { return nil }
        return currentVolume / recentAvg
    }
}
