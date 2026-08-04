import XCTest
@testable import Resonant

/// Regression coverage for the residual defects from the 2026-07-28
/// pause-segmentation audit: statements flipped to questions, the Mei/May
/// homophone collision, and hyphenated-filler mangling.
final class PunctuationLooseEndsTests: XCTestCase {

    func testDontStatementIsNotFlippedToQuestion() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Don't show that we use exa search."),
            "Don't show that we use exa search."
        )
    }

    func testMayHomophoneOfContactNameIsNotFlippedToQuestion() {
        // "Mei, I need to follow up" mis-transcribed as "May I need to follow
        // up" — "May I" + a stative verb is not a permission question.
        XCTAssertEqual(
            QuestionInference.apply(to: "May I need to follow up."),
            "May I need to follow up."
        )
    }

    func testHyphenatedAcknowledgementSurvivesFillerRemoval() {
        let remover = FillerRemover()
        XCTAssertEqual(
            remover.process("Mm-hmm.", removeFillersEnabled: true, removeFalseStartsEnabled: true),
            "Mm-hmm."
        )
        XCTAssertEqual(
            remover.process("Mm-hmm, sounds good.", removeFillersEnabled: true, removeFalseStartsEnabled: true),
            "Mm-hmm, sounds good."
        )
    }
}
