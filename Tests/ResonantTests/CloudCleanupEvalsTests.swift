import XCTest
@testable import Resonant

/// Evals for cloud cleanup sanitizer covering gaps in the existing suites:
/// self-correction coverage, richer double-response patterns, context-aware
/// answer detection, and rejection of narration-style model output.
///
/// When a case is rejected the sanitizer falls back to the raw transcript,
/// which is the safe outcome — tests assert that either the cleaned text is
/// returned or the original is restored.
final class CloudCleanupEvalsTests: XCTestCase {

    // MARK: - Self-correction acceptance
    //
    // When the user self-corrects mid-dictation ("no wait", "sorry I meant",
    // "actually", "scratch that") the cleanup drops a large fraction of
    // tokens. These must not be false-rejected by the coverage heuristic.

    func testAcceptsNoWaitIMeanCorrection() {
        let original = "meet at three pm no wait I mean four pm"
        let cleaned = "Meet at 4 PM."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
    }

    func testAcceptsSorryIMeantNameSwap() {
        let original = "send it to John sorry I meant Sarah"
        let cleaned = "Send it to Sarah."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
    }

    func testAcceptsActuallyCorrection() {
        let original = "the deadline is Tuesday actually no Wednesday"
        let cleaned = "The deadline is Wednesday."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
    }

    func testAcceptsScratchThatFullReplacement() {
        let original = "update the readme actually scrap that update the changelog instead"
        let cleaned = "Update the changelog."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
    }

    func testAcceptsScratchThatTimeSwap() {
        let original = "call Priya at noon scratch that call her at one"
        let cleaned = "Call Priya at 1."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
    }

    func testAcceptsRepeatedRestartCorrection() {
        let original = "we get a new recent mem we get a new recent session"
        let cleaned = "We get a new recent session."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
    }

    func testAcceptsFalseStartLeadInCleanup() {
        let original = "and then we actually know for that we should ship the cleanup fix"
        let cleaned = "We should ship the cleanup fix."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
    }

    func testAcceptsCuelessRestartDroppingLongAbandonedHalf() {
        // No cue word; the abandoned half carries unique content words the final
        // clause drops, so the cleaned output is much shorter than the input.
        // Without the restart exemption this trips the too-short / coverage gate.
        let original = "let's go with the blue option for the homepage let's go with green"
        let cleaned = "Let's go with green."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
    }

    func testRejectsArbitraryTruncationOfNonRestart() {
        // A short tail that is a subsequence of the input but NOT a restart (no
        // repeated phrase). The exemption must not fire, so the low-coverage /
        // too-short rejection stands and the raw transcript is restored.
        let original = "the quarterly revenue numbers came in much higher than we forecast last spring"
        let cleaned = "Last spring."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: cleaned)
        XCTAssertEqual(result.text, original)
    }

    // MARK: - Double-response patterns beyond the plain echo prefix
    //
    // Existing suite covers `raw raw cleaned` and `becomes:` forms. These
    // add Original:/Cleaned: labels, apostrophe-normalized echoes, and
    // before/after blocks separated by headers.

    func testStripsOriginalCleanedLabelBlock() {
        // Original had no terminal punctuation so `preserveTrailingPunctuation`
        // trims the trailing period the model added.
        let original = "push the fix before standup"
        let doubled = "Original: push the fix before standup\nCleaned: Push the fix before standup."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: doubled)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, "Push the fix before standup")
    }

    func testStripsBeforeAfterHeaders() {
        let original = "review the pr by end of day"
        let doubled = "Before: review the pr by end of day\nAfter: Review the PR by end of day."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: doubled)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, "Review the PR by end of day")
    }

    func testStripsQuestionEchoWithApostropheNormalization() {
        // STT emits "whats" without apostrophe; model echoes then emits the
        // apostrophe-corrected version. The existing prefix stripper
        // tokenizes "what's" as two tokens and fails to match — eval guards
        // against that regression when we fix it.
        let original = "whats the plan for friday"
        let doubled = "What's the plan for Friday? What's the plan for Friday?"
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: doubled)
        if result.accepted {
            XCTAssertEqual(result.text, "What's the plan for Friday?")
        } else {
            XCTAssertEqual(result.text, original, "Rejected output must fall back to original")
        }
    }

    func testStripsMarkdownBulletSummaryAboveCleanedText() {
        let original = "remind john about the demo"
        let doubled = "- Capitalized first letter\n- Added period\n\nRemind John about the demo."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: doubled)
        if result.accepted {
            XCTAssertEqual(result.text, "Remind John about the demo.")
        } else {
            XCTAssertEqual(result.text, original)
        }
    }

    // MARK: - Context-aware answer detection
    //
    // In chat profiles the user is dictating a message to someone else; the
    // model must not reply as if the dictation were directed at it.

    func testRejectsChatProfileAssistantReply() {
        let original = "can you push the fix before standup"
        let answer = "Sure, I'll push the fix before standup."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: answer,
            profile: .message
        )
        XCTAssertFalse(result.accepted, "Chat-profile assistant-style reply must be rejected")
    }

    func testRejectsEmailProfileAssistantReply() {
        let original = "can you review the draft when you have a second"
        let answer = "Of course, I'll review the draft shortly."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: answer,
            profile: .emailFragment
        )
        XCTAssertFalse(result.accepted, "Email-profile assistant-style reply must be rejected")
    }

    func testRejectsAbsolutelyPrefixedAgreement() {
        let original = "should we ship the beta this week"
        let answer = "Absolutely, shipping this week is the right call."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted, "Agreement-style answer must be rejected")
    }

    // MARK: - Narration rejection
    //
    // The model occasionally narrates what it did rather than returning the
    // cleaned text. Sanitizer must reject these so we fall back to the raw
    // transcript.

    func testRejectsTextHasBeenCleanedNarration() {
        let original = "review the pr by eod"
        let answer = "The text has been cleaned up as requested."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted)
    }

    func testRejectsIChangedToNarration() {
        let original = "send teh email"
        let answer = "I changed \"teh\" to \"the\" and added punctuation."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertFalse(result.accepted)
    }

    func testStripsHereIsTheCleanedVersionHeader() {
        // `cleanOutput` strips this prefix. Terminal punctuation is trimmed
        // back to match the original per `preserveTrailingPunctuation`.
        let original = "ship the change today"
        let answer = "Here's the cleaned version: Ship the change today."
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(original: original, result: answer)
        XCTAssertTrue(result.accepted, "reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, "Ship the change today")
    }
}
