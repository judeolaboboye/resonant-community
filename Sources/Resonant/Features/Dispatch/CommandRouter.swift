import Foundation
import os

/// Orchestrates the voice command pipeline:
/// 1. Receives transcribed command text + context
/// 2. Sends to Convex cloud LLM for intent classification + action planning
/// 3. Dispatches the resulting `CommandAction` to `ActionExecutor`
/// 4. Returns feedback for the Notch + TTS
@MainActor
final class CommandRouter {

    private static let log = Logger.resonant("CommandRouter")

    let voiceFeedback = VoiceFeedback()

    private var actionExecutor: ActionExecutor?
    private var actionVerifier: DispatchActionVerifier?
    private var convexClient: ConvexClient?
    private var dataStore: DataStore?
    private var learningStore: DispatchLearningStore?
    private var traceStore = DispatchTraceStore()
    private var cancellationGeneration = 0

    private(set) var isProcessing = false
    var cloudFallbackEnabled = false

    func configure(
        pasteManager: PasteManager,
        dataStore: DataStore,
        convexClient: ConvexClient,
        learningStore: DispatchLearningStore? = nil,
        cloudFallbackEnabled: Bool = false
    ) {
        self.dataStore = dataStore
        self.convexClient = convexClient
        self.learningStore = learningStore
        self.cloudFallbackEnabled = cloudFallbackEnabled
        self.actionExecutor = ActionExecutor(
            pasteManager: pasteManager,
            dataStore: dataStore,
            voiceFeedback: voiceFeedback
        )
        self.actionVerifier = DispatchActionVerifier(pasteManager: pasteManager)
    }

    func cancelCurrentCommand() {
        cancellationGeneration += 1
        isProcessing = false
        actionExecutor?.cancel()
        voiceFeedback.stop()
    }

    /// Process a voice command from the user.
    /// Returns a `CommandResult` with feedback text and the action result.
    func processCommand(
        transcribedText: String,
        contextPacket: ContextPacket?,
        onProgress: DispatchCommandProgressHandler? = nil,
        testSnapshots: [DispatchRouteSnapshot]? = nil,
        forceCloudFallback: Bool? = nil
    ) async -> CommandResult {
        let generation = cancellationGeneration
        let effectiveCloudFallbackEnabled = forceCloudFallback ?? cloudFallbackEnabled
        guard !isProcessing else {
            return CommandResult(
                feedback: "Already processing a command.",
                actionResult: nil,
                shouldSpeak: true
            )
        }

        guard let convexClient, let actionExecutor, let actionVerifier, let dataStore else {
            Self.log.error("CommandRouter not configured")
            return CommandResult(
                feedback: "Command system not ready.",
                actionResult: nil,
                shouldSpeak: true
            )
        }

        let trimmed = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CommandResult(
                feedback: "I didn't hear a command.",
                actionResult: nil,
                shouldSpeak: true
            )
        }
        let traceID = traceStore.begin(command: trimmed, contextPacket: contextPacket)

        guard !isCancelled(generation: generation) else {
            return Self.cancelledResult()
        }

        isProcessing = true
        defer { isProcessing = false }

        if let correction = fastCorrection(command: trimmed, contextPacket: contextPacket) {
            let actionResult = correction.success
                ? CommandActionResult.ok(correction.feedback)
                : CommandActionResult.failed(correction.feedback)
            traceStore.append(
                traceID: traceID,
                command: trimmed,
                stage: .correctionApplied,
                success: correction.success,
                summary: correction.feedback,
                metadata: ["correction_kind": correction.kind.rawValue]
            )
            onProgress?(.result(correction.feedback, success: correction.success))
            return CommandResult(
                feedback: correction.feedback,
                actionResult: actionResult,
                shouldSpeak: true
            )
        }

        let fastRoute = await fastLocalResolution(command: trimmed, contextPacket: contextPacket)
        if let action = fastRoute.action, fastRoute.source == .deterministicLocal {
            guard !isCancelled(generation: generation) else {
                return Self.cancelledResult()
            }
            onProgress?(.routeSelected(fastRoute))
            traceStore.append(
                traceID: traceID,
                command: trimmed,
                stage: .routeSelected,
                route: fastRoute,
                action: action,
                summary: fastRoute.reason,
                metadata: routeMetadata(fastRoute, snapshotsCount: 0)
            )
            Self.log.info("Processing command with fast local route: \(fastRoute.card.id, privacy: .public)")
            return await executeResolvedAction(
                action,
                route: fastRoute,
                executor: actionExecutor,
                verifier: actionVerifier,
                command: trimmed,
                traceID: traceID,
                contextPacket: contextPacket,
                snapshots: [],
                generation: generation,
                onProgress: onProgress
            )
        }

        if !effectiveCloudFallbackEnabled, !shouldCheckAmbientRoute(command: trimmed) {
            return noLocalMatchResult(
                command: trimmed,
                contextPacket: contextPacket,
                snapshots: [],
                route: fastRoute,
                traceID: traceID,
                onProgress: onProgress
            )
        }

        let routeResolver = DispatchRouteResolver(dataStore: dataStore, learningStore: learningStore)
        let snapshots: [DispatchRouteSnapshot]
        if let testSnapshots {
            snapshots = testSnapshots
        } else {
            snapshots = await routeResolver.recentSnapshots()
        }
        guard !isCancelled(generation: generation) else {
            return Self.cancelledResult()
        }

        if let correction = learningStore?.applyCorrection(
            command: trimmed,
            contextPacket: contextPacket,
            snapshots: snapshots
        ) {
            let actionResult = correction.success
                ? CommandActionResult.ok(correction.feedback)
                : CommandActionResult.failed(correction.feedback)
            traceStore.append(
                traceID: traceID,
                command: trimmed,
                stage: .correctionApplied,
                success: correction.success,
                summary: correction.feedback,
                metadata: ["correction_kind": correction.kind.rawValue, "snapshots": "\(snapshots.count)"]
            )
            onProgress?(.result(correction.feedback, success: correction.success))
            return CommandResult(
                feedback: correction.feedback,
                actionResult: actionResult,
                shouldSpeak: true
            )
        }

        let initialRoute = await routeResolver.resolve(
            command: trimmed,
            contextPacket: contextPacket,
            snapshots: snapshots
        )
        guard !isCancelled(generation: generation) else {
            return Self.cancelledResult()
        }
        onProgress?(.routeSelected(initialRoute))
        traceStore.append(
            traceID: traceID,
            command: trimmed,
            stage: .routeSelected,
            route: initialRoute,
            action: initialRoute.action,
            summary: initialRoute.reason,
            metadata: routeMetadata(initialRoute, snapshotsCount: snapshots.count)
        )

        if let action = initialRoute.action {
            Self.log.info("Processing command with local route: \(initialRoute.card.id, privacy: .public)")
            return await executeResolvedAction(
                action,
                route: initialRoute,
                executor: actionExecutor,
                verifier: actionVerifier,
                command: trimmed,
                traceID: traceID,
                contextPacket: contextPacket,
                snapshots: snapshots,
                generation: generation,
                onProgress: onProgress
            )
        }

        guard effectiveCloudFallbackEnabled else {
            return noLocalMatchResult(
                command: trimmed,
                contextPacket: contextPacket,
                snapshots: snapshots,
                route: initialRoute,
                traceID: traceID,
                onProgress: onProgress
            )
        }

        Self.log.info("Processing command: \(trimmed, privacy: .public)")
        onProgress?(.actionStarted(initialRoute.actionLine))
        traceStore.append(
            traceID: traceID,
            command: trimmed,
            stage: .cloudClassificationStarted,
            route: initialRoute,
            summary: "Cloud fallback enabled; sending command classification prompt.",
            metadata: ["snapshots": "\(snapshots.count)"]
        )

        let prompt = DispatchCommandPromptBuilder.build(command: trimmed, context: contextPacket)

        // Send to Convex cloud LLM
        do {
            let response = try await sendToCloud(prompt: prompt, convexClient: convexClient)
            guard !isCancelled(generation: generation) else {
                return Self.cancelledResult()
            }
            let action = try DispatchCommandActionParser.parse(response)
            let route = await routeResolver.resolve(
                command: trimmed,
                contextPacket: contextPacket,
                preferredAction: action,
                preferredSource: .cloudAction,
                preferredReason: "The cloud classifier returned a structured action for this command.",
                snapshots: snapshots
            )
            guard !isCancelled(generation: generation) else {
                return Self.cancelledResult()
            }
            onProgress?(.routeSelected(route))
            traceStore.append(
                traceID: traceID,
                command: trimmed,
                stage: .routeSelected,
                route: route,
                action: action,
                summary: route.reason,
                metadata: routeMetadata(route, snapshotsCount: snapshots.count)
            )

            Self.log.info("Parsed action, executing...")
            return await executeResolvedAction(
                action,
                route: route,
                executor: actionExecutor,
                verifier: actionVerifier,
                command: trimmed,
                traceID: traceID,
                contextPacket: contextPacket,
                snapshots: snapshots,
                generation: generation,
                onProgress: onProgress
            )
        } catch {
            guard !isCancelled(generation: generation) else {
                return Self.cancelledResult()
            }
            Self.log.error("Command processing failed: \(error.localizedDescription, privacy: .public)")
            traceStore.append(
                traceID: traceID,
                command: trimmed,
                stage: .cloudClassificationFailed,
                route: initialRoute,
                success: false,
                failureStage: failureStage(for: error),
                summary: error.localizedDescription
            )
            if let action = DispatchLocalActionResolver.fallbackAction(for: trimmed) {
                Self.log.info("Cloud command failed; retrying with local fallback")
                let route = await routeResolver.resolve(
                    command: trimmed,
                    contextPacket: contextPacket,
                    preferredAction: action,
                    preferredSource: .localFallback,
                    preferredReason: "Cloud classification failed, then a deterministic local fallback matched this command.",
                    snapshots: snapshots
                )
                guard !isCancelled(generation: generation) else {
                    return Self.cancelledResult()
                }
                onProgress?(.routeSelected(route))
                traceStore.append(
                    traceID: traceID,
                    command: trimmed,
                    stage: .routeSelected,
                    route: route,
                    action: action,
                    summary: route.reason,
                    metadata: routeMetadata(route, snapshotsCount: snapshots.count)
                )
                return await executeResolvedAction(
                    action,
                    route: route,
                    executor: actionExecutor,
                    verifier: actionVerifier,
                    command: trimmed,
                    traceID: traceID,
                    contextPacket: contextPacket,
                    snapshots: snapshots,
                    generation: generation,
                    onProgress: onProgress
                )
            }
            learningStore?.recordOutcome(
                command: trimmed,
                contextPacket: contextPacket,
                snapshots: snapshots,
                route: initialRoute,
                result: .failed(error.localizedDescription),
                failureStage: failureStage(for: error)
            )
            traceStore.append(
                traceID: traceID,
                command: trimmed,
                stage: .learningRecorded,
                route: initialRoute,
                success: false,
                failureStage: failureStage(for: error),
                summary: error.localizedDescription,
                metadata: ["binding_update": "false"]
            )
            onProgress?(.result("Sorry, I couldn't process that command.", success: false))
            traceStore.append(
                traceID: traceID,
                command: trimmed,
                stage: .commandFinished,
                route: initialRoute,
                success: false,
                summary: "Sorry, I couldn't process that command."
            )
            return CommandResult(
                feedback: "Sorry, I couldn't process that command.",
                actionResult: .failed(error.localizedDescription),
                shouldSpeak: true
            )
        }
    }

    private func fastCorrection(
        command: String,
        contextPacket: ContextPacket?
    ) -> DispatchCorrectionResult? {
        guard DispatchLearningStore.correctionKind(for: command) != nil else { return nil }
        return learningStore?.applyCorrection(
            command: command,
            contextPacket: contextPacket,
            snapshots: []
        )
    }

    private func fastLocalResolution(
        command: String,
        contextPacket: ContextPacket?
    ) async -> DispatchRouteResolution {
        await DispatchRouteResolver.resolve(
            command: command,
            contextPacket: contextPacket,
            snapshots: [],
            learnedBinding: nil,
            ambientMemoryProfile: nil
        )
    }

    private func shouldCheckAmbientRoute(command: String) -> Bool {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        if normalized.contains("notification") || normalized.contains("reply to that") {
            return true
        }

        let ambientCues = [
            "this", "that", "it", "them", "here", "earlier", "last",
            "same", "usual", "clean", "cleanup", "fix", "handle",
            "reply", "respond", "tell", "message", "follow up"
        ]
        guard ambientCues.contains(where: normalized.contains) else {
            return false
        }

        return true
    }

    private func noLocalMatchResult(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot],
        route: DispatchRouteResolution,
        traceID: UUID,
        onProgress: DispatchCommandProgressHandler?
    ) -> CommandResult {
        let feedback = "No local Dispatch action matched."
        traceStore.append(
            traceID: traceID,
            command: command,
            stage: .noLocalMatch,
            route: route,
            success: false,
            failureStage: .localResolution,
            summary: feedback,
            metadata: ["snapshots": "\(snapshots.count)"]
        )
        learningStore?.recordOutcome(
            command: command,
            contextPacket: contextPacket,
            snapshots: snapshots,
            route: route,
            result: .failed(feedback),
            failureStage: .localResolution
        )
        traceStore.append(
            traceID: traceID,
            command: command,
            stage: .learningRecorded,
            route: route,
            success: false,
            failureStage: .localResolution,
            summary: feedback,
            metadata: ["binding_update": "false"]
        )
        onProgress?(.result(feedback, success: false))
        traceStore.append(
            traceID: traceID,
            command: command,
            stage: .commandFinished,
            route: route,
            success: false,
            failureStage: .localResolution,
            summary: feedback
        )
        return CommandResult(
            feedback: feedback,
            actionResult: .failed(feedback, detail: "Enable Dispatch cloud fallback for experimental commands that are not covered by local routes."),
            shouldSpeak: false
        )
    }

    private func executeResolvedAction(
        _ action: CommandAction,
        route: DispatchRouteResolution,
        executor: ActionExecutor,
        verifier: DispatchActionVerifier,
        command: String,
        traceID: UUID,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot],
        generation: Int,
        onProgress: DispatchCommandProgressHandler?
    ) async -> CommandResult {
        guard !isCancelled(generation: generation) else {
            return Self.cancelledResult()
        }
        let plan = DispatchPlanner.makePlan(
            command: command,
            route: route,
            action: action,
            contextPacket: contextPacket,
            snapshots: snapshots
        )
        onProgress?(.planSelected(plan))
        traceStore.append(
            traceID: traceID,
            command: command,
            stage: .planSelected,
            route: route,
            action: action,
            success: !plan.requiresClarification,
            failureStage: plan.requiresClarification ? .targetGuard : nil,
            summary: plan.planLine,
            metadata: plan.traceMetadata
        )
        if plan.requiresClarification {
            let feedback = plan.clarificationPrompt ?? "I need you to confirm the target before I do that."
            onProgress?(.result(feedback, success: false))
            traceStore.append(
                traceID: traceID,
                command: command,
                stage: .commandFinished,
                route: route,
                action: action,
                success: false,
                failureStage: .targetGuard,
                summary: feedback,
                metadata: ["planner_blocked": "true"]
            )
            return CommandResult(
                feedback: feedback,
                actionResult: .failed(feedback),
                shouldSpeak: true,
                recovery: .confirmCurrentSurface(prompt: feedback)
            )
        }
        onProgress?(.actionStarted(route.actionLine))
        traceStore.append(
            traceID: traceID,
            command: command,
            stage: .actionStarted,
            route: route,
            action: action,
            summary: route.actionLine
        )
        if let targetGuardFailure = targetGuardFailure(
            action: action,
            route: route,
            command: command,
            contextPacket: contextPacket,
            snapshots: snapshots
        ) {
            traceStore.append(
                traceID: traceID,
                command: command,
                stage: .targetGuardBlocked,
                route: route,
                action: action,
                success: false,
                failureStage: .targetGuard,
                summary: targetGuardFailure.summary,
                metadata: targetGuardFailure.targetCheck.traceMetadata
            )
            onProgress?(.result(targetGuardFailure.summary, success: false))
            traceStore.append(
                traceID: traceID,
                command: command,
                stage: .commandFinished,
                route: route,
                action: action,
                success: false,
                failureStage: .targetGuard,
                summary: targetGuardFailure.summary
            )
            return CommandResult(
                feedback: targetGuardFailure.summary,
                actionResult: .failed(targetGuardFailure.summary),
                shouldSpeak: true,
                recovery: .confirmCurrentSurface(
                    prompt: "Say \"yes here\" or \"use this box\" to bind this command to the current target."
                )
            )
        }

        var beforeProbe = verifier.capture(contextPacket: contextPacket)
        var result = await executor.execute(action)
        traceStore.append(
            traceID: traceID,
            command: command,
            stage: .actionExecuted,
            route: route,
            action: action,
            success: result.success,
            failureStage: result.success ? nil : .actionExecution,
            summary: result.summary
        )
        guard !isCancelled(generation: generation) else {
            return Self.cancelledResult()
        }
        var verification = await verifier.verify(
            action: action,
            route: route,
            executionResult: result,
            before: beforeProbe,
            contextPacket: contextPacket
        )
        var effectiveResult = Self.result(result, applying: verification)
        traceStore.append(
            traceID: traceID,
            command: command,
            stage: .verificationFinished,
            route: route,
            action: action,
            success: verification.verdict == .passed,
            failureStage: verification.failureStage,
            summary: verification.summary,
            metadata: verification.traceMetadata
        )
        if !effectiveResult.success,
           Self.shouldAttemptRepair(plan: plan, action: action, verification: verification) {
            let repairAction = Self.repairAction(for: action, plan: plan)
            traceStore.append(
                traceID: traceID,
                command: command,
                stage: .repairAttempted,
                route: route,
                action: repairAction,
                summary: "Retrying with \(plan.repairStrategy.rawValue).",
                metadata: [
                    "repair_strategy": plan.repairStrategy.rawValue,
                    "original_verdict": verification.verdict.rawValue
                ]
            )
            beforeProbe = verifier.capture(contextPacket: contextPacket)
            result = await executor.execute(repairAction)
            traceStore.append(
                traceID: traceID,
                command: command,
                stage: .actionExecuted,
                route: route,
                action: repairAction,
                success: result.success,
                failureStage: result.success ? nil : .actionExecution,
                summary: result.summary,
                metadata: ["repair": "true"]
            )
            guard !isCancelled(generation: generation) else {
                return Self.cancelledResult()
            }
            verification = await verifier.verify(
                action: repairAction,
                route: route,
                executionResult: result,
                before: beforeProbe,
                contextPacket: contextPacket
            )
            effectiveResult = Self.result(result, applying: verification)
            traceStore.append(
                traceID: traceID,
                command: command,
                stage: .verificationFinished,
                route: route,
                action: repairAction,
                success: verification.verdict == .passed,
                failureStage: verification.failureStage,
                summary: verification.summary,
                metadata: verification.traceMetadata.merging(["repair": "true"]) { current, _ in current }
            )
        }
        learningStore?.recordOutcome(
            command: command,
            contextPacket: contextPacket,
            snapshots: snapshots,
            route: route,
            result: effectiveResult,
            failureStage: effectiveResult.success ? nil : verification.failureStage ?? .actionExecution,
            allowBindingUpdate: verification.verdict.permitsLearning
        )
        traceStore.append(
            traceID: traceID,
            command: command,
            stage: .learningRecorded,
            route: route,
            action: action,
            success: effectiveResult.success,
            failureStage: effectiveResult.success ? nil : verification.failureStage ?? .actionExecution,
            summary: effectiveResult.summary,
            metadata: ["binding_update": verification.verdict.permitsLearning ? "true" : "false"]
        )
        let feedback = effectiveResult.success ? effectiveResult.summary : "Failed: \(effectiveResult.summary)"
        onProgress?(.result(feedback, success: effectiveResult.success))
        traceStore.append(
            traceID: traceID,
            command: command,
            stage: .commandFinished,
            route: route,
            action: action,
            success: effectiveResult.success,
            failureStage: effectiveResult.success ? nil : verification.failureStage ?? .actionExecution,
            summary: feedback
        )
        return CommandResult(
            feedback: feedback,
            actionResult: effectiveResult,
            shouldSpeak: !action.handlesVoiceFeedbackInline
        )
    }

    private static func result(
        _ result: CommandActionResult,
        applying verification: DispatchActionVerification
    ) -> CommandActionResult {
        switch verification.verdict {
        case .passed:
            return CommandActionResult(
                success: result.success,
                summary: result.summary,
                detail: joinedDetail(result.detail, verification.summary)
            )
        case .failed:
            return .failed(
                verification.summary,
                detail: joinedDetail(result.detail, "Executor summary: \(result.summary)")
            )
        case .inconclusive:
            guard result.success else { return result }
            return CommandActionResult(
                success: true,
                summary: "\(result.summary) (needs verification)",
                detail: joinedDetail(result.detail, verification.summary)
            )
        }
    }

    private static func joinedDetail(_ first: String?, _ second: String?) -> String? {
        let parts = [first, second]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static func shouldAttemptRepair(
        plan: DispatchPlan,
        action: CommandAction,
        verification: DispatchActionVerification
    ) -> Bool {
        guard verification.verdict == .failed else { return false }
        switch plan.repairStrategy {
        case .retryTargetedSurface:
            switch action {
            case .openApp, .openURL:
                return true
            case .typeText, .postSlack, .searchWorkspace, .speakAnswer, .createTicket, .delegateToAgent, .composite:
                return false
            }
        case .prepareClipboardFallback:
            switch action {
            case .postSlack:
                return true
            case .typeText, .openURL, .openApp, .searchWorkspace, .speakAnswer, .createTicket, .delegateToAgent, .composite:
                return false
            }
        case .askUserToConfirmSurface, .noAutomaticRepair:
            return false
        }
    }

    private static func repairAction(for action: CommandAction, plan: DispatchPlan) -> CommandAction {
        switch (plan.repairStrategy, action) {
        case (.retryTargetedSurface, .openApp), (.retryTargetedSurface, .openURL), (.prepareClipboardFallback, .postSlack):
            return action
        default:
            return action
        }
    }

    private func routeMetadata(_ route: DispatchRouteResolution, snapshotsCount: Int) -> [String: String] {
        var metadata: [String: String] = [
            "route_title": route.card.title,
            "route_intent": route.card.intent.rawValue,
            "route_surface": route.card.surface,
            "route_disturbance": route.card.disturbance.rawValue,
            "confidence": String(format: "%.3f", route.confidence),
            "snapshots": "\(snapshotsCount)"
        ]
        if let learnedBindingID = route.learnedBindingID {
            metadata["learned_binding_id"] = learnedBindingID.uuidString
        }
        for (index, evidence) in route.evidence.prefix(4).enumerated() {
            metadata["evidence_\(index + 1)"] = evidence
        }
        return metadata
    }

    private func isCancelled(generation: Int) -> Bool {
        Task.isCancelled || generation != cancellationGeneration
    }

    private static func cancelledResult() -> CommandResult {
        CommandResult(
            feedback: "Command cancelled.",
            actionResult: .failed("Cancelled"),
            shouldSpeak: false
        )
    }

    private func targetGuardFailure(
        action: CommandAction,
        route: DispatchRouteResolution,
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> (summary: String, targetCheck: DispatchTargetCheck)? {
        guard let learningStore,
              let bindingID = route.learnedBindingID,
              let binding = learningStore.binding(id: bindingID) else {
            return nil
        }

        let currentSurface = DispatchLearningStore.surfaceFingerprint(
            contextPacket: contextPacket,
            snapshots: snapshots
        )

        let evaluation = DispatchTargetGuard.evaluate(
            action: action,
            binding: binding,
            currentSurface: currentSurface
        )
        guard !evaluation.allowed else {
            return nil
        }
        let summary = evaluation.check.summary ?? "Target guard blocked active-surface execution."
        learningStore.recordGuardFailure(
            command: command,
            contextPacket: contextPacket,
            snapshots: snapshots,
            route: route,
            binding: binding,
            summary: summary,
            targetCheck: evaluation.check
        )
        return (summary, evaluation.check)
    }

    /// Speak the result feedback via TTS.
    func speakResult(_ result: CommandResult, onFinished: (() -> Void)? = nil) {
        guard result.shouldSpeak else {
            onFinished?()
            return
        }
        voiceFeedback.speak(result.feedback, onFinished: onFinished)
    }

    // MARK: - Cloud communication

    private func sendToCloud(prompt: String, convexClient: ConvexClient) async throws -> String {
        var collected = ""
        // The deployed backend currently exposes the shared chat stream. The
        // command-specific prompt still asks for JSON-only action output.
        for try await chunk in convexClient.streamChat(prompt: prompt) {
            collected += chunk
        }

        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CommandError.emptyResponse
        }
        return trimmed
    }

    private func failureStage(for error: Error) -> DispatchFailureStage {
        guard let commandError = error as? CommandError else {
            return .cloudClassification
        }
        switch commandError {
        case .invalidResponse, .unknownAction:
            return .responseParsing
        case .emptyResponse, .notConfigured:
            return .cloudClassification
        }
    }

}

private extension DispatchActionVerification {
    var traceMetadata: [String: String] {
        var metadata = evidence
        metadata["verdict"] = verdict.rawValue
        return metadata
    }
}

private extension DispatchTargetCheck {
    var traceMetadata: [String: String] {
        var metadata: [String: String] = [
            "required": required ? "true" : "false",
            "expected_ax_target": expectedAXTarget ? "true" : "false",
            "current_ax_target": currentAXTarget ? "true" : "false"
        ]
        if let matchScore {
            metadata["match_score"] = String(format: "%.3f", matchScore)
        }
        if let minimumScore {
            metadata["minimum_score"] = String(format: "%.3f", minimumScore)
        }
        if let summary {
            metadata["target_guard_summary"] = summary
        }
        return metadata
    }
}

private extension DispatchPlan {
    var traceMetadata: [String: String] {
        var metadata: [String: String] = [
            "objective": objective,
            "target_surface": targetSurface,
            "execution_strategy": executionStrategy.rawValue,
            "verification_strategy": verificationStrategy.rawValue,
            "repair_strategy": repairStrategy.rawValue,
            "capability_status": capabilityStatus.rawValue,
            "confidence": String(format: "%.3f", confidence),
            "requires_clarification": requiresClarification ? "true" : "false"
        ]
        if let clarificationPrompt {
            metadata["clarification_prompt"] = clarificationPrompt
        }
        if let surfaceKind {
            metadata["surface_app"] = surfaceKind.rawValue
        }
        if let surfaceVariant {
            metadata["surface_variant"] = surfaceVariant.rawValue
        }
        if requiresAPI {
            metadata["capability_requires_api"] = "true"
        }
        if requiresActiveTarget {
            metadata["capability_requires_active_target"] = "true"
        }
        if let fallback {
            metadata["capability_fallback"] = fallback
        }
        for (index, item) in evidence.prefix(4).enumerated() {
            metadata["planner_evidence_\(index + 1)"] = item
        }
        return metadata
    }
}

// MARK: - Types

struct CommandResult: Sendable {
    let feedback: String
    let actionResult: CommandActionResult?
    let shouldSpeak: Bool
    var recovery: DispatchCommandRecovery? = nil
}

enum DispatchCommandRecovery: Sendable, Equatable {
    case confirmCurrentSurface(prompt: String)
}

enum CommandError: LocalizedError {
    case emptyResponse
    case invalidResponse(String)
    case unknownAction(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .emptyResponse: "Empty response from cloud."
        case .invalidResponse(let r): "Could not parse action: \(r.prefix(200))"
        case .unknownAction(let a): "Unknown action: \(a)"
        case .notConfigured: "Command system not configured."
        }
    }
}
