import XCTest
@testable import Resonant

final class DeadCaptureRestartPolicyTests: XCTestCase {

    func testDeadCaptureRestartsAfterMinimumElapsed() {
        // The field signature: 9.5 s recording that accrued 9 ms of media.
        XCTAssertTrue(DeadCaptureRestartPolicy.shouldRestart(
            elapsedSeconds: 9.5,
            recordedSeconds: 0.009,
            restartsSoFar: 0
        ))
    }

    func testHealthyQuietCaptureNeverRestarts() {
        // A silent room still delivers frames, so recorded tracks wall clock.
        XCTAssertFalse(DeadCaptureRestartPolicy.shouldRestart(
            elapsedSeconds: 5.0,
            recordedSeconds: 4.8,
            restartsSoFar: 0
        ))
    }

    func testYoungCaptureIsLeftAloneEvenWithNoMedia() {
        XCTAssertFalse(DeadCaptureRestartPolicy.shouldRestart(
            elapsedSeconds: DeadCaptureRestartPolicy.minimumElapsedSeconds - 0.1,
            recordedSeconds: 0,
            restartsSoFar: 0
        ))
    }

    func testRecordedJustUnderThresholdAtBoundaryElapsedRestarts() {
        XCTAssertTrue(DeadCaptureRestartPolicy.shouldRestart(
            elapsedSeconds: DeadCaptureRestartPolicy.minimumElapsedSeconds,
            recordedSeconds: DeadCaptureRestartPolicy.maximumRecordedSeconds - 0.01,
            restartsSoFar: 0
        ))
        XCTAssertFalse(DeadCaptureRestartPolicy.shouldRestart(
            elapsedSeconds: DeadCaptureRestartPolicy.minimumElapsedSeconds,
            recordedSeconds: DeadCaptureRestartPolicy.maximumRecordedSeconds,
            restartsSoFar: 0
        ))
    }

    func testOnlyOneRestartPerCapture() {
        XCTAssertFalse(DeadCaptureRestartPolicy.shouldRestart(
            elapsedSeconds: 30,
            recordedSeconds: 0,
            restartsSoFar: DeadCaptureRestartPolicy.maximumRestartsPerCapture
        ))
    }

    func testInvalidRecordedDurationCountsAsNoMedia() {
        // CMTime.invalid yields NaN seconds; an output that never produced a
        // valid duration is exactly the dead case.
        XCTAssertTrue(DeadCaptureRestartPolicy.shouldRestart(
            elapsedSeconds: 5.0,
            recordedSeconds: .nan,
            restartsSoFar: 0
        ))
    }
}
