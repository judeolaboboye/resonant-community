import Foundation
import ObjCExceptionCatcher
import SwiftData

/// Single ModelContainer for all persistent data.
@MainActor
final class DataStore {
    private struct StoreUnavailableError: LocalizedError {
        var errorDescription: String? { "Persistence store is not ready" }
    }

    private struct BackgroundFetchResolutionError: LocalizedError {
        let expectedCount: Int
        let resolvedCount: Int

        var errorDescription: String? {
            "Background fetch resolved \(resolvedCount) of \(expectedCount) persisted models"
        }
    }

    private struct PersistenceObjectiveCException: LocalizedError, Sendable {
        let operation: String
        let name: String
        let reason: String?

        var errorDescription: String? {
            if let reason, !reason.isEmpty {
                return "Objective-C exception during \(operation): \(name) (\(reason))"
            }
            return "Objective-C exception during \(operation): \(name)"
        }
    }

    private(set) var container: ModelContainer?

    /// `true` after `setup()` completes successfully.
    private(set) var isReady = false

    /// Non-nil when setup failed — callers can surface this to the user.
    private(set) var setupError: Error?

    /// Tests inject an isolated URL so persistence behavior can be exercised
    /// without sharing the user's application-support store.
    private let storeURLOverride: URL?
    /// Test seam executed after obsolete rows are staged for deletion but
    /// before the transaction saves. Throwing proves rollback/retry behavior.
    private let obsoletePunctuationRetirementPreSaveHook: (() throws -> Void)?

    private(set) var obsoletePunctuationRetirementCompleted = false
    private(set) var retiredObsoletePunctuationRowCount = 0

    init(
        storeURLOverride: URL? = nil,
        obsoletePunctuationRetirementPreSaveHook: (() throws -> Void)? = nil
    ) {
        self.storeURLOverride = storeURLOverride
        self.obsoletePunctuationRetirementPreSaveHook = obsoletePunctuationRetirementPreSaveHook
    }

    private static let storeSchema = Schema([
        DictationEntry.self,
        MemoEntry.self,
        DictionaryWord.self,
        LearnedContextEntity.self,
        LearnedStyleProfile.self,
        LearnedFormatPreference.self,
        DictationCorrectionEvent.self,
        PersonalizationOutcome.self,
        JournalDay.self,
        MeetingEntry.self,
        AmbientContextSnapshot.self,
    ])

    nonisolated static func storeFamilyURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal"),
        ]
    }

    @discardableResult
    nonisolated static func quarantineCorruptStoreFamily(
        at storeURL: URL,
        fileManager: FileManager = .default,
        timestamp: Int = Int(Date().timeIntervalSince1970)
    ) -> URL? {
        let backupBaseURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("Resonant-corrupt-\(timestamp).store")

        var movedAnyFile = false
        for sourceURL in storeFamilyURLs(for: storeURL) {
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let suffix = String(sourceURL.path.dropFirst(storeURL.path.count))
            let destinationURL = URL(fileURLWithPath: backupBaseURL.path + suffix)
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                movedAnyFile = true
            } catch {
                continue
            }
        }

        return movedAnyFile ? backupBaseURL : nil
    }

    private nonisolated static func saveContext(
        _ context: ModelContext,
        operation: String
    ) throws {
        guard context.hasChanges else { return }

        var thrownError: Error?
        let exception = ObjCTryCatch {
            do {
                try context.save()
            } catch {
                thrownError = error
            }
        }

        if let thrownError {
            throw thrownError
        }

        guard let exception else { return }

        _ = ObjCTryCatch {
            context.rollback()
        }

        throw PersistenceObjectiveCException(
            operation: operation,
            name: exception.name.rawValue,
            reason: exception.reason
        )
    }

    private func reportPersistenceFailure(
        _ error: Error,
        breadcrumbMessage: String,
        logMessage: String,
        operation: String
    ) {
        let diagnosticContext: [String: Any]
        if let exception = error as? PersistenceObjectiveCException {
            diagnosticContext = [
                "operation": exception.operation,
                "exception_name": exception.name,
                "exception_reason": exception.reason ?? "",
            ]
            SentryManager.shared.captureException(error, context: diagnosticContext)
        } else {
            diagnosticContext = SentryManager.shared.diagnosticContext(
                for: error,
                extras: ["operation": operation]
            )
        }

        SentryManager.shared.addBreadcrumb(
            category: "persistence",
            message: breadcrumbMessage,
            level: .error,
            data: diagnosticContext
        )
        print("[DataStore] \(logMessage): \(error)")
    }

    func setup() async {
        guard !isReady else {
            if !obsoletePunctuationRetirementCompleted {
                retireObsoletePunctuationPreferences()
            }
            return
        }
        setupError = nil
        container = nil

        do {
            let config = ModelConfiguration(
                schema: Self.storeSchema,
                url: storeURL(),
                allowsSave: true
            )
            container = try ModelContainer(for: Self.storeSchema, configurations: config)
            isReady = true
            setupError = nil
            retireObsoletePunctuationPreferences()
        } catch {
            isReady = false
            container = nil
            SentryManager.shared.captureException(error, context: ["source": "DataStore.setup"])
            print("[DataStore] Failed to create container: \(error)")
            setupError = error

            // Attempt recovery: quarantine the main SQLite file plus WAL/SHM sidecars
            // before retrying with a fresh container.
            let store = storeURL()
            _ = Self.quarantineCorruptStoreFamily(at: store)

            do {
                let config = ModelConfiguration(
                    schema: Self.storeSchema,
                    url: storeURL(),
                    allowsSave: true
                )
                container = try ModelContainer(for: Self.storeSchema, configurations: config)
                isReady = true
                setupError = nil
                retireObsoletePunctuationPreferences()
                print("[DataStore] Recovery succeeded — created fresh store (old data backed up)")
            } catch {
                isReady = false
                container = nil
                SentryManager.shared.captureException(error, context: ["source": "DataStore.setup.recovery"])
                print("[DataStore] Recovery also failed: \(error)")
                setupError = error
            }
        }
    }

    /// Retires only the inert legacy global punctuation category. The delete
    /// and in-memory ModelContext reconciliation are one save transaction; a
    /// failure rolls back and leaves completion false so the next setup retries.
    /// Re-running after success is harmless because the predicate finds zero
    /// rows and still completes normally.
    private func retireObsoletePunctuationPreferences() {
        guard let context else { return }
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }

        do {
            let descriptor = FetchDescriptor<LearnedFormatPreference>(
                predicate: #Predicate { $0.categoryRaw == "punctuation" }
            )
            let obsoleteRows = try context.fetch(descriptor)
            obsoleteRows.forEach(context.delete)
            try obsoletePunctuationRetirementPreSaveHook?()
            try Self.saveContext(
                context,
                operation: "retire_obsolete_punctuation_preferences"
            )
            retiredObsoletePunctuationRowCount = obsoleteRows.count
            obsoletePunctuationRetirementCompleted = true
        } catch {
            context.rollback()
            retiredObsoletePunctuationRowCount = 0
            obsoletePunctuationRetirementCompleted = false
            reportPersistenceFailure(
                error,
                breadcrumbMessage: "obsolete_punctuation_retirement_failed",
                logMessage: "Obsolete punctuation retirement failed; will retry",
                operation: "retire_obsolete_punctuation_preferences"
            )
        }
    }

    var context: ModelContext? { container?.mainContext }

    // MARK: - Generic CRUD

    @discardableResult
    func save<T: PersistentModel>(_ model: T) async -> Bool {
        guard let ctx = context else { return false }
        ctx.insert(model)
        do {
            try Self.saveContext(ctx, operation: "main_context_insert_save")
            return true
        } catch {
            reportPersistenceFailure(
                error,
                breadcrumbMessage: "save_failed",
                logMessage: "Save failed after insert",
                operation: "main_context_insert_save"
            )
            return false
        }
    }

    @discardableResult
    func delete<T: PersistentModel>(_ model: T) async -> Bool {
        guard let ctx = context else { return false }
        ctx.delete(model)
        do {
            try Self.saveContext(ctx, operation: "main_context_delete_save")
            return true
        } catch {
            reportPersistenceFailure(
                error,
                breadcrumbMessage: "delete_failed",
                logMessage: "Save failed after delete",
                operation: "main_context_delete_save"
            )
            return false
        }
    }

    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        guard let ctx = context else { return [] }
        return (try? ctx.fetch(descriptor)) ?? []
    }

    /// Recovery must distinguish a confirmed absence from an unavailable or
    /// failed read; treating either error as `[]` can duplicate an entry whose
    /// transaction marker already carries a stable ID.
    func fetchForRecovery<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>
    ) throws -> [T] {
        guard let ctx = context else { throw StoreUnavailableError() }
        do {
            return try ctx.fetch(descriptor)
        } catch {
            reportPersistenceFailure(
                error,
                breadcrumbMessage: "recovery_fetch_failed",
                logMessage: "Recovery fetch failed",
                operation: "main_context_recovery_fetch"
            )
            throw error
        }
    }

    /// Fetch on a background context to avoid blocking the main thread.
    /// Returns persistent identifiers that can be resolved on the main context.
    func fetchInBackground<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>
    ) async -> [T] {
        guard let container else { return [] }
        let ids: [PersistentIdentifier] = await Task.detached {
            let bgContext = ModelContext(container)
            bgContext.autosaveEnabled = false
            return (try? bgContext.fetch(descriptor).map(\.persistentModelID)) ?? []
        }.value
        // Resolve on main context (cheap — models are already cached by SQLite)
        guard let ctx = context else { return [] }
        return ids.compactMap { ctx.model(for: $0) as? T }
    }

    func fetchInBackgroundChecked<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>
    ) async throws -> [T] {
        do {
            guard let container else { throw StoreUnavailableError() }
            let ids: [PersistentIdentifier] = try await Task.detached {
                let bgContext = ModelContext(container)
                bgContext.autosaveEnabled = false
                return try bgContext.fetch(descriptor).map(\.persistentModelID)
            }.value
            guard let ctx = context else { throw StoreUnavailableError() }
            let models = ids.compactMap { ctx.model(for: $0) as? T }
            guard models.count == ids.count else {
                throw BackgroundFetchResolutionError(
                    expectedCount: ids.count,
                    resolvedCount: models.count
                )
            }
            return models
        } catch {
            reportPersistenceFailure(
                error,
                breadcrumbMessage: "checked_background_fetch_failed",
                logMessage: "Checked background fetch failed",
                operation: "checked_background_fetch"
            )
            throw error
        }
    }

    /// Count rows on a background context without materializing models.
    func countInBackground<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>
    ) async -> Int {
        guard let container else { return 0 }
        return await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            bgContext.autosaveEnabled = false
            return (try? bgContext.fetchCount(descriptor)) ?? 0
        }.value
    }

    /// Fetch on a background context and map directly into Sendable snapshots.
    /// This avoids resolving SwiftData models on the main context just to serialize them.
    func fetchMappedInBackground<T: PersistentModel, Result: Sendable>(
        _ descriptor: FetchDescriptor<T>,
        map: @escaping @Sendable (T) -> Result
    ) async -> [Result] {
        guard let container else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            bgContext.autosaveEnabled = false
            let models = (try? bgContext.fetch(descriptor)) ?? []
            return models.map(map)
        }.value
    }

    /// Runs a write transaction on a background ModelContext and saves it before returning.
    /// The closure must only capture Sendable values.
    func performBackgroundWrite<Result: Sendable>(
        priority: TaskPriority = .utility,
        _ body: @escaping @Sendable (ModelContext) throws -> Result
    ) async -> Result? {
        guard let container else { return nil }

        do {
            return try await Task.detached(priority: priority) {
                let bgContext = ModelContext(container)
                bgContext.autosaveEnabled = false
                let result = try body(bgContext)
                try Self.saveContext(bgContext, operation: "background_write_save")
                return result
            }.value
        } catch {
            reportPersistenceFailure(
                error,
                breadcrumbMessage: "background_write_failed",
                logMessage: "performBackgroundWrite failed",
                operation: "background_write_save"
            )
            return nil
        }
    }

    @discardableResult
    func saveChanges() -> Bool {
        guard let ctx = context else { return false }
        do {
            try Self.saveContext(ctx, operation: "main_context_save_changes")
            return true
        } catch {
            reportPersistenceFailure(
                error,
                breadcrumbMessage: "save_changes_failed",
                logMessage: "saveChanges failed",
                operation: "main_context_save_changes"
            )
            return false
        }
    }

    func dictationEntry(id: UUID) -> DictationEntry? {
        let descriptor = FetchDescriptor<DictationEntry>(
            predicate: #Predicate { $0.id == id }
        )
        return fetch(descriptor).first
    }

    func memoEntry(id: UUID) -> MemoEntry? {
        let descriptor = FetchDescriptor<MemoEntry>(
            predicate: #Predicate { $0.id == id }
        )
        return fetch(descriptor).first
    }

    func meetingEntry(id: UUID) -> MeetingEntry? {
        let descriptor = FetchDescriptor<MeetingEntry>(
            predicate: #Predicate { $0.id == id }
        )
        return fetch(descriptor).first
    }

    func ambientSnapshot(id: UUID) -> AmbientContextSnapshot? {
        let descriptor = FetchDescriptor<AmbientContextSnapshot>(
            predicate: #Predicate { $0.id == id }
        )
        return fetch(descriptor).first
    }

    func journalDay(on date: Date) -> JournalDay? {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        var descriptor = FetchDescriptor<JournalDay>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        descriptor.fetchLimit = 1
        return fetch(descriptor).first
    }

    func recentDictationTexts(bundleId: String?, appName: String?, limit: Int = 5) -> [String] {
        var descriptor = FetchDescriptor<DictationEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = max(limit * 4, limit)

        let entries = fetch(descriptor)
        let normalizedBundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAppName = appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var results: [String] = []
        var seen = Set<String>()

        for entry in entries {
            let entryBundleId = entry.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let entryAppName = entry.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            let matchesContext = if let normalizedBundleId, !normalizedBundleId.isEmpty {
                entryBundleId == normalizedBundleId
            } else if let normalizedAppName, !normalizedAppName.isEmpty {
                entryAppName == normalizedAppName
            } else {
                true
            }

            guard matchesContext else { continue }

            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard seen.insert(text).inserted else { continue }

            results.append(text)
            if results.count >= limit {
                break
            }
        }

        return results
    }

    // MARK: - Retention cleanup

    @discardableResult
    func purgeOldEntries(olderThan days: Int) async -> [UUID] {
        guard let container, days > 0, days < 36500 else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        do {
            return try await Task.detached(priority: .utility) {
                let ctx = ModelContext(container)
                ctx.autosaveEnabled = false
                var purgedMemoAudioPaths: [String] = []
                var purgedMeetingIDs: [UUID] = []

                let dictDescriptor = FetchDescriptor<DictationEntry>(
                    predicate: #Predicate { $0.date < cutoff }
                )
                for entry in (try? ctx.fetch(dictDescriptor)) ?? [] {
                    ctx.delete(entry)
                }

                let memoDescriptor = FetchDescriptor<MemoEntry>(
                    predicate: #Predicate { $0.date < cutoff }
                )
                for memo in (try? ctx.fetch(memoDescriptor)) ?? [] {
                    if let audioPath = memo.audioPath {
                        purgedMemoAudioPaths.append(audioPath)
                    }
                    ctx.delete(memo)
                }

                let ambientDescriptor = FetchDescriptor<AmbientContextSnapshot>(
                    predicate: #Predicate { $0.timestamp < cutoff }
                )
                for entry in (try? ctx.fetch(ambientDescriptor)) ?? [] {
                    ctx.delete(entry)
                }

                let journalDescriptor = FetchDescriptor<JournalDay>(
                    predicate: #Predicate { $0.date < cutoff }
                )
                for journal in (try? ctx.fetch(journalDescriptor)) ?? [] {
                    ctx.delete(journal)
                }

                let correctionEventDescriptor = FetchDescriptor<DictationCorrectionEvent>(
                    predicate: #Predicate { $0.timestamp < cutoff }
                )
                for event in (try? ctx.fetch(correctionEventDescriptor)) ?? [] {
                    ctx.delete(event)
                }

                let personalizationOutcomeDescriptor = FetchDescriptor<PersonalizationOutcome>(
                    predicate: #Predicate { $0.createdAt < cutoff }
                )
                for outcome in (try? ctx.fetch(personalizationOutcomeDescriptor)) ?? [] {
                    ctx.delete(outcome)
                }

                let meetingDescriptor = FetchDescriptor<MeetingEntry>(
                    predicate: #Predicate { $0.startedAt < cutoff }
                )
                for entry in (try? ctx.fetch(meetingDescriptor)) ?? [] {
                    purgedMeetingIDs.append(entry.id)
                    Self.removeMeetingFiles(
                        markdownPath: entry.markdownPath,
                        audioPath: entry.audioPath,
                        activeJSONLPath: entry.activeJSONLPath
                    )
                    ctx.delete(entry)
                }

                try Self.saveContext(ctx, operation: "purge_old_entries_save")
                for audioPath in purgedMemoAudioPaths {
                    Self.removeAppSupportFile(path: audioPath)
                }
                return purgedMeetingIDs
            }.value
        } catch {
            reportPersistenceFailure(
                error,
                breadcrumbMessage: "purge_old_entries_failed",
                logMessage: "purgeOldEntries save failed",
                operation: "purge_old_entries_save"
            )
            return []
        }
    }

    /// Delete meeting entries with zero duration and zero words, along with their files.
    /// Returns the IDs of deleted meetings so callers can clean up related state (e.g. feed).
    func purgeEmptyMeetings() async -> [UUID] {
        guard let ctx = context else { return [] }
        let allEmpty = FetchDescriptor<MeetingEntry>(
            predicate: #Predicate { $0.durationSeconds == 0 && $0.wordCount == 0 }
        )
        let empty = ((try? ctx.fetch(allEmpty)) ?? [])
            .filter { $0.activeJSONLPath == nil }
        let ids = empty.map(\.id)
        let root = AppSupportPaths.resonantRoot()
        for meeting in empty {
            if let path = meeting.markdownPath {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
            }
            if let path = meeting.audioPath {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
            }
            ctx.delete(meeting)
        }
        if !empty.isEmpty {
            do {
                try Self.saveContext(ctx, operation: "purge_empty_meetings_save")
            } catch {
                reportPersistenceFailure(
                    error,
                    breadcrumbMessage: "purge_empty_meetings_failed",
                    logMessage: "purgeEmptyMeetings save failed",
                    operation: "purge_empty_meetings_save"
                )
            }
            print("[DataStore] Purged \(empty.count) empty meeting(s)")
        }
        return ids
    }

    @discardableResult
    func clearWorkspaceData() async -> Bool {
        guard let ctx = context else { return false }

        do {
            let dictations = try ctx.fetch(FetchDescriptor<DictationEntry>())
            let memos = try ctx.fetch(FetchDescriptor<MemoEntry>())
            let journals = try ctx.fetch(FetchDescriptor<JournalDay>())
            let dictionaryWords = try ctx.fetch(FetchDescriptor<DictionaryWord>())
            let snapshots = try ctx.fetch(FetchDescriptor<AmbientContextSnapshot>())
            let entities = try ctx.fetch(FetchDescriptor<LearnedContextEntity>())
            let profiles = try ctx.fetch(FetchDescriptor<LearnedStyleProfile>())
            let formatPreferences = try ctx.fetch(FetchDescriptor<LearnedFormatPreference>())
            let events = try ctx.fetch(FetchDescriptor<DictationCorrectionEvent>())
            let personalizationOutcomes = try ctx.fetch(FetchDescriptor<PersonalizationOutcome>())
            let meetings = try ctx.fetch(FetchDescriptor<MeetingEntry>())
            let root = AppSupportPaths.resonantRoot()
            let meetingFiles = meetings.flatMap { meeting -> [URL] in
                [meeting.markdownPath, meeting.audioPath, meeting.activeJSONLPath].compactMap { path in
                    path.map { root.appendingPathComponent($0) }
                }
            }

            dictations.forEach(ctx.delete)
            memos.forEach(ctx.delete)
            journals.forEach(ctx.delete)
            dictionaryWords.forEach(ctx.delete)
            snapshots.forEach(ctx.delete)
            entities.forEach(ctx.delete)
            profiles.forEach(ctx.delete)
            formatPreferences.forEach(ctx.delete)
            events.forEach(ctx.delete)
            personalizationOutcomes.forEach(ctx.delete)
            meetings.forEach(ctx.delete)

            try Self.saveContext(ctx, operation: "clear_workspace_data_save")
            for file in meetingFiles {
                try? FileManager.default.removeItem(at: file)
            }
            return true
        } catch {
            ctx.rollback()
            reportPersistenceFailure(
                error,
                breadcrumbMessage: "clear_workspace_data_failed",
                logMessage: "clearWorkspaceData save failed",
                operation: "clear_workspace_data_save"
            )
            return false
        }
    }

    func clearAmbientSnapshots() async {
        guard let ctx = context else { return }
        let descriptor = FetchDescriptor<AmbientContextSnapshot>()
        for entry in (try? ctx.fetch(descriptor)) ?? [] {
            ctx.delete(entry)
        }
        do {
            try Self.saveContext(ctx, operation: "clear_ambient_snapshots_save")
        } catch {
            reportPersistenceFailure(
                error,
                breadcrumbMessage: "clear_ambient_snapshots_failed",
                logMessage: "clearAmbientSnapshots save failed",
                operation: "clear_ambient_snapshots_save"
            )
        }
    }

    // MARK: - Path

    private func storeURL() -> URL {
        if let storeURLOverride { return storeURLOverride }
        return AppSupportPaths.resonantRoot().appendingPathComponent("Resonant.store")
    }

    private func removeMeetingFiles(for meeting: MeetingEntry) {
        Self.removeMeetingFiles(
            markdownPath: meeting.markdownPath,
            audioPath: meeting.audioPath,
            activeJSONLPath: meeting.activeJSONLPath
        )
    }

    private nonisolated static func removeMeetingFiles(
        markdownPath: String?,
        audioPath: String?,
        activeJSONLPath: String?
    ) {
        let root = AppSupportPaths.resonantRoot()
        for relativePath in [markdownPath, audioPath, activeJSONLPath] {
            guard let relativePath else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))
        }
    }

    private nonisolated static func removeAppSupportFile(path: String?) {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return }
        let url: URL
        if path.hasPrefix("file://"), let fileURL = URL(string: path), fileURL.isFileURL {
            url = fileURL
        } else if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = AppSupportPaths.resonantRoot().appendingPathComponent(path)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
