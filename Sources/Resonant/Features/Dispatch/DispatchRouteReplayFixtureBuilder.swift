import Foundation

@MainActor
enum DispatchRouteReplayFixtureBuilder {
    static func scenarios(
        from logs: [DispatchLogEntry],
        failuresOnly: Bool,
        privacy: DispatchDiagnosticPrivacy
    ) -> [DispatchRouteReplayScenario] {
        logs
            .filter { !failuresOnly || !$0.resultSuccess }
            .compactMap { scenario(from: $0, privacy: privacy) }
    }

    static func payload(
        from logs: [DispatchLogEntry],
        failuresOnly: Bool,
        privacy: DispatchDiagnosticPrivacy
    ) -> JSONValue {
        let scenarios = scenarios(from: logs, failuresOnly: failuresOnly, privacy: privacy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(scenarios),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let jsonString = String(data: data, encoding: .utf8) else {
            return .object([
                "count": .int(0),
                "scenarios": .array([]),
                "error": .string("Could not encode replay fixtures.")
            ])
        }

        return .object([
            "count": .int(scenarios.count),
            "privacy": .string(privacy.isRedacted ? "redacted" : "raw"),
            "runnable": .bool(!privacy.isRedacted),
            "scenarios": value,
            "json": .string(jsonString)
        ])
    }

    private static func scenario(
        from log: DispatchLogEntry,
        privacy: DispatchDiagnosticPrivacy
    ) -> DispatchRouteReplayScenario? {
        let command = DispatchDiagnosticRedactor.redactCommand(log.command, privacy: privacy)
        let preferredAction = privacy.isRedacted ? nil : preferredAction(for: log)
        let learnedBinding = privacy.isRedacted ? nil : learnedBinding(for: log)

        return DispatchRouteReplayScenario(
            id: stableID(for: log),
            name: "\(log.routeCard.title) / \(log.resultSuccess ? "success" : "failure")",
            command: command,
            learnedBinding: learnedBinding,
            preferredAction: preferredAction,
            preferredSource: preferredSource(for: log),
            preferredReason: log.routeReason.map {
                DispatchDiagnosticRedactor.redactDiagnosticText($0, privacy: privacy)
            },
            expectation: DispatchRouteExpectation(
                routeID: log.routeCard.id,
                intent: log.routeCard.intent,
                source: log.routeSource,
                minimumConfidence: max(0.1, log.confidence - 0.04),
                learnedBindingRequired: !privacy.isRedacted && log.learnedBindingID != nil,
                titleContains: log.routeCard.title,
                surfaceContains: privacy.isRedacted ? nil : log.routeCard.surface,
                evidenceContains: [],
                action: privacy.isRedacted ? nil : actionExpectation(for: log.action),
                plan: privacy.isRedacted ? nil : planExpectation(for: log),
                targetGuard: privacy.isRedacted ? nil : targetGuardExpectation(for: log)
            )
        )
    }

    private static func preferredAction(for log: DispatchLogEntry) -> CommandAction? {
        switch log.routeSource {
        case .cloudAction, .localFallback, .explicitAction:
            return log.action
        case .cloudClassifier, .correction, .deterministicLocal, .learnedBinding, nil:
            return nil
        }
    }

    private static func preferredSource(for log: DispatchLogEntry) -> DispatchRouteSource {
        switch log.routeSource {
        case .cloudAction, .localFallback, .explicitAction:
            return log.routeSource ?? .cloudAction
        default:
            return .cloudAction
        }
    }

    private static func learnedBinding(for log: DispatchLogEntry) -> DispatchLearningBinding? {
        guard log.learnedBindingID != nil, let action = log.action else { return nil }
        return DispatchLearningBinding(
            id: log.learnedBindingID ?? log.id,
            commandPattern: log.commandPattern,
            commandTokens: DispatchLearningStore.commandTokens(for: log.command),
            surface: log.surface,
            routeCard: log.routeCard,
            action: action,
            confidence: max(log.confidence, 0.72),
            successCount: log.resultSuccess ? 1 : 2,
            failureCount: log.resultSuccess ? 0 : 0,
            createdAt: log.timestamp,
            lastUpdatedAt: log.timestamp
        )
    }

    private static func actionExpectation(for action: CommandAction?) -> DispatchActionExpectation? {
        guard let action else { return DispatchActionExpectation.none }
        switch action {
        case .typeText(_, let appHint):
            return .typeText(appHint: appHint)
        case .openURL(let url):
            let host = URL(string: url)?.host(percentEncoded: false) ?? url
            return .openURL(requiredFragments: [host])
        case .openApp(let name):
            return .openApp(name: name)
        case .searchWorkspace(let query):
            return .searchWorkspace(requiredFragments: Array(DispatchLearningStore.commandTokens(for: query).prefix(2)))
        case .speakAnswer:
            return .speakAnswer
        case .createTicket(_, _, let service):
            return .createTicket(service)
        case .postSlack(let channel, _):
            return .slack(channel: channel)
        case .delegateToAgent(let agent, _, _):
            return .agent(agent)
        case .composite(let actions):
            return .composite(count: actions.count)
        }
    }

    private static func planExpectation(for log: DispatchLogEntry) -> DispatchPlanExpectation? {
        guard let action = log.action else { return nil }
        let route = DispatchRouteResolution(
            card: log.routeCard,
            action: action,
            confidence: log.confidence,
            evidence: log.evidence,
            learnedBindingID: log.learnedBindingID,
            source: log.routeSource ?? .cloudAction,
            reason: log.routeReason ?? "Recorded route replay fixture."
        )
        let plan = DispatchPlanner.makePlan(
            command: log.command,
            route: route,
            action: action,
            contextPacket: nil,
            snapshots: []
        )
        return DispatchPlanExpectation(
            capabilityStatus: plan.capabilityStatus,
            executionStrategy: plan.executionStrategy,
            surfaceKind: plan.surfaceKind,
            fallback: plan.fallback,
            requiresAPI: plan.requiresAPI,
            requiresActiveTarget: plan.requiresActiveTarget
        )
    }

    private static func targetGuardExpectation(for log: DispatchLogEntry) -> DispatchTargetGuardExpectation? {
        guard log.failureStage == .targetGuard else { return nil }
        return DispatchTargetGuardExpectation(
            shouldAllow: false,
            summaryContains: log.targetCheck?.summary.map { String($0.prefix(40)) }
        )
    }

    private static func stableID(for log: DispatchLogEntry) -> String {
        let stem = [
            log.routeCard.id,
            log.failureStage?.rawValue ?? (log.resultSuccess ? "success" : "failure"),
            String(log.id.uuidString.prefix(8))
        ].joined(separator: "-")
        return stem
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
    }
}
