import Foundation

enum SkillTools {

    // MARK: - Tool Specs

    static let weatherSpec = ToolSpec(
        name: "weather_lookup",
        description: "Get current weather and 3-day forecast for a location. Use for any weather questions.",
        properties: ["location": .init(type: "string", description: "City name or zip code (e.g., New York, 90210)")],
        required: ["location"]
    )

    static let calculatorSpec = ToolSpec(
        name: "calculator",
        description: "Evaluate a mathematical expression. Supports: +, -, *, /, **, sqrt, sin, cos, tan, log, log10, pi, e, abs, round, ceil, floor.",
        properties: ["expression": .init(type: "string", description: "Math expression (e.g., sqrt(2) * pi, log(1000), 2**32)")],
        required: ["expression"]
    )

    static let unitConvertSpec = ToolSpec(
        name: "unit_convert",
        description: "Convert between units. Categories: temperature (F/C/K), distance (mi/km/m/ft/in/cm), weight (lb/kg/g/oz), volume (gal/L/mL/cup/fl_oz), speed (mph/kph), data (B/KB/MB/GB/TB).",
        properties: [
            "value": .init(type: "string", description: "Numeric value to convert"),
            "from_unit": .init(type: "string", description: "Source unit (e.g., F, km, lb, GB)"),
            "to_unit": .init(type: "string", description: "Target unit (e.g., C, mi, kg, MB)"),
        ],
        required: ["value", "from_unit", "to_unit"]
    )

    static let dateCalcSpec = ToolSpec(
        name: "date_calc",
        description: "Date calculations. Operations: days_between (two dates), add_days (date + N days), day_of_week (what day), days_until (from today to date).",
        properties: [
            "operation": .init(type: "string", description: "One of: days_between, add_days, day_of_week, days_until"),
            "date1": .init(type: "string", description: "Date in YYYY-MM-DD format"),
            "date2": .init(type: "string", description: "Second date for days_between (YYYY-MM-DD)"),
            "days": .init(type: "string", description: "Number of days for add_days"),
        ],
        required: ["operation", "date1"]
    )

    static let defineWordSpec = ToolSpec(
        name: "define_word",
        description: "Look up a word's definition, pronunciation, and usage examples.",
        properties: ["word": .init(type: "string", description: "Word to define")],
        required: ["word"]
    )

    static let systemDashboardSpec = ToolSpec(
        name: "system_dashboard",
        description: "Show a system health dashboard: CPU, memory, disk, battery, top processes, network, and Ollama model status.",
        properties: [:]
    )

    static let ambientContextSpec = ToolSpec(
        name: "ambient_context",
        description: "Get a snapshot of what the user is currently doing on their Mac: active app, idle time, battery, memory, recent clipboard. Use this when you need real-time context about the user's environment.",
        properties: [:]
    )

    static let recallEpisodesSpec = ToolSpec(
        name: "recall_episodes",
        description: "Recall past conversation episodes (auto-summarized chat sessions). Use this when the user asks about previous conversations, what they discussed before, or 'last time we talked about X'. Returns matching episodes with their summaries.",
        properties: [
            "query": .init(type: "string", description: "Optional keyword/topic to search for. Leave empty to get most recent episodes."),
            "limit": .init(type: "string", description: "Max episodes to return (default 5)"),
        ]
    )

    // MARK: - Registration

    static func register(on registry: ToolRegistry) async {
        await registry.register(weatherSpec) { args in
            await getWeather(location: args["location"] as? String ?? "")
        }
        await registry.register(calculatorSpec) { args in
            await calculate(expression: args["expression"] as? String ?? "")
        }
        await registry.register(unitConvertSpec) { args in
            convertUnit(
                value: args["value"] as? String ?? "",
                from: args["from_unit"] as? String ?? "",
                to: args["to_unit"] as? String ?? ""
            )
        }
        await registry.register(dateCalcSpec) { args in
            dateCalculation(
                operation: args["operation"] as? String ?? "",
                date1: args["date1"] as? String ?? "",
                date2: args["date2"] as? String,
                days: args["days"] as? String
            )
        }
        await registry.register(defineWordSpec) { args in
            await defineWord(args["word"] as? String ?? "")
        }
        await registry.register(systemDashboardSpec) { _ in
            await systemDashboard()
        }
        await registry.register(ambientContextSpec) { _ in
            await ambientContext()
        }
        await registry.register(recallEpisodesSpec) { args in
            recallEpisodes(
                query: args["query"] as? String ?? "",
                limit: Int(args["limit"] as? String ?? "5") ?? 5
            )
        }
    }

    // MARK: - Recall Episodes

    static func recallEpisodes(query: String, limit: Int) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let episodes = q.isEmpty
            ? EpisodicMemory.shared.recent(limit: limit)
            : EpisodicMemory.shared.search(query: q, limit: limit)

        if episodes.isEmpty {
            return q.isEmpty ? "No past episodes recorded yet." : "No episodes found matching '\(q)'."
        }
        return EpisodicMemory.format(episodes)
    }

    // MARK: - Ambient Context

    static func ambientContext() async -> String {
        let s = await AmbientMonitor.shared.current()
        var lines: [String] = ["Current ambient context:"]
        if !s.frontmostApp.isEmpty {
            lines.append("- Active app: \(s.frontmostApp)\(s.frontmostBundleID.isEmpty ? "" : " (\(s.frontmostBundleID))")")
        }
        if !s.windowTitle.isEmpty {
            lines.append("- Window: \(s.windowTitle)")
        }
        lines.append("- Idle: \(s.idleSeconds)s")
        if s.batteryPercent >= 0 {
            lines.append("- Battery: \(s.batteryPercent)%\(s.isCharging ? " (charging)" : "")")
        }
        if s.memoryTotalGB > 0 {
            lines.append("- Memory: \(String(format: "%.1f", s.memoryUsedGB)) / \(String(format: "%.0f", s.memoryTotalGB)) GB")
        }
        lines.append("- Network: \(s.networkOnline ? "online" : "offline")")
        if !s.clipboardPreview.isEmpty {
            lines.append("- Clipboard: \(s.clipboardPreview)")
        }
        let age = Int(Date().timeIntervalSince(s.capturedAt))
        lines.append("- Captured: \(age)s ago")
        return lines.joined(separator: "\n")
    }

    // MARK: - Weather (wttr.in)

    static func getWeather(location: String) async -> String {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Error: empty location" }

        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        guard let url = URL(string: "https://wttr.in/\(encoded)?format=j1") else {
            return "Error: invalid location"
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("curl/8.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Error: could not parse weather data"
            }

            guard let current = (json["current_condition"] as? [[String: Any]])?.first else {
                return "No weather data found for: \(trimmed)"
            }

            let tempF = current["temp_F"] as? String ?? "?"
            let tempC = current["temp_C"] as? String ?? "?"
            let feelsF = current["FeelsLikeF"] as? String ?? "?"
            let humidity = current["humidity"] as? String ?? "?"
            let windMph = current["windspeedMiles"] as? String ?? "?"
            let windDir = current["winddir16Point"] as? String ?? ""
            let desc = (current["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? "Unknown"
            let visibility = current["visibility"] as? String ?? "?"
            let uvIndex = current["uvIndex"] as? String ?? "?"

            var lines = [
                "Weather for \(trimmed)",
                "Condition: \(desc)",
                "Temperature: \(tempF)°F (\(tempC)°C), feels like \(feelsF)°F",
                "Humidity: \(humidity)%",
                "Wind: \(windMph) mph \(windDir)",
                "Visibility: \(visibility) mi",
                "UV Index: \(uvIndex)",
            ]

            // 3-day forecast
            if let forecast = json["weather"] as? [[String: Any]] {
                lines.append("\nForecast:")
                let dayFormatter = DateFormatter()
                dayFormatter.dateFormat = "yyyy-MM-dd"
                let displayFormatter = DateFormatter()
                displayFormatter.dateFormat = "EEE, MMM d"

                for day in forecast.prefix(3) {
                    let dateStr = day["date"] as? String ?? ""
                    let maxF = day["maxtempF"] as? String ?? "?"
                    let minF = day["mintempF"] as? String ?? "?"
                    let hourly = (day["hourly"] as? [[String: Any]])?.first
                    let dayDesc = (hourly?["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? ""

                    var label = dateStr
                    if let date = dayFormatter.date(from: dateStr) {
                        label = displayFormatter.string(from: date)
                    }
                    lines.append("  \(label): \(dayDesc), \(minF)–\(maxF)°F")
                }
            }

            return GroundedResponse.format(
                source: "wttr.in",
                body: lines.joined(separator: "\n")
            )
        } catch {
            return "Weather lookup failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Calculator

    static func calculate(expression: String) async -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Error: empty expression" }

        // Sanitize: only allow math characters, function names, and whitespace
        let allowed = CharacterSet.alphanumerics
            .union(.init(charactersIn: "+-*/().,%^ "))
        let cleaned = trimmed.unicodeScalars.filter { allowed.contains($0) }
        guard cleaned.count == trimmed.unicodeScalars.count else {
            return "Error: expression contains invalid characters"
        }

        let code = """
        import math
        _safe = {k: v for k, v in vars(math).items() if not k.startswith('_')}
        _safe.update({'abs': abs, 'round': round, 'min': min, 'max': max, 'sum': sum, 'pow': pow})
        try:
            result = eval('\(trimmed.replacingOccurrences(of: "'", with: ""))', {"__builtins__": {}}, _safe)
            print(result)
        except Exception as e:
            print(f"Error: {e}")
        """

        let result = await ExecutorTools.runPython(code: code)
        let cleaned_result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip STDERR prefix if present (sandbox warnings)
        var value = cleaned_result
        if cleaned_result.contains("STDERR:") && cleaned_result.contains("\n") {
            let parts = cleaned_result.components(separatedBy: "\n")
            if let firstLine = parts.first, !firstLine.hasPrefix("STDERR:") && !firstLine.hasPrefix("Error") {
                value = firstLine
            }
        }

        if value.hasPrefix("Error") {
            return value
        }
        // Stable lookup — no timestamp needed; the value is mathematically
        // exact and the model should quote it character-for-character.
        return GroundedResponse.format(
            source: "calculator",
            timePolicy: .none,
            body: "\(trimmed) = \(value)"
        )
    }

    // MARK: - Unit Conversion

    static func convertUnit(value: String, from: String, to: String) -> String {
        guard let num = Double(value.trimmingCharacters(in: .whitespaces)) else {
            return "Error: '\(value)' is not a valid number"
        }

        let fromUnit = from.trimmingCharacters(in: .whitespaces).lowercased()
        let toUnit = to.trimmingCharacters(in: .whitespaces).lowercased()

        // Temperature
        if let result = convertTemperature(num, from: fromUnit, to: toUnit) {
            return formatResult(result, unit: to)
        }

        // All other conversions go through a base-unit system
        let categories: [(name: String, base: String, units: [String: Double])] = [
            ("distance", "m", [
                "m": 1, "km": 1000, "mi": 1609.344, "ft": 0.3048,
                "in": 0.0254, "cm": 0.01, "mm": 0.001, "yd": 0.9144,
            ]),
            ("weight", "g", [
                "g": 1, "kg": 1000, "lb": 453.592, "oz": 28.3495,
                "mg": 0.001, "ton": 907185, "tonne": 1_000_000,
            ]),
            ("volume", "ml", [
                "ml": 1, "l": 1000, "gal": 3785.41, "cup": 236.588,
                "fl_oz": 29.5735, "pt": 473.176, "qt": 946.353, "tbsp": 14.787, "tsp": 4.929,
            ]),
            ("speed", "m_s", [
                "mph": 0.44704, "kph": 0.277778, "m_s": 1, "knot": 0.514444, "fps": 0.3048,
            ]),
            ("data", "b", [
                "b": 1, "kb": 1024, "mb": 1_048_576, "gb": 1_073_741_824,
                "tb": 1_099_511_627_776,
            ]),
            ("time", "s", [
                "s": 1, "ms": 0.001, "min": 60, "hr": 3600, "h": 3600,
                "day": 86400, "week": 604800, "month": 2_592_000, "year": 31_536_000,
            ]),
        ]

        for category in categories {
            if let fromFactor = category.units[fromUnit],
               let toFactor = category.units[toUnit] {
                let baseValue = num * fromFactor
                let result = baseValue / toFactor
                return formatResult(result, unit: to)
            }
        }

        return "Error: cannot convert from '\(from)' to '\(to)'. Supported: temperature (F/C/K), distance (m/km/mi/ft/in/cm), weight (g/kg/lb/oz), volume (mL/L/gal/cup/fl_oz), speed (mph/kph/m_s), data (B/KB/MB/GB/TB), time (s/min/hr/day)"
    }

    private static func convertTemperature(_ value: Double, from: String, to: String) -> Double? {
        let tempUnits: Set = ["f", "c", "k"]
        guard tempUnits.contains(from) && tempUnits.contains(to) else { return nil }
        if from == to { return value }

        // Convert to Celsius first
        let celsius: Double
        switch from {
        case "f": celsius = (value - 32) * 5 / 9
        case "k": celsius = value - 273.15
        default: celsius = value
        }

        // Convert from Celsius to target
        switch to {
        case "f": return celsius * 9 / 5 + 32
        case "k": return celsius + 273.15
        default: return celsius
        }
    }

    private static func formatResult(_ value: Double, unit: String) -> String {
        let formatted: String
        if value == value.rounded() && abs(value) < 1e12 {
            formatted = "\(Int(value)) \(unit)"
        } else {
            formatted = "\(String(format: "%.4g", value)) \(unit)"
        }
        return GroundedResponse.format(
            source: "unit_convert",
            timePolicy: .none,
            body: formatted
        )
    }

    // MARK: - Date Calculation

    static func dateCalculation(operation: String, date1: String, date2: String?, days: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEEE, MMMM d, yyyy"

        guard let d1 = formatter.date(from: date1.trimmingCharacters(in: .whitespaces)) else {
            return "Error: invalid date '\(date1)'. Use YYYY-MM-DD format."
        }

        let calendar = Calendar.current

        switch operation.lowercased().trimmingCharacters(in: .whitespaces) {
        case "days_between":
            guard let d2Str = date2, let d2 = formatter.date(from: d2Str.trimmingCharacters(in: .whitespaces)) else {
                return "Error: days_between requires date2 in YYYY-MM-DD format"
            }
            let components = calendar.dateComponents([.day], from: d1, to: d2)
            let count = components.day ?? 0
            return "\(abs(count)) days between \(date1) and \(d2Str)"

        case "add_days":
            guard let daysStr = days, let n = Int(daysStr.trimmingCharacters(in: .whitespaces)) else {
                return "Error: add_days requires a numeric days parameter"
            }
            guard let result = calendar.date(byAdding: .day, value: n, to: d1) else {
                return "Error: could not calculate date"
            }
            return "\(date1) + \(n) days = \(formatter.string(from: result)) (\(displayFormatter.string(from: result)))"

        case "day_of_week":
            return "\(date1) is a \(displayFormatter.string(from: d1))"

        case "days_until":
            let today = calendar.startOfDay(for: Date())
            let target = calendar.startOfDay(for: d1)
            let components = calendar.dateComponents([.day], from: today, to: target)
            let count = components.day ?? 0
            if count > 0 {
                return "\(count) days until \(date1) (\(displayFormatter.string(from: d1)))"
            } else if count == 0 {
                return "\(date1) is today!"
            } else {
                return "\(date1) was \(abs(count)) days ago (\(displayFormatter.string(from: d1)))"
            }

        default:
            return "Error: unknown operation '\(operation)'. Use: days_between, add_days, day_of_week, days_until"
        }
    }

    // MARK: - Define Word (Free Dictionary API)

    static func defineWord(_ word: String) async -> String {
        let trimmed = word.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return "Error: empty word" }

        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        guard let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
            return "Error: invalid word"
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return "No definition found for '\(trimmed)'"
            }

            guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let entry = entries.first else {
                return "No definition found for '\(trimmed)'"
            }

            var lines: [String] = []

            let headword = entry["word"] as? String ?? trimmed
            lines.append(headword.uppercased())

            // Phonetic
            if let phonetic = entry["phonetic"] as? String, !phonetic.isEmpty {
                lines.append("Pronunciation: \(phonetic)")
            } else if let phonetics = entry["phonetics"] as? [[String: Any]] {
                if let first = phonetics.first(where: { ($0["text"] as? String)?.isEmpty == false }) {
                    lines.append("Pronunciation: \(first["text"] as? String ?? "")")
                }
            }

            // Meanings
            if let meanings = entry["meanings"] as? [[String: Any]] {
                for meaning in meanings.prefix(3) {
                    let pos = meaning["partOfSpeech"] as? String ?? ""
                    lines.append("\n\(pos)")

                    if let definitions = meaning["definitions"] as? [[String: Any]] {
                        for (i, def) in definitions.prefix(3).enumerated() {
                            let definition = def["definition"] as? String ?? ""
                            lines.append("  \(i + 1). \(definition)")
                            if let example = def["example"] as? String, !example.isEmpty {
                                lines.append("     Example: \"\(example)\"")
                            }
                        }
                    }

                    if let synonyms = meaning["synonyms"] as? [String], !synonyms.isEmpty {
                        lines.append("  Synonyms: \(synonyms.prefix(5).joined(separator: ", "))")
                    }
                }
            }

            return lines.joined(separator: "\n")
        } catch {
            return "Definition lookup failed: \(error.localizedDescription)"
        }
    }

    // MARK: - System Dashboard

    static func systemDashboard() async -> String {
        var sections: [String] = ["System Dashboard", String(repeating: "─", count: 40)]

        // CPU
        if let cpu = shell("sysctl -n machdep.cpu.brand_string") {
            sections.append("CPU: \(cpu.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let load = shell("sysctl -n vm.loadavg") {
            sections.append("Load: \(load.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Memory
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / (1024 * 1024 * 1024)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        if result == KERN_SUCCESS {
            let pageSize = Double(vm_kernel_page_size)
            let active = Double(stats.active_count) * pageSize / (1024 * 1024 * 1024)
            let wired = Double(stats.wire_count) * pageSize / (1024 * 1024 * 1024)
            let compressed = Double(stats.compressor_page_count) * pageSize / (1024 * 1024 * 1024)
            let free = Double(stats.free_count) * pageSize / (1024 * 1024 * 1024)
            let used = active + wired + compressed
            let pressure = used / totalGB > 0.85 ? "HIGH" : used / totalGB > 0.7 ? "moderate" : "normal"

            sections.append("""
            Memory: \(String(format: "%.1f", used))GB / \(String(format: "%.1f", totalGB))GB (\(String(format: "%.0f", (used / totalGB) * 100))%) — pressure: \(pressure)
              Active: \(String(format: "%.1f", active))GB  Wired: \(String(format: "%.1f", wired))GB  Compressed: \(String(format: "%.1f", compressed))GB  Free: \(String(format: "%.1f", free))GB
            """)
        }

        // Disk
        if let disk = shell("df -h / | tail -1 | awk '{print $3 \" used / \" $2 \" total (\" $5 \" full)\"}'") {
            sections.append("Disk: \(disk.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Battery
        if let battery = shell("pmset -g batt | grep -E 'InternalBattery|AC Power'") {
            sections.append("Power: \(battery.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Uptime
        if let uptime = shell("uptime | sed 's/.*up //' | sed 's/,.*//'") {
            sections.append("Uptime: \(uptime.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Top 5 processes
        if let top = shell("ps -eo pcpu,rss,comm -r | head -6") {
            let lines = top.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.count > 1 {
                sections.append("\nTop Processes (by CPU):")
                for line in lines.dropFirst().prefix(5) {
                    let parts = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    guard parts.count >= 3 else { continue }
                    let cpu = parts[0]
                    let rssKB = Double(parts[1]) ?? 0
                    let name = parts[2...].joined(separator: " ").components(separatedBy: "/").last ?? parts[2]
                    sections.append("  \(name) — \(cpu)% CPU, \(String(format: "%.0f", rssKB / 1024)) MB")
                }
            }
        }

        // Network
        if let netCount = shell("netstat -an 2>/dev/null | grep ESTABLISHED | wc -l") {
            sections.append("\nNetwork: \(netCount.trimmingCharacters(in: .whitespacesAndNewlines)) established connections")
        }

        // Ollama status
        if let ollamaModels = shell("curl -s http://127.0.0.1:11434/api/tags 2>/dev/null") {
            if let data = ollamaModels.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let names = models.compactMap { $0["name"] as? String }
                sections.append("Ollama: \(names.count) models installed (\(names.joined(separator: ", ")))")
            }
        } else {
            sections.append("Ollama: not reachable")
        }

        return sections.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func shell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
