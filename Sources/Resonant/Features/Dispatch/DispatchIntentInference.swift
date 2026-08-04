import Foundation

struct DispatchInferredIntent: Sendable {
    let action: CommandAction
    let confidence: Double
    let reason: String
    let evidence: [String]
}

enum DispatchIntentInference {
    static func infer(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot],
        ambientMemoryProfile: DispatchAmbientMemoryProfile? = nil
    ) -> DispatchInferredIntent? {
        if notificationResponseText(from: command) != nil,
           recentNotification(in: snapshots) != nil {
            return inferNotificationResponse(
                command: command,
                contextPacket: contextPacket,
                snapshots: snapshots
            )
        }
        if let reply = inferCurrentTextTarget(command: command, contextPacket: contextPacket) {
            return reply
        }
        if let memory = ambientMemoryProfile?.inferredIntent(
            command: command,
            contextPacket: contextPacket,
            snapshots: snapshots
        ) {
            return memory
        }
        if let ticket = inferTicket(command: command, contextPacket: contextPacket, snapshots: snapshots) {
            return ticket
        }
        if let agent = inferAgentDelegation(command: command, contextPacket: contextPacket, snapshots: snapshots) {
            return agent
        }
        return nil
    }

    private static func inferCurrentTextTarget(
        command: String,
        contextPacket: ContextPacket?
    ) -> DispatchInferredIntent? {
        guard let contextPacket,
              contextPacket.surface.fieldKind.acceptsLocalDispatchText else {
            return nil
        }

        let normalized = normalized(command)
        let intent = contextPacket.intent.kind
        let surface = contextPacket.surface
        let hasExplicitHere = normalized.contains(" here")
            || normalized.contains(" this box")
            || normalized.contains(" this field")
            || normalized.contains(" in this")

        let shouldTargetCurrentField = hasExplicitHere
            || [.reply, .compose, .formFill, .socialComment, .codeText].contains(intent)
            || (surface.kind == .chat && containsAny(normalized, chatWriteCues))
            || (surface.kind == .email && containsAny(normalized, emailWriteCues))
            || (surface.kind == .task && containsAny(normalized, taskWriteCues))

        guard shouldTargetCurrentField,
              let text = inferredText(command: command, surface: surface) else {
            return nil
        }

        let links = DispatchSurfaceLinkResolver.links(contextPacket: contextPacket)
        var evidence = [
            "Inferred current focused \(surface.fieldKind.rawValue) field from \(surface.kind.rawValue) surface.",
            "Dictation intent: \(intent.rawValue)."
        ]
        if let link = links.first {
            evidence.append("\(link.kind.rawValue): \(link.url ?? link.label)")
        }
        if contextPacket.targetFingerprint != nil {
            evidence.append("Focused AX target fingerprint is available.")
        }

        return DispatchInferredIntent(
            action: .typeText(text: text, appHint: surface.appName),
            confidence: contextPacket.targetFingerprint == nil ? 0.72 : 0.86,
            reason: "Local inference matched the command to the current focused text target.",
            evidence: evidence
        )
    }

    private static func inferNotificationResponse(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchInferredIntent? {
        guard let contextPacket,
              contextPacket.surface.fieldKind.acceptsLocalDispatchText,
              let notification = recentNotification(in: snapshots),
              surface(contextPacket.surface, matches: notification),
              notificationConversationMatchesCurrentSurface(
                notification: notification,
                contextPacket: contextPacket,
                snapshots: snapshots
              ),
              let text = notificationResponseText(from: command) else {
            return nil
        }

        var evidence = [
            "Recent notification: \(notification.summary)",
            "Current app: \(contextPacket.surface.appName ?? "unknown")",
            "Focused field: \(contextPacket.surface.fieldKind.rawValue)"
        ]
        if let conversation = notificationConversationLabel(notification) {
            evidence.append("Notification conversation: \(conversation)")
        }
        if let conversation = currentConversationLabel(contextPacket: contextPacket, snapshots: snapshots) {
            evidence.append("Current conversation: \(conversation)")
        }

        return DispatchInferredIntent(
            action: .typeText(text: text, appHint: contextPacket.surface.appName),
            confidence: contextPacket.targetFingerprint == nil ? 0.76 : 0.88,
            reason: "Local inference matched a vague reply command to the recent notification context.",
            evidence: evidence
        )
    }

    private static func inferTicket(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchInferredIntent? {
        guard let action = DispatchLocalActionResolver.ticketActionForInference(command) else {
            return nil
        }

        let links = DispatchSurfaceLinkResolver.links(contextPacket: contextPacket, snapshots: snapshots)
        var evidence = ["Inferred ticket draft from task/issue wording."]
        if let link = links.first(where: { [.linear, .github].contains($0.kind) }) {
            evidence.append("\(link.kind.rawValue) surface link: \(link.url ?? link.label)")
        }
        if let project = contextPacket?.surface.projectLabel {
            evidence.append("Project: \(project)")
        }

        return DispatchInferredIntent(
            action: action,
            confidence: evidence.count > 1 ? 0.84 : 0.74,
            reason: "Local inference matched a ticket creation command.",
            evidence: evidence
        )
    }

    private static func inferAgentDelegation(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchInferredIntent? {
        let normalized = normalized(command)
        let agent: CommandAction.AgentTarget
        if normalized.contains("devin") || normalized.contains("devon") {
            agent = .devin
        } else if normalized.contains("claude code") || normalized.contains("claude") {
            agent = .claudeCode
        } else if normalized.contains("cursor") {
            agent = .cursor
        } else {
            return nil
        }

        let links = DispatchSurfaceLinkResolver.links(contextPacket: contextPacket, snapshots: snapshots)
        let contextLines = links.map { "\($0.kind.rawValue): \($0.url ?? $0.label)" }
        let explicitContext = contextLines.isEmpty ? nil : contextLines.joined(separator: "\n")
        return DispatchInferredIntent(
            action: .delegateToAgent(agent: agent, prompt: command, context: explicitContext),
            confidence: explicitContext == nil ? 0.62 : 0.78,
            reason: "Local inference matched an agent delegation command and attached available surface links.",
            evidence: ["Agent cue: \(agent.rawValue)"] + contextLines
        )
    }

    private static func inferredText(command: String, surface: SurfaceDescriptor) -> String? {
        let patterns = [
            #"(?i)^\s*(?:reply|respond|answer)\s+here\s+(?:that\s+)?(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:reply|respond|answer)\s+that\s+(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:write|type|insert|put|enter)\s+(.+?)\s+(?:here|in\s+(?:this|the)\s+(?:box|field|app|window|text\s+field)|into\s+(?:this|the)\s+(?:box|field|text\s+field))\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:reply|respond|comment|post|send|say)\s+(?:with\s+)?(.+?)\s+(?:here|in\s+(?:this|the)\s+(?:thread|chat|comment|box|field))\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:reply|respond)\s+(?:with\s+)?(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*comment\s+(?:with\s+)?(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*say\s+(.+?)\s*[.!?]?\s*$"#
        ]
        for pattern in patterns {
            if let content = firstCapture(pattern: pattern, in: command).flatMap(cleanContent) {
                return content
            }
        }

        if surface.kind == .chat || surface.fieldKind == .reply || surface.fieldKind == .comment {
            return cleanContent(command)
        }
        return nil
    }

    private static func notificationResponseText(from command: String) -> String? {
        let patterns = [
            #"(?i)^\s*(?:reply|respond|answer)\s+(?:to\s+)?(?:that|it|the\s+notification|them)\s+(?:saying|with|that)\s+(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:tell|message)\s+them\s+(?:that\s+)?(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*say\s+(?:that\s+)?(.+?)\s*(?:to\s+them|back)\s*[.!?]?\s*$"#
        ]
        for pattern in patterns {
            if let content = firstCapture(pattern: pattern, in: command).flatMap(cleanContent) {
                return content
            }
        }
        return nil
    }

    private static func recentNotification(in snapshots: [DispatchRouteSnapshot]) -> DispatchNotificationHint? {
        let cutoff = Date().addingTimeInterval(-10 * 60)
        return snapshots
            .compactMap(\.notificationHint)
            .filter { $0.receivedAt >= cutoff }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first
    }

    private static func surface(
        _ surface: SurfaceDescriptor,
        matches notification: DispatchNotificationHint
    ) -> Bool {
        let currentSurface = DispatchAppSurfaceResolver.resolve(
            appName: surface.appName,
            bundleID: surface.bundleId,
            browserTitle: surface.windowTitle,
            browserURL: surface.browserURL
        )
        let notificationSurface = DispatchAppSurfaceResolver.resolve(
            appName: notification.appName,
            bundleID: notification.bundleId,
            browserTitle: notification.title,
            browserURL: notification.url
        )
        if currentSurface.isKnownApp, notificationSurface.isKnownApp {
            return currentSurface.kind == notificationSurface.kind
        }

        let appName = normalized(surface.appName ?? "")
        let notificationApp = normalized(notification.appName)
        if appNamesMatch(appName, notificationApp) {
            return true
        }

        if let bundle = surface.bundleId,
           let notificationBundle = notification.bundleId,
           normalized(bundle) == normalized(notificationBundle) {
            return true
        }

        if let url = notification.url,
           let host = URL(string: url)?.host(percentEncoded: false),
           let siteHost = surface.siteHost {
            let notificationHost = normalized(host)
            let currentHost = normalized(siteHost)
            if !notificationHost.isEmpty, !currentHost.isEmpty,
               (notificationHost.contains(currentHost) || currentHost.contains(notificationHost)) {
                return true
            }
        }

        if let browserURL = surface.browserURL,
           let notificationURL = notification.url,
           let browserHost = URL(string: browserURL)?.host(percentEncoded: false),
           let notificationHost = URL(string: notificationURL)?.host(percentEncoded: false),
           normalized(browserHost) == normalized(notificationHost) {
            return true
        }

        return false
    }

    private static func notificationConversationMatchesCurrentSurface(
        notification: DispatchNotificationHint,
        contextPacket: ContextPacket,
        snapshots: [DispatchRouteSnapshot]
    ) -> Bool {
        let notificationIdentifiers = DispatchNotificationCorrelation.conversationIdentifiers(in: [
            notification.title,
            notification.url
        ])
        let currentIdentifiers = DispatchNotificationCorrelation.conversationIdentifiers(in: [
            contextPacket.surface.conversationLabel,
            contextPacket.surface.windowTitle,
            contextPacket.surface.browserURL,
            snapshots.first(where: { snapshot in
                surface(contextPacket.surface, matches: notification)
                    && surfaceForSnapshot(snapshot).kind == surfaceForContext(contextPacket.surface).kind
            })?.slackRecipient
        ])

        return DispatchNotificationCorrelation.matches(
            notificationIdentifiers: notificationIdentifiers,
            currentIdentifiers: currentIdentifiers
        ) == true
    }

    private static func notificationConversationLabel(_ notification: DispatchNotificationHint) -> String? {
        DispatchNotificationCorrelation.conversationIdentifiers(in: [
            notification.title,
            notification.url
        ])
        .sorted()
        .first
    }

    private static func currentConversationLabel(
        contextPacket: ContextPacket,
        snapshots: [DispatchRouteSnapshot]
    ) -> String? {
        DispatchNotificationCorrelation.conversationIdentifiers(in: [
            contextPacket.surface.conversationLabel,
            contextPacket.surface.windowTitle,
            contextPacket.surface.browserURL,
            snapshots.first?.slackRecipient
        ])
        .sorted()
        .first
    }

    private static func surfaceForContext(_ surface: SurfaceDescriptor) -> DispatchAppSurface {
        DispatchAppSurfaceResolver.resolve(
            appName: surface.appName,
            bundleID: surface.bundleId,
            browserTitle: surface.windowTitle,
            browserURL: surface.browserURL
        )
    }

    private static func surfaceForSnapshot(_ snapshot: DispatchRouteSnapshot) -> DispatchAppSurface {
        DispatchAppSurfaceResolver.resolve(
            appName: snapshot.appName,
            bundleID: snapshot.bundleId,
            browserTitle: snapshot.windowTitle,
            browserURL: snapshot.browserURL
        )
    }

    private static func appNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }

        let ignored: Set<String> = ["app", "web", "browser", "desktop", "google", "chrome", "safari"]
        let lhsTokens = Set(lhs.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .filter { $0.count >= 4 && !ignored.contains($0) }
        let rhsTokens = Set(rhs.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .filter { $0.count >= 4 && !ignored.contains($0) }
        return !lhsTokens.isDisjoint(with: rhsTokens)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ haystack: String, _ needles: Set<String>) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static func cleanContent(_ content: String) -> String? {
        let trimmed = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    private static let chatWriteCues: Set<String> = [
        "reply", "respond", "tell them", "say", "send", "post", "message"
    ]
    private static let emailWriteCues: Set<String> = [
        "reply", "respond", "answer", "tell them", "send", "draft"
    ]
    private static let taskWriteCues: Set<String> = [
        "comment", "update", "reply", "add note", "write"
    ]
}

private extension FieldKind {
    var acceptsLocalDispatchText: Bool {
        switch self {
        case .compose, .reply, .comment, .search, .title, .subject, .code, .terminal, .richText, .plainText:
            return true
        case .address, .unknown:
            return false
        }
    }
}
