import Foundation

enum TextTools {

    static let jsonFormatSpec = ToolSpec(
        name: "json_format",
        description: "Format, minify, or extract a value from JSON. Operations: pretty (default), minify, extract (with a key path like 'data.users[0].name').",
        properties: [
            "json": .init(type: "string", description: "JSON string to process"),
            "operation": .init(type: "string", description: "pretty, minify, or extract (default: pretty)"),
            "path": .init(type: "string", description: "Key path for extract operation (e.g., data.items[0].name)"),
        ],
        required: ["json"]
    )

    static let encodeDecodeSpec = ToolSpec(
        name: "encode_decode",
        description: "Encode or decode text. Formats: base64_encode, base64_decode, url_encode, url_decode, html_encode, html_decode.",
        properties: [
            "text": .init(type: "string", description: "Text to encode/decode"),
            "format": .init(type: "string", description: "One of: base64_encode, base64_decode, url_encode, url_decode, html_encode, html_decode"),
        ],
        required: ["text", "format"]
    )

    static let regexSpec = ToolSpec(
        name: "regex_extract",
        description: "Extract matches from text using a regular expression pattern. Returns all matches.",
        properties: [
            "text": .init(type: "string", description: "Text to search"),
            "pattern": .init(type: "string", description: "Regular expression pattern"),
        ],
        required: ["text", "pattern"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(jsonFormatSpec) { args in
            jsonFormat(
                json: args["json"] as? String ?? "",
                operation: args["operation"] as? String ?? "pretty",
                path: args["path"] as? String
            )
        }
        await registry.register(encodeDecodeSpec) { args in
            encodeDecode(
                text: args["text"] as? String ?? "",
                format: args["format"] as? String ?? ""
            )
        }
        await registry.register(regexSpec) { args in
            regexExtract(
                text: args["text"] as? String ?? "",
                pattern: args["pattern"] as? String ?? ""
            )
        }
    }

    // MARK: - JSON

    static func jsonFormat(json: String, operation: String, path: String?) -> String {
        guard let data = json.data(using: .utf8) else { return "Error: invalid input" }

        do {
            let obj = try JSONSerialization.jsonObject(with: data)

            switch operation.lowercased() {
            case "minify":
                let minified = try JSONSerialization.data(withJSONObject: obj)
                return String(data: minified, encoding: .utf8) ?? "Error: encoding failed"

            case "extract":
                guard let keyPath = path, !keyPath.isEmpty else {
                    return "Error: extract requires a path parameter"
                }
                let result = extractPath(obj, keyPath: keyPath)
                if let dict = result as? [String: Any] {
                    let d = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
                    return String(data: d, encoding: .utf8) ?? "\(dict)"
                }
                if let arr = result as? [Any] {
                    let d = try JSONSerialization.data(withJSONObject: arr, options: .prettyPrinted)
                    return String(data: d, encoding: .utf8) ?? "\(arr)"
                }
                return result.map { "\($0)" } ?? "null (path not found)"

            default: // pretty
                let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                return String(data: pretty, encoding: .utf8) ?? "Error: encoding failed"
            }
        } catch {
            return "Error: invalid JSON — \(error.localizedDescription)"
        }
    }

    private static func extractPath(_ obj: Any, keyPath: String) -> Any? {
        let components = keyPath.components(separatedBy: ".")
        var current: Any? = obj

        for component in components {
            guard let cur = current else { return nil }

            // Check for array index: key[0]
            if let bracketRange = component.range(of: "["),
               let endBracket = component.range(of: "]") {
                let key = String(component[..<bracketRange.lowerBound])
                let indexStr = String(component[bracketRange.upperBound..<endBracket.lowerBound])
                guard let index = Int(indexStr) else { return nil }

                if !key.isEmpty {
                    guard let dict = cur as? [String: Any], let arr = dict[key] as? [Any] else { return nil }
                    current = index < arr.count ? arr[index] : nil
                } else {
                    guard let arr = cur as? [Any] else { return nil }
                    current = index < arr.count ? arr[index] : nil
                }
            } else if let dict = cur as? [String: Any] {
                current = dict[component]
            } else {
                return nil
            }
        }

        return current
    }

    // MARK: - Encode/Decode

    static func encodeDecode(text: String, format: String) -> String {
        switch format.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64_encode":
            guard let data = text.data(using: .utf8) else { return "Error: encoding failed" }
            return data.base64EncodedString()

        case "base64_decode":
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let decoded = String(data: data, encoding: .utf8) else {
                return "Error: invalid base64"
            }
            return decoded

        case "url_encode":
            return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text

        case "url_decode":
            return text.removingPercentEncoding ?? text

        case "html_encode":
            return text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")

        case "html_decode":
            return text
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")

        default:
            return "Error: unknown format '\(format)'. Use: base64_encode, base64_decode, url_encode, url_decode, html_encode, html_decode"
        }
    }

    // MARK: - Regex

    static func regexExtract(text: String, pattern: String) -> String {
        guard !pattern.isEmpty else { return "Error: empty pattern" }

        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)

            if matches.isEmpty { return "No matches found." }

            var results: [String] = ["\(matches.count) match(es):"]
            for (i, match) in matches.prefix(50).enumerated() {
                guard let fullRange = Range(match.range, in: text) else { continue }
                var line = "\(i + 1). \(text[fullRange])"

                // Include capture groups
                if match.numberOfRanges > 1 {
                    var groups: [String] = []
                    for g in 1..<match.numberOfRanges {
                        if let r = Range(match.range(at: g), in: text) {
                            groups.append("$\(g)=\"\(text[r])\"")
                        }
                    }
                    if !groups.isEmpty {
                        line += "  [\(groups.joined(separator: ", "))]"
                    }
                }
                results.append(line)
            }

            if matches.count > 50 { results.append("... (\(matches.count - 50) more)") }
            return results.joined(separator: "\n")
        } catch {
            return "Error: invalid regex — \(error.localizedDescription)"
        }
    }
}
