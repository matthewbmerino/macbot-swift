import XCTest
@testable import Macbot

/// Locks the escaping contracts for shell and AppleScript boundaries. These
/// are security-relevant: tools that interpolate LLM-supplied arguments
/// into shell or AppleScript strings without escaping are an injection
/// vector. These tests encode the "attack strings" that must be defanged.
final class InjectionSafetyTests: XCTestCase {

    // MARK: - AppleScript

    func testAppleScriptEscapesDoubleQuotes() {
        // Every double quote in the input must be preceded by a backslash
        // in the output. Substring search isn't enough because the escape
        // sequence still contains the literal quote character; we verify
        // the structural invariant instead: no bare `"` without a `\` before it.
        let attack = #"Safari" to quit tell application "Terminal"#
        let result = InjectionSafety.escapeAppleScriptString(attack)
        let inputQuoteCount = attack.filter { $0 == "\"" }.count
        let escapedQuoteCount = result.components(separatedBy: #"\""#).count - 1
        XCTAssertEqual(escapedQuoteCount, inputQuoteCount,
                       "every input quote must become an escaped \\\" in the output")
        // And no unescaped quote survives at any position.
        for (i, c) in result.enumerated() where c == "\"" {
            let prev = result.index(result.startIndex, offsetBy: i - 1)
            XCTAssertEqual(result[prev], "\\",
                           "quote at position \(i) is not preceded by backslash")
        }
    }

    func testAppleScriptEscapesBackslashes() {
        let result = InjectionSafety.escapeAppleScriptString(#"path\to\file"#)
        // Each backslash doubles so AppleScript doesn't interpret it as an escape.
        XCTAssertEqual(result, #"path\\to\\file"#)
    }

    func testAppleScriptBenignInputPassesThrough() {
        XCTAssertEqual(InjectionSafety.escapeAppleScriptString("Safari"), "Safari")
        XCTAssertEqual(InjectionSafety.escapeAppleScriptString("Visual Studio Code"), "Visual Studio Code")
    }

    func testAppleScriptEmptyInput() {
        XCTAssertEqual(InjectionSafety.escapeAppleScriptString(""), "")
    }

    func testAppleScriptEscapeOrderBackslashFirst() {
        // Critical: backslashes must be doubled BEFORE quotes are escaped,
        // otherwise the `\"` we introduce would then get its backslash
        // doubled, producing `\\"` which wouldn't escape the quote.
        let input = #"a\"b"#
        let result = InjectionSafety.escapeAppleScriptString(input)
        XCTAssertEqual(result, #"a\\\"b"#)
    }

    // MARK: - Shell single-quoted

    func testShellSingleQuoteDefangsSingleQuote() {
        // The POSIX trick: inside a single-quoted string you cannot escape
        // a literal `'`; you must close the quote, emit `\'`, and reopen.
        // So `'` → `'\''`. Verify the structural invariant: every input `'`
        // becomes exactly the 4-char sequence `'\''` in the output.
        let attack = "Safari'; rm -rf ~; echo '"
        let safe = InjectionSafety.escapeShellSingleQuote(attack)

        let inputSingleCount = attack.filter { $0 == "'" }.count
        // Each input single-quote becomes `'\''` (4 chars containing 3 `'`s).
        // So output `'` count = input `'` count * 3.
        let outputSingleCount = safe.filter { $0 == "'" }.count
        XCTAssertEqual(outputSingleCount, inputSingleCount * 3,
                       "each input single-quote must expand to `'\\''` (3 quotes)")
        // And the escape sequence itself must be present.
        XCTAssertTrue(safe.contains(#"'\''"#))
    }

    func testShellSingleQuoteBenignInputPassesThrough() {
        XCTAssertEqual(InjectionSafety.escapeShellSingleQuote("Safari"), "Safari")
        XCTAssertEqual(InjectionSafety.escapeShellSingleQuote("Visual Studio Code"), "Visual Studio Code")
    }

    func testShellSingleQuoteLeavesDoubleQuotesAlone() {
        // Inside a shell single-quoted literal, double quotes are not
        // special — we must not touch them.
        XCTAssertEqual(InjectionSafety.escapeShellSingleQuote(#"say "hi""#), #"say "hi""#)
    }

    func testShellSingleQuoteEmptyInput() {
        XCTAssertEqual(InjectionSafety.escapeShellSingleQuote(""), "")
    }
}
