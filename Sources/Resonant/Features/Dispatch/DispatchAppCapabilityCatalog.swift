import Foundation

struct DispatchCapabilityDecision: Sendable, Equatable {
    var targetSurface: String?
    var surfaceKind: DispatchAppSurfaceKind?
    var surfaceVariant: DispatchAppSurfaceVariant?
    var executionStrategy: DispatchExecutionStrategy?
    var verificationStrategy: DispatchVerificationStrategy?
    var repairStrategy: DispatchRepairStrategy?
    var requiresAPI: Bool
    var requiresActiveTarget: Bool
    var fallback: String?
    var confidenceCap: Double
    var evidence: [String]
}

enum DispatchAppCapabilityCatalog {
    struct MatrixEntry: Sendable, Equatable {
        var app: DispatchAppSurfaceKind
        var operation: String
        var localCapability: DispatchCapabilityStatus
        var preferredStrategy: DispatchExecutionStrategy
        var verificationStrategy: DispatchVerificationStrategy
        var requiresAPI: Bool
        var requiresActiveTarget: Bool
        var fallback: String?
        var notes: String
    }

    static let matrix: [MatrixEntry] = [
        MatrixEntry(
            app: .slack,
            operation: "post_message",
            localCapability: .degraded,
            preferredStrategy: .clipboardDraft,
            verificationStrategy: .clipboardPayload,
            requiresAPI: true,
            requiresActiveTarget: false,
            fallback: "clipboard draft",
            notes: "Can type into an active Slack compose/reply target; direct channel posting needs Slack API auth."
        ),
        MatrixEntry(
            app: .slack,
            operation: "active_reply",
            localCapability: .available,
            preferredStrategy: .localUIAutomation,
            verificationStrategy: .focusedFieldReadback,
            requiresAPI: false,
            requiresActiveTarget: true,
            fallback: "clipboard fallback if Slack field verification fails",
            notes: "Requires current AX target on Slack native or Slack web."
        ),
        MatrixEntry(
            app: .discord,
            operation: "active_reply",
            localCapability: .available,
            preferredStrategy: .localUIAutomation,
            verificationStrategy: .focusedFieldReadback,
            requiresAPI: false,
            requiresActiveTarget: true,
            fallback: nil,
            notes: "Requires current AX target on Discord native or web."
        ),
        MatrixEntry(
            app: .linear,
            operation: "create_ticket",
            localCapability: .degraded,
            preferredStrategy: .clipboardDraft,
            verificationStrategy: .clipboardPayload,
            requiresAPI: true,
            requiresActiveTarget: false,
            fallback: "clipboard ticket draft",
            notes: "Direct issue creation requires Linear API auth; local fallback opens Linear and copies title/body."
        ),
        MatrixEntry(
            app: .github,
            operation: "create_issue",
            localCapability: .degraded,
            preferredStrategy: .clipboardDraft,
            verificationStrategy: .clipboardPayload,
            requiresAPI: true,
            requiresActiveTarget: false,
            fallback: "clipboard ticket draft",
            notes: "Direct issue creation requires GitHub API auth; local fallback opens GitHub issues and copies title/body."
        ),
        MatrixEntry(
            app: .devin,
            operation: "delegate_task",
            localCapability: .degraded,
            preferredStrategy: .agentHandoff,
            verificationStrategy: .clipboardPayload,
            requiresAPI: true,
            requiresActiveTarget: false,
            fallback: "clipboard agent handoff",
            notes: "Direct session creation requires Devin API auth; local fallback opens Devin and copies task context."
        ),
        MatrixEntry(
            app: .browser,
            operation: "open_url",
            localCapability: .available,
            preferredStrategy: .deepLink,
            verificationStrategy: .browserURLReadback,
            requiresAPI: false,
            requiresActiveTarget: false,
            fallback: nil,
            notes: "URL open can be verified by browser URL readback when browser URL access is available."
        )
    ]

    static func matrixPayload(app filter: DispatchAppSurfaceKind? = nil) -> JSONValue {
        let entries = matrix
            .filter { entry in filter.map { $0 == entry.app } ?? true }
            .map { entry -> JSONValue in
                .object([
                    "app": .string(entry.app.rawValue),
                    "operation": .string(entry.operation),
                    "local_capability": .string(entry.localCapability.rawValue),
                    "preferred_strategy": .string(entry.preferredStrategy.rawValue),
                    "verification_strategy": .string(entry.verificationStrategy.rawValue),
                    "requires_api": .bool(entry.requiresAPI),
                    "requires_active_target": .bool(entry.requiresActiveTarget),
                    "fallback": entry.fallback.map { .string($0) } ?? .null,
                    "notes": .string(entry.notes)
                ])
            }
        return .object([
            "entries": .array(entries),
            "count": .int(entries.count),
            "status_values": .array([
                .string(DispatchCapabilityStatus.available.rawValue),
                .string(DispatchCapabilityStatus.degraded.rawValue),
                .string(DispatchCapabilityStatus.blocked.rawValue)
            ])
        ])
    }

    static func decision(
        action: CommandAction,
        route: DispatchRouteResolution,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchCapabilityDecision {
        let surface = mostRelevantSurface(action: action, route: route, contextPacket: contextPacket, snapshots: snapshots)
        var decision = DispatchCapabilityDecision(
            targetSurface: surface?.label,
            surfaceKind: surface?.kind,
            surfaceVariant: surface?.variant,
            executionStrategy: nil,
            verificationStrategy: nil,
            repairStrategy: nil,
            requiresAPI: false,
            requiresActiveTarget: false,
            fallback: nil,
            confidenceCap: 1,
            evidence: []
        )

        if let surface {
            decision.evidence.append("Capability surface: \(surface.label) \(surface.variant.rawValue).")
        } else {
            decision.evidence.append("Capability surface: no known app-specific surface.")
        }

        switch action {
        case .postSlack:
            let activeSlack = surface?.kind == .slack && contextPacket?.targetFingerprint != nil
            decision.surfaceKind = .slack
            decision.surfaceVariant = surface?.kind == .slack ? surface?.variant : nil
            decision.targetSurface = surface?.kind == .slack ? surface?.label : "Slack"
            decision.requiresAPI = true
            decision.requiresActiveTarget = activeSlack
            decision.verificationStrategy = activeSlack ? .focusedFieldReadback : .clipboardPayload
            decision.executionStrategy = activeSlack ? .localUIAutomation : .clipboardDraft
            decision.repairStrategy = activeSlack ? .prepareClipboardFallback : .noAutomaticRepair
            decision.fallback = activeSlack ? "clipboard fallback if Slack field verification fails" : "clipboard draft"
            decision.confidenceCap = activeSlack ? 1 : 0.72
            decision.evidence.append(
                activeSlack
                    ? "Slack compose/reply target is active; direct API posting is unavailable, so local UI automation is allowed."
                    : "Direct Slack posting requires an API token; no verified Slack compose target, so prepare a clipboard draft."
            )

        case .createTicket(_, _, let service):
            decision.requiresAPI = true
            decision.executionStrategy = .clipboardDraft
            decision.verificationStrategy = .clipboardPayload
            decision.repairStrategy = .prepareClipboardFallback
            decision.fallback = "clipboard ticket draft"
            decision.confidenceCap = 0.82
            switch service {
            case .linear:
                decision.surfaceKind = .linear
                decision.targetSurface = surface?.kind == .linear ? surface?.label : "Linear"
                decision.evidence.append("Direct Linear issue creation requires API access; using clipboard ticket draft.")
            case .github:
                decision.surfaceKind = .github
                decision.targetSurface = surface?.kind == .github ? surface?.label : "GitHub"
                decision.evidence.append("Direct GitHub issue creation requires API access; using clipboard ticket draft.")
            }

        case .delegateToAgent(let agent, _, _):
            switch agent {
            case .devin:
                decision.requiresAPI = true
                decision.executionStrategy = .agentHandoff
                decision.verificationStrategy = .clipboardPayload
                decision.repairStrategy = .prepareClipboardFallback
                decision.fallback = "clipboard agent handoff"
                decision.confidenceCap = 0.82
                decision.surfaceKind = .devin
                decision.targetSurface = surface?.kind == .devin ? surface?.label : "Devin"
                decision.evidence.append("Direct Devin session creation requires API access; using clipboard handoff.")
            case .claudeCode, .cursor:
                decision.executionStrategy = .agentHandoff
                decision.verificationStrategy = .clipboardPayload
                decision.repairStrategy = .prepareClipboardFallback
                decision.fallback = "clipboard agent handoff"
                decision.evidence.append("Local agent handoff is clipboard-based unless a dedicated integration is present.")
            }

        case .typeText:
            if let surface, [.slack, .discord, .linear, .github, .devin].contains(surface.kind) {
                decision.requiresActiveTarget = true
                decision.executionStrategy = contextPacket?.targetFingerprint == nil ? nil : .localUIAutomation
                decision.evidence.append("App-specific typing requires an active AX text target on \(surface.label).")
            }

        case .openURL:
            decision.executionStrategy = .deepLink
            decision.verificationStrategy = .browserURLReadback
            decision.repairStrategy = .retryTargetedSurface
            decision.evidence.append("URL actions can be verified by active browser URL readback.")

        case .openApp:
            decision.executionStrategy = .appLaunch
            decision.verificationStrategy = .foregroundAppReadback
            decision.repairStrategy = .retryTargetedSurface
            decision.evidence.append("App launch can be verified by foreground app/surface readback.")

        case .searchWorkspace, .speakAnswer, .composite:
            decision.evidence.append("No app-specific capability constraint applies.")
        }

        return decision
    }

    private static func mostRelevantSurface(
        action: CommandAction,
        route: DispatchRouteResolution,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchAppSurface? {
        let preferredKind = preferredKind(action: action, route: route)
        let candidates = surfaceCandidates(contextPacket: contextPacket, snapshots: snapshots)
        if let preferredKind,
           let exact = candidates.first(where: { $0.kind == preferredKind }) {
            return exact
        }
        if let known = candidates.first(where: { $0.isKnownApp }) {
            return known
        }
        return candidates.first
    }

    private static func surfaceCandidates(
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> [DispatchAppSurface] {
        var surfaces: [DispatchAppSurface] = []
        if let contextPacket {
            surfaces.append(
                DispatchAppSurfaceResolver.resolve(
                    appName: contextPacket.surface.appName,
                    bundleID: contextPacket.surface.bundleId,
                    browserTitle: contextPacket.surface.windowTitle,
                    browserURL: contextPacket.surface.browserURL
                )
            )
        }
        surfaces += snapshots.prefix(6).flatMap { snapshot -> [DispatchAppSurface] in
            var snapshotSurfaces = [
                DispatchAppSurfaceResolver.resolve(
                    appName: snapshot.appName,
                    bundleID: snapshot.bundleId,
                    browserTitle: snapshot.windowTitle,
                    browserURL: snapshot.browserURL
                )
            ]
            if let notification = snapshot.notificationHint {
                snapshotSurfaces.append(
                    DispatchAppSurfaceResolver.resolve(
                        appName: notification.appName,
                        bundleID: notification.bundleId,
                        browserTitle: notification.title,
                        browserURL: notification.url
                    )
                )
            }
            return snapshotSurfaces
        }
        return surfaces
    }

    private static func preferredKind(action: CommandAction, route: DispatchRouteResolution) -> DispatchAppSurfaceKind? {
        switch action {
        case .postSlack:
            .slack
        case .createTicket(_, _, let service):
            service == .linear ? .linear : .github
        case .delegateToAgent(let agent, _, _):
            agent == .devin ? .devin : nil
        case .openApp(let name):
            DispatchAppSurfaceResolver.kindMentioned(in: name)
        case .typeText(_, let appHint):
            appHint.flatMap(DispatchAppSurfaceResolver.kindMentioned)
        case .openURL, .searchWorkspace, .speakAnswer, .composite:
            DispatchAppSurfaceResolver.kindMentioned(in: route.card.surface)
        }
    }
}
