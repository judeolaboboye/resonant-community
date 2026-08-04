import Foundation

enum DispatchCapabilityDiagnosisKind: String, Codable, Sendable, Equatable {
    case missingIntegration = "missing_integration"
    case missingActiveTarget = "missing_active_target"
    case routeMismatch = "route_mismatch"
    case targetGuardBlocked = "target_guard_blocked"
    case executionFailed = "execution_failed"
    case verificationFailed = "verification_failed"
    case cloudUnavailable = "cloud_unavailable"
    case needsClarification = "needs_clarification"
    case latencyRisk = "latency_risk"
    case succeeded = "succeeded"
    case unknown = "unknown"
}

struct DispatchCapabilityDiagnosis: Codable, Sendable, Equatable {
    var kind: DispatchCapabilityDiagnosisKind
    var severity: Int
    var title: String
    var nextAction: String
    var evidence: [String]

    var payload: JSONValue {
        .object([
            "kind": .string(kind.rawValue),
            "severity": .int(severity),
            "title": .string(title),
            "next_action": .string(nextAction),
            "evidence": .array(evidence.map { .string($0) })
        ])
    }
}

enum DispatchCapabilityDiagnoser {
    static func diagnose(trace events: [DispatchTraceEvent]) -> DispatchCapabilityDiagnosis {
        let events = events.sorted { $0.timestamp < $1.timestamp }
        let metadata = mergedMetadata(events)
        let stages = Set(events.map(\.stage))
        let final = events.last { $0.stage == .commandFinished }

        if final?.success == true {
            return DispatchCapabilityDiagnosis(
                kind: .succeeded,
                severity: 0,
                title: "Command completed and verified.",
                nextAction: "Keep this scenario in the passing replay set.",
                evidence: compactEvidence([
                    metadata["capability_status"].map { "capability_status=\($0)" },
                    final?.summary
                ])
            )
        }

        if metadata["requires_clarification"] == "true" {
            return DispatchCapabilityDiagnosis(
                kind: .needsClarification,
                severity: 4,
                title: "Dispatch could not choose a safe target.",
                nextAction: "Ask for the target explicitly or improve ambient context so the target surface is unambiguous.",
                evidence: compactEvidence([
                    metadata["clarification_prompt"],
                    metadata["surface_app"].map { "surface_app=\($0)" },
                    metadata["confidence"].map { "confidence=\($0)" }
                ])
            )
        }

        if stages.contains(.targetGuardBlocked) || final?.failureStage == DispatchFailureStage.targetGuard.rawValue {
            return DispatchCapabilityDiagnosis(
                kind: .targetGuardBlocked,
                severity: 5,
                title: "Dispatch blocked execution because the active target did not match.",
                nextAction: "Improve surface matching or require an explicit confirmation before executing this command.",
                evidence: compactEvidence([
                    metadata["target_guard_summary"],
                    metadata["match_score"].map { "match_score=\($0)" },
                    metadata["minimum_score"].map { "minimum_score=\($0)" }
                ])
            )
        }

        if metadata["capability_requires_active_target"] == "true",
           metadata["ax_target"] != "available" {
            return DispatchCapabilityDiagnosis(
                kind: .missingActiveTarget,
                severity: 5,
                title: "The command needs an active AX target, but none was captured.",
                nextAction: "Capture focused-field AX context before routing, or degrade to a clipboard draft instead of typing.",
                evidence: compactEvidence([
                    metadata["surface_app"].map { "surface_app=\($0)" },
                    metadata["surface_variant"].map { "surface_variant=\($0)" },
                    metadata["capability_requires_active_target"].map { "requires_active_target=\($0)" }
                ])
            )
        }

        if metadata["capability_requires_api"] == "true" {
            return DispatchCapabilityDiagnosis(
                kind: .missingIntegration,
                severity: 3,
                title: "A real app API is needed for native completion.",
                nextAction: "Add the app integration or keep the command explicitly labeled as a local clipboard fallback.",
                evidence: compactEvidence([
                    metadata["surface_app"].map { "surface_app=\($0)" },
                    metadata["capability_fallback"].map { "fallback=\($0)" },
                    metadata["execution_strategy"].map { "execution_strategy=\($0)" }
                ])
            )
        }

        if final?.failureStage == DispatchFailureStage.cloudClassification.rawValue || stages.contains(.cloudClassificationFailed) {
            return DispatchCapabilityDiagnosis(
                kind: .cloudUnavailable,
                severity: 4,
                title: "Cloud classification failed or timed out.",
                nextAction: "Prefer a deterministic local route for this command or shorten the fallback timeout.",
                evidence: compactEvidence([
                    final?.summary,
                    metadata["route_source"].map { "route_source=\($0)" }
                ])
            )
        }

        if final?.failureStage == DispatchFailureStage.verification.rawValue || events.contains(where: { $0.stage == .verificationFinished && $0.success == false }) {
            return DispatchCapabilityDiagnosis(
                kind: .verificationFailed,
                severity: 4,
                title: "The action ran, but verification did not prove success.",
                nextAction: "Tighten the verifier or add a bounded repair for this action type.",
                evidence: compactEvidence([
                    events.last(where: { $0.stage == .verificationFinished })?.summary,
                    final?.summary,
                    metadata["verification_strategy"].map { "verification_strategy=\($0)" }
                ])
            )
        }

        if final?.failureStage == DispatchFailureStage.actionExecution.rawValue {
            return DispatchCapabilityDiagnosis(
                kind: .executionFailed,
                severity: 5,
                title: "Dispatch selected an action but execution failed.",
                nextAction: "Inspect executor logs for this action and add a visible failure response instead of returning to listening.",
                evidence: compactEvidence([
                    final?.summary,
                    metadata["execution_strategy"].map { "execution_strategy=\($0)" }
                ])
            )
        }

        if events.contains(where: { $0.stage == .noLocalMatch }) {
            return DispatchCapabilityDiagnosis(
                kind: .routeMismatch,
                severity: 4,
                title: "No deterministic local route matched the command.",
                nextAction: "Add a route fixture and replay expectation for this command family.",
                evidence: compactEvidence([
                    final?.summary,
                    metadata["route_source"].map { "route_source=\($0)" }
                ])
            )
        }

        return DispatchCapabilityDiagnosis(
            kind: .unknown,
            severity: 2,
            title: "The trace did not contain enough information to diagnose the failure.",
            nextAction: "Add a trace event at the point where the command returns to listening.",
            evidence: compactEvidence([final?.summary])
        )
    }

    private static func mergedMetadata(_ events: [DispatchTraceEvent]) -> [String: String] {
        events.reduce(into: [:]) { result, event in
            if let routeSource = event.routeSource {
                result["route_source"] = routeSource
            }
            for (key, value) in event.metadata {
                result[key] = value
            }
        }
    }

    private static func compactEvidence(_ values: [String?]) -> [String] {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }
}
