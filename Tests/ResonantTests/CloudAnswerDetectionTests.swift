import XCTest
@testable import Resonant

/// Tests that the sanitizer rejects LLM outputs that "answer" the dictated text
/// instead of cleaning it. These cover the main failure modes observed with
/// Llama 4 Scout where the model interprets dictation as a question or request.
final class CloudAnswerDetectionTests: XCTestCase {

    // MARK: - Conversational opener prefixes

    func testRejectsYesPrefixAnswer() {
        let original = "can you review the PR by end of day"
        let answer = "Yes, I can review the PR by end of day."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'Yes, ...' answer to a question")
    }

    func testRejectsNoPrefixAnswer() {
        let original = "is the deployment done"
        let answer = "No, the deployment is not yet completed."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'No, ...' answer to a question")
    }

    func testRejectsYouShouldAnswer() {
        let original = "what should I do about the failing tests"
        let answer = "You should check the test logs and fix the failing assertions."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'You should...' advice response")
    }

    func testRejectsItDependsAnswer() {
        let original = "should we use postgres or redis for this"
        let answer = "It depends on your use case. PostgreSQL is better for structured data while Redis is ideal for caching."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'It depends...' answer")
    }

    func testRejectsIRecommendAnswer() {
        let original = "how should we handle the migration"
        let answer = "I recommend running the migration during off-peak hours to minimize downtime."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'I recommend...' answer")
    }

    func testRejectsUnfortunatelyAnswer() {
        let original = "can we ship this by friday"
        let answer = "Unfortunately, shipping by Friday may not be feasible given the current timeline."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'Unfortunately...' answer")
    }

    func testRejectsThatDependsAnswer() {
        let original = "which database should we use"
        let answer = "That depends on the scale and requirements of your application."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'That depends...' answer")
    }

    // MARK: - Answer-to-question pattern

    func testRejectsDeclarativeAnswerToQuestion() {
        let original = "what time is the meeting tomorrow"
        let answer = "The meeting is scheduled for 3 PM tomorrow."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject declarative answer to a question")
    }

    func testRejectsTheStatusIsAnswer() {
        let original = "what's the status of the migration project"
        let answer = "The status of the migration project is currently in progress."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'The X is...' answer to a question")
    }

    // MARK: - Conversational promise patterns

    func testRejectsIllHelpAnswer() {
        // Only specific assistant verbs (help, assist, do that, take care) are
        // caught here — broader "I'll [verb]" matching would reject legitimate
        // STT apostrophe fixes ("ill send" → "I'll send").
        let original = "can you look into the deployment issue"
        let answer = "I'll help you look into the deployment issue."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'I'll help...' promise response")
    }

    func testRejectsIdBeHappyToAnswer() {
        let original = "can you look into the crash report"
        let answer = "I'd be happy to look into the crash report for you."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'I'd be happy to...' response")
    }

    // MARK: - Valid cleanups that should still pass

    func testAcceptsSimpleGrammarFix() {
        let original = "can you review the pull request by end of day"
        let cleaned = "Can you review the pull request by end of day"
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "Should accept simple grammar/casing fix")
    }

    func testAcceptsQuestionCleanedAsQuestion() {
        let original = "whats the status of the migration project"
        let cleaned = "What's the status of the migration project?"
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "Should accept question cleaned as question")
    }

    func testAcceptsStatementStartingWithThe() {
        // Non-question input starting with "the" should not be falsely rejected
        let original = "the deployment is almost done"
        let cleaned = "The deployment is almost done."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "Should accept statement that legitimately starts with 'the'")
    }

    func testAcceptsInputStartingWithYes() {
        // If the original itself starts with "yes", cleaning should pass
        let original = "yes I can make that meeting"
        let cleaned = "Yes, I can make that meeting."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "Should accept cleanup when original starts with 'yes'")
    }

    func testAcceptsInputStartingWithItIs() {
        let original = "it's ready to ship I think"
        let cleaned = "It's ready to ship, I think."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "Should accept cleanup when original starts with 'it's'")
    }

    func testAcceptsInputStartingWithYouShould() {
        // If the user is dictating advice to someone, the "you should" is theirs
        let original = "you should check the logs before deploying"
        let cleaned = "You should check the logs before deploying."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "Should accept cleanup when original starts with 'you should'")
    }

    func testAcceptsShortQuestionCleanup() {
        let original = "when is the standup"
        let cleaned = "When is the standup?"
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "Should accept question with added punctuation")
    }

    func testBypassesCloudCleanupForVeryShortResponses() {
        let cases = [
            "yeah",
            "thank you",
            "i can do that",
            "sounds good"
        ]

        for transcript in cases {
            XCTAssertTrue(
                CloudProcessingSupport.shouldBypassCloudCleanupForShortDictation(
                    transcript: transcript,
                    profile: .message
                ),
                transcript
            )
        }
    }

    func testDoesNotBypassCloudCleanupForLongerDictation() {
        XCTAssertFalse(
            CloudProcessingSupport.shouldBypassCloudCleanupForShortDictation(
                transcript: "can you review the pull request by end of day",
                profile: .message
            )
        )
    }

    func testDoesNotBypassCloudCleanupForShortSelfCorrection() {
        XCTAssertFalse(
            CloudProcessingSupport.shouldBypassCloudCleanupForShortDictation(
                transcript: "three no wait four",
                profile: .default
            )
        )
    }

    // MARK: - Bare acknowledgment replies (chat-tuned LLM treating dictation as a turn)

    func testRejectsBareOkayAcknowledgment() {
        let original = "let me know once the deploy finishes so I can verify"
        let answer = "Okay."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject bare 'Okay.' acknowledgment")
    }

    func testRejectsNoChangesNeededAcknowledgment() {
        let original = "let me know once the deploy finishes so I can verify"
        let answer = "No changes needed."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'No changes needed.' acknowledgment")
    }

    func testSelectionTransformRejectsNoChangesNeededAcknowledgment() {
        let selectedText = "let me know once the deploy finishes so I can verify"
        let answer = "No changes needed."
        let result = CloudProcessingSupport.sanitizeSelectionTransformOutput(
            selectedText: selectedText,
            result: answer,
            command: "clean this up"
        )
        XCTAssertFalse(result.accepted, "Should reject 'No changes needed.' transform response")
    }

    func testRejectsBareYeahAcknowledgment() {
        let original = "we should probably batch these requests on the client"
        let answer = "Yeah, that makes sense."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'Yeah, that makes sense.' acknowledgment")
    }

    func testRejectsBareAlrightAcknowledgment() {
        let original = "go ahead and merge the branch when CI is green"
        let answer = "Alright, sounds good."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'Alright, sounds good.' acknowledgment")
    }

    func testRejectsGotItAcknowledgment() {
        let original = "ship the patch and update the changelog before EOD"
        let answer = "Got it, I will take care of it."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'Got it...' acknowledgment")
    }

    func testRejectsSoundsGoodAcknowledgment() {
        let original = "lets sync tomorrow morning to walk through the changes"
        let answer = "Sounds good, talk then."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Should reject 'Sounds good...' acknowledgment")
    }

    func testAcceptsInputStartingWithOkay() {
        let original = "okay so the next thing we need to do is migrate the schema"
        let cleaned = "Okay, so the next thing we need to do is migrate the schema."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "Should accept cleanup when original starts with 'okay'")
    }

    func testAcceptsInputStartingWithAlright() {
        let original = "alright lets get this PR merged before standup"
        let cleaned = "Alright, let's get this PR merged before standup."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "Should accept cleanup when original starts with 'alright'")
    }
}
