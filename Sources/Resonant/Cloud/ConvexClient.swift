import Foundation
import Observation

/// Convex HTTP client for account state and Groq-backed cloud processing.
///
/// This file owns the transport layer (request/decode/auth retry), the
/// instrumented cloud-text attempt runner. Domain endpoints live in the
/// ConvexClient+<Domain> files:
/// Dictation, SelectionTransform, Journal, Meetings, WorkspaceSync.
@MainActor
@Observable
final class ConvexClient {
    enum CloudTextModelRoute: String, Sendable {
        case meetingSummary = "meeting_summary"
        case selectionTransformAdvanced = "selection_transform_advanced"
    }

    let authManager: AuthManager
    let settings: SettingsManager
    let hostedServicesConfiguration: HostedServicesConfiguration?
    let baseURL: URL

    // Shared session across all Convex requests so TLS/HTTP connections get
    // reused instead of being re-handshaked per call. Per-request timeouts
    // are set via URLRequest.timeoutInterval rather than per-session config.
    let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(
        authManager: AuthManager,
        settings: SettingsManager = .shared,
        hostedServicesConfiguration: HostedServicesConfiguration? = AppRuntime.hostedServicesConfiguration
    ) {
        self.authManager = authManager
        self.settings = settings
        self.hostedServicesConfiguration = hostedServicesConfiguration
        self.baseURL = hostedServicesConfiguration?.convexCloudURL
            ?? AppEnvironment.unavailableConvexCloudURL
    }

    // MARK: - Cloud request gating

    /// Cloud endpoints need a signed-in session; that is the only client-side
    /// requirement — there is no entitlement or usage metering.
    func canPerformCloudRequest() -> Bool {
        hostedServicesConfiguration != nil && resolvedCloudBearerToken != nil
    }

    // MARK: - Cloud text attempt runner

    /// Runs one cloud-text action with Sentry start/end breadcrumbs. All cloud
    /// text endpoints (cleanup, repair,
    /// transform, memo, meeting summary) go through here.
    func runCloudTextAttempt(_ attempt: CloudTextAttempt) async throws -> CloudTextResponse {
        let label = attempt.resolvedSentryLabel
        let startedAt = Date()
        SentryManager.shared.cloudProcessingStart(path: label)
        do {
            let response: CloudTextResponse = try await request(
                type: .action,
                path: attempt.path,
                args: attempt.args,
                authorizationMode: .requiredConvexBearer,
                timeoutMs: attempt.timeoutMs
            )
            SentryManager.shared.cloudProcessingEnd(
                path: label,
                durationMs: response.durationMs ?? Self.millisecondsSince(startedAt)
            )
            return response
        }
    }

    nonisolated static func millisecondsSince(_ date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1000))
    }

    // MARK: - Request helpers

    func request<T: Decodable>(
        type: RequestType,
        path: String,
        args: [String: Any],
        authorizationMode: AuthorizationMode = .requiredConvexBearer,
        timeoutMs: Int? = nil
    ) async throws -> T {
        guard hostedServicesConfiguration != nil else {
            throw ConvexError.httpError("Hosted services are not configured in this build.")
        }
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "path": path,
            "args": args
        ])

        let bearerToken: String?
        switch authorizationMode {
        case .none:
            bearerToken = nil
        case .requiredConvexBearer:
            guard let token = resolvedCloudBearerToken else {
                throw ConvexError.sessionExpired("Cloud access requires signing in again.")
            }
            bearerToken = token
        }
        let initialResponse = try await performRequest(
            type: type,
            requestBody: requestBody,
            bearerToken: bearerToken,
            timeoutMs: timeoutMs
        )

        if case .requiredConvexBearer = authorizationMode {
            switch Self.authorizationFailureDisposition(
                statusCode: initialResponse.response.statusCode,
                responseBody: initialResponse.data
            ) {
            case .sessionExpired:
                let didRefresh = await authManager.refreshSessionIfPossible()
                guard didRefresh, let refreshedBearerToken = resolvedCloudBearerToken else {
                    // Propagate to the caller; each optional hosted action owns
                    // its user-facing session-expiry behavior.
                    throw ConvexError.sessionExpired("Your session expired. Sign in again.")
                }

                let retryResponse = try await performRequest(
                    type: type,
                    requestBody: requestBody,
                    bearerToken: refreshedBearerToken,
                    timeoutMs: timeoutMs
                )

                switch Self.authorizationFailureDisposition(
                    statusCode: retryResponse.response.statusCode,
                    responseBody: retryResponse.data
                ) {
                case .sessionExpired:
                    throw ConvexError.sessionExpired("Your session expired. Sign in again.")
                case .none:
                    return try decodeResponse(data: retryResponse.data, response: retryResponse.response)
                }
            case .none:
                break
            }
        }

        return try decodeResponse(data: initialResponse.data, response: initialResponse.response)
    }

    private func performRequest(
        type: RequestType,
        requestBody: Data,
        bearerToken: String?,
        timeoutMs: Int?
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: "api/\(type.rawValue)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let timeoutMs {
            request.timeoutInterval = TimeInterval(timeoutMs) / 1000
        }
        request.httpBody = requestBody

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ConvexError.httpError("Invalid Convex response")
        }

        return (data, http)
    }

    private func decodeResponse<T: Decodable>(
        data: Data,
        response: HTTPURLResponse
    ) throws -> T {
        guard (200...299).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown Convex error"
            throw ConvexError.httpError(message)
        }

        let json = try JSONSerialization.jsonObject(with: data)
        if let dictionary = json as? [String: Any],
           dictionary["status"] as? String == "error" {
            throw ConvexError.serverError(dictionary["errorMessage"] as? String ?? "Unknown Convex error")
        }

        let value = (json as? [String: Any])?["value"] ?? json
        let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: encoded)
    }

    nonisolated static func convexBearerToken(from rawToken: String?) -> String? {
        guard let token = rawToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }

        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        return token
    }

    nonisolated static func shouldInvalidateSession(statusCode: Int, responseBody: Data) -> Bool {
        authorizationFailureDisposition(statusCode: statusCode, responseBody: responseBody) == .sessionExpired
    }

    private nonisolated static func authorizationFailureDisposition(
        statusCode: Int,
        responseBody: Data
    ) -> AuthorizationFailureDisposition {
        let details = authFailureDetails(from: responseBody)

        // Convex returns HTTP 200 with error payload for auth failures (e.g. expired token,
        // OIDC verification failure) so we must check the body content regardless of status code.
        if details.contains(where: { detail in
            detail.contains("authentication required")
                || detail.contains("authenticated account not found")
                || detail.contains("oidc")
                || detail.contains("could not verify")
        }) {
            return .sessionExpired
        }

        guard [400, 401, 403].contains(statusCode) else { return .none }

        if details.contains(where: { detail in
            detail.contains("token expired")
                || detail.contains("jwt expired")
                || detail.contains("expired token")
        }) {
            return .sessionExpired
        }

        if details.contains(where: { detail in
            detail.contains("invalidauthheader")
                || detail.contains("could not parse jwt")
                || (detail.contains("jwt") && detail.contains("invalid"))
        }) {
            return .sessionExpired
        }

        if statusCode == 401,
           details.contains(where: { detail in
               detail.contains("unauthorized")
                   || detail.contains("authentication")
                   || detail.contains("sign in")
           }) {
            return .sessionExpired
        }

        return .none
    }

    /// The locally-stored Convex user ID, obtained from the auth callback URL at sign-in.
    var resolvedUserID: String? {
        authManager.userId?.trimmedNilIfEmpty
    }

    var resolvedCloudBearerToken: String? {
        Self.convexBearerToken(from: authManager.cloudAuthToken)
    }

    private nonisolated static func authFailureDetails(from responseBody: Data) -> [String] {
        guard !responseBody.isEmpty else { return [] }

        var details: [String] = []
        if let responseText = String(data: responseBody, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !responseText.isEmpty {
            details.append(responseText.lowercased())
        }

        if let json = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] {
            for key in ["code", "message", "error", "errorMessage"] {
                if let value = json[key] as? String {
                    details.append(value.lowercased())
                }
            }
        }

        return details
    }

    // MARK: - Shared args + analytics property builders

    func cloudContextArgs(
        userID: String,
        windowTitle: String,
        dictionaryTerms: [String],
        appKey: String,
        recentTexts: [String],
        styleHint: String? = nil
    ) -> [String: Any] {
        var args: [String: Any] = [
            "userId": userID,
            "language": currentLanguageCode
        ]

        if !windowTitle.isEmpty {
            args["windowTitle"] = windowTitle
        }
        if !dictionaryTerms.isEmpty {
            args["dictionaryTerms"] = Array(dictionaryTerms.prefix(50))
        }
        if appKey != "other" {
            args["appKey"] = appKey
        }
        if !recentTexts.isEmpty {
            args["recentTexts"] = Array(recentTexts.prefix(5))
        }
        if let styleHint = styleHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !styleHint.isEmpty {
            args["styleHint"] = String(styleHint.prefix(500))
        }

        return args
    }

    func cloudProcessingUsedProperties(
        path: String,
        appKey: String?,
        clientDurationMs: Int,
        serverDurationMs: Int?,
        fallbackReason: String? = nil,
        selectionTransformRoute: CloudProcessingSupport.SelectionTransformRouting? = nil,
        modelRoute: CloudTextModelRoute? = nil
    ) -> [String: Any] {
        var props: [String: Any] = [
            "path": path,
            "duration_ms_client": clientDurationMs
        ]
        if let appKey { props["app_key"] = appKey }
        if let serverDurationMs { props["duration_ms_server"] = serverDurationMs }
        if let fallbackReason { props["fallback_reason"] = fallbackReason }
        if let selectionTransformRoute {
            props["selection_transform_route"] = selectionTransformRoute.route.rawValue
            props["selection_transform_route_reason"] = selectionTransformRoute.reason
        }
        if let modelRoute { props["model_route"] = modelRoute.rawValue }
        return props
    }

    func cloudProcessingFailedProperties(
        path: String,
        appKey: String?,
        clientDurationMs: Int,
        error: Error?,
        fallbackReason: String?,
        sanitizerRejectReason: String? = nil,
        selectionTransformRoute: CloudProcessingSupport.SelectionTransformRouting? = nil,
        modelRoute: CloudTextModelRoute? = nil
    ) -> [String: Any] {
        var props: [String: Any] = [
            "path": path,
            "duration_ms_client": clientDurationMs
        ]
        if let appKey { props["app_key"] = appKey }
        if let error {
            props.merge(AnalyticsEventSanitizer.errorProperties(for: error)) { _, newValue in newValue }
        }
        if let fallbackReason { props["fallback_reason"] = fallbackReason }
        if let sanitizerRejectReason { props["sanitizer_reject_reason"] = sanitizerRejectReason }
        if let selectionTransformRoute {
            props["selection_transform_route"] = selectionTransformRoute.route.rawValue
            props["selection_transform_route_reason"] = selectionTransformRoute.reason
        }
        if let modelRoute { props["model_route"] = modelRoute.rawValue }
        return props
    }

    private var currentLanguageCode: String {
        Locale.preferredLanguages.first?
            .split(separator: "-")
            .first
            .map(String.init) ?? "en"
    }
}

// MARK: - Transport types

extension ConvexClient {
    enum RequestType: String {
        case query
        case mutation
        case action
    }

    enum AuthorizationMode {
        case none
        case requiredConvexBearer
    }

    private enum AuthorizationFailureDisposition {
        case none
        case sessionExpired
    }

    struct ConvexEmptyResponse: Decodable {
        init(from decoder: Decoder) throws {}
    }

    struct CloudTextResponse: Decodable {
        let text: String
        let durationMs: Int?
    }
}

enum ConvexError: LocalizedError {
    case httpError(String)
    case serverError(String)
    case sessionExpired(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let message), .serverError(let message), .sessionExpired(let message):
            return message
        }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
