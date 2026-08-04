import XCTest
@testable import Resonant

final class NotchIssuePresentationTests: XCTestCase {
    func testNoSpeechFromNamedMicrophoneDoesNotRenderAsUnavailable() {
        let presentation = notchIssuePresentation(
            message: "No speech recognized from MacBook Pro Microphone.",
            subtype: .transcription
        )

        XCTAssertEqual(presentation.title, "No speech detected")
        XCTAssertEqual(presentation.actionLabel, "Check Mic")
    }

    func testSpeechDetectedButNoTextDoesNotRenderAsNoSpeech() {
        let presentation = notchIssuePresentation(
            message: "Speech was detected from MacBook Pro Microphone (1.2s), but no text was produced.",
            subtype: .transcription
        )

        XCTAssertEqual(presentation.title, "Transcription missed speech")
        XCTAssertEqual(presentation.actionLabel, "Settings")
    }

    func testInterruptedRecordingDoesNotRenderAsMicrophoneUnavailable() {
        let presentation = notchIssuePresentation(
            message: "Recording interrupted",
            subtype: .transcription
        )

        XCTAssertEqual(presentation.title, "Recording interrupted")
        XCTAssertEqual(presentation.detail, "Retry, or open Dictation settings if this keeps happening.")
    }

    func testStartFailureStillRendersAsMicrophoneUnavailable() {
        let presentation = notchIssuePresentation(
            message: "Could not start MacBook Pro Microphone",
            subtype: .microphone
        )

        XCTAssertEqual(presentation.title, "Microphone unavailable")
        XCTAssertEqual(presentation.actionLabel, "Check Mic")
    }

    func testRetryableTranscriptionFailureOffersRetryAction() {
        let presentation = notchIssuePresentation(
            message: "Speech was detected from MacBook Pro Microphone (1.2s), but no text was produced.",
            subtype: .transcription,
            offersRetry: true
        )

        XCTAssertEqual(presentation.actionLabel, "Retry")
        XCTAssertTrue(presentation.performsRetry)
        XCTAssertEqual(presentation.title, "Transcription missed speech")
    }

    func testRetryableModelFailureOffersRetryAction() {
        let presentation = notchIssuePresentation(
            message: "Local model not ready",
            subtype: .model,
            offersRetry: true
        )

        XCTAssertEqual(presentation.actionLabel, "Retry")
        XCTAssertTrue(presentation.performsRetry)
    }

    func testRetryIsNotOfferedForMicrophoneFailures() {
        // Mic/start failures have no surviving audio to retry — the action
        // must stay a settings/device affordance.
        let presentation = notchIssuePresentation(
            message: "Could not start MacBook Pro Microphone",
            subtype: .microphone,
            offersRetry: true
        )

        XCTAssertEqual(presentation.actionLabel, "Check Mic")
        XCTAssertFalse(presentation.performsRetry)
    }

    func testNoRetryActionWithoutSurvivingClip() {
        let presentation = notchIssuePresentation(
            message: "Speech was detected from MacBook Pro Microphone (1.2s), but no text was produced.",
            subtype: .transcription,
            offersRetry: false
        )

        XCTAssertEqual(presentation.actionLabel, "Settings")
        XCTAssertFalse(presentation.performsRetry)
    }
}
