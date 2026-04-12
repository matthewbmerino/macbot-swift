import Foundation

// MARK: - Shared chart infrastructure (Python runner, stats formatting)

enum ChartShared {

    // MARK: - Python Runner

    static func runPython(script: String, chartPath: String, label: String) async -> String {
        let result = await executeChartScript(script: script, chartPath: chartPath, label: label)

        // Auto-install missing modules and retry once
        // The return format is "Chart failed — missing Python module: <name>"
        if result.hasPrefix("Chart failed — missing Python module:") {
            let module = result
                .replacingOccurrences(of: "Chart failed — missing Python module: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: ".").first ?? ""

            if !module.isEmpty {
                let pipName = ExecutorTools.pipPackageName(for: module)
                Log.tools.info("Chart auto-installing missing module: \(pipName)")
                let installResult = await ExecutorTools.installPackage(pipName)
                if !installResult.hasPrefix("Error:") {
                    return await executeChartScript(script: script, chartPath: chartPath, label: label)
                }
                return "Auto-install of '\(pipName)' failed: \(installResult)\n\nOriginal: \(result)"
            }
        }

        return result
    }

    private static func executeChartScript(script: String, chartPath: String, label: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()

            let deadline = Date().addingTimeInterval(45)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                return "Error: chart generation timed out after 45s"
            }

            if FileManager.default.fileExists(atPath: chartPath) {
                let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let statsBlock = formatStatsBlock(stdout: stdout)
                if statsBlock.isEmpty {
                    return "\(label)\n[IMAGE:\(chartPath)]"
                }
                // Stats first so the LLM cites them in its response, image second.
                return "\(label)\n\(statsBlock)\n[IMAGE:\(chartPath)]"
            }

            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if stderr.contains("No module named") {
                let module = stderr.components(separatedBy: "No module named").last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "'", with: "") ?? "unknown"
                return "Chart failed — missing Python module: \(module)"
            }
            return "Chart failed: \(String(stderr.prefix(300)))"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Stats Formatting

    /// Parses `STATS:{json}` lines from a chart script's stdout and renders
    /// them as plain text the model can quote verbatim. Returns empty string
    /// if no stats line is present.
    ///
    /// The contract: every chart-producing Python script that has numeric
    /// data prints exactly one line of the form `STATS:<json>` to stdout
    /// before `print('OK')`. The JSON is either a single-ticker dict
    /// (`{ticker, period, start_price, end_price, pct_change, ...}`) or a
    /// comparison dict (`{period, tickers: [{ticker, start_price, ...}, ...]}`).
    /// This single source of truth keeps the chart and the LLM's text aligned.
    static func formatStatsBlock(stdout: String) -> String {
        for line in stdout.components(separatedBy: "\n") {
            guard line.hasPrefix("STATS:") else { continue }
            let jsonStr = String(line.dropFirst("STATS:".count))
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return renderStats(obj)
        }
        return ""
    }

    private static func renderStats(_ obj: [String: Any]) -> String {
        let period = (obj["period"] as? String).map { $0.uppercased() } ?? ""
        var lines: [String] = []

        // Comparison-style payload
        if let tickers = obj["tickers"] as? [[String: Any]] {
            lines.append("Data (single source of truth — use these exact numbers in your response):")
            for entry in tickers {
                lines.append(formatTickerLine(entry, period: period))
            }
            return lines.joined(separator: "\n")
        }

        // Single-ticker payload
        if obj["ticker"] is String {
            lines.append("Data (single source of truth — use these exact numbers in your response):")
            lines.append(formatTickerLine(obj, period: period))
            if let hi = obj["period_high"] as? Double {
                lines.append(String(format: "Period high: $%.2f", hi))
            }
            if let lo = obj["period_low"] as? Double {
                lines.append(String(format: "Period low: $%.2f", lo))
            }
            return lines.joined(separator: "\n")
        }

        return ""
    }

    static func formatTickerLine(_ entry: [String: Any], period: String) -> String {
        let sym = entry["ticker"] as? String ?? "?"
        let pct = (entry["pct_change"] as? Double) ?? Double(entry["pct_change"] as? Int ?? 0)
        let start = (entry["start_price"] as? Double) ?? Double(entry["start_price"] as? Int ?? 0)
        let end = (entry["end_price"] as? Double) ?? Double(entry["end_price"] as? Int ?? 0)
        let sign = pct >= 0 ? "+" : ""
        let pctStr = String(format: "%.2f", pct)
        let startStr = String(format: "%.2f", start)
        let endStr = String(format: "%.2f", end)
        if period.isEmpty {
            return "\(sym): \(sign)\(pctStr)% (start $\(startStr) → end $\(endStr))"
        }
        return "\(sym) \(period): \(sign)\(pctStr)% (start $\(startStr) → end $\(endStr))"
    }
}
