import AppKit
import SwiftData
import SwiftUI

/// Space tab — overview of the user's private local workspace.
/// Counts come from the on-disk SwiftData store + filesystem scan of the
/// Resonant folder, so numbers reflect everything on disk (not the capped
/// in-memory feed window).
struct SpaceTabView: View {
    @Environment(AppState.self) private var appState

    @State private var stats = SpaceStats()

    private var vaultPath: URL { AppSupportPaths.resonantRoot() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    metricsSection
                    vaultSection
                    integrationsSection
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(SettingsPalette.warmBackdrop)
        .task(id: vaultPath) { await reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Space")
                    .font(.system(size: 16, weight: .bold))

                Text("Private local workspace — dictations, memos, meetings, and journals stay on your Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            SettingsMetaPill(title: "Private", systemImage: "lock.fill")
        }
    }

    // MARK: - Metrics

    private var metricsSection: some View {
        SpaceSection(icon: "square.stack.3d.up.fill", title: "Inside your space") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: 10, alignment: .top)],
                alignment: .leading,
                spacing: 10
            ) {
                SpaceMetricTile(
                    value: stats.dictationCount.formatted,
                    label: "Dictations",
                    icon: "mic.fill",
                    tint: .blue,
                    isLoading: stats.isLoading
                ) { appState.selectedSettingsTab = .home }

                SpaceMetricTile(
                    value: stats.memoCount.formatted,
                    label: "Memos",
                    icon: "note.text",
                    tint: .orange,
                    isLoading: stats.isLoading
                ) { appState.selectedSettingsTab = .home }

                SpaceMetricTile(
                    value: stats.meetingCount.formatted,
                    label: "Meetings",
                    icon: "video.fill",
                    tint: .green,
                    isLoading: stats.isLoading
                ) { appState.selectedSettingsTab = .meetings }

                SpaceMetricTile(
                    value: stats.journalDayCount.formatted,
                    label: "Journal days",
                    icon: "book.closed.fill",
                    tint: .yellow,
                    isLoading: stats.isLoading
                ) {
                    appState.isShowingSettings = false
                    appState.selectedSettingsTab = .home
                }
            }
        }
    }

    // MARK: - Vault

    private var vaultSection: some View {
        SpaceSection(
            icon: "externaldrive.fill",
            title: "Your vault",
            trailingLabel: "Open in Finder",
            trailingAction: {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: vaultPath.path)
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Resonant folder")
                        .font(.system(size: 13, weight: .semibold))

                    SettingsMetaPill(
                        title: stats.totalSizeLabel,
                        systemImage: "shippingbox.fill"
                    )

                    Spacer(minLength: 0)
                }

                Text(vaultPath.path(percentEncoded: false))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Divider().opacity(0.4)

                HStack(spacing: 16) {
                    VaultDetail(
                        icon: "waveform",
                        text: "\(stats.recordingCount.formatted) recordings"
                    )
                    VaultDetail(
                        icon: "doc.text",
                        text: "\(stats.markdownCount.formatted) markdown files"
                    )
                    if stats.ambientEventCount > 0 {
                        VaultDetail(
                            icon: "sparkles",
                            text: "\(stats.ambientEventCount.formatted) ambient events"
                        )
                    } else if stats.ambientDayCount > 0 {
                        VaultDetail(
                            icon: "sparkles",
                            text: "\(stats.ambientDayCount.formatted) context days"
                        )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Integrations

    private var integrationsSection: some View {
        SpaceSection(
            icon: "bolt.horizontal.fill",
            title: "Connect agents",
            trailingLabel: "Manage",
            trailingAction: {
                appState.isShowingSettings = true
                appState.selectedSettingsTab = .mcpServer
            }
        ) {
            HStack(alignment: .center, spacing: 12) {
                MinimalIntegrationColumn(
                    title: "MCP Server",
                    isActive: appState.settingsManager.mcpServerEnabled
                ) {
                    appState.isShowingSettings = true
                    appState.selectedSettingsTab = .mcpServer
                }

                Divider().frame(height: 24).opacity(0.4)

                MinimalIntegrationColumn(
                    title: "API",
                    isActive: appState.settingsManager.localAPIEnabled
                ) {
                    appState.isShowingSettings = true
                    appState.selectedSettingsTab = .apiCli
                }
            }
        }
    }

    // MARK: - Data

    @MainActor
    private func reload() async {
        stats.isLoading = true

        let dataStore = appState.dataStore
        let root = vaultPath

        async let dict = dataStore.countInBackground(FetchDescriptor<DictationEntry>())
        async let memo = dataStore.countInBackground(FetchDescriptor<MemoEntry>())
        async let meet = dataStore.fetchMappedInBackground(
            FetchDescriptor<MeetingEntry>()
        ) { $0.activeJSONLPath == nil }
            .lazy.filter { $0 }.count
        async let journal = dataStore.countInBackground(FetchDescriptor<JournalDay>())
        async let vault = SpaceVaultScanner.scan(root: root)

        let (dictCount, memoCount, meetCount, journalCount, vaultStats) = await (
            dict, memo, meet, journal, vault
        )

        stats = SpaceStats(
            dictationCount: dictCount,
            memoCount: memoCount,
            meetingCount: meetCount,
            journalDayCount: journalCount,
            ambientDayCount: vaultStats.ambientDayCount,
            ambientEventCount: vaultStats.ambientEventCount,
            ambientBytes: vaultStats.ambientBytes,
            ambientFirstDay: vaultStats.ambientFirstDay,
            ambientLastDay: vaultStats.ambientLastDay,
            recordingCount: vaultStats.recordingCount,
            markdownCount: vaultStats.markdownCount,
            totalBytes: vaultStats.totalBytes,
            isLoading: false
        )
    }
}

// MARK: - Stats Model

private struct SpaceStats {
    var dictationCount: Int = 0
    var memoCount: Int = 0
    var meetingCount: Int = 0
    var journalDayCount: Int = 0
    var ambientDayCount: Int = 0
    var ambientEventCount: Int = 0
    var ambientBytes: Int64 = 0
    var ambientFirstDay: String?
    var ambientLastDay: String?
    var recordingCount: Int = 0
    var markdownCount: Int = 0
    var totalBytes: Int64 = 0
    var isLoading: Bool = true

    var totalSizeLabel: String {
        Self.formatBytes(totalBytes)
    }

    private static func formatBytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}

private extension Int {
    var formatted: String {
        if self < 1000 { return "\(self)" }
        if self < 10_000 { return String(format: "%.1fk", Double(self) / 1000) }
        return "\(self / 1000)k"
    }
}

// MARK: - Vault Scanner

private struct SpaceVaultScan: Sendable {
    var recordingCount: Int = 0
    var markdownCount: Int = 0
    var ambientDayCount: Int = 0
    var ambientEventCount: Int = 0
    var ambientBytes: Int64 = 0
    var ambientFirstDay: String?
    var ambientLastDay: String?
    var totalBytes: Int64 = 0
}

private enum SpaceVaultScanner {
    /// Subdirectories of the Resonant folder that hold user-facing content.
    /// Everything else (Electron cache leftovers, Crashpad, Sentry scratch,
    /// SwiftData store files) is ignored so the size reflects "your vault",
    /// not incidental system files.
    private static let contentDirectories = [
        "archive",
        "stream",
        "audio",
        "meetings-active",
    ]

    /// Walks each content subdirectory off-main to collect vault-wide stats.
    static func scan(root: URL) async -> SpaceVaultScan {
        await Task.detached(priority: .utility) {
            var result = SpaceVaultScan()

            let fm = FileManager.default
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
            ]

            for directoryName in contentDirectories {
                let directory = root.appendingPathComponent(directoryName, isDirectory: true)
                guard
                    fm.fileExists(atPath: directory.path),
                    let enumerator = fm.enumerator(
                        at: directory,
                        includingPropertiesForKeys: keys,
                        options: [.skipsHiddenFiles]
                    )
                else { continue }

                while let next = enumerator.nextObject() {
                    guard let url = next as? URL else { continue }
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }

                    let size = Int64(
                        values?.totalFileAllocatedSize
                            ?? values?.fileAllocatedSize
                            ?? 0
                    )
                    result.totalBytes += size

                    switch url.pathExtension.lowercased() {
                    case "caf", "m4a", "wav", "mp3":
                        result.recordingCount += 1
                    case "md":
                        if url.lastPathComponent != "_daily-summary.md" {
                            result.markdownCount += 1
                        }
                    case "jsonl":
                        if url.deletingLastPathComponent().lastPathComponent == "ambient" {
                            result.ambientDayCount += 1
                            result.ambientBytes += size
                            result.ambientEventCount += Self.lineCount(at: url)

                            let dayStem = url.deletingPathExtension().lastPathComponent
                            if dayStem.count == 10, dayStem.contains("-") {
                                if result.ambientFirstDay == nil || dayStem < result.ambientFirstDay! {
                                    result.ambientFirstDay = dayStem
                                }
                                if result.ambientLastDay == nil || dayStem > result.ambientLastDay! {
                                    result.ambientLastDay = dayStem
                                }
                            }
                        }
                    default:
                        break
                    }
                }
            }

            return result
        }.value
    }

    /// Fast line counter — streams the file and counts 0x0A bytes.
    /// Used to total ambient events without parsing each JSONL record.
    private static func lineCount(at url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }

        var count = 0
        let newline: UInt8 = 0x0A
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            count += chunk.reduce(0) { $0 + ($1 == newline ? 1 : 0) }
        }
        return count
    }
}

// MARK: - Section Container (matches homepage HomeSourceGroup)

private struct SpaceSection<Content: View>: View {
    let icon: String
    let title: String
    var trailingLabel: String? = nil
    var trailingAction: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if let label = trailingLabel, let action = trailingAction {
                    MinimalLinkButton(title: label, action: action)
                }
            }
            .padding(.horizontal, 4)

            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            SettingsPalette.cardBackground,
                            SettingsPalette.cardBackground.opacity(0.25)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            SettingsPalette.border.opacity(0.22),
                            SettingsPalette.border.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Metric Tile (flat, rides inside SpaceSection)

private struct SpaceMetricTile: View {
    let value: String
    let label: String
    let icon: String
    let tint: Color
    let isLoading: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isLoading ? "—" : value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsPalette.mutedCardBackground.opacity(isHovered ? 1 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isHovered ? tint.opacity(0.30) : SettingsPalette.border.opacity(0.14),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { isHovered = hovering }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isLoading)
    }
}

// MARK: - Vault Detail

private struct VaultDetail: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Minimal Link Button

private struct MinimalLinkButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .offset(x: isHovered ? 1 : 0, y: isHovered ? -1 : 0)
            }
            .foregroundStyle(isHovered ? Color.secondary : Color.secondary.opacity(0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { isHovered = hovering }
        }
    }
}

// MARK: - Minimal Integration Column

private struct MinimalIntegrationColumn: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(isActive ? "On" : "Off")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isActive ? Color.secondary : Color.secondary.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(isActive ? 0.10 : 0.05))
                    )

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isHovered ? Color.secondary : Color.secondary.opacity(0.5))
                    .offset(x: isHovered ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { isHovered = hovering }
        }
    }
}
