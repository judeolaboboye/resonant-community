import XCTest
@testable import Resonant

final class DispatchCommandPresentationStateTests: XCTestCase {
    func testPresentationTracksRouteActionAndResultBehindOneInterface() {
        var presentation = DispatchCommandPresentationState(heardText: "tell the team the build passed")
        let route = DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "slack.post",
                intent: .slackDraft,
                title: "Slack route",
                surface: "#resonant",
                action: "Prepare or type Slack message",
                validator: "Slack payload prepared or active field delivery succeeded",
                disturbance: .activeSurface
            ),
            action: .postSlack(channel: "resonant", message: "Build passed"),
            confidence: 0.82,
            evidence: []
        )

        XCTAssertEqual(
            presentation.initialStatus(),
            "Heard: tell the team the build passed\nAction: Resolving route"
        )

        let routedStatus = presentation.status(after: .routeSelected(route))
        XCTAssertTrue(routedStatus.contains("Route: Slack route"))
        XCTAssertTrue(routedStatus.contains("Action: Prepare or type"))
        XCTAssertTrue(routedStatus.contains("Why: Slack payload prepared"))

        let plan = DispatchPlan(
            objective: "Send or prepare a Slack message",
            targetSurface: "#resonant",
            executionStrategy: .localUIAutomation,
            verificationStrategy: .focusedFieldReadback,
            repairStrategy: .retryTargetedSurface,
            confidence: 0.82,
            requiresClarification: false,
            clarificationPrompt: nil,
            evidence: ["Planner found Slack surface evidence."]
        )
        let planStatus = presentation.status(after: .planSelected(plan))
        XCTAssertTrue(planStatus.contains("Plan: Send or prepare"))

        let actionStatus = presentation.status(after: .actionStarted("Insert text into focused field"))
        XCTAssertTrue(actionStatus.contains("Action: Insert text into"))

        let resultStatus = presentation.status(after: .result("Typed into Slack", success: true))
        XCTAssertEqual(resultStatus, "Action: Insert text into focused field\nResult: Typed into Slack")
    }

    func testPresentationShowsCapabilityFallbackInPlanReason() {
        var presentation = DispatchCommandPresentationState(heardText: "create a linear ticket")
        let plan = DispatchPlan(
            objective: "Prepare a linear ticket",
            targetSurface: "Linear",
            surfaceKind: .linear,
            executionStrategy: .clipboardDraft,
            verificationStrategy: .clipboardPayload,
            repairStrategy: .prepareClipboardFallback,
            requiresAPI: true,
            fallback: "clipboard ticket draft",
            confidence: 0.72,
            requiresClarification: false,
            evidence: ["Direct Linear issue creation requires API access; using clipboard ticket draft."]
        )

        let status = presentation.status(after: .planSelected(plan))

        XCTAssertTrue(status.contains("Plan: Prepare a linear"))
        XCTAssertTrue(status.contains("Why: API needed; using clipboard"))
    }

    func testFollowUpCommandTextCompactsLongParentCommand() {
        let parent = String(repeating: "dispatch ", count: 30)

        let text = DispatchCommandPresentationState.followUpCommandText(
            parentCommand: parent,
            followUpText: "use this text box"
        )

        XCTAssertTrue(text.hasPrefix("Follow-up to previous Dispatch command \""))
        XCTAssertTrue(text.hasSuffix("\": use this text box"))
        XCTAssertLessThan(text.count, parent.count)
    }
}
