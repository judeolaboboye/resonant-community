import Foundation
import SwiftData

enum DispatchCommandProgress: Sendable {
    case routeSelected(DispatchRouteResolution)
    case planSelected(DispatchPlan)
    case actionStarted(String)
    case result(String, success: Bool)
}

typealias DispatchCommandProgressHandler = @MainActor (DispatchCommandProgress) -> Void

struct DispatchNotificationHint: Codable, Equatable, Sendable {
    let appName: String
    let bundleId: String?
    let title: String?
    let body: String?
    let url: String?
    let receivedAt: Date

    var summary: String {
        [appName, title, body]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " | ")
    }
}

struct DispatchRouteSnapshot: Codable, Equatable, Sendable {
    let timestamp: Date
    let appName: String
    let bundleId: String
    let windowTitle: String?
    let browserURL: String?
    let codeFileName: String?
    let slackRecipient: String?
    let focusedFieldContent: String?
    let visibleTextSnippets: [String]
    let browserTabs: [String]
    let notificationHint: DispatchNotificationHint?

    init(
        timestamp: Date,
        appName: String,
        bundleId: String,
        windowTitle: String?,
        browserURL: String?,
        codeFileName: String?,
        slackRecipient: String?,
        focusedFieldContent: String?,
        visibleTextSnippets: [String],
        browserTabs: [String],
        notificationHint: DispatchNotificationHint? = nil
    ) {
        self.timestamp = timestamp
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.codeFileName = codeFileName
        self.slackRecipient = slackRecipient
        self.focusedFieldContent = focusedFieldContent
        self.visibleTextSnippets = visibleTextSnippets
        self.browserTabs = browserTabs
        self.notificationHint = notificationHint
    }
}

enum DispatchRouteIntent: String, Codable, Sendable, Equatable {
    case activeText = "Active text"
    case openURL = "Open URL"
    case openApp = "Open app"
    case workspaceSearch = "Workspace search"
    case spokenAnswer = "Voice answer"
    case ticketDraft = "Ticket draft"
    case slackDraft = "Slack"
    case agentDelegation = "Agent delegation"
    case composite = "Composite action"
    case cloudClassification = "Cloud classifier"
}

enum DispatchRouteDisturbance: String, Codable, Sendable, Equatable {
    case background = "background"
    case activeSurface = "active surface"
    case appSwitch = "app switch"
    case preparedOnly = "prepared"
}

struct DispatchRouteCard: Codable, Sendable, Equatable {
    let id: String
    let intent: DispatchRouteIntent
    let title: String
    let surface: String
    let action: String
    let validator: String
    let disturbance: DispatchRouteDisturbance
}

struct DispatchRouteResolution: Sendable {
    let card: DispatchRouteCard
    let action: CommandAction?
    let confidence: Double
    let evidence: [String]
    let learnedBindingID: UUID?
    let source: DispatchRouteSource
    let reason: String

    init(
        card: DispatchRouteCard,
        action: CommandAction?,
        confidence: Double,
        evidence: [String],
        learnedBindingID: UUID? = nil,
        source: DispatchRouteSource = .explicitAction,
        reason: String? = nil
    ) {
        self.card = card
        self.action = action
        self.confidence = confidence
        self.evidence = evidence
        self.learnedBindingID = learnedBindingID
        self.source = source
        self.reason = reason ?? evidence.first ?? card.validator
    }

    var routeLine: String {
        "\(card.title) (\(String(format: "%.0f", confidence * 100))%)"
    }

    var actionLine: String {
        card.action
    }

    func applying(learnedBinding: DispatchLearningBinding) -> DispatchRouteResolution {
        DispatchRouteResolution(
            card: card,
            action: action,
            confidence: max(confidence, learnedBinding.confidence),
            evidence: [
                "Learned local binding matched \(learnedBinding.successCount) successful run(s)."
            ] + evidence,
            learnedBindingID: learnedBinding.id,
            source: .learnedBinding,
            reason: "A learned local binding matched this command and the current surface."
        )
    }
}

@MainActor
struct DispatchRouteResolver {
    private let dataStore: DataStore
    private let learningStore: DispatchLearningStore?

    init(dataStore: DataStore, learningStore: DispatchLearningStore? = nil) {
        self.dataStore = dataStore
        self.learningStore = learningStore
    }

    func resolve(
        command: String,
        contextPacket: ContextPacket?,
        preferredAction: CommandAction? = nil,
        preferredSource: DispatchRouteSource = .cloudAction,
        preferredReason: String? = nil
    ) async -> DispatchRouteResolution {
        let snapshots = await recentSnapshots()
        return await resolve(
            command: command,
            contextPacket: contextPacket,
            preferredAction: preferredAction,
            preferredSource: preferredSource,
            preferredReason: preferredReason,
            snapshots: snapshots
        )
    }

    func recentSnapshots() async -> [DispatchRouteSnapshot] {
        let cutoff = Date().addingTimeInterval(-90 * 60)
        var descriptor = FetchDescriptor<AmbientContextSnapshot>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 80

        return await dataStore.fetchMappedInBackground(descriptor) { snapshot in
            DispatchRouteSnapshot(
                timestamp: snapshot.timestamp,
                appName: snapshot.appName,
                bundleId: snapshot.bundleId,
                windowTitle: snapshot.windowTitle,
                browserURL: snapshot.browserURL,
                codeFileName: snapshot.codeFileName,
                slackRecipient: snapshot.slackRecipient,
                focusedFieldContent: snapshot.focusedFieldContent,
                visibleTextSnippets: snapshot.visibleTextSnippets,
                browserTabs: snapshot.browserTabs,
                notificationHint: Self.notificationHint(from: snapshot)
            )
        }
    }

    private nonisolated static func notificationHint(from snapshot: AmbientContextSnapshot) -> DispatchNotificationHint? {
        guard let appName = nonEmpty(snapshot.notificationAppName),
              nonEmpty(snapshot.notificationTitle) != nil || nonEmpty(snapshot.notificationBody) != nil else {
            return nil
        }
        return DispatchNotificationHint(
            appName: appName,
            bundleId: nonEmpty(snapshot.notificationBundleId),
            title: nonEmpty(snapshot.notificationTitle),
            body: nonEmpty(snapshot.notificationBody),
            url: nonEmpty(snapshot.notificationURL),
            receivedAt: snapshot.notificationReceivedAt ?? snapshot.timestamp
        )
    }

    func resolve(
        command: String,
        contextPacket: ContextPacket?,
        preferredAction: CommandAction? = nil,
        preferredSource: DispatchRouteSource = .cloudAction,
        preferredReason: String? = nil,
        snapshots: [DispatchRouteSnapshot]
    ) async -> DispatchRouteResolution {
        let learnedBinding = preferredAction == nil
            ? learningStore?.bestBinding(command: command, contextPacket: contextPacket, snapshots: snapshots)
            : nil
        let ambientMemoryProfile = preferredAction == nil
            ? learningStore.map {
                DispatchAmbientMemoryProfile.build(
                    contextPacket: contextPacket,
                    snapshots: snapshots,
                    logs: $0.recentLogs(limit: 100)
                )
            }
            : nil
        return await Self.resolve(
            command: command,
            contextPacket: contextPacket,
            preferredAction: preferredAction,
            preferredSource: preferredSource,
            preferredReason: preferredReason,
            snapshots: snapshots,
            learnedBinding: learnedBinding,
            ambientMemoryProfile: ambientMemoryProfile
        )
    }

    nonisolated static func resolve(
        command: String,
        contextPacket: ContextPacket?,
        preferredAction: CommandAction? = nil,
        preferredSource: DispatchRouteSource = .cloudAction,
        preferredReason: String? = nil,
        snapshots: [DispatchRouteSnapshot],
        learnedBinding: DispatchLearningBinding? = nil,
        ambientMemoryProfile: DispatchAmbientMemoryProfile? = nil
    ) async -> DispatchRouteResolution {
        if let action = preferredAction {
            return await resolution(
                for: action,
                command: command,
                contextPacket: contextPacket,
                snapshots: snapshots,
                source: preferredSource,
                reason: preferredReason ?? "A structured action was selected by \(preferredSource.rawValue)."
            )
        }

        if let action = DispatchLocalActionResolver.deterministicAction(for: command) {
            return await resolution(
                for: action,
                command: command,
                contextPacket: contextPacket,
                snapshots: snapshots,
                source: .deterministicLocal,
                reason: "The command matched a deterministic local dispatch rule."
            )
        }

        if let inferred = DispatchIntentInference.infer(
            command: command,
            contextPacket: contextPacket,
            snapshots: snapshots,
            ambientMemoryProfile: ambientMemoryProfile
        ) {
            let route = await resolution(
                for: inferred.action,
                command: command,
                contextPacket: contextPacket,
                snapshots: snapshots,
                source: .deterministicLocal,
                reason: inferred.reason
            )
            return DispatchRouteResolution(
                card: route.card,
                action: route.action,
                confidence: max(route.confidence, inferred.confidence),
                evidence: (inferred.evidence + route.evidence).uniquePreservingOrder(),
                learnedBindingID: route.learnedBindingID,
                source: route.source,
                reason: inferred.reason
            )
        }

        if let learnedBinding, let action = learnedBinding.action {
            let route = await resolution(
                for: action,
                command: command,
                contextPacket: contextPacket,
                snapshots: snapshots,
                source: .learnedBinding,
                reason: "A learned binding was available for this command and surface."
            )
            return route.applying(learnedBinding: learnedBinding)
        }

        if let action = DispatchLocalActionResolver.fallbackAction(for: command) {
            return await resolution(
                for: action,
                command: command,
                contextPacket: contextPacket,
                snapshots: snapshots,
                source: .deterministicLocal,
                reason: "The command matched a deterministic local dispatch rule."
            )
        }

        return DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "cloud.classifier",
                intent: .cloudClassification,
                title: "Cloud action classifier",
                surface: contextSurfaceLabel(contextPacket) ?? "Current context",
                action: "Infer structured action",
                validator: "JSON action parsed",
                disturbance: .background
            ),
            action: nil,
            confidence: 0.45,
            evidence: evidenceForCurrentContext(contextPacket, snapshots: snapshots),
            source: .cloudClassifier,
            reason: "No learned binding or deterministic local rule matched, so cloud classification is required."
        )
    }

    private nonisolated static func resolution(
        for action: CommandAction,
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot],
        source: DispatchRouteSource,
        reason: String
    ) async -> DispatchRouteResolution {
        switch action {
        case .delegateToAgent(let agent, _, let explicitContext):
            let plan = DelegationWorkflowResolver.resolve(
                agent: agent,
                prompt: command,
                explicitContext: explicitContext,
                snapshots: snapshots.map(DelegationWorkflowResolver.Snapshot.init)
            )
            return DispatchRouteResolution(
                card: DispatchRouteCard(
                    id: "agent.\(agent.rawValue).\(plan.surface.rawValue)",
                    intent: .agentDelegation,
                    title: "\(agent.displayName) via \(plan.surface.rawValue)",
                    surface: plan.surface.rawValue,
                    action: "Prepare agent task",
                    validator: "Agent prompt prepared with local context",
                    disturbance: plan.surface == .currentContext ? .activeSurface : .preparedOnly
                ),
                action: action,
                confidence: max(0.45, plan.confidence),
                evidence: plan.evidence,
                source: source,
                reason: reason
            )

        default:
            let card = card(for: action, contextPacket: contextPacket, snapshots: snapshots)
            return DispatchRouteResolution(
                card: card,
                action: action,
                confidence: confidence(for: action, contextPacket: contextPacket, snapshots: snapshots),
                evidence: evidence(for: action, contextPacket: contextPacket, snapshots: snapshots),
                source: source,
                reason: reason
            )
        }
    }

    private nonisolated static func card(
        for action: CommandAction,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchRouteCard {
        switch action {
        case .typeText(_, let appHint):
            let surface = appHint ?? contextSurfaceLabel(contextPacket) ?? recentSurfaceLabel(snapshots) ?? "Active app"
            return DispatchRouteCard(
                id: "active.text",
                intent: .activeText,
                title: "Active text field",
                surface: surface,
                action: "Insert text into focused field",
                validator: "PasteManager delivery succeeded",
                disturbance: .activeSurface
            )

        case .openURL(let url):
            return DispatchRouteCard(
                id: "browser.open",
                intent: .openURL,
                title: browserRouteTitle(for: url),
                surface: URL(string: url)?.host(percentEncoded: false) ?? "Default browser",
                action: "Open URL",
                validator: "Workspace accepted URL open request",
                disturbance: .appSwitch
            )

        case .openApp(let name):
            return DispatchRouteCard(
                id: "app.open.\(name.lowercased())",
                intent: .openApp,
                title: "App switch",
                surface: name,
                action: "Activate or launch app",
                validator: "macOS open request succeeded",
                disturbance: .appSwitch
            )

        case .searchWorkspace(let query):
            return DispatchRouteCard(
                id: "workspace.search",
                intent: .workspaceSearch,
                title: "Local workspace index",
                surface: "Resonant memory",
                action: "Search local dictations, memos, meetings, and ambient context",
                validator: "Search returned result set for \(query)",
                disturbance: .background
            )

        case .speakAnswer:
            return DispatchRouteCard(
                id: "voice.answer",
                intent: .spokenAnswer,
                title: "Voice answer",
                surface: "Local TTS",
                action: "Speak answer",
                validator: "TTS playback completed",
                disturbance: .background
            )

        case .createTicket(_, _, let service):
            return DispatchRouteCard(
                id: "ticket.\(service.rawValue)",
                intent: .ticketDraft,
                title: "\(service.displayName) ticket draft",
                surface: service.displayName,
                action: "Prepare ticket payload",
                validator: "Ticket title/body prepared",
                disturbance: .preparedOnly
            )

        case .postSlack(let channel, _):
            let surface = slackSurfaceLabel(snapshots) ?? "#\(channel)"
            return DispatchRouteCard(
                id: "slack.post",
                intent: .slackDraft,
                title: "Slack route",
                surface: surface,
                action: "Prepare or type Slack message",
                validator: "Slack payload prepared or active field delivery succeeded",
                disturbance: .activeSurface
            )

        case .delegateToAgent:
            return DispatchRouteCard(
                id: "agent.generic",
                intent: .agentDelegation,
                title: "Agent route",
                surface: "Local context",
                action: "Prepare agent task",
                validator: "Agent prompt prepared with local context",
                disturbance: .preparedOnly
            )

        case .composite:
            return DispatchRouteCard(
                id: "composite",
                intent: .composite,
                title: "Composite route",
                surface: "Multiple surfaces",
                action: "Run multiple actions",
                validator: "Each action reports success",
                disturbance: .activeSurface
            )
        }
    }

    private nonisolated static func confidence(
        for action: CommandAction,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> Double {
        switch action {
        case .typeText:
            return contextPacket?.surface.fieldKind == .unknown ? 0.62 : 0.78
        case .openURL, .openApp, .searchWorkspace, .speakAnswer:
            return 0.9
        case .createTicket:
            return 0.72
        case .postSlack:
            return slackSurfaceLabel(snapshots) != nil ? 0.82 : 0.62
        case .delegateToAgent:
            return 0.55
        case .composite:
            return 0.68
        }
    }

    private nonisolated static func evidence(
        for action: CommandAction,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> [String] {
        var lines = evidenceForCurrentContext(contextPacket, snapshots: snapshots)
        switch action {
        case .typeText:
            lines.insert("Route uses the active focused text surface.", at: 0)
        case .openURL:
            lines.insert("URL open route is deterministic.", at: 0)
        case .openApp:
            lines.insert("App route uses macOS activation/open APIs.", at: 0)
        case .searchWorkspace:
            lines.insert("Workspace route stays local to Resonant memory.", at: 0)
        case .speakAnswer:
            lines.insert("Voice route stays local to TTS playback.", at: 0)
        case .createTicket:
            lines.insert("Ticket route is prepared locally until service credentials are connected.", at: 0)
        case .postSlack:
            lines.insert("Slack route uses active Slack if present, otherwise prepares a draft.", at: 0)
        case .delegateToAgent:
            lines.insert("Agent route uses recent local workflow evidence.", at: 0)
        case .composite:
            lines.insert("Composite route executes child routes sequentially.", at: 0)
        }
        return Array(lines.prefix(6))
    }

    private nonisolated static func evidenceForCurrentContext(
        _ contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> [String] {
        var lines: [String] = []
        if let contextPacket {
            let surface = DispatchAppSurfaceResolver.resolve(
                appName: contextPacket.surface.appName,
                bundleID: contextPacket.surface.bundleId,
                browserTitle: contextPacket.surface.windowTitle,
                browserURL: contextPacket.surface.browserURL
            )
            if surface.isKnownApp {
                lines.append("Current surface app: \(surface.label) (\(surface.variant.rawValue))")
            }
            if let app = contextPacket.surface.appName {
                lines.append("Current app: \(app)")
            }
            if let window = contextPacket.surface.windowTitle {
                lines.append("Window: \(window)")
            }
            if let url = contextPacket.surface.browserURL {
                lines.append("URL: \(url)")
            }
            lines.append("Surface: \(contextPacket.surface.kind.rawValue)")
        }
        if let snapshot = snapshots.first {
            let surface = surface(for: snapshot)
            if surface.isKnownApp {
                lines.append("Recent surface app: \(surface.label) (\(surface.variant.rawValue))")
            }
            lines.append("Recent app: \(snapshot.appName)")
            if let title = snapshot.windowTitle, !title.isEmpty {
                lines.append("Recent window: \(title)")
            }
            if let url = snapshot.browserURL, !url.isEmpty {
                lines.append("Recent URL: \(url)")
            }
        }
        if lines.isEmpty {
            lines.append("No recent local context evidence available.")
        }
        return lines
    }

    private nonisolated static func contextSurfaceLabel(_ contextPacket: ContextPacket?) -> String? {
        guard let surface = contextPacket?.surface else { return nil }
        return [
            surface.appName,
            surface.siteHost,
            surface.windowTitle,
            surface.conversationLabel,
            surface.documentLabel,
            surface.projectLabel
        ]
        .compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        .first
    }

    private nonisolated static func recentSurfaceLabel(_ snapshots: [DispatchRouteSnapshot]) -> String? {
        guard let snapshot = snapshots.first else { return nil }
        if let host = host(from: snapshot.browserURL) {
            return host
        }
        if let title = snapshot.windowTitle, !title.isEmpty {
            return "\(snapshot.appName): \(title)"
        }
        return snapshot.appName
    }

    private nonisolated static func slackSurfaceLabel(_ snapshots: [DispatchRouteSnapshot]) -> String? {
        for snapshot in snapshots.prefix(20) {
            let surface = surface(for: snapshot)
            if surface.kind == .slack {
                return snapshot.slackRecipient ?? snapshot.windowTitle ?? "Slack"
            }
        }
        return nil
    }

    private nonisolated static func surface(for snapshot: DispatchRouteSnapshot) -> DispatchAppSurface {
        DispatchAppSurfaceResolver.resolve(
            appName: snapshot.appName,
            bundleID: snapshot.bundleId,
            browserTitle: snapshot.windowTitle,
            browserURL: snapshot.browserURL
        )
    }

    private nonisolated static func browserRouteTitle(for url: String) -> String {
        let normalized = url.lowercased()
        if normalized.contains("google.com/search") && normalized.contains("weather") {
            return "Google weather"
        }
        return "Browser route"
    }

    private nonisolated static func host(from urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString),
              let host = url.host(percentEncoded: false) else {
            return nil
        }
        return host.lowercased()
    }

    private nonisolated static func searchableText(for snapshot: DispatchRouteSnapshot) -> String {
        ([
            snapshot.appName,
            snapshot.bundleId,
            snapshot.windowTitle,
            snapshot.browserURL,
            snapshot.codeFileName,
            snapshot.slackRecipient,
            snapshot.focusedFieldContent,
            snapshot.notificationHint?.summary,
            snapshot.notificationHint?.url
        ] + snapshot.visibleTextSnippets + snapshot.browserTabs)
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private extension CommandAction.AgentTarget {
    var displayName: String {
        switch self {
        case .devin: "Devin"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        }
    }
}

private extension CommandAction.TicketService {
    var displayName: String {
        switch self {
        case .linear: "Linear"
        case .github: "GitHub"
        }
    }
}

private extension DelegationWorkflowResolver.Snapshot {
    init(_ snapshot: DispatchRouteSnapshot) {
        self.init(
            timestamp: snapshot.timestamp,
            appName: snapshot.appName,
            bundleId: snapshot.bundleId,
            windowTitle: snapshot.windowTitle,
            browserURL: snapshot.browserURL,
            codeFileName: snapshot.codeFileName,
            focusedFieldContent: snapshot.focusedFieldContent,
            visibleTextSnippets: snapshot.visibleTextSnippets,
            browserTabs: snapshot.browserTabs
        )
    }
}

private extension Array where Element == String {
    func uniquePreservingOrder() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
