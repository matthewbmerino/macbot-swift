import Foundation

enum TokenEstimator {
    /// BPE-aware token estimation.
    ///
    /// Standard word * 1.3 significantly underestimates code and non-English text.
    /// This uses character-class analysis for better accuracy without requiring
    /// the actual tokenizer vocabulary.
    ///
    /// Empirical calibration against Qwen2.5 tokenizer:
    /// - English prose: ~1.3 tokens/word
    /// - Code: ~2.0 tokens/word (operators, brackets, camelCase splits)
    /// - Mixed: ~1.6 tokens/word
    /// - CJK characters: ~1.0 tokens/character
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var tokens = 0
        var codeScore = 0
        var totalChars = 0

        let scalars = text.unicodeScalars

        for scalar in scalars {
            totalChars += 1

            // CJK characters are typically 1 token each
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                tokens += 1
                continue
            }

            // Code indicators: operators, brackets, semicolons
            if "{}[]()<>=!&|;:@#$%^*+~`\\".unicodeScalars.contains(scalar) {
                codeScore += 1
            }
        }

        // Calculate code ratio
        let codeRatio = totalChars > 0 ? Double(codeScore) / Double(totalChars) : 0

        // Split by whitespace for word-based estimation
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let wordCount = words.count

        // Adaptive multiplier based on content type
        let multiplier: Double
        if codeRatio > 0.08 {
            // High code density
            multiplier = 2.0
        } else if codeRatio > 0.03 {
            // Mixed content
            multiplier = 1.6
        } else {
            // Mostly prose
            multiplier = 1.3
        }

        tokens += Int(Double(wordCount) * multiplier)

        // Account for special tokens (BOS, message role tokens, etc.)
        // Each message typically adds 3-4 special tokens
        return max(1, tokens)
    }

    static func estimate(messages: [[String: Any]]) -> Int {
        var total = 0
        for msg in messages {
            // Per-message overhead: <|im_start|>role\n...<|im_end|>\n = ~4 tokens
            total += 4

            if let content = msg["content"] as? String {
                total += estimate(content)
            }
            if let toolCalls = msg["tool_calls"] {
                if let data = try? JSONSerialization.data(withJSONObject: toolCalls),
                   let text = String(data: data, encoding: .utf8) {
                    total += estimate(text)
                }
            }
        }
        return total
    }

    /// Estimate tokens remaining in a context window.
    static func remainingTokens(used: Int, contextSize: Int) -> Int {
        max(0, contextSize - used)
    }

    /// Check if adding content would exceed the context window.
    static func wouldExceed(_ text: String, currentTokens: Int, contextSize: Int, margin: Double = 0.9) -> Bool {
        let additional = estimate(text)
        return Double(currentTokens + additional) > Double(contextSize) * margin
    }
}
