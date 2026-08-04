import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class MemoManager {

    struct SaveResult {
        let memo: MemoEntry
        let dataStoreCommitted: Bool
        let didPersistRequestedAudio: Bool
    }

    private(set) var memos: [MemoEntry] = []
    private(set) var pendingDeletedExternalIDs: Set<String> = []
    private(set) var hasVerifiedMemoLoad = false
    private var dataStore: DataStore?

    init(dataStore: DataStore? = nil) {
        self.dataStore = dataStore
    }

    /// Replaces the in-memory snapshot only after SwiftData confirms the read.
    /// A failed read must not look like a verified empty workspace: the audio
    /// orphan sweep depends on this snapshot to decide which files are live.
    @discardableResult
    func load(from store: DataStore) async -> Bool {
        dataStore = store
        hasVerifiedMemoLoad = false
        let descriptor = FetchDescriptor<MemoEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        do {
            let loadedMemos = try await store.fetchInBackgroundChecked(descriptor)
            memos = loadedMemos
            hasVerifiedMemoLoad = true
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func save(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        duration: TimeInterval,
        recordingURL: URL? = nil,
        shouldPersistAudio: Bool = false
    ) async -> SaveResult {
        let title = autoTitle(from: text)
        let audioPath = await persistAudioIfNeeded(
            from: recordingURL,
            memoID: id,
            shouldPersistAudio: shouldPersistAudio
        )
        let memo = MemoEntry(
            id: id,
            text: text,
            title: title,
            duration: duration,
            date: date,
            audioPath: audioPath
        )
        memos.insert(memo, at: 0)
        let dataStoreCommitted: Bool
        if let dataStore {
            dataStoreCommitted = await dataStore.save(memo)
        } else {
            dataStoreCommitted = false
        }
        return SaveResult(
            memo: memo,
            dataStoreCommitted: dataStoreCommitted,
            didPersistRequestedAudio: !shouldPersistAudio || audioPath != nil
        )
    }

    func delete(_ memo: MemoEntry) {
        if let externalID = memo.externalID?.nilIfEmpty {
            pendingDeletedExternalIDs.insert(externalID)
        } else {
            // Locally-created memos may not have an externalID yet; track the generated form.
            let localID = "workspace-memo:" + memo.id.uuidString.lowercased()
            pendingDeletedExternalIDs.insert(localID)
        }
        memos.removeAll { $0.id == memo.id }
        let audioURL = audioURL(for: memo)
        Task {
            if let audioURL {
                _ = await Self.removeFileOffMain(audioURL)
            }
            await dataStore?.delete(memo)
        }
    }

    /// Rolls back a memo that was inserted while cancellation was racing the
    /// final save. Permanent audio is removed only after SwiftData confirms the
    /// row deletion; callers retain their recovery marker/source until this
    /// returns true.
    @discardableResult
    func rollback(_ memo: MemoEntry) async -> Bool {
        guard let dataStore else { return false }
        let persistedAudioURL = audioURL(for: memo.audioPath)
        if let persistedAudioURL,
           !(await Self.removeFileOffMain(persistedAudioURL)) {
            return false
        }
        guard await dataStore.delete(memo) else { return false }

        memos.removeAll { $0.id == memo.id }
        return true
    }

    nonisolated static func removePersistedAudioForRecovery(
        memoID: UUID,
        sourceURL: URL,
        supportRoot: URL = AppSupportPaths.resonantRoot()
    ) async -> Bool {
        let destination = persistedAudioURL(
            memoID: memoID,
            sourceURL: sourceURL,
            supportRoot: supportRoot
        )
        return await removeFileOffMain(destination)
    }

    func memo(id: UUID) -> MemoEntry? {
        memos.first { $0.id == id }
    }

    func updateTitle(for memo: MemoEntry, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard memo.title != trimmed else { return }
        memo.title = trimmed
        refreshObservation()
        guard let dataStore else { return }
        let memoID = memo.id
        _ = await dataStore.performBackgroundWrite { context in
            var descriptor = FetchDescriptor<MemoEntry>(
                predicate: #Predicate { $0.id == memoID }
            )
            descriptor.fetchLimit = 1
            guard let persisted = try? context.fetch(descriptor).first else { return }
            persisted.title = trimmed
        }
    }

    func updateText(for memo: MemoEntry, text: String) async {
        guard memo.text != text else { return }
        memo.text = text
        refreshObservation()
        guard let dataStore else { return }
        let memoID = memo.id
        _ = await dataStore.performBackgroundWrite { context in
            var descriptor = FetchDescriptor<MemoEntry>(
                predicate: #Predicate { $0.id == memoID }
            )
            descriptor.fetchLimit = 1
            guard let persisted = try? context.fetch(descriptor).first else { return }
            persisted.text = text
        }
    }

    func updateDistilledText(for memo: MemoEntry, distilledText: String?) async {
        let normalized = distilledText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard memo.distilledText != normalized else { return }
        memo.distilledText = normalized
        refreshObservation()
        guard let dataStore else { return }
        let memoID = memo.id
        _ = await dataStore.performBackgroundWrite { context in
            var descriptor = FetchDescriptor<MemoEntry>(
                predicate: #Predicate { $0.id == memoID }
            )
            descriptor.fetchLimit = 1
            guard let persisted = try? context.fetch(descriptor).first else { return }
            persisted.distilledText = normalized
        }
    }

    func audioURL(for memo: MemoEntry) -> URL? {
        guard let url = audioURL(for: memo.audioPath) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func importAudio(from sourceURL: URL, memoID: UUID) -> String? {
        Self.persistAudioOffMain(
            from: sourceURL,
            memoID: memoID,
            removeSourceAfterCopy: false,
            supportRoot: appSupportDirectory()
        )
    }

    /// Returns and clears any externalIDs that were deleted since the last drain.
    func drainDeletedExternalIDs() -> Set<String> {
        let ids = pendingDeletedExternalIDs
        pendingDeletedExternalIDs.removeAll()
        return ids
    }

    func clearWorkspaceData() async {
        memos = []
        hasVerifiedMemoLoad = false
        pendingDeletedExternalIDs.removeAll()
        let audioDirectory = appSupportDirectory().appendingPathComponent("audio", isDirectory: true)
        await Self.resetDirectoryOffMain(audioDirectory)
    }

    /// Deletes files that no persisted memo references. This is intentionally
    /// independent of file timestamps: a recent orphan is still an orphan, while
    /// an old copied source can still be the live audio for a recent memo.
    ///
    /// Keep the legacy argument until AppState's launch call site is migrated.
    func purgeOldAudio(olderThan _: Int) async {
        guard hasVerifiedMemoLoad else { return }
        let audioDirectory = appSupportDirectory()
            .appendingPathComponent("audio", isDirectory: true)
        let retainedAudioPaths = Set(memos.compactMap { memo in
            audioURL(for: memo.audioPath)?.standardizedFileURL.path
        })
        await Self.purgeUnreferencedAudioFiles(
            in: audioDirectory,
            retainedAudioPaths: retainedAudioPaths
        )
    }

    nonisolated static func purgeUnreferencedAudioFiles(
        in audioDirectory: URL,
        retainedAudioPaths: Set<String>
    ) async {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let files = (try? fileManager.contentsOfDirectory(
                at: audioDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles
            )) ?? []
            for file in files {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true,
                      Self.shouldPurgeAudioFile(file, retainedAudioPaths: retainedAudioPaths)
                else { continue }
                try? fileManager.removeItem(at: file)
            }
        }.value
    }

    nonisolated static func shouldPurgeAudioFile(
        _ fileURL: URL,
        retainedAudioPaths: Set<String>
    ) -> Bool {
        !retainedAudioPaths.contains(fileURL.standardizedFileURL.path)
    }

    // MARK: - Auto title

    func autoTitle(from text: String) -> String {
        // First sentence, up to 60 chars
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        let first = sentences.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
        return String(first.prefix(60))
    }

    func generateAITitle(for memo: MemoEntry, using convexClient: ConvexClient) async {
        let currentTitle = memo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = autoTitle(from: memo.text)

        // Skip if user has manually edited the title
        if !currentTitle.isEmpty, currentTitle != fallbackTitle {
            return
        }

        let snippet = String(memo.text.prefix(500))
        let prompt = "Generate a short title (max 8 words) for this voice memo. Return ONLY the title.\n\n\(snippet)"

        guard let result = await convexClient.processMemo(text: prompt, modelRoute: .meetingSummary)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }

        // Clean up common LLM formatting artifacts
        var cleaned = result
        // Strip surrounding quotes
        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\""))
            || (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")) {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        // Strip common prefixes like "Title: "
        for prefix in ["Title:", "title:", "Title -", "title -"] {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard !cleaned.isEmpty, cleaned.count <= 80 else { return }

        // Double-check title wasn't edited during the request
        let latestTitle = memo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !latestTitle.isEmpty, latestTitle != fallbackTitle {
            return
        }

        await updateTitle(for: memo, title: cleaned)
    }

    private func persistAudioIfNeeded(
        from recordingURL: URL?,
        memoID: UUID,
        shouldPersistAudio: Bool
    ) async -> String? {
        guard shouldPersistAudio, let recordingURL else { return nil }
        let supportRoot = appSupportDirectory()
        return await Task.detached(priority: .utility) {
            Self.persistAudioOffMain(
                from: recordingURL,
                memoID: memoID,
                removeSourceAfterCopy: false,
                supportRoot: supportRoot
            )
        }.value
    }

    nonisolated static func persistAudioOffMain(
        from sourceURL: URL,
        memoID: UUID,
        removeSourceAfterCopy: Bool,
        supportRoot: URL = AppSupportPaths.resonantRoot()
    ) -> String? {
        var copied = false
        defer {
            if removeSourceAfterCopy && copied {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        }

        let audioDirectory = supportRoot.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        let destinationURL = persistedAudioURL(
            memoID: memoID,
            sourceURL: sourceURL,
            supportRoot: supportRoot
        )
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            copied = true
            return "audio/\(destinationURL.lastPathComponent)"
        } catch {
            print("[MemoManager] Failed to persist memo audio: \(error)")
            return nil
        }
    }

    private func appSupportDirectory() -> URL {
        AppSupportPaths.resonantRoot()
    }

    private func refreshObservation() {
        memos = memos.sorted { $0.date > $1.date }
    }

    private nonisolated static func persistedAudioURL(
        memoID: UUID,
        sourceURL: URL,
        supportRoot: URL
    ) -> URL {
        let pathExtension = sourceURL.pathExtension.nilIfEmpty?.lowercased() ?? "m4a"
        return supportRoot
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(memoID.uuidString).\(pathExtension)")
    }

    private nonisolated static func removeFileOffMain(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else { return true }
            do {
                try fileManager.removeItem(at: url)
                return !fileManager.fileExists(atPath: url.path)
            } catch {
                return false
            }
        }.value
    }

    private nonisolated static func resetDirectoryOffMain(_ url: URL) async {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }.value
    }

    private func audioURL(for audioPath: String?) -> URL? {
        guard let audioPath = audioPath?.nilIfEmpty else { return nil }
        if audioPath.hasPrefix("file://"),
           let fileURL = URL(string: audioPath),
           fileURL.isFileURL {
            return fileURL
        }
        if audioPath.hasPrefix("/") {
            return URL(fileURLWithPath: audioPath)
        }
        return appSupportDirectory().appendingPathComponent(audioPath)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
