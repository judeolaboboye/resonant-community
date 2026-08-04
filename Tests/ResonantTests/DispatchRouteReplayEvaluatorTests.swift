import XCTest
@testable import Resonant

@MainActor
final class DispatchRouteReplayEvaluatorTests: XCTestCase {
    func testCoreReplayScenariosPass() async {
        let results = await DispatchRouteReplayEvaluator.evaluate(Self.coreScenarios())
        let failures = results.flatMap(\.failures)

        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
        XCTAssertTrue(results.allSatisfy(\.passed))
    }

    func testReplayScenarioCanRoundTripAsRecordedFixture() throws {
        let scenario = Self.coreScenarios()[0]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(scenario)
        let decoded = try JSONDecoder().decode(DispatchRouteReplayScenario.self, from: data)

        XCTAssertEqual(decoded.id, scenario.id)
        XCTAssertEqual(decoded.command, scenario.command)
        XCTAssertEqual(decoded.expectation.source, scenario.expectation.source)
        XCTAssertEqual(decoded.snapshots, scenario.snapshots)
    }

    func testFixtureBuilderPromotesFailedLogToRunnableScenario() {
        let log = Self.failedGuardLog()

        let scenarios = DispatchRouteReplayFixtureBuilder.scenarios(
            from: [log],
            failuresOnly: true,
            privacy: .raw
        )

        XCTAssertEqual(scenarios.count, 1)
        XCTAssertEqual(scenarios[0].command, "send the update here")
        XCTAssertNotNil(scenarios[0].learnedBinding)
        XCTAssertEqual(scenarios[0].expectation.plan?.capabilityStatus, .degraded)
        XCTAssertEqual(scenarios[0].expectation.plan?.fallback, "clipboard draft")
        XCTAssertEqual(scenarios[0].expectation.targetGuard?.shouldAllow, false)
    }

    func testFixtureBuilderRedactsByDefaultPayload() {
        let payload = DispatchRouteReplayFixtureBuilder.payload(
            from: [Self.failedGuardLog()],
            failuresOnly: true,
            privacy: .redacted
        )
        let object = payload.objectValue ?? [:]

        XCTAssertEqual(object["privacy"], .string("redacted"))
        XCTAssertEqual(object["runnable"], .bool(false))
        XCTAssertTrue(object["json"]?.stringValue?.contains("[redacted command]") == true)
    }

    private static func coreScenarios() -> [DispatchRouteReplayScenario] {
        let slackTarget = targetFingerprint(placeholderToken: "message-field", frameBucket: "10:10:4:1")
        let slackContext = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            conversationLabel: "resonant",
            targetFingerprint: slackTarget
        )
        let slackContextMissingAX = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            conversationLabel: "resonant"
        )
        let slackBinding = learnedSlackBinding(context: slackContext)

        return [
            DispatchRouteReplayScenario(
                id: "weather-google-vienna",
                name: "Weather command opens Google weather for Vienna",
                command: "get me the weather on Google in Vienna",
                expectation: DispatchRouteExpectation(
                    routeID: "browser.open",
                    intent: .openURL,
                    source: .deterministicLocal,
                    minimumConfidence: 0.9,
                    titleContains: "Google weather",
                    action: .openURL(requiredFragments: [
                        "google.com/search",
                        "weather%20Vienna"
                    ])
                )
            ),
            DispatchRouteReplayScenario(
                id: "devin-conductor-terminal",
                name: "Agent delegation uses recent Conductor terminal context",
                command: "give Devin a new task to fix dispatch commands",
                snapshots: [
                    snapshot(
                        appName: "Terminal",
                        bundleId: "com.apple.Terminal",
                        windowTitle: "Conductor - Devin",
                        focusedFieldContent: "cd /Users/dev/conductor/workspaces/example-project/feature-branch",
                        visibleTextSnippets: ["devin task in conductor for parakeet-swift"]
                    )
                ],
                expectation: DispatchRouteExpectation(
                    intent: .agentDelegation,
                    source: .deterministicLocal,
                    minimumConfidence: 0.6,
                    surfaceContains: "Conductor",
                    evidenceContains: ["workspace path"],
                    action: .agent(.devin),
                    plan: DispatchPlanExpectation(
                        capabilityStatus: .degraded,
                        executionStrategy: .agentHandoff,
                        surfaceKind: .devin,
                        fallback: "clipboard agent handoff",
                        requiresAPI: true
                    )
                )
            ),
            DispatchRouteReplayScenario(
                id: "unknown-needs-cloud",
                name: "Unknown command goes to cloud classifier",
                command: "handle the thing from earlier",
                expectation: DispatchRouteExpectation(
                    routeID: "cloud.classifier",
                    intent: .cloudClassification,
                    source: .cloudClassifier,
                    action: DispatchActionExpectation.none
                )
            ),
            DispatchRouteReplayScenario(
                id: "cloud-type-text-current-field",
                name: "Replayed cloud action routes to active text field",
                command: "write done in this box",
                contextPacket: slackContext,
                preferredAction: .typeText(text: "Done", appHint: "Slack"),
                preferredSource: .cloudAction,
                preferredReason: "Recorded cloud action from classifier fixture.",
                expectation: DispatchRouteExpectation(
                    routeID: "active.text",
                    intent: .activeText,
                    source: .cloudAction,
                    minimumConfidence: 0.7,
                    surfaceContains: "Slack",
                    action: .typeText(appHint: "Slack")
                )
            ),
            DispatchRouteReplayScenario(
                id: "learned-slack-missing-ax",
                name: "Learned active-surface route blocks when current AX target is missing",
                command: "usual team update",
                contextPacket: slackContextMissingAX,
                learnedBinding: slackBinding,
                expectation: DispatchRouteExpectation(
                    routeID: "slack.post",
                    intent: .slackDraft,
                    source: .learnedBinding,
                    minimumConfidence: 0.84,
                    learnedBindingRequired: true,
                    action: .slack(channel: "resonant"),
                    plan: DispatchPlanExpectation(
                        capabilityStatus: .degraded,
                        executionStrategy: .clipboardDraft,
                        surfaceKind: .slack,
                        fallback: "clipboard draft",
                        requiresAPI: true
                    ),
                    targetGuard: DispatchTargetGuardExpectation(
                        shouldAllow: false,
                        summaryContains: "can't verify"
                    )
                )
            )
        ]
    }

    private static func learnedSlackBinding(context: ContextPacket) -> DispatchLearningBinding {
        DispatchLearningBinding(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            commandPattern: "usual team update",
            commandTokens: ["usual", "team", "update"],
            surface: DispatchLearningStore.surfaceFingerprint(contextPacket: context, snapshots: []),
            routeCard: slackRouteCard(),
            action: .postSlack(channel: "resonant", message: "I fixed it"),
            confidence: 0.84,
            successCount: 3,
            failureCount: 0,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            lastUpdatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )
    }

    private static func failedGuardLog() -> DispatchLogEntry {
        let context = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            conversationLabel: "resonant",
            targetFingerprint: targetFingerprint(placeholderToken: "message-field", frameBucket: "10:10:4:1")
        )
        return DispatchLogEntry(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            timestamp: Date(timeIntervalSinceReferenceDate: 5_000),
            command: "send the update here",
            commandPattern: "send update here",
            routeCard: slackRouteCard(),
            action: .postSlack(channel: "resonant", message: "Done"),
            actionSummary: "post_slack:resonant",
            confidence: 0.84,
            evidence: ["Target guard blocked active-surface execution."],
            surface: DispatchLearningStore.surfaceFingerprint(contextPacket: context, snapshots: []),
            resultSuccess: false,
            resultSummary: "Target changed.",
            learnedBindingID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            correctionKind: nil,
            routeSource: .learnedBinding,
            routeReason: "A learned local binding matched this command and the current surface.",
            failureStage: .targetGuard,
            targetCheck: DispatchTargetCheck(
                required: true,
                expectedAXTarget: true,
                currentAXTarget: false,
                matchScore: nil,
                minimumScore: 0.52,
                summary: "I can't verify the target text box."
            )
        )
    }

    private static func slackRouteCard() -> DispatchRouteCard {
        DispatchRouteCard(
            id: "slack.post",
            intent: .slackDraft,
            title: "Slack route",
            surface: "#resonant",
            action: "Prepare or type Slack message",
            validator: "Slack payload prepared or active field delivery succeeded",
            disturbance: .activeSurface
        )
    }

    private static func snapshot(
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
            timestamp: Date(timeIntervalSinceReferenceDate: 3_000),
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

    private static func contextPacket(
        appName: String,
        bundleId: String,
        kind: SurfaceKind,
        fieldKind: FieldKind,
        conversationLabel: String? = nil,
        targetFingerprint: ContextTargetFingerprint? = nil
    ) -> ContextPacket {
        ContextPacket(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            capturedAt: Date(timeIntervalSinceReferenceDate: 4_000),
            surface: SurfaceDescriptor(
                kind: kind,
                appName: appName,
                bundleId: bundleId,
                windowTitle: "\(appName) window",
                browserURL: nil,
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

    private static func targetFingerprint(
        placeholderToken: String,
        frameBucket: String
    ) -> ContextTargetFingerprint {
        ContextTargetFingerprint(
            role: "AXTextArea",
            subrole: nil,
            identifierToken: nil,
            titleToken: nil,
            descriptionToken: nil,
            placeholderToken: placeholderToken,
            helpToken: nil,
            frameBucket: frameBucket,
            selectedRangeBucket: nil
        )
    }
}
