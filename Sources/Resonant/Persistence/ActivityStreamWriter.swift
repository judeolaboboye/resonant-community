import Foundation

/// Writes dictation and memo events to a local JSONL stream and generates daily markdown journals.
@MainActor
final class ActivityStreamWriter {

    nonisolated private static let appendLock = NSLock()

    private let fm: FileManager
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let eventsDirectory: URL
    private let journalDirectory: URL
    private let audioDirectory: URL
    private let ambientDirectory: URL
    private let currentAmbientFileURL: URL
    private let streamRoot: URL

    private var journalDebounceTask: Task<Void, Never>?
    private var pendingJournalDate: Date?
    private var isWorkspaceWriteSuspended = false
    private var activeWriteCount = 0
    private var writeDrainWaiters: [CheckedContinuation<Void, Never>] = []

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    // MARK: - Init

    init(fileManager: FileManager = .default, supportRoot: URL? = nil) {
        fm = fileManager
        let support = supportRoot ?? AppSupportPaths.resonantRoot(fileManager: fileManager)
        streamRoot = support.appendingPathComponent("stream", isDirectory: true)
        eventsDirectory = streamRoot.appendingPathComponent("events", isDirectory: true)
        journalDirectory = streamRoot.appendingPathComponent("journal", isDirectory: true)
        audioDirectory = streamRoot.appendingPathComponent("audio", isDirectory: true)
        ambientDirectory = streamRoot.appendingPathComponent("ambient", isDirectory: true)
        currentAmbientFileURL = ambientDirectory.appendingPathComponent("current.json")

        for dir in [eventsDirectory, journalDirectory, audioDirectory, ambientDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Dictation events

    @discardableResult
    func writeDictationEvent(
        result: TranscriptionResult,
        resolvedText: String,
        entry: DictationEntry,
        autoPasted: Bool,
        autoSent: Bool,
        copiedToClipboard: Bool,
        saveAudioEnabled: Bool,
        includeContextMetadata: Bool
    ) async -> Bool {
        guard beginWrite() else { return false }
        defer { endWrite() }
        // Entry identity and date are stable across crash-recovery retries;
        // wall-clock retry time is not. Use the transaction date so the same
        // ID always targets the same daily stream file.
        let now = entry.date
        let eventID = entry.id
        let context = includeContextMetadata ? entry.capturedContext : nil

        var audioPath = entry.audioPath
        if audioPath == nil,
           saveAudioEnabled, let recordingURL = result.recordingURL,
           fm.fileExists(atPath: recordingURL.path) {
            let ext = recordingURL.pathExtension.isEmpty ? "m4a" : recordingURL.pathExtension.lowercased()
            let fileName = "\(eventID.uuidString).\(ext)"
            let dest = audioDirectory.appendingPathComponent(fileName)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: recordingURL, to: dest)
                audioPath = "stream/audio/\(fileName)"
            } catch {
                print("[ActivityStream] Failed to copy audio: \(error)")
            }
        }

        let event = ActivityStreamEvent(
            id: eventID.uuidString,
            timestamp: Self.iso8601Formatter.string(from: now),
            type: .dictation,
            text: resolvedText,
            rawTranscript: result.text != resolvedText ? result.text : nil,
            context: context,
            durationSeconds: result.duration,
            wordCount: entry.wordCount,
            mode: entry.mode,
            audioPath: audioPath,
            delivery: .init(
                autoPasted: autoPasted,
                autoSent: autoSent,
                copiedToClipboard: copiedToClipboard
            ),
            memoTitle: nil,
            meetingTitle: nil
        )

        let fileURL = eventsDirectory.appendingPathComponent("\(Self.dateFormatter.string(from: now)).jsonl")
        guard let jsonData = try? encoder.encode(event) else { return false }
        guard await Self.appendLine(
            jsonData,
            to: fileURL,
            eventID: event.id
        ) else { return false }
        scheduleJournalUpdate(for: now)
        return true
    }

    @discardableResult
    func writeRecoveredDictationEvent(entry: DictationEntry) async -> Bool {
        guard beginWrite() else { return false }
        defer { endWrite() }
        let event = ActivityStreamEvent(
            id: entry.id.uuidString,
            timestamp: Self.iso8601Formatter.string(from: entry.date),
            type: .dictation,
            text: entry.text,
            rawTranscript: entry.rawTranscript,
            context: entry.capturedContext,
            durationSeconds: entry.duration,
            wordCount: entry.wordCount,
            mode: entry.mode,
            audioPath: entry.audioPath,
            delivery: .init(
                autoPasted: entry.autoPasted == true,
                autoSent: entry.autoSent == true,
                copiedToClipboard: entry.copiedToClipboard == true
            ),
            memoTitle: nil,
            meetingTitle: nil
        )
        let fileURL = eventsDirectory.appendingPathComponent(
            "\(Self.dateFormatter.string(from: entry.date)).jsonl"
        )
        guard let jsonData = try? encoder.encode(event) else { return false }
        guard await Self.appendLine(
            jsonData,
            to: fileURL,
            eventID: event.id
        ) else { return false }
        scheduleJournalUpdate(for: entry.date)
        return true
    }

    // MARK: - Memo events

    @discardableResult
    func writeMemoEvent(memo: MemoEntry) async -> Bool {
        guard beginWrite() else { return false }
        defer { endWrite() }
        let date = memo.date

        let event = ActivityStreamEvent(
            id: memo.id.uuidString,
            timestamp: Self.iso8601Formatter.string(from: date),
            type: .memo,
            text: memo.text,
            rawTranscript: nil,
            selectedText: nil,
            appName: nil,
            bundleId: nil,
            windowTitle: nil,
            browserURL: nil,
            codeFileName: nil,
            slackRecipient: nil,
            focusedFieldContent: nil,
            visibleTextSnippets: nil,
            durationSeconds: memo.duration,
            wordCount: memo.text.split(separator: " ").count,
            mode: DictationMode.memo.rawValue,
            audioPath: memo.audioPath,
            delivery: nil,
            memoTitle: memo.displayTitle,
            meetingTitle: nil
        )

        let fileURL = eventsDirectory.appendingPathComponent("\(Self.dateFormatter.string(from: date)).jsonl")
        guard let jsonData = try? encoder.encode(event) else { return false }
        guard await Self.appendLine(jsonData, to: fileURL, eventID: event.id) else {
            return false
        }
        scheduleJournalUpdate(for: date)
        return true
    }

    // MARK: - Meeting events

    func writeMeetingEvent(entry: MeetingEntry, transcript: String) async {
        guard beginWrite() else { return }
        defer { endWrite() }
        let date = entry.startedAt
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmedTranscript.isEmpty ? entry.displayTitle : trimmedTranscript
        let context = CapturedContext(
            appName: entry.detectedApp,
            bundleId: nil,
            windowTitle: nil,
            browserURL: nil,
            codeFileName: nil,
            slackRecipient: nil
        )

        let event = ActivityStreamEvent(
            id: entry.id.uuidString,
            timestamp: Self.iso8601Formatter.string(from: date),
            type: .meeting,
            text: text,
            rawTranscript: nil,
            context: context,
            durationSeconds: entry.durationSeconds,
            wordCount: entry.wordCount,
            mode: "meeting",
            audioPath: entry.audioPath,
            delivery: nil,
            memoTitle: nil,
            meetingTitle: entry.displayTitle
        )

        let fileURL = eventsDirectory.appendingPathComponent("\(Self.dateFormatter.string(from: date)).jsonl")
        guard let jsonData = try? encoder.encode(event) else { return }
        _ = await Self.appendLine(jsonData, to: fileURL, eventID: event.id)
        scheduleJournalUpdate(for: date)
    }

    // MARK: - Ambient events

    func writeAmbientSnapshot(_ snapshot: AmbientContextSnapshot) async {
        guard beginWrite() else { return }
        defer { endWrite() }
        let event = makeAmbientEvent(from: snapshot)
        let fileURL = ambientDirectory.appendingPathComponent("\(Self.dateFormatter.string(from: snapshot.timestamp)).jsonl")
        guard let jsonData = try? encoder.encode(event) else { return }
        _ = await Self.appendLine(jsonData, to: fileURL, eventID: event.id)
    }

    func writeCurrentAmbientSnapshot(_ snapshot: AmbientContextSnapshot) async {
        guard beginWrite() else { return }
        defer { endWrite() }
        guard let jsonData = try? encoder.encode(makeAmbientEvent(from: snapshot)) else { return }
        await Self.writeData(jsonData, to: currentAmbientFileURL)
    }

    func bootstrapAmbientFiles(from snapshots: [AmbientContextSnapshot]) async {
        guard beginWrite() else { return }
        defer { endWrite() }
        let sortedSnapshots = snapshots.sorted { $0.timestamp < $1.timestamp }
        guard !sortedSnapshots.isEmpty else { return }

        let ambientDirectory = ambientDirectory
        let currentAmbientFileURL = currentAmbientFileURL
        let events = sortedSnapshots.map(makeAmbientEvent(from:))
        let latest = sortedSnapshots.last.map(makeAmbientEvent(from:))

        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let hasHistoryFiles = ((try? fm.contentsOfDirectory(
                at: ambientDirectory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )) ?? []).contains { $0.pathExtension == "jsonl" }
            if !hasHistoryFiles {
                Self.rewriteAmbientHistoryOffMain(using: events, ambientDirectory: ambientDirectory)
            }
            if !fm.fileExists(atPath: currentAmbientFileURL.path), let latest {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                if let jsonData = try? encoder.encode(latest) {
                    try? jsonData.write(to: currentAmbientFileURL, options: .atomic)
                }
            }
        }.value
    }

    func clearCurrentAmbientSnapshot() async {
        guard beginWrite() else { return }
        defer { endWrite() }
        let currentAmbientFileURL = currentAmbientFileURL
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            if fm.fileExists(atPath: currentAmbientFileURL.path) {
                try? fm.removeItem(at: currentAmbientFileURL)
            }
        }.value
    }

    // MARK: - Retention

    func purgeOldFiles(olderThan days: Int) async {
        guard beginWrite() else { return }
        defer { endWrite() }
        guard days > 0, days < 36500 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let eventsDirectory = eventsDirectory
        let journalDirectory = journalDirectory
        let ambientDirectory = ambientDirectory
        let audioDirectory = audioDirectory
        await Task.detached(priority: .utility) {
            for dir in [eventsDirectory, journalDirectory, ambientDirectory] {
                Self.purgeFilesByDateStemOffMain(in: dir, before: cutoff)
            }
            Self.purgeFilesByCreationDateOffMain(in: audioDirectory, before: cutoff)
        }.value
    }

    func clearWorkspaceData() async {
        await quiesceForWorkspaceClear()

        let streamRoot = streamRoot
        let directories = [eventsDirectory, journalDirectory, audioDirectory, ambientDirectory]
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            if fm.fileExists(atPath: streamRoot.path) {
                try? fm.removeItem(at: streamRoot)
            }
            for dir in directories {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }.value
        isWorkspaceWriteSuspended = false
    }

    /// Prevents new stream mutations and joins every mutation already admitted,
    /// including a detached markdown render owned by the debounce task.
    func quiesceForWorkspaceClear() async {
        isWorkspaceWriteSuspended = true
        let journalTask = journalDebounceTask
        journalTask?.cancel()
        journalDebounceTask = nil
        pendingJournalDate = nil
        await journalTask?.value
        await waitForActiveWrites()
    }

    /// Use when a multi-store clear aborts before `clearWorkspaceData()`.
    func resumeAfterWorkspaceClear() {
        isWorkspaceWriteSuspended = false
    }

    // MARK: - Private

    private nonisolated static func appendLineOffMain(
        _ jsonData: Data,
        to fileURL: URL,
        eventID: String? = nil
    ) -> Bool {
        appendLock.lock()
        defer { appendLock.unlock() }

        let fm = FileManager.default
        var repairedExistingData = Data()
        var existingData = Data()
        var alreadyCommitted = false
        if fm.fileExists(atPath: fileURL.path) {
            do {
                existingData = try Data(contentsOf: fileURL)
            } catch {
                return false
            }
            // Keep only complete, decodable JSON objects. A process kill during
            // a historical FileHandle append could leave a partial tail; retry
            // must neither concatenate onto it nor treat raw ID bytes as a
            // committed event.
            for rawLine in existingData.split(separator: 0x0A) {
                let line = Data(rawLine)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                if let eventID, object["id"] as? String == eventID {
                    alreadyCommitted = true
                }
                repairedExistingData.append(line)
                repairedExistingData.append(0x0A)
            }
        }

        var line = jsonData
        line.append(0x0A)

        do {
            let needsRepair = repairedExistingData != existingData
            if needsRepair {
                try repairedExistingData.write(to: fileURL, options: .atomic)
            }
            if alreadyCommitted {
                return true
            }
            if fm.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.synchronize()
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func appendLine(
        _ jsonData: Data,
        to fileURL: URL,
        eventID: String? = nil
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            appendLineOffMain(jsonData, to: fileURL, eventID: eventID)
        }.value
    }

    private nonisolated static func writeData(_ data: Data, to fileURL: URL) async {
        await Task.detached(priority: .utility) {
            try? data.write(to: fileURL, options: .atomic)
        }.value
    }

    private nonisolated static func rewriteAmbientHistoryOffMain(using events: [AmbientStreamEvent], ambientDirectory: URL) {
        let fm = FileManager.default
        let iso8601Formatter = makeISO8601Formatter()
        let dateFormatter = makeDayFormatter()
        let existingFiles = (try? fm.contentsOfDirectory(
            at: ambientDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for file in existingFiles where file.pathExtension == "jsonl" {
            try? fm.removeItem(at: file)
        }

        let eventsByDay = Dictionary(grouping: events) { event in
            let date = iso8601Formatter.date(from: event.timestamp) ?? Date.distantPast
            return dateFormatter.string(from: date)
        }

        for (dateString, dayEvents) in eventsByDay {
            let fileURL = ambientDirectory.appendingPathComponent("\(dateString).jsonl")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = dayEvents.reduce(into: Data()) { result, event in
                guard var line = try? encoder.encode(event) else { return }
                line.append(0x0A)
                result.append(line)
            }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func makeAmbientEvent(from snapshot: AmbientContextSnapshot) -> AmbientStreamEvent {
        AmbientStreamEvent(
            id: snapshot.id.uuidString,
            timestamp: Self.iso8601Formatter.string(from: snapshot.timestamp),
            appName: snapshot.appName,
            bundleId: snapshot.bundleId,
            windowTitle: snapshot.windowTitle,
            browserURL: snapshot.browserURL,
            codeFileName: snapshot.codeFileName,
            slackRecipient: snapshot.slackRecipient,
            focusedFieldContent: snapshot.focusedFieldContent,
            visibleTextSnippets: snapshot.visibleTextSnippets.isEmpty ? nil : snapshot.visibleTextSnippets,
            dwellDurationSeconds: snapshot.dwellDurationSeconds,
            clipboardText: snapshot.clipboardText,
            browserTabs: snapshot.browserTabs.isEmpty ? nil : snapshot.browserTabs,
            notificationAppName: snapshot.notificationAppName,
            notificationBundleId: snapshot.notificationBundleId,
            notificationTitle: snapshot.notificationTitle,
            notificationBody: snapshot.notificationBody,
            notificationURL: snapshot.notificationURL,
            notificationReceivedAt: snapshot.notificationReceivedAt.map {
                Self.iso8601Formatter.string(from: $0)
            }
        )
    }

    private func scheduleJournalUpdate(for date: Date) {
        guard !isWorkspaceWriteSuspended else { return }
        pendingJournalDate = date
        journalDebounceTask?.cancel()
        journalDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, let date = self.pendingJournalDate else { return }
            await self.generateDailyMarkdown(for: date)
            self.pendingJournalDate = nil
        }
    }

    private func generateDailyMarkdown(for date: Date) async {
        let dateString = Self.dateFormatter.string(from: date)
        let jsonlURL = eventsDirectory.appendingPathComponent("\(dateString).jsonl")
        let journalDir = journalDirectory

        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: jsonlURL) else { return }

            let decoder = JSONDecoder()
            let events = data.split(separator: 0x0A).compactMap {
                try? decoder.decode(ActivityStreamEvent.self, from: Data($0))
            }
            guard !events.isEmpty else { return }

            let dictationCount = events.filter { $0.type == .dictation }.count
            let memoCount = events.filter { $0.type == .memo }.count
            let meetingCount = events.filter { $0.type == .meeting }.count
            let totalWords = events.reduce(0) { $0 + $1.wordCount }
            let totalDuration = events.reduce(0.0) { $0 + $1.durationSeconds }

            var md = "# Activity — \(dateString)\n\n"
            md += "**\(dictationCount)** dictations, **\(memoCount)** memos, **\(meetingCount)** meetings — "
            md += "**\(totalWords)** words, **\(Self.formatDurationStatic(totalDuration))**\n\n"

            var grouped: [(key: String, events: [ActivityStreamEvent])] = []
            var index: [String: Int] = [:]

            for event in events {
                let key = event.capturedContext.appName
                    ?? (event.type == .memo ? "Memos" : event.type == .meeting ? "Meetings" : "Unknown")
                if let i = index[key] {
                    grouped[i].events.append(event)
                } else {
                    index[key] = grouped.count
                    grouped.append((key, [event]))
                }
            }

            for (appName, groupEvents) in grouped {
                md += "## \(appName)\n\n"
                for event in groupEvents {
                    let time = Self.formatTimestampStatic(event.timestamp)
                    let preview = String(event.text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                    let context = event.capturedContext

                    if event.type == .memo, let title = event.memoTitle {
                        md += "- **\(time)** 🎙 _\(title)_\n"
                    } else if event.type == .meeting {
                        let title = event.meetingTitle ?? "Meeting"
                        md += "- **\(time)** 📞 _\(title)_"
                        if let appName = context.appName, !appName.isEmpty {
                            md += " · \(appName)"
                        }
                        md += "\n"
                    } else {
                        md += "- **\(time)** \(preview)"
                        if let url = context.browserURL {
                            md += " · [\(url)](\(url))"
                        } else if let file = context.codeFileName {
                            md += " · `\(file)`"
                        }
                        md += "\n"
                    }
                }
                md += "\n"
            }

            let mdURL = journalDir.appendingPathComponent("\(dateString).md")
            try? md.write(to: mdURL, atomically: true, encoding: .utf8)
        }.value
    }

    private func beginWrite() -> Bool {
        guard !isWorkspaceWriteSuspended else { return false }
        activeWriteCount += 1
        return true
    }

    private func endWrite() {
        precondition(activeWriteCount > 0)
        activeWriteCount -= 1
        guard activeWriteCount == 0 else { return }
        let waiters = writeDrainWaiters
        writeDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForActiveWrites() async {
        guard activeWriteCount > 0 else { return }
        await withCheckedContinuation { continuation in
            writeDrainWaiters.append(continuation)
        }
    }

    private nonisolated static func purgeFilesByDateStemOffMain(in directory: URL, before cutoff: Date) {
        let fm = FileManager.default
        let dateFormatter = makeDayFormatter()
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        for file in files {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let fileDate = dateFormatter.date(from: stem), fileDate < cutoff else { continue }
            try? fm.removeItem(at: file)
        }
    }

    private nonisolated static func purgeFilesByCreationDateOffMain(in directory: URL, before cutoff: Date) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ) else { return }

        for file in files {
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let created = attrs[.creationDate] as? Date,
                  created < cutoff else { continue }
            try? fm.removeItem(at: file)
        }
    }

    private nonisolated static func formatDurationStatic(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }

    private nonisolated static func formatTimestampStatic(_ iso: String) -> String {
        let iso8601Formatter = makeISO8601Formatter()
        guard let date = iso8601Formatter.date(from: iso) else {
            return String(iso.prefix(5))
        }
        return makeTimeFormatter().string(from: date)
    }

    private nonisolated static func makeDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }

    private nonisolated static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private nonisolated static func makeTimeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }
}
