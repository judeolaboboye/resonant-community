import Foundation

enum DispatchTargetGuard {
    static let minimumAXTargetScore = 0.52

    enum Decision: Equatable {
        case allowed
        case blocked(String)
    }

    struct Evaluation: Equatable, Sendable {
        var allowed: Bool
        var check: DispatchTargetCheck
    }

    static func evaluate(
        action: CommandAction,
        binding: DispatchLearningBinding?,
        currentSurface: DispatchSurfaceFingerprint
    ) -> Evaluation {
        guard requiresStableFocusedTarget(action) else {
            return Evaluation(
                allowed: true,
                check: DispatchTargetCheck(
                    required: false,
                    expectedAXTarget: binding?.surface.hasAXTarget ?? false,
                    currentAXTarget: currentSurface.hasAXTarget,
                    matchScore: nil,
                    minimumScore: nil,
                    summary: "Action does not require a stable focused AX target."
                )
            )
        }

        if currentSurface.axIsSensitiveInput == true {
            let summary = "I won't type into a secure text field. Focus a normal text box and try again."
            return Evaluation(
                allowed: false,
                check: DispatchTargetCheck(
                    required: true,
                    expectedAXTarget: binding?.surface.hasAXTarget ?? false,
                    currentAXTarget: currentSurface.hasAXTarget,
                    matchScore: nil,
                    minimumScore: minimumAXTargetScore,
                    summary: summary
                )
            )
        }

        guard let binding, binding.surface.hasAXTarget else {
            return Evaluation(
                allowed: true,
                check: DispatchTargetCheck(
                    required: true,
                    expectedAXTarget: false,
                    currentAXTarget: currentSurface.hasAXTarget,
                    matchScore: nil,
                    minimumScore: minimumAXTargetScore,
                    summary: "No learned AX target is available to verify."
                )
            )
        }

        guard currentSurface.hasAXTarget else {
            let summary = "I can't verify the target text box. Focus it and say \"use this text box\"."
            return Evaluation(
                allowed: false,
                check: DispatchTargetCheck(
                    required: true,
                    expectedAXTarget: true,
                    currentAXTarget: false,
                    matchScore: nil,
                    minimumScore: minimumAXTargetScore,
                    summary: summary
                )
            )
        }

        let score = binding.surface.axTargetMatchScore(against: currentSurface)
        guard score >= minimumAXTargetScore else {
            let summary = "Target changed. Focus the intended text box and say \"use this text box\"."
            return Evaluation(
                allowed: false,
                check: DispatchTargetCheck(
                    required: true,
                    expectedAXTarget: true,
                    currentAXTarget: true,
                    matchScore: score,
                    minimumScore: minimumAXTargetScore,
                    summary: summary
                )
            )
        }

        return Evaluation(
            allowed: true,
            check: DispatchTargetCheck(
                required: true,
                expectedAXTarget: true,
                currentAXTarget: true,
                matchScore: score,
                minimumScore: minimumAXTargetScore,
                summary: "Target check passed."
            )
        )
    }

    static func decision(
        action: CommandAction,
        binding: DispatchLearningBinding?,
        currentSurface: DispatchSurfaceFingerprint
    ) -> Decision {
        let evaluation = evaluate(action: action, binding: binding, currentSurface: currentSurface)
        if evaluation.allowed {
            return .allowed
        }
        return .blocked(evaluation.check.summary ?? "Target guard blocked active-surface execution.")
    }

    static func requiresStableFocusedTarget(_ action: CommandAction) -> Bool {
        switch action {
        case .typeText, .postSlack:
            return true
        case .composite(let actions):
            return actions.contains { requiresStableFocusedTarget($0) }
        case .openURL, .openApp, .searchWorkspace, .speakAnswer, .createTicket, .delegateToAgent:
            return false
        }
    }
}
