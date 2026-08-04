import AppKit
import XCTest
@testable import Resonant

/// Covers the locale-scoped word-ness fix (0.1.86): the English merge path now
/// resolves a single dictation locale before spell-checking, instead of letting
/// macOS auto-identify across all installed dictionaries (which accepted junk
/// like "gotoforatest"/"ndu"/"thengram"). Combined with a non-word-sliver
/// suspicion anchor, this closes BOTH failure modes at once — and must not
/// re-introduce the over-merge regressions a length-only anchor would.
final class FragmentedWordRepairLocaleScopeTests: XCTestCase {

    private static var englishDictionaryAvailable = false
    override class func setUp() {
        super.setUp()
        englishDictionaryAvailable = NSSpellChecker.shared.availableLanguages.contains { $0.hasPrefix("en") }
    }

    private func repair(_ text: String) -> String {
        FragmentedWordRepair.repair(text, language: "en")
    }

    // MARK: - Under-merge fixed (the new production bug)

    func testOverSegmentedWordWithNoLongAnchorMerges() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        // "industries" -> "i ndu str ies": four short pieces, no 4+ char anchor.
        XCTAssertEqual(repair("i ndu str ies"), "industries")
        XCTAssertEqual(repair("operation heavy i ndu str ies"), "operation heavy industries")
    }

    // MARK: - Existing over-segmentation recall preserved

    func testKnownOverSegmentationsStillMerge() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        XCTAssertEqual(repair("please fix the t rans format i on"), "please fix the transformation")
        XCTAssertEqual(repair("how is it per form ing"), "how is it performing")
        XCTAssertEqual(repair("meeting detect i on works"), "meeting detection works")
        XCTAssertEqual(repair("we need the t ran scripts now"), "we need the transcripts now")
    }

    // MARK: - Over-merge (glue) stays fixed

    func testCorrectlySpacedRealWordsNeverGlue() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        XCTAssertEqual(repair("Who can I go to for a test for this?"), "Who can I go to for a test for this?")
        XCTAssertEqual(repair("go to for a test"), "go to for a test")
        XCTAssertFalse(repair("go to for a test").contains("gotoforatest"))
    }

    // MARK: - Regressions the gate-only patch would have introduced

    func testBareConsonantProseDoesNotGlue() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        // A spelled letter in prose must not be glued — the locale-scoped join
        // check rejects "thengram"/"vitaminddaily"/"gradeabcd".
        XCTAssertEqual(repair("the n gram model"), "the n gram model")
        XCTAssertEqual(repair("vitamin d daily dose"), "vitamin d daily dose")
        XCTAssertEqual(repair("grade a b c d"), "grade a b c d")
    }

    // MARK: - Real-word pairs/phrases stay spaced

    func testRealWordRunsStaySpaced() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        XCTAssertEqual(repair("the in put was wrong"), "the in put was wrong")
        XCTAssertEqual(repair("we meet of ten on Mondays"), "we meet of ten on Mondays")
        XCTAssertEqual(repair("We found a way back into the app."), "We found a way back into the app.")
        XCTAssertEqual(repair("In terms of implementation, we can do that."),
                       "In terms of implementation, we can do that.")
    }
}
