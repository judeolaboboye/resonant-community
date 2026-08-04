import Foundation

enum DispatchExecutionStrategy: String, Codable, Sendable, Equatable {
    case localUIAutomation = "local_ui_automation"
    case appLaunch = "app_launch"
    case deepLink = "deep_link"
    case clipboardDraft = "clipboard_draft"
    case localSearch = "local_search"
    case voiceResponse = "voice_response"
    case agentHandoff = "agent_handoff"
    case composite = "composite"
    case clarification = "clarification"
}

enum DispatchVerificationStrategy: String, Codable, Sendable, Equatable {
    case focusedFieldReadback = "focused_field_readback"
    case foregroundAppReadback = "foreground_app_readback"
    case browserURLReadback = "browser_url_readback"
    case clipboardPayload = "clipboard_payload"
    case commandResult = "command_result"
    case composite = "composite"
}

enum DispatchRepairStrategy: String, Codable, Sendable, Equatable {
    case retryTargetedSurface = "retry_targeted_surface"
    case askUserToConfirmSurface = "ask_user_to_confirm_surface"
    case prepareClipboardFallback = "prepare_clipboard_fallback"
    case noAutomaticRepair = "no_automatic_repair"
}

enum DispatchCapabilityStatus: String, Codable, Sendable, Equatable {
    case available
    case degraded
    case blocked
}

struct DispatchPlan: Codable, Sendable, Equatable {
    var objective: String
    var targetSurface: String
    var surfaceKind: DispatchAppSurfaceKind?
    var surfaceVariant: DispatchAppSurfaceVariant?
    var executionStrategy: DispatchExecutionStrategy
    var verificationStrategy: DispatchVerificationStrategy
    var repairStrategy: DispatchRepairStrategy
    var requiresAPI: Bool
    var requiresActiveTarget: Bool
    var fallback: String?
    var confidence: Double
    var requiresClarification: Bool
    var clarificationPrompt: String?
    var evidence: [String]

    var planLine: String {
        "\(objective) via \(executionStrategy.rawValue)"
    }

    var capabilityStatus: DispatchCapabilityStatus {
        if requiresClarification || executionStrategy == .clarification {
            return .blocked
        }
        if requiresAPI || fallback != nil {
            return .degraded
        }
        return .available
    }

    var capabilitySummary: String? {
        if capabilityStatus == .blocked {
            return clarificationPrompt ?? "Blocked until target is clarified."
        }
        if requiresAPI, let fallback {
            return "API needed; using \(fallback)."
        }
        if requiresActiveTarget {
            return "Requires active \(targetSurface) target."
        }
        if let fallback {
            return "Fallback: \(fallback)."
        }
        return nil
    }

    init(
        objective: String,
        targetSurface: String,
        surfaceKind: DispatchAppSurfaceKind? = nil,
        surfaceVariant: DispatchAppSurfaceVariant? = nil,
        executionStrategy: DispatchExecutionStrategy,
        verificationStrategy: DispatchVerificationStrategy,
        repairStrategy: DispatchRepairStrategy,
        requiresAPI: Bool = false,
        requiresActiveTarget: Bool = false,
        fallback: String? = nil,
        confidence: Double,
        requiresClarification: Bool,
        clarificationPrompt: String? = nil,
        evidence: [String]
    ) {
        self.objective = objective
        self.targetSurface = targetSurface
        self.surfaceKind = surfaceKind
        self.surfaceVariant = surfaceVariant
        self.executionStrategy = executionStrategy
        self.verificationStrategy = verificationStrategy
        self.repairStrategy = repairStrategy
        self.requiresAPI = requiresAPI
        self.requiresActiveTarget = requiresActiveTarget
        self.fallback = fallback
        self.confidence = confidence
        self.requiresClarification = requiresClarification
        self.clarificationPrompt = clarificationPrompt
        self.evidence = evidence
    }
}

enum DispatchPlanner {
    static func makePlan(
        command: String,
        route: DispatchRouteResolution,
        action: CommandAction,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchPlan {
        let capability = DispatchAppCapabilityCatalog.decision(
            action: action,
            route: route,
            contextPacket: contextPacket,
            snapshots: snapshots
        )
        let targetSurface = capability.targetSurface
            ?? inferredTargetSurface(route: route, contextPacket: contextPacket, snapshots: snapshots)
        let executionStrategy = capability.executionStrategy ?? executionStrategy(for: action, route: route)
        let verificationStrategy = capability.verificationStrategy ?? verificationStrategy(for: action)
        let repairStrategy = capability.repairStrategy ?? repairStrategy(for: action, route: route, contextPacket: contextPacket)
        let risk = riskAssessment(action: action, route: route, contextPacket: contextPacket)
        let confidence = min(route.confidence, risk.confidenceCap, capability.confidenceCap)
        let requiresClarification = risk.requiresClarification
        return DispatchPlan(
            objective: objective(for: action, command: command),
            targetSurface: targetSurface,
            surfaceKind: capability.surfaceKind,
            surfaceVariant: capability.surfaceVariant,
            executionStrategy: requiresClarification ? .clarification : executionStrategy,
            verificationStrategy: verificationStrategy,
            repairStrategy: requiresClarification ? .askUserToConfirmSurface : repairStrategy,
            requiresAPI: capability.requiresAPI,
            requiresActiveTarget: capability.requiresActiveTarget,
            fallback: capability.fallback,
            confidence: confidence,
            requiresClarification: requiresClarification,
            clarificationPrompt: requiresClarification ? risk.prompt : nil,
            evidence: (capability.evidence + risk.evidence + Array(route.evidence.prefix(4))).uniquePreservingOrder()
        )
    }

    private static func objective(for action: CommandAction, command: String) -> String {
        switch action {
        case .typeText:
            "Insert dictated text"
        case .openURL:
            "Open a browser target"
        case .openApp(let name):
            "Open \(name)"
        case .searchWorkspace:
            "Search local workspace memory"
        case .speakAnswer:
            "Speak a response"
        case .createTicket(_, _, let service):
            "Prepare a \(service.rawValue) ticket"
        case .postSlack:
            "Send or prepare a Slack message"
        case .delegateToAgent(let agent, _, _):
            "Prepare a task for \(agent.rawValue)"
        case .composite:
            "Run a multi-step command"
        }
    }

    private static func inferredTargetSurface(
        route: DispatchRouteResolution,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> String {
        if route.card.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return route.card.surface
        }
        if let surface = contextPacket?.surface.appName {
            return surface
        }
        if let snapshot = snapshots.first {
            return snapshot.appName
        }
        return "Current context"
    }

    private static func executionStrategy(for action: CommandAction, route: DispatchRouteResolution) -> DispatchExecutionStrategy {
        switch action {
        case .typeText, .postSlack:
            route.card.disturbance == .preparedOnly ? .clipboardDraft : .localUIAutomation
        case .openApp:
            .appLaunch
        case .openURL:
            .deepLink
        case .searchWorkspace:
            .localSearch
        case .speakAnswer:
            .voiceResponse
        case .createTicket:
            .clipboardDraft
        case .delegateToAgent:
            .agentHandoff
        case .composite:
            .composite
        }
    }

    private static func verificationStrategy(for action: CommandAction) -> DispatchVerificationStrategy {
        switch action {
        case .typeText, .postSlack:
            .focusedFieldReadback
        case .openApp:
            .foregroundAppReadback
        case .openURL:
            .browserURLReadback
        case .createTicket, .delegateToAgent:
            .clipboardPayload
        case .searchWorkspace, .speakAnswer:
            .commandResult
        case .composite:
            .composite
        }
    }

    private static func repairStrategy(
        for action: CommandAction,
        route: DispatchRouteResolution,
        contextPacket: ContextPacket?
    ) -> DispatchRepairStrategy {
        switch action {
        case .typeText, .postSlack:
            contextPacket?.targetFingerprint == nil ? .askUserToConfirmSurface : .retryTargetedSurface
        case .createTicket, .delegateToAgent:
            .prepareClipboardFallback
        case .openApp, .openURL:
            .retryTargetedSurface
        case .searchWorkspace, .speakAnswer, .composite:
            .noAutomaticRepair
        }
    }

    private static func riskAssessment(
        action: CommandAction,
        route: DispatchRouteResolution,
        contextPacket: ContextPacket?
    ) -> (requiresClarification: Bool, confidenceCap: Double, prompt: String?, evidence: [String]) {
        switch action {
        case .typeText:
            guard route.card.disturbance == .activeSurface else {
                return (false, 1, nil, ["Planner: text action is not active-surface risky."])
            }
            guard let contextPacket else {
                return (true, 0.48, "I need a focused text field before typing that. Put the cursor where it should go, then say it again.", ["Planner blocked typing because no current context packet was available."])
            }
            if contextPacket.targetFingerprint == nil && route.confidence < 0.78 {
                return (true, 0.58, "I am not confident which field to type into. Say \"yes here\" with the cursor in the right box.", ["Planner blocked typing because target confidence was low and no AX target fingerprint was available."])
            }
            if contextPacket.targetFingerprint?.isSensitiveInput == true {
                return (true, 0.2, "I can't type into a secure text field. Focus a normal text box and try again.", ["Planner blocked typing because the focused target is a secure text field."])
            }
            return (false, 1, nil, ["Planner allowed active text with current surface context."])

        case .postSlack:
            if route.card.disturbance == .activeSurface,
               contextPacket?.targetFingerprint?.isSensitiveInput == true {
                return (true, 0.2, "I can't type into a secure text field. Focus a normal text box and try again.", ["Planner blocked Slack typing because the focused target is a secure text field."])
            }
            let evidence = route.evidence.joined(separator: "\n").lowercased()
            let surface = route.card.surface.lowercased()
            if surface.contains("slack") || surface.hasPrefix("#") || evidence.contains("slack") {
                return (false, 1, nil, ["Planner found Slack surface evidence."])
            }
            return (false, 0.7, nil, ["Planner will use Slack clipboard/draft fallback if no active Slack surface is verified."])

        default:
            return (false, 1, nil, ["Planner found no pre-execution risk requiring clarification."])
        }
    }
}

private extension Array where Element == String {
    func uniquePreservingOrder() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
