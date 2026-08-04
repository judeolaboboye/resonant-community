import Foundation

struct DispatchCommandPresentationState {
    private let heardText: String
    private(set) var routeLine: String?
    private(set) var actionLine: String?
    private(set) var routeReason: String?
    private(set) var planLine: String?

    init(heardText: String) {
        self.heardText = heardText
    }

    mutating func status(after progress: DispatchCommandProgress) -> String {
        switch progress {
        case .routeSelected(let route):
            routeLine = route.routeLine
            actionLine = route.actionLine
            routeReason = route.reason
            return progressStatus()

        case .planSelected(let plan):
            planLine = plan.planLine
            actionLine = plan.executionStrategy == .clarification
                ? "Clarify target"
                : plan.executionStrategy.rawValue
            routeReason = plan.capabilitySummary ?? plan.evidence.first
            return progressStatus()

        case .actionStarted(let action):
            actionLine = action
            return progressStatus()

        case .result(let result, _):
            return resultStatus(result)
        }
    }

    func initialStatus(action: String = "Resolving route") -> String {
        progressStatus(actionOverride: action)
    }

    func resultStatus(_ result: String) -> String {
        let firstLine = actionLine.map { "Action: \(Self.compact($0, limit: 42))" } ?? "Dispatch"
        let secondLine = "Result: \(Self.compact(result, limit: 42))"
        return "\(firstLine)\n\(secondLine)"
    }

    static func followUpCommandText(parentCommand: String, followUpText: String) -> String {
        let parent = compact(parentCommand, limit: 120)
        return "Follow-up to previous Dispatch command \"\(parent)\": \(followUpText)"
    }

    private func progressStatus(actionOverride: String? = nil) -> String {
        let firstLine = planLine.map { "Plan: \(Self.compact($0, limit: 42))" }
            ?? routeLine.map { "Route: \(Self.compact($0, limit: 42))" }
            ?? "Heard: \(Self.compact(heardText, limit: 42))"
        let action = actionOverride ?? actionLine ?? "Resolving route"
        guard let routeReason, !routeReason.isEmpty else {
            let secondLine = "Action: \(Self.compact(action, limit: 42))"
            return "\(firstLine)\n\(secondLine)"
        }
        let secondLine = "Action: \(Self.compact(action, limit: 24)) | Why: \(Self.compact(routeReason, limit: 30))"
        return "\(firstLine)\n\(secondLine)"
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(1, limit - 3))) + "..."
    }
}
