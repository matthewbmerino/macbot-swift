import Foundation

enum CalculatorTool {

    static let spec = ToolSpec(
        name: "calculator",
        description: "Evaluate a mathematical expression. Supports: +, -, *, /, **, sqrt, sin, cos, tan, log, log10, pi, e, abs, round, ceil, floor.",
        properties: ["expression": .init(type: "string", description: "Math expression (e.g., sqrt(2) * pi, log(1000), 2**32)")],
        required: ["expression"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { args in
            await calculate(expression: args["expression"] as? String ?? "")
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
}
