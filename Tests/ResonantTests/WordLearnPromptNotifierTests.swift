import UserNotifications
import XCTest
@testable import Resonant

@MainActor
final class WordLearnPromptNotifierTests: XCTestCase {

    func testPairCooldownBlocksRepromptForADay() {
        let notifier = WordLearnPromptNotifier()
        let now = Date()

        XCTAssertTrue(notifier.shouldPrompt(spoken: "teece", now: now))
        notifier.markPrompted(spoken: "teece", now: now)

        XCTAssertFalse(notifier.shouldPrompt(
            spoken: "teece",
            now: now.addingTimeInterval(60 * 60)
        ))
        XCTAssertFalse(notifier.shouldPrompt(
            spoken: "TEECE",
            now: now.addingTimeInterval(60 * 60)
        ))
        XCTAssertTrue(notifier.shouldPrompt(
            spoken: "teece",
            now: now.addingTimeInterval(WordLearnPromptNotifier.promptCooldown + 1)
        ))
    }

    func testGlobalSpacingLimitsPromptBursts() {
        let notifier = WordLearnPromptNotifier()
        let now = Date()
        notifier.markPrompted(spoken: "teece", now: now)

        // A different pair right afterwards is still a burst.
        XCTAssertFalse(notifier.shouldPrompt(
            spoken: "grafanna",
            now: now.addingTimeInterval(60)
        ))
        XCTAssertTrue(notifier.shouldPrompt(
            spoken: "grafanna",
            now: now.addingTimeInterval(WordLearnPromptNotifier.minimumPromptSpacing + 1)
        ))
    }

    /// Correcting a word must never be the moment a new user first meets the
    /// macOS notification-permission dialog. Undetermined authorization now
    /// reports itself instead of triggering a request.
    func testUndeterminedAuthorizationBlocksInsteadOfRequesting() {
        XCTAssertEqual(
            WordLearnPromptNotifier.authorizationBlocker(for: .notDetermined),
            .authorizationNotDetermined
        )
        XCTAssertEqual(
            WordLearnPromptNotifier.authorizationBlocker(for: .denied),
            .authorizationDenied
        )
        XCTAssertNil(WordLearnPromptNotifier.authorizationBlocker(for: .authorized))
        XCTAssertNil(WordLearnPromptNotifier.authorizationBlocker(for: .provisional))
    }

    /// A prompt that never reached the user must not burn the cooldown, so a
    /// later permission grant still leaves the pair askable.
    func testBlockedPromptDoesNotBurnCooldown() async {
        let notifier = WordLearnPromptNotifier()
        let now = Date()

        let outcome = await notifier.deliverPrompt(spoken: "teece", written: "Thijs", now: now)

        XCTAssertNotEqual(outcome, .delivered)
        XCTAssertTrue(notifier.shouldPrompt(spoken: "teece", now: now))
    }

    func testCooldownSuppressionIsReportedDistinctlyFromDelivery() async {
        let notifier = WordLearnPromptNotifier()
        let now = Date()
        notifier.markPrompted(spoken: "teece", now: now)

        let outcome = await notifier.deliverPrompt(
            spoken: "teece",
            written: "Thijs",
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(outcome, .suppressedByCooldown)
    }

    func testLearnPromptIdentifierRoundTrip() {
        XCTAssertTrue(WordLearnPromptNotifier.isLearnPromptIdentifier(
            WordLearnPromptNotifier.requestIdentifierPrefix + "teece"
        ))
        XCTAssertFalse(WordLearnPromptNotifier.isLearnPromptIdentifier("meeting_detected_prompt_request"))

        let pair = WordLearnPromptNotifier.pair(from: [
            WordLearnPromptNotifier.userInfoSpokenKey: "teece",
            WordLearnPromptNotifier.userInfoWrittenKey: "Thijs",
        ])
        XCTAssertEqual(pair?.spoken, "teece")
        XCTAssertEqual(pair?.written, "Thijs")
        XCTAssertNil(WordLearnPromptNotifier.pair(from: [:]))
    }
}
