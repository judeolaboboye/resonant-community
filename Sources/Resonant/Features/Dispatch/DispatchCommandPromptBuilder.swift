import Foundation

enum DispatchCommandPromptBuilder {
    static func build(command: String, context: ContextPacket?) -> String {
        var contextSection = ""
        if let context {
            let contextLines = contextLines(for: context)
            if !contextLines.isEmpty {
                contextSection = "\nCONTEXT:\n" + contextLines.joined(separator: "\n")
            }
        }

        return """
        You are Resonant's voice command processor. The user spoke a command and you must decide what action to take.

        AVAILABLE ACTIONS (respond with exactly one JSON object):

        1. Type text into the active app:
           {"action": "type_text", "text": "...", "app_hint": "optional app name"}

        2. Open a URL:
           {"action": "open_url", "url": "https://..."}

        3. Open/switch to an app:
           {"action": "open_app", "name": "App Name"}

        4. Search the user's workspace (dictations, meetings, memos):
           {"action": "search_workspace", "query": "search terms"}

        5. Speak an answer to the user:
           {"action": "speak_answer", "text": "what to say"}

        6. Create a ticket:
           {"action": "create_ticket", "title": "...", "body": "...", "service": "linear|github"}

        7. Post to Slack:
           {"action": "post_slack", "channel": "channel-name", "message": "..."}

        8. Delegate to an AI agent:
           {"action": "delegate_agent", "agent": "devin|claude_code|cursor", "prompt": "...", "context": "optional"}

        9. Multiple actions:
           {"action": "composite", "actions": [{...}, {...}]}

        EXECUTION PLAYBOOKS:
        - Always choose an executable action. Do not merely describe what should happen.
        - If the user asks to write, reply, comment, post, send, or fill "here" and the focused field is a compose/reply/comment/text/search/code field, use type_text with the generated text and app_hint set to the active app.
        - For Slack/chat commands, use post_slack when a channel or recipient is named. If the user says "here" in an active chat field, use type_text.
        - For Linear/GitHub task commands, use create_ticket with a concise title and body. Include enough command/context detail in body for the user to paste or submit.
        - For agent commands involving Devin, Claude Code, or Cursor, use delegate_agent with a self-contained prompt and relevant local context.
        - For browser or web-app tasks, prefer a direct open_url when a reliable URL can accomplish the task. Otherwise use type_text into the active field or speak_answer to ask for the missing target.
        - For app-specific multi-step tasks that can be done with the available actions, use composite, for example open_app followed by type_text.
        - Treat SURFACE LINKS as durable return targets for browser-backed inboxes, threads, issues, documents, and web-app pages.
        - Treat TARGET ANCHOR as an in-session focused-field locator, not a durable URL.
        - If the requested operation requires clicks, menus, or private app APIs that are not available in this schema, prepare the nearest useful draft/prompt rather than pretending it was completed.

        RULES:
        - Respond ONLY with a single JSON object. No markdown, no explanation.
        - Infer the best action from the command and context.
        - For questions or lookups, search the workspace first, then speak the answer.
        - For "post it here" / "type it here", use type_text with the generated content.
        - For ambiguous commands, prefer speak_answer to confirm understanding.
        \(contextSection)

        USER COMMAND: \(command)

        JSON:
        """
    }

    private static func contextLines(for context: ContextPacket) -> [String] {
        var lines: [String] = []
        if let app = context.surface.appName {
            lines.append("Active app: \(app)")
        }
        if let bundleId = context.surface.bundleId {
            lines.append("Bundle ID: \(bundleId)")
        }
        if let window = context.surface.windowTitle {
            lines.append("Window: \(window)")
        }
        if let url = context.surface.browserURL {
            lines.append("URL: \(url)")
        }
        lines.append("Surface: \(context.surface.kind.rawValue)")
        lines.append("Focused field: \(context.surface.fieldKind.rawValue)")
        if let conversation = context.surface.conversationLabel {
            lines.append("Conversation: \(conversation)")
        }
        if let document = context.surface.documentLabel {
            lines.append("Document: \(document)")
        }
        if let project = context.surface.projectLabel {
            lines.append("Project: \(project)")
        }
        if let selectedText = context.selectedTextPreview, !selectedText.isEmpty {
            lines.append("Selected text preview: \(selectedText)")
        }
        if let focusedText = context.focusedFieldPreview, !focusedText.isEmpty {
            lines.append("Focused field preview: \(focusedText)")
        }
        if !context.visibleGroundingSnippets.isEmpty {
            lines.append("Visible snippets: \(context.visibleGroundingSnippets.prefix(3).joined(separator: " | "))")
        }
        let links = DispatchSurfaceLinkResolver.links(contextPacket: context)
        let surfaceLinks = links.filter { $0.url != nil }
        if !surfaceLinks.isEmpty {
            lines.append("Surface links: \(surfaceLinks.map { "\($0.kind.rawValue)=\($0.url ?? "")" }.joined(separator: " | "))")
        }
        let anchors = links.filter { $0.url == nil }
        if !anchors.isEmpty {
            lines.append("Target anchors: \(anchors.map(\.label).joined(separator: " | "))")
        }
        let entities = context.entities
            .filter { !$0.isSensitive && $0.trustTier != .blocked }
            .sorted { $0.rankingScore > $1.rankingScore }
            .prefix(6)
            .map { "\($0.type.rawValue)=\($0.value)" }
        if !entities.isEmpty {
            lines.append("Grounded entities: \(entities.joined(separator: ", "))")
        }
        return lines
    }
}
