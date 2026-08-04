import XCTest
@testable import Resonant

final class LearnedCasingApplierTests: XCTestCase {

    func testAppliesLearnedWordCasing() {
        XCTAssertEqual(
            LearnedCasingApplier.apply(["figma": "Figma"], to: "open the figma file"),
            "open the Figma file"
        )
    }

    func testEmptyCasingsLeaveTextUntouched() {
        XCTAssertEqual(
            LearnedCasingApplier.apply([:], to: "open the figma file"),
            "open the figma file"
        )
    }

    func testDoesNotRecaseDomainLeadingLabel() {
        XCTAssertEqual(
            LearnedCasingApplier.apply(["substack": "Substack"], to: "visit substack.com today"),
            "visit substack.com today"
        )
    }

    func testDoesNotRecaseEmailLocalPartOrHandle() {
        XCTAssertEqual(
            LearnedCasingApplier.apply(["figma": "Figma"], to: "mail figma@example.com or @figma"),
            "mail figma@example.com or @figma"
        )
    }

    func testLowercasePreferenceSkipsSentenceInitialPosition() {
        XCTAssertEqual(
            LearnedCasingApplier.apply(["vim": "vim"], to: "I use Vim daily. Vim is fast."),
            "I use vim daily. Vim is fast."
        )
    }

    func testRecasesFullEmailAddress() {
        XCTAssertEqual(
            LearnedCasingApplier.apply(
                ["john.doe@company.com": "John.Doe@Company.com"],
                to: "reach me at john.doe@company.com please"
            ),
            "reach me at John.Doe@Company.com please"
        )
    }

    func testEmailPreferenceWinsOverEmbeddedWordPreference() {
        XCTAssertEqual(
            LearnedCasingApplier.apply(
                [
                    "john.doe@company.com": "John.Doe@Company.com",
                    "company": "COMPANY",
                ],
                to: "john.doe@company.com runs the company"
            ),
            "John.Doe@Company.com runs the COMPANY"
        )
    }
}
