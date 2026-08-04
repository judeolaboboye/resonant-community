import XCTest
@testable import Resonant

@MainActor
final class DispatchLearningStoreTests: XCTestCase {

    func testSuccessfulOutcomeCreatesReusableBinding() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let context = contextPacket(appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", kind: .chat, fieldKind: .compose)
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
            action: .postSlack(channel: "resonant", message: "I fixed it"),
            confidence: 0.82,
            evidence: []
        )

        store.recordOutcome(
            command: "tell the team I fixed it",
            contextPacket: context,
            snapshots: [],
            route: route,
            result: .ok("Slack message ready")
        )

        let binding = store.bestBinding(
            command: "tell team I fixed it",
            contextPacket: context,
            snapshots: []
        )

        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.routeCard.id, "slack.post")
        guard case .postSlack(let channel, _)? = binding?.action else {
            return XCTFail("Expected learned Slack action")
        }
        XCTAssertEqual(channel, "resonant")
    }

    func testVerifiedCloudActionOutcomeCreatesReusableBinding() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let route = DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "app.open.slack",
                intent: .openApp,
                title: "App switch",
                surface: "Slack",
                action: "Activate or launch app",
                validator: "macOS open request succeeded",
                disturbance: .appSwitch
            ),
            action: .openApp(name: "Slack"),
            confidence: 0.82,
            evidence: [],
            source: .cloudAction
        )

        store.recordOutcome(
            command: "show Slack",
            contextPacket: nil,
            snapshots: [],
            route: route,
            result: .ok("Opened Slack")
        )

        XCTAssertNotNil(store.bestBinding(command: "show Slack", contextPacket: nil, snapshots: []))
        XCTAssertTrue(store.logsForTesting.contains { $0.actionSummary == "open_app:Slack" })
    }

    func testSensitiveTextTargetsAreNotLearnedOrReused() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let context = contextPacket(
            appName: "Safari",
            bundleId: "com.apple.Safari",
            kind: .browser,
            fieldKind: .plainText,
            targetFingerprint: targetFingerprint(
                placeholderToken: "password",
                frameBucket: "10:10:20:4",
                isSensitiveInput: true
            )
        )

        store.recordOutcome(
            command: "type ship it",
            contextPacket: context,
            snapshots: [],
            route: textRoute(),
            result: .ok("Typed into Safari")
        )

        XCTAssertNil(store.bestBinding(
            command: "type ship it",
            contextPacket: context,
            snapshots: []
        ))
        XCTAssertTrue(store.logsForTesting.contains { $0.actionSummary == "type_text:Safari" })
        XCTAssertTrue(store.bindingsForTesting.isEmpty)
    }

    func testOutcomeCanLogWithoutUpdatingReusableBindings() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let context = contextPacket(appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", kind: .chat, fieldKind: .compose)

        store.recordOutcome(
            command: "tell the team I fixed it",
            contextPacket: context,
            snapshots: [],
            route: slackRoute(),
            result: .ok("Slack message ready"),
            allowBindingUpdate: false
        )

        XCTAssertEqual(store.logsForTesting.last?.resultSuccess, true)
        XCTAssertTrue(store.bindingsForTesting.isEmpty)
        XCTAssertNil(store.bestBinding(
            command: "tell team I fixed it",
            contextPacket: context,
            snapshots: []
        ))
    }

    func testFailureSuppressesBindingUntilItHasMoreSuccessThanFailure() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let context = contextPacket(appName: "Safari", bundleId: "com.apple.Safari", kind: .browser, fieldKind: .search)
        let route = DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "browser.open",
                intent: .openURL,
                title: "Browser route",
                surface: "google.com",
                action: "Open URL",
                validator: "Workspace accepted URL open request",
                disturbance: .appSwitch
            ),
            action: .openURL(url: "https://google.com/search?q=weather"),
            confidence: 0.9,
            evidence: []
        )

        store.recordOutcome(
            command: "open my usual search",
            contextPacket: context,
            snapshots: [],
            route: route,
            result: .ok("Opened URL")
        )
        store.recordOutcome(
            command: "open my usual search",
            contextPacket: context,
            snapshots: [],
            route: route,
            result: .failed("Wrong target")
        )

        XCTAssertEqual(store.logsForTesting.last?.failureStage, .actionExecution)
        XCTAssertNil(store.bestBinding(
            command: "open usual search",
            contextPacket: context,
            snapshots: []
        ))
    }

    func testSpeechProfileLearnsTrailingSilence() {
        let store = DispatchLearningStore(storageURL: temporaryURL())

        store.recordSpeechTurn(utteranceDuration: 8.0, trailingSilence: 1.8)

        XCTAssertEqual(store.speechProfileForTesting.observedTurns, 1)
        XCTAssertGreaterThan(store.recommendedFollowUpTrailingSilence, 2.0)
        XCTAssertGreaterThan(store.followUpOpenWindow, 8.0)
    }

    func testNegativeCorrectionPenalizesLastBindingAndLogsCorrection() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let context = contextPacket(appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", kind: .chat, fieldKind: .compose)
        let route = slackRoute()

        store.recordOutcome(
            command: "tell the team I fixed it",
            contextPacket: context,
            snapshots: [],
            route: route,
            result: .ok("Slack message ready")
        )
        let correctedLogID = store.logsForTesting.last?.id

        let correction = store.applyCorrection(
            command: "no not there",
            contextPacket: context,
            snapshots: []
        )

        XCTAssertEqual(correction?.kind, .negative)
        XCTAssertEqual(store.bindingsForTesting.first?.failureCount, 1)
        XCTAssertNil(store.bestBinding(command: "tell team I fixed it", contextPacket: context, snapshots: []))
        XCTAssertEqual(store.logsForTesting.last?.correctionKind, .negative)
        XCTAssertEqual(store.logsForTesting.last?.routeSource, .correction)
        XCTAssertEqual(store.logsForTesting.last?.correctedLogID, correctedLogID)
    }

    func testPositiveCorrectionReinforcesLastBinding() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let context = contextPacket(appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", kind: .chat, fieldKind: .compose)

        store.recordOutcome(
            command: "tell the team I fixed it",
            contextPacket: context,
            snapshots: [],
            route: slackRoute(),
            result: .ok("Slack message ready")
        )
        let before = store.bindingsForTesting.first?.confidence ?? 0

        let correction = store.applyCorrection(
            command: "that was right",
            contextPacket: context,
            snapshots: []
        )

        XCTAssertEqual(correction?.kind, .positive)
        XCTAssertGreaterThan(store.bindingsForTesting.first?.confidence ?? 0, before)
        XCTAssertEqual(store.bindingsForTesting.first?.successCount, 2)
    }

    func testYesHereCorrectionPrefersCurrentSurface() {
        XCTAssertEqual(DispatchLearningStore.correctionKind(for: "yes here"), .preferCurrentSurface)
        XCTAssertEqual(DispatchLearningStore.correctionKind(for: "use this box"), .preferCurrentSurface)
    }

    func testPreferCurrentSurfaceBindsLastRouteToCurrentSurface() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let original = contextPacket(appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", kind: .chat, fieldKind: .compose)
        let current = contextPacket(appName: "Linear", bundleId: "com.linear", kind: .task, fieldKind: .comment)

        store.recordOutcome(
            command: "add this update",
            contextPacket: original,
            snapshots: [],
            route: slackRoute(),
            result: .ok("Slack message ready")
        )

        let correction = store.applyCorrection(
            command: "always use this page for that",
            contextPacket: current,
            snapshots: []
        )

        XCTAssertEqual(correction?.kind, .preferCurrentSurface)
        let binding = store.bestBinding(
            command: "add this update",
            contextPacket: current,
            snapshots: []
        )
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.surface.bundleId, "com.linear")
    }

    func testAXTargetMismatchBlocksLearnedBindingForSameApp() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let firstField = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "message-field", frameBucket: "10:10:4:1")
        )
        let secondField = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "search-field", frameBucket: "1:1:3:1")
        )

        store.recordOutcome(
            command: "send the update here",
            contextPacket: firstField,
            snapshots: [],
            route: slackRoute(),
            result: .ok("Slack message ready")
        )

        XCTAssertNil(store.bestBinding(
            command: "send the update here",
            contextPacket: secondField,
            snapshots: []
        ))
    }

    func testAXTargetMatchAllowsLearnedBindingForSameTextBox() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let target = targetFingerprint(placeholderToken: "message-field", frameBucket: "10:10:4:1")
        let context = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: target
        )

        store.recordOutcome(
            command: "send the update here",
            contextPacket: context,
            snapshots: [],
            route: slackRoute(),
            result: .ok("Slack message ready")
        )

        XCTAssertNotNil(store.bestBinding(
            command: "send the update here",
            contextPacket: context,
            snapshots: []
        ))
    }

    func testResolverCanUseLearnedBindingBeforeCloudClassifier() async {
        let context = contextPacket(appName: "Linear", bundleId: "com.linear", kind: .task, fieldKind: .search)
        let binding = DispatchLearningBinding(
            id: UUID(),
            commandPattern: "usual triage app",
            commandTokens: ["usual", "triage", "app"],
            surface: DispatchLearningStore.surfaceFingerprint(contextPacket: context, snapshots: []),
            routeCard: DispatchRouteCard(
                id: "app.open.linear",
                intent: .openApp,
                title: "App switch",
                surface: "Linear",
                action: "Activate or launch app",
                validator: "macOS open request succeeded",
                disturbance: .appSwitch
            ),
            action: .openApp(name: "Linear"),
            confidence: 0.84,
            successCount: 3,
            failureCount: 0,
            createdAt: Date(),
            lastUpdatedAt: Date()
        )

        let route = await DispatchRouteResolver.resolve(
            command: "usual triage app",
            contextPacket: context,
            snapshots: [],
            learnedBinding: binding
        )

        XCTAssertEqual(route.card.intent, .openApp)
        XCTAssertGreaterThanOrEqual(route.confidence, 0.84)
        XCTAssertTrue(route.evidence.first?.contains("Learned local binding") == true)
    }

    func testTargetGuardAllowsLearnedTextActionForSameAXTarget() {
        let target = targetFingerprint(placeholderToken: "message-field", frameBucket: "10:10:4:1")
        let context = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: target
        )
        let surface = DispatchLearningStore.surfaceFingerprint(contextPacket: context, snapshots: [])
        let binding = learnedBinding(surface: surface, action: .typeText(text: "Done", appHint: nil))

        let decision = DispatchTargetGuard.decision(
            action: .typeText(text: "Done", appHint: nil),
            binding: binding,
            currentSurface: surface
        )

        XCTAssertEqual(decision, .allowed)
    }

    func testTargetGuardBlocksLearnedTextActionWhenAXTargetChanged() {
        let first = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "message-field", frameBucket: "10:10:4:1")
        )
        let second = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "search-field", frameBucket: "1:1:3:1")
        )
        let binding = learnedBinding(
            surface: DispatchLearningStore.surfaceFingerprint(contextPacket: first, snapshots: []),
            action: .typeText(text: "Done", appHint: nil)
        )

        let decision = DispatchTargetGuard.decision(
            action: .typeText(text: "Done", appHint: nil),
            binding: binding,
            currentSurface: DispatchLearningStore.surfaceFingerprint(contextPacket: second, snapshots: [])
        )

        guard case .blocked(let summary) = decision else {
            return XCTFail("Expected target guard block")
        }
        XCTAssertTrue(summary.contains("Target changed"))
    }

    func testTargetGuardBlocksLearnedTextActionWhenCurrentAXTargetIsMissing() {
        let first = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "message-field", frameBucket: "10:10:4:1")
        )
        let current = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose
        )
        let binding = learnedBinding(
            surface: DispatchLearningStore.surfaceFingerprint(contextPacket: first, snapshots: []),
            action: .typeText(text: "Done", appHint: nil)
        )

        let decision = DispatchTargetGuard.decision(
            action: .typeText(text: "Done", appHint: nil),
            binding: binding,
            currentSurface: DispatchLearningStore.surfaceFingerprint(contextPacket: current, snapshots: [])
        )

        guard case .blocked(let summary) = decision else {
            return XCTFail("Expected target guard block")
        }
        XCTAssertTrue(summary.contains("can't verify"))
    }

    func testTargetGuardDoesNotBlockBackgroundActions() {
        let first = contextPacket(
            appName: "Safari",
            bundleId: "com.apple.Safari",
            kind: .browser,
            fieldKind: .search,
            targetFingerprint: targetFingerprint(placeholderToken: "search-field", frameBucket: "1:1:3:1")
        )
        let current = contextPacket(
            appName: "Safari",
            bundleId: "com.apple.Safari",
            kind: .browser,
            fieldKind: .search,
            targetFingerprint: targetFingerprint(placeholderToken: "address-field", frameBucket: "2:2:4:1")
        )
        let binding = learnedBinding(
            surface: DispatchLearningStore.surfaceFingerprint(contextPacket: first, snapshots: []),
            action: .openURL(url: "https://google.com/search?q=weather")
        )

        let decision = DispatchTargetGuard.decision(
            action: .openURL(url: "https://google.com/search?q=weather"),
            binding: binding,
            currentSurface: DispatchLearningStore.surfaceFingerprint(contextPacket: current, snapshots: [])
        )

        XCTAssertEqual(decision, .allowed)
    }

    func testGuardFailureLogsWithoutPenalizingBinding() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let original = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "message-field", frameBucket: "10:10:4:1")
        )
        let current = contextPacket(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            kind: .chat,
            fieldKind: .compose,
            targetFingerprint: targetFingerprint(placeholderToken: "search-field", frameBucket: "1:1:3:1")
        )

        store.recordOutcome(
            command: "send the update here",
            contextPacket: original,
            snapshots: [],
            route: slackRoute(),
            result: .ok("Slack message ready")
        )
        guard let binding = store.bindingsForTesting.first else {
            return XCTFail("Expected learned binding")
        }

        store.recordGuardFailure(
            command: "send the update here",
            contextPacket: current,
            snapshots: [],
            route: slackRoute().applying(learnedBinding: binding),
            binding: binding,
            summary: "Target changed. Focus the intended text box and say \"use this text box\"."
        )

        XCTAssertEqual(store.bindingsForTesting.first?.successCount, binding.successCount)
        XCTAssertEqual(store.bindingsForTesting.first?.failureCount, binding.failureCount)
        XCTAssertEqual(store.logsForTesting.last?.learnedBindingID, binding.id)
        XCTAssertFalse(store.logsForTesting.last?.resultSuccess ?? true)
        XCTAssertEqual(store.logsForTesting.last?.failureStage, .targetGuard)
        XCTAssertEqual(store.logsForTesting.last?.targetCheck?.expectedAXTarget, true)
        XCTAssertEqual(store.logsForTesting.last?.targetCheck?.currentAXTarget, true)
        XCTAssertLessThan(store.logsForTesting.last?.targetCheck?.matchScore ?? 1, DispatchTargetGuard.minimumAXTargetScore)
        XCTAssertTrue(store.logsForTesting.last?.evidence.first?.contains("Target guard") == true)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-learning-\(UUID().uuidString).json")
    }

    private func slackRoute() -> DispatchRouteResolution {
        DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "slack.post",
                intent: .slackDraft,
                title: "Slack route",
                surface: "#resonant",
                action: "Prepare or type Slack message",
                validator: "Slack payload prepared or active field delivery succeeded",
                disturbance: .activeSurface
            ),
            action: .postSlack(channel: "resonant", message: "I fixed it"),
            confidence: 0.82,
            evidence: []
        )
    }

    private func textRoute() -> DispatchRouteResolution {
        DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "active.text",
                intent: .activeText,
                title: "Active text target",
                surface: "Safari",
                action: "Insert text into focused field",
                validator: "Focused field contains inserted text",
                disturbance: .activeSurface
            ),
            action: .typeText(text: "ship it", appHint: "Safari"),
            confidence: 0.9,
            evidence: [],
            source: .cloudAction
        )
    }

    private func learnedBinding(
        surface: DispatchSurfaceFingerprint,
        action: CommandAction
    ) -> DispatchLearningBinding {
        DispatchLearningBinding(
            id: UUID(),
            commandPattern: "send update here",
            commandTokens: ["send", "update", "here"],
            surface: surface,
            routeCard: slackRoute().card,
            action: action,
            confidence: 0.84,
            successCount: 2,
            failureCount: 0,
            createdAt: Date(),
            lastUpdatedAt: Date()
        )
    }

    private func contextPacket(
        appName: String,
        bundleId: String,
        kind: SurfaceKind,
        fieldKind: FieldKind,
        targetFingerprint: ContextTargetFingerprint? = nil
    ) -> ContextPacket {
        ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: SurfaceDescriptor(
                kind: kind,
                appName: appName,
                bundleId: bundleId,
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
            targetFingerprint: targetFingerprint,
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
    }

    private func targetFingerprint(
        placeholderToken: String,
        frameBucket: String,
        isSensitiveInput: Bool = false
    ) -> ContextTargetFingerprint {
        ContextTargetFingerprint(
            role: "AXTextArea",
            subrole: nil,
            isSensitiveInput: isSensitiveInput,
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
