import Foundation
import Network

@MainActor
final class LoopbackRedirectServer {

    private final class ResumeState: @unchecked Sendable {
        var didResume = false
    }

    enum ServerError: LocalizedError {
        case listenerFailed(String)
        case invalidCallbackRequest
        case missingAuthorizationCode(String?)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .listenerFailed(let message):
                return message
            case .invalidCallbackRequest:
                return "The browser returned an invalid auth callback."
            case .missingAuthorizationCode(let message):
                return message ?? "The auth callback did not include an authorization code."
            case .timedOut:
                return "Timed out waiting for the browser to finish signing in."
            case .cancelled:
                return "The sign-in callback listener was cancelled."
            }
        }
    }

    private let callbackPath = "/auth/callback"
    private let queue = DispatchQueue(label: "com.resonance.resonant.auth-loopback")

    private var listener: NWListener?
    private var callbackOriginURL: URL?
    private var expectedState: String?
    private var receivedCallbackURL: URL?
    private var waitContinuation: CheckedContinuation<URL, Error>?
    private var timeoutTask: Task<Void, Never>?

    func start(expectedState: String) async throws -> URL {
        invalidateCurrentListener(resumePendingWaiter: true)
        self.expectedState = expectedState
        receivedCallbackURL = nil

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let resumeState = ResumeState()
            @Sendable func resume(_ result: Result<URL, Error>) {
                objc_sync_enter(resumeState)
                let shouldResume: Bool
                if resumeState.didResume {
                    shouldResume = false
                } else {
                    resumeState.didResume = true
                    shouldResume = true
                }
                objc_sync_exit(resumeState)

                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleConnection(connection)
                }
            }

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }

                switch state {
                case .ready:
                    guard let port = listener?.port else {
                        resume(.failure(ServerError.listenerFailed("The local auth callback listener did not bind to a port.")))
                        Task { @MainActor [weak self] in
                            self?.invalidateCurrentListener(resumePendingWaiter: true)
                        }
                        return
                    }

                    let originURL = URL(string: "http://127.0.0.1:\(port.rawValue)")!
                    let callbackURL = Self.callbackURL(
                        originURL: originURL,
                        path: self.callbackPath,
                        state: expectedState
                    )
                    Task { @MainActor [weak self] in
                        self?.callbackOriginURL = originURL
                    }
                    resume(.success(callbackURL))
                case .failed(let error):
                    resume(.failure(ServerError.listenerFailed(error.localizedDescription)))
                    Task { @MainActor [weak self] in
                        self?.invalidateCurrentListener(resumePendingWaiter: true)
                    }
                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    nonisolated static func callbackURL(originURL: URL, path: String, state: String) -> URL {
        var components = URLComponents(
            url: originURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        return components.url!
    }

    nonisolated static func callbackStateIsValid(_ url: URL, expectedState: String?) -> Bool {
        guard let expectedState,
              !expectedState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let state = components.queryItems?
                .first(where: { $0.name == "state" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }

        return state == expectedState
    }

    func waitForCallback(timeout: TimeInterval = 180) async throws -> URL {
        if let receivedCallbackURL {
            return receivedCallbackURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            waitContinuation = continuation
            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor [weak self] in
                let duration = max(timeout, 1)
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard let self else { return }
                self.completeWaiting(with: .failure(ServerError.timedOut))
            }
        }
    }

    func cancel() {
        invalidateCurrentListener(resumePendingWaiter: true)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private nonisolated func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if let error {
                Self.respond(
                    on: connection,
                    statusLine: "HTTP/1.1 500 Internal Server Error",
                    body: "<html><body><h1>Resonant sign-in failed</h1><p>\(Self.htmlEscape(error.localizedDescription))</p></body></html>"
                )
                return
            }

            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                Task { @MainActor [weak self] in
                    self?.processRequest(buffer, on: connection)
                }
                return
            }

            guard buffer.count < 16_384 else {
                Self.respond(
                    on: connection,
                    statusLine: "HTTP/1.1 413 Payload Too Large",
                    body: "<html><body><h1>Resonant sign-in failed</h1><p>The callback request was too large.</p></body></html>"
                )
                return
            }

            self.receiveRequest(on: connection, accumulated: buffer)
        }
    }

    private func processRequest(_ data: Data, on connection: NWConnection) {
        guard let callbackOriginURL,
              let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            Self.respond(
                on: connection,
                statusLine: "HTTP/1.1 400 Bad Request",
                body: "<html><body><h1>Resonant sign-in failed</h1><p>The callback request was invalid.</p></body></html>"
            )
            Task { @MainActor [weak self] in
                self?.completeWaiting(with: .failure(ServerError.invalidCallbackRequest))
            }
            return
        }

        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2,
              components[0] == "GET",
              let callbackURL = URL(string: String(components[1]), relativeTo: callbackOriginURL)?.absoluteURL,
              callbackURL.path == callbackPath else {
            Self.respond(
                on: connection,
                statusLine: "HTTP/1.1 404 Not Found",
                body: "<html><body><h1>Resonant sign-in failed</h1><p>The callback path was not recognized.</p></body></html>"
            )
            return
        }

        guard Self.callbackStateIsValid(callbackURL, expectedState: expectedState) else {
            Self.respond(
                on: connection,
                statusLine: "HTTP/1.1 400 Bad Request",
                body: "<html><body><h1>Resonant sign-in failed</h1><p>The callback state was invalid.</p></body></html>"
            )
            Task { @MainActor [weak self] in
                self?.completeWaiting(with: .failure(ServerError.invalidCallbackRequest))
            }
            return
        }

        let urlComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let errorDescription = urlComponents?.queryItems?
            .first(where: { $0.name == "error_description" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authorizationCode = urlComponents?.queryItems?
            .first(where: { $0.name == "code" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let authorizationCode, !authorizationCode.isEmpty {
            Self.respond(
                on: connection,
                statusLine: "HTTP/1.1 200 OK",
                body: Self.successHandoffPage()
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receivedCallbackURL = callbackURL
                self.completeWaiting(with: .success(callbackURL))
            }
            return
        }

        Self.respond(
            on: connection,
            statusLine: "HTTP/1.1 400 Bad Request",
            body: "<html><body><h1>Resonant sign-in failed</h1><p>\(Self.htmlEscape(errorDescription ?? "The browser callback did not include an authorization code."))</p></body></html>"
        )
        Task { @MainActor [weak self] in
            self?.completeWaiting(with: .failure(ServerError.missingAuthorizationCode(errorDescription)))
        }
    }

    private nonisolated static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private nonisolated static func javaScriptStringLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private nonisolated static func successHandoffPage() -> String {
        let handoffURL = AuthManager.authCompletionHandoffURL.absoluteString
        let escapedHandoffURL = htmlEscape(handoffURL)
        let scriptHandoffURL = javaScriptStringLiteral(handoffURL)

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="referrer" content="no-referrer">
          <title>Opening Resonant</title>
          <style>
            :root {
              color-scheme: light dark;
              --bg: #f7f2e8;
              --panel: #fffaf1;
              --text: #201d18;
              --muted: #73695d;
              --border: #ded2c1;
              --button: #201d18;
              --button-text: #fffaf1;
            }

            @media (prefers-color-scheme: dark) {
              :root {
                --bg: #12110f;
                --panel: #1b1916;
                --text: #f4efe5;
                --muted: #b7ab9b;
                --border: #353029;
                --button: #f4efe5;
                --button-text: #12110f;
              }
            }

            * { box-sizing: border-box; }

            body {
              min-height: 100vh;
              margin: 0;
              display: grid;
              place-items: center;
              padding: 24px;
              background: var(--bg);
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            }

            main {
              width: min(100%, 440px);
              border: 1px solid var(--border);
              border-radius: 8px;
              background: var(--panel);
              padding: 28px;
              box-shadow: 0 20px 70px rgba(0, 0, 0, 0.12);
            }

            .mark {
              width: 40px;
              height: 40px;
              border-radius: 8px;
              display: grid;
              place-items: center;
              margin-bottom: 18px;
              background: var(--button);
              color: var(--button-text);
              font-weight: 700;
              letter-spacing: 0;
            }

            h1 {
              margin: 0 0 10px;
              font-size: 24px;
              line-height: 1.2;
              letter-spacing: 0;
            }

            p {
              margin: 0;
              color: var(--muted);
              font-size: 15px;
              line-height: 1.6;
            }

            a {
              display: inline-flex;
              align-items: center;
              justify-content: center;
              min-height: 44px;
              margin-top: 22px;
              padding: 0 16px;
              border-radius: 8px;
              background: var(--button);
              color: var(--button-text);
              text-decoration: none;
              font-size: 14px;
              font-weight: 600;
            }
          </style>
        </head>
        <body>
          <main>
            <div class="mark" aria-hidden="true">R</div>
            <h1>Opening Resonant</h1>
            <p>Your browser sign-in finished. Resonant is being brought back to the front.</p>
            <a href="\(escapedHandoffURL)">Open Resonant</a>
          </main>
          <script>
            (function () {
              var handoffURL = "\(scriptHandoffURL)";
              try {
                window.history.replaceState(null, document.title, "/auth/complete");
              } catch (_) {}
              window.setTimeout(function () {
                window.location.href = handoffURL;
              }, 50);
            }());
          </script>
        </body>
        </html>
        """
    }

    private nonisolated static func respond(on connection: NWConnection, statusLine: String, body: String) {
        let response = """
        \(statusLine)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Cache-Control: no-store\r
        Referrer-Policy: no-referrer\r
        X-Content-Type-Options: nosniff\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func completeWaiting(with result: Result<URL, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil

        let continuation = waitContinuation
        waitContinuation = nil
        continuation?.resume(with: result)

        clearListenerHandlers(listener)
        listener?.cancel()
        listener = nil
        callbackOriginURL = nil
        expectedState = nil
    }

    private func invalidateCurrentListener(resumePendingWaiter: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil

        clearListenerHandlers(listener)
        listener?.cancel()
        listener = nil
        callbackOriginURL = nil
        expectedState = nil
        receivedCallbackURL = nil

        guard resumePendingWaiter else { return }

        let continuation = waitContinuation
        waitContinuation = nil
        continuation?.resume(throwing: ServerError.cancelled)
    }

    private func clearListenerHandlers(_ listener: NWListener?) {
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
    }
}
