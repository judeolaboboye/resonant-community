import Foundation
import SwiftData

/// MCP adapter for the canonical workspace tool registry.
/// WorkspaceTools owns schemas and structured execution; this adapter keeps
/// the MCP text-response contract stable for JSON-RPC clients.
@MainActor
enum MCPTools {
    static let allTools: [MCPTool] = WorkspaceTools.allTools.map {
        MCPTool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
    }

    static func handle(
        tool: String,
        arguments: [String: JSONValue]?,
        dataStore: DataStore
    ) async -> MCPToolResult {
        let result = await WorkspaceTools.handle(tool: tool, arguments: arguments, dataStore: dataStore)
        if result.isError {
            return errorResult(result.errorMessage ?? "Tool failed.")
        }
        return textResult(format(result))
    }

    private static func format(_ result: WorkspaceToolCallResult) -> String {
        switch result.toolName {
        case "search", "ambient_search":
            return formatSearchResult(result)
        case "recent_activity":
            return formatRecentActivity(result)
        case "get_meeting":
            return formatMeeting(result.payload.objectValue?["meeting"]?.objectValue)
        case "get_journal":
            return formatJournal(result)
        case "list_meetings":
            return formatMeetings(result.payload.objectValue?["meetings"]?.arrayValue ?? [])
        case "list_dictations":
            return formatDictations(result)
        case "get_dictation":
            return formatDictation(result.payload.objectValue?["dictation"]?.objectValue)
        case "list_memos":
            return formatMemos(result.payload.objectValue?["memos"]?.arrayValue ?? [])
        case "get_memo":
            return formatMemo(result.payload.objectValue?["memo"]?.objectValue)
        case "ambient_timeline":
            return formatAmbientTimeline(result.payload.objectValue?["snapshots"]?.arrayValue ?? [])
        case "ambient_app_usage", "list_apps":
            return formatAmbientUsage(result.payload.objectValue?["usage"]?.arrayValue ?? [])
        case "list_journals":
            return formatJournals(result.payload.objectValue?["journals"]?.arrayValue ?? [])
        case "get_ambient_snapshot":
            return formatAmbientSnapshot(result.payload.objectValue?["snapshot"])
        default:
            return result.payload.prettyJSONString ?? ""
        }
    }

    private static func formatSearchResult(_ result: WorkspaceToolCallResult) -> String {
        let object = result.payload.objectValue ?? [:]
        let query = object["query"]?.stringValue ?? ""
        let results = object["results"]?.arrayValue?.compactMap(\.stringDictionary) ?? []
        if results.isEmpty {
            return result.toolName == "ambient_search"
                ? "No ambient context matches for \"\(query)\"."
                : "No results found for \"\(query)\"."
        }
        return formatSearchResults(results)
    }

    private static func formatRecentActivity(_ result: WorkspaceToolCallResult) -> String {
        let items = result.payload.objectValue?["items"]?.arrayValue ?? []
        if items.isEmpty {
            return "No activity in the requested time range."
        }

        let lines = items.map { item -> String in
            let object = item.objectValue ?? [:]
            let type = object["type"]?.stringValue ?? ""
            let date = object["date"]?.stringValue ?? ""
            let context = object["context"]?.stringValue ?? ""
            let text = object["text"]?.stringValue ?? ""
            var line = "[\(type)] \(date)"
            if !context.isEmpty { line += " (\(context))" }
            line += "\n\(text)"
            return line
        }
        return lines.joined(separator: "\n\n---\n\n")
    }

    private static func formatMeeting(_ meeting: [String: JSONValue]?) -> String {
        guard let meeting else { return "Meeting not found." }
        var parts: [String] = [
            "# \(meeting.string("title", default: "Meeting"))",
            "**Date:** \(meeting.string("date"))",
            "**Duration:** \(meeting.string("duration"))",
            "**Words:** \(meeting.int("words"))"
        ]

        if let app = meeting.nonEmptyString("app") { parts.append("**App:** \(app)") }
        if let organizer = meeting.nonEmptyString("organizer") { parts.append("**Organizer:** \(organizer)") }
        if let attendees = meeting["attendees"]?.stringArray, !attendees.isEmpty {
            parts.append("**Attendees:** \(attendees.joined(separator: ", "))")
        }
        if let calendar = meeting.nonEmptyString("calendar") { parts.append("**Calendar:** \(calendar)") }
        if let scheduledStart = meeting.nonEmptyString("scheduledStart") { parts.append("**Scheduled start:** \(scheduledStart)") }
        if let scheduledEnd = meeting.nonEmptyString("scheduledEnd") { parts.append("**Scheduled end:** \(scheduledEnd)") }
        if let conferencingURL = meeting.nonEmptyString("conferencingURL") { parts.append("**Call link:** \(conferencingURL)") }
        if let recordingOrigin = meeting.nonEmptyString("recordingOrigin") { parts.append("**Recording origin:** \(recordingOrigin)") }
        if let markdownPath = meeting.nonEmptyString("markdownPath") { parts.append("**Archive markdown:** \(markdownPath)") }
        if let audioPath = meeting.nonEmptyString("audioPath") { parts.append("**Archive audio:** \(audioPath)") }
        if let notes = meeting.nonEmptyString("notes") { parts.append("\n## Notes (during meeting)\n\(notes)") }
        if let postNotes = meeting.nonEmptyString("postMeetingNotes") { parts.append("\n## Notes (post-meeting)\n\(postNotes)") }
        if let summary = meeting.nonEmptyString("summary") { parts.append("\n## Summary\n\(summary)") }
        if let transcript = meeting.nonEmptyString("transcript") { parts.append("\n## Transcript\n\(transcript)") }

        return parts.joined(separator: "\n")
    }

    private static func formatJournal(_ result: WorkspaceToolCallResult) -> String {
        let object = result.payload.objectValue ?? [:]
        guard let journal = object["journal"]?.objectValue else {
            let date = object["date"]?.stringValue ?? ""
            return "No journal entry for \(date)."
        }

        var parts: [String] = ["# Journal - \(journal.string("date"))"]
        if let summary = journal.nonEmptyString("summary") {
            parts.append("\n## Summary\n\(summary)")
        }

        for block in journal["blocks"]?.arrayValue ?? [] {
            let object = block.objectValue ?? [:]
            let start = object.string("start")
            let end = object.string("end")
            let app = object.string("app")
            var header = "### \(start)-\(end) - \(app)"
            if let context = object.nonEmptyString("context") { header += " (\(context))" }
            parts.append(header)
            if let topic = object.nonEmptyString("topic") { parts.append("**Topic:** \(topic)") }
            if let summary = object.nonEmptyString("summary") { parts.append(summary) }
            if let accomplishment = object.nonEmptyString("accomplishment") { parts.append("**Accomplishment:** \(accomplishment)") }
            if let entries = object["entries"]?.stringArray { parts.append(entries.joined(separator: "\n")) }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func formatMeetings(_ meetings: [JSONValue]) -> String {
        let meetings = meetings.compactMap(\.stringDictionary)
        if meetings.isEmpty {
            return "No meetings in the requested time range."
        }

        let lines = meetings.map { m in
            var line = "- **\(m["title"] ?? "")** | \(m["date"] ?? "") | \(m["duration"] ?? "") | \(m["words"] ?? "0") words"
            if let organizer = m["organizer"], !organizer.isEmpty { line += " | organizer: \(organizer)" }
            if let participants = m["participants"], !participants.isEmpty { line += " | participants: \(participants)" }
            if let calendar = m["calendar"], !calendar.isEmpty { line += " | calendar: \(calendar)" }
            line += " | id: `\(m["id"] ?? "")`"
            return line
        }
        return "## Meetings\n\n\(lines.joined(separator: "\n"))"
    }

    private static func formatDictations(_ result: WorkspaceToolCallResult) -> String {
        let object = result.payload.objectValue ?? [:]
        let dictations = object["dictations"]?.arrayValue?.compactMap(\.stringDictionary) ?? []
        if dictations.isEmpty {
            let app = object["app"]?.stringValue
            return "No dictations in the requested time range\(app.map { " for app '\($0)'" } ?? "")."
        }

        let lines = dictations.map { d in
            var line = "- **\(d["date"] ?? "")** | \(d["app"] ?? "")"
            if let window = d["window"], !window.isEmpty { line += " | \(window)" }
            if let url = d["url"], !url.isEmpty { line += " | \(url)" }
            if let file = d["file"], !file.isEmpty { line += " | \(file)" }
            if let slack = d["slack"], !slack.isEmpty { line += " | @\(slack)" }
            line += " | \(d["words"] ?? "0") words"
            line += "\n  \(d["text"] ?? "")"
            line += "\n  id: `\(d["id"] ?? "")`"
            return line
        }
        return "## Dictations\n\n\(lines.joined(separator: "\n\n"))"
    }

    private static func formatDictation(_ dictation: [String: JSONValue]?) -> String {
        guard let d = dictation else { return "Dictation not found." }
        var parts: [String] = [
            "# Dictation",
            "**Date:** \(d.string("date"))",
            "**App:** \(d.string("app")) (\(d.string("bundleId")))",
            "**Words:** \(d.int("words"))",
            "**Duration:** \(String(format: "%.1fs", d.double("duration")))"
        ]

        if let window = d.nonEmptyString("window") { parts.append("**Window:** \(window)") }
        if let url = d.nonEmptyString("url") { parts.append("**URL:** \(url)") }
        if let file = d.nonEmptyString("file") { parts.append("**File:** \(file)") }
        if let slack = d.nonEmptyString("slack") { parts.append("**Slack:** @\(slack)") }
        parts.append("\n## Text\n\(d.string("text"))")
        if let raw = d.nonEmptyString("rawTranscript") { parts.append("\n## Raw Transcript\n\(raw)") }
        if let selected = d.nonEmptyString("selectedText") { parts.append("\n## Selected Text (at time of dictation)\n\(selected)") }
        if let delivered = d.nonEmptyString("deliveredText") { parts.append("\n## Delivered Text\n\(delivered)") }
        if let focused = d.nonEmptyString("focusedFieldContent") { parts.append("\n## Focused Field Content\n\(focused)") }
        if let snippets = d["visibleTextSnippets"]?.stringArray, !snippets.isEmpty {
            parts.append("\n## Visible Text Snippets\n\(snippets.map { "- \($0)" }.joined(separator: "\n"))")
        }
        return parts.joined(separator: "\n")
    }

    private static func formatMemos(_ memos: [JSONValue]) -> String {
        let memos = memos.compactMap(\.stringDictionary)
        if memos.isEmpty {
            return "No memos in the requested time range."
        }

        let lines = memos.map { memo in
            var line = "- **\(memo["title"] ?? "")** | \(memo["date"] ?? "") | \(memo["duration"] ?? "0")s"
            if let summary = memo["summary"], !summary.isEmpty {
                line += "\n  Summary: \(summary)"
            } else if let text = memo["text"], !text.isEmpty {
                line += "\n  \(text)"
            }
            line += "\n  id: `\(memo["id"] ?? "")`"
            return line
        }
        return "## Memos\n\n\(lines.joined(separator: "\n\n"))"
    }

    private static func formatMemo(_ memo: [String: JSONValue]?) -> String {
        guard let memo else { return "Memo not found." }
        var parts: [String] = [
            "# \(memo.string("title", default: "Memo"))",
            "**Date:** \(memo.string("date"))",
            "**Duration:** \(String(format: "%.0fs", memo.double("duration")))"
        ]
        parts.append("\n## Full Text\n\(memo.string("text"))")
        if let summary = memo.nonEmptyString("summary") { parts.append("\n## Summary\n\(summary)") }
        return parts.joined(separator: "\n")
    }

    private static func formatAmbientTimeline(_ snapshots: [JSONValue]) -> String {
        let snapshots = snapshots.compactMap(\.stringDictionary)
        if snapshots.isEmpty {
            return "No ambient context data in the requested time range. Ensure ambient context capture is enabled in Resonant settings."
        }

        let lines = snapshots.map { s in
            var line = "**\(s["timestamp"] ?? "")** - \(s["app"] ?? "")"
            if let window = s["window"], !window.isEmpty { line += " | \(window)" }
            if let url = s["url"], !url.isEmpty { line += " | \(url)" }
            if let file = s["file"], !file.isEmpty { line += " | \(file)" }
            if let dwell = s["dwell"], !dwell.isEmpty { line += " (\(dwell))" }
            if let clipboard = s["clipboard"], !clipboard.isEmpty { line += "\n  Clipboard: \(clipboard)" }
            if let tabs = s["tabs"], !tabs.isEmpty { line += "\n  Tabs: \(tabs)" }
            return line
        }
        return "## Ambient Timeline\n\n\(lines.joined(separator: "\n\n"))"
    }

    private static func formatAmbientUsage(_ usage: [JSONValue]) -> String {
        let usage = usage.compactMap(\.stringDictionary)
        if usage.isEmpty {
            return "No ambient context data in the requested time range."
        }
        let lines = usage.map { "- **\($0["app"] ?? "")** - \($0["totalDwell"] ?? "0m") (\($0["switches"] ?? "0") switches)" }
        return "## App Usage\n\n\(lines.joined(separator: "\n"))"
    }

    private static func formatJournals(_ journals: [JSONValue]) -> String {
        let journals = journals.compactMap(\.objectValue)
        if journals.isEmpty {
            return "No journal entries in the requested time range."
        }

        let lines = journals.map { journal -> String in
            let date = journal.string("date")
            let blockCount = journal.int("blockCount")
            var line = "- **\(date)** | \(blockCount) blocks"
            if let summary = journal.nonEmptyString("summary") {
                let truncated = summary.count > 200 ? String(summary.prefix(200)) + "..." : summary
                line += "\n  \(truncated)"
            }
            return line
        }
        return "## Journals\n\n\(lines.joined(separator: "\n\n"))"
    }

    private static func formatAmbientSnapshot(_ snapshot: JSONValue?) -> String {
        guard let s = snapshot?.stringDictionary else {
            return "No recent ambient activity. Ensure ambient context capture is enabled in Resonant settings."
        }

        var parts: [String] = ["# Current Ambient Snapshot"]
        parts.append("**Timestamp:** \(s["timestamp"] ?? "")")
        parts.append("**App:** \(s["app"] ?? "")")
        if let window = s["window"], !window.isEmpty { parts.append("**Window:** \(window)") }
        if let url = s["url"], !url.isEmpty { parts.append("**URL:** \(url)") }
        if let file = s["file"], !file.isEmpty { parts.append("**File:** \(file)") }
        if let slack = s["slack"], !slack.isEmpty { parts.append("**Slack:** @\(slack)") }
        if let dwell = s["dwell"], !dwell.isEmpty { parts.append("**Dwell:** \(dwell)") }
        if let clipboard = s["clipboard"], !clipboard.isEmpty { parts.append("**Clipboard:** \(clipboard)") }
        if let tabs = s["tabs"], !tabs.isEmpty { parts.append("**Tabs:** \(tabs)") }
        return parts.joined(separator: "\n")
    }

    private static func textResult(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [MCPContent(type: "text", text: text)], isError: nil)
    }

    private static func errorResult(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [MCPContent(type: "text", text: text)], isError: true)
    }

    private static func formatSearchResults(_ results: [[String: String]]) -> String {
        results.enumerated().map { idx, item in
            let type = item["type"] ?? "unknown"
            let date = item["date"] ?? ""
            let score = item["score"] ?? ""
            var line = "\(idx + 1). [\(type)] \(date) (relevance: \(score))"
            if let title = item["title"], !title.isEmpty { line += " - \(title)" }
            if let app = item["app"], !app.isEmpty { line += " (\(app))" }
            if let window = item["window"], !window.isEmpty { line += " | \(window)" }
            if let url = item["url"], !url.isEmpty { line += " | \(url)" }
            if let context = item["context"], !context.isEmpty, item["window"] == nil { line += " | \(context)" }
            if let text = item["text"], !text.isEmpty { line += "\n   \(String(text.prefix(300)))" }
            if let snippet = item["snippet"], !snippet.isEmpty { line += "\n   \(String(snippet.prefix(300)))" }
            if let id = item["id"] { line += "\n   id: \(id)" }
            return line
        }.joined(separator: "\n\n")
    }
}

private extension JSONValue {
    var stringArray: [String]? {
        arrayValue?.compactMap(\.stringValue)
    }

    var stringDictionary: [String: String]? {
        guard let object = objectValue else { return nil }
        return object.mapValues { value in
            switch value {
            case .string(let string): return string
            case .int(let int): return "\(int)"
            case .double(let double): return "\(double)"
            case .bool(let bool): return "\(bool)"
            case .null: return ""
            case .array, .object: return value.prettyJSONString ?? ""
            }
        }
    }

    var prettyJSONString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String, default fallback: String = "") -> String {
        self[key]?.stringValue ?? fallback
    }

    func nonEmptyString(_ key: String) -> String? {
        guard let string = self[key]?.stringValue, !string.isEmpty else { return nil }
        return string
    }

    func int(_ key: String) -> Int {
        self[key]?.intValue ?? 0
    }

    func double(_ key: String) -> Double {
        self[key]?.doubleValue ?? 0
    }
}
