import Foundation

// MARK: - Dictation cleanup + quality repair

extension ConvexClient {
    struct CleanupSanitizationResult: Equatable {
        let accepted: Bool
        let text: String?
        let reason: String?
    }

    struct DictationCleanupResult: Equatable {
        let text: String?
        let trace: DictationQualityTrace.Cleanup
    }

    struct DictationQualityRepairResult: Equatable {
        let text: String?
        let attempted: Bool
        let accepted: Bool?
        let rejectReason: String?
        let clientDurationMs: Int?
        let serverDurationMs: Int?

        static func notAttempted(reason: String) -> DictationQualityRepairResult {
            DictationQualityRepairResult(
                text: nil,
                attempted: false,
                accepted: nil,
                rejectReason: reason,
                clientDurationMs: nil,
                serverDurationMs: nil
            )
        }
    }

    /// Typed input retained across endpoint attempts. Final Convex arguments
    /// are intentionally not stored here: they are rebuilt from this value and
    /// live privacy settings immediately before each primary/fallback dispatch.
    struct DictationCleanupRequest: Equatable {
        let userID: String
        let windowTitle: String
        let dictionaryTerms: [String]
        let appKey: String
        let recentTexts: [String]
        let styleHint: String?
        let transcript: String
        let profile: CloudProcessingSupport.CleanupPromptProfile
        let listIntent: CloudProcessingSupport.ListIntent
        let pauseAnnotatedTranscript: String?
        let editExemplars: [DictationEditExemplar]
        let polishLevel: DictationPolishLevel
    }

    private enum DictationCleanupAttemptRoute: CaseIterable {
        case primary
        case fallback

        var path: String {
            switch self {
            case .primary: "cloudProcessing:processDictationCleanup"
            case .fallback: "cloudProcessing:processTranscript"
            }
        }

        var fallbackReason: String? {
            switch self {
            case .primary: nil
            case .fallback: "primary_endpoint_unavailable"
            }
        }

        var errorLabel: String {
            switch self {
            case .primary: path
            case .fallback: "\(path)(cleanup-fallback)"
            }
        }
    }

    func processDictationCleanup(
        transcript: String,
        windowTitle: String?,
        appName: String?,
        bundleId: String?,
        browserURL: String?,
        dictionaryTerms: [String],
        recentTexts: [String],
        styleHint: String? = nil,
        cleanupProfileOverride: CloudProcessingSupport.CleanupPromptProfile? = nil
    ) async -> String? {
        let result = await processDictationCleanupDetailed(
            transcript: transcript,
            windowTitle: windowTitle,
            appName: appName,
            bundleId: bundleId,
            browserURL: browserURL,
            dictionaryTerms: dictionaryTerms,
            recentTexts: recentTexts,
            styleHint: styleHint,
            cleanupProfileOverride: cleanupProfileOverride
        )
        return result.text
    }

    func processDictationCleanupDetailed(
        transcript: String,
        windowTitle: String?,
        appName: String?,
        bundleId: String?,
        browserURL: String?,
        dictionaryTerms: [String],
        recentTexts: [String],
        styleHint: String? = nil,
        cleanupProfileOverride: CloudProcessingSupport.CleanupPromptProfile? = nil,
        pauseAnnotatedTranscript: String? = nil,
        editExemplars: [DictationEditExemplar] = [],
        polishLevel: DictationPolishLevel = .clean,
        attemptRunner: ((DictationCleanupRequest, CloudTextAttempt) async throws -> CloudTextResponse)? = nil
    ) async -> DictationCleanupResult {
        let normalizedTranscript = transcript.trimmedNilIfEmpty ?? transcript
        let normalizedWindowTitle = windowTitle?.trimmedNilIfEmpty ?? appName?.trimmedNilIfEmpty ?? ""
        let appKey = CloudProcessingSupport.normalizeAppKey(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        let cleanupProfile = cleanupProfileOverride ?? CloudProcessingSupport.cleanupPromptProfile(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        let listIntent = CloudProcessingSupport.listIntent(
            transcript: normalizedTranscript,
            profile: cleanupProfile
        )
        let profileName = String(describing: cleanupProfile)
        let listIntentName = listIntent.rawValue

        func skipped(_ reason: String) -> DictationCleanupResult {
            DictationCleanupResult(
                text: nil,
                trace: .skipped(reason: reason, profile: profileName, listIntent: listIntentName)
            )
        }

        func finished(
            status: DictationQualityTrace.CleanupStatus,
            text: String? = nil,
            accepted: Bool,
            path: String,
            fallbackReason: String?,
            sanitizerRejectReason: String? = nil,
            clientDurationMs: Int,
            serverDurationMs: Int? = nil
        ) -> DictationCleanupResult {
            DictationCleanupResult(
                text: text,
                trace: DictationQualityTrace.Cleanup(
                    status: status,
                    profile: profileName,
                    listIntent: listIntentName,
                    attempted: true,
                    accepted: accepted,
                    path: path,
                    fallbackReason: fallbackReason,
                    sanitizerRejectReason: sanitizerRejectReason,
                    clientDurationMs: clientDurationMs,
                    serverDurationMs: serverDurationMs
                )
            )
        }

        guard settings.cloudProcessingEnabled, canPerformCloudRequest() else {
            return skipped("cloud_unavailable")
        }
        guard let userID = resolvedUserID else {
            return skipped("no_user_id")
        }
        guard !normalizedTranscript.isEmpty else {
            return skipped("empty_transcript")
        }

        // Email profiles intentionally exclude recent texts — they bias the
        // model toward inventing message content that was never dictated.
        let recentTextsForCleanup = cleanupProfile == .emailFull || cleanupProfile == .emailFragment ? [] : recentTexts
        let request = DictationCleanupRequest(
            userID: userID,
            windowTitle: normalizedWindowTitle,
            dictionaryTerms: dictionaryTerms,
            appKey: appKey,
            recentTexts: recentTextsForCleanup,
            styleHint: styleHint,
            transcript: normalizedTranscript,
            profile: cleanupProfile,
            listIntent: listIntent,
            pauseAnnotatedTranscript: pauseAnnotatedTranscript,
            editExemplars: editExemplars,
            polishLevel: polishLevel
        )
        let cleanupStartedAt = Date()

        for (index, route) in DictationCleanupAttemptRoute.allCases.enumerated() {
            let isLast = index == DictationCleanupAttemptRoute.allCases.count - 1
            // This is the final request-argument boundary. The builder rereads
            // explicit consent and HIPAA mode, sanitizes/revalidates examples,
            // and constructs this route's instruction. No suspension point
            // exists between this call and the runner invocation below.
            let attempt = makeDictationCleanupAttempt(request: request, route: route)
            do {
                let response: CloudTextResponse
                if let attemptRunner {
                    response = try await attemptRunner(request, attempt)
                } else {
                    response = try await runCloudTextAttempt(attempt)
                }
                let clientDurationMs = Self.millisecondsSince(cleanupStartedAt)
                let sanitized = Self.sanitizeDictationCleanupResponse(
                    original: normalizedTranscript,
                    result: response.text,
                    profile: cleanupProfile,
                    polishLevel: polishLevel
                )
                guard sanitized.accepted, let sanitizedText = sanitized.text else {
                    let reason = sanitized.reason ?? "unknown"
                    AnalyticsManager.shared.capture("cloud_processing_failed", properties: cloudProcessingFailedProperties(
                        path: attempt.path,
                        appKey: appKey,
                        clientDurationMs: clientDurationMs,
                        error: nil,
                        fallbackReason: route.fallbackReason,
                        sanitizerRejectReason: reason
                    ))
                    return finished(
                        status: .rejected,
                        accepted: false,
                        path: attempt.path,
                        fallbackReason: route.fallbackReason,
                        sanitizerRejectReason: reason,
                        clientDurationMs: clientDurationMs,
                        serverDurationMs: response.durationMs
                    )
                }
                AnalyticsManager.shared.capture("cloud_processing_used", properties: cloudProcessingUsedProperties(
                    path: attempt.path,
                    appKey: appKey,
                    clientDurationMs: clientDurationMs,
                    serverDurationMs: response.durationMs,
                    fallbackReason: route.fallbackReason
                ))
                return finished(
                    status: .accepted,
                    text: sanitizedText,
                    accepted: true,
                    path: attempt.path,
                    fallbackReason: route.fallbackReason,
                    clientDurationMs: clientDurationMs,
                    serverDurationMs: response.durationMs
                )
            } catch {
                let errorText = String(describing: error)
                let clientDurationMs = Self.millisecondsSince(cleanupStartedAt)

                if CloudErrorClassifier.isDailyLimit(errorText) {
                    AnalyticsManager.shared.capture("cloud_processing_failed", properties: cloudProcessingFailedProperties(
                        path: attempt.path,
                        appKey: appKey,
                        clientDurationMs: clientDurationMs,
                        error: error,
                        fallbackReason: "daily_limit_reached"
                    ))
                    return finished(
                        status: .failed,
                        accepted: false,
                        path: attempt.path,
                        fallbackReason: "daily_limit_reached",
                        clientDurationMs: clientDurationMs
                    )
                }

                if !isLast, CloudErrorClassifier.canFallbackFromDedicatedCleanup(errorText) {
                    continue
                }

                let failureReason = index == 0 ? nil : "fallback_endpoint_failed"
                AnalyticsManager.shared.capture("cloud_processing_failed", properties: cloudProcessingFailedProperties(
                    path: attempt.path,
                    appKey: appKey,
                    clientDurationMs: clientDurationMs,
                    error: error,
                    fallbackReason: failureReason
                ))
                SentryManager.shared.cloudProcessingError(path: route.errorLabel, error: error)
                return finished(
                    status: .failed,
                    accepted: false,
                    path: attempt.path,
                    fallbackReason: failureReason,
                    clientDurationMs: clientDurationMs
                )
            }
        }

        return skipped("no_attempts")
    }

    private func makeDictationCleanupAttempt(
        request: DictationCleanupRequest,
        route: DictationCleanupAttemptRoute
    ) -> CloudTextAttempt {
        // Read both live values, rather than trusting an earlier effective
        // snapshot. HIPAA is a hard veto even if stale consent somehow exists.
        let examplesEnabled = SettingsManager.effectiveCloudPersonalizationExamplesConsent(
            explicitConsent: settings.cloudPersonalizationExamplesEnabled,
            hipaaMode: settings.hipaaMode
        )
        let sanitizedExamples = examplesEnabled
            ? DictationEditExemplarSanitizer.sanitizedCandidates(request.editExemplars)
            : []

        var args = cloudContextArgs(
            userID: request.userID,
            windowTitle: request.windowTitle,
            dictionaryTerms: request.dictionaryTerms,
            appKey: request.appKey,
            recentTexts: request.recentTexts,
            styleHint: request.styleHint
        )
        args["transcript"] = request.transcript
        args["instruction"] = CloudProcessingSupport.cleanupInstruction(
            for: request.profile,
            listIntent: request.listIntent,
            pauseAnnotatedTranscript: request.pauseAnnotatedTranscript,
            editExemplars: sanitizedExamples,
            polishLevel: request.polishLevel
        )
        if route == .fallback {
            args["mode"] = "dictation_cleanup"
        }

        return CloudTextAttempt(
            path: route.path,
            args: args,
            timeoutMs: CloudTimeouts.dictationCleanupMs
        )
    }

    func repairDictationQuality(
        originalTranscript: String,
        candidateText: String,
        issues: [String],
        profile: CloudProcessingSupport.CleanupPromptProfile,
        listIntent: CloudProcessingSupport.ListIntent,
        windowTitle: String?,
        appName: String?,
        bundleId: String?,
        browserURL: String?,
        dictionaryTerms: [String],
        styleHint: String? = nil
    ) async -> DictationQualityRepairResult {
        let normalizedCandidate = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty, !issues.isEmpty else {
            return .notAttempted(reason: "no_quality_issues")
        }
        guard settings.cloudProcessingEnabled, canPerformCloudRequest() else {
            return .notAttempted(reason: "cloud_unavailable")
        }
        guard let userID = resolvedUserID else {
            return .notAttempted(reason: "no_user_id")
        }

        let appKey = CloudProcessingSupport.normalizeAppKey(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        let normalizedWindowTitle = windowTitle?.trimmedNilIfEmpty ?? appName?.trimmedNilIfEmpty ?? ""
        var args = cloudContextArgs(
            userID: userID,
            windowTitle: normalizedWindowTitle,
            dictionaryTerms: dictionaryTerms,
            appKey: appKey,
            recentTexts: [],
            styleHint: styleHint
        )
        args["transcript"] = normalizedCandidate
        args["instruction"] = CloudProcessingSupport.qualityRepairInstruction(
            for: profile,
            issues: issues,
            listIntent: listIntent
        )
        args["qualityIssues"] = issues

        let primaryPath = "cloudProcessing:processQualityRepair"
        let fallbackPath = "cloudProcessing:processDictationCleanup"
        var fallbackArgs = args
        fallbackArgs.removeValue(forKey: "qualityIssues")

        let startedAt = Date()
        var usedPath = primaryPath
        var usedFallback = false

        func baseProperties(clientDurationMs: Int, serverDurationMs: Int? = nil) -> [String: Any] {
            var properties: [String: Any] = [
                "issues": issues,
                "profile": String(describing: profile),
                "app_key": appKey,
                "path": usedPath,
                "used_fallback_endpoint": usedFallback,
                "client_duration_ms": clientDurationMs
            ]
            if let serverDurationMs {
                properties["server_duration_ms"] = serverDurationMs
            }
            return properties
        }

        func sendRepairRequest(_ attempt: CloudTextAttempt) async throws -> CloudTextResponse {
            do {
                return try await runCloudTextAttempt(attempt)
            } catch {
                SentryManager.shared.cloudProcessingError(path: attempt.resolvedSentryLabel, error: error)
                throw error
            }
        }

        do {
            let response: CloudTextResponse
            do {
                response = try await sendRepairRequest(CloudTextAttempt(
                    path: primaryPath,
                    args: args,
                    timeoutMs: CloudTimeouts.qualityRepairMs
                ))
            } catch {
                let errorText = String(describing: error)
                guard CloudErrorClassifier.canFallbackFromDedicatedQualityRepair(errorText) else {
                    throw error
                }
                usedPath = fallbackPath
                usedFallback = true
                AnalyticsManager.shared.capture("dictation_quality_repair_endpoint_fallback", properties: [
                    "issues": issues,
                    "profile": String(describing: profile),
                    "app_key": appKey,
                    "from_path": primaryPath,
                    "to_path": fallbackPath,
                    "reason": "dedicated_endpoint_unavailable",
                    "error": errorText
                ])
                response = try await sendRepairRequest(CloudTextAttempt(
                    path: fallbackPath,
                    sentryLabel: "\(fallbackPath)(quality-repair-fallback)",
                    args: fallbackArgs,
                    timeoutMs: CloudTimeouts.qualityRepairMs
                ))
            }

            let clientDurationMs = Self.millisecondsSince(startedAt)
            let sanitized = Self.sanitizeDictationCleanupResponse(
                original: normalizedCandidate,
                result: response.text,
                profile: profile
            )
            guard sanitized.accepted, let repairedText = sanitized.text else {
                let reason = sanitized.reason ?? "unknown"
                var properties = baseProperties(clientDurationMs: clientDurationMs, serverDurationMs: response.durationMs)
                properties["reason"] = reason
                AnalyticsManager.shared.capture("dictation_quality_repair_failed", properties: properties)
                return DictationQualityRepairResult(
                    text: nil,
                    attempted: true,
                    accepted: false,
                    rejectReason: reason,
                    clientDurationMs: clientDurationMs,
                    serverDurationMs: response.durationMs
                )
            }

            AnalyticsManager.shared.capture(
                "dictation_quality_repair_used",
                properties: baseProperties(clientDurationMs: clientDurationMs, serverDurationMs: response.durationMs)
            )
            return DictationQualityRepairResult(
                text: repairedText,
                attempted: true,
                accepted: true,
                rejectReason: nil,
                clientDurationMs: clientDurationMs,
                serverDurationMs: response.durationMs
            )
        } catch {
            let clientDurationMs = Self.millisecondsSince(startedAt)
            var properties = baseProperties(clientDurationMs: clientDurationMs)
            properties["reason"] = "request_failed"
            properties["error"] = String(describing: error)
            AnalyticsManager.shared.capture("dictation_quality_repair_failed", properties: properties)
            return DictationQualityRepairResult(
                text: nil,
                attempted: true,
                accepted: false,
                rejectReason: "request_failed",
                clientDurationMs: clientDurationMs,
                serverDurationMs: nil
            )
        }
    }

    nonisolated static func sanitizeDictationCleanupResponse(
        original: String,
        result: String?,
        profile: CloudProcessingSupport.CleanupPromptProfile,
        polishLevel: DictationPolishLevel = .clean
    ) -> CleanupSanitizationResult {
        let sanitized = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: result,
            profile: profile,
            polishLevel: polishLevel
        )
        guard sanitized.accepted else {
            return CleanupSanitizationResult(
                accepted: false,
                text: nil,
                reason: sanitized.reason
            )
        }
        return CleanupSanitizationResult(
            accepted: true,
            text: sanitized.text,
            reason: nil
        )
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
