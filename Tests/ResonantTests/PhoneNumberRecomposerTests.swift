import XCTest
@testable import Resonant

/// Direct unit tests for the pure recomposer, operating on already-digitized
/// text (i.e. what reaches it after the NeMo pass in `ITNProcessor`).
final class PhoneNumberRecomposerTests: XCTestCase {

    // MARK: - Reformatting with a cue

    func testGroupsTenDigitRunAfterCue() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("my number is 5551234567"),
            "my number is 555-123-4567"
        )
    }

    func testGroupsSevenDigitRunWhenCuePresent() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("call 5551234"),
            "call 555-1234"
        )
    }

    func testKeepsAlreadyGroupedTenDigitRun() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("my number is 555-123-4567"),
            "my number is 555-123-4567"
        )
    }

    func testAddsCountryCodeForPlusOne() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("text me at + 1 555-123-4567"),
            "text me at +1 555-123-4567"
        )
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("text me at +1 5551234567"),
            "text me at +1 555-123-4567"
        )
    }

    func testFormatsElevenDigitLeadingOneWithoutPlus() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("call 15551234567"),
            "call 1-555-123-4567"
        )
    }

    func testAppendsExtension() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("call 123-123-5678 extension 99"),
            "call 123-123-5678 ext. 99"
        )
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("call 5551234567 ext 234"),
            "call 555-123-4567 ext. 234"
        )
    }

    // MARK: - Gating

    func testDoesNotReformatSevenDigitsWithoutCue() {
        // A bare 7-digit run has no cue and no phone-shaped grouping.
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("the code is 5551234"),
            "the code is 5551234"
        )
    }

    func testDoesNotReformatIdContextEvenWithNumberWord() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("the invoice number is 5551234567"),
            "the invoice number is 5551234567"
        )
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("order number 5551234567"),
            "order number 5551234567"
        )
    }

    func testDoesNotReformatBareYear() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("in 1995 things changed"),
            "in 1995 things changed"
        )
    }

    func testLeavesUngroupedTenDigitsWithoutCueAlone() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("the value was 5551234567 total"),
            "the value was 5551234567 total"
        )
    }

    func testReformatsAlreadyGroupedRunWithoutCue() {
        // Shape alone is sufficient at 10 digits.
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("here it is 555 123 4567 done"),
            "here it is 555-123-4567 done"
        )
    }

    // MARK: - Learned style preference

    func testParenthesizedStyleGroupsTenDigits() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("call me at 5551234567", style: .parenthesized),
            "call me at (555) 123-4567"
        )
    }

    func testDottedStyleGroupsTenDigits() {
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("call me at 5551234567", style: .dotted),
            "call me at 555.123.4567"
        )
    }

    func testStyleNameMappingFallsBackToHyphenated() {
        XCTAssertEqual(PhoneNumberRecomposer.style(named: "parenthesized"), .parenthesized)
        XCTAssertEqual(PhoneNumberRecomposer.style(named: "dotted"), .dotted)
        XCTAssertEqual(PhoneNumberRecomposer.style(named: "unknown"), .hyphenated)
        XCTAssertEqual(PhoneNumberRecomposer.style(named: nil), .hyphenated)
    }
}
