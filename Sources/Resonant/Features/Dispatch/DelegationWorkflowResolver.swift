import Foundation
import SwiftData

/// Resolves broad "give this to an agent" commands into the local workflow the
/// user has recently used: web app, Conductor terminal, project/workspace, etc.
@MainActor
struct DelegationWorkflowResolver {

    struct Snapshot: Sendable {
        let timestamp: Date
        let appName: String
        let bundleId: String
        let windowTitle: String?
        let browserURL: String?
        let codeFileName: String?
        let focusedFieldContent: String?
        let visibleTextSnippets: [String]
        let browserTabs: [String]
    }

    struct Plan: Sendable {
        enum Surface: String, Sendable {
            case devinWeb = "Devin web app"
            case conductorTerminal = "Conductor terminal"
            case terminal = "Terminal"
            case currentContext = "Current context"
            case unresolved = "Unresolved"
        }

        let agent: CommandAction.AgentTarget
        let surface: Surface
        let projectHint: String?
        let workspacePath: String?
        let confidence: Double
        let evidence: [String]

        var summary: String {
            switch surface {
            case .devinWeb:
                return "Use recent Devin web context"
            case .conductorTerminal:
                return "Use recent Conductor terminal context"
            case .terminal:
                return "Use recent terminal context"
            case .currentContext:
                return "Use current local context"
            case .unresolved:
                return "No confident local agent workflow found"
            }
        }

        func detail(prompt: String, explicitContext: String?) -> String {
            var lines: [String] = [
                "Agent: \(agent.rawValue)",
                "Surface: \(surface.rawValue)",
                "Confidence: \(String(format: "%.2f", confidence))"
            ]
            if let projectHint, !projectHint.isEmpty {
                lines.append("Project: \(projectHint)")
            }
            if let workspacePath, !workspacePath.isEmpty {
                lines.append("Workspace: \(workspacePath)")
            }
            if let explicitContext, !explicitContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Explicit context: \(explicitContext)")
            }
            if !evidence.isEmpty {
                lines.append("Evidence:")
                lines.append(contentsOf: evidence.prefix(6).map { "- \($0)" })
            }
            lines.append("")
            lines.append("Task prompt:")
            lines.append(prompt)
            return lines.joined(separator: "\n")
        }
    }

    private let dataStore: DataStore

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    func resolve(
        agent: CommandAction.AgentTarget,
        prompt: String,
        explicitContext: String?
    ) async -> Plan {
        let snapshots = await recentSnapshots()
        return Self.resolve(
            agent: agent,
            prompt: prompt,
            explicitContext: explicitContext,
            snapshots: snapshots
        )
    }

    nonisolated static func resolve(
        agent: CommandAction.AgentTarget,
        prompt: String,
        explicitContext: String?,
        snapshots: [Snapshot]
    ) -> Plan {
        let scoredSnapshots = snapshots
            .map { snapshot in (snapshot, score(snapshot: snapshot, agent: agent)) }
            .filter { $0.1.score > 0 }
            .sorted { lhs, rhs in
                if lhs.1.score == rhs.1.score {
                    return lhs.0.timestamp > rhs.0.timestamp
                }
                return lhs.1.score > rhs.1.score
            }

        guard let best = scoredSnapshots.first else {
            return Plan(
                agent: agent,
                surface: .unresolved,
                projectHint: projectHint(from: explicitContext ?? prompt),
                workspacePath: workspacePath(from: explicitContext ?? prompt),
                confidence: 0.15,
                evidence: ["No recent matching local workflow evidence found."]
            )
        }

        let snapshot = best.0
        let confidence = min(best.1.score, 1.0)
        let surface = best.1.surface
        let text = searchableText(for: snapshot)
        let explicit = [explicitContext, prompt].compactMap { $0 }.joined(separator: "\n")
        let workspace = workspacePath(from: text) ?? workspacePath(from: explicit)
        let project = projectHint(from: text) ?? projectHint(from: explicit)
        let evidence = evidenceLines(for: snapshot, reasons: best.1.reasons)

        return Plan(
            agent: agent,
            surface: surface,
            projectHint: project,
            workspacePath: workspace,
            confidence: confidence,
            evidence: evidence
        )
    }

    private func recentSnapshots() async -> [Snapshot] {
        let cutoff = Date().addingTimeInterval(-90 * 60)
        var descriptor = FetchDescriptor<AmbientContextSnapshot>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 80

        return await dataStore.fetchMappedInBackground(descriptor) { snapshot in
            Snapshot(
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

    private nonisolated static func score(
        snapshot: Snapshot,
        agent: CommandAction.AgentTarget
    ) -> (score: Double, surface: Plan.Surface, reasons: [String]) {
        let text = searchableText(for: snapshot)
        let normalized = text.lowercased()
        var score = recencyScore(for: snapshot.timestamp)
        var reasons: [String] = []
        var surface: Plan.Surface = .currentContext

        switch agent {
        case .devin:
            if normalized.contains("devin") || normalized.contains("devon") {
                score += 0.35
                reasons.append("mentions Devin")
            }
            if let host = host(from: snapshot.browserURL), host.contains("devin") {
                score += 0.45
                surface = .devinWeb
                reasons.append("recent Devin browser URL")
            }
        case .claudeCode:
            if normalized.contains("claude") || normalized.contains("claude code") {
                score += 0.35
                reasons.append("mentions Claude Code")
            }
        case .cursor:
            if normalized.contains("cursor") {
                score += 0.35
                reasons.append("mentions Cursor")
            }
        }

        if normalized.contains("conductor") {
            score += 0.22
            surface = surface == .devinWeb ? surface : .conductorTerminal
            reasons.append("recent Conductor context")
        }
        if snapshot.bundleId.lowercased().contains("terminal")
            || snapshot.appName.lowercased().contains("terminal")
            || normalized.contains("terminal") {
            score += 0.16
            if surface == .currentContext {
                surface = .terminal
            }
            reasons.append("recent terminal context")
        }
        if workspacePath(from: text) != nil {
            score += 0.18
            reasons.append("contains Conductor workspace path")
        }
        if projectHint(from: text) != nil {
            score += 0.08
            reasons.append("contains project hint")
        }

        return (score, surface, reasons)
    }

    private nonisolated static func recencyScore(for date: Date) -> Double {
        let age = max(0, Date().timeIntervalSince(date))
        return max(0.05, 0.25 * (1 - min(age / (90 * 60), 1)))
    }

    private nonisolated static func evidenceLines(for snapshot: Snapshot, reasons: [String]) -> [String] {
        var lines: [String] = []
        if !reasons.isEmpty {
            lines.append("Matched: \(reasons.joined(separator: ", "))")
        }
        lines.append("App: \(snapshot.appName) (\(snapshot.bundleId))")
        if let title = snapshot.windowTitle, !title.isEmpty {
            lines.append("Window: \(title)")
        }
        if let url = snapshot.browserURL, !url.isEmpty {
            lines.append("URL: \(url)")
        }
        if let codeFile = snapshot.codeFileName, !codeFile.isEmpty {
            lines.append("Code file: \(codeFile)")
        }
        if let focused = snapshot.focusedFieldContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !focused.isEmpty {
            lines.append("Focused field preview: \(String(focused.prefix(160)))")
        }
        if let snippet = snapshot.visibleTextSnippets.first {
            lines.append("Visible text preview: \(String(snippet.prefix(160)))")
        }
        return lines
    }

    private nonisolated static func searchableText(for snapshot: Snapshot) -> String {
        ([
            snapshot.appName,
            snapshot.bundleId,
            snapshot.windowTitle,
            snapshot.browserURL,
            snapshot.codeFileName,
            snapshot.focusedFieldContent
        ] + snapshot.visibleTextSnippets + snapshot.browserTabs)
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private nonisolated static func host(from urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString),
              let host = url.host(percentEncoded: false) else {
            return nil
        }
        return host.lowercased()
    }

    private nonisolated static func workspacePath(from text: String) -> String? {
        let pattern = #"/Users/[^\s]+/conductor/workspaces/[^\s\"']+"#
        return firstMatch(pattern: pattern, in: text)
    }

    private nonisolated static func projectHint(from text: String) -> String? {
        if let workspace = workspacePath(from: text) {
            let parts = workspace.split(separator: "/").map(String.init)
            if let workspacesIndex = parts.lastIndex(of: "workspaces"),
               parts.indices.contains(workspacesIndex + 1) {
                return parts[workspacesIndex + 1]
            }
        }

        let patterns = [
            #"(?i)\b(?:repo|project|workspace)[:=]\s*([A-Za-z0-9._-]+)"#,
            #"(?i)\b([A-Za-z0-9._-]+)\s+(?:repo|workspace)"#
        ]
        for pattern in patterns {
            if let match = firstCapture(pattern: pattern, in: text) {
                return match
            }
        }
        return nil
    }

    private nonisolated static func firstMatch(pattern: String, in text: String) -> String? {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        return nsText.substring(with: match.range)
    }

    private nonisolated static func firstCapture(pattern: String, in text: String) -> String? {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }
}
