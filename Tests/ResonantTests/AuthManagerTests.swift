import XCTest
@testable import Resonant

@MainActor
final class AuthManagerTests: XCTestCase {

    private struct AuthSettingsSnapshot {
        let authToken: String?
        let cloudAuthToken: String?
        let refreshToken: String?
        let userId: String?
        let userEmail: String?
        let userDisplayName: String?
    }

    func testLoginURLEmbedsStateAndPreferredRedirectParameters() {
        let url = AuthManager.loginURL(authBaseURL: "https://onresonant.com", state: "expected-state")

        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "state" })?.value, "expected-state")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "redirect" })?.value, AuthManager.preferredCallbackURL)
    }

    func testValidCallbackRequiresMatchingStateForSupportedSchemes() {
        let matchingSwiftURL = URL(string: "resonantmac://auth-callback?state=expected-state&token=opaque&userId=user-123")!
        let matchingLegacyURL = URL(string: "resonant://auth-callback?state=expected-state&token=opaque&userId=user-123")!
        let matchingDevURL = URL(string: "resonantmac-dev://auth-callback?state=expected-state&token=opaque&userId=user-123")!
        let mismatchedURL = URL(string: "resonantmac://auth-callback?state=wrong-state&token=opaque&userId=user-123")!

        XCTAssertTrue(AuthManager.isValidCallbackURL(matchingSwiftURL, expectedState: "expected-state"))
        XCTAssertTrue(AuthManager.isValidCallbackURL(matchingLegacyURL, expectedState: "expected-state"))
        XCTAssertTrue(AuthManager.isValidCallbackURL(matchingDevURL, expectedState: "expected-state"))
        XCTAssertFalse(AuthManager.isValidCallbackURL(mismatchedURL, expectedState: "expected-state"))
    }

    func testPreferredCallbackSchemeFollowsBundleIdentity() {
        XCTAssertEqual(
            AuthManager.preferredCallbackScheme(bundleIdentifier: "com.resonance.resonant"),
            "resonantmac"
        )
        XCTAssertEqual(
            AuthManager.preferredCallbackScheme(bundleIdentifier: "com.resonance.resonant.dev"),
            "resonantmac-dev"
        )
        XCTAssertEqual(
            AuthManager.preferredCallbackScheme(bundleIdentifier: "org.resonant.community"),
            "resonant-community"
        )
        XCTAssertEqual(
            AuthManager.preferredCallbackScheme(bundleIdentifier: "org.resonant.community.dev"),
            "resonant-community-dev"
        )
    }

    func testConfiguredCallbackSchemeComesFromPackagedURLType() {
        let schemes = AuthManager.configuredCallbackSchemes(infoDictionary: [
            "CFBundleURLTypes": [[
                "CFBundleURLSchemes": ["my-resonant-fork", "not a scheme"]
            ]]
        ])
        XCTAssertEqual(schemes, ["my-resonant-fork"])
    }

    func testNativeOAuthCallbackUsesPreferredAppScheme() {
        XCTAssertEqual(
            AuthManager.nativeOAuthCallbackURL(bundleIdentifier: "com.resonance.resonant").absoluteString,
            "resonantmac://auth/callback"
        )
        XCTAssertEqual(
            AuthManager.authCompletionHandoffURL(bundleIdentifier: "com.resonance.resonant").absoluteString,
            "resonantmac://auth/complete"
        )
        XCTAssertEqual(
            AuthManager.nativeOAuthCallbackURL(bundleIdentifier: "com.resonance.resonant.dev").absoluteString,
            "resonantmac-dev://auth/callback"
        )
        XCTAssertEqual(
            AuthManager.authCompletionHandoffURL(bundleIdentifier: "com.resonance.resonant.dev").absoluteString,
            "resonantmac-dev://auth/complete"
        )
        XCTAssertTrue(AuthManager.isAuthCompletionHandoffURL(AuthManager.authCompletionHandoffURL))
        XCTAssertFalse(AuthManager.isAuthCompletionHandoffURL(AuthManager.nativeOAuthCallbackURL))
    }

    func testNativeOAuthCallbackCanEmbedState() {
        let url = AuthManager.nativeOAuthCallbackURL(
            state: "expected-state",
            bundleIdentifier: "com.resonance.resonant"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(url.scheme, "resonantmac")
        XCTAssertEqual(url.host, "auth")
        XCTAssertEqual(url.path, "/callback")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "state" })?.value, "expected-state")
    }

    func testLoopbackCallbackURLEmbedsState() {
        let url = LoopbackRedirectServer.callbackURL(
            originURL: URL(string: "http://127.0.0.1:49152")!,
            path: "/auth/callback",
            state: "expected-state"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:49152/auth/callback?state=expected-state")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "state" })?.value, "expected-state")
    }

    func testLoopbackCallbackRequiresMatchingState() {
        let matchingURL = URL(string: "http://127.0.0.1:49152/auth/callback?state=expected-state&code=abc")!
        let missingURL = URL(string: "http://127.0.0.1:49152/auth/callback?code=abc")!
        let mismatchedURL = URL(string: "http://127.0.0.1:49152/auth/callback?state=wrong-state&code=abc")!

        XCTAssertTrue(LoopbackRedirectServer.callbackStateIsValid(matchingURL, expectedState: "expected-state"))
        XCTAssertFalse(LoopbackRedirectServer.callbackStateIsValid(missingURL, expectedState: "expected-state"))
        XCTAssertFalse(LoopbackRedirectServer.callbackStateIsValid(mismatchedURL, expectedState: "expected-state"))
        XCTAssertFalse(LoopbackRedirectServer.callbackStateIsValid(matchingURL, expectedState: nil))
    }

    func testExtractedCloudAuthTokenPrefersDedicatedJWT() {
        let url = URL(string: "resonant://auth-callback?state=expected&token=opaque-token&cloudToken=header.payload.signature")!

        XCTAssertEqual(AuthManager.extractedCloudAuthToken(from: url), "header.payload.signature")
    }

    func testExtractedCloudAuthTokenFallsBackToJWTWebsiteToken() {
        let url = URL(string: "resonant://auth-callback?state=expected&token=header.payload.signature")!

        XCTAssertEqual(AuthManager.extractedCloudAuthToken(from: url), "header.payload.signature")
    }

    func testCloudTokenIssuerParsesJWTIssuerClaim() {
        let token = makeJWT(issuer: "https://operator.example.com")

        XCTAssertEqual(
            AuthManager.cloudTokenIssuer(from: token),
            "https://operator.example.com"
        )
    }

    func testDevelopmentEnvironmentRejectsProductionCloudToken() {
        let token = makeJWT(issuer: "https://operator.example.com")

        XCTAssertFalse(
            AuthManager.isCloudTokenCompatible(
                token,
                expectedConvexCloudURL: AppEnvironment.development.convexCloudURL(
                    processEnvironment: [:],
                    infoDictionary: nil
                )
            )
        )
    }

    func testAuthenticationSessionErrorKeepsPendingStateForDeepLinkFallback() async {
        let snapshot = snapshotAuthSettings()
        defer {
            AuthManager().logout()
            restoreAuthSettings(snapshot)
        }

        let authManager = AuthManager()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        authManager.storePendingAuthState("expected-state", initiatedAt: startedAt)
        authManager.handleAuthenticationSessionFailure(at: startedAt.addingTimeInterval(5))

        let callbackURL = URL(
            string: "resonantmac://auth-callback?state=expected-state&token=opaque-token&cloudToken=header.payload.signature&userId=user-123&email=test%40example.com&name=Alex"
        )!

        let didAuthenticate = await authManager.handleCallback(url: callbackURL, now: startedAt.addingTimeInterval(10))

        XCTAssertTrue(didAuthenticate)
        XCTAssertNil(authManager.activePendingAuthState(at: startedAt.addingTimeInterval(10)))
        XCTAssertEqual(authManager.userId, "user-123")
        XCTAssertEqual(authManager.userEmail, "test@example.com")
        XCTAssertEqual(authManager.userDisplayName, "Alex")
        XCTAssertEqual(authManager.cloudAuthToken, "header.payload.signature")
    }

    func testExpiredPendingStateRejectsFallbackCallback() async {
        let snapshot = snapshotAuthSettings()
        defer {
            AuthManager().logout()
            restoreAuthSettings(snapshot)
        }

        let authManager = AuthManager()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        authManager.storePendingAuthState("expected-state", initiatedAt: startedAt)

        let expiredAt = startedAt.addingTimeInterval(AuthManager.pendingAuthStateRetentionWindow + 1)
        authManager.handleAuthenticationSessionFailure(at: expiredAt)

        let callbackURL = URL(
            string: "resonantmac://auth-callback?state=expected-state&token=opaque-token&userId=user-123"
        )!

        let didAuthenticate = await authManager.handleCallback(url: callbackURL, now: expiredAt)

        XCTAssertFalse(didAuthenticate)
        XCTAssertNil(authManager.activePendingAuthState(at: expiredAt))
    }

    func testPendingStatePersistsAcrossAuthManagerInstances() async {
        let snapshot = snapshotAuthSettings()
        defer {
            AuthManager().logout()
            restoreAuthSettings(snapshot)
        }

        let startedAt = Date(timeIntervalSince1970: 2_000)
        let loginManager = AuthManager()
        loginManager.storePendingAuthState("expected-state", initiatedAt: startedAt)

        let callbackManager = AuthManager()
        let callbackURL = URL(
            string: "resonantmac://auth-callback?state=expected-state&token=opaque-token&userId=user-123&email=test%40example.com&name=Alex"
        )!

        let didAuthenticate = await callbackManager.handleCallback(url: callbackURL, now: startedAt.addingTimeInterval(5))

        XCTAssertTrue(didAuthenticate)
        XCTAssertEqual(callbackManager.userId, "user-123")
        XCTAssertEqual(callbackManager.userEmail, "test@example.com")
        XCTAssertEqual(callbackManager.userDisplayName, "Alex")

        await loginManager.resume()
        XCTAssertTrue(loginManager.isLoggedIn)
        XCTAssertEqual(loginManager.userId, "user-123")
        XCTAssertEqual(loginManager.userDisplayName, "Alex")
    }

    func testLegacyCallbackClearsStoredRefreshToken() async {
        let snapshot = snapshotAuthSettings()
        defer {
            AuthManager().logout()
            restoreAuthSettings(snapshot)
        }

        let settings = SettingsManager.shared
        settings.refreshToken = "refresh-token"

        let authManager = AuthManager()
        let startedAt = Date(timeIntervalSince1970: 3_000)
        authManager.storePendingAuthState("expected-state", initiatedAt: startedAt)

        let callbackURL = URL(
            string: "resonantmac://auth-callback?state=expected-state&token=opaque-token&userId=user-123"
        )!

        let didAuthenticate = await authManager.handleCallback(url: callbackURL, now: startedAt.addingTimeInterval(5))

        XCTAssertTrue(didAuthenticate)
        XCTAssertNil(authManager.refreshToken)
        XCTAssertNil(settings.refreshToken)
    }

    func testResumeClearsStaleIdentityWhenNoCredentialsRemain() async {
        let snapshot = snapshotAuthSettings()
        defer {
            AuthManager().logout()
            restoreAuthSettings(snapshot)
        }

        let settings = SettingsManager.shared
        settings.authToken = nil
        settings.cloudAuthToken = nil
        settings.refreshToken = nil
        settings.userId = "user-123"
        settings.userEmail = "test@example.com"
        settings.userDisplayName = "Alex"

        let authManager = AuthManager()
        await authManager.resume()

        XCTAssertFalse(authManager.isLoggedIn)
        XCTAssertNil(authManager.userId)
        XCTAssertNil(authManager.userEmail)
        XCTAssertNil(authManager.userDisplayName)
        XCTAssertNil(settings.userId)
        XCTAssertNil(settings.userEmail)
        XCTAssertNil(settings.userDisplayName)
    }

    func testResumeClearsEnvironmentMismatchedCloudSession() async {
        let snapshot = snapshotAuthSettings()
        defer {
            AuthManager().logout()
            restoreAuthSettings(snapshot)
        }

        let settings = SettingsManager.shared
        settings.authToken = makeJWT(issuer: "https://operator.example.com")
        settings.cloudAuthToken = makeJWT(issuer: "https://operator.example.com")
        settings.refreshToken = "refresh-token"
        settings.userId = "user-123"
        settings.userEmail = "test@example.com"

        let authManager = AuthManager()
        await authManager.resume()

        XCTAssertFalse(authManager.isLoggedIn)
        XCTAssertNil(authManager.userId)
        XCTAssertNil(authManager.userEmail)
        XCTAssertNil(authManager.authToken)
        XCTAssertNil(authManager.cloudAuthToken)
        XCTAssertNil(authManager.refreshToken)
        XCTAssertEqual(
            authManager.sessionExpiredMessage,
            "The saved session belongs to production. Sign in again to use the development app."
        )
        XCTAssertNil(settings.userId)
        XCTAssertNil(settings.userEmail)
        XCTAssertNil(settings.authToken)
        XCTAssertNil(settings.cloudAuthToken)
        XCTAssertNil(settings.refreshToken)
    }

    private func snapshotAuthSettings() -> AuthSettingsSnapshot {
        let settings = SettingsManager.shared
        return AuthSettingsSnapshot(
            authToken: settings.authToken,
            cloudAuthToken: settings.cloudAuthToken,
            refreshToken: settings.refreshToken,
            userId: settings.userId,
            userEmail: settings.userEmail,
            userDisplayName: settings.userDisplayName
        )
    }

    private func restoreAuthSettings(_ snapshot: AuthSettingsSnapshot) {
        let settings = SettingsManager.shared
        settings.authToken = snapshot.authToken
        settings.cloudAuthToken = snapshot.cloudAuthToken
        settings.refreshToken = snapshot.refreshToken
        settings.userId = snapshot.userId
        settings.userEmail = snapshot.userEmail
        settings.userDisplayName = snapshot.userDisplayName
    }

    private func makeJWT(issuer: String) -> String {
        let encoder = JSONEncoder()
        let headerData = try! encoder.encode(["alg": "none", "typ": "JWT"])
        let payloadData = try! encoder.encode([
            "iss": issuer,
            "sub": "user-123"
        ])

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        return "\(base64URL(headerData)).\(base64URL(payloadData)).signature"
    }
}
