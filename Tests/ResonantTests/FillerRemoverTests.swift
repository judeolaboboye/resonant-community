import XCTest
@testable import Resonant

final class FillerRemoverTests: XCTestCase {

    // MARK: - Inline repairs: "X or Y, sorry" → "Y"

    func testChoiceRepairSwapsSecondWord() {
        XCTAssertEqual(
            repair("I'm using a Yeti external speaker or microphone, sorry."),
            "I'm using a Yeti external microphone."
        )
    }

    func testChoiceRepairWithoutCommaBeforeSorry() {
        XCTAssertEqual(
            repair("grab the red or blue sorry folder"),
            "grab the blue folder"
        )
    }

    func testPlainChoiceWithoutSorryUntouched() {
        XCTAssertEqual(
            repair("we can have pizza or pasta for lunch"),
            "we can have pizza or pasta for lunch"
        )
    }

    // MARK: - Inline repairs: "X, I mean Y" → "Y"

    func testIMeanSwapsSingleWordWithComma() {
        XCTAssertEqual(
            repair("meet on Tuesday, I mean Wednesday"),
            "meet on Wednesday"
        )
    }

    func testIMeanWithoutCommaLeavesTextAlone() {
        // "yeah I mean yes" is filler, not a correction — no comma guard.
        XCTAssertEqual(
            repair("yeah I mean yes"),
            "yeah I mean yes"
        )
    }

    // MARK: - Inline repairs: "X, no, Y" -> "Y"

    func testNoCommaSwapsSingleWordCorrection() {
        XCTAssertEqual(
            repair("meet on Monday, no, Tuesday"),
            "meet on Tuesday"
        )
    }

    func testNoWithoutCommaDoesNotEatValidNegativePhrase() {
        XCTAssertEqual(
            repair("there are no Tuesday meetings"),
            "there are no Tuesday meetings"
        )
    }

    // MARK: - Inline repairs: "X, or rather Y" → "Y"

    func testOrRatherSwapsSingleWordWithComma() {
        XCTAssertEqual(
            repair("he left Monday, or rather Tuesday"),
            "he left Tuesday"
        )
    }

    func testOrRatherSwapsSingleWordWithoutComma() {
        XCTAssertEqual(
            repair("he left Monday or rather Tuesday"),
            "he left Tuesday"
        )
    }

    // MARK: - Inline repairs: "X no actually Y" → "Y"

    func testNoActuallySwapsSingleWordWithoutDroppingSentenceFrame() {
        XCTAssertEqual(
            repair("meet on Tuesday no actually Wednesday"),
            "meet on Wednesday"
        )
    }

    func testActuallyNoSwapsSingleWordWithoutDroppingSentenceFrame() {
        XCTAssertEqual(
            repair("the deadline is Tuesday actually no Wednesday"),
            "the deadline is Wednesday"
        )
    }

    func testNoWaitSwapsSingleWordWithoutDroppingSentenceFrame() {
        XCTAssertEqual(
            repair("set it to blue no wait green"),
            "set it to green"
        )
    }

    func testWaitButActuallySwapsSingleWordWithoutDroppingSentenceFrame() {
        XCTAssertEqual(
            repair("set it to blue wait but actually green"),
            "set it to green"
        )
    }

    func testButActuallySwapsSingleWordWithoutDroppingSentenceFrame() {
        XCTAssertEqual(
            repair("send it Monday but actually Tuesday"),
            "send it Tuesday"
        )
    }

    // MARK: - Phrase-level repairs

    func testScratchThatWithReplacementStripsAbandonedPrefix() {
        XCTAssertEqual(
            repair("call Priya at noon scratch that call her at one"),
            "Call her at one"
        )
    }

    func testScratchThisWithReplacementStripsAbandonedPrefix() {
        XCTAssertEqual(
            repair("use the first paragraph scratch this use the second paragraph"),
            "Use the second paragraph"
        )
    }

    func testNeverMindWithReplacementStripsAbandonedPrefix() {
        XCTAssertEqual(
            repair("use the old plan never mind use the revised plan"),
            "Use the revised plan"
        )
    }

    // MARK: - Repeated restart repairs

    func testRepeatedRestartDropsAbandonedWord() {
        XCTAssertEqual(
            repair("we get a new recent mem we get a new recent session"),
            "We get a new recent session"
        )
    }

    func testRepeatedRestartPreservesLeadingContext() {
        XCTAssertEqual(
            repair("Make sure on the left hand side we get a new recent mem we get a new recent session"),
            "Make sure on the left hand side we get a new recent session"
        )
    }

    func testRepeatedRestartIgnoresUnsafeAbandonedConjunction() {
        XCTAssertEqual(
            repair("we get a new recent and we get a new recent session"),
            "we get a new recent and we get a new recent session"
        )
    }

    func testNeverMindWithoutReplacementDoesNotEraseTranscript() {
        let transcript = "ship the first version actually never mind"
        XCTAssertEqual(repair(transcript), transcript)
    }

    func testNeverMindButDoesNotStripPrefix() {
        let transcript = "sometimes we say actually never mind but keep the rest"
        XCTAssertEqual(repair(transcript), transcript)
    }

    func testWaitActuallyBeforeNeverMindButDoesNotStripPrefix() {
        let transcript = "let's use Tuesday wait actually never mind but keep exploring"
        XCTAssertEqual(repair(transcript), transcript)
    }

    // MARK: - Adjacent stutter collapse

    func testCollapsesDoubledArticle() {
        XCTAssertEqual(
            repair("I want the the button to look pressed"),
            "I want the button to look pressed"
        )
    }

    func testCollapsesRecapitalizedArticleRestart() {
        XCTAssertEqual(
            repair("move it to the user and the The step should show channels"),
            "move it to the user and the step should show channels"
        )
    }

    func testCollapsesDoubledSubjectPronoun() {
        XCTAssertEqual(
            repair("or I I don't know if he's good"),
            "or I don't know if he's good"
        )
    }

    func testCollapsesTripledPronoun() {
        XCTAssertEqual(
            repair("I I I think we should ship it"),
            "I think we should ship it"
        )
    }

    func testCollapsesDoubledContraction() {
        XCTAssertEqual(
            repair("it's it's probably something we need to do"),
            "it's probably something we need to do"
        )
    }

    // MARK: - Stutter collapse false-positive guards

    func testDoesNotCollapseDoubledAuxiliary() {
        // "had had" is grammatical (past perfect of "have").
        XCTAssertEqual(
            repair("the cake I had had went moldy"),
            "the cake I had had went moldy"
        )
    }

    func testDoesNotCollapseDoubledTo() {
        // "go to to what" — preposition + infinitive marker, both intended.
        XCTAssertEqual(
            repair("clear from what step we go to to what step we land on"),
            "clear from what step we go to to what step we land on"
        )
    }

    func testDoesNotCollapseDoubledThat() {
        XCTAssertEqual(
            repair("the thing that that he mentioned was wrong"),
            "the thing that that he mentioned was wrong"
        )
    }

    func testDoesNotCollapseEmphaticContentWord() {
        XCTAssertEqual(
            repair("that was very very good"),
            "that was very very good"
        )
    }

    func testDoesNotCollapseObjectPronounBeforeClauseSubject() {
        // "told you you should" — object pronoun then clause subject, valid.
        XCTAssertEqual(
            repair("I told you you should go now"),
            "I told you you should go now"
        )
    }

    func testDoesNotCollapseCollapsibleWordAcrossComma() {
        // A comma between the copies signals deliberate phrasing, not a stutter.
        XCTAssertEqual(
            repair("pick the, the second option please"),
            "pick the, the second option please"
        )
    }

    func testDoesNotCollapseArticleBeforeTitledProperNoun() {
        // "the The Office" / "the The North Face" are article + titled proper
        // noun, not stutters — the capital must survive.
        XCTAssertEqual(
            repair("we should watch the The Office reruns tonight"),
            "we should watch the The Office reruns tonight"
        )
        XCTAssertEqual(
            repair("buy the The North Face jacket today"),
            "buy the The North Face jacket today"
        )
    }

    func testPreservesBandNamedTheThe() {
        XCTAssertEqual(
            repair("I really love the band The The"),
            "I really love the band The The"
        )
    }

    func testCollapsesStutterButPreservesParagraphBreak() {
        // The stutter on the second line collapses; the paragraph break the
        // pause segmenter inserted upstream must survive cleanup.
        XCTAssertEqual(
            repair("That wraps up the update.\n\nThe the next topic is hiring."),
            "That wraps up the update.\n\nThe next topic is hiring."
        )
    }

    func testPreservesParagraphBreakWithNoStutter() {
        XCTAssertEqual(
            repair("First topic is done.\n\nSecond topic starts now."),
            "First topic is done.\n\nSecond topic starts now."
        )
    }

    // MARK: - Corrections across pause-inserted punctuation
    //
    // The pause before a self-correction routinely becomes a period — from
    // the model's own punctuation or pause segmentation — so repairs must
    // tolerate a sentence boundary sitting on top of the cue.

    func testActuallyNoSwapsAcrossPauseInsertedPeriod() {
        XCTAssertEqual(
            repair("the deadline is Tuesday. Actually no Wednesday."),
            "the deadline is Wednesday."
        )
    }

    func testNoWaitSwapsAcrossCommaAfterCue() {
        XCTAssertEqual(
            repair("set it to blue, no wait, green"),
            "set it to green"
        )
    }

    func testCrossBoundarySwapVetoedWhenReplacementOpensClause() {
        // Sentence-initial "No wait Sarah should join too" is an afterthought
        // clause, not a one-word replacement for "Tuesday".
        let transcript = "that's all for Tuesday. No wait Sarah should join too."
        XCTAssertEqual(repair(transcript), transcript)
    }

    func testStrongCueRetractsAcrossPauseInsertedPeriod() {
        XCTAssertEqual(
            repair("call Priya at noon. Scratch that call her at one."),
            "Call her at one."
        )
    }

    // MARK: - Sentence-scoped false starts

    func testStrongCueCorrectionPreservesEarlierSentence() {
        XCTAssertEqual(
            repair("Send the report to Alice. Call Priya at noon scratch that call her at one."),
            "Send the report to Alice. Call her at one."
        )
    }

    func testCorrectionRepairsOnLaterParagraph() {
        XCTAssertEqual(
            repair("First topic is done.\n\nUse the old plan never mind use the revised plan"),
            "First topic is done.\n\nUse the revised plan"
        )
    }

    func testWeakCueOpeningSentenceIsPreservedAsContent() {
        // A dictated reply like "actually no I disagree" carries the cue as
        // content — with nothing before it to retract, it must survive.
        let transcript = "actually no I disagree with him"
        XCTAssertEqual(repair(transcript), transcript)
    }

    func testWeakCueAfterSentenceBoundaryDoesNotEatPreviousSentence() {
        // Weak connective cues never reach back across a boundary; the
        // previous sentence may be exactly what the speaker meant to keep.
        let transcript = "Ship it Friday. Actually no let's revisit the plan tomorrow."
        XCTAssertEqual(repair(transcript), transcript)
    }

    func testStrongCueAtTextStartIsPreservedAsContent() {
        // "Scratch that off the list" — imperative content, nothing to retract.
        let transcript = "scratch that off the list please"
        XCTAssertEqual(repair(transcript), transcript)
    }

    // MARK: - Non-corrections pass through

    func testStandaloneSorryNotTreatedAsCorrection() {
        XCTAssertEqual(
            repair("I'm sorry I'm late"),
            "I'm sorry I'm late"
        )
    }

    func testSorryAfterChoiceOnlyFiresWithOrMarker() {
        // Without "or <word>" before it, trailing "sorry" is just an apology.
        XCTAssertEqual(
            repair("bring the folder, sorry"),
            "bring the folder, sorry"
        )
    }

    // MARK: - Helpers

    private func repair(_ text: String) -> String {
        FillerRemover().process(
            text,
            removeFillersEnabled: false,
            removeFalseStartsEnabled: true
        )
    }
}
