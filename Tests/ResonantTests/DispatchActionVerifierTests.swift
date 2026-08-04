import XCTest
@testable import Resonant

final class DispatchActionVerifierTests: XCTestCase {
    func testTextInsertionPassesWhenFocusedFieldContainsInsertedText() {
        let verification = DispatchActionVerifier.evaluate(
            action: .typeText(text: "testing dispatch", appHint: nil),
            route: route(id: "active.text", intent: .activeText),
            executionResult: .ok("Typed into Notes"),
            before: probe(field: ""),
            after: probe(field: "testing dispatch")
        )

        XCTAssertEqual(verification.verdict, .passed)
        XCTAssertEqual(verification.evidence["focused_field_contains_inserted_text"], "true")
    }

    func testTextInsertionIsInconclusiveWhenFocusedFieldWasUnchanged() {
        let verification = DispatchActionVerifier.evaluate(
            action: .typeText(text: "Done", appHint: nil),
            route: route(id: "active.text", intent: .activeText),
            executionResult: .ok("Typed into Notes"),
            before: probe(field: "Done"),
            after: probe(field: "Done")
        )

        XCTAssertEqual(verification.verdict, .inconclusive)
        XCTAssertFalse(verification.verdict.permitsLearning)
        XCTAssertEqual(verification.evidence["focused_field_changed"], "false")
    }

    func testTextInsertionIsInconclusiveWhenFieldCannotBeReadBack() {
        let verification = DispatchActionVerifier.evaluate(
            action: .typeText(text: "testing dispatch", appHint: nil),
            route: route(id: "active.text", intent: .activeText),
            executionResult: .ok("Typed into Discord"),
            before: probe(field: nil),
            after: probe(field: nil)
        )

        XCTAssertEqual(verification.verdict, .inconclusive)
        XCTAssertFalse(verification.verdict.permitsLearning)
    }

    func testTextInsertionFailsWhenFieldDoesNotContainText() {
        let verification = DispatchActionVerifier.evaluate(
            action: .typeText(text: "testing dispatch", appHint: nil),
            route: route(id: "active.text", intent: .activeText),
            executionResult: .ok("Typed into Notes"),
            before: probe(field: ""),
            after: probe(field: "different text")
        )

        XCTAssertEqual(verification.verdict, .failed)
        XCTAssertEqual(verification.failureStage, .verification)
    }

    func testOpenAppPassesOnlyWhenExpectedAppIsFrontmost() {
        let pass = DispatchActionVerifier.evaluate(
            action: .openApp(name: "Slack"),
            route: route(id: "app.open.slack", intent: .openApp),
            executionResult: .ok("Opened Slack"),
            before: probe(app: "Finder", bundleID: "com.apple.finder"),
            after: probe(app: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        )
        let fail = DispatchActionVerifier.evaluate(
            action: .openApp(name: "Slack"),
            route: route(id: "app.open.slack", intent: .openApp),
            executionResult: .ok("Opened Slack"),
            before: probe(app: "Finder", bundleID: "com.apple.finder"),
            after: probe(app: "Discord", bundleID: "com.hnc.Discord")
        )

        XCTAssertEqual(pass.verdict, .passed)
        XCTAssertEqual(fail.verdict, .failed)
    }

    func testOpenAppPassesWhenExpectedAppIsActiveWebSurface() {
        let verification = DispatchActionVerifier.evaluate(
            action: .openApp(name: "Slack"),
            route: route(id: "app.open.slack", intent: .openApp),
            executionResult: .ok("Opened Slack"),
            before: probe(app: "Finder", bundleID: "com.apple.finder"),
            after: probe(
                app: "Arc",
                bundleID: "company.thebrowser.browser",
                browserURL: "https://app.slack.com/client/T123/C456"
            )
        )

        XCTAssertEqual(verification.verdict, .passed)
        XCTAssertEqual(verification.evidence["after_surface_app"], "slack")
        XCTAssertEqual(verification.evidence["after_surface_variant"], "web")
    }

    func testOpenAppIsInconclusiveWhenForegroundDidNotChangeYet() {
        let verification = DispatchActionVerifier.evaluate(
            action: .openApp(name: "Slack"),
            route: route(id: "app.open.slack", intent: .openApp),
            executionResult: .ok("Opened Slack"),
            before: probe(app: "Finder", bundleID: "com.apple.finder"),
            after: probe(app: "Finder", bundleID: "com.apple.finder")
        )

        XCTAssertEqual(verification.verdict, .inconclusive)
        XCTAssertFalse(verification.verdict.permitsLearning)
    }

    func testPreparedTicketVerifiesClipboardPayload() {
        let verification = DispatchActionVerifier.evaluate(
            action: .createTicket(title: "Fix dispatch", body: "Silent failure repro", service: .linear),
            route: route(id: "ticket.linear", intent: .ticketDraft),
            executionResult: .ok("Linear ticket ready: Fix dispatch"),
            before: probe(clipboard: nil),
            after: probe(clipboard: "Title: Fix dispatch\nBody: Silent failure repro")
        )

        XCTAssertEqual(verification.verdict, .passed)
        XCTAssertEqual(verification.evidence["clipboard_contains_title"], "true")
        XCTAssertEqual(verification.evidence["clipboard_contains_body"], "true")
    }

    func testAgentDelegationRequiresExpectedAgentMarkerForNonDevinAgents() {
        let pass = DispatchActionVerifier.evaluate(
            action: .delegateToAgent(agent: .claudeCode, prompt: "fix dispatch", context: nil),
            route: route(id: "agent.claude_code", intent: .agentDelegation),
            executionResult: .ok("Copied Claude Code prompt"),
            before: probe(clipboard: nil),
            after: probe(clipboard: "Agent: claudeCode\nTask prompt: fix dispatch")
        )
        let missingAgent = DispatchActionVerifier.evaluate(
            action: .delegateToAgent(agent: .claudeCode, prompt: "fix dispatch", context: nil),
            route: route(id: "agent.claude_code", intent: .agentDelegation),
            executionResult: .ok("Copied Claude Code prompt"),
            before: probe(clipboard: nil),
            after: probe(clipboard: "Agent: devin\nTask prompt: fix dispatch")
        )

        XCTAssertEqual(pass.verdict, .passed)
        XCTAssertEqual(missingAgent.verdict, .inconclusive)
        XCTAssertEqual(missingAgent.evidence["clipboard_contains_agent"], "false")
    }

    func testOpenURLPassesWhenActiveBrowserTabMatches() {
        let verification = DispatchActionVerifier.evaluate(
            action: .openURL(url: "https://linear.app/resonant/issue/RES-123/fix-dispatch"),
            route: route(id: "browser.open", intent: .openURL),
            executionResult: .ok("Opened linear.app"),
            before: probe(app: "Arc", bundleID: "company.thebrowser.browser", browserURL: "https://google.com"),
            after: probe(
                app: "Arc",
                bundleID: "company.thebrowser.browser",
                browserURL: "https://linear.app/resonant/issue/RES-123/fix-dispatch"
            )
        )

        XCTAssertEqual(verification.verdict, .passed)
        XCTAssertEqual(verification.evidence["browser_host_matches_expected"], "true")
    }

    func testOpenURLFailsWhenBrowserChangedToWrongHost() {
        let verification = DispatchActionVerifier.evaluate(
            action: .openURL(url: "https://linear.app/resonant/issue/RES-123/fix-dispatch"),
            route: route(id: "browser.open", intent: .openURL),
            executionResult: .ok("Opened linear.app"),
            before: probe(app: "Arc", bundleID: "company.thebrowser.browser", browserURL: "https://google.com"),
            after: probe(app: "Arc", bundleID: "company.thebrowser.browser", browserURL: "https://discord.com/channels/1/2")
        )

        XCTAssertEqual(verification.verdict, .failed)
        XCTAssertEqual(verification.failureStage, .verification)
    }

    func testOpenURLIsInconclusiveWhenBrowserURLCannotBeRead() {
        let verification = DispatchActionVerifier.evaluate(
            action: .openURL(url: "https://linear.app/resonant/issue/RES-123/fix-dispatch"),
            route: route(id: "browser.open", intent: .openURL),
            executionResult: .ok("Opened linear.app"),
            before: probe(app: "Arc", bundleID: "company.thebrowser.browser", browserURL: nil),
            after: probe(app: "Arc", bundleID: "company.thebrowser.browser", browserURL: nil)
        )

        XCTAssertEqual(verification.verdict, .inconclusive)
        XCTAssertFalse(verification.verdict.permitsLearning)
    }

    func testNotificationReplyPassesWhenActiveSurfaceMatchesNotificationEvidence() {
        let verification = DispatchActionVerifier.evaluate(
            action: .typeText(text: "I am on it", appHint: "Slack"),
            route: notificationRoute(),
            executionResult: .ok("Typed into Slack"),
            before: probe(app: "Slack", bundleID: "com.tinyspeck.slackmacgap", field: ""),
            after: probe(app: "Slack", bundleID: "com.tinyspeck.slackmacgap", field: "I am on it")
        )

        XCTAssertEqual(verification.verdict, .passed)
        XCTAssertEqual(verification.evidence["notification_correlation"], "passed")
    }

    func testNotificationReplyFailsWhenActiveSurfaceDoesNotMatchNotificationEvidence() {
        let verification = DispatchActionVerifier.evaluate(
            action: .typeText(text: "I am on it", appHint: "Slack"),
            route: notificationRoute(),
            executionResult: .ok("Typed into Discord"),
            before: probe(app: "Discord", bundleID: "com.hnc.Discord", field: ""),
            after: probe(app: "Discord", bundleID: "com.hnc.Discord", field: "I am on it")
        )

        XCTAssertEqual(verification.verdict, .failed)
        XCTAssertEqual(verification.failureStage, .verification)
        XCTAssertEqual(verification.evidence["notification_correlation"], "failed")
    }

    func testNotificationReplyPassesWhenSlackNotificationMatchesSlackBrowserTab() {
        let verification = DispatchActionVerifier.evaluate(
            action: .typeText(text: "I am on it", appHint: "Slack"),
            route: notificationRoute(),
            executionResult: .ok("Typed into Slack"),
            before: probe(app: "Arc", bundleID: "company.thebrowser.browser", field: ""),
            after: probe(
                app: "Arc",
                bundleID: "company.thebrowser.browser",
                field: "I am on it",
                browserURL: "https://app.slack.com/client/T123/C456"
            )
        )

        XCTAssertEqual(verification.verdict, .passed)
        XCTAssertEqual(verification.evidence["notification_correlation"], "passed")
        XCTAssertEqual(verification.evidence["after_surface_app"], "slack")
    }

    func testNotificationReplyFailsWhenConversationDoesNotMatchNotificationEvidence() {
        let verification = DispatchActionVerifier.evaluate(
            action: .typeText(text: "I am on it", appHint: "Slack"),
            route: notificationRoute(evidence: [
                "Recent notification: Slack | Alex in #channel-a | Can you check dispatch?",
                "Notification conversation: #channel-a",
                "Current app: Slack",
                "Focused field: reply"
            ]),
            executionResult: .ok("Typed into Slack"),
            before: probe(app: "Arc", bundleID: "company.thebrowser.browser", field: ""),
            after: probe(
                app: "Arc",
                bundleID: "company.thebrowser.browser",
                field: "I am on it",
                browserURL: "https://app.slack.com/client/T123/C999",
                browserTitle: "#channel-b | Slack"
            )
        )

        XCTAssertEqual(verification.verdict, .failed)
        XCTAssertEqual(verification.failureStage, .verification)
        XCTAssertEqual(verification.evidence["notification_correlation"], "failed")
    }

    func testPostSlackFailsWhenTextLandsInWrongKnownSurface() {
        let verification = DispatchActionVerifier.evaluate(
            action: .postSlack(channel: "resonant", message: "I am on it"),
            route: route(id: "slack.post", intent: .activeText),
            executionResult: .ok("Typed Slack message"),
            before: probe(app: "Discord", bundleID: "com.hnc.Discord", field: ""),
            after: probe(app: "Discord", bundleID: "com.hnc.Discord", field: "I am on it")
        )

        XCTAssertEqual(verification.verdict, .failed)
        XCTAssertEqual(verification.failureStage, .verification)
        XCTAssertEqual(verification.evidence["after_surface_app"], "discord")
    }

    func testSurfaceResolverRecognizesNativeAndWebApplicationSurfaces() {
        let nativeDiscord = DispatchAppSurfaceResolver.resolve(
            appName: "Discord",
            bundleID: "com.hnc.Discord",
            browserTitle: nil,
            browserURL: nil
        )
        let webLinear = DispatchAppSurfaceResolver.resolve(
            appName: "Arc",
            bundleID: "company.thebrowser.browser",
            browserTitle: "Linear",
            browserURL: "https://linear.app/resonant/issue/RES-1"
        )

        XCTAssertEqual(nativeDiscord.kind, .discord)
        XCTAssertEqual(nativeDiscord.variant, .native)
        XCTAssertEqual(webLinear.kind, .linear)
        XCTAssertEqual(webLinear.variant, .web)
    }

    private func probe(
        app: String? = nil,
        bundleID: String? = nil,
        field: String? = nil,
        clipboard: String? = nil,
        browserURL: String? = nil,
        browserTitle: String? = nil
    ) -> DispatchActionProbe {
        DispatchActionProbe(
            frontmostAppName: app,
            frontmostBundleID: bundleID,
            focusedFieldContent: field,
            clipboardString: clipboard,
            browserTitle: browserTitle,
            browserURL: browserURL
        )
    }

    private func route(id: String, intent: DispatchRouteIntent) -> DispatchRouteResolution {
        DispatchRouteResolution(
            card: DispatchRouteCard(
                id: id,
                intent: intent,
                title: "Route",
                surface: "Surface",
                action: "Action",
                validator: "Validator",
                disturbance: .activeSurface
            ),
            action: nil,
            confidence: 0.9,
            evidence: [],
            source: .deterministicLocal
        )
    }

    private func notificationRoute(evidence: [String]? = nil) -> DispatchRouteResolution {
        DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "active.text",
                intent: .activeText,
                title: "Active text field",
                surface: "Slack",
                action: "Insert text into focused field",
                validator: "PasteManager delivery succeeded",
                disturbance: .activeSurface
            ),
            action: .typeText(text: "I am on it", appHint: "Slack"),
            confidence: 0.88,
            evidence: evidence ?? [
                "Recent notification: Slack | Alex | Can you check dispatch?",
                "Current app: Slack",
                "Focused field: reply"
            ],
            source: .deterministicLocal
        )
    }
}
