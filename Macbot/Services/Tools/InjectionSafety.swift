import Foundation

/// String-escaping helpers for the tool layer. All strings that cross a
/// shell or AppleScript boundary should be routed through one of these
/// functions — the LLM can supply arbitrary tool arguments, and a dropped
/// quote or apostrophe is all it takes to turn a benign-looking tool call
/// into an injection vector.
enum InjectionSafety {

    /// Escape a string for safe interpolation inside an AppleScript double-
    /// quoted literal. Handles backslashes and double quotes — the only two
    /// metacharacters meaningful inside `"..."` in AppleScript.
    ///
    /// Usage:
    /// ```
    /// let safe = InjectionSafety.escapeAppleScriptString(userInput)
    /// let script = "tell application \"\(safe)\" to activate"
    /// ```
    static func escapeAppleScriptString(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Escape a string for safe interpolation inside a POSIX shell single-
    /// quoted literal. The POSIX trick: you can't escape `'` inside `'...'`,
    /// so you close the quote, insert an escaped `\'`, and reopen the quote.
    ///
    /// Usage:
    /// ```
    /// let safe = InjectionSafety.escapeShellSingleQuote(userInput)
    /// let command = "open -a '\(safe)'"
    /// ```
    ///
    /// This is intentionally narrower than a full shell-safe quoter — it
    /// only protects inside single-quoted literals. Callers must still wrap
    /// the result in single quotes themselves; otherwise there's nothing for
    /// this escape to protect.
    static func escapeShellSingleQuote(_ input: String) -> String {
        input.replacingOccurrences(of: "'", with: "'\\''")
    }
}
