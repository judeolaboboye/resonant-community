import XCTest
@testable import Resonant

@MainActor
final class WorkspaceToolsTests: XCTestCase {
    func testWorkspaceDateParserParsesStableDateFormats() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parser = WorkspaceDateParser(now: date("2026-05-02T12:34:56Z"), calendar: calendar)

        XCTAssertEqual(parser.parse("2026-03-25"), date("2026-03-25T00:00:00Z"))
        XCTAssertEqual(parser.parse("2026-03-25 14:30"), date("2026-03-25T14:30:00Z"))
        XCTAssertEqual(parser.parse("2026-03-25T14:30:00Z"), date("2026-03-25T14:30:00Z"))
        XCTAssertEqual(parser.parse("2026-03-25T14:30:00.123Z"), date("2026-03-25T14:30:00.123Z"))
    }

    func testWorkspaceDateParserParsesRelativeDatesFromInjectedNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-05-02T12:34:56Z")
        let parser = WorkspaceDateParser(now: now, calendar: calendar)

        XCTAssertEqual(parser.parse("today"), date("2026-05-02T00:00:00Z"))
        XCTAssertEqual(parser.parse("yesterday"), date("2026-05-01T00:00:00Z"))
        XCTAssertEqual(parser.parse("now"), now)
        XCTAssertEqual(parser.parse("3d"), date("2026-04-29T12:34:56Z"))
        XCTAssertEqual(parser.parse("2w"), date("2026-04-18T12:34:56Z"))
        XCTAssertNil(parser.parse("0d"))
    }

    func testMCPToolsAreBackedByWorkspaceToolsRegistry() {
        XCTAssertEqual(MCPTools.allTools.map(\.name), WorkspaceTools.allTools.map(\.name))

        for (mcpTool, workspaceTool) in zip(MCPTools.allTools, WorkspaceTools.allTools) {
            XCTAssertEqual(mcpTool.name, workspaceTool.name)
            XCTAssertEqual(mcpTool.description, workspaceTool.description)
            XCTAssertEqual(mcpTool.inputSchema, workspaceTool.inputSchema)
        }
    }

    func testWorkspaceToolRegistryExposesExpectedStableNames() {
        XCTAssertEqual(
            WorkspaceTools.allTools.map(\.name),
            [
                "search",
                "recent_activity",
                "get_meeting",
                "get_journal",
                "list_meetings",
                "list_dictations",
                "get_dictation",
                "list_memos",
                "get_memo",
                "ambient_timeline",
                "ambient_app_usage",
                "ambient_search",
                "list_apps",
                "list_journals",
                "get_ambient_snapshot",
                "type_text",
                "open_url",
                "open_app",
                "notify_user",
                "record_notification_hint",
                "run_command",
                "dispatch_capabilities",
                "dispatch_test_run",
                "dispatch_trial_next",
                "dispatch_trial_outcome",
                "dispatch_trials",
                "dispatch_traces",
                "dispatch_log",
                "dispatch_bindings",
                "dispatch_replay_fixtures"
            ]
        )
    }

    @MainActor
    func testDispatchCapabilitiesToolExposesLocalCapabilityMatrix() async {
        let result = await WorkspaceTools.handle(
            tool: "dispatch_capabilities",
            arguments: ["app": .string("linear")],
            dataStore: DataStore()
        )

        XCTAssertFalse(result.isError)
        let object = result.payload.objectValue ?? [:]
        XCTAssertEqual(object["count"], JSONValue.int(1))
        let entry = object["entries"]?.arrayValue?.first?.objectValue ?? [:]
        XCTAssertEqual(entry["app"], JSONValue.string("linear"))
        XCTAssertEqual(entry["operation"], JSONValue.string("create_ticket"))
        XCTAssertEqual(entry["local_capability"], JSONValue.string("degraded"))
        XCTAssertEqual(entry["requires_api"], JSONValue.bool(true))
        XCTAssertEqual(entry["fallback"], JSONValue.string("clipboard ticket draft"))
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }
}
