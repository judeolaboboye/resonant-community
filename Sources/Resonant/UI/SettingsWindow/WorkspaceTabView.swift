import Defaults
import SwiftUI

struct WorkspaceTabView: View {
    @Environment(AppState.self) private var appState
    @State private var isShowingClearWorkspaceAlert = false
    @State private var isClearingWorkspace = false
    @State private var didClearWorkspace = false
    @State private var pendingRetentionDays: Int?

    private var storagePath: URL { AppSupportPaths.resonantRoot() }
    private var archivePath: URL { storagePath.appendingPathComponent("archive") }

    var body: some View {
        @Bindable var settings = appState.settingsManager

        SettingsPage(title: "Privacy") {
            SettingsCardSection("Local data", footer: "Local data stays on this Mac.") {
                SettingsToggleRow(
                    "Save audio recordings",
                    detail: "Keep playable recordings with local dictations and memos.",
                    isOn: $settings.saveAudioEnabled
                )

                SettingsRowDivider()
                SettingsPickerRow(
                    "Retention",
                    detail: "Automatically remove older local workspace history.",
                    selection: Binding(
                        get: { settings.historyRetentionDays },
                        set: { newValue in
                            if Self.requiresRetentionConfirmation(
                                currentDays: settings.historyRetentionDays,
                                newDays: newValue
                            ) {
                                pendingRetentionDays = newValue
                            } else {
                                settings.historyRetentionDays = newValue
                            }
                        }
                    ),
                    controlWidth: 180
                ) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("Forever").tag(36500)
                }
            }
            .id(SettingsAnchor.workspaceStorage)

            SettingsCardSection("Local files") {
                SettingsValueRow(
                    "Workspace folder",
                    detail: "The local Resonant workspace root."
                ) {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: storagePath.path)
                    } label: {
                        Label("Open", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                SettingsRowDivider()
                SettingsValueRow(
                    "Archive folder",
                    detail: "Markdown files for Finder, Obsidian, MCP, and the local API."
                ) {
                    Button {
                        try? FileManager.default.createDirectory(at: archivePath, withIntermediateDirectories: true)
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: archivePath.path)
                    } label: {
                        Label("Open", systemImage: "archivebox")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .id(SettingsAnchor.workspaceArchive)

            if AppFeatureVisibility.cloudSync {
                SettingsCardSection("Cloud sync") {
                    SettingsDrillInRow(
                        title: "Cloud Sync",
                        detail: cloudSyncSummary,
                        value: cloudSyncStatusBadge,
                        systemImage: "icloud.fill"
                    ) {
                        appState.pendingSettingsBackTarget = .workspace
                        appState.selectedSettingsTab = .workspaceCloud
                    }
                }
                .id(SettingsAnchor.workspaceCloud)
            }

            SettingsCardSection("Context capture") {
                SettingsToggleRow(
                    "App context",
                    detail: "Attach active app, window title, URL, and related context to dictations.",
                    isOn: $settings.contextMetadataEnabled
                )

                SettingsRowDivider()
                SettingsToggleRow(
                    "Ambient local context",
                    detail: ambientContextDetail,
                    isOn: $settings.ambientContextEnabled
                )
                .disabled(!settings.contextMetadataEnabled || settings.hipaaMode)

                SettingsRowDivider()
                SettingsDrillInRow(
                    title: "Excluded apps",
                    detail: "Apps that never contribute to ambient context.",
                    value: "\(settings.ambientExcludedBundleIds.count)",
                    systemImage: "app.badge"
                ) {
                    appState.pendingSettingsBackTarget = .workspace
                    appState.selectedSettingsTab = .workspaceExcludedApps
                }
            }
            .id(SettingsAnchor.workspacePrivacy)

            SettingsCardSection(
                "Reset",
                footer: "Removes local dictations, memos, journal summaries, archive files, workspace history, and progression stats."
            ) {
                SettingsValueRow(
                    "Local workspace data",
                    detail: "Account and preferences remain."
                ) {
                    Button(role: .destructive) {
                        didClearWorkspace = false
                        isShowingClearWorkspaceAlert = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isClearingWorkspace)
                }

                if isClearingWorkspace {
                    SettingsRowDivider()
                    SettingsSectionBody {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Clearing workspace...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if didClearWorkspace {
                    SettingsRowDivider()
                    SettingsSectionBody {
                        Label("Workspace cleared", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .id(SettingsAnchor.workspaceReset)
        }
        .alert("Clear Workspace Data?", isPresented: $isShowingClearWorkspaceAlert) {
            Button("Clear", role: .destructive) {
                guard !isClearingWorkspace else { return }
                isClearingWorkspace = true
                didClearWorkspace = false
                Task {
                    await appState.clearWorkspace()
                    isClearingWorkspace = false
                    didClearWorkspace = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes local workspace content and clears the exported workspace history. Your account and preferred settings will remain.")
        }
        .alert(
            "Shorten Data Retention?",
            isPresented: Binding(
                get: { pendingRetentionDays != nil },
                set: { if !$0 { pendingRetentionDays = nil } }
            )
        ) {
            Button("Delete Older Data", role: .destructive) {
                guard let days = pendingRetentionDays else { return }
                pendingRetentionDays = nil
                settings.historyRetentionDays = days
            }
            Button("Cancel", role: .cancel) {
                pendingRetentionDays = nil
            }
        } message: {
            if let days = pendingRetentionDays {
                Text("Local workspace entries and associated meeting files older than \(days) days will be permanently deleted now.")
            }
        }
    }

    static func requiresRetentionConfirmation(currentDays: Int, newDays: Int) -> Bool {
        newDays < currentDays
    }

    private var ambientContextDetail: String {
        let settings = appState.settingsManager
        if settings.hipaaMode {
            return "Unavailable while HIPAA Mode is on."
        }
        if !settings.contextMetadataEnabled {
            return "Enable app context first."
        }
        return "Builds a local activity store from apps, windows, pages, clipboard, and visible text."
    }

    private var cloudSyncSummary: String {
        if !appState.authManager.isLoggedIn { return "Requires sign-in." }
        if appState.settingsManager.workspaceCloudUploadEnabled {
            return "Background uploads are on."
        }
        return "Off until you enable it."
    }

    private var cloudSyncStatusBadge: String? {
        switch appState.workspaceCloudUploadState {
        case .uploading: "Uploading"
        case .preparing: "Preparing"
        case .deleting: "Deleting"
        case .failed: "Failed"
        default: nil
        }
    }
}
