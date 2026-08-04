import Foundation
import XCTest
@testable import Resonant

final class MCPConfigWriterTests: XCTestCase {
    func testCodexTOMLRegistrationPreservesOtherSectionsAndEscapesCommand() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configURL = fixture.root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        model = "gpt-5.4"

        [mcp_servers.other]
        command = "/bin/other"

        [tools]
        web_search = true
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let writer = MCPConfigWriter(serverKey: "resonant")
        let target = MCPManager.ConfigTarget(url: configURL, format: .codexToml)
        let commandURL = fixture.root.appendingPathComponent(#"bin/resonant "quoted"\mcp"#)
        let result = await writer.serializedInstallAndRegister(
            executablePath: "/Applications/Resonant.app/Contents/MacOS/Resonant",
            scriptURL: commandURL,
            installDirectory: commandURL.deletingLastPathComponent(),
            entryData: Data(#"{"command":"/unused/json"}"#.utf8),
            targets: [target],
            all: [target]
        )

        XCTAssertTrue(result.scriptInstalled)
        XCTAssertEqual(result.registeredTargets, [target])
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#"model = "gpt-5.4""#))
        XCTAssertTrue(text.contains("[mcp_servers.other]"))
        XCTAssertTrue(text.contains("[tools]"))
        XCTAssertTrue(text.contains("[mcp_servers.resonant]"))
        XCTAssertTrue(text.contains(#"command = ""#))
        XCTAssertTrue(text.contains(#"\"quoted\""#))
        XCTAssertTrue(text.contains(#"\\mcp""#))
    }

    func testCodexTOMLDeregisterRemovesOnlyResonantSectionAndScript() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configURL = fixture.root.appendingPathComponent(".codex/config.toml")
        let scriptURL = fixture.root.appendingPathComponent("bin/resonant-mcp")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [mcp_servers.other]
        command = "/bin/other"

        [mcp_servers.resonant]
        command = "\(scriptURL.path)"

        [mcp_servers.resonant.env]
        RESONANT_TEST = "1"

        [tools]
        web_search = true
        """.write(to: configURL, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        \(MCPConfigWriter.managedScriptMarker)
        exec "/Applications/Resonant.app/Contents/MacOS/Resonant" --mcp "$@"
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        let writer = MCPConfigWriter(serverKey: "resonant")
        let target = MCPManager.ConfigTarget(url: configURL, format: .codexToml)
        let registered = await writer.serializedDeregisterAndRemove(
            all: [target],
            scriptURL: scriptURL
        )

        XCTAssertTrue(registered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptURL.path))
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[mcp_servers.other]"))
        XCTAssertTrue(text.contains("[tools]"))
        XCTAssertFalse(text.contains("[mcp_servers.resonant]"))
        XCTAssertFalse(text.contains("[mcp_servers.resonant.env]"))
    }

    func testJSONRegistrationRefusesToOverwriteInvalidConfig() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configURL = fixture.root.appendingPathComponent("client/mcp.json")
        let scriptURL = fixture.root.appendingPathComponent("bin/resonant-mcp")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{invalid json".write(to: configURL, atomically: true, encoding: .utf8)

        let writer = MCPConfigWriter(serverKey: "resonant")
        let target = MCPManager.ConfigTarget(url: configURL, format: .json)
        let result = await writer.serializedInstallAndRegister(
            executablePath: "/Applications/Resonant.app/Contents/MacOS/Resonant",
            scriptURL: scriptURL,
            installDirectory: scriptURL.deletingLastPathComponent(),
            entryData: Data(#"{"command":"/tmp/resonant-mcp"}"#.utf8),
            targets: [target],
            all: [target]
        )

        XCTAssertTrue(result.scriptInstalled)
        XCTAssertTrue(result.registeredTargets.isEmpty)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "{invalid json")
    }

    func testDeregisterPreservesForeignEntryAndUnmanagedScript() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configURL = fixture.root.appendingPathComponent("client/mcp.json")
        let scriptURL = fixture.root.appendingPathComponent("bin/resonant-mcp")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"mcpServers":{"resonant":{"command":"/usr/local/bin/foreign"}}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        try "foreign script".write(to: scriptURL, atomically: true, encoding: .utf8)

        let writer = MCPConfigWriter(serverKey: "resonant")
        let target = MCPManager.ConfigTarget(url: configURL, format: .json)
        let registered = await writer.serializedDeregisterAndRemove(
            all: [target],
            scriptURL: scriptURL
        )

        XCTAssertTrue(registered.isEmpty)
        XCTAssertEqual(try String(contentsOf: scriptURL, encoding: .utf8), "foreign script")
        XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains("/usr/local/bin/foreign"))
    }

    func testRegistrationPreservesForeignEntryWithSameServerKey() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configURL = fixture.root.appendingPathComponent("client/mcp.json")
        let scriptURL = fixture.root.appendingPathComponent("bin/resonant-mcp")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"mcpServers":{"resonant":{"command":"/usr/local/bin/foreign"}}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)

        let writer = MCPConfigWriter(serverKey: "resonant")
        let target = MCPManager.ConfigTarget(url: configURL, format: .json)
        let result = await writer.serializedInstallAndRegister(
            executablePath: "/Applications/Resonant.app/Contents/MacOS/Resonant",
            scriptURL: scriptURL,
            installDirectory: scriptURL.deletingLastPathComponent(),
            entryData: Data("{\"command\":\"\(scriptURL.path)\"}".utf8),
            targets: [target],
            all: [target]
        )

        XCTAssertTrue(result.scriptInstalled)
        XCTAssertTrue(result.registeredTargets.isEmpty)
        XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains("/usr/local/bin/foreign"))
    }

    func testManagedWrapperShellQuotesExecutablePath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configURL = fixture.root.appendingPathComponent("client/mcp.json")
        let scriptURL = fixture.root.appendingPathComponent("bin/resonant-mcp")
        let target = MCPManager.ConfigTarget(url: configURL, format: .json)
        let executable = "/Applications/Resonant's; touch injected.app/Contents/MacOS/Resonant"
        let writer = MCPConfigWriter(serverKey: "resonant")

        let result = await writer.serializedInstallAndRegister(
            executablePath: executable,
            scriptURL: scriptURL,
            installDirectory: scriptURL.deletingLastPathComponent(),
            entryData: Data("{\"command\":\"\(scriptURL.path)\"}".utf8),
            targets: [target],
            all: [target]
        )

        XCTAssertTrue(result.scriptInstalled)
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("exec '/Applications/Resonant'\"'\"'s; touch injected.app/Contents/MacOS/Resonant' --mcp \"$@\""))
    }
}

private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResonantMCPConfigWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
