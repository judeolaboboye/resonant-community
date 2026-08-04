import XCTest
@testable import Resonant

final class DispatchPlannerTests: XCTestCase {
    func testPlannerBlocksRiskyTypingWithoutCurrentContext() {
        let route = route(
            action: .typeText(text: "ship it", appHint: nil),
            confidence: 0.72,
            disturbance: .activeSurface
        )

        let plan = DispatchPlanner.makePlan(
            command: "type ship it",
            route: route,
            action: .typeText(text: "ship it", appHint: nil),
            contextPacket: nil,
            snapshots: []
        )

        XCTAssertTrue(plan.requiresClarification)
        XCTAssertEqual(plan.executionStrategy, .clarification)
        XCTAssertEqual(plan.repairStrategy, .askUserToConfirmSurface)
        XCTAssertEqual(plan.capabilityStatus, .blocked)
    }

    func testPlannerAllowsTypedReplyWithAXTarget() {
        let action = CommandAction.typeText(text: "I am on it", appHint: "Slack")
        let plan = DispatchPlanner.makePlan(
            command: "reply that I am on it",
            route: route(action: action, confidence: 0.86, disturbance: .activeSurface),
            action: action,
            contextPacket: contextPacket(appName: "Slack", targetFingerprint: targetFingerprint()),
            snapshots: []
        )

        XCTAssertFalse(plan.requiresClarification)
        XCTAssertEqual(plan.executionStrategy, .localUIAutomation)
        XCTAssertEqual(plan.verificationStrategy, .focusedFieldReadback)
        XCTAssertEqual(plan.capabilityStatus, .available)
    }

    func testPlannerBlocksTypingIntoSecureTextField() {
        let action = CommandAction.typeText(text: "ship it", appHint: "Slack")
        let plan = DispatchPlanner.makePlan(
            command: "type ship it",
            route: route(action: action, confidence: 0.9, disturbance: .activeSurface),
            action: action,
            contextPacket: contextPacket(appName: "Slack", targetFingerprint: targetFingerprint(isSensitiveInput: true)),
            snapshots: []
        )

        XCTAssertTrue(plan.requiresClarification)
        XCTAssertEqual(plan.executionStrategy, .clarification)
        XCTAssertEqual(plan.capabilityStatus, .blocked)
        XCTAssertTrue(plan.evidence.contains("Planner blocked typing because the focused target is a secure text field."))
    }

    func testPlannerBlocksActiveSlackTypingIntoSecureTextField() {
        let action = CommandAction.postSlack(channel: "#eng", message: "Shipping now")
        let plan = DispatchPlanner.makePlan(
            command: "tell slack eng shipping now",
            route: route(action: action, confidence: 0.88, disturbance: .activeSurface, surface: "Slack"),
            action: action,
            contextPacket: contextPacket(
                appName: "Slack",
                bundleId: "com.tinyspeck.slackmacgap",
                targetFingerprint: targetFingerprint(isSensitiveInput: true)
            ),
            snapshots: []
        )

        XCTAssertTrue(plan.requiresClarification)
        XCTAssertEqual(plan.executionStrategy, .clarification)
        XCTAssertEqual(plan.capabilityStatus, .blocked)
        XCTAssertTrue(plan.evidence.contains("Planner blocked Slack typing because the focused target is a secure text field."))
    }

    func testPlannerUsesActiveSlackWebComposeWhenAvailable() {
        let action = CommandAction.postSlack(channel: "#eng", message: "Shipping now")
        let plan = DispatchPlanner.makePlan(
            command: "tell slack eng shipping now",
            route: route(action: action, confidence: 0.88, disturbance: .activeSurface, surface: "Slack"),
            action: action,
            contextPacket: contextPacket(
                appName: "Arc",
                bundleId: "company.thebrowser.Browser",
                browserURL: "https://app.slack.com/client/T123/C456",
                targetFingerprint: targetFingerprint()
            ),
            snapshots: []
        )

        XCTAssertFalse(plan.requiresClarification)
        XCTAssertEqual(plan.surfaceKind, .slack)
        XCTAssertEqual(plan.surfaceVariant, .web)
        XCTAssertEqual(plan.executionStrategy, .localUIAutomation)
        XCTAssertEqual(plan.verificationStrategy, .focusedFieldReadback)
        XCTAssertTrue(plan.requiresAPI)
        XCTAssertEqual(plan.fallback, "clipboard fallback if Slack field verification fails")
        XCTAssertEqual(plan.capabilityStatus, .degraded)
    }

    func testPlannerFallsBackToClipboardWhenSlackTargetIsNotVerified() {
        let action = CommandAction.postSlack(channel: "#eng", message: "Shipping now")
        let plan = DispatchPlanner.makePlan(
            command: "tell slack eng shipping now",
            route: route(action: action, confidence: 0.88, disturbance: .preparedOnly, surface: "Slack"),
            action: action,
            contextPacket: contextPacket(
                appName: "Discord",
                bundleId: "com.hnc.discord",
                browserURL: nil,
                targetFingerprint: targetFingerprint()
            ),
            snapshots: []
        )

        XCTAssertFalse(plan.requiresClarification)
        XCTAssertEqual(plan.surfaceKind, .slack)
        XCTAssertEqual(plan.executionStrategy, .clipboardDraft)
        XCTAssertEqual(plan.verificationStrategy, .clipboardPayload)
        XCTAssertTrue(plan.requiresAPI)
        XCTAssertEqual(plan.fallback, "clipboard draft")
        XCTAssertEqual(plan.capabilityStatus, .degraded)
        XCTAssertLessThanOrEqual(plan.confidence, 0.721)
    }

    func testPlannerUsesClipboardDraftForTickets() {
        let action = CommandAction.createTicket(title: "Fix dispatch", body: "Silent failure", service: .linear)
        let plan = DispatchPlanner.makePlan(
            command: "create a Linear ticket to fix dispatch",
            route: route(action: action, confidence: 0.74, disturbance: .preparedOnly),
            action: action,
            contextPacket: nil,
            snapshots: []
        )

        XCTAssertFalse(plan.requiresClarification)
        XCTAssertEqual(plan.executionStrategy, .clipboardDraft)
        XCTAssertEqual(plan.verificationStrategy, .clipboardPayload)
        XCTAssertEqual(plan.repairStrategy, .prepareClipboardFallback)
        XCTAssertEqual(plan.surfaceKind, .linear)
        XCTAssertTrue(plan.requiresAPI)
        XCTAssertEqual(plan.fallback, "clipboard ticket draft")
        XCTAssertEqual(plan.capabilityStatus, .degraded)
        XCTAssertTrue(plan.evidence.contains("Direct Linear issue creation requires API access; using clipboard ticket draft."))
    }

    func testPlannerUsesClipboardHandoffForDevinWithoutAPI() {
        let action = CommandAction.delegateToAgent(agent: .devin, prompt: "Fix dispatch reliability", context: nil)
        let plan = DispatchPlanner.makePlan(
            command: "ask Devin to fix dispatch reliability",
            route: route(action: action, confidence: 0.79, disturbance: .preparedOnly, surface: "Devin"),
            action: action,
            contextPacket: nil,
            snapshots: [
                snapshot(
                    appName: "Safari",
                    bundleId: "com.apple.Safari",
                    browserURL: "https://app.devin.ai/sessions"
                )
            ]
        )

        XCTAssertFalse(plan.requiresClarification)
        XCTAssertEqual(plan.surfaceKind, .devin)
        XCTAssertEqual(plan.surfaceVariant, .web)
        XCTAssertEqual(plan.executionStrategy, .agentHandoff)
        XCTAssertEqual(plan.verificationStrategy, .clipboardPayload)
        XCTAssertTrue(plan.requiresAPI)
        XCTAssertEqual(plan.fallback, "clipboard agent handoff")
        XCTAssertEqual(plan.capabilityStatus, .degraded)
    }

    private func route(
        action: CommandAction,
        confidence: Double,
        disturbance: DispatchRouteDisturbance,
        surface: String = "Current app"
    ) -> DispatchRouteResolution {
        DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "test.route",
                intent: .activeText,
                title: "Test route",
                surface: surface,
                action: "Run action",
                validator: "Verify action",
                disturbance: disturbance
            ),
            action: action,
            confidence: confidence,
            evidence: ["Test evidence"],
            source: .deterministicLocal
        )
    }

    private func contextPacket(
        appName: String,
        bundleId: String? = nil,
        browserURL: String? = nil,
        targetFingerprint: ContextTargetFingerprint?
    ) -> ContextPacket {
        ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: SurfaceDescriptor(
                kind: .chat,
                appName: appName,
                bundleId: bundleId,
                windowTitle: "\(appName) window",
                browserURL: browserURL,
                siteHost: nil,
                siteName: nil,
                fieldKind: .reply,
                conversationLabel: nil,
                documentLabel: nil,
                projectLabel: nil
            ),
            intent: DictationIntent(
                kind: .command,
                confidence: 1,
                allowsBiasTerms: true,
                allowsStyleHint: true,
                allowsSelectedTextGrounding: true,
                allowsVisibleContextGrounding: true,
                allowsMemoryGrounding: true,
                evidence: []
            ),
            entities: [],
            styleHint: nil,
            selectedTextPreview: nil,
            focusedFieldPreview: nil,
            targetFingerprint: targetFingerprint,
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
    }

    private func snapshot(
        appName: String,
        bundleId: String,
        browserURL: String?
    ) -> DispatchRouteSnapshot {
        DispatchRouteSnapshot(
            timestamp: Date(),
            appName: appName,
            bundleId: bundleId,
            windowTitle: "\(appName) window",
            browserURL: browserURL,
            codeFileName: nil,
            slackRecipient: nil,
            focusedFieldContent: nil,
            visibleTextSnippets: [],
            browserTabs: []
        )
    }

    private func targetFingerprint(isSensitiveInput: Bool = false) -> ContextTargetFingerprint {
        ContextTargetFingerprint(
            role: "AXTextArea",
            subrole: nil,
            isSensitiveInput: isSensitiveInput,
            identifierToken: nil,
            titleToken: nil,
            descriptionToken: nil,
            placeholderToken: "reply",
            helpToken: nil,
            frameBucket: "10:10:20:4",
            selectedRangeBucket: nil
        )
    }
}
