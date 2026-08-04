import AppKit
import SwiftUI

@MainActor
final class AuthWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private weak var appState: AppState?

    func show(appState: AppState) {
        self.appState = appState
        if let window {
            window.contentView = makeHostingView(appState: appState)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Resonant"
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeHostingView(appState: appState)

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func dismiss() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Fires for the red button and programmatic dismiss alike; a
        // successful sign-in applies the session before dismissing, so
        // isLoggedIn distinguishes completion from abandonment.
        guard let appState, !appState.authManager.isLoggedIn else { return }
        appState.analyticsManager.capture("auth_abandoned")
        // The hosting view outlives the closed window (the window is reused),
        // so tell it to cancel any in-flight auth attempt — otherwise an OAuth
        // flow can complete and sign the user in after they closed the window.
        NotificationCenter.default.post(name: .authWindowClosedWhileUnauthenticated, object: nil)
    }

    private func makeHostingView(appState: AppState) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(AuthView().environment(appState)))
        host.sizingOptions = []
        return host
    }
}

private struct AuthView: View {

    @Environment(AppState.self) private var appState

    @State private var email = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var needsEmailVerification = false
    @State private var needsSignInCodeVerification = false
    @State private var isWorking = false
    @State private var workingMessage = ""
    @State private var errorMessage: String?
    @State private var activeAuthTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to Resonant")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(needsEmailVerification || needsSignInCodeVerification
                     ? "Enter the verification code we sent to \(email)."
                     : "Use a provider or your email and password.")
                    .foregroundStyle(.secondary)
            }

            if needsEmailVerification {
                verificationSection
            } else if needsSignInCodeVerification {
                signInCodeSection
            } else {
                oauthSection
                Divider()
                passwordSection
            }

            if isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(workingMessage)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Button("Open Account on the Web") {
                    NSWorkspace.shared.open(AppRuntime.appEnvironment.authBaseURL().appending(path: "account"))
                }
                .buttonStyle(.link)

                Spacer()

                if needsEmailVerification || needsSignInCodeVerification {
                    Button("Back") {
                        errorMessage = nil
                        verificationCode = ""
                        needsEmailVerification = false
                        needsSignInCodeVerification = false
                    }
                    .disabled(isWorking)
                }

                Button("Close") {
                    appState.authWindowController.dismiss()
                }
                .disabled(isWorking)
            }
        }
        .padding(28)
        .frame(width: 480, height: 620, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: .authWindowClosedWhileUnauthenticated)) { _ in
            activeAuthTask?.cancel()
        }
    }

    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue with")
                .font(.headline)

            ForEach(AuthManager.OAuthProvider.allCases) { provider in
                OAuthButton(provider: provider, isDisabled: isWorking) {
                    beginOAuthSignIn(provider)
                }
            }
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Or use email")
                .font(.headline)

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)

            HStack {
                Button("Sign In") {
                    beginPasswordSignIn()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || email.trimmedForAuth == nil || password.isEmpty)

                Button("Send sign-in code instead") {
                    beginSendSignInCode()
                }
                .buttonStyle(.link)
                .disabled(isWorking || email.trimmedForAuth == nil)
            }
        }
    }

    private var signInCodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Email sign-in code")
                .font(.headline)

            TextField("6-digit code", text: $verificationCode)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)

            HStack {
                Button("Sign In") {
                    verifySignInCode()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || verificationCode.trimmedForAuth == nil)

                Button("Resend Code") {
                    beginSendSignInCode()
                }
                .disabled(isWorking)
            }
        }
    }

    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Email verification")
                .font(.headline)

            TextField("Verification code", text: $verificationCode)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)

            HStack {
                Button("Verify Code") {
                    verifyEmailCode()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || verificationCode.trimmedForAuth == nil)

                Button("Resend Code") {
                    resendVerificationCode()
                }
                .disabled(isWorking || email.trimmedForAuth == nil)
            }
        }
    }

    private func beginOAuthSignIn(_ provider: AuthManager.OAuthProvider) {
        activeAuthTask = Task {
            await runAuthAction(method: "oauth_\(provider.rawValue)", message: "Waiting for \(provider.rawValue.capitalized) in your browser...") {
                try await appState.authManager.signInWithOAuth(provider: provider)
                await appState.completeNativeSignIn()
            }
        }
    }

    private func beginPasswordSignIn() {
        activeAuthTask = Task {
            await runAuthAction(method: "password", message: "Signing you in...") {
                let result = try await appState.authManager.signInWithEmail(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
                switch result {
                case .signedIn:
                    await appState.completeNativeSignIn()
                case .needsEmailVerification:
                    password = ""
                    verificationCode = ""
                    needsEmailVerification = true
                }
            }
        }
    }

    private func verifyEmailCode() {
        activeAuthTask = Task {
            await runAuthAction(method: "email_verification_code", message: "Verifying your email code...") {
                try await appState.authManager.verifyEmailCode(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    code: verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                await appState.completeNativeSignIn()
            }
        }
    }

    private func resendVerificationCode() {
        activeAuthTask = Task {
            await runAuthAction(method: "resend_verification_code", message: "Sending a new verification code...") {
                try await appState.authManager.resendEmailVerificationCode(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    private func beginSendSignInCode() {
        activeAuthTask = Task {
            await runAuthAction(method: "send_sign_in_code", message: "Sending sign-in code...") {
                try await appState.authManager.sendSignInCode(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                verificationCode = ""
                needsSignInCodeVerification = true
            }
        }
    }

    private func verifySignInCode() {
        activeAuthTask = Task {
            await runAuthAction(method: "sign_in_code", message: "Signing you in...") {
                try await appState.authManager.verifySignInCode(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    code: verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                await appState.completeNativeSignIn()
            }
        }
    }

    private func runAuthAction(
        method: String,
        message: String,
        action: @escaping @MainActor () async throws -> Void
    ) async {
        errorMessage = nil
        isWorking = true
        workingMessage = message
        appState.analyticsManager.capture("auth_method_attempted", properties: ["method": method])
        defer {
            isWorking = false
            workingMessage = ""
        }

        do {
            try await action()
            appState.analyticsManager.capture("auth_method_succeeded", properties: ["method": method])
        } catch is CancellationError {
            // The user closed the browser sheet or backed out mid-flow.
            appState.analyticsManager.capture("auth_method_cancelled", properties: ["method": method])
            return
        } catch {
            var properties = AnalyticsEventSanitizer.errorProperties(for: error)
            properties["method"] = method
            appState.analyticsManager.capture("auth_method_failed", properties: properties)
            errorMessage = error.userFacingAuthMessage
        }
    }
}

extension Notification.Name {
    static let authWindowClosedWhileUnauthenticated = Notification.Name("authWindowClosedWhileUnauthenticated")
}

// MARK: - OAuth Button

private struct OAuthButton: View {
    let provider: AuthManager.OAuthProvider
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                providerLogo
                    .frame(width: 20, height: 20)
                Text(provider.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(provider == .google ? Color.primary : Color.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }

    @ViewBuilder
    private var providerLogo: some View {
        switch provider {
        case .google: GoogleLogoView()
        case .apple: AppleLogoView()
        case .github: GitHubLogoView()
        }
    }

    private var background: Color {
        switch provider {
        case .google: Color(nsColor: .controlBackgroundColor)
        case .apple: Color.black
        case .github: Color(red: 0.141, green: 0.161, blue: 0.184)
        }
    }

    private var borderColor: Color {
        switch provider {
        case .google: Color(red: 0.855, green: 0.855, blue: 0.878)
        case .apple: Color.clear
        case .github: Color.clear
        }
    }
}

// MARK: - Provider Logos

private struct GoogleLogoView: View {
    var body: some View {
        if let image = Self.cachedImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
        }
    }

    private static let cachedImage: NSImage? = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="48" height="48">\
        <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.07 5.07 0 0 1-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/>\
        <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"/>\
        <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"/>\
        <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"/>\
        </svg>
        """
        guard let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }()
}

private struct AppleLogoView: View {
    var body: some View {
        Image(systemName: "apple.logo")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.white)
    }
}

private struct GitHubLogoView: View {
    var body: some View {
        if let image = Self.cachedImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
        }
    }

    private static let cachedImage: NSImage? = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="48" height="48">\
        <path fill="white" d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/>\
        </svg>
        """
        guard let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }()
}

private extension Error {
    var userFacingAuthMessage: String {
        let message = localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Sign-in failed. Please try again." : message
    }
}

private extension String {
    var trimmedForAuth: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
