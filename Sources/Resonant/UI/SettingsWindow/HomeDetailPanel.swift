import AppKit
import SwiftData
import SwiftUI

// MARK: - Finder Reveal

private func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

private struct RevealInFinderButton: View {
    let url: URL
    var tooltip: String = "Show in Finder"

    var body: some View {
        Button {
            revealInFinder(url)
        } label: {
            DetailIconButton(
                systemImage: "folder",
                tone: .neutral,
                tooltip: tooltip
            )
        }
        .buttonStyle(.plain)
    }
}

/// Detail panel that slides in from the right in the Home tab.
/// Routes to per-type content based on the selected item.
struct HomeDetailPanel: View {
    @ObservedObject var playbackController: MemoPlaybackController
    @Environment(AppState.self) private var appState

    private var selectedItem: FeedItem? {
        guard let id = appState.selectedFeedItemID else { return nil }
        return appState.feedManager.items.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let item = selectedItem {
                switch item.kind {
                case .memo:
                    MemoDetailContent(
                        item: item,
                        playbackController: playbackController
                    )
                case .dictation:
                    DictationDetailContent(
                        item: item,
                        playbackController: playbackController
                    )
                case .meeting:
                    MeetingPreviewContent(item: item)
                default:
                    fallbackContent(item: item)
                }
            } else {
                Spacer()
                Text("Select an item")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func fallbackContent(item: FeedItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.appName ?? "Item")
                    .font(.system(size: 18, weight: .semibold))
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(14)
        }
    }
}

// MARK: - Context Strip

private struct FeedItemContextStrip: View {
    let item: FeedItem

    // Metadata keys surfaced in the Details section and therefore skipped in the
    // "Raw metadata" dump.
    private static let surfacedMetadataKeys: Set<String> = [
        "duration", "durationSeconds", "wordCount", "title"
    ]

    private var rawMetadataEntries: [(key: String, value: String)] {
        item.metadata
            .filter { !Self.surfacedMetadataKeys.contains($0.key) }
            .map { ($0.key, $0.value) }
            .sorted { $0.key.localizedCompare($1.key) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailsSection
            if !rawMetadataEntries.isEmpty {
                rawSection
            }
        }
        .padding(.top, 4)
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(SettingsPalette.border.opacity(0.18))
                .frame(height: 1)
                .padding(.bottom, 12)

            Text("Details")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                row("Kind", item.kind.rawValue.capitalized)
                row("ID", item.id.uuidString)
                row("Captured", formatFullDate(item.date))

                if let duration = item.feedDurationText {
                    row("Duration", duration)
                }

                if let words = item.wordCount, words > 0 {
                    row("Words", "\(words)")
                }

                if let app = trimmed(item.appName) {
                    row("App", app)
                }

                if let windowTitle = trimmed(item.windowTitle) {
                    row("Window", windowTitle)
                }

                if let url = trimmed(item.browserURL) {
                    row("URL", url)
                }

                if let context = trimmed(item.contextLabel), context != trimmed(item.appName) {
                    row("Context", context)
                }

                if let bundleId = trimmed(item.bundleId) {
                    row("Bundle", bundleId)
                }

                if let audio = trimmed(item.audioPath) {
                    row("Audio", (audio as NSString).lastPathComponent)
                }
            }
        }
    }

    private var rawSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raw Metadata")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rawMetadataEntries, id: \.key) { entry in
                    row(entry.key, entry.value)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.quaternary)
                .textCase(.uppercase)
                .tracking(0.3)
                .frame(width: 78, alignment: .leading)

            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func formatFullDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · h:mm:ss a"
        return f.string(from: date)
    }
}

// MARK: - Memo Detail

private struct MemoDetailContent: View {
    let item: FeedItem
    @ObservedObject var playbackController: MemoPlaybackController
    @Environment(AppState.self) private var appState

    @State private var titleDraft: String = ""
    @State private var isDistilling = false
    @State private var distillError: String?
    @State private var isDistillSheetPresented = false
    @State private var distillPrompt = kDefaultMemoDistillPrompt
    @State private var didCopy = false

    private var memo: MemoEntry? {
        appState.memoManager.memo(id: item.id)
    }

    private var audioURL: URL? {
        memo.flatMap { appState.memoManager.audioURL(for: $0) }
    }

    private var canDistill: Bool {
        AppFeatureVisibility.hostedServices && appState.authManager.isLoggedIn
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Editable title
                TextField("Title", text: $titleDraft)
                    .font(.system(size: 20, weight: .semibold))
                    .textFieldStyle(.plain)

                // Metadata
                if let memo {
                    HStack(spacing: 8) {
                        Text(formatDate(memo.date))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if memo.duration > 0 {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(formatDuration(memo.duration))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Audio player + reveal
                if let memo, let audioURL {
                    HStack(spacing: 8) {
                        CompactAudioPlayerView(
                            playbackController: playbackController,
                            itemID: memo.id,
                            audioURL: audioURL,
                            showRateControl: true
                        )
                        RevealInFinderButton(url: audioURL, tooltip: "Show audio in Finder")
                    }
                }

                Divider()

                // Distilled note
                if let memo, let distilled = memo.distilledText, !distilled.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Distilled Note")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)

                        Text(distilled)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }

                    Divider()
                }

                // Transcript
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcript")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)

                    Text(item.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // Actions
                HStack(spacing: 8) {
                    if AppFeatureVisibility.hostedServices {
                        if canDistill {
                            Menu {
                                Button("Quick summary") { runDistillation(prompt: kDefaultMemoDistillPrompt) }
                                Button("Action items") { runDistillation(prompt: "Extract action items from this memo as a bulleted list.") }
                                Button("Meeting recap") { runDistillation(prompt: "Write a brief recap of this meeting/conversation.") }
                                Divider()
                                Button("Custom prompt...") { isDistillSheetPresented = true }
                            } label: {
                                DetailIconButton(
                                    systemImage: isDistilling ? "hourglass" : (memo?.distilledText != nil ? "text.document.fill" : "sparkles"),
                                    tone: .accent,
                                    tooltip: "Distill"
                                )
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        } else {
                            Button {
                                promptForSignIn()
                            } label: {
                                DetailIconButton(systemImage: "lock.fill", tone: .locked, tooltip: "Distill (sign in)")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                        didCopy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { didCopy = false }
                    } label: {
                        DetailIconButton(
                            systemImage: didCopy ? "checkmark" : "doc.on.doc",
                            tone: .neutral,
                            tooltip: didCopy ? "Copied" : "Copy transcript"
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        Task {
                            await appState.deleteFeedItem(item)
                            appState.selectedFeedItemID = nil
                        }
                    } label: {
                        DetailIconButton(systemImage: "trash", tone: .destructive, tooltip: "Delete")
                    }
                    .buttonStyle(.plain)
                }

                if let error = distillError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }

                MemoFullFieldsSection(itemID: item.id, audioURL: audioURL)

                FeedItemContextStrip(item: item)
            }
            .padding(14)
        }
        .sheet(isPresented: $isDistillSheetPresented) {
            DistillPromptSheet(
                prompt: $distillPrompt,
                isProcessing: isDistilling,
                error: distillError,
                onCancel: { isDistillSheetPresented = false },
                onSubmit: {
                    isDistillSheetPresented = false
                    runDistillation(prompt: distillPrompt)
                }
            )
        }
        .onAppear {
            titleDraft = memo?.displayTitle ?? ""
        }
        .onChange(of: item.id) { _, _ in
            titleDraft = memo?.displayTitle ?? ""
            distillError = nil
        }
        .onChange(of: titleDraft) { _, newTitle in
            guard let memo else { return }
            Task { await appState.memoManager.updateTitle(for: memo, title: newTitle) }
        }
    }

    private func runDistillation(prompt: String) {
        guard let memo else { return }
        guard AppFeatureVisibility.hostedServices else { return }
        guard appState.authManager.isLoggedIn else {
            distillError = "Sign in to distill memos."
            return
        }

        isDistilling = true
        distillError = nil

        Task {
            let requestText = "\(prompt)\n\nMemo title: \(memo.displayTitle)\n\nMemo transcript:\n\(memo.text)"
            let result = await appState.convexClient.processMemo(
                text: requestText,
                modelRoute: .meetingSummary
            )?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let result, !result.isEmpty {
                await appState.memoManager.updateDistilledText(for: memo, distilledText: result)
            } else {
                distillError = "Distillation failed. Try again."
            }
            isDistilling = false
        }
    }

    private func promptForSignIn() {
        guard AppFeatureVisibility.hostedServices else { return }
        distillError = "Sign in to distill memos."
        appState.initiateLogin(source: "home_memo_distill")
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let total = Int(d.rounded(.towardZero))
        if total < 60 { return "\(total)s" }
        let m = total / 60, s = total % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
}

// MARK: - Memo Full Fields

private struct MemoFullFieldsSection: View {
    let itemID: UUID
    let audioURL: URL?
    @Environment(AppState.self) private var appState
    @State private var memo: MemoEntry?

    var body: some View {
        Group {
            if let memo {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("Processing")

                    VStack(alignment: .leading, spacing: 6) {
                        row("Transcription", "Parakeet (on-device)")
                        row("Distilled", memo.distilledText?.isEmpty == false ? "Yes (cloud)" : "No")
                        row("Words", "\(memo.text.split(whereSeparator: { $0.isWhitespace }).count)")
                        row("Duration", formatDuration(memo.duration))
                        row("Captured", memo.date.formatted(date: .abbreviated, time: .standard))
                        if let externalID = trimmed(memo.externalID) {
                            row("External ID", externalID)
                        }
                        if let audioPath = trimmed(memo.audioPath) {
                            row("Audio path", audioPath)
                            if let url = audioURL {
                                HStack(spacing: 6) {
                                    Text("")
                                        .frame(width: 94, alignment: .leading)
                                    Button {
                                        revealInFinder(url)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "folder")
                                                .font(.system(size: 10, weight: .semibold))
                                            Text("Show in Finder")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundStyle(SettingsPalette.infoText)
                                    }
                                    .buttonStyle(.plain)
                                    Spacer()
                                }
                            }
                        }
                        row("ID", memo.id.uuidString)
                    }
                }
            }
        }
        .task(id: itemID) {
            let targetID = itemID
            let descriptor = FetchDescriptor<MemoEntry>(
                predicate: #Predicate<MemoEntry> { $0.id == targetID }
            )
            let results = await appState.dataStore.fetchInBackground(descriptor)
            self.memo = results.first
        }
    }

    @ViewBuilder
    private func sectionHeader(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(SettingsPalette.border.opacity(0.18))
                .frame(height: 1)
                .padding(.bottom, 10)

            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.quaternary)
                .textCase(.uppercase)
                .tracking(0.3)
                .frame(width: 94, alignment: .leading)

            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let total = Int(d.rounded(.towardZero))
        if total < 60 { return "\(total)s" }
        let m = total / 60, s = total % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
}

// MARK: - Dictation Detail

private struct DictationDetailContent: View {
    let item: FeedItem
    @ObservedObject var playbackController: MemoPlaybackController
    @Environment(AppState.self) private var appState
    @State private var didCopy = false
    @State private var isRetranscribing = false

    private var audioURL: URL? {
        appState.feedManager.resolveAudioURL(item.audioPath)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 10) {
                    HomeItemIcon(item: item, source: FeedSourceDisplay(item: item), size: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.appName ?? "Dictation")
                            .font(.system(size: 18, weight: .semibold))

                        HStack(spacing: 6) {
                            Text(formatDate(item.date))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            if let context = item.contextLabel, context != item.appName {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(context)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                // Audio player + reveal
                if let audioURL {
                    HStack(spacing: 8) {
                        CompactAudioPlayerView(
                            playbackController: playbackController,
                            itemID: item.id,
                            audioURL: audioURL,
                            showRateControl: false
                        )
                        RevealInFinderButton(url: audioURL, tooltip: "Show audio in Finder")
                    }
                }

                Divider()

                // Delivered text
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                // Actions
                HStack(spacing: 8) {
                    if audioURL != nil {
                        Button {
                            isRetranscribing = true
                            Task {
                                try? await appState.retranscribeFeedItem(item)
                                isRetranscribing = false
                            }
                        } label: {
                            DetailIconButton(
                                systemImage: isRetranscribing ? "hourglass" : "arrow.clockwise",
                                tone: .neutral,
                                tooltip: "Retranscribe"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isRetranscribing)
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                        didCopy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { didCopy = false }
                    } label: {
                        DetailIconButton(
                            systemImage: didCopy ? "checkmark" : "doc.on.doc",
                            tone: .neutral,
                            tooltip: didCopy ? "Copied" : "Copy text"
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        Task {
                            await appState.deleteFeedItem(item)
                            appState.selectedFeedItemID = nil
                        }
                    } label: {
                        DetailIconButton(systemImage: "trash", tone: .destructive, tooltip: "Delete")
                    }
                    .buttonStyle(.plain)
                }

                DictationFullFieldsSection(itemID: item.id, audioURL: audioURL)

                FeedItemContextStrip(item: item)
            }
            .padding(14)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Dictation Full Fields

/// Fetches the persisted DictationEntry and surfaces every field, including
/// AX capture data, cloud-cleanup status, and delivery flags.
private struct DictationFullFieldsSection: View {
    let itemID: UUID
    let audioURL: URL?
    @Environment(AppState.self) private var appState
    @State private var entry: DictationEntry?

    var body: some View {
        Group {
            if let entry {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("Processing")
                    processingRows(entry)

                    if let rawTranscript = trimmed(entry.rawTranscript),
                       rawTranscript != entry.text {
                        sectionHeader("Raw Transcript (pre-cleanup)")
                        longText(rawTranscript)
                    }

                    if let audit = entry.vocabularyBoostAuditSummary,
                       !audit.decisions.isEmpty {
                        sectionHeader("Vocabulary Boost")
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(audit.decisions.enumerated()), id: \.offset) { _, decision in
                                longText(decision.diagnosticLine)
                            }
                        }
                    }

                    if let selectedText = trimmed(entry.selectedText) {
                        sectionHeader("Selected Text")
                        longText(selectedText)
                    }

                    if let focused = trimmed(entry.focusedFieldContent) {
                        sectionHeader("Focused Field")
                        longText(focused)
                    }

                    let snippets = entry.visibleTextSnippets.compactMap { trimmed($0) }
                    if !snippets.isEmpty {
                        sectionHeader("Visible Text Snippets (AX)")
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(snippets.enumerated()), id: \.offset) { _, snippet in
                                Text("• \(snippet)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    sectionHeader("Capture Source")
                    captureRows(entry)
                }
            }
        }
        .task(id: itemID) {
            let targetID = itemID
            let descriptor = FetchDescriptor<DictationEntry>(
                predicate: #Predicate<DictationEntry> { $0.id == targetID }
            )
            let results = await appState.dataStore.fetchInBackground(descriptor)
            self.entry = results.first
        }
    }

    @ViewBuilder
    private func sectionHeader(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(SettingsPalette.border.opacity(0.18))
                .frame(height: 1)
                .padding(.bottom, 10)

            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }

    @ViewBuilder
    private func processingRows(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Mode", entry.dictationMode.rawValue.capitalized)

            let didCloudCleanup = wasCloudCleaned(entry)
            row("Cleanup", didCloudCleanup ? "Cloud-cleaned" : "Raw (no cleanup)")

            if didCloudCleanup {
                row("Cleanup source", "Convex cloud processing")
            }

            row("Transcription", "Parakeet (on-device)")

            if let wc = entry.text.split(whereSeparator: { $0.isWhitespace }).count as Int? {
                row("Words", "\(wc)")
            }
            row("Duration", formatDuration(entry.duration))

            if let autoPasted = entry.autoPasted {
                row("Auto-pasted", autoPasted ? "Yes" : "No")
            }
            if let copied = entry.copiedToClipboard {
                row("Copied to clipboard", copied ? "Yes" : "No")
            }
            if let autoSent = entry.autoSent {
                row("Auto-sent", autoSent ? "Yes" : "No")
            }

            if let deliveredText = trimmed(entry.deliveredText), deliveredText != entry.text {
                row("Delivered text", deliveredText)
            }

            if let externalID = trimmed(entry.externalID) {
                row("External ID", externalID)
            }
        }
    }

    @ViewBuilder
    private func captureRows(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("App", entry.appName.isEmpty ? "—" : entry.appName)
            row("Bundle ID", entry.bundleId.isEmpty ? "—" : entry.bundleId)

            if let wt = trimmed(entry.windowTitle) {
                row("Window title", wt)
            }
            if let url = trimmed(entry.browserURL) {
                row("Browser URL", url)
            }
            if let file = trimmed(entry.codeFileName) {
                row("Code file", file)
            }
            if let slack = trimmed(entry.slackRecipient) {
                row("Slack recipient", slack)
            }

            if let audioPath = trimmed(entry.audioPath) {
                row("Audio path", audioPath)
                if let url = audioURL {
                    HStack(spacing: 6) {
                        Text("")
                            .frame(width: 94, alignment: .leading)
                        Button {
                            revealInFinder(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Show in Finder")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(SettingsPalette.infoText)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                }
            }

            row("Captured", entry.date.formatted(date: .abbreviated, time: .standard))
            row("ID", entry.id.uuidString)
        }
    }

    private func wasCloudCleaned(_ entry: DictationEntry) -> Bool {
        guard let raw = trimmed(entry.rawTranscript) else { return false }
        return raw != entry.text
    }

    private func longText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.quaternary)
                .textCase(.uppercase)
                .tracking(0.3)
                .frame(width: 94, alignment: .leading)

            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let total = Int(d.rounded(.towardZero))
        if total < 60 { return "\(total)s" }
        let m = total / 60, s = total % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
}

// MARK: - Meeting Preview

private struct MeetingPreviewContent: View {
    let item: FeedItem
    @Environment(AppState.self) private var appState
    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(SettingsPalette.elevatedBackground)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.metadata["title"] ?? item.appName ?? "Meeting")
                            .font(.system(size: 18, weight: .semibold))

                        HStack(spacing: 6) {
                            Text(formatDate(item.date))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            if let duration = item.feedDurationText {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(duration)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            if let app = item.appName {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(app)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                // Summary
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(10)
                }

                // Open in Meetings
                Button {
                    appState.selectedFeedItemID = nil
                    appState.selectedSettingsTab = .meetings
                } label: {
                    HStack(spacing: 6) {
                        Text("Open in Meetings")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(SettingsPalette.infoText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(SettingsPalette.accentFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(SettingsPalette.accentBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Actions
                HStack(spacing: 8) {
                    if !item.text.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.text, forType: .string)
                            didCopy = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { didCopy = false }
                        } label: {
                            DetailIconButton(
                                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                                tone: .neutral,
                                tooltip: didCopy ? "Copied" : "Copy summary"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button {
                        Task {
                            await appState.deleteFeedItem(item)
                            appState.selectedFeedItemID = nil
                        }
                    } label: {
                        DetailIconButton(systemImage: "trash", tone: .destructive, tooltip: "Delete")
                    }
                    .buttonStyle(.plain)
                }

                MeetingMetadataStrip(itemID: item.id)

                FeedItemContextStrip(item: item)
            }
            .padding(14)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Meeting Metadata Strip

private struct MeetingMetadataStrip: View {
    let itemID: UUID
    @Environment(AppState.self) private var appState
    @State private var meeting: MeetingEntry?

    var body: some View {
        Group {
            if let meeting {
                VStack(alignment: .leading, spacing: 10) {
                    Rectangle()
                        .fill(SettingsPalette.border.opacity(0.18))
                        .frame(height: 1)

                    Text("Meeting Record")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    VStack(alignment: .leading, spacing: 6) {
                        row("Started", meeting.startedAt.formatted(date: .abbreviated, time: .standard))
                        if let ended = meeting.endedAt {
                            row("Ended", ended.formatted(date: .abbreviated, time: .standard))
                        }
                        row("Duration", "\(Int(meeting.durationSeconds.rounded()))s")
                        row("Words", "\(meeting.wordCount)")

                        if let app = trimmed(meeting.detectedApp) {
                            row("Detected app", app)
                        }
                        if let custom = trimmed(meeting.customTitle) {
                            row("Custom title", custom)
                        }
                        if let origin = trimmed(meeting.recordingOriginRaw) {
                            row("Origin", origin)
                        }
                        if let calendar = trimmed(meeting.calendarName) {
                            row("Calendar", calendar)
                        }
                        if let eventID = trimmed(meeting.calendarEventID) {
                            row("Event ID", eventID)
                        }
                        if let scheduledStart = meeting.scheduledStartAt {
                            row("Scheduled start", scheduledStart.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let scheduledEnd = meeting.scheduledEndAt {
                            row("Scheduled end", scheduledEnd.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let organizer = trimmed(meeting.organizerName) {
                            row("Organizer", organizer)
                        }
                        if let names = parseList(meeting.attendeeNamesJSON) {
                            row("Attendees", names.joined(separator: ", "))
                        }
                        if let emails = parseList(meeting.attendeeEmailsJSON) {
                            row("Emails", emails.joined(separator: ", "))
                        }
                        if let url = trimmed(meeting.conferencingURL) {
                            row("Conferencing", url)
                        }
                        if let audio = trimmed(meeting.audioPath) {
                            fileRow("Audio", relativePath: audio)
                        }
                        if let markdown = trimmed(meeting.markdownPath) {
                            fileRow("Markdown", relativePath: markdown)
                        }
                        if let jsonl = trimmed(meeting.activeJSONLPath) {
                            fileRow("Active JSONL", relativePath: jsonl)
                        }
                        if let notes = trimmed(meeting.userNotes) {
                            row("Notes", notes)
                        }
                        if let post = trimmed(meeting.postMeetingNotes) {
                            row("Post notes", post)
                        }
                        if let summary = trimmed(meeting.summary) {
                            row("Summary", summary)
                        }
                        if let distilled = trimmed(meeting.distilledSummary) {
                            row("Distilled", distilled)
                        }
                        if let aliases = trimmed(meeting.speakerAliasesJSON) {
                            row("Speaker aliases", aliases)
                        }
                    }
                }
            } else {
                EmptyView()
            }
        }
        .task(id: itemID) {
            let targetID = itemID
            let descriptor = FetchDescriptor<MeetingEntry>(
                predicate: #Predicate<MeetingEntry> { $0.id == targetID }
            )
            let results = await appState.dataStore.fetchInBackground(descriptor)
            self.meeting = results.first
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.quaternary)
                .textCase(.uppercase)
                .tracking(0.3)
                .frame(width: 94, alignment: .leading)

            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func fileRow(_ label: String, relativePath: String) -> some View {
        let url = AppSupportPaths.resonantRoot().appendingPathComponent(relativePath)
        let exists = FileManager.default.fileExists(atPath: url.path)

        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.quaternary)
                .textCase(.uppercase)
                .tracking(0.3)
                .frame(width: 94, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text((relativePath as NSString).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if exists {
                    Button {
                        revealInFinder(url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Show in Finder")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(SettingsPalette.infoText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func parseList(_ json: String?) -> [String]? {
        guard let json = trimmed(json), let data = json.data(using: .utf8) else { return nil }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return array.isEmpty ? nil : array
    }
}
