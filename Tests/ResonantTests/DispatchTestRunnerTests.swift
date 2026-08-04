import XCTest
@testable import Resonant

@MainActor
final class DispatchTestRunnerTests: XCTestCase {
    func testDryRunRoutesInjectedGmailReplyContext() async {
        let result = await DispatchTestRunner.run(
            args: [
                "command": .string("reply here that I can do it tomorrow"),
                "context": .object([
                    "app_name": .string("Google Chrome"),
                    "bundle_id": .string("com.google.Chrome"),
                    "surface_kind": .string("email"),
                    "field_kind": .string("reply"),
                    "browser_url": .string("https://mail.google.com/mail/u/0/#inbox/FMfcgzExample"),
                    "target": .object([
                        "role": .string("AXTextArea"),
                        "placeholder_token": .string("reply-field"),
                        "frame_bucket": .string("10:10:8:2")
                    ])
                ]),
                "expect": .object([
                    "route_id": .string("active.text"),
                    "source": .string("deterministic_local"),
                    "action": .string("type_text"),
                    "text": .string("I can do it tomorrow"),
                    "app_hint": .string("Google Chrome")
                ])
            ],
            commandRouter: CommandRouter(),
            learningStore: tempLearningStore(),
            defaultCloudFallbackEnabled: false
        )

        XCTAssertFalse(result.isError)
        let payload = result.payload.objectValue ?? [:]
        XCTAssertEqual(payload["passed"], .bool(true))
        XCTAssertEqual(payload["route"]?.objectValue?["id"], .string("active.text"))
        XCTAssertEqual(payload["action"]?.objectValue?["text"], .string("I can do it tomorrow"))
    }

    func testDryRunUsesInjectedNotificationSnapshotForVagueReply() async {
        let result = await DispatchTestRunner.run(
            args: [
                "command": .string("reply to that saying I am on it"),
                "context": .object([
                    "app_name": .string("Slack"),
                    "bundle_id": .string("com.tinyspeck.slackmacgap"),
                    "surface_kind": .string("chat"),
                    "field_kind": .string("compose"),
                    "target": .object([
                        "role": .string("AXTextArea"),
                        "placeholder_token": .string("message-field"),
                        "frame_bucket": .string("10:10:8:2")
                    ])
                ]),
                "snapshots": .array([
                    .object([
                        "app_name": .string("Slack"),
                        "bundle_id": .string("com.tinyspeck.slackmacgap"),
                        "slack_recipient": .string("#resonant"),
                        "notification": .object([
                            "app_name": .string("Slack"),
                            "bundle_id": .string("com.tinyspeck.slackmacgap"),
                            "title": .string("Alex in #resonant"),
                            "body": .string("Can you take this?"),
                            "received_at": .string("now")
                        ])
                    ])
                ]),
                "expect": .object([
                    "route_id": .string("active.text"),
                    "action": .string("type_text"),
                    "text": .string("I am on it"),
                    "app_hint": .string("Slack")
                ])
            ],
            commandRouter: CommandRouter(),
            learningStore: tempLearningStore(),
            defaultCloudFallbackEnabled: false
        )

        XCTAssertFalse(result.isError)
        let payload = result.payload.objectValue ?? [:]
        XCTAssertEqual(payload["passed"], .bool(true))
        XCTAssertEqual(payload["snapshots"]?.arrayValue?.count, 1)
        XCTAssertEqual(payload["action"]?.objectValue?["text"], .string("I am on it"))
    }

    func testDryRunIncludesCapabilityPlanForLinearDraft() async {
        let result = await DispatchTestRunner.run(
            args: [
                "command": .string("create a Linear ticket to fix dispatch silent failures"),
                "expect": .object([
                    "route_id": .string("ticket.linear"),
                    "action": .string("create_ticket"),
                    "capability_status": .string("degraded"),
                    "execution_strategy": .string("clipboard_draft"),
                    "surface_app": .string("linear"),
                    "fallback": .string("clipboard ticket draft"),
                    "requires_api": .bool(true)
                ])
            ],
            commandRouter: CommandRouter(),
            learningStore: tempLearningStore(),
            defaultCloudFallbackEnabled: false
        )

        XCTAssertFalse(result.isError)
        let payload = result.payload.objectValue ?? [:]
        let plan = payload["plan"]?.objectValue ?? [:]
        XCTAssertEqual(plan["surface_app"], .string("linear"))
        XCTAssertEqual(plan["execution_strategy"], .string("clipboard_draft"))
        XCTAssertEqual(plan["capability_status"], .string("degraded"))
        XCTAssertEqual(plan["requires_api"], .bool(true))
        XCTAssertEqual(plan["fallback"], .string("clipboard ticket draft"))
        XCTAssertEqual(plan["capability_summary"], .string("API needed; using clipboard ticket draft."))
    }

    func testDryRunFailsWhenExpectedCapabilityStatusDoesNotMatch() async {
        let result = await DispatchTestRunner.run(
            args: [
                "command": .string("create a Linear ticket to fix dispatch silent failures"),
                "expect": .object([
                    "route_id": .string("ticket.linear"),
                    "action": .string("create_ticket"),
                    "capability_status": .string("available")
                ])
            ],
            commandRouter: CommandRouter(),
            learningStore: tempLearningStore(),
            defaultCloudFallbackEnabled: false
        )

        XCTAssertTrue(result.isError)
        let assertions = result.payload.objectValue?["assertions"]?.arrayValue ?? []
        let capabilityAssertion = assertions
            .compactMap(\.objectValue)
            .first { $0["name"] == .string("capability_status") }
        XCTAssertEqual(capabilityAssertion?["passed"], .bool(false))
        XCTAssertEqual(capabilityAssertion?["actual"], .string("degraded"))
    }

    private func tempLearningStore() -> DispatchLearningStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-test-\(UUID().uuidString).json")
        return DispatchLearningStore(storageURL: url)
    }
}
