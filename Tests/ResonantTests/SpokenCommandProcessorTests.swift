import XCTest
@testable import Resonant

final class SpokenCommandProcessorTests: XCTestCase {

    // MARK: - New line

    func testNewLineBecomesLineBreak() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("buy milk new line buy eggs"),
            "buy milk\nbuy eggs"
        )
    }

    func testNewLineStripsAutoPunctuationArtifacts() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("buy milk, new line, buy eggs"),
            "buy milk\nbuy eggs"
        )
    }

    func testNewLineHandlesSentenceCaseFromASR() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("Buy milk. New line. Buy eggs."),
            "Buy milk.\nBuy eggs."
        )
    }

    func testNewlineSingleWordIsRecognized() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("buy milk newline buy eggs"),
            "buy milk\nbuy eggs"
        )
    }

    func testNextLineIsRecognized() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("buy milk next line buy eggs"),
            "buy milk\nbuy eggs"
        )
    }

    // MARK: - New paragraph

    func testNewParagraphBecomesBlankLine() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("That's the update. New paragraph. Let me know if you have questions."),
            "That's the update.\n\nLet me know if you have questions."
        )
    }

    func testNewParagraphKeepsSentencePunctuationBeforeBreak() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("Is that okay? New paragraph thanks again"),
            "Is that okay?\n\nthanks again"
        )
    }

    // MARK: - Bullet points

    func testBulletPointsBuildList() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("we need bullet point milk bullet point eggs bullet point bread"),
            "we need\n- milk\n- eggs\n- bread"
        )
    }

    func testLeadingBulletPointStartsList() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("bullet point milk bullet point eggs"),
            "- milk\n- eggs"
        )
    }

    func testBulletPointAfterColonKeepsColon() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("we need the following: bullet point milk bullet point eggs"),
            "we need the following:\n- milk\n- eggs"
        )
    }

    func testBulletPointStripsAutoPunctuationArtifacts() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("we need, bullet point, milk, bullet point, eggs"),
            "we need\n- milk\n- eggs"
        )
    }

    func testNewBulletVariantIsRecognized() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("bullet point milk new bullet eggs next bullet bread"),
            "- milk\n- eggs\n- bread"
        )
    }

    // MARK: - Prose guards

    func testDeterminerBlocksBulletCommand() {
        let input = "add a bullet point system to the app"
        XCTAssertEqual(SpokenCommandProcessor.process(input), input)
    }

    func testDeterminerBlocksNewLineCommand() {
        let input = "we're launching a new line of products"
        XCTAssertEqual(SpokenCommandProcessor.process(input), input)
    }

    func testPossessiveBlocksNewLineCommand() {
        let input = "check out our new line this fall"
        XCTAssertEqual(SpokenCommandProcessor.process(input), input)
    }

    func testFollowingOfBlocksCommand() {
        let input = "they announced new line of clothing"
        XCTAssertEqual(SpokenCommandProcessor.process(input), input)
    }

    func testDeterminerBlocksNewParagraphCommand() {
        let input = "start the new paragraph with a quote"
        XCTAssertEqual(SpokenCommandProcessor.process(input), input)
    }

    func testPluralBulletPointsNotTreatedAsCommand() {
        let input = "use bullet points to summarize"
        XCTAssertEqual(SpokenCommandProcessor.process(input), input)
    }

    // MARK: - Edge positions

    func testTrailingCommandIsDropped() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("buy milk new line"),
            "buy milk"
        )
    }

    func testTrailingBulletCommandIsDropped() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("bullet point milk bullet point"),
            "- milk"
        )
    }

    func testConsecutiveBreaksCollapse() {
        XCTAssertEqual(
            SpokenCommandProcessor.process("intro new paragraph new line body"),
            "intro\n\nbody"
        )
    }

    func testTextWithoutCommandsIsUntouched() {
        let input = "regular sentence with no commands at all"
        XCTAssertEqual(SpokenCommandProcessor.process(input), input)
    }

    // MARK: - TextFormatter integration

    func testFinalizeCapitalizesLineLeads() {
        XCTAssertEqual(
            TextFormatter.finalize(
                "buy milk\nbuy eggs",
                ensureTrailingPunctuation: true
            ),
            "Buy milk\nBuy eggs."
        )
    }

    func testFinalizeCapitalizesBulletItems() {
        XCTAssertEqual(
            TextFormatter.finalize(
                "we need\n- milk\n- eggs",
                ensureTrailingPunctuation: true
            ),
            "We need\n- Milk\n- Eggs"
        )
    }

    func testFinalizeSkipsListHeuristicsOnStructuredText() {
        // Explicit structure wins — comma-noun detection must not re-format.
        let input = "shopping\n- red apples, green oranges, yellow bananas, purple grapes"
        let result = TextFormatter.finalize(input, bulletPointsEnabled: true)
        XCTAssertTrue(result.hasPrefix("Shopping\n- "))
    }

    func testFinalizePreservesParagraphBreaks() {
        XCTAssertEqual(
            TextFormatter.finalize("first part.\n\nsecond part."),
            "First part.\n\nSecond part."
        )
    }
}
