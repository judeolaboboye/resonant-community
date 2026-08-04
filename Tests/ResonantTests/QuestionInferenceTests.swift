import XCTest
@testable import Resonant

final class QuestionInferenceTests: XCTestCase {

    // MARK: - Auxiliary inversion

    func testCanYouBecomesQuestion() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Can you send me the file."),
            "Can you send me the file?"
        )
    }

    func testIsTheBuildGreenBecomesQuestion() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Is the build green."),
            "Is the build green?"
        )
    }

    func testNegativeContractionBecomesQuestion() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Isn't that the same bug."),
            "Isn't that the same bug?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "Didn't you see it."),
            "Didn't you see it?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "Doesn't the build pass."),
            "Doesn't the build pass?"
        )
    }

    func testWillDoStaysStatement() {
        XCTAssertEqual(QuestionInference.apply(to: "Will do."), "Will do.")
    }

    func testCouldBeStaysStatement() {
        XCTAssertEqual(QuestionInference.apply(to: "Could be."), "Could be.")
    }

    // MARK: - Do/have inversion vs imperative

    func testDidYouBecomesQuestion() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Did you see the message."),
            "Did you see the message?"
        )
    }

    func testDidTheBuildPassBecomesQuestion() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Did the build pass."),
            "Did the build pass?"
        )
    }

    func testDoItNowStaysImperative() {
        XCTAssertEqual(QuestionInference.apply(to: "Do it now."), "Do it now.")
    }

    func testHaveYouTriedBecomesQuestion() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Have you tried restarting."),
            "Have you tried restarting?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "Has the deploy finished."),
            "Has the deploy finished?"
        )
    }

    func testHaveItReadyStaysImperative() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Have it ready by monday."),
            "Have it ready by monday."
        )
    }

    func testHadTheMeetingStaysStatement() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Had the meeting earlier."),
            "Had the meeting earlier."
        )
    }

    // MARK: - Wh-openers

    func testWhatTimeIsItBecomesQuestion() {
        XCTAssertEqual(
            QuestionInference.apply(to: "What time is it."),
            "What time is it?"
        )
    }

    func testHowAreYouBecomesQuestion() {
        XCTAssertEqual(QuestionInference.apply(to: "How are you."), "How are you?")
    }

    func testWhSubjectClauseStaysStatement() {
        XCTAssertEqual(
            QuestionInference.apply(to: "What we need is more time."),
            "What we need is more time."
        )
    }

    // MARK: - Tag endings

    func testTagEndingBecomesQuestion() {
        XCTAssertEqual(
            QuestionInference.apply(to: "That works, right."),
            "That works, right?"
        )
    }

    func testRightWithoutCommaStaysStatement() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Turn right."),
            "Turn right."
        )
    }

    // MARK: - Multi-sentence and edge cases

    func testOnlyQuestionSentenceFlipsInMultiSentenceText() {
        XCTAssertEqual(
            QuestionInference.apply(to: "I pushed the fix. Can you verify."),
            "I pushed the fix. Can you verify?"
        )
    }

    func testDecimalsAreNotSentenceBoundaries() {
        XCTAssertEqual(
            QuestionInference.apply(to: "It costs 2.5 million. Should we proceed."),
            "It costs 2.5 million. Should we proceed?"
        )
    }

    func testMultiLineTextFlipsPerLine() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Update is out.\n\nCan you test it."),
            "Update is out.\n\nCan you test it?"
        )
    }

    func testExistingQuestionMarkUntouched() {
        let text = "Are we done?"
        XCTAssertEqual(QuestionInference.apply(to: text), text)
    }

    func testExplicitUnterminatedPermissionAddsOnlySemanticQuestionMark() {
        XCTAssertEqual(
            QuestionInference.apply(
                to: "Can you ship the update",
                appendWhenUnterminated: true
            ),
            "Can you ship the update?"
        )
        XCTAssertEqual(
            QuestionInference.apply(
                to: "Can you ship the update?",
                appendWhenUnterminated: true
            ),
            "Can you ship the update?"
        )
        XCTAssertEqual(
            QuestionInference.apply(
                to: "Ship the update",
                appendWhenUnterminated: true
            ),
            "Ship the update"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "Can you ship the update"),
            "Can you ship the update",
            "the caller must explicitly authorize appending punctuation"
        )
    }

    func testPlainStatementUntouched() {
        let text = "The deploy finished without errors."
        XCTAssertEqual(QuestionInference.apply(to: text), text)
    }

    // MARK: - Conservative positive evidence

    func testAuxiliaryQuestionsRequireAnObservableSubject() {
        let questions: [(String, String)] = [
            ("Is it ready.", "Is it ready?"),
            ("Can the build wait.", "Can the build wait?"),
            ("Will there be downtime.", "Will there be downtime?"),
            ("Can Resonant export this.", "Can Resonant export this?"),
            ("Is Sam joining.", "Is Sam joining?"),
        ]
        for (input, expected) in questions {
            XCTAssertEqual(QuestionInference.apply(to: input), expected, input)
        }

        let statements = [
            "Should work now.",
            "Would love an update.",
            "Could use help.",
            "Can confirm.",
            "Must remember the logs.",
        ]
        for statement in statements {
            XCTAssertEqual(QuestionInference.apply(to: statement), statement, statement)
        }
    }

    func testMayPermissionQuestionsDoNotTurnWishesIntoQuestions() {
        XCTAssertEqual(
            QuestionInference.apply(to: "May I continue."),
            "May I continue?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "May we proceed."),
            "May we proceed?"
        )

        let wishes = [
            "May the force be with you.",
            "May you live long.",
            "May he rest in peace.",
            "May it be enough.",
        ]
        for wish in wishes {
            XCTAssertEqual(QuestionInference.apply(to: wish), wish, wish)
        }
    }

    func testDoNegativeImperativesFailClosedWithoutAWhOpener() {
        let imperatives = [
            "Don't forget the logs.",
            "Don't you forget the logs.",
            "Doesn't matter anymore.",
        ]
        for imperative in imperatives {
            XCTAssertEqual(QuestionInference.apply(to: imperative), imperative, imperative)
        }

        XCTAssertEqual(
            QuestionInference.apply(to: "Why don't you check the logs."),
            "Why don't you check the logs?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "Why don’t you check the logs."),
            "Why don’t you check the logs?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "Isn’t that ready."),
            "Isn’t that ready?"
        )
    }

    // MARK: - Wh questions and embedded clauses

    func testWhSubjectQuestionsRemainSupported() {
        let questions: [(String, String)] = [
            ("Who broke the build.", "Who broke the build?"),
            ("Who can attend the meeting.", "Who can attend the meeting?"),
            ("What can improve outcomes.", "What can improve outcomes?"),
            ("What happened.", "What happened?"),
            ("Which failed.", "Which failed?"),
            ("Which build did fail.", "Which build did fail?"),
            ("How many users are affected.", "How many users are affected?"),
        ]
        for (input, expected) in questions {
            XCTAssertEqual(QuestionInference.apply(to: input), expected, input)
        }
    }

    func testEmbeddedWhClausesRemainStatements() {
        let statements = [
            "What matters is the result.",
            "What is needed is more time.",
            "What is possible changes daily.",
            "What works today might fail tomorrow.",
            "Who gets access depends on role.",
            "Who can attend gets priority.",
            "Who can attend qualifies automatically.",
            "Who can attend qualifies.",
            "Who can attend deserves access.",
            "Who can attend wins.",
            "What is good helps.",
            "Who is selected depends on the vote.",
            "Who is selected receives access.",
            "Where the data lives matters.",
            "When the job runs depends on load.",
            "How this works is simple.",
            "Which option we choose is irrelevant.",
        ]
        for statement in statements {
            XCTAssertEqual(QuestionInference.apply(to: statement), statement, statement)
        }
    }

    func testTagQuestionsNormalizeOptionalTerminalPunctuation() {
        for text in ["That works, right", "That works, right.", "That works, right?"] {
            XCTAssertTrue(QuestionInference.isQuestion(text), text)
        }
        XCTAssertEqual(
            QuestionInference.apply(to: "That works, right."),
            "That works, right?"
        )
    }

    func testIncompleteWhFragmentsFailClosed() {
        let fragments = [
            "What time is.",
            "How many users are.",
            "Where can confirm.",
        ]
        for fragment in fragments {
            XCTAssertEqual(QuestionInference.apply(to: fragment), fragment, fragment)
        }
    }

    // MARK: - Semantic sentence boundaries

    func testAbbreviationsInitialsAndDecimalsDoNotSplitQuestions() {
        let questions: [(String, String)] = [
            ("Can you ask Dr. Smith.", "Can you ask Dr. Smith?"),
            ("Can you ask Ms. Jones.", "Can you ask Ms. Jones?"),
            ("Can T. Smith join.", "Can T. Smith join?"),
            ("Can the U.S. team join.", "Can the U.S. team join?"),
            ("Should we approve 2.5 million.", "Should we approve 2.5 million?"),
        ]
        for (input, expected) in questions {
            XCTAssertEqual(QuestionInference.apply(to: input), expected, input)
        }
    }

    func testSentenceFinalAbbreviationDoesNotHideFollowingQuestion() {
        XCTAssertEqual(
            QuestionInference.apply(to: "We checked logs, traces, etc. Can you verify."),
            "We checked logs, traces, etc. Can you verify?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "We contacted Acme Inc. Can you follow up."),
            "We contacted Acme Inc. Can you follow up?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "We operate in the U.S. Can you verify."),
            "We operate in the U.S. Can you verify?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "We operate in the U.S. can you verify."),
            "We operate in the U.S. can you verify?"
        )
    }

    func testQuestionEndingInAbbreviationPreservesItsPeriod() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Can you contact Acme Inc."),
            "Can you contact Acme Inc.?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "Are you in the U.S."),
            "Are you in the U.S.?"
        )
    }

    func testOrdinaryNoAndSingleLetterEndingsUseAQuestionMarkOnly() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Is the answer no."),
            "Is the answer no?"
        )
        XCTAssertEqual(
            QuestionInference.apply(to: "Is the answer B."),
            "Is the answer B?"
        )
    }

    func testFinalSemanticSentenceUsesRealAndFlattenedBoundaries() {
        XCTAssertEqual(
            QuestionInference.finalSemanticSentence(in: "Status sent. Can you verify"),
            "Can you verify"
        )
        XCTAssertEqual(
            QuestionInference.finalSemanticSentence(in: "Can you verify. Status sent"),
            "Status sent"
        )
        XCTAssertEqual(
            QuestionInference.finalSemanticSentence(in: "Status sent\nCan you verify"),
            "Can you verify"
        )
        XCTAssertEqual(
            QuestionInference.finalSemanticSentence(in: "Status sent; Can you verify"),
            "Can you verify"
        )
        XCTAssertEqual(
            QuestionInference.finalSemanticSentence(in: "Context: Can you verify"),
            "Can you verify"
        )
        XCTAssertEqual(
            QuestionInference.finalSemanticSentence(in: "Thinking… Can you verify"),
            "Can you verify"
        )
    }

    func testWillNameAmbiguityFailsClosed() {
        XCTAssertEqual(
            QuestionInference.apply(to: "Will Smith stars in the film."),
            "Will Smith stars in the film."
        )
    }
}
