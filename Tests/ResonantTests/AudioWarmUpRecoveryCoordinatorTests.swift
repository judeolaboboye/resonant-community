import XCTest
@testable import Resonant

@MainActor
final class AudioWarmUpRecoveryCoordinatorTests: XCTestCase {
    func testDeadlineExtendsFromLatestHardwareEvent() {
        let clock = ContinuousClock()
        let start = clock.now
        var deadline = AudioWarmUpRecoveryDeadline()

        deadline.extend(from: start, by: .seconds(5))
        XCTAssertEqual(
            deadline.remaining(from: start.advanced(by: .seconds(2))),
            .seconds(3)
        )

        deadline.extend(
            from: start.advanced(by: .seconds(3)),
            by: .seconds(5)
        )
        XCTAssertEqual(
            deadline.remaining(from: start.advanced(by: .seconds(3))),
            .seconds(5)
        )
    }

    func testCancellationPreservesRecoveryDeadline() {
        let coordinator = AudioWarmUpRecoveryCoordinator(
            stabilizationDelay: .seconds(1)
        )

        coordinator.enterRecovery()
        XCTAssertTrue(coordinator.deferActivationIfNeeded({}))
        coordinator.cancelPendingActivation()

        XCTAssertNotNil(coordinator.remainingRecoveryDelay)
    }

    func testMeetingRearmWaitsRemainingDeadlineAndFiresOnce() async {
        let coordinator = AudioWarmUpRecoveryCoordinator(
            stabilizationDelay: .milliseconds(200)
        )
        var activationCount = 0

        coordinator.enterRecovery()
        XCTAssertTrue(
            coordinator.deferActivationIfNeeded {
                activationCount += 1
            }
        )

        try? await Task.sleep(for: .milliseconds(35))
        coordinator.cancelPendingActivation() // meeting startup suppression
        try? await Task.sleep(for: .milliseconds(35))

        let rearmed = expectation(description: "activation after remaining recovery")
        let rearmStartedAt = ContinuousClock().now
        XCTAssertTrue(
            coordinator.deferActivationIfNeeded {
                activationCount += 1
                rearmed.fulfill()
            }
        )

        await fulfillment(of: [rearmed], timeout: 1)
        let elapsed = rearmStartedAt.duration(to: ContinuousClock().now)
        XCTAssertGreaterThan(elapsed, .milliseconds(70))
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(activationCount, 1)
    }

    func testPersistentWarmPolicyUsesBridgeAndEveryLiveMeetingState() {
        XCTAssertFalse(
            PersistentAudioWarmUpPolicy.shouldSuppress(
                hasStartupSuppression: false,
                isMeetingStarting: false,
                isMeetingRecording: false,
                isMeetingFinalizing: false,
                isLocalCaptureActive: false,
                isSystemSleeping: false,
                isShuttingDown: false,
                isClearingWorkspace: false
            )
        )

        for state in 0..<8 {
            XCTAssertTrue(
                PersistentAudioWarmUpPolicy.shouldSuppress(
                    hasStartupSuppression: state == 0,
                    isMeetingStarting: state == 1,
                    isMeetingRecording: state == 2,
                    isMeetingFinalizing: state == 3,
                    isLocalCaptureActive: state == 4,
                    isSystemSleeping: state == 5,
                    isShuttingDown: state == 6,
                    isClearingWorkspace: state == 7
                )
            )
        }
    }

    func testLocalCaptureAdmissionRejectsMeetingHandoffAndTerminalLifecycle() {
        XCTAssertTrue(
            LocalAudioCaptureAdmissionPolicy.allowsCapture(
                hasMeetingStartupSuppression: false,
                isMeetingStarting: false,
                isMeetingRecording: false,
                isMeetingFinalizing: false,
                isSystemSleeping: false,
                isShuttingDown: false,
                isClearingWorkspace: false
            )
        )

        for state in 0..<7 {
            XCTAssertFalse(
                LocalAudioCaptureAdmissionPolicy.allowsCapture(
                    hasMeetingStartupSuppression: state == 0,
                    isMeetingStarting: state == 1,
                    isMeetingRecording: state == 2,
                    isMeetingFinalizing: state == 3,
                    isSystemSleeping: state == 4,
                    isShuttingDown: state == 5,
                    isClearingWorkspace: state == 6
                )
            )
        }
    }

    func testFailedStartRearmsOnlyAfterCaptureStateIsRetired() {
        XCTAssertTrue(
            FailedLocalCaptureWarmUpPolicy.shouldRequestPersistentWarmUp(
                isLowLatencyEnabled: true,
                isRecording: false,
                isStartingRecording: false,
                isFinishingCapture: false
            )
        )

        XCTAssertFalse(
            FailedLocalCaptureWarmUpPolicy.shouldRequestPersistentWarmUp(
                isLowLatencyEnabled: false,
                isRecording: false,
                isStartingRecording: false,
                isFinishingCapture: false
            )
        )
        for activeState in 0..<3 {
            XCTAssertFalse(
                FailedLocalCaptureWarmUpPolicy.shouldRequestPersistentWarmUp(
                    isLowLatencyEnabled: true,
                    isRecording: activeState == 0,
                    isStartingRecording: activeState == 1,
                    isFinishingCapture: activeState == 2
                )
            )
        }
    }

    func testAcceptedStartIsVetoedWhenTerminalLifecycleArrivesDuringAwait() {
        XCTAssertTrue(
            AudioStartContinuationPolicy.shouldContinue(
                ownsStartAttempt: true,
                isSystemSleeping: false,
                isShuttingDown: false,
                isClearingWorkspace: false
            )
        )

        XCTAssertFalse(
            AudioStartContinuationPolicy.shouldContinue(
                ownsStartAttempt: false,
                isSystemSleeping: false,
                isShuttingDown: false,
                isClearingWorkspace: false
            )
        )
        for terminalState in 0..<3 {
            XCTAssertFalse(
                AudioStartContinuationPolicy.shouldContinue(
                    ownsStartAttempt: true,
                    isSystemSleeping: terminalState == 0,
                    isShuttingDown: terminalState == 1,
                    isClearingWorkspace: terminalState == 2
                )
            )
        }
    }

    func testBackgroundMicrophoneActivationRejectsCaptureAndMeetingOwnership() {
        XCTAssertTrue(
            BackgroundMicrophoneActivationPolicy.allowsActivation(
                terminalCaptureAllowed: true,
                isLocalCaptureRecording: false,
                isLocalCaptureStarting: false,
                isMeetingStarting: false,
                isMeetingRecording: false,
                isMeetingFinalizing: false
            )
        )

        for veto in 0..<6 {
            XCTAssertFalse(
                BackgroundMicrophoneActivationPolicy.allowsActivation(
                    terminalCaptureAllowed: veto != 0,
                    isLocalCaptureRecording: veto == 1,
                    isLocalCaptureStarting: veto == 2,
                    isMeetingStarting: veto == 3,
                    isMeetingRecording: veto == 4,
                    isMeetingFinalizing: veto == 5
                )
            )
        }
    }
}
