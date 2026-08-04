import Foundation

/// Delivers bug reports to the Resonant support channel via Convex support relay.
@MainActor
final class TelegramReporter {

    struct DeliveryResult: Equatable {
        enum FailureReason: String {
            case invalidRequest = "invalid_request"
            case invalidResponse = "invalid_response"
            case httpStatus = "http_status"
            case relayRejected = "relay_rejected"
            case transport = "transport"
        }

        let delivered: Bool
        let attempts: Int
        let failureReason: FailureReason?
        let statusCode: Int?
        let message: String?
        let route: String?

        static func success(attempts: Int, route: String) -> DeliveryResult {
            DeliveryResult(
                delivered: true,
                attempts: attempts,
                failureReason: nil,
                statusCode: nil,
                message: nil,
                route: route
            )
        }

        static func failure(
            _ reason: FailureReason,
            attempts: Int,
            statusCode: Int? = nil,
            message: String? = nil
        ) -> DeliveryResult {
            DeliveryResult(
                delivered: false,
                attempts: attempts,
                failureReason: reason,
                statusCode: statusCode,
                message: message,
                route: nil
            )
        }
    }

    static let shared = TelegramReporter()

    private let baseURL: URL
    private let session: URLSession
    private let retryDelays: [Duration]

    private enum RelayRoute: String {
        case feedbackMutation = "feedback_mutation"
        case legacySupportAction = "legacy_support_action"
    }

    init(
        baseURL: URL = AppRuntime.appEnvironment.convexCloudURL(),
        session: URLSession = .shared,
        retryDelays: [Duration] = [.milliseconds(400), .seconds(1)]
    ) {
        self.baseURL = baseURL
        self.session = session
        self.retryDelays = retryDelays
    }

    func sendBugReport(severity: String, description: String, reportID: String) async -> DeliveryResult {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let enrichedDescription = trimMessage("""
        \(trimmedDescription)

        Report: \(reportID)
        App: v\(version) build \(build)
        OS: \(osVersion)
        """)

        let primaryRequest: URLRequest
        do {
            primaryRequest = try legacySupportActionRequest(
                severity: severity,
                description: enrichedDescription,
                osVersion: osVersion,
                version: version,
                build: build
            )
        } catch {
            return .failure(.invalidRequest, attempts: 0, message: "Could not encode support report.")
        }

        let primaryResult = await deliverWithRetries(primaryRequest, route: .legacySupportAction)
        if primaryResult.delivered || !shouldAttemptFeedbackFallback(primaryResult) {
            return primaryResult
        }

        do {
            let fallbackRequest = try feedbackMutationRequest(
                severity: severity,
                description: enrichedDescription,
                reportID: reportID
            )
            let fallbackResult = await deliverWithRetries(fallbackRequest, route: .feedbackMutation)
            if fallbackResult.delivered {
                return DeliveryResult.success(
                    attempts: primaryResult.attempts + fallbackResult.attempts,
                    route: RelayRoute.feedbackMutation.rawValue
                )
            }
            return DeliveryResult.failure(
                fallbackResult.failureReason ?? primaryResult.failureReason ?? .transport,
                attempts: primaryResult.attempts + fallbackResult.attempts,
                statusCode: fallbackResult.statusCode ?? primaryResult.statusCode,
                message: fallbackResult.message ?? primaryResult.message
            )
        } catch {
            return primaryResult
        }
    }

    // MARK: - Private

    private func feedbackMutationRequest(
        severity: String,
        description: String,
        reportID: String
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/mutation"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": "feedback:submit",
            "args": [
                "kind": "bug",
                "severity": severity,
                "description": description,
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func legacySupportActionRequest(
        severity: String,
        description: String,
        osVersion: String,
        version: String,
        build: String
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/action"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": "support:submitBugReport",
            "args": [
                "severity": severity,
                "description": description,
                "appVersion": "v\(version) build \(build)",
                "osVersion": osVersion,
            ],
        ])
        return request
    }

    private func deliverWithRetries(_ request: URLRequest, route: RelayRoute) async -> DeliveryResult {
        var lastFailure = DeliveryResult.failure(.transport, attempts: 0)
        for attemptIndex in 0...(retryDelays.count) {
            let attempts = attemptIndex + 1
            let result = await deliver(request, attempts: attempts, route: route)
            if result.delivered {
                return result
            }

            lastFailure = result
            guard shouldRetry(result), attemptIndex < retryDelays.count else {
                return result
            }
            try? await Task.sleep(for: retryDelays[attemptIndex])
        }

        return lastFailure
    }

    private func deliver(_ request: URLRequest, attempts: Int, route: RelayRoute) async -> DeliveryResult {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse, attempts: attempts)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                return .failure(
                    .httpStatus,
                    attempts: attempts,
                    statusCode: httpResponse.statusCode,
                    message: responseMessage(from: data)
                )
            }

            if relayRejected(data) {
                return .failure(
                    .relayRejected,
                    attempts: attempts,
                    statusCode: httpResponse.statusCode,
                    message: responseMessage(from: data)
                )
            }

            return .success(attempts: attempts, route: route.rawValue)
        } catch {
            return .failure(
                .transport,
                attempts: attempts,
                message: AnalyticsEventSanitizer.errorKind(for: error)
            )
        }
    }

    private func shouldRetry(_ result: DeliveryResult) -> Bool {
        switch result.failureReason {
        case .transport:
            return true
        case .httpStatus:
            guard let statusCode = result.statusCode else { return false }
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        case .relayRejected:
            return true
        case .invalidRequest, .invalidResponse, nil:
            return false
        }
    }

    private func shouldAttemptFeedbackFallback(_ result: DeliveryResult) -> Bool {
        switch result.failureReason {
        case .httpStatus:
            return result.statusCode == 400 || result.statusCode == 404
        case .relayRejected:
            return true
        case .invalidRequest, .invalidResponse, .transport, nil:
            return false
        }
    }

    private func relayRejected(_ data: Data) -> Bool {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return payload["status"] as? String == "error"
    }

    private func responseMessage(from data: Data) -> String? {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorMessage = payload["errorMessage"] as? String {
                return trimMessage(errorMessage, maxLength: 240)
            }
            if let message = payload["message"] as? String {
                return trimMessage(message, maxLength: 240)
            }
        }

        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return trimMessage(text, maxLength: 240)
    }

    private func trimMessage(_ text: String, maxLength: Int = 3900) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 24)) + "\n\n[truncated for length]"
    }
}
