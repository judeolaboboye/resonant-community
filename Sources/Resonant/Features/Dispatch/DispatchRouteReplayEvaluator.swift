import Foundation

struct DispatchRouteReplayScenario: Codable, Sendable {
    var id: String
    var name: String
    var command: String
    var contextPacket: ContextPacket?
    var snapshots: [DispatchRouteSnapshot]
    var learnedBinding: DispatchLearningBinding?
    var preferredAction: CommandAction?
    var preferredSource: DispatchRouteSource
    var preferredReason: String?
    var expectation: DispatchRouteExpectation

    init(
        id: String,
        name: String,
        command: String,
        contextPacket: ContextPacket? = nil,
        snapshots: [DispatchRouteSnapshot] = [],
        learnedBinding: DispatchLearningBinding? = nil,
        preferredAction: CommandAction? = nil,
        preferredSource: DispatchRouteSource = .cloudAction,
        preferredReason: String? = nil,
        expectation: DispatchRouteExpectation
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.contextPacket = contextPacket
        self.snapshots = snapshots
        self.learnedBinding = learnedBinding
        self.preferredAction = preferredAction
        self.preferredSource = preferredSource
        self.preferredReason = preferredReason
        self.expectation = expectation
    }
}

struct DispatchRouteExpectation: Codable, Sendable {
    var routeID: String?
    var intent: DispatchRouteIntent?
    var source: DispatchRouteSource?
    var minimumConfidence: Double?
    var learnedBindingRequired: Bool
    var titleContains: String?
    var surfaceContains: String?
    var evidenceContains: [String]
    var action: DispatchActionExpectation?
    var plan: DispatchPlanExpectation?
    var targetGuard: DispatchTargetGuardExpectation?

    init(
        routeID: String? = nil,
        intent: DispatchRouteIntent? = nil,
        source: DispatchRouteSource? = nil,
        minimumConfidence: Double? = nil,
        learnedBindingRequired: Bool = false,
        titleContains: String? = nil,
        surfaceContains: String? = nil,
        evidenceContains: [String] = [],
        action: DispatchActionExpectation? = nil,
        plan: DispatchPlanExpectation? = nil,
        targetGuard: DispatchTargetGuardExpectation? = nil
    ) {
        self.routeID = routeID
        self.intent = intent
        self.source = source
        self.minimumConfidence = minimumConfidence
        self.learnedBindingRequired = learnedBindingRequired
        self.titleContains = titleContains
        self.surfaceContains = surfaceContains
        self.evidenceContains = evidenceContains
        self.action = action
        self.plan = plan
        self.targetGuard = targetGuard
    }
}

struct DispatchPlanExpectation: Codable, Sendable {
    var capabilityStatus: DispatchCapabilityStatus?
    var executionStrategy: DispatchExecutionStrategy?
    var surfaceKind: DispatchAppSurfaceKind?
    var fallback: String?
    var requiresAPI: Bool?
    var requiresActiveTarget: Bool?
}

enum DispatchActionExpectation: Codable, Sendable {
    case none
    case openURL(requiredFragments: [String])
    case openApp(name: String)
    case agent(CommandAction.AgentTarget)
    case slack(channel: String?)
    case typeText(appHint: String?)
    case searchWorkspace(requiredFragments: [String])
    case speakAnswer
    case createTicket(CommandAction.TicketService)
    case composite(count: Int?)
}

struct DispatchTargetGuardExpectation: Codable, Sendable {
    var contextPacket: ContextPacket?
    var snapshots: [DispatchRouteSnapshot]
    var shouldAllow: Bool
    var summaryContains: String?

    init(
        contextPacket: ContextPacket? = nil,
        snapshots: [DispatchRouteSnapshot] = [],
        shouldAllow: Bool,
        summaryContains: String? = nil
    ) {
        self.contextPacket = contextPacket
        self.snapshots = snapshots
        self.shouldAllow = shouldAllow
        self.summaryContains = summaryContains
    }
}

struct DispatchRouteReplayResult: Sendable {
    var scenarioID: String
    var scenarioName: String
    var route: DispatchRouteResolution
    var failures: [String]

    var passed: Bool {
        failures.isEmpty
    }
}

@MainActor
enum DispatchRouteReplayEvaluator {
    static func evaluate(_ scenarios: [DispatchRouteReplayScenario]) async -> [DispatchRouteReplayResult] {
        var results: [DispatchRouteReplayResult] = []
        for scenario in scenarios {
            results.append(await evaluate(scenario))
        }
        return results
    }

    static func evaluate(_ scenario: DispatchRouteReplayScenario) async -> DispatchRouteReplayResult {
        let route = await DispatchRouteResolver.resolve(
            command: scenario.command,
            contextPacket: scenario.contextPacket,
            preferredAction: scenario.preferredAction,
            preferredSource: scenario.preferredSource,
            preferredReason: scenario.preferredReason,
            snapshots: scenario.snapshots,
            learnedBinding: scenario.learnedBinding
        )
        return DispatchRouteReplayResult(
            scenarioID: scenario.id,
            scenarioName: scenario.name,
            route: route,
            failures: failures(for: route, scenario: scenario)
        )
    }

    private static func failures(
        for route: DispatchRouteResolution,
        scenario: DispatchRouteReplayScenario
    ) -> [String] {
        let expectation = scenario.expectation
        var failures: [String] = []

        if let routeID = expectation.routeID, route.card.id != routeID {
            failures.append("Expected route id \(routeID), got \(route.card.id).")
        }
        if let intent = expectation.intent, route.card.intent != intent {
            failures.append("Expected intent \(intent.rawValue), got \(route.card.intent.rawValue).")
        }
        if let source = expectation.source, route.source != source {
            failures.append("Expected source \(source.rawValue), got \(route.source.rawValue).")
        }
        if let minimumConfidence = expectation.minimumConfidence, route.confidence < minimumConfidence {
            failures.append("Expected confidence >= \(minimumConfidence), got \(route.confidence).")
        }
        if expectation.learnedBindingRequired, route.learnedBindingID == nil {
            failures.append("Expected route to use a learned binding.")
        }
        if let title = expectation.titleContains, !contains(route.card.title, title) {
            failures.append("Expected title to contain \(title), got \(route.card.title).")
        }
        if let surface = expectation.surfaceContains, !contains(route.card.surface, surface) {
            failures.append("Expected surface to contain \(surface), got \(route.card.surface).")
        }
        for evidence in expectation.evidenceContains {
            let matched = route.evidence.contains { contains($0, evidence) }
            if !matched {
                failures.append("Expected evidence containing \(evidence), got \(route.evidence).")
            }
        }
        if let actionExpectation = expectation.action {
            failures.append(contentsOf: actionFailures(for: route.action, expectation: actionExpectation))
        }
        if let planExpectation = expectation.plan {
            failures.append(contentsOf: planFailures(
                for: route,
                scenario: scenario,
                expectation: planExpectation
            ))
        }
        if let guardExpectation = expectation.targetGuard {
            failures.append(contentsOf: targetGuardFailures(
                route: route,
                scenario: scenario,
                expectation: guardExpectation
            ))
        }

        return failures.map { "[\(scenario.id)] \($0)" }
    }

    private static func planFailures(
        for route: DispatchRouteResolution,
        scenario: DispatchRouteReplayScenario,
        expectation: DispatchPlanExpectation
    ) -> [String] {
        guard let action = route.action else {
            return ["Expected plan evaluation, but route has no action."]
        }
        let plan = DispatchPlanner.makePlan(
            command: scenario.command,
            route: route,
            action: action,
            contextPacket: scenario.contextPacket,
            snapshots: scenario.snapshots
        )

        var failures: [String] = []
        if let capabilityStatus = expectation.capabilityStatus, plan.capabilityStatus != capabilityStatus {
            failures.append("Expected capability status \(capabilityStatus.rawValue), got \(plan.capabilityStatus.rawValue).")
        }
        if let executionStrategy = expectation.executionStrategy, plan.executionStrategy != executionStrategy {
            failures.append("Expected execution strategy \(executionStrategy.rawValue), got \(plan.executionStrategy.rawValue).")
        }
        if let surfaceKind = expectation.surfaceKind, plan.surfaceKind != surfaceKind {
            failures.append("Expected surface kind \(surfaceKind.rawValue), got \(plan.surfaceKind?.rawValue ?? "nil").")
        }
        if let fallback = expectation.fallback, plan.fallback != fallback {
            failures.append("Expected fallback \(fallback), got \(plan.fallback ?? "nil").")
        }
        if let requiresAPI = expectation.requiresAPI, plan.requiresAPI != requiresAPI {
            failures.append("Expected requiresAPI \(requiresAPI), got \(plan.requiresAPI).")
        }
        if let requiresActiveTarget = expectation.requiresActiveTarget, plan.requiresActiveTarget != requiresActiveTarget {
            failures.append("Expected requiresActiveTarget \(requiresActiveTarget), got \(plan.requiresActiveTarget).")
        }
        return failures
    }

    private static func actionFailures(
        for action: CommandAction?,
        expectation: DispatchActionExpectation
    ) -> [String] {
        switch expectation {
        case .none:
            return action == nil ? [] : ["Expected no action, got \(actionLabel(action))."]

        case .openURL(let requiredFragments):
            guard case .openURL(let url)? = action else {
                return ["Expected openURL action, got \(actionLabel(action))."]
            }
            return requiredFragments
                .filter { !url.contains($0) }
                .map { "Expected URL to contain \($0), got \(url)." }

        case .openApp(let name):
            guard case .openApp(let actual)? = action else {
                return ["Expected openApp action, got \(actionLabel(action))."]
            }
            return contains(actual, name) ? [] : ["Expected app \(name), got \(actual)."]

        case .agent(let agent):
            guard case .delegateToAgent(let actual, _, _)? = action else {
                return ["Expected agent delegation action, got \(actionLabel(action))."]
            }
            return actual.rawValue == agent.rawValue ? [] : ["Expected agent \(agent.rawValue), got \(actual.rawValue)."]

        case .slack(let channel):
            guard case .postSlack(let actual, _)? = action else {
                return ["Expected Slack action, got \(actionLabel(action))."]
            }
            guard let channel else { return [] }
            return contains(actual, channel) ? [] : ["Expected Slack channel \(channel), got \(actual)."]

        case .typeText(let appHint):
            guard case .typeText(_, let actualHint)? = action else {
                return ["Expected typeText action, got \(actionLabel(action))."]
            }
            guard let appHint else { return [] }
            return contains(actualHint ?? "", appHint) ? [] : ["Expected app hint \(appHint), got \(actualHint ?? "nil")."]

        case .searchWorkspace(let requiredFragments):
            guard case .searchWorkspace(let query)? = action else {
                return ["Expected workspace search action, got \(actionLabel(action))."]
            }
            return requiredFragments
                .filter { !contains(query, $0) }
                .map { "Expected workspace query to contain \($0), got \(query)." }

        case .speakAnswer:
            guard case .speakAnswer? = action else {
                return ["Expected speakAnswer action, got \(actionLabel(action))."]
            }
            return []

        case .createTicket(let service):
            guard case .createTicket(_, _, let actual)? = action else {
                return ["Expected createTicket action, got \(actionLabel(action))."]
            }
            return actual.rawValue == service.rawValue ? [] : ["Expected ticket service \(service.rawValue), got \(actual.rawValue)."]

        case .composite(let count):
            guard case .composite(let actions)? = action else {
                return ["Expected composite action, got \(actionLabel(action))."]
            }
            guard let count else { return [] }
            return actions.count == count ? [] : ["Expected \(count) composite actions, got \(actions.count)."]
        }
    }

    private static func targetGuardFailures(
        route: DispatchRouteResolution,
        scenario: DispatchRouteReplayScenario,
        expectation: DispatchTargetGuardExpectation
    ) -> [String] {
        guard let action = route.action else {
            return ["Expected target guard evaluation, but route has no action."]
        }

        let contextPacket = expectation.contextPacket ?? scenario.contextPacket
        let snapshots = expectation.snapshots.isEmpty ? scenario.snapshots : expectation.snapshots
        let currentSurface = DispatchLearningStore.surfaceFingerprint(
            contextPacket: contextPacket,
            snapshots: snapshots
        )
        let evaluation = DispatchTargetGuard.evaluate(
            action: action,
            binding: scenario.learnedBinding,
            currentSurface: currentSurface
        )

        var failures: [String] = []
        if evaluation.allowed != expectation.shouldAllow {
            failures.append("Expected target guard allowed=\(expectation.shouldAllow), got \(evaluation.allowed).")
        }
        if let summary = expectation.summaryContains,
           !contains(evaluation.check.summary ?? "", summary) {
            failures.append("Expected target guard summary to contain \(summary), got \(evaluation.check.summary ?? "nil").")
        }
        return failures
    }

    private static func contains(_ value: String, _ fragment: String) -> Bool {
        value.range(of: fragment, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func actionLabel(_ action: CommandAction?) -> String {
        guard let action else { return "nil" }
        switch action {
        case .typeText:
            return "typeText"
        case .openURL:
            return "openURL"
        case .openApp:
            return "openApp"
        case .searchWorkspace:
            return "searchWorkspace"
        case .speakAnswer:
            return "speakAnswer"
        case .createTicket:
            return "createTicket"
        case .postSlack:
            return "postSlack"
        case .delegateToAgent:
            return "delegateToAgent"
        case .composite:
            return "composite"
        }
    }
}
