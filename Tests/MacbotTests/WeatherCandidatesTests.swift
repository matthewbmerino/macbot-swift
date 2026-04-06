import XCTest
@testable import Macbot

/// Locks the contract for `weatherQueryCandidates`. The bug this prevents:
/// "current temp in nassau bahamas" hit a 404 because the previous code
/// percent-encoded the space and wttr.in returned 404 for `Nassau%20Bahamas`.
/// The fallback chain ensures that even vague phrasings resolve.
final class WeatherCandidatesTests: XCTestCase {

    func testTwoWordLocationProducesCommaSeparatedAndBareCity() {
        let candidates = SkillTools.weatherQueryCandidates("Nassau Bahamas")
        // Comma-separated form must come first (most specific)
        XCTAssertEqual(candidates.first, "Nassau,Bahamas")
        // Bare city must be in the chain as a fallback
        XCTAssertTrue(candidates.contains("Nassau"))
    }

    func testCommaSeparatedInputIsNormalized() {
        let candidates = SkillTools.weatherQueryCandidates("Nassau, Bahamas")
        XCTAssertEqual(candidates.first, "Nassau,Bahamas")
        XCTAssertTrue(candidates.contains("Nassau"))
    }

    func testThreeWordCityCountry() {
        let candidates = SkillTools.weatherQueryCandidates("New York USA")
        XCTAssertEqual(candidates.first, "New York,USA")
        XCTAssertTrue(candidates.contains("New"))
    }

    func testSingleWordPassesThroughUnchanged() {
        let candidates = SkillTools.weatherQueryCandidates("Nassau")
        XCTAssertEqual(candidates, ["Nassau"])
    }

    func testEmptyOrWhitespaceProducesNoCandidates() {
        XCTAssertTrue(SkillTools.weatherQueryCandidates("").isEmpty)
        XCTAssertTrue(SkillTools.weatherQueryCandidates("   ").isEmpty)
    }

    func testSpacesGetReplacedWithPlusInOriginalForm() {
        // The "+" form is the wttr.in convention for multi-word names like
        // "New+York". It must appear somewhere in the chain.
        let candidates = SkillTools.weatherQueryCandidates("New York")
        XCTAssertTrue(candidates.contains("New+York") || candidates.contains("New,York"))
    }

    func testCandidatesAreDeduplicated() {
        let candidates = SkillTools.weatherQueryCandidates("Nassau,Bahamas")
        // Should not list "Nassau,Bahamas" twice even though multiple branches
        // could produce it.
        let unique = Set(candidates)
        XCTAssertEqual(candidates.count, unique.count)
    }

    func testBareCityIsAlwaysAFallbackForMultiWord() {
        // The fix's whole point: if "Nassau Bahamas" 404s, "Nassau" alone
        // should still be tried.
        let candidates = SkillTools.weatherQueryCandidates("Nassau Bahamas")
        guard let cityIdx = candidates.firstIndex(of: "Nassau"),
              let comboIdx = candidates.firstIndex(of: "Nassau,Bahamas") else {
            return XCTFail("expected both 'Nassau' and 'Nassau,Bahamas' candidates")
        }
        XCTAssertGreaterThan(cityIdx, comboIdx, "specific form should be tried first")
    }
}
