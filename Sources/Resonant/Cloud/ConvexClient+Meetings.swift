import Foundation

struct MeetingRecapDecision: Equatable {
    let text: String
    let owner: String?

    init(text: String, owner: String? = nil) {
        self.text = text
        self.owner = owner
    }
}

struct MeetingRecapActionItem: Equatable {
    let text: String
    let owner: String?
    let dueDate: String?

    init(text: String, owner: String? = nil, dueDate: String? = nil) {
        self.text = text
        self.owner = owner
        self.dueDate = dueDate
    }
}

struct MeetingRecapPayload: Equatable {
    let meetingTitle: String
    let meetingStartedAt: Date?
    let summary: String
    let decisions: [MeetingRecapDecision]
    let actionItems: [MeetingRecapActionItem]
    let attendees: [String]
    let transcriptExcerpt: String?
}

struct MeetingRecapShareResult: Equatable {
    let recapId: String
    let shareId: String
    let url: URL
}

struct MeetingCompletionEmailResult: Equatable {
    let deliveredTo: String?
}

enum MeetingRecapPublicLinkDelivery: String, Equatable {
    case copyLink = "copy_public_link"
    case email = "email_public_link"
}

enum MeetingRecapSharePolicy {
    static let defaultExpirationDays = 14

    static func normalizedExpirationDays(_ days: Int) -> Int {
        max(1, days)
    }
}

// MARK: - Meeting summaries + recap shares

extension ConvexClient {
    struct RecapShareResponse: Decodable {
        let shareId: String
        let token: String
        let url: String
    }

    struct MeetingCompletionEmailResponse: Decodable {
        let deliveredTo: String?
    }

    /// Typed meeting summarization. Falls back to the legacy memo endpoint
    /// when the dedicated summary function is missing on the backend.
    func summarizeMeetingDetailed(
        transcript: String,
        appName: String?,
        durationSeconds: Double,
        style: MeetingSummaryStyle = .standard
    ) async -> Result<String, CloudProcessingFailure> {
        guard canPerformCloudRequest() else {
            return .failure(resolvedCloudBearerToken == nil ? .signInRequired : .cloudUnavailable)
        }
        guard let userID = resolvedUserID else {
            return .failure(.signInRequired)
        }

        let durationMin = max(1, Int(durationSeconds / 60))
        let meetingTranscript = Self.meetingSummaryTranscriptWindow(transcript)

        let legacyPrompt = """
        \(style.promptInstructions)

        Meeting app: \(appName ?? "Unknown")
        Duration: \(durationMin) minutes

        Transcript:
        \(meetingTranscript)
        """

        let dedicatedPath = "cloudProcessing:processMeetingSummary"
        let legacyLabel = "cloudProcessing:processMemo(meeting-summary)"
        let startedAt = Date()

        func deliver(_ response: CloudTextResponse, path: String, fallbackReason: String? = nil) -> Result<String, CloudProcessingFailure> {
            AnalyticsManager.shared.capture("cloud_processing_used", properties: cloudProcessingUsedProperties(
                path: path,
                appKey: nil,
                clientDurationMs: Self.millisecondsSince(startedAt),
                serverDurationMs: response.durationMs,
                fallbackReason: fallbackReason
            ))
            guard let text = response.text.trimmedNilIfEmpty else {
                return .failure(.outputRejected(reason: "empty-output"))
            }
            return .success(text)
        }

        func failed(_ error: Error, path: String, fallbackReason: String?) -> Result<String, CloudProcessingFailure> {
            AnalyticsManager.shared.capture("cloud_processing_failed", properties: cloudProcessingFailedProperties(
                path: path,
                appKey: nil,
                clientDurationMs: Self.millisecondsSince(startedAt),
                error: error,
                fallbackReason: fallbackReason
            ))
            SentryManager.shared.cloudProcessingError(path: path, error: error)
            return .failure(CloudProcessingFailure.classify(error))
        }

        do {
            let response = try await runCloudTextAttempt(CloudTextAttempt(
                path: dedicatedPath,
                args: [
                    "userId": userID,
                    "transcript": meetingTranscript,
                    "appName": appName ?? "",
                    "durationSeconds": durationSeconds,
                    "style": style.rawValue
                ],
                timeoutMs: CloudTimeouts.meetingSummaryMs
            ))
            return deliver(response, path: dedicatedPath)
        } catch {
            guard CloudErrorClassifier.isFunctionNotFound(String(describing: error), path: dedicatedPath) else {
                return failed(error, path: dedicatedPath, fallbackReason: nil)
            }
            do {
                let response = try await runCloudTextAttempt(CloudTextAttempt(
                    path: "cloudProcessing:processMemo",
                    sentryLabel: legacyLabel,
                    args: [
                        "userId": userID,
                        "transcript": legacyPrompt
                    ],
                    timeoutMs: CloudTimeouts.meetingSummaryLegacyMs
                ))
                return deliver(response, path: legacyLabel, fallbackReason: "meeting_summary_endpoint_unavailable")
            } catch {
                return failed(error, path: legacyLabel, fallbackReason: "meeting_summary_endpoint_unavailable")
            }
        }
    }

    func summarizeMeeting(
        transcript: String,
        appName: String?,
        durationSeconds: Double,
        style: MeetingSummaryStyle = .standard
    ) async -> String? {
        try? await summarizeMeetingDetailed(
            transcript: transcript,
            appName: appName,
            durationSeconds: durationSeconds,
            style: style
        ).get()
    }

    func createMeetingRecapShare(
        payload: MeetingRecapPayload,
        expiresInDays: Int = MeetingRecapSharePolicy.defaultExpirationDays
    ) async throws -> MeetingRecapShareResult {
        if resolvedCloudBearerToken == nil {
            _ = await authManager.refreshSessionIfPossible()
        }

        let expirationDays = MeetingRecapSharePolicy.normalizedExpirationDays(expiresInDays)
        let recapId: String = try await request(
            type: .mutation,
            path: "growth:createMeetingRecap",
            args: Self.meetingRecapArgs(from: payload),
            authorizationMode: .requiredConvexBearer
        )

        let share: RecapShareResponse = try await request(
            type: .mutation,
            path: "growth:createRecapShare",
            args: [
                "recapId": recapId,
                "audience": "attendee",
                "expiresInDays": expirationDays,
                "includeTranscriptExcerpt": payload.transcriptExcerpt?.trimmedNilIfEmpty != nil
            ],
            authorizationMode: .requiredConvexBearer
        )

        return MeetingRecapShareResult(
            recapId: recapId,
            shareId: share.shareId,
            url: URL(string: share.url)
                ?? Self.meetingRecapShareURL(
                    forToken: share.token,
                    baseURL: hostedServicesConfiguration?.authBaseURL
                        ?? AppEnvironment.unavailableAuthBaseURL
                )
            ?? AppEnvironment.unavailableAuthBaseURL
        )
    }

    func sendMeetingCompletionEmail(
        payload: MeetingCompletionEmailPayload
    ) async throws -> MeetingCompletionEmailResult {
        if resolvedCloudBearerToken == nil {
            _ = await authManager.refreshSessionIfPossible()
        }
        guard authManager.userEmail?.trimmedNilIfEmpty != nil else {
            throw ConvexError.serverError("Signed-in account has no email address.")
        }

        let response: MeetingCompletionEmailResponse = try await request(
            type: .action,
            path: "growth:sendMeetingCompletionEmail",
            args: Self.meetingCompletionEmailArgs(from: payload),
            authorizationMode: .requiredConvexBearer,
            timeoutMs: CloudTimeouts.meetingCompletionEmailMs
        )
        return MeetingCompletionEmailResult(deliveredTo: response.deliveredTo)
    }

    nonisolated static func meetingRecapShareURL(
        forToken token: String,
        baseURL: URL = AppEnvironment.unavailableAuthBaseURL
    ) -> URL? {
        var components = URLComponents(
            url: baseURL.appending(path: "recap").appending(path: token),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "utm_source", value: "shared_recap"),
            URLQueryItem(name: "utm_medium", value: "product_share"),
            URLQueryItem(name: "utm_campaign", value: "meeting_recap")
        ]
        return components?.url
    }

    /// Windows very long transcripts down to evenly-spaced excerpts so the
    /// summary prompt stays under the model context limit.
    nonisolated static func meetingSummaryTranscriptWindow(
        _ transcript: String,
        maxCharacters: Int = 180_000
    ) -> String {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxCharacters else { return cleaned }

        let segmentCount = 6
        let segmentSize = max(1, maxCharacters / segmentCount)
        let omittedCharacters = max(0, cleaned.count - (segmentSize * segmentCount))
        let gapSize = max(0, omittedCharacters / max(segmentCount - 1, 1))
        var cursor = cleaned.startIndex
        var segments: [String] = []

        for index in 0..<segmentCount {
            guard cursor < cleaned.endIndex else { break }
            let remaining = cleaned.distance(from: cursor, to: cleaned.endIndex)
            let length = min(segmentSize, remaining)
            let end = cleaned.index(cursor, offsetBy: length, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            segments.append(String(cleaned[cursor..<end]))
            guard index < segmentCount - 1 else { break }
            cursor = cleaned.index(end, offsetBy: gapSize, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
        }

        return segments.enumerated()
            .map { index, segment in
                "[Transcript excerpt \(index + 1) of \(segments.count)]\n\(segment)"
            }
            .joined(separator: "\n\n[... transcript omitted between excerpts for length ...]\n\n")
    }

    private nonisolated static func meetingRecapArgs(from payload: MeetingRecapPayload) -> [String: Any] {
        var args: [String: Any] = [
            "meetingTitle": trimmed(payload.meetingTitle, limit: 120, fallback: "Meeting recap"),
            "summary": trimmed(payload.summary, limit: 4_000, fallback: "Meeting recap"),
            "decisions": payload.decisions.prefix(12).compactMap { decisionObject(from: $0) },
            "actionItems": payload.actionItems.prefix(20).compactMap { actionItemObject(from: $0) },
            "attendees": uniqueTrimmedStrings(payload.attendees, limit: 50, maxCharacters: 120)
        ]

        if let startedAt = payload.meetingStartedAt {
            args["meetingStartedAt"] = Int(startedAt.timeIntervalSince1970 * 1000)
        }

        if let transcriptExcerpt = payload.transcriptExcerpt?.trimmedNilIfEmpty {
            args["transcriptExcerpt"] = trimmed(transcriptExcerpt, limit: 8_000, fallback: "")
        }

        return args
    }

    nonisolated static func meetingCompletionEmailArgs(
        from payload: MeetingCompletionEmailPayload
    ) -> [String: Any] {
        // No recipient address is accepted from the client. The backend must
        // derive the only destination from the authenticated account.
        var args: [String: Any] = [
            "recipientScope": "authenticated_user",
            "meetingId": payload.meetingId,
            "meetingTitle": trimmed(payload.meetingTitle, limit: 160, fallback: "Meeting"),
            "startedAt": Int(payload.startedAt.timeIntervalSince1970 * 1000),
            "endedAt": Int(payload.endedAt.timeIntervalSince1970 * 1000),
            "durationSeconds": payload.durationSeconds,
            "transcript": trimmed(payload.transcript, limit: 500_000, fallback: "")
        ]

        if let detectedApp = payload.detectedApp?.trimmedNilIfEmpty {
            args["detectedApp"] = trimmed(detectedApp, limit: 120, fallback: "")
        }
        if let conferencingURL = payload.conferencingURL?.trimmedNilIfEmpty {
            args["conferencingURL"] = trimmed(conferencingURL, limit: 2_000, fallback: "")
        }
        if let markdownPath = payload.markdownPath?.trimmedNilIfEmpty {
            args["markdownPath"] = trimmed(markdownPath, limit: 2_000, fallback: "")
        }

        return args
    }

    private nonisolated static func decisionObject(from decision: MeetingRecapDecision) -> [String: Any]? {
        guard let text = decision.text.trimmedNilIfEmpty else { return nil }
        var object: [String: Any] = ["text": trimmed(text, limit: 500, fallback: "Decision")]
        if let owner = decision.owner?.trimmedNilIfEmpty {
            object["owner"] = trimmed(owner, limit: 120, fallback: "")
        }
        return object
    }

    private nonisolated static func actionItemObject(from item: MeetingRecapActionItem) -> [String: Any]? {
        guard let text = item.text.trimmedNilIfEmpty else { return nil }
        var object: [String: Any] = [
            "text": trimmed(text, limit: 500, fallback: "Action item"),
            "status": "open"
        ]
        if let owner = item.owner?.trimmedNilIfEmpty {
            object["owner"] = trimmed(owner, limit: 120, fallback: "")
        }
        if let dueDate = item.dueDate?.trimmedNilIfEmpty {
            object["dueDate"] = trimmed(dueDate, limit: 60, fallback: "")
        }
        return object
    }

    private nonisolated static func uniqueTrimmedStrings(
        _ values: [String],
        limit: Int,
        maxCharacters: Int
    ) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let trimmedValue = trimmed(value, limit: maxCharacters, fallback: "")
            guard !trimmedValue.isEmpty else { continue }
            let key = trimmedValue.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(trimmedValue)
            if output.count >= limit { break }
        }
        return output
    }

    nonisolated static func trimmed(_ value: String, limit: Int, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : trimmed
        guard resolved.count > limit else { return resolved }
        return String(resolved.prefix(limit))
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
