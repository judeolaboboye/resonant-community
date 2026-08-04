import XCTest
@testable import Resonant

@MainActor
final class DispatchLearningInspectorTests: XCTestCase {
    func testLogPayloadIncludesRouteResultActionAndSurface() {
        let entry = DispatchLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSinceReferenceDate: 1_000),
            command: "send the update here",
            commandPattern: "send update here",
            routeCard: routeCard(),
            action: .postSlack(channel: "resonant", message: "Done"),
            actionSummary: nil,
            confidence: 0.82,
            evidence: ["Learned local binding matched."],
            surface: surface(),
            resultSuccess: true,
            resultSummary: "Slack message ready",
            learnedBindingID: UUID(),
            correctionKind: nil,
            routeSource: .learnedBinding,
            routeReason: "A learned local binding matched this command and the current surface.",
            failureStage: nil,
            targetCheck: DispatchTargetCheck(
                required: true,
                expectedAXTarget: true,
                currentAXTarget: true,
                matchScore: 0.91,
                minimumScore: 0.52,
                summary: "Target check passed."
            )
        )

        let payload = DispatchLearningInspector.logPayload(entries: [entry])
        let object = payload.objectValue ?? [:]
        let logs = object["logs"]?.arrayValue ?? []
        let log = logs.first?.objectValue ?? [:]
        let surface = log["surface"]?.objectValue ?? [:]

        XCTAssertEqual(object["count"], .int(1))
        XCTAssertEqual(log["command"], .string("send the update here"))
        XCTAssertEqual(log["route_id"], .string("slack.post"))
        XCTAssertEqual(log["action"], .string("post_slack:resonant"))
        XCTAssertEqual(log["route_source"], .string("learned_binding"))
        XCTAssertEqual(log["route_reason"], .string("A learned local binding matched this command and the current surface."))
        XCTAssertEqual(log["success"], .bool(true))
        XCTAssertEqual(log["used_learned_binding"], .bool(true))
        XCTAssertEqual(log["target_check"]?.objectValue?["match_score"], .double(0.91))
        XCTAssertEqual(surface["bundle_id"], .string("com.tinyspeck.slackmacgap"))
        XCTAssertEqual(surface["ax_placeholder_token"], .string("message-field"))
    }

    func testBindingsPayloadIncludesUsabilityCountsAndActionSummary() {
        let binding = DispatchLearningBinding(
            id: UUID(),
            commandPattern: "send update here",
            commandTokens: ["send", "update", "here"],
            surface: surface(),
            routeCard: routeCard(),
            action: .typeText(text: "Done", appHint: "Slack"),
            confidence: 0.84,
            successCount: 3,
            failureCount: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            lastUpdatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )

        let payload = DispatchLearningInspector.bindingsPayload(bindings: [binding])
        let object = payload.objectValue ?? [:]
        let bindings = object["bindings"]?.arrayValue ?? []
        let item = bindings.first?.objectValue ?? [:]

        XCTAssertEqual(object["count"], .int(1))
        XCTAssertEqual(item["command_pattern"], .string("send update here"))
        XCTAssertEqual(item["action"], .string("type_text:Slack"))
        XCTAssertEqual(item["success_count"], .int(3))
        XCTAssertEqual(item["failure_count"], .int(1))
        XCTAssertEqual(item["usable"], .bool(true))
    }

    func testRedactedBindingsPayloadHidesPatternActionAndSurfaceLabels() {
        let binding = DispatchLearningBinding(
            id: UUID(),
            commandPattern: "send private roadmap to resonant",
            commandTokens: ["send", "private", "roadmap", "resonant"],
            surface: surface(),
            routeCard: routeCard(),
            action: .postSlack(channel: "resonant", message: "Done"),
            confidence: 0.84,
            successCount: 3,
            failureCount: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            lastUpdatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )

        let payload = DispatchLearningInspector.bindingsPayload(bindings: [binding], privacy: .redacted)
        let item = payload.objectValue?["bindings"]?.arrayValue?.first?.objectValue ?? [:]
        let surface = item["surface"]?.objectValue ?? [:]

        XCTAssertEqual(payload.objectValue?["privacy"], .string("redacted"))
        XCTAssertEqual(item["command_pattern"], .string("[redacted pattern]"))
        XCTAssertEqual(item["route_surface"], .string("[redacted surface]"))
        XCTAssertEqual(item["action"], .string("post_slack:[channel]"))
        XCTAssertEqual(surface["slack_recipient"], .string("[redacted recipient]"))
        XCTAssertEqual(surface["conversation_label"], .string("[redacted conversation]"))
    }

    func testStoreBackedPayloadClampsLimit() {
        let store = DispatchLearningStore(storageURL: temporaryURL())
        let route = DispatchRouteResolution(
            card: routeCard(),
            action: .postSlack(channel: "resonant", message: "Done"),
            confidence: 0.82,
            evidence: []
        )

        store.recordOutcome(
            command: "send the update here",
            contextPacket: nil,
            snapshots: [],
            route: route,
            result: .ok("Slack message ready")
        )

        let payload = DispatchLearningInspector.logPayload(store: store, limit: -4)
        XCTAssertEqual(payload.objectValue?["count"], .int(1))
    }

    func testRedactedLogPayloadHidesCommandAndSensitiveEvidence() {
        let entry = DispatchLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSinceReferenceDate: 1_000),
            command: "send the update to person@example.com",
            commandPattern: "send update person example com",
            routeCard: routeCard(),
            action: .postSlack(channel: "resonant", message: "Done"),
            actionSummary: nil,
            confidence: 0.82,
            evidence: ["URL: https://example.com/private", "Workspace: /Users/dev/private-dir"],
            surface: surface(),
            resultSuccess: false,
            resultSummary: "Failed at /Users/dev/private-dir",
            learnedBindingID: nil,
            correctionKind: nil
        )

        let payload = DispatchLearningInspector.logPayload(entries: [entry], privacy: .redacted)
        let log = payload.objectValue?["logs"]?.arrayValue?.first?.objectValue ?? [:]
        let evidence = log["evidence"]?.arrayValue?.compactMap(\.stringValue) ?? []

        XCTAssertEqual(payload.objectValue?["privacy"], .string("redacted"))
        XCTAssertEqual(log["command"], .string("[redacted command]"))
        XCTAssertEqual(log["command_pattern"], .string("[redacted pattern]"))
        XCTAssertTrue(evidence.contains("URL: [url]"))
        XCTAssertTrue(evidence.contains("Workspace: [path]"))
        XCTAssertEqual(log["result"], .string("Failed at [path]"))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-inspector-\(UUID().uuidString).json")
    }

    private func routeCard() -> DispatchRouteCard {
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

    private func surface() -> DispatchSurfaceFingerprint {
        DispatchSurfaceFingerprint(
            surfaceKind: "chat",
            fieldKind: "compose",
            appName: "slack",
            bundleId: "com.tinyspeck.slackmacgap",
            siteHost: nil,
            urlPathToken: nil,
            windowTitleToken: nil,
            fieldContentToken: nil,
            nearbyTextToken: nil,
            conversationLabel: "resonant",
            documentLabelToken: nil,
            projectLabel: nil,
            codeFileName: nil,
            slackRecipient: "resonant",
            axRole: "AXTextArea",
            axSubrole: nil,
            axIdentifierToken: nil,
            axTitleToken: nil,
            axDescriptionToken: nil,
            axPlaceholderToken: "message-field",
            axHelpToken: nil,
            axFrameBucket: "10:10:4:1",
            axSelectedRangeBucket: nil
        )
    }
}
