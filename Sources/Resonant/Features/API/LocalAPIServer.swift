import Foundation
import Network
import Darwin

/// Lightweight HTTP API server on localhost, exposing workspace data to local tools and agents.
/// Binds to 127.0.0.1 only — never exposed to the network.
@MainActor
@Observable
final class LocalAPIServer {

    nonisolated static let defaultPort: UInt16 = 19222
    nonisolated private static let networkQueue = DispatchQueue(
        label: "com.resonance.resonant.local-api",
        qos: .userInitiated
    )

    nonisolated private let queryEngine: WorkspaceQueryEngine
    nonisolated private let authTokenStore = LocalAPIAuthTokenStore()
    private var listener: NWListener?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private(set) var port: UInt16 = 0
    private(set) var isRunning = false
    private(set) var startFailure: String?
    private var activationAttempted = false

    init(queryEngine: WorkspaceQueryEngine) {
        self.queryEngine = queryEngine
    }

    private static let legacyCLIMigrationKey = "didRemoveLegacyResonantCLI"

    /// One-shot migration: removes `~/.local/bin/resonant` if a prior version installed it.
    /// Gated by a UserDefaults marker so it never runs twice, and only deletes files whose
    /// contents match the old wrapper signature.
    private static func removeLegacyCLI() {
        guard AppRuntime.distributionFlavor == .official else { return }
        let defaults = AppDefaults.suite
        guard !defaults.bool(forKey: legacyCLIMigrationKey) else { return }
        defer { defaults.set(true, forKey: legacyCLIMigrationKey) }

        let path = MCPManager.installDirectory.appendingPathComponent("resonant")
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return }
        guard let contents = try? String(contentsOf: path, encoding: .utf8),
              contents.contains("$HOME/.resonant/api.port") else {
            return
        }
        do {
            try fm.removeItem(at: path)
            print("[LocalAPI] Removed legacy CLI at \(path.path)")
        } catch {
            print("[LocalAPI] Failed to remove legacy CLI: \(error)")
        }
    }

    func start(port requestedPort: UInt16 = defaultPort) {
        guard !isRunning else { return }
        activationAttempted = true
        startFailure = nil
        Self.removeLegacyCLI()
        guard let authToken = Self.loadOrCreateToken() else {
            isRunning = false
            removePortFile()
            startFailure = "Unable to persist auth token at \(Self.tokenFilePath.path)"
            return
        }
        authTokenStore.set(authToken)
        bind(port: requestedPort, isRetry: false)
    }

    func stop() {
        guard activationAttempted || listener != nil || isRunning else { return }
        listener?.cancel()
        listener = nil
        isRunning = false
        startFailure = nil
        activationAttempted = false
        removePortFile()
    }

    private func bind(port requestedPort: UInt16, isRetry: Bool) {
        do {
            let listener = try makeListener(port: requestedPort, isRetry: isRetry)
            listener.start(queue: Self.networkQueue)
            self.listener = listener
        } catch {
            print("[LocalAPI] Failed to create listener: \(error)")
            if !isRetry {
                removePortFile()
                bind(port: 0, isRetry: true)
            } else {
                isRunning = false
                startFailure = "Failed to start local API: \(error.localizedDescription)"
            }
        }
    }

    private func makeListener(port requestedPort: UInt16, isRetry: Bool) throws -> NWListener {
        let params = NWParameters.tcp
        let endpointPort: NWEndpoint.Port
        if requestedPort == 0 {
            endpointPort = .any
        } else {
            endpointPort = NWEndpoint.Port(rawValue: requestedPort)!
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: endpointPort
        )
        let listener = try NWListener(using: params)

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor [weak self, weak listener] in
                guard let self else { return }
                switch state {
                case .ready:
                    if let actualPort = listener?.port?.rawValue {
                        self.port = actualPort
                        self.isRunning = true
                        self.startFailure = nil
                        self.writePortFile()
                        print("[LocalAPI] Listening on 127.0.0.1:\(actualPort)")
                    }
                case .failed(let error):
                    print("[LocalAPI] Listener failed: \(error)")
                    listener?.cancel()
                    self.listener = nil
                    self.isRunning = false
                    self.removePortFile()
                    if !isRetry {
                        print("[LocalAPI] Retrying on ephemeral port…")
                        self.bind(port: 0, isRetry: true)
                    } else {
                        self.startFailure = "Port unavailable: \(error.localizedDescription)"
                    }
                case .cancelled:
                    self.isRunning = false
                    self.removePortFile()
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        return listener
    }

    // MARK: - Connection handling

    private nonisolated static let maxHeaderBytes = 65536
    private nonisolated static let headerTerminator = Data("\r\n\r\n".utf8)

    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.start(queue: Self.networkQueue)
        receiveHeaders(connection: connection, accumulated: Data())
    }

    /// Accumulates bytes until `\r\n\r\n` (end of HTTP headers) is seen.
    /// GET-only API has no body, so we stop as soon as headers are complete.
    private nonisolated func receiveHeaders(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.sendResponse(
                    connection: connection,
                    status: 500,
                    body: ["error": "Connection failed: \(error.localizedDescription)"]
                )
                return
            }

            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let range = buffer.range(of: Self.headerTerminator) {
                if range.lowerBound > Self.maxHeaderBytes {
                    self.sendResponse(connection: connection, status: 431, body: ["error": "Request headers too large"])
                    return
                }
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                Task { [weak self] in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    await self.handleRequest(headerData: headerData, connection: connection)
                }
                return
            }

            if buffer.count >= Self.maxHeaderBytes {
                self.sendResponse(connection: connection, status: 431, body: ["error": "Request headers too large"])
                return
            }

            if isComplete {
                self.sendResponse(connection: connection, status: 400, body: ["error": "Malformed request"])
                return
            }

            self.receiveHeaders(connection: connection, accumulated: buffer)
        }
    }

    private nonisolated func handleRequest(headerData: Data, connection: NWConnection) async {
        guard let requestString = String(data: headerData, encoding: .utf8) else {
            sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
            return
        }

        let parsed = Self.parseHTTPRequest(requestString)
        guard parsed.method == "GET" else {
            sendResponse(connection: connection, status: 405, body: ["error": "Method not allowed"])
            return
        }

        let cleanPath = parsed.path.hasPrefix("/v1/") ? String(parsed.path.dropFirst(3)) : parsed.path
        if cleanPath != "/status" {
            guard let authToken = authTokenStore.value() else {
                sendResponse(connection: connection, status: 503, body: [
                    "error": "Auth unavailable. Unable to persist the API token at \(Self.tokenFilePath.path)."
                ])
                return
            }
            let provided = parsed.headers["authorization"] ?? ""
            let presented: String
            if provided.lowercased().hasPrefix("bearer ") {
                presented = String(provided.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
            } else {
                presented = provided.trimmingCharacters(in: .whitespaces)
            }
            if presented != authToken {
                sendResponse(connection: connection, status: 401, body: [
                    "error": "Unauthorized. Pass the token from \(Self.tokenFilePath.path) as 'Authorization: Bearer <token>'."
                ])
                return
            }
        }

        let response = await route(path: parsed.path, query: parsed.query)
        sendResponse(connection: connection, status: response.status, body: response.body)
    }

    // MARK: - Routing

    private struct RouteResponse {
        let status: Int
        let body: Any // must be JSON-serializable
    }

    private nonisolated func route(path: String, query: [String: String]) async -> RouteResponse {

        // Strip /v1 prefix if present
        let cleanPath: String
        if path.hasPrefix("/v1/") {
            cleanPath = String(path.dropFirst(3))
        } else {
            cleanPath = path
        }

        switch cleanPath {

        case "/tools":
            let tools = WorkspaceTools.allTools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema.apiValue
                ]
            }
            return RouteResponse(status: 200, body: ["tools": tools, "count": tools.count])

        case "/tools/call":
            guard let name = query["name"], !name.isEmpty else {
                return RouteResponse(status: 400, body: ["error": "Missing required parameter: name"])
            }
            let result = await callWorkspaceTool(name, arguments: Self.toolArguments(from: query, dropping: ["name"]))
            return toolRouteResponse(result)

        case "/search":
            guard let q = query["q"], !q.isEmpty else {
                return RouteResponse(status: 400, body: ["error": "Missing required parameter: q"])
            }
            let result = await callWorkspaceTool("search", arguments: Self.toolArguments(from: query, aliases: ["q": "query"]))
            let results = result.payload.objectValue?["results"]?.apiArray ?? []
            return RouteResponse(status: result.isError ? 400 : 200, body: result.isError ? result.apiBody : ["results": results, "count": results.count])

        case "/recent":
            let result = await callWorkspaceTool("recent_activity", arguments: Self.toolArguments(from: query))
            let items = result.payload.objectValue?["items"]?.apiArray ?? []
            return RouteResponse(status: result.isError ? 400 : 200, body: result.isError ? result.apiBody : ["items": items, "count": items.count])

        case "/meetings":
            let result = await callWorkspaceTool("list_meetings", arguments: Self.toolArguments(from: query))
            let meetings = result.payload.objectValue?["meetings"]?.apiArray ?? []
            return RouteResponse(status: 200, body: ["meetings": meetings, "count": meetings.count])

        case "/dictations":
            let result = await callWorkspaceTool("list_dictations", arguments: Self.toolArguments(from: query))
            let dictations = result.payload.objectValue?["dictations"]?.apiArray ?? []
            return RouteResponse(status: 200, body: ["dictations": dictations, "count": dictations.count])

        case "/memos":
            let result = await callWorkspaceTool("list_memos", arguments: Self.toolArguments(from: query))
            let memos = result.payload.objectValue?["memos"]?.apiArray ?? []
            return RouteResponse(status: 200, body: ["memos": memos, "count": memos.count])

        case "/journal":
            let result = await callWorkspaceTool("get_journal", arguments: Self.toolArguments(from: query))
            if result.isError {
                return RouteResponse(status: 400, body: result.apiBody)
            }
            if let journal = result.payload.objectValue?["journal"], journal != .null {
                return RouteResponse(status: 200, body: journal.apiValue)
            }
            return RouteResponse(status: 404, body: ["error": "No journal entry for that date."])

        case "/ambient/timeline":
            let result = await callWorkspaceTool("ambient_timeline", arguments: Self.toolArguments(from: query))
            let items = result.payload.objectValue?["snapshots"]?.apiArray ?? []
            return RouteResponse(status: 200, body: ["items": items, "count": items.count])

        case "/ambient/usage":
            let result = await callWorkspaceTool("ambient_app_usage", arguments: Self.toolArguments(from: query))
            let apps = result.payload.objectValue?["usage"]?.apiArray ?? []
            return RouteResponse(status: 200, body: ["apps": apps, "count": apps.count])

        case "/ambient/search":
            guard let q = query["q"], !q.isEmpty else {
                return RouteResponse(status: 400, body: ["error": "Missing required parameter: q"])
            }
            let result = await callWorkspaceTool("ambient_search", arguments: Self.toolArguments(from: query, aliases: ["q": "query"]))
            let results = result.payload.objectValue?["results"]?.apiArray ?? []
            return RouteResponse(status: result.isError ? 400 : 200, body: result.isError ? result.apiBody : ["results": results, "count": results.count])

        case "/status":
            return RouteResponse(status: 200, body: [
                "server": "resonant",
                "version": "1.0.0",
                "auth": "Bearer token required on all endpoints except /status. Token lives at \(Self.tokenFilePath.path).",
                "endpoints": [
                    "/search",
                    "/recent",
                    "/meetings",
                    "/dictations",
                    "/memos",
                    "/journal",
                    "/tools",
                    "/tools/call",
                    "/ambient/timeline",
                    "/ambient/usage",
                    "/ambient/search"
                ],
                "tools": "Canonical MCP-compatible tool surface. Call /tools for schemas, then /tools/call?name=search&query=...",
                "timeline_params": "All list endpoints accept: from, to (dates: YYYY-MM-DD, ISO8601, 'today', 'yesterday', '3d', '2w', '1m'), days (int), hours (recent only)"
            ])

        default:
            // Check for /meetings/:id, /dictations/:id, /memos/:id
            if let id = Self.extractId(from: cleanPath, prefix: "/meetings/") {
                let result = await callWorkspaceTool("get_meeting", arguments: ["id": .string(id.uuidString)])
                if let meeting = result.payload.objectValue?["meeting"], meeting != .null {
                    return RouteResponse(status: 200, body: meeting.apiValue)
                }
                return RouteResponse(status: 404, body: ["error": "Meeting not found"])
            }
            if let id = Self.extractId(from: cleanPath, prefix: "/dictations/") {
                let result = await callWorkspaceTool("get_dictation", arguments: ["id": .string(id.uuidString)])
                if let dictation = result.payload.objectValue?["dictation"], dictation != .null {
                    return RouteResponse(status: 200, body: dictation.apiValue)
                }
                return RouteResponse(status: 404, body: ["error": "Dictation not found"])
            }
            if let id = Self.extractId(from: cleanPath, prefix: "/memos/") {
                let result = await callWorkspaceTool("get_memo", arguments: ["id": .string(id.uuidString)])
                if let memo = result.payload.objectValue?["memo"], memo != .null {
                    return RouteResponse(status: 200, body: memo.apiValue)
                }
                return RouteResponse(status: 404, body: ["error": "Memo not found"])
            }

            return RouteResponse(status: 404, body: ["error": "Not found. Try /status for available endpoints."])
        }
    }

    private nonisolated func callWorkspaceTool(
        _ name: String,
        arguments: [String: JSONValue]
    ) async -> WorkspaceToolCallResult {
        await WorkspaceTools.handle(
            tool: name,
            arguments: arguments,
            dataStore: queryEngine.dataStore
        )
    }

    private nonisolated func toolRouteResponse(_ result: WorkspaceToolCallResult) -> RouteResponse {
        RouteResponse(status: result.isError ? 400 : 200, body: result.apiBody)
    }

    private nonisolated static func toolArguments(
        from query: [String: String],
        aliases: [String: String] = [:],
        dropping droppedKeys: Set<String> = []
    ) -> [String: JSONValue] {
        var args: [String: JSONValue] = [:]
        for (rawKey, rawValue) in query where !droppedKeys.contains(rawKey) {
            let key = aliases[rawKey] ?? rawKey
            args[key] = queryValue(rawValue)
        }
        return args
    }

    private nonisolated static func queryValue(_ value: String) -> JSONValue {
        if let int = Int(value) {
            return .int(int)
        }
        if value == "true" {
            return .bool(true)
        }
        if value == "false" {
            return .bool(false)
        }
        return .string(value)
    }

    private nonisolated static func extractId(from path: String, prefix: String) -> UUID? {
        guard path.hasPrefix(prefix) else { return nil }
        let idString = String(path.dropFirst(prefix.count))
        return UUID(uuidString: idString)
    }

    // MARK: - HTTP helpers

    private nonisolated static func parseHTTPRequest(
        _ raw: String
    ) -> (method: String, path: String, query: [String: String], headers: [String: String]) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return ("", "/", [:], [:]) }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return ("", "/", [:], [:]) }

        let method = String(parts[0])
        let fullPath = String(parts[1])

        let pathAndQuery = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathAndQuery[0])
        var queryParams: [String: String] = [:]

        if pathAndQuery.count > 1 {
            let queryString = String(pathAndQuery[1])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    queryParams[key] = value
                }
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colonIdx]).lowercased()
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return (method, path, queryParams, headers)
    }

    private nonisolated func sendResponse(connection: NWConnection, status: Int, body: Any) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 431: statusText = "Request Header Fields Too Large"
        case 503: statusText = "Service Unavailable"
        case 500: statusText = "Internal Server Error"
        default:  statusText = "Error"
        }

        let jsonData: Data
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
            jsonData = data
        } else {
            jsonData = Data("{\"error\":\"Serialization failed\"}".utf8)
        }

        let header = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(jsonData.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var responseData = Data(header.utf8)
        responseData.append(jsonData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Port file

    nonisolated static var runtimeDirectoryPath: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".\(AppRuntime.localIdentitySlug)", isDirectory: true)
    }

    nonisolated static var portFilePath: URL {
        runtimeDirectoryPath.appendingPathComponent("api.port")
    }

    private func writePortFile() {
        let url = Self.portFilePath
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "\(port)".write(to: url, atomically: true, encoding: .utf8)
    }

    private func removePortFile() {
        try? FileManager.default.removeItem(at: Self.portFilePath)
    }

    // MARK: - Auth token

    nonisolated static var tokenFilePath: URL {
        runtimeDirectoryPath.appendingPathComponent("api.token")
    }

    private static func loadOrCreateToken() -> String? {
        let url = tokenFilePath
        guard secureRuntimeDirectory() else { return nil }

        if FileManager.default.fileExists(atPath: url.path) {
            guard enforceTokenFilePermissions(at: url),
                  let data = try? Data(contentsOf: url),
                  let existing = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !existing.isEmpty else {
                return nil
            }
            return existing
        }

        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let data = Data(token.utf8)
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            print("[LocalAPI] Refusing to create auth token: \(String(cString: strerror(errno)))")
            return nil
        }
        defer { Darwin.close(descriptor) }

        let written = data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(descriptor, baseAddress, bytes.count)
        }
        guard written == data.count,
              Darwin.fsync(descriptor) == 0,
              enforceTokenFilePermissions(at: url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return token
    }

    private static func secureRuntimeDirectory() -> Bool {
        let directory = runtimeDirectoryPath
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            print("[LocalAPI] Failed to create private runtime directory: \(error)")
            return false
        }

        guard var status = fileStatus(at: directory),
              status.st_uid == geteuid(),
              (status.st_mode & S_IFMT) == S_IFDIR,
              chmod(directory.path, S_IRWXU) == 0,
              let verified = fileStatus(at: directory) else {
            print("[LocalAPI] Runtime directory is not a private, owned directory.")
            return false
        }
        status = verified
        return status.st_uid == geteuid()
            && (status.st_mode & S_IFMT) == S_IFDIR
            && (status.st_mode & 0o077) == 0
    }

    private nonisolated static func fileStatus(at url: URL) -> stat? {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        return result == 0 ? status : nil
    }

    @discardableResult
    nonisolated static func enforceTokenFilePermissions(at url: URL) -> Bool {
        guard let initial = fileStatus(at: url),
              initial.st_uid == geteuid(),
              (initial.st_mode & S_IFMT) == S_IFREG else {
            print("[LocalAPI] Refusing an unowned, non-regular, or symlinked auth token file.")
            return false
        }

        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0,
              let verified = fileStatus(at: url),
              verified.st_uid == geteuid(),
              (verified.st_mode & S_IFMT) == S_IFREG,
              (verified.st_mode & 0o077) == 0 else {
            print("[LocalAPI] Failed to verify private auth token permissions.")
            return false
        }
        return true
    }
}

private final class LocalAPIAuthTokenStore: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func set(_ token: String?) {
        lock.withLock { self.token = token }
    }

    func value() -> String? {
        lock.withLock { token }
    }
}

private extension WorkspaceToolCallResult {
    var apiBody: Any {
        [
            "tool": toolName,
            "isError": isError,
            "payload": payload.apiValue
        ]
    }
}

private extension JSONValue {
    var apiArray: [Any]? {
        if case .array(let values) = self {
            return values.map(\.apiValue)
        }
        return nil
    }

    var apiValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.apiValue)
        case .object(let object):
            return object.mapValues(\.apiValue)
        }
    }
}
