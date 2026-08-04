import XCTest
@testable import Resonant

@MainActor
final class DispatchRouteResolverTests: XCTestCase {

    func testWeatherCommandRoutesToGoogleWeatherCard() async {
        let route = await DispatchRouteResolver.resolve(
            command: "get me the weather on Google in Vienna",
            contextPacket: nil,
            snapshots: []
        )

        XCTAssertEqual(route.card.intent, .openURL)
        XCTAssertEqual(route.card.title, "Google weather")
        XCTAssertEqual(route.card.disturbance, .appSwitch)
        XCTAssertEqual(route.source, .deterministicLocal)
        XCTAssertTrue(route.reason.contains("deterministic local"))

        guard case .openURL(let url)? = route.action else {
            return XCTFail("Expected openURL action")
        }
        XCTAssertTrue(url.hasPrefix("https://www.google.com/search?"))
        XCTAssertTrue(url.contains("q=weather%20Vienna"))
    }

    func testSlackRouteUsesRecentSlackSurface() async {
        let route = await DispatchRouteResolver.resolve(
            command: "tell the team I fixed it",
            contextPacket: nil,
            preferredAction: .postSlack(channel: "team", message: "I fixed it"),
            snapshots: [
                snapshot(
                    appName: "Slack",
                    bundleId: "com.tinyspeck.slackmacgap",
                    windowTitle: "Resonant team",
                    slackRecipient: "#resonant"
                )
            ]
        )

        XCTAssertEqual(route.card.intent, .slackDraft)
        XCTAssertEqual(route.card.title, "Slack route")
        XCTAssertEqual(route.card.surface, "#resonant")
        XCTAssertGreaterThan(route.confidence, 0.8)
    }

    func testSlackRouteUsesRecentSlackWebSurface() async {
        let route = await DispatchRouteResolver.resolve(
            command: "tell the team I fixed it",
            contextPacket: nil,
            preferredAction: .postSlack(channel: "team", message: "I fixed it"),
            snapshots: [
                snapshot(
                    appName: "Arc",
                    bundleId: "company.thebrowser.browser",
                    windowTitle: "Slack | Resonant",
                    browserURL: "https://app.slack.com/client/T123/C456",
                    slackRecipient: "#resonant"
                )
            ]
        )

        XCTAssertEqual(route.card.intent, .slackDraft)
        XCTAssertEqual(route.card.surface, "#resonant")
        XCTAssertTrue(route.evidence.contains(where: { $0 == "Recent surface app: Slack (web)" }))
        XCTAssertGreaterThan(route.confidence, 0.8)
    }

    func testSlackRouteDoesNotTreatDiscordTextMentionAsSlackSurface() async {
        let route = await DispatchRouteResolver.resolve(
            command: "tell the team I fixed it",
            contextPacket: nil,
            preferredAction: .postSlack(channel: "team", message: "I fixed it"),
            snapshots: [
                snapshot(
                    appName: "Discord",
                    bundleId: "com.hnc.Discord",
                    windowTitle: "dispatch chat",
                    focusedFieldContent: "someone mentioned slack in this message"
                )
            ]
        )

        XCTAssertEqual(route.card.intent, .slackDraft)
        XCTAssertEqual(route.card.surface, "#team")
        XCTAssertLessThan(route.confidence, 0.8)
    }

    func testAgentRouteUsesRecentConductorContext() async {
        let route = await DispatchRouteResolver.resolve(
            command: "give Devin a new task to fix dispatch commands",
            contextPacket: nil,
            snapshots: [
                snapshot(
                    appName: "Terminal",
                    bundleId: "com.apple.Terminal",
                    windowTitle: "Conductor - Devin",
                    focusedFieldContent: "cd /Users/dev/conductor/workspaces/example-project/feature-branch",
                    visibleTextSnippets: ["devin task in conductor"]
                )
            ]
        )

        XCTAssertEqual(route.card.intent, .agentDelegation)
        XCTAssertTrue(route.card.title.contains("Devin"))
        XCTAssertTrue(route.card.surface.contains("Conductor"))
        XCTAssertGreaterThan(route.confidence, 0.6)
    }

    func testUnknownCommandFallsBackToCloudClassifierRoute() async {
        let route = await DispatchRouteResolver.resolve(
            command: "handle the thing from earlier",
            contextPacket: nil,
            snapshots: []
        )

        XCTAssertNil(route.action)
        XCTAssertEqual(route.card.intent, .cloudClassification)
        XCTAssertEqual(route.card.title, "Cloud action classifier")
        XCTAssertEqual(route.card.disturbance, .background)
        XCTAssertEqual(route.source, .cloudClassifier)
        XCTAssertTrue(route.reason.contains("cloud classification"))
    }

    func testDeterministicOpenAppRouteBeatsWrongLearnedBinding() async {
        let wrongBinding = DispatchLearningBinding(
            id: UUID(),
            commandPattern: "open slack",
            commandTokens: ["open", "slack"],
            surface: DispatchLearningStore.surfaceFingerprint(contextPacket: nil, snapshots: []),
            routeCard: DispatchRouteCard(
                id: "app.open.discord",
                intent: .openApp,
                title: "App switch",
                surface: "Discord",
                action: "Activate or launch app",
                validator: "macOS open request succeeded",
                disturbance: .appSwitch
            ),
            action: .openApp(name: "Discord"),
            confidence: 0.9,
            successCount: 4,
            failureCount: 0,
            createdAt: Date(),
            lastUpdatedAt: Date()
        )

        let route = await DispatchRouteResolver.resolve(
            command: "Open Slack.",
            contextPacket: nil,
            snapshots: [],
            learnedBinding: wrongBinding
        )

        XCTAssertEqual(route.source, .deterministicLocal)
        guard case .openApp(let name)? = route.action else {
            return XCTFail("Expected openApp action")
        }
        XCTAssertEqual(name, "Slack")
    }

    func testCurrentFieldCommandUsesContextAwareLocalRoute() async {
        let route = await DispatchRouteResolver.resolve(
            command: "write done in this box",
            contextPacket: contextPacket(appName: "Slack", kind: .chat, fieldKind: .compose),
            snapshots: []
        )

        XCTAssertEqual(route.card.intent, .activeText)
        XCTAssertEqual(route.source, .deterministicLocal)

        guard case .typeText(let text, let appHint)? = route.action else {
            return XCTFail("Expected typeText action")
        }
        XCTAssertEqual(text, "done")
        XCTAssertEqual(appHint, "Slack")
    }

    func testInferenceRoutesContextualReplyBeforeCloudClassifier() async {
        let route = await DispatchRouteResolver.resolve(
            command: "reply here that I can do it tomorrow",
            contextPacket: contextPacket(appName: "Google Chrome", kind: .email, fieldKind: .reply),
            snapshots: []
        )

        XCTAssertEqual(route.card.intent, .activeText)
        XCTAssertEqual(route.source, .deterministicLocal)
        XCTAssertTrue(route.reason.contains("Local inference"))

        guard case .typeText(let text, let appHint)? = route.action else {
            return XCTFail("Expected typeText action")
        }
        XCTAssertEqual(text, "I can do it tomorrow")
        XCTAssertEqual(appHint, "Google Chrome")
    }

    private func snapshot(
        appName: String,
        bundleId: String,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        codeFileName: String? = nil,
        slackRecipient: String? = nil,
        focusedFieldContent: String? = nil,
        visibleTextSnippets: [String] = [],
        browserTabs: [String] = []
    ) -> DispatchRouteSnapshot {
        DispatchRouteSnapshot(
            timestamp: Date().addingTimeInterval(-60),
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            codeFileName: codeFileName,
            slackRecipient: slackRecipient,
            focusedFieldContent: focusedFieldContent,
            visibleTextSnippets: visibleTextSnippets,
            browserTabs: browserTabs
        )
    }

    private func contextPacket(
        appName: String,
        kind: SurfaceKind,
        fieldKind: FieldKind
    ) -> ContextPacket {
        ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: SurfaceDescriptor(
                kind: kind,
                appName: appName,
                bundleId: nil,
                windowTitle: "\(appName) window",
                browserURL: nil,
                siteHost: nil,
                siteName: nil,
                fieldKind: fieldKind,
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
            targetFingerprint: nil,
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
    }
}
