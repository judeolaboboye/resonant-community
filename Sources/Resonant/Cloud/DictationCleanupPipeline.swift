import Foundation

/// Owns the dictation post-processing sequence in one place:
///
///   cloud cleanup → deterministic preservation gate → email normalization
///   → local lint + local repairs → optional cloud quality repair
///   → deterministic preservation gate + post-repair lint verification
///
/// AppState supplies entitlements and side-effect hooks (notch progress,
/// latency marks, analytics); the pipeline owns ordering, gating, and
/// quality-trace bookkeeping.
@MainActor
struct DictationCleanupPipeline {
    struct Outcome {
        let text: String
        let cleanup: DictationQualityTrace.Cleanup
    }

    let convexClient: ConvexClient
    let cloudProcessingEnabled: Bool
    let lowLatencyMode: Bool
    let isLoggedIn: Bool
    let fallbackSenderName: String?
    let recentTexts: [String]
    /// Injectable result seams keep the orchestration testable without making
    /// network calls. Production leaves both nil and uses ConvexClient.
    var cleanupResultProvider: (() async -> ConvexClient.DictationCleanupResult)?
    var qualityRepairResultProvider: (() async -> ConvexClient.DictationQualityRepairResult)?
    /// Per-surface cleanup latitude; `.standard` keeps today's behavior.
    var polishSettings: DictationPolishSettings = .standard

    /// Notch progress callback; nil when the workflow UI is not visible.
    var onStage: ((_ progress: Double, _ stage: String) -> Void)?
    var markLatency: ((_ label: StaticString) -> Void)?
    var captureAnalytics: ((_ event: String, _ properties: [String: Any]) -> Void)?

    func resolve(
        transcript: String,
        result: TranscriptionResult,
        emailMode: CloudProcessingSupport.EmailDictationMode
    ) async -> Outcome {
        let cleanupProfile = CloudProcessingSupport.cleanupPromptProfile(
            appName: result.targetApp,
            bundleId: result.targetBundleId,
            windowTitle: result.windowTitle,
            browserURL: result.browserURL,
            emailMode: emailMode
        )
        let listIntent = CloudProcessingSupport.listIntent(
            transcript: transcript,
            profile: cleanupProfile
        )
        let profileName = String(describing: cleanupProfile)
        let listIntentName = listIntent.rawValue

        func localOutcome(
            reason: String,
            status: DictationQualityTrace.CleanupStatus = .skipped,
            attempted: Bool = false,
            accepted: Bool? = nil,
            path: String? = nil,
            sanitizerRejectReason: String? = nil,
            clientDurationMs: Int? = nil,
            serverDurationMs: Int? = nil,
            cloudSubmission: CloudContextPersonalizationSubmission = .none
        ) -> Outcome {
            let normalized = EmailSignatureSupport.normalizeDictatedEmailText(
                transcript,
                mode: emailMode,
                fallbackSenderName: fallbackSenderName,
                existingFieldContent: result.focusedFieldContent
            )
            var cleanupTrace = DictationQualityTrace.Cleanup(
                status: status,
                profile: profileName,
                listIntent: listIntentName,
                attempted: attempted,
                accepted: accepted,
                path: path,
                fallbackReason: reason,
                sanitizerRejectReason: sanitizerRejectReason,
                clientDurationMs: clientDurationMs,
                serverDurationMs: serverDurationMs
            )
            cleanupTrace.recordCloudContextSubmission(cloudSubmission)
            return localQualityOutcome(
                transcript: transcript,
                normalizedText: normalized,
                result: result,
                cleanupProfile: cleanupProfile,
                cleanupTrace: cleanupTrace
            )
        }

        if emailMode == .signoffOnly {
            return localOutcome(reason: "email_signoff_only")
        }

        let polishLevel = polishSettings.level(for: cleanupProfile)
        if polishLevel == .verbatim {
            return localOutcome(reason: "polish_verbatim")
        }

        if lowLatencyMode {
            return localOutcome(reason: "low_latency_mode")
        }

        if CloudProcessingSupport.shouldBypassCloudCleanupForShortDictation(
            transcript: transcript,
            profile: cleanupProfile
        ) {
            return localOutcome(reason: "short_dictation")
        }

        // Skip the network round-trip entirely when cloud cleanup can't run.
        guard cloudProcessingEnabled, isLoggedIn else {
            return localOutcome(reason: cloudProcessingEnabled ? "signed_out" : "cloud_disabled")
        }

        onStage?(0.5, "Cleaning up…")

        markLatency?("cloudCleanupStart")
        let cloudContextPayload = CloudContextSanitizer.cleanupPayload(
            from: result.contextPacket
        )
        let cleanupResult: ConvexClient.DictationCleanupResult
        if let cleanupResultProvider {
            cleanupResult = await cleanupResultProvider()
        } else {
            cleanupResult = await convexClient.processDictationCleanupDetailed(
                transcript: transcript,
                windowTitle: result.windowTitle,
                appName: result.targetApp,
                bundleId: result.targetBundleId,
                browserURL: result.browserURL,
                dictionaryTerms: cloudContextPayload.biasTerms,
                recentTexts: recentTexts,
                styleHint: cloudContextPayload.styleHint,
                cleanupProfileOverride: cleanupProfile,
                pauseAnnotatedTranscript: result.pauseAnnotatedTranscript,
                editExemplars: result.contextPacket?.editExemplars ?? [],
                polishLevel: polishLevel
            )
        }
        let cloudSubmission = cleanupResult.trace.attempted
            ? cloudContextPayload.personalizationSubmission
            : .none
        var cleanupTrace = cleanupResult.trace
        cleanupTrace.recordCloudContextSubmission(cloudSubmission)
        let cleanedCandidate = cleanupResult.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        markLatency?("cloudCleanupEnd")
        guard let cleaned = cleanedCandidate,
              !cleaned.isEmpty
        else {
            return localOutcome(
                reason: cleanupResult.trace.sanitizerRejectReason
                    ?? cleanupResult.trace.fallbackReason
                    ?? "cloud_no_result",
                status: .fallbackLocal,
                attempted: cleanupResult.trace.attempted,
                accepted: cleanupResult.trace.accepted,
                path: cleanupResult.trace.path,
                sanitizerRejectReason: cleanupResult.trace.sanitizerRejectReason,
                clientDurationMs: cleanupResult.trace.clientDurationMs,
                serverDurationMs: cleanupResult.trace.serverDurationMs,
                cloudSubmission: cloudSubmission
            )
        }

        // The cloud result has already consumed the single cleanup pass. A
        // deterministic content-preservation gate decides whether it is safe
        // to ship; rejection returns the local/raw path without asking another
        // model to vote on the rewrite.
        let candidateDecision = DictationCleanupCandidateGate.resolve(
            original: transcript,
            candidate: cleaned
        )
        if !candidateDecision.accepted {
            let reason = candidateDecision.issue?.rawValue
                ?? DictationQualityIssue.parallelClauseContentDeletion.rawValue
            let fallback = localOutcome(
                reason: reason,
                status: .fallbackLocal,
                attempted: cleanupResult.trace.attempted,
                accepted: false,
                path: cleanupResult.trace.path,
                sanitizerRejectReason: cleanupResult.trace.sanitizerRejectReason,
                clientDurationMs: cleanupResult.trace.clientDurationMs,
                serverDurationMs: cleanupResult.trace.serverDurationMs,
                cloudSubmission: cloudSubmission
            )
            return Outcome(
                text: fallback.text,
                cleanup: candidateDecision.applying(to: fallback.cleanup)
            )
        }

        let normalized = EmailSignatureSupport.normalizeDictatedEmailText(
            cleaned,
            mode: emailMode,
            fallbackSenderName: fallbackSenderName,
            existingFieldContent: result.focusedFieldContent
        )
        return await qualityRepairIfNeeded(
            transcript: transcript,
            normalizedText: normalized,
            result: result,
            cleanupProfile: cleanupProfile,
            listIntent: listIntent,
            emailMode: emailMode,
            cleanupTrace: cleanupTrace
        )
    }

    // MARK: - Quality repair

    private func qualityRepairIfNeeded(
        transcript: String,
        normalizedText: String,
        result: TranscriptionResult,
        cleanupProfile: CloudProcessingSupport.CleanupPromptProfile,
        listIntent: CloudProcessingSupport.ListIntent,
        emailMode: CloudProcessingSupport.EmailDictationMode,
        cleanupTrace: DictationQualityTrace.Cleanup
    ) async -> Outcome {
        let localQuality = localQualityOutcome(
            transcript: transcript,
            normalizedText: normalizedText,
            result: result,
            cleanupProfile: cleanupProfile,
            cleanupTrace: cleanupTrace
        )
        let candidateText = localQuality.text
        var trace = localQuality.cleanup

        let appKey = Self.appKey(for: result)
        let surfaceKind = Self.surfaceKind(for: result)
        let lint = DictationQualityLint.evaluate(
            originalTranscript: transcript,
            candidateText: candidateText,
            profile: cleanupProfile,
            appKey: appKey,
            surfaceKind: surfaceKind
        )

        trace.qualityPolicy = lint.policy.mode.rawValue
        trace.qualityIssuesAfterLocalRepair = lint.issueCodes
        guard lint.requiresRepair,
              shouldAttemptQualityRepair(
                  lint: lint,
                  cleanupProfile: cleanupProfile
              )
        else {
            return Outcome(text: candidateText, cleanup: trace)
        }

        guard isLoggedIn,
              cloudProcessingEnabled,
              !lowLatencyMode
        else {
            return Outcome(text: candidateText, cleanup: trace)
        }

        onStage?(0.68, "Polishing…")
        markLatency?("qualityRepairStart")
        let cloudContextPayload = CloudContextSanitizer.cleanupPayload(
            from: result.contextPacket
        )
        let repairResult: ConvexClient.DictationQualityRepairResult
        if let qualityRepairResultProvider {
            repairResult = await qualityRepairResultProvider()
        } else {
            repairResult = await convexClient.repairDictationQuality(
                originalTranscript: transcript,
                candidateText: candidateText,
                issues: lint.issueCodes,
                profile: cleanupProfile,
                listIntent: listIntent,
                windowTitle: result.windowTitle,
                appName: result.targetApp,
                bundleId: result.targetBundleId,
                browserURL: result.browserURL,
                dictionaryTerms: cloudContextPayload.biasTerms,
                styleHint: cloudContextPayload.styleHint
            )
        }
        markLatency?("qualityRepairEnd")

        trace.qualityRepairAttempted = repairResult.attempted
        trace.qualityRepairAccepted = repairResult.accepted
        trace.qualityRepairRejectReason = repairResult.rejectReason
        trace.qualityRepairClientDurationMs = repairResult.clientDurationMs
        trace.qualityRepairServerDurationMs = repairResult.serverDurationMs
        if repairResult.attempted {
            trace.recordCloudContextSubmission(
                cloudContextPayload.personalizationSubmission
            )
        }

        guard let repairedText = repairResult.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repairedText.isEmpty
        else {
            return Outcome(text: candidateText, cleanup: trace)
        }

        let normalizedRepair = EmailSignatureSupport.normalizeDictatedEmailText(
            repairedText,
            mode: emailMode,
            fallbackSenderName: fallbackSenderName,
            existingFieldContent: result.focusedFieldContent
        )
        guard normalizedRepair != candidateText else {
            trace.qualityRepairAccepted = false
            trace.qualityRepairRejectReason = "no_change"
            return Outcome(text: candidateText, cleanup: trace)
        }

        let postLint = DictationQualityLint.evaluate(
            originalTranscript: transcript,
            candidateText: normalizedRepair,
            profile: cleanupProfile,
            appKey: appKey,
            surfaceKind: surfaceKind
        )
        trace.qualityIssuesAfterRepair = postLint.issueCodes
        let repairDecision = DictationCleanupCandidateGate.resolve(
            original: transcript,
            candidate: normalizedRepair
        )
        guard repairDecision.accepted else {
            trace.qualityRepairAccepted = false
            trace.qualityRepairRejectReason = repairDecision.issue?.rawValue
                ?? DictationQualityIssue.parallelClauseContentDeletion.rawValue
            return Outcome(text: candidateText, cleanup: trace)
        }
        if Set(postLint.issueCodes).isSuperset(of: Set(lint.issueCodes)) {
            trace.qualityRepairAccepted = false
            trace.qualityRepairRejectReason = "no_quality_improvement"
            return Outcome(text: candidateText, cleanup: trace)
        }

        return Outcome(text: normalizedRepair, cleanup: trace)
    }

    /// Runs lint + deterministic local repairs and records both pre- and
    /// post-repair issue codes on the trace.
    private func localQualityOutcome(
        transcript: String,
        normalizedText: String,
        result: TranscriptionResult,
        cleanupProfile: CloudProcessingSupport.CleanupPromptProfile,
        cleanupTrace: DictationQualityTrace.Cleanup
    ) -> Outcome {
        let appKey = Self.appKey(for: result)
        let surfaceKind = Self.surfaceKind(for: result)
        let lint = DictationQualityLint.evaluate(
            originalTranscript: transcript,
            candidateText: normalizedText,
            profile: cleanupProfile,
            appKey: appKey,
            surfaceKind: surfaceKind
        )
        let locallyRepaired = DictationQualityLint.applyLocalRepairs(
            to: normalizedText,
            policy: lint.policy
        )
        let postLocalLint = locallyRepaired == normalizedText
            ? lint
            : DictationQualityLint.evaluate(
                originalTranscript: transcript,
                candidateText: locallyRepaired,
                profile: cleanupProfile,
                appKey: appKey,
                surfaceKind: surfaceKind
            )

        var trace = cleanupTrace
        trace.qualityPolicy = lint.policy.mode.rawValue
        trace.qualityIssues = lint.issueCodes
        trace.qualityLocalRepairApplied = locallyRepaired != normalizedText
        trace.qualityIssuesAfterLocalRepair = postLocalLint.issueCodes
        return Outcome(text: locallyRepaired, cleanup: trace)
    }

    private func shouldAttemptQualityRepair(
        lint: DictationQualityLintResult,
        cleanupProfile: CloudProcessingSupport.CleanupPromptProfile
    ) -> Bool {
        guard lint.policy.allowsCloudRepair else {
            return false
        }

        switch cleanupProfile {
        case .emailFull:
            return true
        case .default:
            return lint.issues.contains(.longUnstructuredText)
                || lint.issues.contains(.assistantArtifact)
        case .message, .emailFragment:
            return false
        }
    }

    private static func appKey(for result: TranscriptionResult) -> String {
        CloudProcessingSupport.normalizeAppKey(
            appName: result.targetApp,
            bundleId: result.targetBundleId,
            windowTitle: result.windowTitle,
            browserURL: result.browserURL
        )
    }

    private static func surfaceKind(for result: TranscriptionResult) -> String {
        result.contextPacket?.surface.kind.rawValue
            ?? SurfaceClassifier.classify(
                appName: result.targetApp,
                bundleId: result.targetBundleId,
                windowTitle: result.windowTitle,
                browserURL: result.browserURL
            ).kind.rawValue
    }
}
