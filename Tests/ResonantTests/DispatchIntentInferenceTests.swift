import XCTest
@testable import Resonant

final class DispatchIntentInferenceTests: XCTestCase {
    func testInfersReplyIntoCurrentGmailFieldWithSurfaceLinkEvidence() {
        let context = contextPacket(
            appName: "Google Chrome",
            kind: .email,
            fieldKind: .reply,
            browserURL: "https://mail.google.com/mail/u/0/#inbox/FMfcgzGtwExample",
            targetFingerprint: targetFingerprint()
        )

        let inferred = DispatchIntentInference.infer(
            command: "reply here that I can do it tomorrow",
            contextPacket: context,
            snapshots: []
        )

        guard case .typeText(let text, let appHint)? = inferred?.action else {
            return XCTFail("Expected typeText action")
        }
        XCTAssertEqual(text, "I can do it tomorrow")
        XCTAssertEqual(appHint, "Google Chrome")
        XCTAssertGreaterThanOrEqual(inferred?.confidence ?? 0, 0.86)
        XCTAssertTrue(inferred?.evidence.contains(where: { $0.contains("Gmail") }) == true)
    }

    func testInfersTaskCommentFromLinearSurface() {
        let context = contextPacket(
            appName: "Safari",
            kind: .task,
            fieldKind: .comment,
            browserURL: "https://linear.app/resonant/issue/RES-123/fix-dispatch",
            targetFingerprint: targetFingerprint()
        )

        let inferred = DispatchIntentInference.infer(
            command: "comment this is fixed",
            contextPacket: context,
            snapshots: []
        )

        guard case .typeText(let text, let appHint)? = inferred?.action else {
            return XCTFail("Expected typeText action")
        }
        XCTAssertEqual(text, "this is fixed")
        XCTAssertEqual(appHint, "Safari")
    }

    func testAgentDelegationCarriesSurfaceLinksAsContext() {
        let context = contextPacket(
            appName: "Safari",
            kind: .task,
            fieldKind: .comment,
            browserURL: "https://linear.app/resonant/issue/RES-123/fix-dispatch",
            targetFingerprint: nil
        )

        let inferred = DispatchIntentInference.infer(
            command: "ask Devin to fix this",
            contextPacket: context,
            snapshots: []
        )

        guard case .delegateToAgent(let agent, _, let explicitContext)? = inferred?.action else {
            return XCTFail("Expected delegateToAgent action")
        }
        XCTAssertEqual(agent, .devin)
        XCTAssertTrue(explicitContext?.contains("linear.app") == true)
    }

    func testVagueReplyCanUseRecentNotificationWhenCurrentSurfaceMatches() {
        let context = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            browserURL: nil,
            targetFingerprint: targetFingerprint()
        )
        let snapshot = DispatchRouteSnapshot(
            timestamp: Date(),
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Resonant",
            browserURL: nil,
            codeFileName: nil,
            slackRecipient: "#resonant",
            focusedFieldContent: nil,
            visibleTextSnippets: [],
            browserTabs: [],
            notificationHint: DispatchNotificationHint(
                appName: "Slack",
                bundleId: "com.tinyspeck.slackmacgap",
                title: "Alex in #resonant",
                body: "Can you take this?",
                url: nil,
                receivedAt: Date()
            )
        )

        let inferred = DispatchIntentInference.infer(
            command: "reply to that saying I am on it",
            contextPacket: context,
            snapshots: [snapshot]
        )

        guard case .typeText(let text, let appHint)? = inferred?.action else {
            return XCTFail("Expected typeText action")
        }
        XCTAssertEqual(text, "I am on it")
        XCTAssertEqual(appHint, "Slack")
        XCTAssertTrue(inferred?.reason.contains("notification") == true)
    }

    func testVagueReplyCanUseSlackNotificationWhenCurrentSurfaceIsSlackWeb() {
        let context = contextPacket(
            appName: "Arc",
            bundleId: "company.thebrowser.browser",
            kind: .chat,
            fieldKind: .compose,
            browserURL: "https://app.slack.com/client/T123/C456",
            targetFingerprint: targetFingerprint()
        )
        let snapshot = DispatchRouteSnapshot(
            timestamp: Date(),
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Resonant",
            browserURL: nil,
            codeFileName: nil,
            slackRecipient: "#resonant",
            focusedFieldContent: nil,
            visibleTextSnippets: [],
            browserTabs: [],
            notificationHint: DispatchNotificationHint(
                appName: "Slack",
                bundleId: "com.tinyspeck.slackmacgap",
                title: "Alex in #resonant",
                body: "Can you take this?",
                url: nil,
                receivedAt: Date()
            )
        )

        let inferred = DispatchIntentInference.infer(
            command: "reply to that saying I am on it",
            contextPacket: context,
            snapshots: [snapshot]
        )

        guard case .typeText(let text, let appHint)? = inferred?.action else {
            return XCTFail("Expected typeText action")
        }
        XCTAssertEqual(text, "I am on it")
        XCTAssertEqual(appHint, "Arc")
    }

    func testVagueReplyIgnoresSlackNotificationForDifferentConversation() {
        let context = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            browserURL: nil,
            conversationLabel: "#channel-b",
            targetFingerprint: targetFingerprint()
        )
        let snapshot = DispatchRouteSnapshot(
            timestamp: Date(),
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Slack",
            browserURL: nil,
            codeFileName: nil,
            slackRecipient: "#channel-b",
            focusedFieldContent: nil,
            visibleTextSnippets: [],
            browserTabs: [],
            notificationHint: DispatchNotificationHint(
                appName: "Slack",
                bundleId: "com.tinyspeck.slackmacgap",
                title: "Alex in #channel-a",
                body: "Can you take this?",
                url: nil,
                receivedAt: Date()
            )
        )

        XCTAssertNil(DispatchIntentInference.infer(
            command: "reply to that saying I am on it",
            contextPacket: context,
            snapshots: [snapshot]
        ))
    }

    func testVagueReplyIgnoresNotificationForDifferentSurface() {
        let context = contextPacket(
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            kind: .browser,
            fieldKind: .compose,
            browserURL: "https://docs.google.com/document/d/example",
            targetFingerprint: targetFingerprint()
        )
        let snapshot = DispatchRouteSnapshot(
            timestamp: Date(),
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Resonant",
            browserURL: nil,
            codeFileName: nil,
            slackRecipient: "#resonant",
            focusedFieldContent: nil,
            visibleTextSnippets: [],
            browserTabs: [],
            notificationHint: DispatchNotificationHint(
                appName: "Slack",
                bundleId: "com.tinyspeck.slackmacgap",
                title: "Alex in #resonant",
                body: "Can you take this?",
                url: nil,
                receivedAt: Date()
            )
        )

        XCTAssertNil(DispatchIntentInference.infer(
            command: "reply to that saying I am on it",
            contextPacket: context,
            snapshots: [snapshot]
        ))
    }

    private func contextPacket(
        appName: String,
        bundleId: String? = nil,
        kind: SurfaceKind,
        fieldKind: FieldKind,
        browserURL: String?,
        conversationLabel: String? = nil,
        targetFingerprint: ContextTargetFingerprint?
    ) -> ContextPacket {
        ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: SurfaceDescriptor(
                kind: kind,
                appName: appName,
                bundleId: bundleId,
                windowTitle: "\(appName) window",
                browserURL: browserURL,
                siteHost: nil,
                siteName: nil,
                fieldKind: fieldKind,
                conversationLabel: conversationLabel,
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

    private func targetFingerprint() -> ContextTargetFingerprint {
        ContextTargetFingerprint(
            role: "AXTextArea",
            subrole: nil,
            identifierToken: nil,
            titleToken: nil,
            descriptionToken: nil,
            placeholderToken: "reply-field",
            helpToken: nil,
            frameBucket: "10:10:8:2",
            selectedRangeBucket: nil
        )
    }
}
