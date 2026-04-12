import Foundation

enum WeatherTool {

    static let spec = ToolSpec(
        name: "weather_lookup",
        description: "Get current weather and 3-day forecast for a location. Use for any weather questions.",
        properties: ["location": .init(type: "string", description: "City name or zip code (e.g., New York, 90210)")],
        required: ["location"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { args in
            await getWeather(location: args["location"] as? String ?? "")
        }
    }

    // MARK: - Weather (wttr.in)

    /// Build the ordered list of query strings to try against wttr.in.
    /// wttr.in is finicky with spaces: it returns 404 for `Nassau%20Bahamas`
    /// but resolves `Nassau,Bahamas` correctly. It also resolves bare city
    /// names for major cities globally. We try the most-specific form first,
    /// then progressively fall back so a vague user phrasing still works.
    static func weatherQueryCandidates(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = []

        // 1. If the user already comma-separated it, normalize whitespace
        //    around the comma and use that first.
        if trimmed.contains(",") {
            let parts = trimmed.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count >= 2, !parts[0].isEmpty {
                candidates.append(parts.joined(separator: ","))
                candidates.append(parts[0])  // bare city fallback
            }
        }

        // 2. Multi-word "City Country" → try "City,Country" then bare "City".
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count >= 2 {
            candidates.append(words.dropLast().joined(separator: " ") + "," + words.last!)
            candidates.append(words[0])
        }

        // 3. Original string with spaces collapsed to + (wttr.in's preferred
        //    in-query separator for multi-word names like "New+York").
        candidates.append(trimmed.replacingOccurrences(of: " ", with: "+"))

        // Deduplicate preserving order.
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// 5-minute TTL cache for weather lookups. Weather doesn't change
    /// meaningfully inside a 5-minute window, and wttr.in is shared
    /// infrastructure that we shouldn't hammer.
    static let weatherCache = ToolCache(ttl: 300, maxEntries: 32)

    static func getWeather(location: String) async -> String {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Error: empty location" }

        let cacheKey = trimmed.lowercased()
        if let cached = weatherCache.get(cacheKey) {
            return cached
        }

        let candidates = weatherQueryCandidates(trimmed)
        var lastError = ""

        for candidate in candidates {
            switch await fetchWeatherJSON(candidate: candidate) {
            case .success(let json):
                let formatted = formatWeatherJSON(json: json, displayLocation: trimmed)
                weatherCache.set(cacheKey, value: formatted)
                return formatted
            case .failure(let err):
                lastError = err
                Log.tools.warning("[weather] candidate '\(candidate)' failed: \(err)")
                continue
            }
        }

        return "Weather lookup failed for '\(trimmed)' after \(candidates.count) attempts. Last error: \(lastError)"
    }

    private enum WeatherFetchResult {
        case success([String: Any])
        case failure(String)
    }

    private static func fetchWeatherJSON(candidate: String) async -> WeatherFetchResult {
        // wttr.in expects path-style queries. We allow letters, digits, comma,
        // plus, hyphen, period, underscore — NOT spaces (wttr.in 404s on those).
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: ",+-._"))
        let encoded = candidate.addingPercentEncoding(withAllowedCharacters: allowed) ?? candidate
        guard let url = URL(string: "https://wttr.in/\(encoded)?format=j1") else {
            return .failure("invalid url for '\(candidate)'")
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("curl/8.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("non-HTTP response")
            }
            if http.statusCode != 200 {
                return .failure("HTTP \(http.statusCode)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("non-JSON response")
            }
            // wttr.in occasionally returns valid JSON with no current_condition
            // when the location is ambiguous — treat as a miss so we fall back.
            guard json["current_condition"] != nil else {
                return .failure("no current_condition in payload")
            }
            return .success(json)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func formatWeatherJSON(json: [String: Any], displayLocation: String) -> String {
        guard let current = (json["current_condition"] as? [[String: Any]])?.first else {
            return "No weather data found for: \(displayLocation)"
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

        // wttr.in echoes back the resolved location in nearest_area; use it
        // when present so the model knows which place actually answered
        // (catches "Nassau" → "Nassau, Bahamas" disambiguation).
        var resolved = displayLocation
        if let nearest = (json["nearest_area"] as? [[String: Any]])?.first,
           let areaName = (nearest["areaName"] as? [[String: Any]])?.first?["value"] as? String,
           !areaName.isEmpty {
            let country = (nearest["country"] as? [[String: Any]])?.first?["value"] as? String ?? ""
            resolved = country.isEmpty ? areaName : "\(areaName), \(country)"
        }

        var lines = [
            "Weather for \(resolved)",
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
    }
}
