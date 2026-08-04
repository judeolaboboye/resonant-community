import XCTest
@testable import Resonant

@MainActor
final class DispatchAmbientMemoryProfileTests: XCTestCase {
    func testSuccessfulTextRouteBecomesAmbientMemoryForSameNativeAppTarget() {
        let now = Date()
        let priorContext = contextPacket(
            appName: "Discord",
            bundleId: "com.hnc.Discord",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "message-field")
        )
        let currentContext = priorContext
        let log = dispatchLog(
            command: "tell them I am on it",
            contextPacket: priorContext,
            action: .typeText(text: "I am on it", appHint: "Discord"),
            routeCard: activeTextCard(),
            timestamp: now.addingTimeInterval(-60)
        )

        let profile = DispatchAmbientMemoryProfile.build(
            contextPacket: currentContext,
            snapshots: [],
            logs: [log],
            now: now
        )
        let inferred = profile.inferredIntent(
            command: "tell them shipped",
            contextPacket: currentContext,
            snapshots: []
        )

        guard case .typeText(let text, let appHint)? = inferred?.action else {
            return XCTFail("Expected remembered typeText action")
        }
        XCTAssertEqual(text, "shipped")
        XCTAssertEqual(appHint, "Discord")
        XCTAssertTrue(inferred?.reason.contains("Ambient memory") == true)
    }

    func testNativeAppMemoryDoesNotBleedIntoBrowserTabForSameService() {
        let now = Date()
        let nativeContext = contextPacket(
            appName: "Discord",
            bundleId: "com.hnc.Discord",
            kind: .chat,
            fieldKind: .compose
        )
        let browserContext = contextPacket(
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            kind: .chat,
            fieldKind: .compose,
            browserURL: "https://discord.com/channels/1/2",
            siteHost: "discord.com"
        )
        let log = dispatchLog(
            command: "tell them I am on it",
            contextPacket: nativeContext,
            action: .typeText(text: "I am on it", appHint: "Discord"),
            routeCard: activeTextCard(),
            timestamp: now.addingTimeInterval(-60)
        )

        let profile = DispatchAmbientMemoryProfile.build(
            contextPacket: browserContext,
            snapshots: [],
            logs: [log],
            now: now
        )

        XCTAssertNil(profile.inferredIntent(
            command: "tell them shipped",
            contextPacket: browserContext,
            snapshots: []
        ))
    }

    func testTextMemoryDoesNotRunWhenAXTargetChanged() {
        let now = Date()
        let priorContext = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "message-field")
        )
        let currentContext = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "search-field")
        )
        let log = dispatchLog(
            command: "tell them I am on it",
            contextPacket: priorContext,
            action: .typeText(text: "I am on it", appHint: "Slack"),
            routeCard: activeTextCard(),
            timestamp: now.addingTimeInterval(-60)
        )

        let profile = DispatchAmbientMemoryProfile.build(
            contextPacket: currentContext,
            snapshots: [],
            logs: [log],
            now: now
        )

        XCTAssertNil(profile.inferredIntent(
            command: "tell them shipped",
            contextPacket: currentContext,
            snapshots: []
        ))
    }

    func testTextMemoryDoesNotRunWhenCurrentAXTargetIsMissing() {
        let now = Date()
        let priorContext = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "message-field")
        )
        let currentContext = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose
        )
        let log = dispatchLog(
            command: "tell them I am on it",
            contextPacket: priorContext,
            action: .typeText(text: "I am on it", appHint: "Slack"),
            routeCard: activeTextCard(),
            timestamp: now.addingTimeInterval(-60)
        )

        let profile = DispatchAmbientMemoryProfile.build(
            contextPacket: currentContext,
            snapshots: [],
            logs: [log],
            now: now
        )

        XCTAssertNil(profile.inferredIntent(
            command: "tell them shipped",
            contextPacket: currentContext,
            snapshots: []
        ))
    }

    func testAgentWorkflowCanBeReusedFromAmbientMemoryForVagueCleanupCommand() {
        let now = Date()
        let context = contextPacket(
            appName: "Terminal",
            bundleId: "com.apple.Terminal",
            kind: .terminal,
            fieldKind: .terminal,
            windowTitle: "Conductor - feature-branch"
        )
        let log = dispatchLog(
            command: "ask Devin to fix dispatch commands",
            contextPacket: context,
            action: .delegateToAgent(
                agent: .devin,
                prompt: "ask Devin to fix dispatch commands",
                context: "Workspace: /Users/dev/conductor/workspaces/example-project/feature-branch"
            ),
            routeCard: agentCard(),
            timestamp: now.addingTimeInterval(-120)
        )

        let profile = DispatchAmbientMemoryProfile.build(
            contextPacket: context,
            snapshots: [],
            logs: [log],
            now: now
        )
        let inferred = profile.inferredIntent(
            command: "clean this up",
            contextPacket: context,
            snapshots: []
        )

        guard case .delegateToAgent(let agent, let prompt, let explicitContext)? = inferred?.action else {
            return XCTFail("Expected remembered agent delegation")
        }
        XCTAssertEqual(agent, .devin)
        XCTAssertEqual(prompt, "clean this up")
        XCTAssertTrue(explicitContext?.contains("feature-branch") == true)
    }

    private func dispatchLog(
        command: String,
        contextPacket: ContextPacket,
        action: CommandAction,
        routeCard: DispatchRouteCard,
        timestamp: Date
    ) -> DispatchLogEntry {
        DispatchLogEntry(
            id: UUID(),
            timestamp: timestamp,
            command: command,
            commandPattern: DispatchLearningStore.commandTokens(for: command).joined(separator: " "),
            routeCard: routeCard,
            action: action,
            actionSummary: nil,
            confidence: 0.86,
            evidence: [],
            surface: DispatchLearningStore.surfaceFingerprint(contextPacket: contextPacket, snapshots: []),
            resultSuccess: true,
            resultSummary: "ok",
            learnedBindingID: nil,
            correctionKind: nil,
            routeSource: .deterministicLocal,
            routeReason: "test route",
            failureStage: nil,
            targetCheck: nil,
            correctedLogID: nil
        )
    }

    private func activeTextCard() -> DispatchRouteCard {
        DispatchRouteCard(
            id: "active.text",
            intent: .activeText,
            title: "Active text field",
            surface: "Discord",
            action: "Insert text into focused field",
            validator: "PasteManager delivery succeeded",
            disturbance: .activeSurface
        )
    }

    private func agentCard() -> DispatchRouteCard {
        DispatchRouteCard(
            id: "agent.devin.Conductor terminal",
            intent: .agentDelegation,
            title: "Devin via Conductor terminal",
            surface: "Conductor terminal",
            action: "Prepare agent task",
            validator: "Agent prompt prepared with local context",
            disturbance: .preparedOnly
        )
    }

    private func contextPacket(
        appName: String,
        bundleId: String,
        kind: SurfaceKind,
        fieldKind: FieldKind,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        siteHost: String? = nil,
        targetFingerprint: ContextTargetFingerprint? = nil
    ) -> ContextPacket {
        ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: SurfaceDescriptor(
                kind: kind,
                appName: appName,
                bundleId: bundleId,
                windowTitle: windowTitle ?? "\(appName) window",
                browserURL: browserURL,
                siteHost: siteHost,
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
            targetFingerprint: targetFingerprint,
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
    }

    private func targetFingerprint(placeholderToken: String) -> ContextTargetFingerprint {
        ContextTargetFingerprint(
            role: "AXTextArea",
            subrole: nil,
            identifierToken: nil,
            titleToken: nil,
            descriptionToken: nil,
            placeholderToken: placeholderToken,
            helpToken: nil,
            frameBucket: "10:10:4:1",
            selectedRangeBucket: nil
        )
    }
}
