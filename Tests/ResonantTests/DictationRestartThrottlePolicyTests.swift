import XCTest
@testable import Resonant

final class DictationRestartThrottlePolicyTests: XCTestCase {

    // MARK: - shouldSuppressUnproductiveRestart

    func testRapidHoldRestartAfterUnproductiveCaptureIsSuppressed() {
        XCTAssertTrue(DictationRestartThrottlePolicy.shouldSuppressUnproductiveRestart(
            mode: .hold,
            millisecondsSinceUnproductiveStop: 100
        ))
    }

    func testHoldRestartPastCooldownIsAllowed() {
        XCTAssertFalse(DictationRestartThrottlePolicy.shouldSuppressUnproductiveRestart(
            mode: .hold,
            millisecondsSinceUnproductiveStop: DictationRestartThrottlePolicy.holdUnproductiveRestartCooldownMs
        ))
        XCTAssertFalse(DictationRestartThrottlePolicy.shouldSuppressUnproductiveRestart(
            mode: .hold,
            millisecondsSinceUnproductiveStop: DictationRestartThrottlePolicy.holdUnproductiveRestartCooldownMs + 50
        ))
    }

    func testHoldRestartWithNoPriorUnproductiveCaptureIsAllowed() {
        // A productive (or first-ever) capture clears the timestamp -> nil.
        XCTAssertFalse(DictationRestartThrottlePolicy.shouldSuppressUnproductiveRestart(
            mode: .hold,
            millisecondsSinceUnproductiveStop: nil
        ))
    }

    func testToggleModeIsNeverThrottledByThisPolicy() {
        // Toggle mode has its own bounce cooldowns in HotkeyManager.
        XCTAssertFalse(DictationRestartThrottlePolicy.shouldSuppressUnproductiveRestart(
            mode: .toggle,
            millisecondsSinceUnproductiveStop: 100
        ))
    }

    func testNegativeElapsedIsTreatedAsNotThrottled() {
        // Defensive: a clock skew should never wedge the throttle on.
        XCTAssertFalse(DictationRestartThrottlePolicy.shouldSuppressUnproductiveRestart(
            mode: .hold,
            millisecondsSinceUnproductiveStop: -10
        ))
    }

    // MARK: - shouldSilenceSelfCollision

    func testHoldSelfCollisionWhileFinishingIsSilenced() {
        XCTAssertTrue(DictationRestartThrottlePolicy.shouldSilenceSelfCollision(
            mode: .hold,
            isRecording: false,
            isStartingRecording: false,
            isFinishingCapture: true
        ))
    }

    func testHoldSelfCollisionWhileStartingIsSilenced() {
        XCTAssertTrue(DictationRestartThrottlePolicy.shouldSilenceSelfCollision(
            mode: .hold,
            isRecording: false,
            isStartingRecording: true,
            isFinishingCapture: false
        ))
    }

    func testActiveRecordingCollisionIsNotSilenced() {
        // A genuinely active recording is left to the normal busy guard.
        XCTAssertFalse(DictationRestartThrottlePolicy.shouldSilenceSelfCollision(
            mode: .hold,
            isRecording: true,
            isStartingRecording: false,
            isFinishingCapture: true
        ))
    }

    func testNoInFlightCaptureIsNotSilenced() {
        XCTAssertFalse(DictationRestartThrottlePolicy.shouldSilenceSelfCollision(
            mode: .hold,
            isRecording: false,
            isStartingRecording: false,
            isFinishingCapture: false
        ))
    }

    func testToggleSelfCollisionIsNotSilenced() {
        XCTAssertFalse(DictationRestartThrottlePolicy.shouldSilenceSelfCollision(
            mode: .toggle,
            isRecording: false,
            isStartingRecording: false,
            isFinishingCapture: true
        ))
    }
}
