import Foundation
import SwiftData

/// Canonical workspace tool registry shared by MCP and in-app model adapters.
/// Adapters own protocol-specific formatting; this layer owns names, schemas,
/// argument parsing, and structured data lookup.
@MainActor
enum WorkspaceTools {
    nonisolated private static let fromProp: [String: JSONValue] = [
        "type": .string("string"),
        "description": .string("Start of date range. Accepts YYYY-MM-DD, ISO8601, or relative: 'today', 'yesterday', '3d', '2w', '1m'. Overrides 'days' when set.")
    ]

    nonisolated private static let toProp: [String: JSONValue] = [
        "type": .string("string"),
        "description": .string("End of date range (same formats as 'from'). Defaults to now.")
    ]

    nonisolated static let allTools: [WorkspaceTool] = [
        WorkspaceTool(
            name: "search",
            description: "Search across all dictations, memos, meetings, and journals. Supports multi-word queries (all terms must match), quoted phrases, and relevance ranking. Use `type: \"journal\"` to restrict to journal entries, `type: \"dictation\"`/`\"memo\"`/`\"meeting\"`/`\"ambient\"` for other kinds. Results sorted by relevance score.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search query. Multiple words use AND logic. Use quotes for exact phrases: '\"project update\" slack'")
                    ]),
                    "type": .object([
                        "type": .string("string"),
                        "enum": .array([.string("dictation"), .string("memo"), .string("meeting"), .string("ambient"), .string("journal")]),
                        "description": .string("Filter by entry type. Omit to search all types.")
                    ]),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Filter dictation results by app name (e.g. 'Slack', 'VS Code').")
                    ]),
                    "days": .object([
                        "type": .string("integer"),
                        "description": .string("Limit search to the last N days. Defaults to 30. Ignored if 'from' is set.")
                    ]),
                    "from": .object(fromProp),
                    "to": .object(toProp),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum results to return. Defaults to 20.")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ),
        WorkspaceTool(
            name: "recent_activity",
            description: "Get recent dictations, memos, and meetings, grouped chronologically with app context. Use 'from'/'to' for precise date ranges or 'hours' for simple lookback.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "hours": .object([
                        "type": .string("integer"),
                        "description": .string("Look back N hours. Defaults to 24. Ignored if 'from' is set.")
                    ]),
                    "from": .object(fromProp),
                    "to": .object(toProp),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum items to return. Defaults to 50.")
                    ])
                ])
            ])
        ),
        WorkspaceTool(
            name: "get_meeting",
            description: "Get a specific meeting's full transcript and notes by ID or exact title.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Meeting UUID")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Meeting title. Exact match, case-insensitive.")
                    ])
                ])
            ])
        ),
        WorkspaceTool(
            name: "get_journal",
            description: "Get the journal summary for a specific date, including activity blocks, topics, and accomplishments.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "date": .object([
                        "type": .string("string"),
                        "description": .string("Date: YYYY-MM-DD, 'today', 'yesterday', or relative like '3d'. Defaults to today.")
                    ])
                ])
            ])
        ),
        WorkspaceTool(
            name: "list_meetings",
            description: "List recent meetings with their metadata (date, duration, app, organizer, participants, calendar source). Use get_meeting to fetch transcripts and full meeting context. Filter by organizer or attendee to find meetings involving specific people.",
            inputSchema: listSchema(extra: [
                "organizer": .object([
                    "type": .string("string"),
                    "description": .string("Filter by organizer name (substring, case-insensitive).")
                ]),
                "attendee": .object([
                    "type": .string("string"),
                    "description": .string("Filter by attendee name (substring match against any attendee, case-insensitive).")
                ])
            ], defaultDays: 7, defaultLimit: 20, limitDescription: "Maximum meetings to return. Defaults to 20.")
        ),
        WorkspaceTool(
            name: "list_dictations",
            description: "List recent dictations with full app/window context (app name, window title, URL, code file, Slack recipient).",
            inputSchema: listSchema(extra: [
                "app": .object([
                    "type": .string("string"),
                    "description": .string("Filter by app name (e.g. 'Slack', 'VS Code'). Omit for all apps.")
                ])
            ], defaultDays: 7, defaultLimit: 50, limitDescription: "Maximum dictations to return. Defaults to 50.")
        ),
        WorkspaceTool(
            name: "get_dictation",
            description: "Get a specific dictation by ID, including full text, raw transcript, app context, window title, URL, selected text, and delivered text.",
            inputSchema: idSchema(description: "Dictation UUID")
        ),
        WorkspaceTool(
            name: "list_memos",
            description: "List recent voice memos with titles and summaries.",
            inputSchema: listSchema(extra: [:], defaultDays: 30, defaultLimit: 50, limitDescription: "Maximum memos to return. Defaults to 50.")
        ),
        WorkspaceTool(
            name: "get_memo",
            description: "Get a specific memo by ID, including full text, title, distilled summary, and duration.",
            inputSchema: idSchema(description: "Memo UUID")
        ),
        WorkspaceTool(
            name: "ambient_timeline",
            description: "Get a timeline of screen activity from ambient context capture. Shows which apps were active, window titles, URLs, browser tabs, clipboard content, and dwell times. Requires ambient context to be enabled.",
            inputSchema: ambientListSchema(defaultDays: 1, defaultLimit: 100)
        ),
        WorkspaceTool(
            name: "ambient_app_usage",
            description: "Get aggregated app usage statistics from ambient context. Shows total dwell time and switch count per app for the given period.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "days": .object([
                        "type": .string("integer"),
                        "description": .string("Look back N days. Defaults to 1. Ignored if 'from' is set.")
                    ]),
                    "from": .object(fromProp),
                    "to": .object(toProp)
                ])
            ])
        ),
        WorkspaceTool(
            name: "ambient_search",
            description: "Search ambient context snapshots by keyword. Searches across app names, window titles, URLs, visible text, clipboard, and browser tabs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search query. Multiple words use AND logic.")
                    ]),
                    "days": .object([
                        "type": .string("integer"),
                        "description": .string("Look back N days. Defaults to 7. Ignored if 'from' is set.")
                    ]),
                    "from": .object(fromProp),
                    "to": .object(toProp),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Filter by app name (e.g. 'Chrome', 'VS Code').")
                    ]),
                    "url_host": .object([
                        "type": .string("string"),
                        "description": .string("Filter to results whose browser URL host contains this substring (e.g. 'github.com').")
                    ]),
                    "window_substring": .object([
                        "type": .string("string"),
                        "description": .string("Filter to results whose window title contains this substring (case-insensitive).")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum results to return. Defaults to 20.")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ),
        WorkspaceTool(
            name: "list_apps",
            description: "List apps seen in ambient context with total dwell time and switch counts. Use this to answer 'what apps did I use today/this week'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "days": .object([
                        "type": .string("integer"),
                        "description": .string("Look back N days. Defaults to 1. Ignored if 'from' is set.")
                    ]),
                    "from": .object(fromProp),
                    "to": .object(toProp)
                ])
            ])
        ),
        WorkspaceTool(
            name: "list_journals",
            description: "List recent journal entries (date + summary + block count). Use get_journal to fetch full content for a specific date.",
            inputSchema: listSchema(extra: [:], defaultDays: 7, defaultLimit: 30, limitDescription: "Maximum journal entries to return. Defaults to 30.")
        ),
        WorkspaceTool(
            name: "get_ambient_snapshot",
            description: "Get the single most recent ambient context snapshot - what the user is (or was just) doing right now. Returns app, window, URL, dwell, etc.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        ),

        // MARK: - Write tools (Dispatch)

        WorkspaceTool(
            name: "type_text",
            description: "Type text into the user's currently active application using Resonant's text delivery system. Supports any app with a text field.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("The text to type into the active app.")
                    ]),
                    "app_hint": .object([
                        "type": .string("string"),
                        "description": .string("Optional app name to target. If omitted, types into the frontmost app.")
                    ])
                ]),
                "required": .array([.string("text")])
            ])
        ),
        WorkspaceTool(
            name: "open_url",
            description: "Open a URL in the user's default browser.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The URL to open.")
                    ])
                ]),
                "required": .array([.string("url")])
            ])
        ),
        WorkspaceTool(
            name: "open_app",
            description: "Open or switch to an application by name.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("The application name (e.g. 'Slack', 'VS Code', 'Safari').")
                    ])
                ]),
                "required": .array([.string("name")])
            ])
        ),
        WorkspaceTool(
            name: "notify_user",
            description: "Show a notification to the user via Resonant's notch overlay and optionally speak it aloud via TTS.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("The notification message to show.")
                    ]),
                    "speak": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether to also speak the message via TTS. Defaults to false.")
                    ])
                ]),
                "required": .array([.string("message")])
            ])
        ),
        WorkspaceTool(
            name: "record_notification_hint",
            description: "Record a recent app notification hint so the next Dispatch command can resolve vague replies like 'reply to that'. Intended for local browser/app integrations.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_name": .object([
                        "type": .string("string"),
                        "description": .string("Name of the app or web service that emitted the notification, e.g. Slack, Discord, Gmail.")
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional native app bundle ID.")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Optional notification title.")
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Optional notification body preview.")
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("Optional URL associated with the notification or resulting browser thread/page.")
                    ]),
                    "received_at": .object([
                        "type": .string("string"),
                        "description": .string("Optional timestamp. Accepts ISO8601 or relative forms supported by Resonant. Defaults to now.")
                    ])
                ]),
                "required": .array([.string("app_name")])
            ])
        ),
        WorkspaceTool(
            name: "run_command",
            description: "Execute a voice command through Resonant's Dispatch system. The command will be processed by the LLM and the appropriate action will be taken.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The command to execute, as if the user spoke it.")
                    ])
                ]),
                "required": .array([.string("command")])
            ])
        ),
        WorkspaceTool(
            name: "dispatch_capabilities",
            description: "Describe what Dispatch can do locally per app/operation, including whether a command is available, degraded to a local fallback, blocked pending target context, or requires an API integration.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object([
                        "type": .string("string"),
                        "enum": .array(["slack", "discord", "linear", "github", "devin", "browser"].map { .string($0) }),
                        "description": .string("Optional app filter.")
                    ])
                ])
            ])
        ),
        WorkspaceTool(
            name: "dispatch_test_run",
            description: "Run a Dispatch E2E debug scenario with optional injected context/snapshots. Defaults to dry-run routing; set execute=true to run the resolved command through the real Dispatch executor.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The command text to route or execute.")
                    ]),
                    "execute": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether to execute the command. Defaults to false for route-only dry runs.")
                    ]),
                    "cloud_fallback": .object([
                        "type": .string("boolean"),
                        "description": .string("Override Dispatch cloud fallback for this test run. Defaults to current setting.")
                    ]),
                    "context": .object([
                        "type": .string("object"),
                        "description": .string("Optional injected current context: app_name, bundle_id, surface_kind, field_kind, browser_url, window_title, selected_text, focused_text, visible_snippets, target.")
                    ]),
                    "snapshots": .object([
                        "type": .string("array"),
                        "description": .string("Optional injected ambient snapshots. Each item may include app_name, bundle_id, window_title, browser_url, slack_recipient, visible_text_snippets, browser_tabs, notification.")
                    ]),
                    "expect": .object([
                        "type": .string("object"),
                        "description": .string("Optional assertions: route_id, intent, source, action/action_type, text, app_hint, url_contains, capability_status, execution_strategy, surface_app, fallback, requires_api, success.")
                    ])
                ]),
                "required": .array([.string("command")])
            ])
        ),
        WorkspaceTool(
            name: "dispatch_trial_next",
            description: "Start the next guided Dispatch trial and return the exact phrase the user should say. The spoken command trace will be appended to dispatch_trials.jsonl.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "scenario_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional scenario id to start instead of the next scenario in the queue.")
                    ]),
                    "include_sensitive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include raw trial diagnostics and log path. The spoken phrase is always returned. Defaults to false.")
                    ])
                ])
            ])
        ),
        WorkspaceTool(
            name: "dispatch_trial_outcome",
            description: "Mark the active or most recent guided Dispatch trial with the user's observed outcome.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "trial_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional UUID of the trial to mark. Defaults to active or latest trial.")
                    ]),
                    "outcome": .object([
                        "type": .string("string"),
                        "enum": .array(DispatchTrialOutcome.allCases.map { .string($0.rawValue) }),
                        "description": .string("Observed outcome: worked, wrong_app, wrong_target, nothing_happened, too_slow, bad_transcript, silent_failure, mic_failed, other.")
                    ]),
                    "notes": .object([
                        "type": .string("string"),
                        "description": .string("Optional short note about what happened.")
                    ]),
                    "include_sensitive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include raw trial prompt, transcript, diagnostic messages, and log path in the returned trial. Defaults to false.")
                    ])
                ]),
                "required": .array([.string("outcome")])
            ])
        ),
        WorkspaceTool(
            name: "dispatch_trials",
            description: "Inspect guided Dispatch trial state, recent trial traces, scenario queue, and the JSONL log path.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum recent trials to return. Defaults to 20.")
                    ]),
                    "include_scenarios": .object([
                        "type": .string("boolean"),
                        "description": .string("Include the guided scenario queue. Defaults to true.")
                    ]),
                    "include_sensitive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include raw trial prompt, transcript, diagnostic messages, and log path. Defaults to false.")
                    ])
                ])
            ])
        ),
        WorkspaceTool(
            name: "dispatch_traces",
            description: "Inspect recent stage-by-stage Dispatch command traces: transcript received, route selected, action started, execution result, verification, learning, and finish status.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum trace events to return. Defaults to 50.")
                    ]),
                    "include_sensitive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include raw command text, URLs, window titles, and diagnostic evidence. Defaults to false.")
                    ])
                ])
            ])
        ),
        WorkspaceTool(
            name: "dispatch_log",
            description: "Inspect recent Dispatch route decisions, outcomes, corrections, and whether learned bindings were used.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum log entries to return. Defaults to 20.")
                    ]),
                    "include_sensitive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include raw command text and diagnostic strings. Defaults to false.")
                    ])
                ])
            ])
        ),
        WorkspaceTool(
            name: "dispatch_bindings",
            description: "Inspect learned Dispatch command-to-surface bindings and their reward scores.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum learned bindings to return. Defaults to 20.")
                    ]),
                    "include_sensitive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include raw learned command patterns and target labels. Defaults to false.")
                    ])
                ])
            ])
        ),
        WorkspaceTool(
            name: "dispatch_replay_fixtures",
            description: "Export recent Dispatch logs as replay/eval scenarios. Redacted by default; set include_sensitive=true for runnable local fixtures.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum recent Dispatch logs to consider. Defaults to 20.")
                    ]),
                    "failures_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Only export failed Dispatch attempts. Defaults to true.")
                    ]),
                    "include_sensitive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include raw command text and action details so scenarios are runnable. Defaults to false.")
                    ])
                ])
            ])
        )
    ]

    /// Callback for write tool execution. Set by AppState when Dispatch is configured.
    static var onWriteToolCall: ((_ tool: String, _ args: [String: JSONValue]) async -> WorkspaceToolCallResult)?

    /// Write tool names that require execution context (Dispatch).
    static let writeToolNames: Set<String> = [
        "type_text",
        "open_url",
        "open_app",
        "notify_user",
        "record_notification_hint",
        "run_command",
        "dispatch_test_run",
        "dispatch_trial_next",
        "dispatch_trial_outcome",
        "dispatch_trials",
        "dispatch_traces",
        "dispatch_log",
        "dispatch_bindings",
        "dispatch_replay_fixtures"
    ]

    static func handle(
        tool: String,
        arguments: [String: JSONValue]?,
        dataStore: DataStore
    ) async -> WorkspaceToolCallResult {
        let args = arguments ?? [:]

        // Route write tools to the Dispatch handler
        if writeToolNames.contains(tool) {
            guard let handler = onWriteToolCall else {
                return error(toolName: tool, "Dispatch not configured. Open the Resonant app and enable Dispatch in Settings -> Dictation.")
            }
            return await handler(tool, args)
        }

        let engine = WorkspaceQueryEngine(dataStore: dataStore)

        switch tool {
        case "search": return await handleSearch(args: args, engine: engine)
        case "recent_activity": return await handleRecentActivity(args: args, engine: engine)
        case "get_meeting": return await handleGetMeeting(args: args, engine: engine)
        case "get_journal": return await handleGetJournal(args: args, engine: engine)
        case "list_meetings": return await handleListMeetings(args: args, engine: engine)
        case "list_dictations": return await handleListDictations(args: args, engine: engine)
        case "get_dictation": return await handleGetDictation(args: args, engine: engine)
        case "list_memos": return await handleListMemos(args: args, engine: engine)
        case "get_memo": return await handleGetMemo(args: args, engine: engine)
        case "ambient_timeline": return await handleAmbientTimeline(args: args, engine: engine)
        case "ambient_app_usage", "list_apps": return await handleAmbientAppUsage(tool: tool, args: args, engine: engine)
        case "ambient_search": return await handleAmbientSearch(args: args, engine: engine)
        case "list_journals": return await handleListJournals(args: args, engine: engine)
        case "get_ambient_snapshot": return await handleGetAmbientSnapshot(args: args, engine: engine)
        case "dispatch_capabilities": return handleDispatchCapabilities(args: args)
        default:
            return error(toolName: tool, "Unknown tool: \(tool)")
        }
    }

    private static func handleSearch(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            return error(toolName: "search", "Missing required parameter: query")
        }

        let params = WorkspaceQueryEngine.SearchParams(
            query: query,
            type: args["type"]?.stringValue,
            days: args["days"]?.intValue,
            from: parseFrom(args),
            to: parseTo(args),
            limit: args["limit"]?.intValue ?? 20,
            app: args["app"]?.stringValue
        )
        let results = await engine.serializeSearchResults(engine.search(params))
        return success("search", [
            "query": .string(query),
            "results": .array(results.map(JSONValue.stringObject))
        ])
    }

    private static func handleRecentActivity(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        let params = WorkspaceQueryEngine.RecentActivityParams(
            hours: args["hours"]?.intValue,
            from: parseFrom(args),
            to: parseTo(args),
            limit: args["limit"]?.intValue ?? 50
        )
        let iso = ISO8601DateFormatter()
        let items = await engine.recentActivity(params).map { item in
            JSONValue.object([
                "type": .string(item.type),
                "date": .string(iso.string(from: item.date)),
                "id": .string(item.id),
                "text": .string(item.text),
                "context": .string(item.context)
            ])
        }
        return success("recent_activity", ["items": .array(items)])
    }

    private static func handleGetMeeting(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        let meeting: [String: Any]?
        if let idString = args["id"]?.stringValue, !idString.isEmpty {
            guard let id = UUID(uuidString: idString) else {
                return error(toolName: "get_meeting", "Invalid meeting ID")
            }
            meeting = await engine.getMeeting(id: id)
        } else if let title = args["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            meeting = await engine.getMeeting(title: title)
        } else {
            return error(toolName: "get_meeting", "Missing meeting identifier. Provide 'id' or 'title'.")
        }

        guard let meeting else {
            if let idString = args["id"]?.stringValue, !idString.isEmpty {
                return error(toolName: "get_meeting", "Meeting not found: \(idString)")
            }
            return error(toolName: "get_meeting", "Meeting not found for the provided title.")
        }
        return success("get_meeting", ["meeting": JSONValue(any: meeting)])
    }

    private static func handleGetJournal(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        let targetDate: Date?
        if let dateString = args["date"]?.stringValue {
            guard let parsed = WorkspaceQueryEngine.parseDate(dateString) else {
                return error(toolName: "get_journal", "Invalid date. Use YYYY-MM-DD, 'today', 'yesterday', or relative like '3d'.")
            }
            targetDate = parsed
        } else {
            targetDate = nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = targetDate.map { dateFormatter.string(from: $0) } ?? dateFormatter.string(from: Date())
        let journal = await engine.getJournal(date: targetDate)
        return success("get_journal", [
            "date": .string(dateString),
            "journal": journal.map(JSONValue.init(any:)) ?? .null
        ])
    }

    private static func handleListMeetings(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        let params = WorkspaceQueryEngine.ListParams(
            days: args["days"]?.intValue,
            from: parseFrom(args),
            to: parseTo(args),
            limit: args["limit"]?.intValue ?? 20,
            organizer: args["organizer"]?.stringValue,
            attendee: args["attendee"]?.stringValue
        )
        let meetings = await engine.listMeetings(params)
        return success("list_meetings", ["meetings": .array(meetings.map(JSONValue.stringObject))])
    }

    private static func handleListDictations(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        let params = WorkspaceQueryEngine.ListParams(
            days: args["days"]?.intValue,
            from: parseFrom(args),
            to: parseTo(args),
            limit: args["limit"]?.intValue ?? 50,
            app: args["app"]?.stringValue
        )
        let dictations = await engine.listDictations(params)
        return success("list_dictations", [
            "app": params.app.map(JSONValue.string) ?? .null,
            "dictations": .array(dictations.map(JSONValue.stringObject))
        ])
    }

    private static func handleGetDictation(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        guard let idString = args["id"]?.stringValue, let id = UUID(uuidString: idString) else {
            return error(toolName: "get_dictation", "Missing or invalid dictation ID")
        }
        guard let dictation = await engine.getDictation(id: id) else {
            return error(toolName: "get_dictation", "Dictation not found: \(idString)")
        }
        return success("get_dictation", ["dictation": JSONValue(any: dictation)])
    }

    private static func handleListMemos(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        let params = WorkspaceQueryEngine.ListParams(
            days: args["days"]?.intValue,
            from: parseFrom(args),
            to: parseTo(args),
            limit: args["limit"]?.intValue ?? 50
        )
        let memos = await engine.listMemos(params)
        return success("list_memos", ["memos": .array(memos.map(JSONValue.stringObject))])
    }

    private static func handleGetMemo(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        guard let idString = args["id"]?.stringValue, let id = UUID(uuidString: idString) else {
            return error(toolName: "get_memo", "Missing or invalid memo ID")
        }
        guard let memo = await engine.getMemo(id: id) else {
            return error(toolName: "get_memo", "Memo not found: \(idString)")
        }
        return success("get_memo", ["memo": JSONValue(any: memo)])
    }

    private static func handleAmbientTimeline(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        let params = WorkspaceQueryEngine.AmbientTimelineParams(
            days: args["days"]?.intValue,
            from: parseFrom(args),
            to: parseTo(args),
            limit: args["limit"]?.intValue ?? 100,
            app: args["app"]?.stringValue,
            urlHost: args["url_host"]?.stringValue,
            windowSubstring: args["window_substring"]?.stringValue
        )
        let snapshots = await engine.ambientTimeline(params)
        return success("ambient_timeline", ["snapshots": .array(snapshots.map(JSONValue.stringObject))])
    }

    private static func handleAmbientAppUsage(tool: String, args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        let params = WorkspaceQueryEngine.AmbientUsageParams(
            days: args["days"]?.intValue,
            from: parseFrom(args),
            to: parseTo(args)
        )
        let usage = await engine.ambientAppUsage(params)
        return success(tool, ["usage": .array(usage.map(JSONValue.stringObject))])
    }

    private static func handleAmbientSearch(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            return error(toolName: "ambient_search", "Missing required parameter: query")
        }

        let params = WorkspaceQueryEngine.SearchParams(
            query: query,
            type: "ambient",
            days: args["days"]?.intValue ?? 7,
            from: parseFrom(args),
            to: parseTo(args),
            limit: args["limit"]?.intValue ?? 20,
            app: args["app"]?.stringValue,
            urlHost: args["url_host"]?.stringValue,
            windowSubstring: args["window_substring"]?.stringValue
        )
        let results = await engine.serializeSearchResults(engine.ambientSearch(params))
        return success("ambient_search", [
            "query": .string(query),
            "results": .array(results.map(JSONValue.stringObject))
        ])
    }

    private static func handleListJournals(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        let params = WorkspaceQueryEngine.ListParams(
            days: args["days"]?.intValue,
            from: parseFrom(args),
            to: parseTo(args),
            limit: args["limit"]?.intValue ?? 30
        )
        let journals = await engine.listJournals(params)
        return success("list_journals", ["journals": .array(journals.map(JSONValue.init(any:)))])
    }

    private static func handleGetAmbientSnapshot(args: [String: JSONValue], engine: WorkspaceQueryEngine) async -> WorkspaceToolCallResult {
        let params = WorkspaceQueryEngine.AmbientTimelineParams(days: 1, limit: 1)
        let snapshots = await engine.ambientTimeline(params)
        return success("get_ambient_snapshot", ["snapshot": snapshots.first.map(JSONValue.stringObject) ?? .null])
    }

    private static func handleDispatchCapabilities(args: [String: JSONValue]) -> WorkspaceToolCallResult {
        let app = args["app"]?.stringValue.flatMap(DispatchAppSurfaceKind.init(rawValue:))
        return WorkspaceToolCallResult(
            toolName: "dispatch_capabilities",
            payload: DispatchAppCapabilityCatalog.matrixPayload(app: app),
            isError: false
        )
    }

    private static func parseFrom(_ args: [String: JSONValue]) -> Date? {
        args["from"]?.stringValue.flatMap(WorkspaceQueryEngine.parseDate)
    }

    private static func parseTo(_ args: [String: JSONValue]) -> Date? {
        args["to"]?.stringValue.flatMap(WorkspaceQueryEngine.parseDate)
    }

    private static func success(_ toolName: String, _ payload: [String: JSONValue]) -> WorkspaceToolCallResult {
        WorkspaceToolCallResult(toolName: toolName, payload: .object(payload), isError: false)
    }

    private static func error(toolName: String, _ message: String) -> WorkspaceToolCallResult {
        WorkspaceToolCallResult(
            toolName: toolName,
            payload: .object(["message": .string(message)]),
            isError: true
        )
    }

    nonisolated private static func idSchema(description: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string(description)
                ])
            ]),
            "required": .array([.string("id")])
        ])
    }

    nonisolated private static func listSchema(
        extra: [String: JSONValue],
        defaultDays: Int,
        defaultLimit: Int,
        limitDescription: String
    ) -> JSONValue {
        var properties: [String: JSONValue] = [
            "days": .object([
                "type": .string("integer"),
                "description": .string("Look back N days. Defaults to \(defaultDays). Ignored if 'from' is set.")
            ]),
            "from": .object(fromProp),
            "to": .object(toProp),
            "limit": .object([
                "type": .string("integer"),
                "description": .string(limitDescription)
            ])
        ]
        for (key, value) in extra {
            properties[key] = value
        }
        _ = defaultLimit
        return .object([
            "type": .string("object"),
            "properties": .object(properties)
        ])
    }

    nonisolated private static func ambientListSchema(defaultDays: Int, defaultLimit: Int) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "days": .object([
                    "type": .string("integer"),
                    "description": .string("Look back N days. Defaults to \(defaultDays). Ignored if 'from' is set.")
                ]),
                "from": .object(fromProp),
                "to": .object(toProp),
                "app": .object([
                    "type": .string("string"),
                    "description": .string("Filter by app name (e.g. 'Chrome', 'VS Code').")
                ]),
                "url_host": .object([
                    "type": .string("string"),
                    "description": .string("Filter to snapshots whose browser URL host contains this substring (e.g. 'github.com').")
                ]),
                "window_substring": .object([
                    "type": .string("string"),
                    "description": .string("Filter to snapshots whose window title contains this substring (case-insensitive).")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum snapshots to return. Defaults to \(defaultLimit).")
                ])
            ])
        ])
    }
}

struct WorkspaceTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

struct WorkspaceToolCallResult: Sendable {
    let toolName: String
    let payload: JSONValue
    let isError: Bool

    var errorMessage: String? {
        payload.objectValue?["message"]?.stringValue
    }
}

private extension JSONValue {
    static func stringObject(_ dictionary: [String: String]) -> JSONValue {
        .object(dictionary.mapValues { .string($0) })
    }

    init(any value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            self = .double(double)
        case let bool as Bool:
            self = .bool(bool)
        case let strings as [String]:
            self = .array(strings.map { .string($0) })
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(any:)))
        case Optional<Any>.none:
            self = .null
        default:
            self = .string(String(describing: value))
        }
    }
}
