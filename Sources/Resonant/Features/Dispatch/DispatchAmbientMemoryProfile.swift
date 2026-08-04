import Foundation

struct DispatchAmbientMemoryProfile: Sendable {
    struct Memory: Sendable {
        var logID: UUID
        var timestamp: Date
        var command: String
        var commandTokens: [String]
        var surface: DispatchSurfaceFingerprint
        var routeCard: DispatchRouteCard
        var action: CommandAction?
        var routeConfidence: Double
        var surfaceScore: Double
        var recencyScore: Double
    }

    var currentSurface: DispatchSurfaceFingerprint
    var memories: [Memory]

    @MainActor
    static func build(
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot],
        logs: [DispatchLogEntry],
        now: Date = Date()
    ) -> DispatchAmbientMemoryProfile {
        let currentSurface = DispatchLearningStore.surfaceFingerprint(
            contextPacket: contextPacket,
            snapshots: snapshots
        )

        let memories = logs.compactMap { log -> Memory? in
            guard log.resultSuccess,
                  log.correctionKind == nil,
                  log.action != nil else {
                return nil
            }

            let surfaceScore = log.surface.matchScore(against: currentSurface)
            guard surfaceScore >= 0.46 else { return nil }

            let ageSeconds = max(0, now.timeIntervalSince(log.timestamp))
            let recencyScore = max(0.05, 1 - min(ageSeconds / (30 * 24 * 60 * 60), 1))

            return Memory(
                logID: log.id,
                timestamp: log.timestamp,
                command: log.command,
                commandTokens: commandTokens(for: log.command),
                surface: log.surface,
                routeCard: log.routeCard,
                action: log.action,
                routeConfidence: log.confidence,
                surfaceScore: surfaceScore,
                recencyScore: recencyScore
            )
        }
        .sorted { lhs, rhs in
            let left = lhs.surfaceScore * 0.62 + lhs.routeConfidence * 0.25 + lhs.recencyScore * 0.13
            let right = rhs.surfaceScore * 0.62 + rhs.routeConfidence * 0.25 + rhs.recencyScore * 0.13
            if left == right {
                return lhs.timestamp > rhs.timestamp
            }
            return left > right
        }
        .prefix(12)

        return DispatchAmbientMemoryProfile(
            currentSurface: currentSurface,
            memories: Array(memories)
        )
    }

    func inferredIntent(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchInferredIntent? {
        let commandTokens = Self.commandTokens(for: command)
        guard let memory = rankedMemory(for: command, commandTokens: commandTokens) else {
            return nil
        }

        if let inferred = inferTextTarget(
            command: command,
            contextPacket: contextPacket,
            memory: memory
        ) {
            return inferred
        }

        if let inferred = inferAgentDelegation(
            command: command,
            contextPacket: contextPacket,
            snapshots: snapshots,
            memory: memory
        ) {
            return inferred
        }

        if let inferred = inferTicket(command: command, contextPacket: contextPacket, memory: memory) {
            return inferred
        }

        if let inferred = inferAppSwitch(command: command, memory: memory) {
            return inferred
        }

        return nil
    }

    private func rankedMemory(for command: String, commandTokens: [String]) -> Memory? {
        let normalized = Self.normalized(command)
        let hasMemoryCue = Self.containsAny(normalized, Self.memoryCues)
        let hasActionCue = Self.containsAny(normalized, Self.actionCues)

        return memories
            .compactMap { memory -> (Memory, Double)? in
                let commandScore = Self.jaccard(commandTokens, memory.commandTokens)
                let routeCueBonus = routeCueBonus(for: memory.routeCard.intent, command: normalized)
                let score = memory.surfaceScore * 0.48
                    + commandScore * 0.22
                    + memory.routeConfidence * 0.16
                    + memory.recencyScore * 0.08
                    + routeCueBonus
                    + (hasMemoryCue ? 0.08 : 0)

                guard score >= 0.58 else { return nil }
                guard memory.surfaceScore >= 0.72
                    || commandScore >= 0.22
                    || hasMemoryCue
                    || hasActionCue && routeCueBonus > 0 else {
                    return nil
                }
                return (memory, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.timestamp > rhs.0.timestamp
                }
                return lhs.1 > rhs.1
            }
            .first?
            .0
    }

    private func inferTextTarget(
        command: String,
        contextPacket: ContextPacket?,
        memory: Memory
    ) -> DispatchInferredIntent? {
        guard [.activeText, .slackDraft].contains(memory.routeCard.intent),
              let surface = contextPacket?.surface,
              surface.fieldKind.acceptsAmbientTextTarget,
              memory.surfaceScore >= 0.72,
              targetAllowsActiveText(memory: memory),
              let text = Self.inferredText(command: command) else {
            return nil
        }

        let confidence = min(0.91, 0.66 + memory.surfaceScore * 0.18 + memory.routeConfidence * 0.07)
        return DispatchInferredIntent(
            action: .typeText(text: text, appHint: surface.appName),
            confidence: confidence,
            reason: "Ambient memory matched this command to a previously successful focused text target.",
            evidence: evidence(for: memory) + [
                "Current field: \(surface.fieldKind.rawValue)",
                targetEvidence(for: memory),
                "Typed fresh text from this command."
            ].compactMap { $0 }
        )
    }

    private func targetAllowsActiveText(memory: Memory) -> Bool {
        guard memory.surface.hasAXTarget, currentSurface.hasAXTarget else {
            return false
        }
        return memory.surface.axTargetMatchScore(against: currentSurface) >= DispatchTargetGuard.minimumAXTargetScore
    }

    private func targetEvidence(for memory: Memory) -> String? {
        guard memory.surface.hasAXTarget, currentSurface.hasAXTarget else {
            return nil
        }
        let score = memory.surface.axTargetMatchScore(against: currentSurface)
        return "AX target match: \(String(format: "%.2f", score))."
    }

    private func inferAgentDelegation(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot],
        memory: Memory
    ) -> DispatchInferredIntent? {
        guard case .delegateToAgent(let agent, _, let previousContext)? = memory.action,
              memory.routeCard.intent == .agentDelegation,
              Self.containsAny(Self.normalized(command), Self.agentCues) else {
            return nil
        }

        let links = DispatchSurfaceLinkResolver.links(contextPacket: contextPacket, snapshots: snapshots)
        var contextLines = links.map { "\($0.kind.rawValue): \($0.url ?? $0.label)" }
        if let previousContext, !previousContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextLines.append("Previous successful context: \(previousContext)")
        }
        let explicitContext = contextLines.isEmpty ? nil : contextLines.joined(separator: "\n")

        return DispatchInferredIntent(
            action: .delegateToAgent(agent: agent, prompt: command, context: explicitContext),
            confidence: min(0.88, 0.62 + memory.surfaceScore * 0.16 + memory.routeConfidence * 0.08),
            reason: "Ambient memory matched this command to a previously successful agent workflow.",
            evidence: evidence(for: memory) + Array(contextLines.prefix(4))
        )
    }

    private func inferTicket(
        command: String,
        contextPacket: ContextPacket?,
        memory: Memory
    ) -> DispatchInferredIntent? {
        guard case .createTicket(_, _, let service)? = memory.action,
              memory.routeCard.intent == .ticketDraft,
              Self.containsAny(Self.normalized(command), Self.ticketCues) else {
            return nil
        }

        let title = Self.ticketTitle(from: command)
        var evidence = evidence(for: memory)
        if let project = contextPacket?.surface.projectLabel {
            evidence.append("Project: \(project)")
        }

        return DispatchInferredIntent(
            action: .createTicket(
                title: title,
                body: "Created from Dispatch command: \(command)",
                service: service
            ),
            confidence: min(0.86, 0.61 + memory.surfaceScore * 0.16 + memory.routeConfidence * 0.08),
            reason: "Ambient memory matched this command to a previously successful ticket workflow.",
            evidence: evidence
        )
    }

    private func inferAppSwitch(command: String, memory: Memory) -> DispatchInferredIntent? {
        guard case .openApp(let appName)? = memory.action,
              memory.routeCard.intent == .openApp,
              Self.containsAny(Self.normalized(command), Self.appSwitchCues) else {
            return nil
        }

        return DispatchInferredIntent(
            action: .openApp(name: appName),
            confidence: min(0.88, 0.64 + memory.surfaceScore * 0.12 + memory.routeConfidence * 0.08),
            reason: "Ambient memory matched this command to a previously successful app switch.",
            evidence: evidence(for: memory)
        )
    }

    private func routeCueBonus(for intent: DispatchRouteIntent, command: String) -> Double {
        switch intent {
        case .activeText, .slackDraft:
            return Self.containsAny(command, Self.textCues) ? 0.1 : 0
        case .agentDelegation:
            return Self.containsAny(command, Self.agentCues) ? 0.14 : 0
        case .ticketDraft:
            return Self.containsAny(command, Self.ticketCues) ? 0.12 : 0
        case .openApp:
            return Self.containsAny(command, Self.appSwitchCues) ? 0.1 : 0
        case .openURL, .workspaceSearch, .spokenAnswer, .composite, .cloudClassification:
            return 0
        }
    }

    private func evidence(for memory: Memory) -> [String] {
        [
            "Ambient memory: prior \(memory.routeCard.title) succeeded.",
            "Prior command: \(memory.command)",
            "Surface match: \(String(format: "%.2f", memory.surfaceScore))."
        ]
    }

    private static func inferredText(command: String) -> String? {
        let patterns = [
            #"(?i)^\s*(?:reply|respond|answer)\s+here\s+(?:that\s+)?(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:reply|respond|answer)\s+that\s+(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:write|type|insert|put|enter)\s+(.+?)\s+(?:here|in\s+(?:this|the)\s+(?:box|field|app|window|text\s+field)|into\s+(?:this|the)\s+(?:box|field|text\s+field))\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:reply|respond|comment|post|send|say|tell them)\s+(?:with\s+)?(.+?)\s+(?:here|in\s+(?:this|the)\s+(?:thread|chat|comment|box|field))\s*[.!?]?\s*$"#,
            #"(?i)^\s*(?:reply|respond|comment|post|send|say|tell them)\s+(?:with\s+)?(.+?)\s*[.!?]?\s*$"#
        ]

        for pattern in patterns {
            if let content = firstCapture(pattern: pattern, in: command).flatMap(cleanContent) {
                return content
            }
        }
        return nil
    }

    private static func ticketTitle(from command: String) -> String {
        let patterns = [
            #"(?i)\b(?:to|for)\s+(.+)$"#,
            #"(?i)\b(?:called|titled|named)\s+(.+)$"#,
            #"(?i)^\s*(?:create|make|add|file|open)\s+(?:a\s+|an\s+|new\s+)?(?:linear|github)?\s*(?:ticket|issue|task)\s+(.+)$"#
        ]
        for pattern in patterns {
            if let title = firstCapture(pattern: pattern, in: command).flatMap(cleanContent) {
                return title
            }
        }
        return cleanContent(command) ?? "New task"
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commandTokens(for command: String) -> [String] {
        let rawTokens = normalized(command)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let stopwords: Set<String> = [
            "a", "an", "and", "are", "can", "could", "do", "for", "from", "get",
            "give", "go", "i", "in", "it", "me", "my", "of", "on", "or", "please",
            "that", "the", "this", "to", "use", "with", "you"
        ]
        return Array(rawTokens
            .filter { $0.count > 1 && !stopwords.contains($0) }
            .prefix(16))
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

    private static func jaccard(_ lhs: [String], _ rhs: [String]) -> Double {
        let left = Set(lhs)
        let right = Set(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private static let memoryCues: Set<String> = [
        "again", "same", "usual", "like before", "as before", "normally", "default"
    ]

    private static let actionCues: Set<String> = [
        "reply", "respond", "comment", "post", "send", "say", "tell them",
        "ticket", "issue", "task", "agent", "devin", "devon", "claude", "cursor",
        "fix", "clean", "cleanup", "implement", "open", "switch"
    ]

    private static let textCues: Set<String> = [
        "reply", "respond", "comment", "post", "send", "say", "tell them", "write", "type"
    ]

    private static let agentCues: Set<String> = [
        "agent", "devin", "devon", "claude", "cursor", "fix", "clean", "cleanup",
        "implement", "build", "work on", "continue", "hand this", "send this"
    ]

    private static let ticketCues: Set<String> = [
        "ticket", "issue", "task", "bug", "todo", "follow up", "file", "create", "add"
    ]

    private static let appSwitchCues: Set<String> = [
        "open", "switch", "go to", "usual", "same", "triage app", "app"
    ]
}

private extension FieldKind {
    var acceptsAmbientTextTarget: Bool {
        switch self {
        case .compose, .reply, .comment, .search, .title, .subject, .code, .terminal, .richText, .plainText:
            return true
        case .address, .unknown:
            return false
        }
    }
}
