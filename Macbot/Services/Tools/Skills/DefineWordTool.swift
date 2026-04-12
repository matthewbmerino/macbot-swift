import Foundation

enum DefineWordTool {

    static let spec = ToolSpec(
        name: "define_word",
        description: "Look up a word's definition, pronunciation, and usage examples.",
        properties: ["word": .init(type: "string", description: "Word to define")],
        required: ["word"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { args in
            await defineWord(args["word"] as? String ?? "")
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
}
