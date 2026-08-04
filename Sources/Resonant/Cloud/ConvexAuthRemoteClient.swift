import Foundation

struct ConvexAuthTokens: Decodable, Equatable {
    let token: String
    let refreshToken: String
}

struct ConvexAuthUser: Decodable, Equatable {
    let _id: String
    let email: String?
    let name: String?
}

enum ConvexPasswordSignInResult: Equatable {
    case signedIn(ConvexAuthTokens)
    case needsEmailVerification
}

enum ConvexAuthRemoteError: LocalizedError {
    case invalidRedirectURL
    case missingOAuthRedirect
    case missingTokens
    case missingCurrentUser
    case invalidCredentials
    case invalidVerificationCode
    case httpError(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidRedirectURL:
            return "The sign-in redirect URL was invalid."
        case .missingOAuthRedirect:
            return "The auth server did not return an OAuth redirect."
        case .missingTokens:
            return "The auth server did not return a session token."
        case .missingCurrentUser:
            return "Signed in, but could not load the current user."
        case .invalidCredentials:
            return "Incorrect email or password."
        case .invalidVerificationCode:
            return "Invalid or expired verification code."
        case .httpError(let message), .serverError(let message):
            return message
        }
    }
}

struct ConvexOAuthStart: Equatable {
    let redirectURL: URL
    let verifier: String
}

final class ConvexAuthRemoteClient {

    private struct SignInResponse: Decodable {
        let redirect: String?
        let verifier: String?
        let tokens: ConvexAuthTokens?
        let started: Bool?
    }

    private enum RequestType: String {
        case query
        case action
    }

    private let baseURL = AppRuntime.appEnvironment.convexCloudURL()
    private let calledBy = "resonant-macos-native"

    func startOAuthSignIn(provider: String, redirectTo: String) async throws -> ConvexOAuthStart {
        let response: SignInResponse = try await request(
            type: .action,
            path: "auth:signIn",
            args: [
                "provider": provider,
                "params": [
                    "redirectTo": redirectTo
                ],
                "calledBy": calledBy
            ],
            bearerToken: nil
        )

        guard let redirect = response.redirect,
              let verifier = response.verifier,
              let redirectURL = URL(string: redirect) else {
            throw ConvexAuthRemoteError.missingOAuthRedirect
        }

        return ConvexOAuthStart(redirectURL: redirectURL, verifier: verifier)
    }

    func completeOAuthSignIn(code: String, verifier: String) async throws -> ConvexAuthTokens {
        let response: SignInResponse = try await request(
            type: .action,
            path: "auth:signIn",
            args: [
                "params": [
                    "code": code
                ],
                "verifier": verifier,
                "calledBy": calledBy
            ],
            bearerToken: nil
        )

        guard let tokens = response.tokens else {
            throw ConvexAuthRemoteError.missingTokens
        }

        return tokens
    }

    func signInWithPassword(email: String, password: String) async throws -> ConvexPasswordSignInResult {
        let response: SignInResponse = try await request(
            type: .action,
            path: "auth:signIn",
            args: [
                "provider": "password",
                "params": [
                    "email": email,
                    "password": password,
                    "flow": "signIn"
                ],
                "calledBy": calledBy
            ],
            bearerToken: nil
        )

        if let tokens = response.tokens {
            return .signedIn(tokens)
        }

        if response.started == true {
            return .needsEmailVerification
        }

        throw ConvexAuthRemoteError.invalidCredentials
    }

    func verifyEmailCode(email: String, code: String) async throws -> ConvexAuthTokens {
        let response: SignInResponse = try await request(
            type: .action,
            path: "auth:signIn",
            args: [
                "provider": "password",
                "params": [
                    "email": email,
                    "code": code,
                    "flow": "email-verification"
                ],
                "calledBy": calledBy
            ],
            bearerToken: nil
        )

        guard let tokens = response.tokens else {
            throw ConvexAuthRemoteError.invalidVerificationCode
        }

        return tokens
    }

    // MARK: - Passwordless OTP (resend-otp provider)

    func sendSignInCode(email: String) async throws {
        let response: SignInResponse = try await request(
            type: .action,
            path: "auth:signIn",
            args: [
                "provider": "resend-otp",
                "params": ["email": email],
                "calledBy": calledBy
            ],
            bearerToken: nil
        )

        guard response.started == true else {
            throw ConvexAuthRemoteError.serverError("Could not send the sign-in code.")
        }
    }

    func verifySignInCode(email: String, code: String) async throws -> ConvexAuthTokens {
        let response: SignInResponse = try await request(
            type: .action,
            path: "auth:signIn",
            args: [
                "provider": "resend-otp",
                "params": ["email": email, "code": code],
                "calledBy": calledBy
            ],
            bearerToken: nil
        )

        guard let tokens = response.tokens else {
            throw ConvexAuthRemoteError.invalidVerificationCode
        }

        return tokens
    }

    func resendEmailVerificationCode(email: String) async throws {
        let response: SignInResponse = try await request(
            type: .action,
            path: "auth:signIn",
            args: [
                "provider": "password",
                "params": [
                    "email": email,
                    "flow": "email-verification"
                ],
                "calledBy": calledBy
            ],
            bearerToken: nil
        )

        guard response.started == true else {
            throw ConvexAuthRemoteError.serverError("Could not resend the verification code.")
        }
    }

    func refreshSession(refreshToken: String) async throws -> ConvexAuthTokens {
        let response: SignInResponse = try await request(
            type: .action,
            path: "auth:signIn",
            args: [
                "refreshToken": refreshToken,
                "calledBy": calledBy
            ],
            bearerToken: nil
        )

        guard let tokens = response.tokens else {
            throw ConvexAuthRemoteError.missingTokens
        }

        return tokens
    }

    func currentUser(bearerToken: String) async throws -> ConvexAuthUser {
        let user: ConvexAuthUser? = try await request(
            type: .query,
            path: "users:getCurrentUser",
            args: [:],
            bearerToken: bearerToken
        )

        guard let user else {
            throw ConvexAuthRemoteError.missingCurrentUser
        }

        return user
    }

    private func request<T: Decodable>(
        type: RequestType,
        path: String,
        args: [String: Any],
        bearerToken: String?
    ) async throws -> T {
        guard AppFeatureVisibility.hostedServices else {
            throw ConvexAuthRemoteError.httpError("Hosted authentication is not configured in this build.")
        }
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "path": path,
            "args": args
        ])

        var request = URLRequest(url: baseURL.appending(path: "api/\(type.rawValue)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = requestBody

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConvexAuthRemoteError.httpError("Invalid auth server response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown auth server error"
            throw ConvexAuthRemoteError.httpError(message)
        }

        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let dictionary = json as? [String: Any],
           dictionary["status"] as? String == "error" {
            throw ConvexAuthRemoteError.serverError(dictionary["errorMessage"] as? String ?? "Unknown auth server error")
        }

        let value = (json as? [String: Any])?["value"] ?? json
        let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: encoded)
    }
}
