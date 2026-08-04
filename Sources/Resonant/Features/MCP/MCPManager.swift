import Foundation

/// Manages the MCP server lifecycle within the main app.
///
/// When enabled, installs a `resonant-mcp` wrapper script and auto-registers
/// with detected MCP clients (Claude Code, Cursor, Windsurf). When disabled,
/// removes the script and deregisters from all clients.
@MainActor
@Observable
final class MCPManager {

    private(set) var isActive = false
    private(set) var installedScriptPath: String?
    private(set) var registeredClients: [MCPClient] = []
    private var latestToggleGeneration: UInt64 = 0

    private let dataStore: DataStore

    /// The directory where the MCP wrapper script is installed.
    static let installDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/bin")
    }()

    static var scriptName: String {
        "\(AppRuntime.localIdentitySlug)-mcp"
    }

    static var scriptURL: URL {
        installDirectory.appendingPathComponent(scriptName)
    }

    static var serverKey: String {
        AppRuntime.localIdentitySlug
    }

    // MARK: - Known MCP clients

    enum ConfigFormat: Sendable, Hashable {
        case json
        case codexToml
    }

    struct ConfigTarget: Sendable, Hashable {
        let url: URL
        let format: ConfigFormat
    }

    enum MCPClient: String, CaseIterable, Identifiable {
        case codex     = "Codex"
        case claudeCode = "Claude Code"
        case cursor     = "Cursor"
        case windsurf   = "Windsurf"

        var id: String { rawValue }

        fileprivate static func claudeBinaryExists() -> Bool {
            let candidates = [
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/local/claude").path
            ]
            return candidates.contains { FileManager.default.fileExists(atPath: $0) }
        }

        var configURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .codex:      return home.appendingPathComponent(".codex/config.toml")
            case .claudeCode: return home.appendingPathComponent(".claude.json")
            case .cursor:     return home.appendingPathComponent(".cursor/mcp.json")
            case .windsurf:   return home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
            }
        }

        var configTarget: ConfigTarget {
            ConfigTarget(
                url: configURL,
                format: self == .codex ? .codexToml : .json
            )
        }

        var isInstalled: Bool {
            switch self {
            case .codex:
                let home = FileManager.default.homeDirectoryForCurrentUser
                let fm = FileManager.default
                if fm.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path) { return true }
                if fm.fileExists(atPath: home.appendingPathComponent(".codex").path) { return true }
                return [
                    "/usr/local/bin/codex",
                    "/opt/homebrew/bin/codex"
                ].contains { fm.fileExists(atPath: $0) }
            case .claudeCode:
                let home = FileManager.default.homeDirectoryForCurrentUser
                let fm = FileManager.default
                // Primary: user-scope MCP config file. Secondary: settings dir. Tertiary: claude binary on PATH.
                if fm.fileExists(atPath: home.appendingPathComponent(".claude.json").path) { return true }
                if fm.fileExists(atPath: home.appendingPathComponent(".claude").path) { return true }
                return Self.claudeBinaryExists()
            case .cursor:
                let apps = [
                    "/Applications/Cursor.app",
                    FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Applications/Cursor.app").path
                ]
                return apps.contains { FileManager.default.fileExists(atPath: $0) }
                    || FileManager.default.fileExists(
                        atPath: FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".cursor").path
                    )
            case .windsurf:
                let apps = [
                    "/Applications/Windsurf.app",
                    FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Applications/Windsurf.app").path
                ]
                return apps.contains { FileManager.default.fileExists(atPath: $0) }
                    || FileManager.default.fileExists(
                        atPath: FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".codeium").path
                    )
            }
        }
    }

    /// The JSON config snippet for manual setup.
    static var configSnippet: String {
        """
        {
          "mcpServers": {
            "\(serverKey)": {
              "command": "\(scriptURL.path)"
            }
          }
        }
        """
    }

    static var codexConfigSnippet: String {
        """
        [mcp_servers.\(serverKey)]
        command = "\(scriptURL.path)"
        """
    }

    init(dataStore: DataStore) {
        self.dataStore = dataStore
        if MCPConfigWriter.isManagedScript(at: Self.scriptURL) {
            installedScriptPath = Self.scriptURL.path
            isActive = true
        }
        refreshRegisteredClients()
    }

    // MARK: - Enable / Disable

    func enable() {
        let serverEntry: [String: Any] = ["command": Self.scriptURL.path]
        guard let entryData = try? JSONSerialization.data(withJSONObject: serverEntry) else { return }

        let targets = MCPClient.allCases.filter(\.isInstalled).map(\.configTarget)
        let all = MCPClient.allCases.map { ($0, $0.configTarget) }
        let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "Resonant"
        let generation = nextToggleGeneration()

        Task { [configWriter] in
            let result = await configWriter.serializedInstallAndRegister(
                executablePath: executablePath,
                scriptURL: Self.scriptURL,
                installDirectory: Self.installDirectory,
                entryData: entryData,
                targets: targets,
                all: all.map(\.1)
            )
            let registered = all.filter { result.registeredTargets.contains($0.1) }.map(\.0)
            await MainActor.run {
                guard self.shouldApplyToggleResult(generation) else { return }
                self.registeredClients = registered
                self.installedScriptPath = result.scriptInstalled ? Self.scriptURL.path : nil
                self.isActive = result.scriptInstalled
            }
        }
    }

    func disable() {
        let all = MCPClient.allCases.map { ($0, $0.configTarget) }
        let generation = nextToggleGeneration()

        Task { [configWriter] in
            let registeredTargets = await configWriter.serializedDeregisterAndRemove(
                all: all.map(\.1),
                scriptURL: Self.scriptURL
            )
            let registered = all.filter { registeredTargets.contains($0.1) }.map(\.0)
            await MainActor.run {
                guard self.shouldApplyToggleResult(generation) else { return }
                self.registeredClients = registered
                self.installedScriptPath = nil
                self.isActive = false
            }
        }
    }

    // MARK: - Client registration
    //
    // All wrapper-script and config-file I/O goes through `configWriter`.
    // Invariant: install always happens before register, and deregister always
    // happens before remove, within one serialized queue so rapid toggles
    // cannot leave clients pointing at a deleted script.

    private let configWriter = MCPConfigWriter(serverKey: serverKey)

    func refreshRegisteredClients() {
        let all = MCPClient.allCases.map { ($0, $0.configTarget) }
        Task { [configWriter] in
            let registeredTargets = await configWriter.collectRegistered(
                all.map(\.1),
                commandPath: Self.scriptURL.path
            )
            let registered = all.filter { registeredTargets.contains($0.1) }.map(\.0)
            await MainActor.run { self.registeredClients = registered }
        }
    }

    private func nextToggleGeneration() -> UInt64 {
        latestToggleGeneration &+= 1
        return latestToggleGeneration
    }

    private func shouldApplyToggleResult(_ generation: UInt64) -> Bool {
        generation == latestToggleGeneration
    }

    /// Run the MCP server in stdio mode (called when app is launched with --mcp).
    func runStdioServer() async {
        let server = MCPServer(dataStore: dataStore)
        await server.run()
    }
}

/// Serializes wrapper-script and third-party MCP client config file I/O.
/// An internal task chain establishes one total order for install/register,
/// refresh, and deregister/remove transactions.
actor MCPConfigWriter {
    nonisolated static let managedScriptMarker = "# Managed by Resonant MCP"

    nonisolated static func isManagedScript(at scriptURL: URL) -> Bool {
        guard let contents = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            return false
        }
        return contents.contains(managedScriptMarker)
    }

    struct SerializedRegistrationResult: Sendable {
        let scriptInstalled: Bool
        let registeredTargets: Set<MCPManager.ConfigTarget>
    }

    private let serverKey: String
    private var pendingOperation: Task<Void, Never>?

    init(serverKey: String) {
        self.serverKey = serverKey
    }

    /// Chains synchronous filesystem transactions so async callers still share
    /// one serialization point without blocking the actor on I/O.
    private func enqueue<T: Sendable>(_ operation: @Sendable @escaping () -> T) async -> T {
        let previous = pendingOperation
        let task = Task<T, Never> {
            if let previous {
                await previous.value
            }
            return operation()
        }
        pendingOperation = Task {
            _ = await task.value
        }
        return await task.value
    }

    func serializedInstallAndRegister(
        executablePath: String,
        scriptURL: URL,
        installDirectory: URL,
        entryData: Data,
        targets: [MCPManager.ConfigTarget],
        all: [MCPManager.ConfigTarget]
    ) async -> SerializedRegistrationResult {
        let serverKey = self.serverKey
        return await enqueue {
            let scriptInstalled = Self.installScript(
                executablePath: executablePath,
                scriptURL: scriptURL,
                installDirectory: installDirectory
            )
            if scriptInstalled {
                for target in targets {
                    Self.register(
                        entryData: entryData,
                        commandPath: scriptURL.path,
                        target: target,
                        serverKey: serverKey
                    )
                }
            }
            let registeredTargets = Self.collectRegistered(
                all,
                serverKey: serverKey,
                commandPath: scriptURL.path
            )
            return SerializedRegistrationResult(
                scriptInstalled: scriptInstalled,
                registeredTargets: registeredTargets
            )
        }
    }

    func serializedDeregisterAndRemove(
        all: [MCPManager.ConfigTarget],
        scriptURL: URL
    ) async -> Set<MCPManager.ConfigTarget> {
        let serverKey = self.serverKey
        return await enqueue {
            for target in all {
                Self.deregister(
                    target: target,
                    serverKey: serverKey,
                    commandPath: scriptURL.path
                )
            }
            let registeredTargets = Self.collectRegistered(
                all,
                serverKey: serverKey,
                commandPath: scriptURL.path
            )
            Self.removeScript(at: scriptURL)
            return registeredTargets
        }
    }

    func collectRegistered(
        _ targets: [MCPManager.ConfigTarget],
        commandPath: String
    ) async -> Set<MCPManager.ConfigTarget> {
        let serverKey = self.serverKey
        return await enqueue {
            Self.collectRegistered(
                targets,
                serverKey: serverKey,
                commandPath: commandPath
            )
        }
    }

    private static func installScript(
        executablePath: String,
        scriptURL: URL,
        installDirectory: URL
    ) -> Bool {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)

            if fm.fileExists(atPath: scriptURL.path) {
                guard isManagedScript(at: scriptURL) else {
                    print("[MCPManager] Refusing to overwrite unmanaged script at \(scriptURL.path)")
                    return false
                }
            }

            let script = """
            #!/bin/sh
            \(managedScriptMarker)
            exec \(shellSingleQuoted(executablePath)) --mcp "$@"
            """

            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return true
        } catch {
            print("[MCPManager] Failed to install MCP script: \(error)")
            return false
        }
    }

    private nonisolated static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func removeScript(at scriptURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scriptURL.path),
              isManagedScript(at: scriptURL) else { return }
        try? fm.removeItem(at: scriptURL)
    }

    private static func register(
        entryData: Data,
        commandPath: String,
        target: MCPManager.ConfigTarget,
        serverKey: String
    ) {
        switch target.format {
        case .json:
            registerJSON(
                entryData: entryData,
                commandPath: commandPath,
                at: target.url,
                serverKey: serverKey
            )
        case .codexToml:
            registerCodexTOML(commandPath: commandPath, at: target.url, serverKey: serverKey)
        }
    }

    private static func registerJSON(
        entryData: Data,
        commandPath: String,
        at configURL: URL,
        serverKey: String
    ) {
        let fm = FileManager.default
        try? fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let entry = try? JSONSerialization.jsonObject(with: entryData) as? [String: Any] else { return }

        var config: [String: Any] = [:]
        if fm.fileExists(atPath: configURL.path) {
            // File exists — must parse successfully, otherwise abort to avoid
            // clobbering other keys (e.g. Claude Code stores project history,
            // auth, and settings alongside `mcpServers` in ~/.claude.json).
            guard let data = try? Data(contentsOf: configURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[MCPConfigWriter] Refusing to overwrite \(configURL.path): existing file failed to parse")
                return
            }
            config = json
        }

        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        if let existing = servers[serverKey] {
            guard serverEntryCommand(existing) == commandPath else {
                print("[MCPConfigWriter] Refusing to replace unmanaged MCP entry '\(serverKey)' in \(configURL.path)")
                return
            }
        }
        servers[serverKey] = entry
        config["mcpServers"] = servers

        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    private static func registerCodexTOML(commandPath: String, at configURL: URL, serverKey: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        if containsCodexTOMLServerSection(existing, serverKey: serverKey),
           !isRegisteredCodexTOML(
               text: existing,
               serverKey: serverKey,
               commandPath: commandPath
           ) {
            print("[MCPConfigWriter] Refusing to replace unmanaged MCP entry '\(serverKey)' in \(configURL.path)")
            return
        }
        var text = removeCodexTOMLServerSection(from: existing, serverKey: serverKey)
            .trimmingCharacters(in: .newlines)
        if !text.isEmpty {
            text += "\n\n"
        }
        text += """
        [mcp_servers.\(serverKey)]
        command = "\(escapeTOMLString(commandPath))"
        """
        text += "\n"
        try? text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private static func deregister(
        target: MCPManager.ConfigTarget,
        serverKey: String,
        commandPath: String
    ) {
        switch target.format {
        case .json:
            deregisterJSON(at: target.url, serverKey: serverKey, commandPath: commandPath)
        case .codexToml:
            deregisterCodexTOML(at: target.url, serverKey: serverKey, commandPath: commandPath)
        }
    }

    private static func deregisterJSON(
        at configURL: URL,
        serverKey: String,
        commandPath: String
    ) {
        guard let data = try? Data(contentsOf: configURL),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var servers = config["mcpServers"] as? [String: Any],
              let existing = servers[serverKey],
              serverEntryCommand(existing) == commandPath else {
            return
        }
        servers.removeValue(forKey: serverKey)
        config["mcpServers"] = servers
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    private static func deregisterCodexTOML(
        at configURL: URL,
        serverKey: String,
        commandPath: String
    ) {
        guard let existing = try? String(contentsOf: configURL, encoding: .utf8),
              isRegisteredCodexTOML(
                  text: existing,
                  serverKey: serverKey,
                  commandPath: commandPath
              ) else { return }
        let text = removeCodexTOMLServerSection(from: existing, serverKey: serverKey)
            .trimmingCharacters(in: .newlines) + "\n"
        try? text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private static func collectRegistered(
        _ targets: [MCPManager.ConfigTarget],
        serverKey: String,
        commandPath: String
    ) -> Set<MCPManager.ConfigTarget> {
        var result: Set<MCPManager.ConfigTarget> = []
        for target in targets where isRegistered(
            target: target,
            serverKey: serverKey,
            commandPath: commandPath
        ) {
            result.insert(target)
        }
        return result
    }

    private static func isRegistered(
        target: MCPManager.ConfigTarget,
        serverKey: String,
        commandPath: String
    ) -> Bool {
        switch target.format {
        case .json:
            return isRegisteredJSON(at: target.url, serverKey: serverKey, commandPath: commandPath)
        case .codexToml:
            return isRegisteredCodexTOML(at: target.url, serverKey: serverKey, commandPath: commandPath)
        }
    }

    private static func isRegisteredJSON(
        at configURL: URL,
        serverKey: String,
        commandPath: String
    ) -> Bool {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = config["mcpServers"] as? [String: Any],
              let entry = servers[serverKey] else {
            return false
        }
        return serverEntryCommand(entry) == commandPath
    }

    private static func isRegisteredCodexTOML(
        at configURL: URL,
        serverKey: String,
        commandPath: String
    ) -> Bool {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return false
        }
        return isRegisteredCodexTOML(
            text: text,
            serverKey: serverKey,
            commandPath: commandPath
        )
    }

    private static func isRegisteredCodexTOML(
        text: String,
        serverKey: String,
        commandPath: String
    ) -> Bool {
        var inRootSection = false
        let expectedCommand = "command = \"\(escapeTOMLString(commandPath))\""

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "[mcp_servers.\(serverKey)]" {
                inRootSection = true
                continue
            }
            if inRootSection && isTOMLTableHeader(trimmed) {
                return false
            }
            if inRootSection && trimmed == expectedCommand {
                return true
            }
        }
        return false
    }

    private static func containsCodexTOMLServerSection(
        _ text: String,
        serverKey: String
    ) -> Bool {
        text.components(separatedBy: .newlines)
            .contains { isCodexTOMLServerHeader($0, serverKey: serverKey) }
    }

    private static func serverEntryCommand(_ entry: Any) -> String? {
        (entry as? [String: Any])?["command"] as? String
    }

    private static func removeCodexTOMLServerSection(from text: String, serverKey: String) -> String {
        var output: [String] = []
        var skipping = false

        for line in text.components(separatedBy: .newlines) {
            if isCodexTOMLServerHeader(line, serverKey: serverKey) {
                skipping = true
                continue
            }
            if skipping && isTOMLTableHeader(line) {
                skipping = false
            }
            if !skipping {
                output.append(line)
            }
        }

        return output.joined(separator: "\n")
    }

    private static func isCodexTOMLServerHeader(_ line: String, serverKey: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "[mcp_servers.\(serverKey)]"
            || trimmed.hasPrefix("[mcp_servers.\(serverKey).")
    }

    private static func isTOMLTableHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
    }

    private static func escapeTOMLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
