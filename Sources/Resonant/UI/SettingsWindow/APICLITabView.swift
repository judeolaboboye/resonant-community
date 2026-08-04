import SwiftUI

struct APICLITabView: View {
    @Environment(AppState.self) private var appState
    @State private var copiedField: String?

    private var baseURL: String {
        "http://127.0.0.1:\(appState.localAPIServer.port)"
    }

    private var toolsURL: String {
        "\(baseURL)/v1/tools"
    }

    private var curlExample: String {
        "curl -H \"Authorization: Bearer $(cat \(LocalAPIServer.tokenFilePath.path))\" \(toolsURL)"
    }

    var body: some View {
        @Bindable var settings = appState.settingsManager

        SettingsPage(title: "Local API") {
            SettingsCardSection(
                "Server",
                footer: "Runs on 127.0.0.1 only. Dictations, memos, meetings, and journal data stay on this Mac."
            ) {
                SettingsToggleRow("Enable local API", isOn: $settings.localAPIEnabled)

                SettingsRowDivider()
                SettingsValueRow("Status", detail: "Loopback HTTP server") {
                    statusRow
                }
            }
            .id(SettingsAnchor.apiToggle)

            SettingsCardSection("Connect", footer: "Requests use the local bearer token and never leave your machine.") {
                copyableRow(
                    label: "Base URL",
                    detail: "Use this from local scripts and HTTP clients.",
                    value: baseURL,
                    field: "url",
                    buttonTitle: "Copy URL"
                )
                SettingsRowDivider()
                copyableRow(
                    label: "Tools Endpoint",
                    detail: "Mirrors the MCP tool surface.",
                    value: toolsURL,
                    field: "tools",
                    buttonTitle: "Copy Endpoint"
                )
                SettingsRowDivider()
                copyableRow(
                    label: "Example",
                    detail: "Uses the bearer token saved in \(LocalAPIServer.tokenFilePath.path).",
                    value: curlExample,
                    field: "curl",
                    buttonTitle: "Copy cURL",
                    lineLimit: 4
                )
            }
            .id(SettingsAnchor.apiConnect)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if !appState.settingsManager.localAPIEnabled {
            SettingsStatusPill(title: "Off", detail: "Not listening", systemImage: "power", tint: .gray)
        } else if appState.localAPIServer.isRunning {
            SettingsStatusPill(
                title: "Running",
                detail: "Port \(appState.localAPIServer.port)",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        } else {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Starting…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyableRow(
        label: String,
        detail: String,
        value: String,
        field: String,
        buttonTitle: String,
        lineLimit: Int = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    copy(value, field: field)
                } label: {
                    Label(
                        copiedField == field ? "Copied" : buttonTitle,
                        systemImage: copiedField == field ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            SettingsCodeBlock(text: value, lineLimit: lineLimit)
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
    }

    private func copy(_ value: String, field: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedField = field
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedField == field { copiedField = nil }
        }
    }
}
