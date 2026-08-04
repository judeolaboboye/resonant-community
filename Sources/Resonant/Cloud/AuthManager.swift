import Foundation
import AppKit
import AuthenticationServices
import CoreServices
import Observation

@MainActor
@Observable
final class AuthManager {

    enum OAuthProvider: String, CaseIterable, Identifiable {
        case google
        case github
        case apple

        var id: String { rawValue }

        var title: String {
            switch self {
            case .google:
                "Continue with Google"
            case .github:
                "Continue with GitHub"
            case .apple:
                "Continue with Apple"
            }
        }
    }

    enum EmailSignInResult: Equatable {
        case signedIn
        case needsEmailVerification
    }

    nonisolated static let callbackHost = "auth-callback"
    nonisolated static let nativeOAuthCallbackHost = "auth"
    nonisolated static let nativeOAuthCallbackPath = "/callback"
    nonisolated static let authCompletionHandoffPath = "/complete"
    nonisolated static let pendingAuthStateRetentionWindow: TimeInterval = 30
    private nonisolated static let stateQueryItemName = "state"
    private nonisolated static let redirectQueryItemName = "redirect"
    private nonisolated static let websiteTokenQueryItemName = "token"
    private nonisolated static let cloudTokenQueryItemNames = ["convexToken", "cloudToken", "cloudAuthToken"]
    private nonisolated static let pendingAuthStateDefaultsKey = "pendingDesktopAuthState"
    private nonisolated static let pendingAuthInitiatedAtDefaultsKey = "pendingDesktopAuthStartedAt"

    nonisolated static var preferredCallbackScheme: String {
        configuredCallbackSchemes(infoDictionary: Bundle.main.infoDictionary).first
            ?? preferredCallbackScheme(bundleIdentifier: Bundle.main.bundleIdentifier ?? AppRuntime.bundleIdentifier)
    }

    nonisolated static func preferredCallbackScheme(bundleIdentifier: String?) -> String {
        let normalizedBundleID = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedBundleID == "org.resonant.community.dev" {
            return "resonant-community-dev"
        }
        if normalizedBundleID == "org.resonant.community" {
            return "resonant-community"
        }
        if normalizedBundleID == "com.resonance.resonant.dev" || normalizedBundleID?.hasSuffix(".dev") == true {
            return "resonantmac-dev"
        }
        return "resonantmac"
    }

    nonisolated static func configuredCallbackSchemes(infoDictionary: [String: Any]?) -> [String] {
        guard let urlTypes = infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else {
            return []
        }
        return urlTypes.flatMap { urlType in
            (urlType["CFBundleURLSchemes"] as? [String] ?? []).compactMap { rawScheme in
                let scheme = rawScheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !scheme.isEmpty,
                      scheme.range(of: #"^[a-z][a-z0-9+.-]*$"#, options: .regularExpression) != nil else {
                    return nil
                }
                return scheme
            }
        }
    }

    private struct PendingAuthSession {
        let state: String
        let initiatedAt: Date
    }

    private enum OAuthFlowError: Equatable, LocalizedError {
        case authenticationSessionDidNotStart
        case missingCallbackURL
        case invalidCallbackURL
        case missingAuthorizationCode(String?)
        case authorizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .authenticationSessionDidNotStart:
                return "Could not start browser sign-in."
            case .missingCallbackURL:
                return "The browser did not return an auth callback."
            case .invalidCallbackURL:
                return "The browser returned an invalid auth callback."
            case .missingAuthorizationCode(let message):
                return message ?? "The auth callback did not include an authorization code."
            case .authorizationFailed(let message):
                return message
            }
        }
    }

    nonisolated static func isAppScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        let configured = configuredCallbackSchemes(infoDictionary: Bundle.main.infoDictionary)
        let compatible = [
            "resonantmac", "resonant", "resonantmac-dev", "resonant-dev",
            "resonant-community", "resonant-community-dev",
        ]
        return configured.contains(scheme) || compatible.contains(scheme)
    }

    nonisolated static var preferredCallbackURL: String {
        "\(preferredCallbackScheme)://\(callbackHost)"
    }

    nonisolated static var nativeOAuthCallbackScheme: String {
        preferredCallbackScheme
    }

    nonisolated static var nativeOAuthCallbackURL: URL {
        URL(string: "\(preferredCallbackScheme)://\(nativeOAuthCallbackHost)\(nativeOAuthCallbackPath)")!
    }

    nonisolated static var authCompletionHandoffURL: URL {
        URL(string: "\(preferredCallbackScheme)://\(nativeOAuthCallbackHost)\(authCompletionHandoffPath)")!
    }

    nonisolated static func nativeOAuthCallbackURL(bundleIdentifier: String?) -> URL {
        let scheme = preferredCallbackScheme(bundleIdentifier: bundleIdentifier)
        return URL(string: "\(scheme)://\(nativeOAuthCallbackHost)\(nativeOAuthCallbackPath)")!
    }

    nonisolated static func nativeOAuthCallbackURL(state: String, bundleIdentifier: String?) -> URL {
        var components = URLComponents(
            url: nativeOAuthCallbackURL(bundleIdentifier: bundleIdentifier),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: stateQueryItemName, value: state))
        components.queryItems = queryItems
        return components.url!
    }

    nonisolated static func authCompletionHandoffURL(bundleIdentifier: String?) -> URL {
        let scheme = preferredCallbackScheme(bundleIdentifier: bundleIdentifier)
        return URL(string: "\(scheme)://\(nativeOAuthCallbackHost)\(authCompletionHandoffPath)")!
    }

    nonisolated static func registerPreferredURLSchemeHandler() {
        guard AppRuntime.hasValidMainBundle else { return }

        let bundleURL = Bundle.main.bundleURL as CFURL
        let bundleIdentifier = (Bundle.main.bundleIdentifier ?? AppRuntime.bundleIdentifier) as CFString
        LSRegisterURL(bundleURL, true)

        let schemesToRegister = Set([preferredCallbackScheme])
        if #available(macOS 12.0, *) {
            for scheme in schemesToRegister {
                NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL,
                    toOpenURLsWithScheme: scheme
                ) { error in
                    if let error {
                        NSLog("Failed to register %@ URL handler: %@", scheme, error.localizedDescription)
                    }
                }
            }
        } else {
            for scheme in schemesToRegister {
                let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleIdentifier)
                if status != noErr {
                    NSLog("Failed to register %@ URL handler (status %d)", scheme, status)
                }
            }
        }
    }

    nonisolated static func loginURL(
        authBaseURL: String,
        state: String,
        redirect: String = preferredCallbackURL
    ) -> URL? {
        guard var components = URLComponents(string: "\(authBaseURL)/auth/app-login") else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: stateQueryItemName, value: state))
        queryItems.append(URLQueryItem(name: redirectQueryItemName, value: redirect))
        components.queryItems = queryItems
        return components.url
    }

    nonisolated static func isValidCallbackURL(_ url: URL, expectedState: String) -> Bool {
        guard isAppScheme(url),
              url.host == callbackHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              queryItemValue(named: stateQueryItemName, in: components) == expectedState
        else {
            return false
        }

        return true
    }

    nonisolated static func isAuthCompletionHandoffURL(_ url: URL) -> Bool {
        url.scheme == nativeOAuthCallbackScheme
            && url.host == nativeOAuthCallbackHost
            && url.path == authCompletionHandoffPath
    }

    nonisolated static func extractedCloudAuthToken(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        for key in cloudTokenQueryItemNames {
            let candidate = queryItemValue(named: key, in: components)
            if let bearer = ConvexClient.convexBearerToken(from: candidate) {
                return bearer
            }
        }

        let websiteToken = queryItemValue(named: websiteTokenQueryItemName, in: components)
        return ConvexClient.convexBearerToken(from: websiteToken)
    }

    nonisolated static func cloudTokenIssuer(from token: String?) -> String? {
        guard let token = ConvexClient.convexBearerToken(from: token) else {
            return nil
        }

        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (4 - payload.count % 4) % 4
        if paddingCount > 0 {
            payload += String(repeating: "=", count: paddingCount)
        }

        guard let payloadData = Data(base64Encoded: payload),
              let jsonObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        return (jsonObject["iss"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    nonisolated static func isCloudTokenCompatible(
        _ token: String?,
        expectedConvexCloudURL: URL
    ) -> Bool {
        guard let issuer = cloudTokenIssuer(from: token),
              let issuerURL = URL(string: issuer),
              let issuerHost = issuerURL.host?.lowercased(),
              let expectedHost = expectedConvexCloudURL.host?
                .replacingOccurrences(of: ".convex.cloud", with: ".convex.site")
                .lowercased() else {
            return true
        }

        return issuerHost == expectedHost
    }

    private nonisolated static func queryItemValue(named name: String, in components: URLComponents) -> String? {
        components.queryItems?
            .first(where: { $0.name == name })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private nonisolated static func generateAuthState() -> String {
        UUID().uuidString.lowercased()
    }

    private nonisolated static func isNativeOAuthCallbackURL(_ url: URL) -> Bool {
        url.scheme == nativeOAuthCallbackScheme
            && url.host == nativeOAuthCallbackHost
            && url.path == nativeOAuthCallbackPath
    }

    var isLoggedIn = false
    var userEmail: String?
    var userDisplayName: String?
    var userId: String?
    var authToken: String?
    var cloudAuthToken: String?
    var refreshToken: String?
    var sessionExpiredMessage: String?

    private let settings = SettingsManager.shared
    private let authBaseURL = AppRuntime.appEnvironment.authBaseURL().absoluteString
    private let remoteClient = ConvexAuthRemoteClient()
    private var authSession: ASWebAuthenticationSession?
    private var pendingAuthSession: PendingAuthSession?
    private var loopbackRedirectServer: LoopbackRedirectServer?
    private var refreshTask: Task<Bool, Never>?

    // MARK: - Resume session

    func resume() async {
        userId    = settings.userId
        userEmail = settings.userEmail
        userDisplayName = settings.userDisplayName
        authToken = settings.authToken
        cloudAuthToken = settings.cloudAuthToken
        refreshToken = settings.refreshToken

        let hasPersistedCredentials =
            authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
            || cloudAuthToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
            || refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil

        guard hasPersistedCredentials else {
            if userId != nil || userEmail != nil || userDisplayName != nil {
                NSLog("AuthManager.resume clearing stale identity without persisted credentials")
                userId = nil
                userEmail = nil
                userDisplayName = nil
                settings.userId = nil
                settings.userEmail = nil
                settings.userDisplayName = nil
            }
            isLoggedIn = false
            return
        }

        let expectedCloudURL = AppRuntime.appEnvironment.convexCloudURL()
        if let cloudAuthToken = cloudAuthToken,
           !Self.isCloudTokenCompatible(cloudAuthToken, expectedConvexCloudURL: expectedCloudURL) {
            NSLog(
                "AuthManager.resume clearing auth session for environment mismatch issuer=%@ expectedHost=%@",
                Self.cloudTokenIssuer(from: cloudAuthToken) ?? "unknown",
                expectedCloudURL.host ?? "unknown"
            )
            logout(
                sessionExpiredMessage: AppRuntime.appEnvironment == .development
                    ? "The saved session belongs to production. Sign in again to use the development app."
                    : "The saved session belongs to a different environment. Sign in again."
            )
            return
        }

        isLoggedIn = userId != nil
    }

    // MARK: - Native Convex Auth

    func signInWithOAuth(provider: OAuthProvider) async throws {
        sessionExpiredMessage = nil

        do {
            try await signInWithOAuthUsingAuthenticationSession(provider: provider)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard Self.shouldAttemptLoopbackOAuthFallback(after: error) else {
                throw error
            }

            NSLog("Native OAuth callback failed before completion, falling back to loopback: %@", error.localizedDescription)
            try await signInWithOAuthUsingLoopback(provider: provider)
        }
    }

    private func signInWithOAuthUsingAuthenticationSession(provider: OAuthProvider) async throws {
        let state = Self.generateAuthState()
        storePendingAuthState(state)

        do {
            let oauthStart = try await remoteClient.startOAuthSignIn(
                provider: provider.rawValue,
                redirectTo: Self.nativeOAuthCallbackURL(
                    state: state,
                    bundleIdentifier: Bundle.main.bundleIdentifier ?? AppRuntime.bundleIdentifier
                ).absoluteString
            )
            let callbackURL = try await waitForAuthenticationSessionCallback(authURL: oauthStart.redirectURL)
            guard let expectedState = activePendingAuthState() else {
                throw OAuthFlowError.invalidCallbackURL
            }
            let code = try Self.authorizationCode(
                fromNativeOAuthCallbackURL: callbackURL,
                expectedState: expectedState
            )
            let tokens = try await remoteClient.completeOAuthSignIn(code: code, verifier: oauthStart.verifier)
            try await applyAuthenticatedSession(tokens)
        } catch {
            clearPendingAuthState()
            throw error
        }
    }

    private func signInWithOAuthUsingLoopback(provider: OAuthProvider) async throws {
        let state = Self.generateAuthState()
        let loopbackRedirectServer = LoopbackRedirectServer()
        self.loopbackRedirectServer = loopbackRedirectServer
        defer {
            loopbackRedirectServer.cancel()
            if self.loopbackRedirectServer === loopbackRedirectServer {
                self.loopbackRedirectServer = nil
            }
        }

        let callbackURL = try await loopbackRedirectServer.start(expectedState: state)
        let oauthStart = try await remoteClient.startOAuthSignIn(
            provider: provider.rawValue,
            redirectTo: callbackURL.absoluteString
        )

        guard NSWorkspace.shared.open(oauthStart.redirectURL) else {
            throw ConvexAuthRemoteError.invalidRedirectURL
        }

        let browserCallbackURL = try await loopbackRedirectServer.waitForCallback()
        guard let components = URLComponents(url: browserCallbackURL, resolvingAgainstBaseURL: false),
              let code = Self.queryItemValue(named: "code", in: components) else {
            throw LoopbackRedirectServer.ServerError.missingAuthorizationCode(nil)
        }

        let tokens = try await remoteClient.completeOAuthSignIn(code: code, verifier: oauthStart.verifier)
        try await applyAuthenticatedSession(tokens)
    }

    private func waitForAuthenticationSessionCallback(authURL: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var didResume = false

                @MainActor
                func resume(_ result: Result<URL, Error>) {
                    guard !didResume else { return }
                    didResume = true
                    authSession = nil
                    continuation.resume(with: result)
                }

                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: Self.nativeOAuthCallbackScheme
                ) { callbackURL, error in
                    Task { @MainActor in
                        if let error {
                            let nsError = error as NSError
                            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                               nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                                resume(.failure(CancellationError()))
                            } else {
                                resume(.failure(error))
                            }
                            return
                        }

                        guard let callbackURL else {
                            resume(.failure(OAuthFlowError.missingCallbackURL))
                            return
                        }

                        resume(.success(callbackURL))
                    }
                }

                session.presentationContextProvider = WebAuthContextProvider.shared
                session.prefersEphemeralWebBrowserSession = false
                authSession = session

                guard session.start() else {
                    resume(.failure(OAuthFlowError.authenticationSessionDidNotStart))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.authSession?.cancel()
                self?.authSession = nil
            }
        }
    }

    private nonisolated static func authorizationCode(
        fromNativeOAuthCallbackURL url: URL,
        expectedState: String
    ) throws -> String {
        guard isNativeOAuthCallbackURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              queryItemValue(named: stateQueryItemName, in: components) == expectedState else {
            throw OAuthFlowError.invalidCallbackURL
        }

        let errorDescription = queryItemValue(named: "error_description", in: components)
        if let authError = queryItemValue(named: "error", in: components) {
            throw OAuthFlowError.authorizationFailed(errorDescription ?? authError)
        }

        guard let code = queryItemValue(named: "code", in: components) else {
            throw OAuthFlowError.missingAuthorizationCode(errorDescription)
        }

        return code
    }

    private nonisolated static func shouldAttemptLoopbackOAuthFallback(after error: Error) -> Bool {
        if let oauthError = error as? OAuthFlowError {
            return oauthError == .authenticationSessionDidNotStart
        }

        if let remoteError = error as? ConvexAuthRemoteError {
            switch remoteError {
            case .serverError(let message), .httpError(let message):
                return message.localizedCaseInsensitiveContains("redirect")
            case .invalidRedirectURL, .missingOAuthRedirect:
                return true
            default:
                return false
            }
        }

        return false
    }

    func signInWithEmail(email: String, password: String) async throws -> EmailSignInResult {
        sessionExpiredMessage = nil
        let result = try await remoteClient.signInWithPassword(email: email, password: password)

        switch result {
        case .signedIn(let tokens):
            try await applyAuthenticatedSession(tokens)
            return .signedIn
        case .needsEmailVerification:
            return .needsEmailVerification
        }
    }

    func verifyEmailCode(email: String, code: String) async throws {
        sessionExpiredMessage = nil
        let tokens = try await remoteClient.verifyEmailCode(email: email, code: code)
        try await applyAuthenticatedSession(tokens)
    }

    func resendEmailVerificationCode(email: String) async throws {
        try await remoteClient.resendEmailVerificationCode(email: email)
    }

    func sendSignInCode(email: String) async throws {
        sessionExpiredMessage = nil
        try await remoteClient.sendSignInCode(email: email)
    }

    func verifySignInCode(email: String, code: String) async throws {
        sessionExpiredMessage = nil
        let tokens = try await remoteClient.verifySignInCode(email: email, code: code)
        try await applyAuthenticatedSession(tokens)
    }

    func refreshSessionIfPossible() async -> Bool {
        if let refreshTask {
            return await refreshTask.value
        }

        guard let refreshToken = (refreshToken ?? settings.refreshToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            return false
        }

        let task = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }

            do {
                let tokens = try await self.remoteClient.refreshSession(refreshToken: refreshToken)
                try await self.applyAuthenticatedSession(tokens)
                return true
            } catch {
                NSLog("Failed to refresh Convex auth session: %@", error.localizedDescription)
                self.logout(sessionExpiredMessage: "Your session expired. Sign in again.")
                return false
            }
        }

        refreshTask = task
        let didRefresh = await task.value
        refreshTask = nil
        return didRefresh
    }

    // MARK: - Legacy browser bridge (fallback only)

    func initiateLogin(onComplete: (@MainActor @Sendable (URL) async -> Void)? = nil) {
        Self.registerPreferredURLSchemeHandler()
        let state = Self.generateAuthState()
        storePendingAuthState(state)

        // Always request the Swift app's dedicated callback scheme so LaunchServices
        // doesn't route the OAuth completion URL to an unrelated Electron app.
        guard let url = Self.loginURL(authBaseURL: authBaseURL, state: state) else {
            clearPendingAuthState()
            return
        }

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: Self.preferredCallbackScheme
        ) { [weak self] callbackURL, error in
            if let callbackURL, error == nil {
                Task { @MainActor [weak self] in
                    let didAuthenticate = await self?.handleCallback(url: callbackURL) ?? false
                    self?.authSession = nil
                    if didAuthenticate {
                        await onComplete?(callbackURL)
                    }
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handleAuthenticationSessionFailure()
                }
            }
        }

        session.presentationContextProvider = WebAuthContextProvider.shared
        session.prefersEphemeralWebBrowserSession = false
        guard session.start() else {
            clearPendingAuthState()
            return
        }
        authSession = session
    }

    // MARK: - OAuth callback

    func storePendingAuthState(_ state: String, initiatedAt: Date = .now) {
        let session = PendingAuthSession(state: state, initiatedAt: initiatedAt)
        pendingAuthSession = session
        Self.persistPendingAuthSession(session)
    }

    func activePendingAuthState(at now: Date = .now) -> String? {
        guard let pendingAuthSession = pendingAuthSession ?? Self.persistedPendingAuthSession() else { return nil }
        guard now.timeIntervalSince(pendingAuthSession.initiatedAt) <= Self.pendingAuthStateRetentionWindow else {
            clearPendingAuthState()
            return nil
        }
        self.pendingAuthSession = pendingAuthSession
        return pendingAuthSession.state
    }

    func handleAuthenticationSessionFailure(at now: Date = .now) {
        _ = activePendingAuthState(at: now)
        authSession = nil
    }

    @discardableResult
    func handleCallback(url: URL, now: Date = .now) async -> Bool {
        guard let expectedState = activePendingAuthState(at: now),
              Self.isValidCallbackURL(url, expectedState: expectedState),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = Self.queryItemValue(named: Self.websiteTokenQueryItemName, in: components)
        else { return false }

        clearPendingAuthState()

        sessionExpiredMessage = nil
        authToken = token
        settings.authToken = token
        let extractedCloudAuthToken = Self.extractedCloudAuthToken(from: url)
        cloudAuthToken = extractedCloudAuthToken
        settings.cloudAuthToken = extractedCloudAuthToken
        refreshToken = nil
        settings.refreshToken = nil

        let callbackUserId = Self.queryItemValue(named: "userId", in: components)
        let callbackEmail = Self.queryItemValue(named: "email", in: components)
        let callbackDisplayName = Self.queryItemValue(named: "name", in: components)

        if let id = callbackUserId {
            userId = id
            settings.userId = id
        }
        if let email = callbackEmail {
            userEmail = email
            settings.userEmail = email
        }
        if let callbackDisplayName {
            userDisplayName = callbackDisplayName
            settings.userDisplayName = callbackDisplayName
        }

        isLoggedIn = userId != nil
        return isLoggedIn
    }

    // MARK: - Logout

    func logout(sessionExpiredMessage: String? = nil) {
        isLoggedIn = false
        userEmail  = nil
        userDisplayName = nil
        userId     = nil
        authToken  = nil
        cloudAuthToken = nil
        refreshToken = nil
        authSession = nil
        refreshTask?.cancel()
        refreshTask = nil
        loopbackRedirectServer?.cancel()
        loopbackRedirectServer = nil
        clearPendingAuthState()
        self.sessionExpiredMessage = sessionExpiredMessage
        settings.authToken = nil
        settings.cloudAuthToken = nil
        settings.refreshToken = nil
        settings.userId    = nil
        settings.userEmail = nil
        settings.userDisplayName = nil
    }

    private func applyAuthenticatedSession(_ tokens: ConvexAuthTokens) async throws {
        let normalizedBearerToken = ConvexClient.convexBearerToken(from: tokens.token) ?? tokens.token
        let user = try await remoteClient.currentUser(bearerToken: normalizedBearerToken)

        clearPendingAuthState()
        authSession = nil
        sessionExpiredMessage = nil
        authToken = normalizedBearerToken
        cloudAuthToken = normalizedBearerToken
        refreshToken = tokens.refreshToken
        userId = user._id
        userEmail = user.email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        userDisplayName = user.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        isLoggedIn = true

        settings.authToken = normalizedBearerToken
        settings.cloudAuthToken = normalizedBearerToken
        settings.refreshToken = tokens.refreshToken
        settings.userId = user._id
        settings.userEmail = userEmail
        settings.userDisplayName = userDisplayName
    }

    private func clearPendingAuthState() {
        pendingAuthSession = nil
        Self.clearPersistedPendingAuthSession()
    }

    private nonisolated static func persistedPendingAuthSession() -> PendingAuthSession? {
        guard let state = AppDefaults.suite.string(forKey: pendingAuthStateDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            return nil
        }

        let initiatedAt = AppDefaults.suite.object(forKey: pendingAuthInitiatedAtDefaultsKey) as? Date ?? .distantPast
        return PendingAuthSession(state: state, initiatedAt: initiatedAt)
    }

    private nonisolated static func persistPendingAuthSession(_ session: PendingAuthSession) {
        AppDefaults.suite.set(session.state, forKey: pendingAuthStateDefaultsKey)
        AppDefaults.suite.set(session.initiatedAt, forKey: pendingAuthInitiatedAtDefaultsKey)
    }

    private nonisolated static func clearPersistedPendingAuthSession() {
        AppDefaults.suite.removeObject(forKey: pendingAuthStateDefaultsKey)
        AppDefaults.suite.removeObject(forKey: pendingAuthInitiatedAtDefaultsKey)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Presentation context

private final class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthContextProvider()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first(where: { $0.isVisible && !$0.isMiniaturized })
            ?? NSApplication.shared.windows.first
            ?? NSWindow()
    }
}
