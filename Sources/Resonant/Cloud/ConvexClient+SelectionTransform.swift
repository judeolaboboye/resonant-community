import Foundation

enum TransformFailure: Error {
    case featureDisabled
    case signInRequired
    case emptyInput
    case serverError(String)
    case outputRejected(String)

    var userMessage: String {
        switch self {
        case .featureDisabled:
            "Selection transform is turned off in settings."
        case .signInRequired:
            "Sign in to transform selected text."
        case .emptyInput:
            "No text to transform. Select text and try again."
        case .serverError(let detail):
            "Transform failed: \(detail)"
        case .outputRejected(let reason):
            "Transform produced an unexpected result (\(reason)). Try rephrasing your instruction."
        }
    }
}

// MARK: - Selection transform

extension ConvexClient {
    func transformSelection(
        command: String,
        selectedText: String,
        windowTitle: String?,
        appName: String?,
        bundleId: String?,
        browserURL: String?,
        dictionaryTerms: [String],
        recentTexts: [String],
        routing: CloudProcessingSupport.SelectionTransformRouting? = nil
    ) async -> Result<String, TransformFailure> {
        guard settings.selectionTransformEnabled else {
            NSLog("[TransformDebug] ConvexClient.transformSelection aborted: feature disabled")
            return .failure(.featureDisabled)
        }

        guard let userID = resolvedUserID else {
            NSLog("[TransformDebug] ConvexClient.transformSelection aborted: no user id")
            return .failure(.signInRequired)
        }

        let normalizedCommand = command.trimmedNilIfEmpty ?? ""
        let normalizedSelectedText = selectedText.trimmedNilIfEmpty ?? ""
        guard !normalizedCommand.isEmpty, !normalizedSelectedText.isEmpty else {
            NSLog(
                "[TransformDebug] ConvexClient.transformSelection aborted: empty input commandLen=%ld selectedLen=%ld",
                normalizedCommand.count,
                normalizedSelectedText.count
            )
            return .failure(.emptyInput)
        }

        // Self-heal: if token is missing, attempt a refresh before giving up
        if resolvedCloudBearerToken == nil {
            _ = await authManager.refreshSessionIfPossible()
        }

        guard canPerformCloudRequest() else {
            NSLog("[TransformDebug] ConvexClient.transformSelection blocked: no auth token")
            return .failure(.signInRequired)
        }

        let lengthPolicy = CloudProcessingSupport.selectionTransformLengthPolicy(
            command: normalizedCommand,
            selectedText: normalizedSelectedText
        )
        let transformRouting = routing ?? CloudProcessingSupport.selectionTransformRouting(
            command: normalizedCommand,
            selectedText: normalizedSelectedText
        )
        let modelRoute: CloudTextModelRoute? = transformRouting.route == .advanced
            ? .selectionTransformAdvanced
            : nil
        let requestTimeoutMs = CloudTimeouts.selectionTransform(for: transformRouting.route)
        let normalizedWindowTitle = windowTitle?.trimmedNilIfEmpty ?? appName?.trimmedNilIfEmpty ?? ""
        let appKey = CloudProcessingSupport.normalizeAppKey(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        // Don't send dictionary terms or recent texts for transforms — they're
        // for fixing STT errors in dictation cleanup, not for rewriting
        // already-written text. Including them causes the LLM to inject
        // the terms/content into its output.
        let baseArgs = cloudContextArgs(
            userID: userID,
            windowTitle: normalizedWindowTitle,
            dictionaryTerms: [],
            appKey: appKey,
            recentTexts: []
        )

        // Try primary endpoint, then two legacy fallbacks
        let endpoints: [CloudTextAttempt] = {
            var primary = baseArgs
            primary["command"] = normalizedCommand
            primary["selectedText"] = normalizedSelectedText
            primary["transformIntent"] = lengthPolicy.intent.rawValue
            // Every user gets the full-length output policy; the server still
            // expects an accessTier hint on the request.
            primary["accessTier"] = "pro"
            primary["maxOutputCharacters"] = lengthPolicy.maxOutputCharacters
            primary["maxOutputTokens"] = lengthPolicy.approximateMaxOutputTokens
            if let modelRoute {
                primary["modelRoute"] = modelRoute.rawValue
            }

            var legacy = baseArgs
            legacy["transcript"] = normalizedSelectedText
            legacy["mode"] = "selection_transform"
            legacy["instruction"] = normalizedCommand

            let transcript = CloudProcessingSupport.buildSelectionTransformTranscript(
                command: normalizedCommand,
                selectedText: normalizedSelectedText
            )
            var cleanup = baseArgs
            cleanup["transcript"] = transcript

            var attempts = [
                CloudTextAttempt(path: "cloudProcessing:transformSelection", args: primary, timeoutMs: requestTimeoutMs),
                CloudTextAttempt(path: "cloudProcessing:processTranscript", args: legacy, timeoutMs: requestTimeoutMs),
            ]
            if !transcript.isEmpty {
                attempts.append(CloudTextAttempt(path: "cloudProcessing:processTranscript", args: cleanup, timeoutMs: requestTimeoutMs))
            }
            return attempts
        }()

        NSLog(
            "[TransformDebug] ConvexClient.transformSelection starting commandLen=%ld selectedLen=%ld appKey=%@ route=%@ reason=%@ endpoints=%ld",
            normalizedCommand.count,
            normalizedSelectedText.count,
            appKey,
            transformRouting.route.rawValue,
            transformRouting.reason,
            endpoints.count
        )

        let transformStartedAt = Date()

        func sanitize(_ response: CloudTextResponse) -> (accepted: Bool, text: String, reason: String?) {
            CloudProcessingSupport.sanitizeSelectionTransformOutput(
                selectedText: normalizedSelectedText,
                result: response.text,
                command: normalizedCommand,
                lengthPolicy: lengthPolicy
            )
        }

        func captureUsed(path: String, response: CloudTextResponse, fallbackReason: String?, includeModelRoute: Bool = true) {
            AnalyticsManager.shared.capture("cloud_processing_used", properties: cloudProcessingUsedProperties(
                path: path,
                appKey: appKey,
                clientDurationMs: Self.millisecondsSince(transformStartedAt),
                serverDurationMs: response.durationMs,
                fallbackReason: fallbackReason,
                selectionTransformRoute: transformRouting,
                modelRoute: includeModelRoute ? modelRoute : nil
            ))
        }

        func captureRejected(path: String, reason: String, fallbackReason: String?, includeModelRoute: Bool = true) {
            AnalyticsManager.shared.capture("cloud_processing_failed", properties: cloudProcessingFailedProperties(
                path: path,
                appKey: appKey,
                clientDurationMs: Self.millisecondsSince(transformStartedAt),
                error: nil,
                fallbackReason: fallbackReason,
                sanitizerRejectReason: reason,
                selectionTransformRoute: transformRouting,
                modelRoute: includeModelRoute ? modelRoute : nil
            ))
        }

        var lastError: Error?
        var didRetrySanitizerFailure = false
        for (i, endpoint) in endpoints.enumerated() {
            let fallbackReason: String? = i == 0 ? nil : "primary_endpoint_failed"
            do {
                let response = try await runCloudTextAttempt(endpoint)
                let sanitized = sanitize(response)
                if sanitized.accepted {
                    NSLog("[TransformDebug] endpoint success path=%@ responseLen=%ld", endpoint.path, sanitized.text.count)
                    captureUsed(path: endpoint.path, response: response, fallbackReason: fallbackReason)
                    return .success(sanitized.text)
                }

                let reason = sanitized.reason ?? "unknown"
                NSLog("[TransformDebug] endpoint rejected path=%@ reason=%@", endpoint.path, reason)
                if i == 0,
                   !didRetrySanitizerFailure,
                   Self.shouldRetrySelectionTransformSanitizerFailure(reason) {
                    didRetrySanitizerFailure = true
                    var retryArgs = endpoint.args
                    retryArgs["retryReason"] = reason
                    retryArgs["strictReplacementOnly"] = true
                    retryArgs["command"] = Self.strictSelectionTransformRetryCommand(
                        command: normalizedCommand,
                        reason: reason,
                        maxOutputCharacters: lengthPolicy.maxOutputCharacters
                    )
                    do {
                        let retryResponse = try await runCloudTextAttempt(CloudTextAttempt(
                            path: endpoint.path,
                            args: retryArgs,
                            timeoutMs: requestTimeoutMs
                        ))
                        let retrySanitized = sanitize(retryResponse)
                        if retrySanitized.accepted {
                            NSLog(
                                "[TransformDebug] endpoint retry success path=%@ responseLen=%ld reason=%@",
                                endpoint.path,
                                retrySanitized.text.count,
                                reason
                            )
                            captureUsed(path: endpoint.path, response: retryResponse, fallbackReason: "sanitizer_retry_\(reason)")
                            return .success(retrySanitized.text)
                        }
                        NSLog(
                            "[TransformDebug] endpoint retry rejected path=%@ originalReason=%@ retryReason=%@",
                            endpoint.path,
                            reason,
                            retrySanitized.reason ?? "unknown"
                        )
                    } catch {
                        NSLog(
                            "[TransformDebug] endpoint retry failed path=%@ reason=%@ error=%@",
                            endpoint.path,
                            reason,
                            String(describing: error)
                        )
                    }
                }
                captureRejected(path: endpoint.path, reason: reason, fallbackReason: fallbackReason)
                return .failure(.outputRejected(reason))
            } catch {
                lastError = error
                let errorText = String(describing: error)
                NSLog("[TransformDebug] endpoint failed path=%@ error=%@", endpoint.path, errorText)
                if CloudErrorClassifier.isDailyLimit(errorText) {
                    break
                }
                if i == 0,
                   modelRoute != nil,
                   Self.shouldRetrySelectionTransformWithoutModelRoute(errorText: errorText) {
                    var retryArgs = endpoint.args
                    retryArgs.removeValue(forKey: "modelRoute")
                    NSLog("[TransformDebug] retrying transform without unsupported modelRoute path=%@", endpoint.path)
                    do {
                        let retryResponse = try await runCloudTextAttempt(CloudTextAttempt(
                            path: endpoint.path,
                            args: retryArgs,
                            timeoutMs: requestTimeoutMs
                        ))
                        let retrySanitized = sanitize(retryResponse)
                        if retrySanitized.accepted {
                            captureUsed(
                                path: endpoint.path,
                                response: retryResponse,
                                fallbackReason: "model_route_unsupported",
                                includeModelRoute: false
                            )
                            return .success(retrySanitized.text)
                        }
                        let reason = retrySanitized.reason ?? "unknown"
                        captureRejected(
                            path: endpoint.path,
                            reason: reason,
                            fallbackReason: "model_route_unsupported",
                            includeModelRoute: false
                        )
                        return .failure(.outputRejected(reason))
                    } catch {
                        lastError = error
                        NSLog(
                            "[TransformDebug] transform retry without modelRoute failed path=%@ error=%@",
                            endpoint.path,
                            String(describing: error)
                        )
                    }
                }
            }
        }

        if let lastError {
            NSLog("[TransformDebug] all endpoints failed finalError=%@", String(describing: lastError))
            let errorText = String(describing: lastError)
            AnalyticsManager.shared.capture("cloud_processing_failed", properties: cloudProcessingFailedProperties(
                path: "cloudProcessing:transformSelection",
                appKey: appKey,
                clientDurationMs: Self.millisecondsSince(transformStartedAt),
                error: lastError,
                fallbackReason: CloudErrorClassifier.isDailyLimit(errorText) ? "daily_limit_reached" : "all_endpoints_failed",
                selectionTransformRoute: transformRouting,
                modelRoute: modelRoute
            ))
            SentryManager.shared.cloudProcessingError(path: "cloudProcessing:transformSelection", error: lastError)
            if CloudErrorClassifier.isDailyLimit(errorText) {
                return .failure(.serverError("Daily free cloud processing limit reached."))
            }
            if case ConvexError.sessionExpired = lastError {
                return .failure(.signInRequired)
            }
        }
        return .failure(.serverError(lastError?.localizedDescription ?? "All endpoints failed"))
    }

    nonisolated static func shouldRetrySelectionTransformSanitizerFailure(_ reason: String) -> Bool {
        switch reason {
        case "too-long", "command-echo", "assistant-response", "transform-explanation", "empty-output":
            return true
        default:
            return false
        }
    }

    nonisolated static func selectionTransformTimeoutMs(
        for route: CloudProcessingSupport.SelectionTransformRouting.Route
    ) -> Int {
        CloudTimeouts.selectionTransform(for: route)
    }

    nonisolated static func shouldRetrySelectionTransformWithoutModelRoute(errorText: String) -> Bool {
        CloudErrorClassifier.hasExtraFieldValidationError(errorText, fields: ["modelRoute"])
    }

    nonisolated static func strictSelectionTransformRetryCommand(
        command: String,
        reason: String,
        maxOutputCharacters: Int
    ) -> String {
        """
        \(command)

        Retry because the previous response was rejected: \(reason).
        Return only the replacement text for the selected text.
        Do not repeat this instruction.
        Do not explain the rewrite.
        Do not include before/after labels.
        Keep the output under \(maxOutputCharacters) characters unless the selected text itself requires that much space.
        """
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
