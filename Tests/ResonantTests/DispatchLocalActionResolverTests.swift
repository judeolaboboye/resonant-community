import XCTest
@testable import Resonant

final class DispatchLocalActionResolverTests: XCTestCase {
    func testWeatherOnGoogleCommandOpensGoogleWeatherSearch() {
        let action = DispatchLocalActionResolver.deterministicAction(
            for: "get me the weather on Google in Vienna"
        )

        guard case .openURL(let url)? = action else {
            return XCTFail("Expected openURL action")
        }

        XCTAssertTrue(url.hasPrefix("https://www.google.com/search?"))
        XCTAssertTrue(url.contains("q=weather%20Vienna"))
    }

    func testWeatherInLocationOnGoogleOrderAlsoWorks() {
        let action = DispatchLocalActionResolver.deterministicAction(
            for: "show weather in Vienna on Google"
        )

        guard case .openURL(let url)? = action else {
            return XCTFail("Expected openURL action")
        }

        XCTAssertTrue(url.contains("q=weather%20Vienna"))
    }

    func testWeatherCommandDoesNotRequireGoogleWord() {
        let action = DispatchLocalActionResolver.deterministicAction(
            for: "weather in Vienna"
        )

        guard case .openURL(let url)? = action else {
            return XCTFail("Expected openURL action")
        }

        XCTAssertTrue(url.contains("q=weather%20Vienna"))
    }

    func testFallbackRoutesDevinCommandsToAgentDelegation() {
        let action = DispatchLocalActionResolver.fallbackAction(
            for: "give Devin a new task to fix the onboarding crash"
        )

        guard case .delegateToAgent(let agent, let prompt, _)? = action else {
            return XCTFail("Expected delegateToAgent action")
        }

        XCTAssertEqual(agent, .devin)
        XCTAssertTrue(prompt.contains("onboarding crash"))
    }

    func testFallbackRoutesDevonMisrecognitionToDevinDelegation() {
        let action = DispatchLocalActionResolver.fallbackAction(
            for: "ask Devon to fix the onboarding crash"
        )

        guard case .delegateToAgent(let agent, let prompt, _)? = action else {
            return XCTFail("Expected delegateToAgent action")
        }

        XCTAssertEqual(agent, .devin)
        XCTAssertTrue(prompt.contains("onboarding crash"))
    }

    func testActionUsesDeterministicRouteBeforeAgentFallback() {
        let action = DispatchLocalActionResolver.action(
            for: "ask Devin for weather in Vienna"
        )

        guard case .openURL(let url)? = action else {
            return XCTFail("Expected weather shortcut to win")
        }
        XCTAssertTrue(url.contains("q=weather%20Vienna"))
    }

    func testGoogleSearchCommandOpensGoogleSearch() {
        let action = DispatchLocalActionResolver.deterministicAction(
            for: "search Google for Swift concurrency actors"
        )

        guard case .openURL(let url)? = action else {
            return XCTFail("Expected openURL action")
        }
        XCTAssertTrue(url.contains("google.com/search"))
        XCTAssertTrue(url.contains("Swift%20concurrency%20actors"))
    }

    func testOpenKnownAppCommandOpensApp() {
        let action = DispatchLocalActionResolver.deterministicAction(for: "open Slack")

        guard case .openApp(let name)? = action else {
            return XCTFail("Expected openApp action")
        }
        XCTAssertEqual(name, "Slack")
    }

    func testOpenKnownAppCommandHandlesVoicePhrasing() {
        let commands = [
            "Open Slack.",
            "open up the Slack app please",
            "bring up Slack window"
        ]

        for command in commands {
            let action = DispatchLocalActionResolver.deterministicAction(for: command)
            guard case .openApp(let name)? = action else {
                return XCTFail("Expected openApp action for \(command)")
            }
            XCTAssertEqual(name, "Slack")
        }
    }

    func testWorkspaceSearchCommandStaysLocal() {
        let action = DispatchLocalActionResolver.deterministicAction(
            for: "what did I say about dispatch routing"
        )

        guard case .searchWorkspace(let query)? = action else {
            return XCTFail("Expected searchWorkspace action")
        }
        XCTAssertEqual(query, "dispatch routing")
    }

    func testExplicitURLCommandOpensURL() {
        let action = DispatchLocalActionResolver.deterministicAction(for: "open example.com/docs")

        guard case .openURL(let url)? = action else {
            return XCTFail("Expected openURL action")
        }
        XCTAssertEqual(url, "https://example.com/docs")
    }

    func testCurrentComposeFieldCommandTypesIntoActiveApp() {
        let action = DispatchLocalActionResolver.deterministicAction(
            for: "write done in this box",
            contextPacket: contextPacket(appName: "Slack", kind: .chat, fieldKind: .compose)
        )

        guard case .typeText(let text, let appHint)? = action else {
            return XCTFail("Expected typeText action")
        }
        XCTAssertEqual(text, "done")
        XCTAssertEqual(appHint, "Slack")
    }

    func testCurrentCommentCommandTypesIntoCommentField() {
        let action = DispatchLocalActionResolver.deterministicAction(
            for: "comment LGTM",
            contextPacket: contextPacket(appName: "Safari", kind: .browser, fieldKind: .comment)
        )

        guard case .typeText(let text, let appHint)? = action else {
            return XCTFail("Expected typeText action")
        }
        XCTAssertEqual(text, "LGTM")
        XCTAssertEqual(appHint, "Safari")
    }

    func testLinearTicketCommandCreatesTicketDraft() {
        let action = DispatchLocalActionResolver.deterministicAction(
            for: "create a Linear ticket to fix dispatch commands"
        )

        guard case .createTicket(let title, let body, let service)? = action else {
            return XCTFail("Expected createTicket action")
        }
        XCTAssertEqual(service, .linear)
        XCTAssertEqual(title, "fix dispatch commands")
        XCTAssertTrue(body.contains("create a Linear ticket"))
    }

    func testGitHubIssueCommandCreatesGitHubDraft() {
        let action = DispatchLocalActionResolver.deterministicAction(
            for: "file a GitHub issue for the onboarding crash"
        )

        guard case .createTicket(let title, _, let service)? = action else {
            return XCTFail("Expected createTicket action")
        }
        XCTAssertEqual(service, .github)
        XCTAssertEqual(title, "the onboarding crash")
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
