import Foundation

enum DispatchLocalActionResolver {
    static func action(for command: String) -> CommandAction? {
        deterministicAction(for: command) ?? fallbackAction(for: command)
    }

    static func action(for command: String, contextPacket: ContextPacket?) -> CommandAction? {
        deterministicAction(for: command, contextPacket: contextPacket) ?? fallbackAction(for: command)
    }

    static func deterministicAction(for command: String) -> CommandAction? {
        weatherAction(for: command)
            ?? explicitURLAction(for: command)
            ?? webSearchAction(for: command)
            ?? workspaceSearchAction(for: command)
            ?? openKnownAppAction(for: command)
            ?? ticketAction(for: command)
    }

    static func deterministicAction(for command: String, contextPacket: ContextPacket?) -> CommandAction? {
        deterministicAction(for: command)
            ?? currentSurfaceTextAction(for: command, contextPacket: contextPacket)
    }

    static func ticketActionForInference(_ command: String) -> CommandAction? {
        ticketAction(for: command)
    }

    static func weatherAction(for command: String) -> CommandAction? {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        guard normalized.contains("weather") else { return nil }

        let location = weatherLocation(from: command)
        let query = ["weather", location].compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: " ")

        return googleSearchAction(query: query)
    }

    private static func explicitURLAction(for command: String) -> CommandAction? {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)\b(?:open|go to|visit)\s+(https?://[^\s]+)"#,
            #"(?i)\b(?:open|go to|visit)\s+([A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/[^\s]*)?)"#
        ]
        for pattern in patterns {
            if let match = firstCapture(pattern: pattern, in: normalized) {
                let url = match.lowercased().hasPrefix("http") ? match : "https://\(match)"
                return .openURL(url: url)
            }
        }
        return nil
    }

    private static func webSearchAction(for command: String) -> CommandAction? {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        guard normalized.contains("google") || normalized.contains("search the web") else {
            return nil
        }

        let patterns = [
            #"(?i)\b(?:google|search google for|search the web for|search for|look up|find)\s+(.+?)(?:\s+on\s+google)?$"#,
            #"(?i)\b(?:search|look up|find)\s+(.+?)\s+on\s+google$"#
        ]
        for pattern in patterns {
            guard var query = firstCapture(pattern: pattern, in: command) else { continue }
            query = cleanQuery(query)
            guard !query.isEmpty, query.lowercased() != "google" else { continue }
            return googleSearchAction(query: query)
        }
        return nil
    }

    private static func workspaceSearchAction(for command: String) -> CommandAction? {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let workspaceHints = [
            "workspace", "memory", "dictation", "dictations", "memo", "memos",
            "meeting", "meetings", "journal", "activity", "what did i say"
        ]
        guard workspaceHints.contains(where: normalized.contains) else { return nil }

        let patterns = [
            #"(?i)\b(?:search|find|look up)\s+(?:my\s+)?(?:workspace|memory|dictations?|memos?|meetings?|journal|activity)\s+(?:for|about)?\s*(.+)$"#,
            #"(?i)\bwhat did i say about\s+(.+)$"#,
            #"(?i)\b(?:find|search)\s+(.+?)\s+in\s+(?:my\s+)?(?:workspace|memory|dictations?|memos?|meetings?|journal|activity)$"#
        ]
        for pattern in patterns {
            guard var query = firstCapture(pattern: pattern, in: command) else { continue }
            query = cleanQuery(query)
            guard !query.isEmpty else { continue }
            return .searchWorkspace(query: query)
        }
        return nil
    }

    private static func openKnownAppAction(for command: String) -> CommandAction? {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["open up ", "open ", "launch ", "switch to ", "go to ", "bring up "]
        guard prefixes.contains(where: normalized.hasPrefix) else { return nil }

        let appAliases: [(aliases: [String], app: String)] = [
            (["slack"], "Slack"),
            (["safari"], "Safari"),
            (["chrome", "google chrome"], "Google Chrome"),
            (["linear"], "Linear"),
            (["cursor"], "Cursor"),
            (["claude", "claude code"], "Claude"),
            (["terminal"], "Terminal"),
            (["finder"], "Finder"),
            (["calendar"], "Calendar"),
            (["mail"], "Mail"),
            (["notes"], "Notes"),
            (["messages", "imessage"], "Messages"),
            (["notion"], "Notion"),
            (["figma"], "Figma"),
            (["github desktop"], "GitHub Desktop")
        ]

        let requestedApp = prefixes.reduce(normalized) { current, prefix in
            current.hasPrefix(prefix) ? String(current.dropFirst(prefix.count)) : current
        }
        let cleanedRequestedApp = requestedApp
            .replacingOccurrences(of: #"(?i)^the\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+please$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+(?:app|application|window)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for candidate in appAliases {
            if candidate.aliases.contains(where: { alias in
                cleanedRequestedApp == alias
            }) {
                return .openApp(name: candidate.app)
            }
        }
        return nil
    }

    private static func currentSurfaceTextAction(
        for command: String,
        contextPacket: ContextPacket?
    ) -> CommandAction? {
        guard let surface = contextPacket?.surface,
              surface.fieldKind.acceptsDirectTextCommand else {
            return nil
        }

        let contentPatterns = [
            #"(?i)^\s*(?:reply|respond|answer)\s+here\s+(?:that\s+)?(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:reply|respond|answer)\s+that\s+(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:write|type|insert|put|enter)\s+(.+?)\s+(?:here|in\s+(?:this|the)\s+(?:box|field|app|window|text\s+field)|into\s+(?:this|the)\s+(?:box|field|text\s+field))\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:reply|respond|comment|post|send|say)\s+(?:with\s+)?(.+?)\s+(?:here|in\s+(?:this|the)\s+(?:thread|chat|comment|box|field))\s*[.!?]?\s*$"#
        ]

        for pattern in contentPatterns {
            guard let content = firstCapture(pattern: pattern, in: command).flatMap(cleanDictatedContent),
                  !content.isEmpty else {
                continue
            }
            return .typeText(text: content, appHint: surface.appName)
        }

        if surface.kind == .chat || surface.fieldKind == .reply || surface.fieldKind == .comment {
            let directPatterns = [
                #"(?i)^\s*(?:reply|respond)\s+(?:with\s+)?(.+?)\s*[.!?]?\s*$"#,
                #"(?i)^\s*comment\s+(?:with\s+)?(.+?)\s*[.!?]?\s*$"#,
                #"(?i)^\s*say\s+(.+?)\s*[.!?]?\s*$"#
            ]
            for pattern in directPatterns {
                guard let content = firstCapture(pattern: pattern, in: command).flatMap(cleanDictatedContent),
                      !content.isEmpty else {
                    continue
                }
                return .typeText(text: content, appHint: surface.appName)
            }
        }

        return nil
    }

    private static func ticketAction(for command: String) -> CommandAction? {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        guard matches(pattern: #"\b(?:create|make|add|file|open)\s+(?:a\s+|an\s+|new\s+)?(?:linear\s+|github\s+)?(?:ticket|issue|task)\b|\b(?:linear|github)\b.*\b(?:ticket|issue|task)\b"#, in: normalized) else {
            return nil
        }

        let service: CommandAction.TicketService = normalized.contains("github") ? .github : .linear
        let titlePatterns = [
            #"(?i)\b(?:to|for)\s+(.+)$"#,
            #"(?i)\b(?:called|titled|named)\s+(.+)$"#,
            #"(?i)^\s*(?:create|make|add|file|open)\s+(?:a\s+|an\s+|new\s+)?(?:linear|github)?\s*(?:ticket|issue|task)\s+(.+)$"#
        ]

        let title = titlePatterns
            .compactMap { firstCapture(pattern: $0, in: command).flatMap(cleanDictatedContent) }
            .first { !$0.isEmpty }
            ?? cleanDictatedContent(command)
            ?? "New task"

        return .createTicket(title: title, body: "Created from Dispatch command: \(command)", service: service)
    }

    private static func googleSearchAction(query: String) -> CommandAction? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]

        guard let url = components?.url?.absoluteString else { return nil }
        return .openURL(url: url)
    }

    static func fallbackAction(for command: String) -> CommandAction? {
        if let deterministic = deterministicAction(for: command) {
            return deterministic
        }

        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        if normalized.contains("devin") || normalized.contains("devon") {
            return .delegateToAgent(agent: .devin, prompt: command, context: nil)
        }

        if normalized.contains("claude") || normalized.contains("claude code") {
            return .delegateToAgent(agent: .claudeCode, prompt: command, context: nil)
        }

        if normalized.contains("cursor") {
            return .delegateToAgent(agent: .cursor, prompt: command, context: nil)
        }

        return nil
    }

    private static func weatherLocation(from command: String) -> String {
        let nsCommand = command as NSString
        let range = NSRange(location: 0, length: nsCommand.length)
        let pattern = #"\bin\s+(.+)$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.matches(in: command, range: range).last,
              match.numberOfRanges > 1 else {
            return ""
        }

        var location = nsCommand.substring(with: match.range(at: 1))
        let removals = [
            #"(?i)\s+on\s+google\b.*$"#,
            #"(?i)\s+in\s+google\b.*$"#,
            #"(?i)\s+using\s+google\b.*$"#
        ]
        for pattern in removals {
            location = location.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return location.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanQuery(_ query: String) -> String {
        query
            .replacingOccurrences(of: #"(?i)\b(on|using)\s+google\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanDictatedContent(_ content: String) -> String? {
        let trimmed = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private static func matches(pattern: String, in text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return (try? NSRegularExpression(pattern: pattern))
            .map { $0.firstMatch(in: text, range: range) != nil }
            ?? false
    }
}

private extension FieldKind {
    var acceptsDirectTextCommand: Bool {
        switch self {
        case .compose, .reply, .comment, .search, .title, .subject, .code, .terminal, .richText, .plainText:
            return true
        case .address, .unknown:
            return false
        }
    }
}
