import Defaults
import SwiftUI

/// Cloud Sync sub-page. Drilled into from the Privacy tab so the main page can
/// stay short. Owns the consent sheet, status, sync controls, and cloud-data
/// management.
struct WorkspaceCloudSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isShowingCloudConsent = false
    @State private var isShowingDeleteCloudAlert = false

    var body: some View {
        @Bindable var settings = appState.settingsManager
        let isLoggedIn = appState.authManager.isLoggedIn
        let cloudSyncEnabled = Binding<Bool>(
            get: { settings.workspaceCloudUploadEnabled },
            set: { isEnabled in
                if isEnabled {
                    isShowingCloudConsent = true
                } else {
                    settings.workspaceCloudUploadEnabled = false
                }
            }
        )

        SettingsPage(
            title: "Cloud Sync",
            subtitle: isLoggedIn
                ? "Background uploads of workspace text. Off until you enable it."
                : "Requires sign-in. Nothing uploads unless you enable it after signing in."
        ) {
            SettingsBackLink(target: .workspace) {
                appState.selectedSettingsTab = .workspace
            }

            SettingsCardSection("Sync") {
                SettingsValueRow("Status", detail: statusDetail(isLoggedIn: isLoggedIn)) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }

                if let progress = appState.workspaceCloudUploadState.progressFraction {
                    SettingsRowDivider()
                    SettingsValueRow("Upload progress") {
                        VStack(alignment: .trailing, spacing: 5) {
                            ProgressView(value: progress)
                                .frame(width: 160)
                            Text("\(Int((progress * 100).rounded()))% uploaded")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsRowDivider()
                SettingsToggleRow(
                    "Sync this workspace",
                    detail: "Uploads workspace text for account search. Local sync remains on-device.",
                    isOn: cloudSyncEnabled
                )
                .disabled(!isLoggedIn && !settings.workspaceCloudUploadEnabled)
            }

            if settings.workspaceCloudUploadEnabled || canOfferCloudDataDeletion {
                SettingsCardSection("Manage cloud data") {
                    SettingsValueRow(
                        "Cloud data",
                        detail: cloudDataDetail(isLoggedIn: isLoggedIn)
                    ) {
                        HStack(spacing: 8) {
                            if settings.workspaceCloudUploadEnabled {
                                Button {
                                    Task {
                                        await appState.uploadWorkspaceToCloud(enableBackgroundSync: true)
                                    }
                                } label: {
                                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!isLoggedIn || appState.workspaceCloudUploadState.isActive)
                            }

                            if canOfferCloudDataDeletion {
                                Button(role: .destructive) {
                                    isShowingDeleteCloudAlert = true
                                } label: {
                                    Label("Delete Cloud Data", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                                .disabled(appState.workspaceCloudUploadState.isActive)
                            }
                        }
                    }
                }
            }
        }
        .alert("Delete Cloud Workspace Data?", isPresented: $isShowingDeleteCloudAlert) {
            Button("Delete Cloud Data", role: .destructive) {
                Task {
                    await appState.deleteWorkspaceCloudData()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes uploaded workspace data from Resonant Cloud. Local workspace data on this Mac is not deleted.")
        }
        .sheet(isPresented: $isShowingCloudConsent) {
            WorkspaceCloudConsentSheet(
                onCancel: { isShowingCloudConsent = false },
                onEnable: {
                    isShowingCloudConsent = false
                    Task {
                        await appState.uploadWorkspaceToCloud(enableBackgroundSync: true)
                    }
                }
            )
        }
    }

    private func statusDetail(isLoggedIn: Bool) -> String {
        guard isLoggedIn else { return "Sign in before uploads can run." }
        if appState.settingsManager.workspaceCloudUploadEnabled {
            return "Background uploads are allowed for this workspace."
        }
        return "Off until you enable it."
    }

    private func cloudDataDetail(isLoggedIn: Bool) -> String {
        if appState.settingsManager.workspaceCloudUploadEnabled {
            return "Sync now or remove uploaded workspace data."
        }
        if canOfferCloudDataDeletion {
            return "Remove previously uploaded workspace data."
        }
        return isLoggedIn ? "No cloud data has been uploaded." : "Sign in to enable background sync."
    }

    private var statusText: String {
        switch appState.workspaceCloudUploadState {
        case .idle(let lastSyncedAt):
            if appState.settingsManager.workspaceCloudUploadEnabled {
                return lastSyncedAt.map { "Synced \(Self.relativeDateFormatter.localizedString(for: $0, relativeTo: Date()))" } ?? "Ready"
            }
            return "Off"
        case .preparing:        return "Preparing"
        case .uploading(let completed, let total):
            guard total > 0 else { return "Uploading" }
            return "Uploading \(Int((Double(completed) / Double(total) * 100).rounded()))%"
        case .succeeded:        return "Synced"
        case .deleting:         return "Deleting"
        case .deleted:          return "Deleted"
        case .failed:           return "Failed"
        }
    }

    private var statusColor: Color {
        switch appState.workspaceCloudUploadState {
        case .failed: .red
        case .preparing, .uploading, .deleting: .blue
        case .deleted: .green
        case .idle, .succeeded: .secondary
        }
    }

    private var hasSyncedCloudData: Bool {
        switch appState.workspaceCloudUploadState {
        case .idle(let lastSyncedAt):
            return lastSyncedAt != nil
        case .succeeded, .failed:
            return Defaults[.workspaceCloudTextLastSyncedAt] != nil
        case .preparing, .uploading, .deleting, .deleted:
            return false
        }
    }

    private var canOfferCloudDataDeletion: Bool {
        appState.authManager.isLoggedIn
            || appState.settingsManager.workspaceCloudUploadEnabled
            || hasSyncedCloudData
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct WorkspaceCloudConsentSheet: View {
    let onCancel: () -> Void
    let onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cloud")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable Cloud Sync")
                        .font(.title3.weight(.semibold))
                    Text("This uploads your workspace text to Resonant Cloud in the background. Local workspace sync remains on-device either way.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                consentRow("Dictation text and delivered text")
                consentRow("Voice note titles, text, and distilled text")
                consentRow("Meeting titles, summaries, transcripts, notes, and timing")
                consentRow("Smart links and dictionary corrections")
            }

            Divider()

            Text("You can pause background sync or delete uploaded cloud workspace data later from Workspace settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Enable and Sync", action: onEnable)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func consentRow(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.callout)
            .foregroundStyle(.primary)
    }
}
