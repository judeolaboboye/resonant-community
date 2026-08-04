import SwiftUI

struct MCPServerTabView: View {
    @Environment(AppState.self) private var appState
    @State private var didCopyConfig = false
    @State private var didCopyCodexConfig = false

    var body: some View {
        @Bindable var settings = appState.settingsManager

        SettingsPage(title: "MCP Server") {
            SettingsCardSection(
                "Server",
                footer: "Installs a local wrapper and registers detected clients. Workspace data stays on this Mac."
            ) {
                SettingsToggleRow("Enable MCP server", isOn: $settings.mcpServerEnabled)

                SettingsRowDivider()
                SettingsValueRow("Status", detail: "Local wrapper script") {
                    serverStatusRow
                }

                SettingsRowDivider()
                SettingsValueRow("Clients", detail: "Detected MCP apps") {
                    registeredClients
                }
            }
            .id(SettingsAnchor.mcpToggle)

            SettingsCardSection("Config", footer: "Paste one of these snippets into an MCP client when automatic registration is unavailable.") {
                configSnippet
            }
            .id(SettingsAnchor.mcpConfig)
        }
    }

    @ViewBuilder
    private var serverStatusRow: some View {
        if !appState.settingsManager.mcpServerEnabled {
            SettingsStatusPill(title: "Off", detail: "Not installed", systemImage: "power", tint: .gray)
        } else if appState.mcpManager.isActive {
            SettingsStatusPill(
                title: "Installed",
                detail: MCPManager.scriptName,
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        } else {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Installing...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var registeredClients: some View {
        if !appState.settingsManager.mcpServerEnabled {
            Text("Disabled")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !appState.mcpManager.registeredClients.isEmpty {
            HStack(spacing: 6) {
                ForEach(appState.mcpManager.registeredClients) { client in
                    SettingsStatusPill(
                        title: client.rawValue,
                        detail: "Registered",
                        systemImage: "checkmark.circle.fill",
                        tint: .green
                    )
                }
            }
        } else if !appState.mcpManager.isActive {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Installing…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else {
            SettingsStatusPill(title: "Manual setup", detail: "No clients detected", systemImage: "link", tint: .gray)
        }
    }

    private var configSnippet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server JSON")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("Points your client at the local Resonant wrapper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    copyConfig()
                } label: {
                    Label(
                        didCopyConfig ? "Copied" : "Copy Config",
                        systemImage: didCopyConfig ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            SettingsCodeBlock(text: MCPManager.configSnippet)

            Divider()
                .padding(.vertical, 2)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex TOML")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("Add this to ~/.codex/config.toml.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    copyCodexConfig()
                } label: {
                    Label(
                        didCopyCodexConfig ? "Copied" : "Copy Codex",
                        systemImage: didCopyCodexConfig ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            SettingsCodeBlock(text: MCPManager.codexConfigSnippet)
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
    }

    private func copyConfig() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPManager.configSnippet, forType: .string)
        didCopyConfig = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            didCopyConfig = false
        }
    }

    private func copyCodexConfig() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPManager.codexConfigSnippet, forType: .string)
        didCopyCodexConfig = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            didCopyCodexConfig = false
        }
    }
}
