import XCTest
@testable import Resonant

@MainActor
final class CommandRouterTests: XCTestCase {
    func testSpeakAnswerHandlesVoiceFeedbackInline() {
        let action = CommandAction.speakAnswer(text: "The build passed.")

        XCTAssertTrue(action.handlesVoiceFeedbackInline)
    }

    func testCompositeWithSpeakAnswerHandlesVoiceFeedbackInline() {
        let action = CommandAction.composite([
            .openApp(name: "Safari"),
            .speakAnswer(text: "Opened Safari.")
        ])

        XCTAssertTrue(action.handlesVoiceFeedbackInline)
    }

    func testNonVoiceActionsStillUseResultSpeech() {
        let action = CommandAction.openApp(name: "Safari")

        XCTAssertFalse(action.handlesVoiceFeedbackInline)
    }

    func testPlannerRepairAllowsOpenAppVerificationFailureRetry() {
        let plan = DispatchPlan(
            objective: "Open Slack",
            targetSurface: "Slack",
            executionStrategy: .appLaunch,
            verificationStrategy: .foregroundAppReadback,
            repairStrategy: .retryTargetedSurface,
            confidence: 0.9,
            requiresClarification: false,
            clarificationPrompt: nil,
            evidence: []
        )
        let verification = DispatchActionVerification(
            verdict: .failed,
            summary: "Expected Slack to be frontmost, found Discord.",
            failureStage: .verification,
            evidence: [:]
        )

        XCTAssertTrue(CommandRouter.shouldAttemptRepair(
            plan: plan,
            action: .openApp(name: "Slack"),
            verification: verification
        ))
    }

    func testPlannerRepairDoesNotRetryRiskyTextInsertion() {
        let plan = DispatchPlan(
            objective: "Insert dictated text",
            targetSurface: "Current app",
            executionStrategy: .localUIAutomation,
            verificationStrategy: .focusedFieldReadback,
            repairStrategy: .retryTargetedSurface,
            confidence: 0.8,
            requiresClarification: false,
            clarificationPrompt: nil,
            evidence: []
        )
        let verification = DispatchActionVerification(
            verdict: .failed,
            summary: "Focused field did not contain the inserted text.",
            failureStage: .verification,
            evidence: [:]
        )

        XCTAssertFalse(CommandRouter.shouldAttemptRepair(
            plan: plan,
            action: .typeText(text: "hello", appHint: nil),
            verification: verification
        ))
    }
}
