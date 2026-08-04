import AppKit

// When launched with --mcp, run as a headless MCP stdio server instead of the GUI.
if CommandLine.arguments.contains("--mcp") {
    Task { @MainActor in
        let dataStore = DataStore()
        await dataStore.setup()
        let server = MCPServer(dataStore: dataStore)
        await server.run()
        exit(0)
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.run()
}
