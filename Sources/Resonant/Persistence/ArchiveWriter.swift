import Foundation
import os

/// Writes per-entry markdown files and copies audio to a date-organized archive directory.
///
/// Archive layout:
/// ```
/// ~/Library/Application Support/Resonant/archive/
/// ├── 2026/
/// │   └── 03/
/// │       └── 18/
/// │           ├── _daily-summary.md
/// │           ├── 09-15-32-a1b2c3d4-….md
/// │           ├── 09-15-32-a1b2c3d4-….caf
/// │           └── ...
/// ```
@MainActor
final class ArchiveWriter {

    struct MeetingWriteResult {
        let didCopyRecordingToArchive: Bool
    }

    struct DictationWriteResult {
        let didWriteMarkdown: Bool
        let didCopyRecordingToArchive: Bool
    }

    struct MemoWriteResult {
        let didWriteMarkdown: Bool
        let didCopyRecordingToArchive: Bool
    }

    private struct FileWriteResult: Sendable {
        let audioRelativePath: String?
        let markdownRelativePath: String?
        let didCopyRecordingToArchive: Bool
    }

    private let fm = FileManager.default
    private let log = Logger.resonant("ArchiveWriter")

    private let appSupportRoot: URL
    private let archiveRoot: URL

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private var summaryDebounceTask: Task<Void, Never>?
    private var pendingSummaryDate: Date?

    // MARK: - Init

    init(appSupportRoot: URL = AppSupportPaths.resonantRoot()) {
        self.appSupportRoot = appSupportRoot
        archiveRoot = appSupportRoot.appendingPathComponent("archive", isDirectory: true)
    }

    // MARK: - Dictation

    /// Writes a dictation archive entry: copies audio, sets `entry.audioPath`, writes `.md`.
    @discardableResult
    func writeDictation(
        entry: DictationEntry,
        rawTranscript: String?,
        deliveredText: String?,
        recordingURL: URL?
    ) async -> DictationWriteResult {
        let parts = DateParts(entry.date)
        let baseName = baseName(for: entry.date, id: entry.id)
        let dayDir = parts.dayDirectory(under: archiveRoot)

        let md = dictationMarkdown(
            entry: entry,
            rawTranscript: rawTranscript,
            deliveredText: deliveredText
        )
        let mdWithCopiedAudio = recordingURL.map { recordingURL in
            let ext = recordingURL.pathExtension.isEmpty
                ? "m4a"
                : recordingURL.pathExtension.lowercased()
            return dictationMarkdown(
                entry: entry,
                rawTranscript: rawTranscript,
                deliveredText: deliveredText,
                audioFileNameOverride: "\(baseName).\(ext)"
            )
        }
        let result = await Self.writeArchiveFilesOffMain(
            archiveRoot: archiveRoot,
            dayDir: dayDir,
            dayRelativePath: parts.relativePath,
            baseName: baseName,
            markdown: md,
            markdownWhenAudioCopied: mdWithCopiedAudio,
            recordingURL: recordingURL,
            label: "dictation"
        )
        entry.audioPath = result.audioRelativePath

        scheduleDailySummaryUpdate(for: entry.date)
        return DictationWriteResult(
            didWriteMarkdown: result.markdownRelativePath != nil,
            didCopyRecordingToArchive: result.didCopyRecordingToArchive
        )
    }

    // MARK: - Memo

    /// Writes a memo archive entry: copies audio from the memo's existing path, writes `.md`.
    @discardableResult
    func writeMemo(memo: MemoEntry) async -> MemoWriteResult {
        let baseName = baseName(for: memo.date, id: memo.id)
        let dayDir = DateParts(memo.date).dayDirectory(under: archiveRoot)

        let sourceURL = memo.audioPath.map(resolveAppSupportPath(_:))
        let md = memoMarkdown(memo: memo, audioFileName: nil)
        let mdWithCopiedAudio = sourceURL.map { sourceURL in
            let ext = sourceURL.pathExtension.isEmpty
                ? "m4a"
                : sourceURL.pathExtension.lowercased()
            return memoMarkdown(
                memo: memo,
                audioFileName: "\(baseName).\(ext)"
            )
        }
        let result = await Self.writeArchiveFilesOffMain(
            archiveRoot: archiveRoot,
            dayDir: dayDir,
            dayRelativePath: DateParts(memo.date).relativePath,
            baseName: baseName,
            markdown: md,
            markdownWhenAudioCopied: mdWithCopiedAudio,
            recordingURL: sourceURL,
            label: "memo"
        )

        scheduleDailySummaryUpdate(for: memo.date)
        return MemoWriteResult(
            didWriteMarkdown: result.markdownRelativePath != nil,
            didCopyRecordingToArchive: result.didCopyRecordingToArchive
        )
    }

    // MARK: - Meeting

    @discardableResult
    func writeMeeting(session: CompletedMeetingSession, entry: MeetingEntry, summary: String? = nil) async -> MeetingWriteResult {
        let parts = DateParts(session.startedAt)
        let baseName = baseName(for: session.startedAt, id: session.id)
        let dayDir = parts.dayDirectory(under: archiveRoot)

        let md = MeetingMarkdownExporter.markdown(
            for: session,
            title: entry.customTitle,
            summary: summary ?? entry.summary,
            speakerAliases: entry.speakerAliases
        )
        let result = await Self.writeArchiveFilesOffMain(
            archiveRoot: archiveRoot,
            dayDir: dayDir,
            dayRelativePath: parts.relativePath,
            baseName: baseName,
            markdown: md,
            recordingURL: session.recordingURL,
            label: "meeting"
        )
        entry.audioPath = result.audioRelativePath
        entry.markdownPath = result.markdownRelativePath

        scheduleDailySummaryUpdate(for: session.startedAt)

        return MeetingWriteResult(didCopyRecordingToArchive: result.didCopyRecordingToArchive)
    }

    @discardableResult
    func writeImportedMeetingMarkdown(meetingID: UUID, startedAt: Date, markdown: String) async -> String? {
        let parts = DateParts(startedAt)
        let baseName = baseName(for: startedAt, id: meetingID)
        let dayDir = parts.dayDirectory(under: archiveRoot)
        let result = await Self.writeArchiveFilesOffMain(
            archiveRoot: archiveRoot,
            dayDir: dayDir,
            dayRelativePath: parts.relativePath,
            baseName: baseName,
            markdown: markdown,
            recordingURL: nil,
            label: "meeting"
        )
        guard let markdownRelativePath = result.markdownRelativePath else { return nil }
        scheduleDailySummaryUpdate(for: startedAt)
        return markdownRelativePath
    }

    @discardableResult
    func rewriteMeetingSummary(markdownPath: String, newSummary: String) async -> Bool {
        let url = resolveAppSupportPath(markdownPath)
        let normalizedSummary = newSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSummary.isEmpty else { return false }

        let result = await Task.detached(priority: .utility) { () -> (didWrite: Bool, meetingDate: Date?) in
            guard var markdown = try? String(contentsOf: url, encoding: .utf8) else {
                return (false, nil)
            }
            let frontmatter = Self.parseFrontmatterStatic(markdown)
            let meetingDate = frontmatter["date"].flatMap {
                ISO8601DateFormatter().date(from: $0)
            }
            markdown = Self.updatedMeetingMarkdown(markdown: markdown, newSummary: normalizedSummary)
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                return (true, meetingDate)
            } catch {
                return (false, meetingDate)
            }
        }.value

        guard result.didWrite else { return false }
        scheduleDailySummaryUpdate(for: result.meetingDate ?? Date())
        return true
    }

    // MARK: - Retention

    func purgeOldArchive(olderThan days: Int) async {
        guard days > 0, days < 36500 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let archiveRoot = archiveRoot
        await Task.detached(priority: .utility) {
            Self.purgeOldArchiveOffMain(archiveRoot: archiveRoot, cutoff: cutoff)
        }.value
    }

    func clearWorkspaceData() async {
        let summaryTask = summaryDebounceTask
        summaryTask?.cancel()
        summaryDebounceTask = nil
        pendingSummaryDate = nil
        await summaryTask?.value

        let archiveRoot = archiveRoot
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            if fm.fileExists(atPath: archiveRoot.path) {
                try? fm.removeItem(at: archiveRoot)
            }
            try? fm.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        }.value
    }

    // MARK: - Daily summary

    private func scheduleDailySummaryUpdate(for date: Date) {
        pendingSummaryDate = date
        summaryDebounceTask?.cancel()
        summaryDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, let date = self.pendingSummaryDate else { return }
            await self.generateDailySummary(for: date)
            self.pendingSummaryDate = nil
        }
    }

    private func generateDailySummary(for date: Date) async {
        let parts = DateParts(date)
        let dayDir = parts.dayDirectory(under: archiveRoot)
        await Task.detached(priority: .utility) {
            Self.generateDailySummaryOffMain(dayDir: dayDir, dateString: parts.dateString)
        }.value
    }

    // MARK: - Markdown generation

    private func dictationMarkdown(
        entry: DictationEntry,
        rawTranscript: String?,
        deliveredText: String?,
        audioFileNameOverride: String? = nil
    ) -> String {
        let audioFileName = audioFileNameOverride
            ?? entry.audioPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let context = entry.capturedContext
        let archiveSnippets = LocalContextPersistencePolicy.archiveVisibleTextSnippets(from: context)

        var yaml: [(String, String)] = [
            ("type", "dictation"),
            ("id", entry.id.uuidString),
            ("date", Self.iso8601Formatter.string(from: entry.date)),
            ("duration_seconds", String(format: "%.1f", entry.duration)),
            ("word_count", "\(entry.wordCount)"),
            ("app", entry.appName),
            ("bundle_id", entry.bundleId),
        ]
        yamlAppendOptional(&yaml, "window_title", context.windowTitle)
        yamlAppendOptional(&yaml, "browser_url", context.browserURL)
        yamlAppendOptional(&yaml, "code_file", context.codeFileName)
        yamlAppendOptional(&yaml, "slack_recipient", context.slackRecipient)
        yamlAppendOptional(&yaml, "selected_text_preview", LocalContextPersistencePolicy.archiveSelectedTextPreview(from: context))
        yamlAppendOptional(&yaml, "focused_field_preview", LocalContextPersistencePolicy.archiveFocusedFieldPreview(from: context))
        if !archiveSnippets.isEmpty {
            yaml.append(("visible_text_snippet_count", "\(context.visibleTextSnippets.count)"))
        }
        yaml.append(("mode", entry.mode))
        yamlAppendOptional(&yaml, "audio", audioFileName)

        var md = "---\n"
        for (key, value) in yaml {
            md += "\(key): \(yamlQuote(value))\n"
        }
        md += "delivery:\n"
        md += "  auto_pasted: \(entry.autoPasted ?? false)\n"
        md += "  auto_sent: \(entry.autoSent ?? false)\n"
        md += "  copied_to_clipboard: \(entry.copiedToClipboard ?? false)\n"
        md += "---\n\n"

        md += "# Dictation\n\n"

        let displayText = deliveredText ?? entry.text
        md += displayText + "\n"

        if let raw = rawTranscript, !raw.isEmpty,
           raw.trimmed != displayText.trimmed {
            appendSection(&md, heading: "Raw Transcript", blockquote: raw)
        }

        if let audit = entry.vocabularyBoostAuditSummary,
           !audit.decisions.isEmpty {
            md += "\n---\n\n## Vocabulary Boost\n\n"
            for decision in audit.decisions {
                md += "- \(decision.diagnosticLine)\n"
            }
        }

        if let selected = context.selectedText, !selected.trimmed.isEmpty {
            appendSection(&md, heading: "Selected Text", blockquote: selected)
        }

        if let focused = context.focusedFieldContent, !focused.trimmed.isEmpty {
            md += "\n---\n\n## Focused Field Content\n\n"
            md += "```\n" + focused + "\n```\n"
        }

        if !archiveSnippets.isEmpty {
            md += "\n---\n\n## Visible Text Context\n\n"
            for snippet in archiveSnippets {
                md += "- " + snippet.replacingOccurrences(of: "\n", with: " ") + "\n"
            }
        }

        return md
    }

    private func memoMarkdown(memo: MemoEntry, audioFileName: String?) -> String {
        var yaml: [(String, String)] = [
            ("type", "memo"),
            ("id", memo.id.uuidString),
            ("date", Self.iso8601Formatter.string(from: memo.date)),
            ("title", memo.displayTitle),
            ("duration_seconds", String(format: "%.1f", memo.duration)),
            ("word_count", "\(memo.text.split(separator: " ").count)"),
        ]
        yamlAppendOptional(&yaml, "audio", audioFileName)
        var md = "---\n"
        for (key, value) in yaml {
            md += "\(key): \(yamlQuote(value))\n"
        }
        md += "---\n\n"

        md += "# \(memo.displayTitle)\n\n"
        md += memo.text + "\n"

        if let distilled = memo.distilledText,
           !distilled.trimmed.isEmpty {
            md += "\n---\n\n## Distilled\n\n"
            md += distilled + "\n"
        }

        return md
    }

    // MARK: - Helpers

    /// Extracts and caches year/month/day components from a date for path construction.
    private struct DateParts {
        let year: Int
        let month: Int
        let day: Int

        init(_ date: Date) {
            let calendar = Calendar.current
            year = calendar.component(.year, from: date)
            month = calendar.component(.month, from: date)
            day = calendar.component(.day, from: date)
        }

        func dayDirectory(under root: URL) -> URL {
            root.appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }

        /// Relative path under App Support: `archive/YYYY/MM/DD`
        var relativePath: String {
            String(format: "archive/%04d/%02d/%02d", year, month, day)
        }

        var dateString: String {
            String(format: "%04d-%02d-%02d", year, month, day)
        }
    }

    /// File base name: `HH-mm-ss-{full UUID}`. The full identity prevents a
    /// same-second 16-bit prefix collision from overwriting retained audio.
    private func baseName(for date: Date, id: UUID) -> String {
        let calendar = Calendar.current
        let h = calendar.component(.hour, from: date)
        let m = calendar.component(.minute, from: date)
        let s = calendar.component(.second, from: date)
        return String(
            format: "%02d-%02d-%02d-%@",
            h,
            m,
            s,
            id.uuidString.lowercased()
        )
    }

    /// Copies an audio file into `dayDir`, returning the destination file name on success.
    @discardableResult
    private func copyAudio(from sourceURL: URL, to dayDir: URL, baseName: String, label: String) -> String? {
        guard fm.fileExists(atPath: sourceURL.path) else { return nil }
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
        let audioFileName = "\(baseName).\(ext)"
        let dest = dayDir.appendingPathComponent(audioFileName)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: sourceURL, to: dest)
            return audioFileName
        } catch {
            log.error("Failed to copy \(label, privacy: .public) audio: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func ensureDirectory(_ url: URL) {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func resolveAppSupportPath(_ relativePath: String) -> URL {
        if relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: relativePath)
        }
        return appSupportRoot.appendingPathComponent(relativePath)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }

    private func appendSection(_ md: inout String, heading: String, blockquote text: String) {
        md += "\n---\n\n## \(heading)\n\n"
        md += "> " + text.replacingOccurrences(of: "\n", with: "\n> ") + "\n"
    }

    private func yamlQuote(_ value: String) -> String {
        if value.contains(":") || value.contains("\"") || value.contains("#")
            || value.hasPrefix(" ") || value.hasSuffix(" ") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private func yamlAppendOptional(_ pairs: inout [(String, String)], _ key: String, _ value: String?) {
        if let value, !value.trimmed.isEmpty {
            pairs.append((key, value))
        }
    }

    /// Parses simple YAML frontmatter from `---` delimited markdown.
    private func parseFrontmatter(_ content: String) -> [String: String] {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first == "---" else { return [:] }

        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line == "---" { break }
            if line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    private nonisolated static func writeArchiveFilesOffMain(
        archiveRoot: URL,
        dayDir: URL,
        dayRelativePath: String,
        baseName: String,
        markdown: String,
        markdownWhenAudioCopied: String? = nil,
        recordingURL: URL?,
        label: String
    ) async -> FileWriteResult {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dayDir, withIntermediateDirectories: true)

            var audioRelativePath: String?
            var didCopyRecordingToArchive = false

            if let recordingURL, fm.fileExists(atPath: recordingURL.path) {
                let ext = recordingURL.pathExtension.isEmpty ? "m4a" : recordingURL.pathExtension.lowercased()
                let audioFileName = "\(baseName).\(ext)"
                let destinationURL = dayDir.appendingPathComponent(audioFileName)
                do {
                    if fm.fileExists(atPath: destinationURL.path) {
                        try fm.removeItem(at: destinationURL)
                    }
                    try fm.copyItem(at: recordingURL, to: destinationURL)
                    audioRelativePath = "\(dayRelativePath)/\(audioFileName)"
                    didCopyRecordingToArchive = true
                } catch {
                    Logger.resonant("ArchiveWriter")
                        .error("Failed to copy \(label, privacy: .public) audio: \(error.localizedDescription, privacy: .public)")
                }
            }

            let resolvedMarkdown = didCopyRecordingToArchive
                ? (markdownWhenAudioCopied ?? markdown)
                : markdown
            let markdownFileName = "\(baseName).md"
            let markdownURL = dayDir.appendingPathComponent(markdownFileName)
            do {
                try resolvedMarkdown.write(to: markdownURL, atomically: true, encoding: .utf8)
            } catch {
                print("[ArchiveWriter] Failed to write markdown: \(error)")
                return FileWriteResult(
                    audioRelativePath: audioRelativePath,
                    markdownRelativePath: nil,
                    didCopyRecordingToArchive: didCopyRecordingToArchive
                )
            }

            return FileWriteResult(
                audioRelativePath: audioRelativePath,
                markdownRelativePath: "\(dayRelativePath)/\(markdownFileName)",
                didCopyRecordingToArchive: didCopyRecordingToArchive
            )
        }.value
    }

    private nonisolated static func purgeOldArchiveOffMain(archiveRoot: URL, cutoff: Date) {
        let fm = FileManager.default
        let calendar = Calendar.current

        guard let yearDirs = try? fm.contentsOfDirectory(
            at: archiveRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        for yearDir in yearDirs {
            guard let year = Int(yearDir.lastPathComponent) else { continue }

            guard let monthDirs = try? fm.contentsOfDirectory(
                at: yearDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { continue }

            for monthDir in monthDirs {
                guard let month = Int(monthDir.lastPathComponent) else { continue }

                guard let dayDirs = try? fm.contentsOfDirectory(
                    at: monthDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                ) else { continue }

                for dayDir in dayDirs {
                    guard let day = Int(dayDir.lastPathComponent) else { continue }
                    var comps = DateComponents()
                    comps.year = year
                    comps.month = month
                    comps.day = day
                    guard let dirDate = calendar.date(from: comps), dirDate < cutoff else { continue }
                    try? fm.removeItem(at: dayDir)
                }

                if (try? fm.contentsOfDirectory(atPath: monthDir.path))?.isEmpty == true {
                    try? fm.removeItem(at: monthDir)
                }
            }

            if (try? fm.contentsOfDirectory(atPath: yearDir.path))?.isEmpty == true {
                try? fm.removeItem(at: yearDir)
            }
        }
    }

    private nonisolated static func generateDailySummaryOffMain(dayDir: URL, dateString: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dayDir.path) else { return }

        guard let files = try? fm.contentsOfDirectory(
            at: dayDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        let mdFiles = files
            .filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !mdFiles.isEmpty else { return }

        struct TimelineEntry {
            let time: String
            let label: String
            let fileName: String
            let wordCount: Int
        }

        var dictationCount = 0
        var memoCount = 0
        var meetingCount = 0
        var totalWords = 0
        var totalDuration: Double = 0
        var timeline: [TimelineEntry] = []

        for file in mdFiles {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let frontmatter = parseFrontmatterStatic(content)

            let type = frontmatter["type"] ?? ""
            let words = Int(frontmatter["word_count"] ?? "") ?? 0
            let duration = Double(frontmatter["duration_seconds"] ?? "") ?? 0

            totalWords += words
            totalDuration += duration

            let fileName = file.lastPathComponent
            let stem = file.deletingPathExtension().lastPathComponent
            let timePart = String(stem.prefix(5)).replacingOccurrences(of: "-", with: ":")

            switch type {
            case "dictation":
                dictationCount += 1
                let app = frontmatter["app"] ?? "Unknown"
                timeline.append(TimelineEntry(time: timePart, label: "Dictation in \(app)", fileName: fileName, wordCount: words))
            case "memo":
                memoCount += 1
                let title = frontmatter["title"] ?? "Untitled memo"
                timeline.append(TimelineEntry(time: timePart, label: "Memo: \(title)", fileName: fileName, wordCount: words))
            case "meeting":
                meetingCount += 1
                let title = frontmatter["title"] ?? "Meeting"
                let app = frontmatter["app"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedApp = (app?.isEmpty == false) ? app : nil
                let label = resolvedApp.map { "\(title) (\($0))" } ?? title
                timeline.append(TimelineEntry(time: timePart, label: "Meeting: \(label)", fileName: fileName, wordCount: words))
            default:
                break
            }
        }

        let durationFormatted = formatDurationStatic(totalDuration)
        let wordCountFormatter = NumberFormatter()
        wordCountFormatter.numberStyle = .decimal
        let formattedWordCount = wordCountFormatter.string(from: NSNumber(value: totalWords)) ?? "\(totalWords)"
        var md = """
        ---
        type: daily_summary
        date: \(dateString)
        dictation_count: \(dictationCount)
        memo_count: \(memoCount)
        total_words: \(totalWords)
        total_duration_seconds: \(totalDuration)
        ---

        # Daily Summary \u{2014} \(dateString)

        **\(dictationCount)** dictations \u{00B7} **\(memoCount)** memos \u{00B7} **\(meetingCount)** meetings \u{00B7} **\(formattedWordCount)** words \u{00B7} **\(durationFormatted)**

        ## Timeline\n\n
        """

        for entry in timeline {
            md += "- `\(entry.time)` \u{2014} [\(entry.label)](./\(entry.fileName)) \u{2014} \(entry.wordCount) words\n"
        }

        let summaryURL = dayDir.appendingPathComponent("_daily-summary.md")
        try? md.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    private nonisolated static func formatDurationStatic(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }

    private nonisolated static func parseFrontmatterStatic(_ content: String) -> [String: String] {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first == "---" else { return [:] }

        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line == "---" { break }
            if line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    nonisolated static func updatedMeetingMarkdown(markdown: String, newSummary: String) -> String {
        let normalizedSummary = newSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSummary.isEmpty else { return markdown }

        var updated = markdown
        let summaryMarker = "\n## Summary\n"

        if let summaryRange = updated.range(of: summaryMarker) {
            let afterSummary = updated[summaryRange.upperBound...]
            let summaryEnd = afterSummary.range(of: "\n## ")?.lowerBound ?? updated.endIndex
            updated.replaceSubrange(
                summaryRange.lowerBound..<summaryEnd,
                with: "\n## Summary\n\n\(normalizedSummary)\n"
            )
            return updated
        }

        if let transcriptRange = updated.range(of: "\n## Transcript\n") {
            updated.insert(contentsOf: "\n## Summary\n\n\(normalizedSummary)\n", at: transcriptRange.lowerBound)
            return updated
        }

        if !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += "\n## Summary\n\n\(normalizedSummary)\n"
        return updated
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
