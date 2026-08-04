import XCTest
@testable import Resonant

final class ITNNumberListTests: XCTestCase {

    // MARK: - Enumerated number lists (pre-NeMo)

    func testNumberCueRunBecomesCommaSeparatedList() {
        XCTAssertEqual(
            ITNProcessor().process("some pages like number seven eleven seventeen nineteen twenty three"),
            "some pages like number 7, 11, 17, 19, 23"
        )
    }

    func testHybridDigitTailJoinsItsOnesWord() {
        // Parakeet's per-chunk emission digitizes part of the run in place;
        // "20 three" is one number split across a decode seam.
        XCTAssertEqual(
            ITNProcessor().process("some pages like number seven eleven seventeen nineteen 20 three"),
            "some pages like number 7, 11, 17, 19, 23"
        )
    }

    func testSingularCuePairReadsAsCompositeNumber() {
        XCTAssertEqual(
            ITNProcessor().process("it's on page seven eleven"),
            "it's on page 711"
        )
    }

    func testPluralCuePairReadsAsList() {
        XCTAssertEqual(
            ITNProcessor().process("see pages seven eleven"),
            "see pages 7, 11"
        )
    }

    func testPluralCueSingleDigitRunReadsAsList() {
        XCTAssertEqual(
            ITNProcessor().process("check numbers three five seven"),
            "check numbers 3, 5, 7"
        )
    }

    func testSingularCueSingleDigitRunStaysDigitSequence() {
        XCTAssertEqual(
            ITNProcessor().process("the winning number one two three"),
            "the winning number 123"
        )
    }

    func testCommaDelimitedRunAfterSingularCueStaysList() {
        // Commas from the pause-driven delimiter mark real gaps — even a
        // singular cue must not composite across them.
        XCTAssertEqual(
            ITNProcessor().process("page seven, eleven"),
            "page 7, 11"
        )
    }

    func testSingularCueYearPairReadsAsYear() {
        XCTAssertEqual(
            ITNProcessor().process("chapter twenty twenty six"),
            "chapter 2026"
        )
    }

    func testCueWithSingleNumberUntouched() {
        XCTAssertEqual(
            ITNProcessor().process("chapter twenty five"),
            "chapter 25"
        )
    }

    func testPhoneAfterAdjacentNumberCueStillRecomposes() {
        XCTAssertEqual(
            ITNProcessor().process("call the number five five five one two three four"),
            "call the number 555-1234"
        )
    }

    // MARK: - Time/year regressions (no cue, no commas — unchanged behavior)

    func testBareTimeStillConverts() {
        XCTAssertEqual(ITNProcessor().process("seven eleven"), "7:11")
    }

    func testBareYearStillConverts() {
        XCTAssertEqual(
            ITNProcessor().process("it happened in seventeen seventy six"),
            "it happened in 1776"
        )
    }

    // MARK: - Mixed word/digit list uniformity (post-NeMo)

    func testMixedWordDigitListDigitizesUniformly() {
        XCTAssertEqual(
            ITNProcessor().process("we chose seven, eleven, 23"),
            "we chose 7, 11, 23"
        )
    }

    func testMixedListWithAndDigitizes() {
        // NeMo's own enumeration grammar consumes the spoken "and" along
        // with the list; the uniformity pass never sees this shape.
        XCTAssertEqual(
            ITNProcessor().process("pick 3, seven, and eleven"),
            "pick 3, 7, 11"
        )
    }

    func testAllWordListLeftToNemo() {
        // Pre-existing NeMo behavior: an all-word comma enumeration is
        // digitized by NeMo itself, not by the uniformity pass (which
        // requires at least one digit item — verified directly below).
        XCTAssertEqual(
            ITNProcessor().process("one, two, three"),
            "1, 2, 3"
        )
    }

    func testTwoItemMixedListUntouched() {
        XCTAssertEqual(ITNProcessor().process("seven, 11"), "seven, 11")
    }

    // MARK: - Uniformity pass unit behavior (no NeMo)

    func testUniformityPassSkipsAllWordLists() {
        XCTAssertEqual(
            ITNProcessor().normalizingNumericListUniformity(in: "one, two, three"),
            "one, two, three"
        )
    }

    func testUniformityPassPreservesAndBeforeLastItem() {
        XCTAssertEqual(
            ITNProcessor().normalizingNumericListUniformity(in: "3, seven, and eleven"),
            "3, 7, and 11"
        )
    }

    func testUniformityPassConvertsCompoundWordItems() {
        XCTAssertEqual(
            ITNProcessor().normalizingNumericListUniformity(in: "seven, eleven, twenty three, 40"),
            "7, 11, 23, 40"
        )
    }
}
