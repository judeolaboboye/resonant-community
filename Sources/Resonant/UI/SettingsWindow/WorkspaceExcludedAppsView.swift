import SwiftUI

/// Excluded apps editor for ambient context capture. Sub-page drilled into
/// from the Privacy tab so the main page can stay short.
struct WorkspaceExcludedAppsView: View {
    @Environment(AppState.self) private var appState
    @State private var newExcludedBundleId = ""

    var body: some View {
        SettingsPage(
            title: "Excluded apps",
            subtitle: "Bundle IDs listed here are never used for ambient context."
        ) {
            SettingsBackLink(target: .workspace) {
                appState.selectedSettingsTab = .workspace
            }

            SettingsCardSection("Add an app") {
                SettingsValueRow(
                    "Bundle ID",
                    detail: "Use a bundle ID like com.example.app."
                ) {
                    HStack(spacing: 8) {
                        TextField("com.example.app", text: $newExcludedBundleId)
                            .settingsRowTextField(maxWidth: 220, isMonospaced: true)
                            .onSubmit(addExcludedBundleId)

                        Button(action: addExcludedBundleId) {
                            Label("Add", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canAddExcludedBundleId)
                    }
                }
            }

            SettingsCardSection("Excluded") {
                let excludedBundleIds = appState.settingsManager.ambientExcludedBundleIds
                if excludedBundleIds.isEmpty {
                    SettingsSectionBody {
                        Text("No apps are excluded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(excludedBundleIds.enumerated()), id: \.element) { index, bundleId in
                        if index > 0 { SettingsRowDivider() }
                        SettingsValueRow(displayName(for: bundleId)) {
                            Button {
                                appState.settingsManager.ambientExcludedBundleIds.removeAll { $0 == bundleId }
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.regular)
                            .help("Remove excluded app")
                        }
                    }
                }
            }
        }
    }

    private var trimmedExcludedBundleId: String {
        newExcludedBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddExcludedBundleId: Bool {
        !trimmedExcludedBundleId.isEmpty
            && !appState.settingsManager.ambientExcludedBundleIds.contains(trimmedExcludedBundleId)
    }

    private func addExcludedBundleId() {
        guard canAddExcludedBundleId else { return }
        appState.settingsManager.ambientExcludedBundleIds.append(trimmedExcludedBundleId)
        newExcludedBundleId = ""
    }

    private func displayName(for bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
           let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return "\(name) (\(bundleId))"
        }
        return bundleId
    }
}
