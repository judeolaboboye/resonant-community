import AppKit
import Defaults
import Foundation
import os
import SwiftData

private final class WorkspaceExportFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func beginExport() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func commit<T>(generation expected: UInt64, _ operation: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { return nil }
        return operation()
    }

    func isCurrent(_ expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expected
    }
}

@MainActor
final class WorkspaceSyncEngine {
    private struct TrackedTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct ExportWriteResult: Sendable {
        let modificationDate: Date?
        let byteCount: Int
        let didWrite: Bool
        let succeeded: Bool
    }

    private struct ExportSettingsSnapshot: Sendable {
        let onboardingCompleted: Bool
        let triggerKey: String
        let triggerKeys: [String]
        let hotkeyMode: String
        let selectedModelId: String
        let removeFillersEnabled: Bool
        let removeFalseStartsEnabled: Bool
        let itnEnabled: Bool
        let autoPunctuationEnabled: Bool
        let bulletPointsEnabled: Bool
        let cloudProcessingEnabled: Bool
        let selectionTransformEnabled: Bool
        let journalSummarizationEnabled: Bool
        let autoPasteEnabled: Bool
        let copyToClipboardEnabled: Bool
        let autoSendEnabled: Bool
        let emailSignatureEnabled: Bool
        let emailSignoffName: String?
        let soundsEnabled: Bool
        let soundsVolume: Double
        let hotMicEnabled: Bool
        let pauseMediaWhileRecording: Bool
        let duckSystemAudioWhileRecording: Bool
        let hotWord: String
        let lowLatencyMode: Bool
        let meetingSummarizationEnabled: Bool
        let meetingRecordingEnabled: Bool
        let meetingJoinPromptEnabled: Bool
        let meetingAutoStartEnabled: Bool
        let meetingAutoStopEnabled: Bool
        let meetingUseCalendarHints: Bool
        let meetingSaveAudio: Bool
        let saveAudioEnabled: Bool
        let contextMetadataEnabled: Bool
        let historyRetentionDays: Int
        let hipaaMode: Bool
        let launchAtLogin: Bool
        let crashDiagnosticsEnabled: Bool
        let overlayMode: String
        let analyticsEnabled: Bool
        let inputDeviceUID: String?
        let pinnedDisplayId: Int?
        let userId: String?
        let userEmail: String?
        let userDisplayName: String?
        var smartLinks: [SmartLink]
        var dictionaryWords: [DictionaryStore.WorkspaceWord]
    }

    private struct ExistingDictationSnapshot: Sendable {
        let id: UUID
        var externalID: String?
        let text: String
        let bundleId: String
        let duration: TimeInterval
        let date: Date
    }

    private struct ExistingMemoSnapshot: Sendable {
        let id: UUID
        var externalID: String?
        let text: String
        let duration: TimeInterval
        let date: Date
        var audioPath: String?
        var distilledText: String?
    }

    private struct AmbientImportCandidate: Sendable {
        let event: AmbientStreamEvent
        let id: UUID
        let timestamp: Date
        let notificationReceivedAt: Date?
    }

    private struct ImportTimestampParser {
        private let fractionalFormatter = WorkspaceSyncEngine.makeImportTimestampFormatter(withFractionalSeconds: true)
        private let standardFormatter = WorkspaceSyncEngine.makeImportTimestampFormatter(withFractionalSeconds: false)

        func parse(_ value: String?) -> Date? {
            guard let value = value?.nilIfEmpty else { return nil }
            return WorkspaceSyncEngine.parseTimestamp(
                value,
                fractionalFormatter: fractionalFormatter,
                standardFormatter: standardFormatter
            )
        }
    }

    private enum Constants {
        static let pollInterval: Duration = .seconds(5)
        static let dictationExternalPrefix = "workspace-dictation:"
        static let memoExternalPrefix = "workspace-memo:"
        static let workspaceAudioDirectories = [
            "audio",
            "memos",
            "recordings",
            "stream/audio",
            "voice-notes",
            "voiceNotes",
            "memo-audio",
            "voice-notes/audio",
            "voiceNotes/audio",
        ]
        static let workspaceHistoryDirectories = [
            "stream/ambient",
        ]
        static let voiceNoteAudioKeys = [
            "audioPath",
            "audioRelativePath",
            "audioFileName",
            "audioFilename",
            "audioFile",
            "audioURL",
            "audioUrl",
            "audioUri",
            "audioURI",
            "fileName",
            "filename",
        ]
        static let supportedAudioExtensions: Set<String> = [
            "aac",
            "aif",
            "aiff",
            "caf",
            "m4a",
            "mp3",
            "wav",
        ]
        static let ignoredWorkspaceSearchDirectories: Set<String> = [
            "cache",
            "code cache",
            "crashpad",
            "dawngraphitecache",
            "dawnwebgpucache",
            "gpucache",
            "local storage",
            "models",
            "native-notch",
            "session storage",
            "shared dictionary",
            "sounds",
            "sentry",
        ]
        static let legacyHotWordKeys = [
            "hotWord",
            "hotMicWakePhrase",
        ]
        static let legacyAuthTokenKeys = [
            "authToken",
            "clawAuthToken",
        ]
    }

    private let dataStore: DataStore
    private let settingsManager: SettingsManager
    private let smartLinkStore: SmartLinkStore
    private let dictionaryStore: DictionaryStore
    private let memoManager: MemoManager
    private let feedManager: FeedManager
    private let journalManager: JournalManager
    private let archiveWriter: ArchiveWriter
    private let convexClient: ConvexClient

    private var startupTask: TrackedTask?
    private var syncTask: Task<Void, Never>?
    private var trackedModificationDates: [URL: Date] = [:]
    private var appNameCache: [String: String] = [:]
    private var exportDirty = true
    private var suppressContinuousRoamingSettingsImport = false
    private var lastFullExportDate: Date = .distantPast
    private var isCloudUploadInFlight = false
    private var isWorkspaceClearPrepared = false
    private let exportFence = WorkspaceExportFence()
    private nonisolated static let diagnosticsLog = Logger(
        subsystem: "com.resonance.resonant",
        category: "workspace.sync"
    )
    private nonisolated static let exportSignposter = OSSignposter(
        subsystem: "com.resonance.resonant",
        category: "workspace.sync"
    )
    // Dirty exports still flush on the 5s sync loop. This is only a fallback
    // full export for missed dirty marks, so keep it infrequent: full SwiftData
    // exports can materialize large histories and previously showed up as
    // recurring SQLite temp-file disk-write diagnostics.
    private static let exportThrottleInterval: TimeInterval = 30 * 60
    private static let ambientImportBatchSize = 500

    var onCloudUploadStateChange: ((WorkspaceCloudUploadState) -> Void)?

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        smartLinkStore: SmartLinkStore,
        dictionaryStore: DictionaryStore,
        memoManager: MemoManager,
        feedManager: FeedManager,
        journalManager: JournalManager,
        archiveWriter: ArchiveWriter,
        convexClient: ConvexClient
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.smartLinkStore = smartLinkStore
        self.dictionaryStore = dictionaryStore
        self.memoManager = memoManager
        self.feedManager = feedManager
        self.journalManager = journalManager
        self.archiveWriter = archiveWriter
        self.convexClient = convexClient
    }

    func start() async {
        guard !isWorkspaceClearPrepared else { return }
        if let startupTask {
            await startupTask.task.value
            return
        }
        guard syncTask == nil else { return }

        let startupID = UUID()
        let task = Task { [weak self] in
            await self?.syncIfNeeded(force: true)
            await self?.exportIfNeeded(force: true)
        }
        startupTask = TrackedTask(id: startupID, task: task)
        await task.value

        // stop/stopAndWait removes this exact task before awaiting it. Never
        // install the polling loop if a clear boundary retired the startup.
        guard startupTask?.id == startupID, !isWorkspaceClearPrepared else { return }
        startupTask = nil
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Constants.pollInterval)
                guard !Task.isCancelled else { break }
                await self?.syncIfNeeded(force: false)
                await self?.exportIfNeeded(force: false)
            }
        }
    }

    func stop() {
        startupTask?.task.cancel()
        startupTask = nil
        syncTask?.cancel()
        syncTask = nil
        exportFence.invalidate()
    }

    func stopAndWait() async {
        let startup = startupTask
        let polling = syncTask
        startup?.task.cancel()
        polling?.cancel()
        startupTask = nil
        syncTask = nil
        exportFence.invalidate()
        await startup?.task.value
        await polling?.value
    }

    /// Signal that settings or data changed and should be written to the workspace file.
    func markExportNeeded(roamingSettingsChanged: Bool = false) {
        exportDirty = true
        if roamingSettingsChanged {
            suppressContinuousRoamingSettingsImport = true
        }
    }

    func flushPendingExport() async {
        await exportIfNeeded(force: true)
    }

    func uploadWorkspaceTextToCloud(enableBackgroundSync: Bool) async {
        guard AppFeatureVisibility.cloudSync else {
            settingsManager.workspaceCloudUploadEnabled = false
            onCloudUploadStateChange?(.idle(lastSyncedAt: Defaults[.workspaceCloudTextLastSyncedAt]))
            return
        }
        if enableBackgroundSync {
            settingsManager.workspaceCloudUploadEnabled = true
        }
        await exportIfNeeded(force: true, syncCloudTextOverride: true)
    }

    func clearWorkspaceData() async {
        guard await prepareForWorkspaceClear() else { return }
        await finishWorkspaceClear()
    }

    /// Establishes a monotonic clear boundary. Import mirrors disappear before
    /// SwiftData is touched, so a crash cannot resurrect cleared history on the
    /// next launch.
    @discardableResult
    func prepareForWorkspaceClear() async -> Bool {
        isWorkspaceClearPrepared = true
        await stopAndWait()
        trackedModificationDates.removeAll()
        let directories = Self.workspaceSupportDirectories()
        let removedImportMirrors = await Task.detached(priority: .utility) {
            Self.removeWorkspaceImportMirrorsOffMain(directories: directories)
        }.value

        exportDirty = true
        lastFullExportDate = .distantPast
        return removedImportMirrors
    }

    /// Rebuilds the workspace mirror from the already-cleared local stores.
    func finishWorkspaceClear() async {
        isWorkspaceClearPrepared = false
        exportDirty = true
        lastFullExportDate = .distantPast
        await exportIfNeeded(force: true)
    }

    /// Restores mirrors from the still-authoritative stores when a later clear
    /// stage fails after import mirrors were removed.
    func abortWorkspaceClear() async {
        await finishWorkspaceClear()
    }

    private func syncIfNeeded(force: Bool) async {
        guard !isWorkspaceClearPrepared else { return }
        let currentTrackedDates = trackedModificationDates

        // Perform all file I/O off the main thread.
        let io = await Task.detached(priority: .utility) {
            () -> (modDates: [URL: Date], snapshotJSON: [String: Any]?, ambientHistory: [AmbientStreamEvent], syncState: SyncState, stateFileURL: URL?)? in

            let directories = Self.workspaceSupportDirectories()
            let stateFileURL = directories.first?.appendingPathComponent("workspace-sync-state.json")
            let files = Self.workspaceFilesOffMain(directories: directories)
            var newModDates: [URL: Date] = [:]
            var changed = force
            for file in files {
                let modDate = Self.modificationDateOffMain(for: file) ?? .distantPast
                newModDates[file] = modDate
                if currentTrackedDates[file] != modDate { changed = true }
            }
            for key in currentTrackedDates.keys where newModDates[key] == nil {
                changed = true
            }
            guard changed else { return nil }

            var snapshotJSON: [String: Any]?
            for dir in directories {
                let fileURL = dir.appendingPathComponent("settings.json")
                if let json = Self.loadRawWorkspaceJSONOffMain(at: fileURL) {
                    snapshotJSON = json
                    break
                }
            }

            let syncState = Self.loadSyncStateOffMain(at: stateFileURL)
            let ambientHistory = Self.loadAmbientHistoryOffMain(directories: directories)
            return (newModDates, snapshotJSON, ambientHistory, syncState, stateFileURL)
        }.value

        guard let io else { return }
        trackedModificationDates = io.modDates

        guard io.snapshotJSON != nil || !io.ambientHistory.isEmpty else { return }
        let snapshot = io.snapshotJSON.map(parseWorkspaceSnapshot) ?? .empty
        if io.snapshotJSON != nil {
            await syncSettings(from: snapshot)
            mergeStats(from: snapshot.stats, dailyWordCounts: snapshot.dailyWordCounts)
        }

        var syncState = io.syncState
        let dictationResult = await syncDictationHistory(from: snapshot.dictationHistory, syncState: &syncState)
        let memoResult = await syncVoiceNotes(from: snapshot.voiceNotes, syncState: &syncState)
        let meetingResult = await syncMeetingHistory(from: snapshot.meetingHistory)
        let ambientResult = await syncAmbientHistory(from: io.ambientHistory)
        if dictationResult.hadFailure || memoResult.hadFailure || meetingResult.hadFailure || ambientResult.hadFailure {
            trackedModificationDates = currentTrackedDates
        }

        // Persist sync state off main if anything changed.
        if dictationResult.syncStateChanged || memoResult.syncStateChanged, let url = io.stateFileURL {
            let stateToSave = syncState
            await Task.detached(priority: .utility) {
                Self.saveSyncStateOffMain(stateToSave, to: url)
            }.value
        }

        if dictationResult.didChange || memoResult.didChange || meetingResult.didChange || ambientResult.didChange {
            exportDirty = true
            await memoManager.load(from: dataStore)
            await feedManager.reload()

            for day in dictationResult.importedDays.sorted() {
                guard await journalManager.hasJournal(on: day) else { continue }
                _ = await journalManager.generate(for: day)
            }
            await journalManager.reload()
        }
    }

    private func exportIfNeeded(force: Bool, syncCloudTextOverride: Bool = false) async {
        guard !isWorkspaceClearPrepared else { return }
        guard let fileURL = Self.workspaceSettingsFileURL() else { return }

        // Skip expensive data collection when nothing has changed.
        let now = Date()
        let wasDirty = exportDirty
        let needsPeriodicExport = now.timeIntervalSince(lastFullExportDate) >= Self.exportThrottleInterval
        guard force || exportDirty || needsPeriodicExport else { return }
        let exportGeneration = exportFence.beginExport()
        let exportReason = Self.exportReason(force: force, dirty: wasDirty, periodic: needsPeriodicExport)
        let exportStartedAt = ContinuousClock.now
        let exportSignpostID = Self.exportSignposter.makeSignpostID()
        Self.exportSignposter.emitEvent("workspace.export.start", id: exportSignpostID)
        let shouldSyncCloudText = Self.shouldSyncCloudText(
            permissionGranted: AppFeatureVisibility.cloudSync && settingsManager.workspaceCloudUploadEnabled,
            override: syncCloudTextOverride,
            exportDirty: exportDirty,
            lastSyncedAt: Defaults[.workspaceCloudTextLastSyncedAt]
        )
        exportDirty = false
        lastFullExportDate = now

        // Fetch and serialize entries entirely off the main thread so SwiftData
        // property faults and JSON serialization don't block the UI.
        async let dictationDataTask = exportedDictationData()
        async let voiceNotesTask = exportedMemoData()
        async let meetingHistoryTask = exportedMeetingData()
        let smartLinks = smartLinkStore.links
        let dictionaryWords = dictionaryStore.workspaceSnapshot()
        async let settingsSnapshotTask = Task.detached(priority: .utility) {
            Self.exportSettingsSnapshot()
        }.value
        let collectStartedAt = ContinuousClock.now
        var (dictationData, voiceNotes, meetingHistory, settingsSnapshot) = await (
            dictationDataTask,
            voiceNotesTask,
            meetingHistoryTask,
            settingsSnapshotTask
        )
        let collectMilliseconds = DiagnosticTiming.milliseconds(from: collectStartedAt)
        settingsSnapshot.smartLinks = smartLinks
        settingsSnapshot.dictionaryWords = dictionaryWords
        let settingsJSON = Self.workspaceSettingsJSON(
            from: settingsSnapshot,
            dictationHistory: dictationData.history,
            voiceNotes: voiceNotes,
            meetingHistory: meetingHistory
        )

        let parentDir = fileURL.deletingLastPathComponent()
        let standardizedURL = fileURL.standardizedFileURL

        let writeStartedAt = ContinuousClock.now
        let writeResult: ExportWriteResult? = await Task.detached(priority: .utility) { [exportFence] in
            var json = Self.loadRawWorkspaceJSONOffMain(at: fileURL) ?? [:]
            for (key, value) in settingsJSON {
                json[key] = value
            }

            // Compute stats off the main actor — UserDefaults reads can block.
            let dailyWordCounts = dictationData.dailyWordCounts
            json["dailyWordCounts"] = dailyWordCounts
            json["stats"] = Self.exportStats(dailyWordCounts: dailyWordCounts)

            guard let exportedData = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            ) else {
                return ExportWriteResult(
                    modificationDate: nil,
                    byteCount: 0,
                    didWrite: false,
                    succeeded: false
                )
            }
            let byteCount = exportedData.count

            let currentData = try? Data(contentsOf: fileURL)
            guard force || currentData != exportedData else {
                return ExportWriteResult(
                    modificationDate: Self.modificationDateOffMain(for: standardizedURL),
                    byteCount: byteCount,
                    didWrite: false,
                    succeeded: true
                )
            }

            let stagedURL = parentDir.appendingPathComponent(
                ".settings-\(UUID().uuidString).tmp"
            )
            do {
                try FileManager.default.createDirectory(
                    at: parentDir,
                    withIntermediateDirectories: true
                )
                try exportedData.write(to: stagedURL, options: [.atomic])
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                return ExportWriteResult(
                    modificationDate: nil,
                    byteCount: byteCount,
                    didWrite: false,
                    succeeded: false
                )
            }

            // Only the same-directory atomic replacement is serialized. Large
            // JSON reads/serialization/staging never hold a lock that the
            // MainActor's stop/clear path may need.
            let didCommit = exportFence.commit(generation: exportGeneration) {
                do {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        _ = try FileManager.default.replaceItemAt(
                            fileURL,
                            withItemAt: stagedURL
                        )
                    } else {
                        try FileManager.default.moveItem(at: stagedURL, to: fileURL)
                    }
                    return true
                } catch {
                    return false
                }
            }
            guard didCommit == true else {
                try? FileManager.default.removeItem(at: stagedURL)
                return didCommit == nil ? nil : ExportWriteResult(
                    modificationDate: nil,
                    byteCount: byteCount,
                    didWrite: false,
                    succeeded: false
                )
            }

            return ExportWriteResult(
                modificationDate: Self.modificationDateOffMain(for: standardizedURL),
                byteCount: byteCount,
                didWrite: true,
                succeeded: true
            )
        }.value
        guard let writeResult, exportFence.isCurrent(exportGeneration) else { return }
        let writeMilliseconds = DiagnosticTiming.milliseconds(from: writeStartedAt)

        guard writeResult.succeeded else {
            exportDirty = true
            lastFullExportDate = .distantPast
            Self.logWorkspaceExport(
                reason: exportReason,
                dictationCount: dictationData.history.count,
                voiceNoteCount: voiceNotes.count,
                meetingCount: meetingHistory.count,
                byteCount: writeResult.byteCount,
                didWrite: false,
                shouldSyncCloudText: false,
                collectMilliseconds: collectMilliseconds,
                writeMilliseconds: writeMilliseconds,
                totalMilliseconds: DiagnosticTiming.milliseconds(from: exportStartedAt)
            )
            Self.exportSignposter.emitEvent("workspace.export.finish", id: exportSignpostID)
            return
        }

        trackedModificationDates[standardizedURL] = writeResult.modificationDate ?? .distantPast
        suppressContinuousRoamingSettingsImport = false

        Self.logWorkspaceExport(
            reason: exportReason,
            dictationCount: dictationData.history.count,
            voiceNoteCount: voiceNotes.count,
            meetingCount: meetingHistory.count,
            byteCount: writeResult.byteCount,
            didWrite: writeResult.didWrite,
            shouldSyncCloudText: shouldSyncCloudText,
            collectMilliseconds: collectMilliseconds,
            writeMilliseconds: writeMilliseconds,
            totalMilliseconds: DiagnosticTiming.milliseconds(from: exportStartedAt)
        )
        Self.exportSignposter.emitEvent("workspace.export.finish", id: exportSignpostID)

        await syncCloudTextIfNeeded(
            shouldSync: shouldSyncCloudText,
            dictations: dictationData.history,
            voiceNotes: voiceNotes,
            meetings: meetingHistory,
            smartLinks: smartLinks,
            dictionaryWords: dictionaryWords
        )
    }

    private func syncCloudTextIfNeeded(
        shouldSync: Bool,
        dictations: [[String: Any]],
        voiceNotes: [[String: Any]],
        meetings: [[String: Any]],
        smartLinks: [SmartLink],
        dictionaryWords: [DictionaryStore.WorkspaceWord]
    ) async {
        guard AppFeatureVisibility.cloudSync else {
            settingsManager.workspaceCloudUploadEnabled = false
            onCloudUploadStateChange?(.idle(lastSyncedAt: Defaults[.workspaceCloudTextLastSyncedAt]))
            return
        }
        guard shouldSync else { return }
        guard settingsManager.workspaceCloudUploadEnabled else {
            onCloudUploadStateChange?(.idle(lastSyncedAt: Defaults[.workspaceCloudTextLastSyncedAt]))
            return
        }
        guard !isCloudUploadInFlight else { return }

        isCloudUploadInFlight = true
        onCloudUploadStateChange?(.preparing)
        let result = await convexClient.syncWorkspaceTextBatch(
            dictations: dictations,
            voiceNotes: voiceNotes,
            meetings: meetings,
            smartLinks: smartLinks,
            dictionaryWords: dictionaryWords,
            progress: { [weak self] completed, total in
                self?.onCloudUploadStateChange?(.uploading(completed: completed, total: total))
            }
        )
        isCloudUploadInFlight = false

        switch result {
        case .success(let syncResult):
            let syncedAt = Date()
            Defaults[.workspaceCloudTextLastSyncedAt] = syncedAt
            onCloudUploadStateChange?(.succeeded(
                inserted: syncResult.inserted,
                updated: syncResult.updated,
                syncedAt: syncedAt
            ))
        case .failure(let error):
            onCloudUploadStateChange?(.failed(error.localizedDescription))
        }
    }

    static func shouldSyncCloudText(
        permissionGranted: Bool,
        override: Bool,
        exportDirty: Bool,
        lastSyncedAt: Date?
    ) -> Bool {
        guard AppFeatureVisibility.cloudSync else { return false }
        guard permissionGranted else { return false }
        return override || exportDirty || lastSyncedAt == nil
    }

    private nonisolated static func exportReason(force: Bool, dirty: Bool, periodic: Bool) -> String {
        if force { return "force" }
        if dirty { return "dirty" }
        if periodic { return "periodic" }
        return "unknown"
    }

    private nonisolated static func logWorkspaceExport(
        reason: String,
        dictationCount: Int,
        voiceNoteCount: Int,
        meetingCount: Int,
        byteCount: Int,
        didWrite: Bool,
        shouldSyncCloudText: Bool,
        collectMilliseconds: Int64,
        writeMilliseconds: Int64,
        totalMilliseconds: Int64
    ) {
        let line = "reason=\(reason) dictations=\(dictationCount) voiceNotes=\(voiceNoteCount) meetings=\(meetingCount) bytes=\(byteCount) wrote=\(didWrite) cloudSync=\(shouldSyncCloudText) collect=\(collectMilliseconds)ms write=\(writeMilliseconds)ms total=\(totalMilliseconds)ms"
        diagnosticsLog.info("workspace.export \(line, privacy: .public)")
        NSLog("[WorkspaceSync] export %@", line)
    }

    private nonisolated static func logWorkspaceCollection(
        kind: String,
        count: Int,
        milliseconds: Int64
    ) {
        let line = "\(kind) count=\(count) total=\(milliseconds)ms"
        diagnosticsLog.info("workspace.collect \(line, privacy: .public)")
        NSLog("[WorkspaceSync] collect %@", line)
    }

    private nonisolated static func modificationDateOffMain(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private nonisolated static func loadRawWorkspaceJSONOffMain(at fileURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return jsonObject
    }

    private nonisolated static func loadAmbientHistoryOffMain(directories: [URL]) -> [AmbientStreamEvent] {
        let decoder = JSONDecoder()
        let fm = FileManager.default
        let fractionalFormatter = makeImportTimestampFormatter(withFractionalSeconds: true)
        let standardFormatter = makeImportTimestampFormatter(withFractionalSeconds: false)
        var eventsByID: [String: AmbientStreamEvent] = [:]

        for directory in directories {
            let ambientDirectory = directory.appendingPathComponent("stream/ambient", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(
                at: ambientDirectory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else {
                continue
            }

            for fileURL in files where fileURL.pathExtension == "jsonl" {
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                for line in data.split(separator: 0x0A) {
                    guard let event = try? decoder.decode(AmbientStreamEvent.self, from: Data(line)) else { continue }
                    eventsByID[event.id] = event
                }
            }
        }

        return eventsByID.values
            .map { event in
                (
                    event: event,
                    date: parseTimestamp(
                        event.timestamp,
                        fractionalFormatter: fractionalFormatter,
                        standardFormatter: standardFormatter
                    ) ?? .distantPast
                )
            }
            .sorted { lhs, rhs in lhs.date < rhs.date }
            .map(\.event)
    }

    private nonisolated static func workspaceFilesOffMain(directories: [URL]) -> [URL] {
        let fm = FileManager.default
        let audioDirectoryNames = Constants.workspaceAudioDirectories
        let historyDirectoryNames = Constants.workspaceHistoryDirectories
        var seen: Set<String> = []
        var candidates = directories.flatMap { directory in
            [directory.appendingPathComponent("settings.json")]
                + audioDirectoryNames.map { directory.appendingPathComponent($0, isDirectory: true) }
                + historyDirectoryNames.map { directory.appendingPathComponent($0, isDirectory: true) }
        }

        for directory in directories {
            for historyDirectoryName in historyDirectoryNames {
                let historyDirectory = directory.appendingPathComponent(historyDirectoryName, isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(
                    at: historyDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: .skipsHiddenFiles
                ) else {
                    continue
                }
                candidates.append(contentsOf: files)
            }
        }

        return candidates
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path.lowercased()).inserted }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    private nonisolated static func loadSyncStateOffMain(at fileURL: URL?) -> SyncState {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else {
            return SyncState()
        }
        return state
    }

    private nonisolated static func saveSyncStateOffMain(_ state: SyncState, to fileURL: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic])
    }

    private nonisolated static func workspaceSupportDirectories() -> [URL] {
        cachedWorkspaceSupportDirectories
    }

    /// Removes every file that can seed a workspace import. This deliberately
    /// verifies absence after deletion: reporting success while a read-only or
    /// concurrently recreated mirror remains would let cleared SwiftData rows
    /// return on the next launch.
    nonisolated static func removeWorkspaceImportMirrorsOffMain(
        directories: [URL],
        fileManager: FileManager = .default
    ) -> Bool {
        var staticMirrors: [URL] = []
        var ambientDirectories: [URL] = []
        for directory in directories {
            staticMirrors.append(directory.appendingPathComponent("settings.json"))
            staticMirrors.append(directory.appendingPathComponent("workspace-sync-state.json"))
            ambientDirectories.append(
                directory.appendingPathComponent("stream/ambient", isDirectory: true)
            )
        }

        var mirrors = staticMirrors
        for ambientDirectory in ambientDirectories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: ambientDirectory.path, isDirectory: &isDirectory) else {
                continue
            }
            guard isDirectory.boolValue else { return false }
            do {
                mirrors.append(contentsOf: try fileManager.contentsOfDirectory(
                    at: ambientDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: .skipsHiddenFiles
                ).filter {
                    $0.pathExtension.lowercased() == "jsonl"
                        || $0.lastPathComponent == "current.json"
                })
            } catch {
                return false
            }
        }

        var seen: Set<String> = []
        for mirror in mirrors.map(\.standardizedFileURL)
            where seen.insert(mirror.path.lowercased()).inserted {
            guard fileManager.fileExists(atPath: mirror.path) else { continue }
            do {
                try fileManager.removeItem(at: mirror)
            } catch {
                return false
            }
        }

        guard staticMirrors.allSatisfy({ !fileManager.fileExists(atPath: $0.path) }) else {
            return false
        }
        for ambientDirectory in ambientDirectories {
            guard fileManager.fileExists(atPath: ambientDirectory.path) else { continue }
            guard let files = try? fileManager.contentsOfDirectory(
                at: ambientDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles
            ) else {
                return false
            }
            guard !files.contains(where: {
                $0.pathExtension.lowercased() == "jsonl"
                    || $0.lastPathComponent == "current.json"
            }) else {
                return false
            }
        }
        return true
    }

    private nonisolated static let cachedWorkspaceSupportDirectories: [URL] = {
        [AppSupportPaths.resonantRoot().standardizedFileURL]
    }()

    private nonisolated static func workspaceSettingsFileURL() -> URL? {
        workspaceSupportDirectories().first?.appendingPathComponent("settings.json")
    }

    private func redactAuthTokenFromWorkspaceFiles() async {
        let directories = Self.workspaceSupportDirectories()
        let writeGeneration = exportFence.beginExport()
        await Task.detached(priority: .utility) { [exportFence] in
            for directory in directories {
                let fileURL = directory.appendingPathComponent("settings.json")
                guard let data = try? Data(contentsOf: fileURL),
                      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continue
                }

                let hadAuthToken = Constants.legacyAuthTokenKeys.contains { json[$0] != nil }
                guard hadAuthToken else {
                    continue
                }

                for key in Constants.legacyAuthTokenKeys {
                    json.removeValue(forKey: key)
                }
                guard let updated = try? JSONSerialization.data(
                    withJSONObject: json,
                    options: [.prettyPrinted, .sortedKeys]
                ) else { continue }
                let stagedURL = directory.appendingPathComponent(
                    ".settings-redaction-\(UUID().uuidString).tmp"
                )
                guard (try? updated.write(to: stagedURL, options: [.atomic])) != nil else {
                    continue
                }
                let committed = exportFence.commit(generation: writeGeneration) {
                    do {
                        _ = try FileManager.default.replaceItemAt(
                            fileURL,
                            withItemAt: stagedURL
                        )
                        return true
                    } catch {
                        return false
                    }
                }
                if committed != true {
                    try? FileManager.default.removeItem(at: stagedURL)
                }
            }
        }.value
    }

    private func parseWorkspaceSnapshot(_ json: [String: Any]) -> WorkspaceSnapshot {
        let meetingSettings = Self.meetingSettingsSnapshot(from: json)
        return WorkspaceSnapshot(
            onboardingCompleted: boolValue(json["onboardingCompleted"]),
            triggerKey: stringValue(json["triggerKey"]),
            triggerKeys: stringArrayValue(json["triggerKeys"]),
            hotkeyMode: stringValue(json["hotkeyMode"]),
            sttModel: stringValue(json["sttModel"]),
            removeFillerWords: boolValue(json["removeFillerWords"]),
            removeFalseStarts: boolValue(json["removeFalseStarts"]),
            itnEnabled: boolValue(json["itnEnabled"]),
            punctuationEnabled: boolValue(json["punctuationEnabled"]),
            formatBulletPoints: boolValue(json["formatBulletPoints"]),
            cloudProcessingEnabled: boolValue(json["cloudProcessingEnabled"]),
            selectionTransformEnabled: boolValue(json["selectionTransformEnabled"]),
            journalSummarizationEnabled: boolValue(json["journalSummarizationEnabled"]),
            meetingSummarizationEnabled: meetingSettings.summarizationEnabled,
            autoPaste: boolValue(json["autoPaste"]),
            copyToClipboard: boolValue(json["copyToClipboard"]),
            autoSend: boolValue(json["autoSend"]),
            emailSignatureEnabled: boolValue(json["emailSignatureEnabled"]),
            emailSignoffName: stringValue(json["emailSignoffName"]),
            triggerKeySoundEnabled: boolValue(json["triggerKeySoundEnabled"]),
            triggerKeySoundVolume: doubleValue(json["triggerKeySoundVolume"]),

            expressionSoundsEnabled: boolValue(json["expressionSoundsEnabled"]),
            expressionSoundsVolume: doubleValue(json["expressionSoundsVolume"]),
            overlayMode: stringValue(json["overlayMode"]),
            inputDeviceUID: stringValue(json["inputDeviceUID"]),
            hotMicEnabled: boolValue(json["hotMicEnabled"]),
            pauseMediaWhileRecording: boolValue(json["pauseMediaWhileRecording"]),
            duckSystemAudioWhileRecording: boolValue(json["duckSystemAudioWhileRecording"]),
            hotWord: Self.hotWordValue(from: json),
            lowLatencyMode: boolValue(json["lowLatencyMode"]),
            meetingRecordingEnabled: meetingSettings.recordingEnabled,
            meetingJoinPromptEnabled: meetingSettings.joinPromptEnabled,
            meetingAutoStartEnabled: meetingSettings.autoStartEnabled,
            meetingAutoStopEnabled: meetingSettings.autoStopEnabled,
            meetingUseCalendarHints: meetingSettings.calendarHintsEnabled,
            meetingSaveAudio: meetingSettings.saveAudioEnabled,
            saveAudio: boolValue(json["saveAudio"]),
            saveContextMetadata: boolValue(json["saveContextMetadata"]),
            historyRetentionDays: intValue(json["historyRetentionDays"]),
            hipaaMode: boolValue(json["hipaaMode"]),
            launchAtLogin: boolValue(json["launchAtLogin"]),
            crashDiagnosticsEnabled: boolValue(json["crashDiagnosticsEnabled"]),
            analyticsEnabled: boolValue(json["analyticsEnabled"]),
            authToken: Self.authTokenValue(from: json),
            userId: stringValue(json["userId"]),
            userEmail: stringValue(json["userEmail"]),
            userDisplayName: stringValue(json["userDisplayName"]),
            pinnedDisplayId: intValue(json["pinnedDisplayId"]),
            smartLinks: codableArray(SmartLink.self, from: json["smartLinks"]),
            hasSmartLinks: json.keys.contains("smartLinks"),
            dictionaryWords: codableArray(DictionaryStore.WorkspaceWord.self, from: json["dictionaryWords"]),
            hasDictionaryWords: json.keys.contains("dictionaryWords"),
            dictationHistory: dictionaryArray(json["dictationHistory"]).compactMap(parseDictationRecord),
            voiceNotes: dictionaryArray(json["voiceNotes"]).compactMap(parseVoiceNoteRecord),
            meetingHistory: dictionaryArray(json["meetingHistory"]).compactMap(parseMeetingRecord),
            stats: dictionaryValue(json["stats"]).map(parseStatsRecord),
            dailyWordCounts: intDictionaryValue(json["dailyWordCounts"])
        )
    }

    private static let didMigrateWorkspaceSettingsKey = "didMigrateWorkspaceSettings"

    private func syncSettings(from snapshot: WorkspaceSnapshot) async {
        if !suppressContinuousRoamingSettingsImport {
            Self.applyContinuouslyRoamingSettings(from: snapshot, to: settingsManager)
            if snapshot.hasSmartLinks {
                smartLinkStore.mergeWorkspaceLinks(snapshot.smartLinks)
            }
            if snapshot.hasDictionaryWords {
                dictionaryStore.mergeWorkspaceWords(snapshot.dictionaryWords)
            }
        }

        // Only apply legacy workspace settings once as an initial migration.
        // After that, UserDefaults is the source of truth.
        // Data sync (dictation history, voice notes, stats) continues regardless.
        let suite = AppDefaults.suite
        if suite.bool(forKey: Self.didMigrateWorkspaceSettingsKey) {
            // Legacy snapshots may contain credentials. Remove them from disk,
            // but never restore them into this device's auth state.
            if snapshot.authToken?.nilIfEmpty != nil {
                await redactAuthTokenFromWorkspaceFiles()
            }
            return
        }

        if let triggerKeys = snapshot.triggerKeys?.compactMap(mapTriggerKey),
           !triggerKeys.isEmpty {
            settingsManager.setHotkeyBindings(
                primary: triggerKeys[0],
                alternates: Array(triggerKeys.dropFirst())
            )
        } else if let trigger = mapTriggerKey(snapshot.triggerKey) {
            settingsManager.setHotkeyBindings(primary: trigger, alternates: [])
        }

        if let hotkeyMode = snapshot.hotkeyMode.flatMap(HotkeyMode.init(rawValue:)) {
            settingsManager.hotkeyMode = hotkeyMode.normalized
        }

        if let modelID = snapshot.sttModel?.nilIfEmpty {
            settingsManager.selectedModelId = modelID
        }

        if let removeFillers = snapshot.removeFillerWords {
            settingsManager.removeFillersEnabled = removeFillers
        }

        if let removeFalseStarts = snapshot.removeFalseStarts {
            settingsManager.removeFalseStartsEnabled = removeFalseStarts
        }

        if let itnEnabled = snapshot.itnEnabled {
            settingsManager.itnEnabled = itnEnabled
        }

        if let punctuationEnabled = snapshot.punctuationEnabled {
            settingsManager.autoPunctuationEnabled = punctuationEnabled
        }

        if let bulletPointsEnabled = snapshot.formatBulletPoints {
            settingsManager.bulletPointsEnabled = bulletPointsEnabled
        }

        if let cloudProcessingEnabled = snapshot.cloudProcessingEnabled {
            settingsManager.cloudProcessingEnabled = cloudProcessingEnabled
        }

        if let selectionTransformEnabled = snapshot.selectionTransformEnabled {
            settingsManager.selectionTransformEnabled = selectionTransformEnabled
        }

        if let journalSummarizationEnabled = snapshot.journalSummarizationEnabled {
            settingsManager.journalSummarizationEnabled = journalSummarizationEnabled
        }

        if let autoPaste = snapshot.autoPaste {
            settingsManager.autoPasteEnabled = autoPaste
        }

        if let copyToClipboard = snapshot.copyToClipboard {
            settingsManager.copyToClipboardEnabled = copyToClipboard
        }

        if let autoSend = snapshot.autoSend {
            settingsManager.autoSendEnabled = autoSend
        }

        if let soundsEnabled = snapshot.expressionSoundsEnabled ?? snapshot.triggerKeySoundEnabled {
            settingsManager.soundsEnabled = soundsEnabled
        }

        if let soundsVolume = snapshot.expressionSoundsVolume ?? snapshot.triggerKeySoundVolume {
            settingsManager.soundsVolume = min(max(soundsVolume, 0), 1)
        }


        if let overlayMode = snapshot.overlayMode.flatMap(OverlayMode.init(rawValue:)) {
            settingsManager.overlayMode = overlayMode
        }

        if let hotWord = snapshot.hotWord?.nilIfEmpty,
           settingsManager.hotWord == SettingsManager.defaultHotWord {
            settingsManager.hotWord = hotWord
        }

        if let lowLatencyMode = snapshot.lowLatencyMode {
            settingsManager.lowLatencyMode = lowLatencyMode
        }

        if snapshot.authToken?.nilIfEmpty != nil {
            await redactAuthTokenFromWorkspaceFiles()
        }

        suite.set(true, forKey: Self.didMigrateWorkspaceSettingsKey)
    }

    private func historyRetentionCutoff(now: Date = Date()) -> Date? {
        let days = settingsManager.historyRetentionDays
        guard days > 0, days < 36_500 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: now)
    }

    private func syncDictationHistory(from history: [WorkspaceSnapshot.DictationRecord], syncState: inout SyncState) async -> ImportResult {
        let timestampParser = ImportTimestampParser()
        let retentionCutoff = historyRetentionCutoff()
        let descriptor = FetchDescriptor<DictationEntry>()
        let existingEntries = await dataStore.fetchMappedInBackground(descriptor) { entry in
            ExistingDictationSnapshot(
                id: entry.id,
                externalID: entry.externalID,
                text: entry.text,
                bundleId: entry.bundleId,
                duration: entry.duration,
                date: entry.date
            )
        }
        var existingByExternalID = existingEntries.reduce(into: [String: ExistingDictationSnapshot]()) { partialResult, entry in
            guard let externalID = entry.externalID?.nilIfEmpty else { return }
            partialResult[externalID] = entry
        }
        var knownEntries = existingEntries
        var importedExternalIDs = Set(syncState.importedDictationIDs)
        var importedCount = 0
        var importedDays: Set<Date> = []
        var didUpdateExistingEntries = false

        for record in history {
            let externalID = Constants.dictationExternalPrefix + record.id
            guard let timestamp = timestampParser.parse(record.timestamp),
                  retentionCutoff.map({ timestamp >= $0 }) ?? true else { continue }

            let text = record.sentText?.nilIfEmpty ?? record.text.nilIfEmpty
            guard let text else { continue }

            if existingByExternalID[externalID] != nil {
                _ = importedExternalIDs.insert(externalID)
                continue
            }

            let bundleID = record.app?.nilIfEmpty ?? ""
            let durationSeconds = max(Double(record.duration ?? 0) / 1000.0, 0)
            if let matchingEntry = existingWorkspaceDictation(
                timestamp: timestamp,
                text: text,
                duration: durationSeconds,
                bundleID: bundleID,
                in: knownEntries
            ) {
                if matchingEntry.externalID != externalID {
                    let entryID = matchingEntry.id
                    _ = await dataStore.performBackgroundWrite { context in
                        var descriptor = FetchDescriptor<DictationEntry>(
                            predicate: #Predicate { $0.id == entryID }
                        )
                        descriptor.fetchLimit = 1
                        guard let entry = try? context.fetch(descriptor).first else { return }
                        entry.externalID = externalID
                    }
                    var updatedEntry = matchingEntry
                    updatedEntry.externalID = externalID
                    existingByExternalID[externalID] = updatedEntry
                    if let index = knownEntries.firstIndex(where: { $0.id == entryID }) {
                        knownEntries[index] = updatedEntry
                    }
                    didUpdateExistingEntries = true
                }
                _ = importedExternalIDs.insert(externalID)
                continue
            }

            let appName = await resolveAppName(bundleID: bundleID) ?? bundleID.nilIfEmpty ?? "Dictation"
            let entryID = UUID()
            let windowTitle = record.windowTitle
            let browserURL = record.url
            let wordCount = text.split(whereSeparator: \.isWhitespace).count
            guard await dataStore.performBackgroundWrite({ context in
                let entry = DictationEntry(
                    id: entryID,
                    text: text,
                    appName: appName,
                    bundleId: bundleID,
                    windowTitle: windowTitle,
                    browserURL: browserURL,
                    wordCount: wordCount,
                    duration: durationSeconds,
                    mode: .dictation,
                    date: timestamp,
                    externalID: externalID
                )
                context.insert(entry)
                return true
            }) == true else {
                continue
            }
            let snapshot = ExistingDictationSnapshot(
                id: entryID,
                externalID: externalID,
                text: text,
                bundleId: bundleID,
                duration: durationSeconds,
                date: timestamp
            )
            existingByExternalID[externalID] = snapshot
            knownEntries.insert(snapshot, at: 0)
            _ = importedExternalIDs.insert(externalID)
            importedCount += 1
            importedDays.insert(Calendar.current.startOfDay(for: timestamp))
        }

        let stateChanged = importedCount > 0 || didUpdateExistingEntries
        if stateChanged {
            syncState.importedDictationIDs = Array(importedExternalIDs).sorted()
        }

        return ImportResult(importedCount: importedCount, importedDays: importedDays, syncStateChanged: stateChanged)
    }

    private func syncVoiceNotes(from voiceNotes: [WorkspaceSnapshot.VoiceNoteRecord], syncState: inout SyncState) async -> ImportResult {
        let workspaceDirectories = Self.workspaceSupportDirectories()
        let timestampParser = ImportTimestampParser()
        let retentionCutoff = historyRetentionCutoff()

        // Drain locally-deleted IDs into the persistent sync state so they survive restarts.
        let newlyDeleted = memoManager.drainDeletedExternalIDs()
        if !newlyDeleted.isEmpty {
            var deletedSet = Set(syncState.deletedMemoIDs)
            deletedSet.formUnion(newlyDeleted)
            syncState.deletedMemoIDs = Array(deletedSet).sorted()
        }
        let deletedIDs = Set(syncState.deletedMemoIDs)

        var importedExternalIDs = Set(syncState.importedMemoIDs)
        var importedCount = 0
        var updatedCount = 0
        var importedDays: Set<Date> = []
        var syncStateChanged = !newlyDeleted.isEmpty
        var hadFailure = false
        let descriptor = FetchDescriptor<MemoEntry>()
        var existingMemos = await dataStore.fetchMappedInBackground(descriptor) { memo in
            ExistingMemoSnapshot(
                id: memo.id,
                externalID: memo.externalID,
                text: memo.text,
                duration: memo.duration,
                date: memo.date,
                audioPath: memo.audioPath,
                distilledText: memo.distilledText
            )
        }
        var existingByExternalID = existingMemos.reduce(into: [String: ExistingMemoSnapshot]()) { partialResult, memo in
            guard let externalID = memo.externalID?.nilIfEmpty else { return }
            partialResult[externalID] = memo
        }
        for record in voiceNotes {
            let externalID = Constants.memoExternalPrefix + record.id

            // Skip memos that were deleted locally.
            if deletedIDs.contains(externalID) { continue }
            guard let timestamp = timestampParser.parse(record.timestamp),
                  retentionCutoff.map({ timestamp >= $0 }) ?? true else { continue }
            guard let text = record.text.nilIfEmpty else { continue }

            let durationSeconds = max(Double(record.duration ?? 0) / 1000.0, 0)
            if var existingMemo = existingByExternalID[externalID] {
                let importedAudioPath: String?
                if existingMemo.audioPath?.nilIfEmpty == nil,
                   let audioURL = await resolveVoiceNoteAudioURL(
                        for: record,
                        workspaceDirectories: workspaceDirectories
                   ) {
                    importedAudioPath = MemoManager.persistAudioOffMain(
                        from: audioURL,
                        memoID: existingMemo.id,
                        removeSourceAfterCopy: false
                    )
                } else {
                    importedAudioPath = nil
                }
                let clarifiedText = existingMemo.distilledText?.nilIfEmpty == nil
                    ? record.clarifiedText?.nilIfEmpty
                    : nil
                if importedAudioPath != nil || clarifiedText != nil {
                    let memoID = existingMemo.id
                    guard await dataStore.performBackgroundWrite({ context in
                        var descriptor = FetchDescriptor<MemoEntry>(
                            predicate: #Predicate { $0.id == memoID }
                        )
                        descriptor.fetchLimit = 1
                        guard let memo = try? context.fetch(descriptor).first else { return false }
                        if memo.audioPath?.nilIfEmpty == nil, let importedAudioPath {
                            memo.audioPath = importedAudioPath
                        }
                        if memo.distilledText?.nilIfEmpty == nil, let clarifiedText {
                            memo.distilledText = clarifiedText
                        }
                        return true
                    }) == true else {
                        hadFailure = true
                        continue
                    }
                    if let importedAudioPath {
                        existingMemo.audioPath = importedAudioPath
                    }
                    if let clarifiedText {
                        existingMemo.distilledText = clarifiedText
                    }
                    existingByExternalID[externalID] = existingMemo
                    if let index = existingMemos.firstIndex(where: { $0.id == existingMemo.id }) {
                        existingMemos[index] = existingMemo
                    }
                    updatedCount += 1
                }
                if importedExternalIDs.insert(externalID).inserted {
                    syncStateChanged = true
                }
                continue
            }

            let matchingMemo = existingWorkspaceMemo(
                timestamp: timestamp,
                text: text,
                duration: durationSeconds,
                in: existingMemos
            )

            if var matchingMemo {
                if matchingMemo.externalID != externalID {
                    let memoID = matchingMemo.id
                    guard await dataStore.performBackgroundWrite({ context in
                        var descriptor = FetchDescriptor<MemoEntry>(
                            predicate: #Predicate { $0.id == memoID }
                        )
                        descriptor.fetchLimit = 1
                        guard let memo = try? context.fetch(descriptor).first else { return false }
                        memo.externalID = externalID
                        return true
                    }) == true else {
                        hadFailure = true
                        continue
                    }
                    matchingMemo.externalID = externalID
                    existingByExternalID[externalID] = matchingMemo
                    if let index = existingMemos.firstIndex(where: { $0.id == memoID }) {
                        existingMemos[index] = matchingMemo
                    }
                }
                if importedExternalIDs.insert(externalID).inserted {
                    syncStateChanged = true
                }
                let importedAudioPath: String?
                if matchingMemo.audioPath?.nilIfEmpty == nil,
                   let audioURL = await resolveVoiceNoteAudioURL(
                        for: record,
                        workspaceDirectories: workspaceDirectories
                   ) {
                    importedAudioPath = MemoManager.persistAudioOffMain(
                        from: audioURL,
                        memoID: matchingMemo.id,
                        removeSourceAfterCopy: false
                    )
                } else {
                    importedAudioPath = nil
                }
                let clarifiedText = matchingMemo.distilledText?.nilIfEmpty == nil
                    ? record.clarifiedText?.nilIfEmpty
                    : nil
                if importedAudioPath != nil || clarifiedText != nil {
                    let memoID = matchingMemo.id
                    guard await dataStore.performBackgroundWrite({ context in
                        var descriptor = FetchDescriptor<MemoEntry>(
                            predicate: #Predicate { $0.id == memoID }
                        )
                        descriptor.fetchLimit = 1
                        guard let memo = try? context.fetch(descriptor).first else { return false }
                        if memo.audioPath?.nilIfEmpty == nil, let importedAudioPath {
                            memo.audioPath = importedAudioPath
                        }
                        if memo.distilledText?.nilIfEmpty == nil, let clarifiedText {
                            memo.distilledText = clarifiedText
                        }
                        return true
                    }) == true else {
                        hadFailure = true
                        continue
                    }
                    if let importedAudioPath {
                        matchingMemo.audioPath = importedAudioPath
                    }
                    if let clarifiedText {
                        matchingMemo.distilledText = clarifiedText
                    }
                    existingByExternalID[externalID] = matchingMemo
                    if let index = existingMemos.firstIndex(where: { $0.id == matchingMemo.id }) {
                        existingMemos[index] = matchingMemo
                    }
                    updatedCount += 1
                }
                continue
            }

            let title = record.title?.nilIfEmpty ?? autoMemoTitle(from: text)
            let memoID = UUID()
            let distilledText = record.clarifiedText?.nilIfEmpty
            let audioPath = (await resolveVoiceNoteAudioURL(
                for: record,
                workspaceDirectories: workspaceDirectories
            )).flatMap {
                MemoManager.persistAudioOffMain(
                    from: $0,
                    memoID: memoID,
                    removeSourceAfterCopy: false
                )
            }
            guard await dataStore.performBackgroundWrite({ context in
                let memo = MemoEntry(
                    id: memoID,
                    text: text,
                    title: title,
                    duration: durationSeconds,
                    date: timestamp,
                    audioPath: audioPath,
                    distilledText: distilledText,
                    externalID: externalID
                )
                context.insert(memo)
                return true
            }) == true else {
                hadFailure = true
                continue
            }
            let snapshot = ExistingMemoSnapshot(
                id: memoID,
                externalID: externalID,
                text: text,
                duration: durationSeconds,
                date: timestamp,
                audioPath: audioPath,
                distilledText: distilledText
            )
            existingMemos.insert(snapshot, at: 0)
            existingByExternalID[externalID] = snapshot
            if importedExternalIDs.insert(externalID).inserted {
                syncStateChanged = true
            }
            importedCount += 1
            importedDays.insert(Calendar.current.startOfDay(for: timestamp))
        }

        if syncStateChanged {
            syncState.importedMemoIDs = Array(importedExternalIDs).sorted()
        }

        return ImportResult(
            importedCount: importedCount,
            updatedCount: updatedCount,
            importedDays: importedDays,
            syncStateChanged: syncStateChanged,
            hadFailure: hadFailure
        )
    }

    private func syncMeetingHistory(from meetings: [WorkspaceSnapshot.MeetingRecord]) async -> ImportResult {
        let timestampParser = ImportTimestampParser()
        let retentionCutoff = historyRetentionCutoff()
        let descriptor = FetchDescriptor<MeetingEntry>()
        let existingMeetings = await dataStore.fetchInBackground(descriptor)
            .filter { $0.activeJSONLPath == nil }
        var existingByID = existingMeetings.reduce(into: [UUID: MeetingEntry]()) { partialResult, entry in
            partialResult[entry.id] = entry
        }
        var importedCount = 0
        var updatedCount = 0

        for record in meetings {
            guard let id = UUID(uuidString: record.id),
                  let startedAt = timestampParser.parse(record.timestamp),
                  retentionCutoff.map({ startedAt >= $0 }) ?? true
            else {
                continue
            }

            let endedAt = timestampParser.parse(record.endedAt)
            let trimmedTitle = record.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let trimmedApp = record.app?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let trimmedNotes = record.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let trimmedPostNotes = record.postMeetingNotes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let trimmedSummary = record.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let trimmedMarkdown = record.markdown?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let trimmedCalendarEventID = record.calendarEventID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let scheduledStartAt = timestampParser.parse(record.scheduledStartAt)
            let scheduledEndAt = timestampParser.parse(record.scheduledEndAt)
            let trimmedOrganizerName = record.organizerName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let attendeeNames = record.attendeeNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let attendeeEmails = record.attendeeEmails
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let speakerAliases = MeetingSpeakerAliasResolver.normalized(record.speakerAliases)
            let trimmedConferencingURL = record.conferencingURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let trimmedCalendarName = record.calendarName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let recordingOrigin = record.recordingOrigin.flatMap(MeetingRecordingOrigin.init(rawValue:))

            if let existing = existingByID[id] {
                var didUpdate = false
                if existing.customTitle?.nilIfEmpty != trimmedTitle {
                    existing.customTitle = trimmedTitle
                    didUpdate = true
                }
                if existing.detectedApp?.nilIfEmpty != trimmedApp {
                    existing.detectedApp = trimmedApp
                    didUpdate = true
                }
                if existing.startedAt != startedAt {
                    existing.startedAt = startedAt
                    didUpdate = true
                }
                if existing.endedAt != endedAt {
                    existing.endedAt = endedAt
                    didUpdate = true
                }
                if let duration = record.duration,
                   existing.durationSeconds != Double(duration) {
                    existing.durationSeconds = Double(duration)
                    didUpdate = true
                }
                if let wordCount = record.wordCount,
                   existing.wordCount != wordCount {
                    existing.wordCount = wordCount
                    didUpdate = true
                }
                if existing.userNotes?.nilIfEmpty != trimmedNotes {
                    existing.userNotes = trimmedNotes
                    didUpdate = true
                }
                if existing.postMeetingNotes?.nilIfEmpty != trimmedPostNotes {
                    existing.postMeetingNotes = trimmedPostNotes
                    didUpdate = true
                }
                if existing.summary?.nilIfEmpty != trimmedSummary {
                    existing.summary = trimmedSummary
                    didUpdate = true
                }
                if existing.speakerAliases != speakerAliases {
                    existing.speakerAliases = speakerAliases
                    didUpdate = true
                }
                if record.hasCaptureMetadata,
                   Self.applyMeetingCaptureMetadata(
                    calendarEventID: trimmedCalendarEventID,
                    scheduledStartAt: scheduledStartAt,
                    scheduledEndAt: scheduledEndAt,
                    organizerName: trimmedOrganizerName,
                    attendeeNames: attendeeNames,
                    attendeeEmails: attendeeEmails,
                    conferencingURL: trimmedConferencingURL,
                    calendarName: trimmedCalendarName,
                    recordingOrigin: recordingOrigin,
                    to: existing
                   ) {
                    didUpdate = true
                }
                let importedMarkdownPath: String?
                if let markdown = trimmedMarkdown {
                    importedMarkdownPath = await archiveWriter.writeImportedMeetingMarkdown(
                    meetingID: id,
                    startedAt: startedAt,
                    markdown: markdown
                    )
                } else {
                    importedMarkdownPath = nil
                }
                if let importedMarkdownPath,
                   existing.markdownPath != importedMarkdownPath {
                    didUpdate = true
                }

                if didUpdate {
                    _ = await dataStore.performBackgroundWrite { context in
                        var descriptor = FetchDescriptor<MeetingEntry>(
                            predicate: #Predicate { $0.id == id }
                        )
                        descriptor.fetchLimit = 1
                        guard let entry = try? context.fetch(descriptor).first else { return }
                        entry.customTitle = trimmedTitle
                        entry.detectedApp = trimmedApp
                        entry.startedAt = startedAt
                        entry.endedAt = endedAt
                        if let duration = record.duration {
                            entry.durationSeconds = Double(duration)
                        }
                        if let wordCount = record.wordCount {
                            entry.wordCount = wordCount
                        }
                        entry.userNotes = trimmedNotes
                        entry.postMeetingNotes = trimmedPostNotes
                        entry.summary = trimmedSummary
                        entry.speakerAliases = speakerAliases
                        if record.hasCaptureMetadata {
                            _ = Self.applyMeetingCaptureMetadata(
                                calendarEventID: trimmedCalendarEventID,
                                scheduledStartAt: scheduledStartAt,
                                scheduledEndAt: scheduledEndAt,
                                organizerName: trimmedOrganizerName,
                                attendeeNames: attendeeNames,
                                attendeeEmails: attendeeEmails,
                                conferencingURL: trimmedConferencingURL,
                                calendarName: trimmedCalendarName,
                                recordingOrigin: recordingOrigin,
                                to: entry
                            )
                        }
                        if let importedMarkdownPath {
                            entry.markdownPath = importedMarkdownPath
                        }
                    }
                    updatedCount += 1
                }
                continue
            }

            let importedMarkdownPath: String?
            if let markdown = trimmedMarkdown {
                importedMarkdownPath = await archiveWriter.writeImportedMeetingMarkdown(
                    meetingID: id,
                    startedAt: startedAt,
                    markdown: markdown
                )
            } else {
                importedMarkdownPath = nil
            }
            _ = await dataStore.performBackgroundWrite { context in
                let entry = MeetingEntry(
                    id: id,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    detectedApp: trimmedApp,
                    customTitle: trimmedTitle,
                    durationSeconds: Double(record.duration ?? 0),
                    wordCount: record.wordCount ?? 0,
                    userNotes: trimmedNotes,
                    postMeetingNotes: trimmedPostNotes,
                    summary: trimmedSummary,
                    speakerAliasesJSON: encodeJSONStringDictionary(speakerAliases)
                )
                if record.hasCaptureMetadata {
                    _ = Self.applyMeetingCaptureMetadata(
                        calendarEventID: trimmedCalendarEventID,
                        scheduledStartAt: scheduledStartAt,
                        scheduledEndAt: scheduledEndAt,
                        organizerName: trimmedOrganizerName,
                        attendeeNames: attendeeNames,
                        attendeeEmails: attendeeEmails,
                        conferencingURL: trimmedConferencingURL,
                        calendarName: trimmedCalendarName,
                        recordingOrigin: recordingOrigin,
                        to: entry
                    )
                }
                entry.markdownPath = importedMarkdownPath
                context.insert(entry)
            }
            if let persisted = dataStore.meetingEntry(id: id) {
                existingByID[id] = persisted
            }
            importedCount += 1
        }

        return ImportResult(importedCount: importedCount, updatedCount: updatedCount)
    }

    private nonisolated static func applyMeetingCaptureMetadata(
        calendarEventID: String?,
        scheduledStartAt: Date?,
        scheduledEndAt: Date?,
        organizerName: String?,
        attendeeNames: [String],
        attendeeEmails: [String],
        conferencingURL: String?,
        calendarName: String?,
        recordingOrigin: MeetingRecordingOrigin?,
        to entry: MeetingEntry
    ) -> Bool {
        var didUpdate = false

        if entry.calendarEventID?.nilIfEmpty != calendarEventID {
            entry.calendarEventID = calendarEventID
            didUpdate = true
        }
        if entry.scheduledStartAt != scheduledStartAt {
            entry.scheduledStartAt = scheduledStartAt
            didUpdate = true
        }
        if entry.scheduledEndAt != scheduledEndAt {
            entry.scheduledEndAt = scheduledEndAt
            didUpdate = true
        }
        if entry.organizerName?.nilIfEmpty != organizerName {
            entry.organizerName = organizerName
            didUpdate = true
        }
        if entry.attendeeNames != attendeeNames {
            entry.attendeeNamesJSON = encodeJSONStringArray(attendeeNames)
            didUpdate = true
        }
        if entry.attendeeEmails != attendeeEmails {
            entry.attendeeEmailsJSON = encodeJSONStringArray(attendeeEmails)
            didUpdate = true
        }
        if entry.conferencingURL?.nilIfEmpty != conferencingURL {
            entry.conferencingURL = conferencingURL
            didUpdate = true
        }
        if entry.calendarName?.nilIfEmpty != calendarName {
            entry.calendarName = calendarName
            didUpdate = true
        }
        if entry.recordingOrigin != recordingOrigin {
            entry.recordingOrigin = recordingOrigin
            didUpdate = true
        }

        return didUpdate
    }

    private func syncAmbientHistory(from events: [AmbientStreamEvent]) async -> ImportResult {
        guard !events.isEmpty else { return ImportResult() }

        let timestampParser = ImportTimestampParser()
        let descriptor = FetchDescriptor<AmbientContextSnapshot>()
        var existingIDs = Set(await dataStore.fetchMappedInBackground(descriptor) { $0.id })
        let retentionDays = settingsManager.historyRetentionDays
        let cutoff = retentionDays > 0 && retentionDays < 36500
            ? Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
            : nil
        var importedCount = 0
        var hadFailure = false
        var batch: [AmbientImportCandidate] = []
        batch.reserveCapacity(Self.ambientImportBatchSize)

        for event in events {
            guard let id = UUID(uuidString: event.id),
                  !existingIDs.contains(id),
                  let timestamp = timestampParser.parse(event.timestamp),
                  cutoff.map({ timestamp >= $0 }) ?? true
            else {
                continue
            }
            let notificationReceivedAt = event.notificationReceivedAt.flatMap { timestampParser.parse($0) }

            batch.append(AmbientImportCandidate(
                event: event,
                id: id,
                timestamp: timestamp,
                notificationReceivedAt: notificationReceivedAt
            ))
            existingIDs.insert(id)

            if batch.count >= Self.ambientImportBatchSize {
                let count = batch.count
                if await insertAmbientSnapshots(batch) {
                    importedCount += count
                } else {
                    hadFailure = true
                }
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            let count = batch.count
            if await insertAmbientSnapshots(batch) {
                importedCount += count
            } else {
                hadFailure = true
            }
        }

        return ImportResult(importedCount: importedCount, hadFailure: hadFailure)
    }

    private func insertAmbientSnapshots(_ candidates: [AmbientImportCandidate]) async -> Bool {
        guard !candidates.isEmpty else { return true }

        return await dataStore.performBackgroundWrite { context in
            for candidate in candidates {
                let event = candidate.event
                let snapshot = AmbientContextSnapshot(
                    id: candidate.id,
                    timestamp: candidate.timestamp,
                    appName: event.appName,
                    bundleId: event.bundleId,
                    windowTitle: event.windowTitle,
                    browserURL: event.browserURL,
                    codeFileName: event.codeFileName,
                    slackRecipient: event.slackRecipient,
                    focusedFieldContent: event.focusedFieldContent,
                    visibleTextSnippetsJSON: encodeJSONStringArray(event.visibleTextSnippets),
                    dwellDurationSeconds: event.dwellDurationSeconds,
                    clipboardText: event.clipboardText,
                    browserTabsJSON: encodeJSONStringArray(event.browserTabs),
                    notificationAppName: event.notificationAppName,
                    notificationBundleId: event.notificationBundleId,
                    notificationTitle: event.notificationTitle,
                    notificationBody: event.notificationBody,
                    notificationURL: event.notificationURL,
                    notificationReceivedAt: candidate.notificationReceivedAt
                )
                context.insert(snapshot)
            }
            return true
        } == true
    }

    private func mergeStats(from stats: WorkspaceSnapshot.StatsRecord?, dailyWordCounts: [String: Int]) {
        guard let stats else { return }

        Defaults[.statsTotalWords] = max(Defaults[.statsTotalWords], stats.totalWords ?? 0)
        Defaults[.statsTotalDictations] = max(Defaults[.statsTotalDictations], stats.totalDictations ?? 0)
        Defaults[.statsLongestDictation] = max(Defaults[.statsLongestDictation], stats.longestDictation ?? 0)

        let derivedCurrentStreak = Self.currentDayStreak(from: dailyWordCounts)
        let derivedLongestStreak = longestDayStreak(from: dailyWordCounts)
        Defaults[.statsLongestStreakDays] = max(
            Defaults[.statsLongestStreakDays],
            max(stats.streakDays ?? 0, derivedLongestStreak)
        )

        if let legacyLastUsedDate = Self.parseDay(stats.lastUsedDate) {
            let currentLastUsedDate = Defaults[.statsLastUsedDate] ?? .distantPast
            if legacyLastUsedDate >= currentLastUsedDate {
                Defaults[.statsLastUsedDate] = legacyLastUsedDate
                Defaults[.statsStreakDays] = max(stats.streakDays ?? 0, derivedCurrentStreak)
                Defaults[.streakLastDictationDate] = legacyLastUsedDate
            }
        } else if derivedCurrentStreak > 0 {
            Defaults[.statsStreakDays] = max(Defaults[.statsStreakDays], derivedCurrentStreak)
        }
    }

    private nonisolated static func syncStateURL() -> URL? {
        workspaceSupportDirectories().first?.appendingPathComponent("workspace-sync-state.json")
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func stringArrayValue(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        let strings = array.compactMap(stringValue)
        return strings.isEmpty ? nil : strings
    }

    private func stringDictionaryValue(_ value: Any?) -> [String: String]? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let normalized = dictionary.reduce(into: [String: String]()) { result, entry in
            guard let value = stringValue(entry.value)?.nilIfEmpty else { return }
            result[entry.key] = value
        }
        return normalized.isEmpty ? nil : normalized
    }

    private func firstStringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(dictionary[key])?.nilIfEmpty {
                return value
            }
        }
        return nil
    }

    private func dictionaryArray(_ value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    private func codableArray<T: Decodable>(_ type: T.Type, from value: Any?) -> [T] {
        let array = dictionaryArray(value)
        guard !array.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: array) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([T].self, from: data)) ?? []
    }

    private func dictionaryValue(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private func intDictionaryValue(_ value: Any?) -> [String: Int] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [String: Int]()) { partialResult, item in
            if let number = intValue(item.value) {
                partialResult[item.key] = number
            }
        }
    }

    private func parseDictationRecord(_ record: [String: Any]) -> WorkspaceSnapshot.DictationRecord? {
        guard let id = stringValue(record["id"]),
              let text = stringValue(record["text"]),
              let timestamp = stringValue(record["timestamp"])
        else {
            return nil
        }

        return WorkspaceSnapshot.DictationRecord(
            id: id,
            text: text,
            sentText: stringValue(record["sentText"]),
            timestamp: timestamp,
            app: stringValue(record["app"]),
            windowTitle: stringValue(record["windowTitle"]),
            url: stringValue(record["url"]),
            duration: intValue(record["duration"])
        )
    }

    private func parseVoiceNoteRecord(_ record: [String: Any]) -> WorkspaceSnapshot.VoiceNoteRecord? {
        guard let id = stringValue(record["id"]),
              let text = stringValue(record["text"]),
              let timestamp = stringValue(record["timestamp"])
        else {
            return nil
        }

        return WorkspaceSnapshot.VoiceNoteRecord(
            id: id,
            text: text,
            clarifiedText: stringValue(record["clarifiedText"]),
            title: stringValue(record["title"]),
            timestamp: timestamp,
            duration: intValue(record["duration"]),
            hasAudio: boolValue(record["hasAudio"]),
            audioReference: firstStringValue(in: record, keys: Constants.voiceNoteAudioKeys)
        )
    }

    func parseMeetingRecord(_ record: [String: Any]) -> WorkspaceSnapshot.MeetingRecord? {
        guard let id = stringValue(record["id"]),
              let timestamp = stringValue(record["timestamp"])
        else {
            return nil
        }

        let metadataKeys = [
            "calendarEventID",
            "calendarEventId",
            "scheduledStartAt",
            "scheduledStart",
            "scheduledEndAt",
            "scheduledEnd",
            "organizerName",
            "attendeeNames",
            "attendees",
            "attendeeEmails",
            "speakerAliases",
            "conferencingURL",
            "conferencingUrl",
            "calendarName",
            "recordingOrigin",
        ]

        return WorkspaceSnapshot.MeetingRecord(
            id: id,
            title: stringValue(record["title"]),
            timestamp: timestamp,
            endedAt: stringValue(record["endedAt"]),
            duration: intValue(record["duration"]),
            wordCount: intValue(record["wordCount"]),
            app: stringValue(record["app"]),
            notes: stringValue(record["notes"]),
            postMeetingNotes: stringValue(record["postMeetingNotes"]),
            summary: stringValue(record["summary"]),
            markdown: stringValue(record["markdown"]),
            calendarEventID: firstStringValue(in: record, keys: ["calendarEventID", "calendarEventId"]),
            scheduledStartAt: firstStringValue(in: record, keys: ["scheduledStartAt", "scheduledStart"]),
            scheduledEndAt: firstStringValue(in: record, keys: ["scheduledEndAt", "scheduledEnd"]),
            organizerName: stringValue(record["organizerName"]),
            attendeeNames: stringArrayValue(record["attendeeNames"]) ?? stringArrayValue(record["attendees"]) ?? [],
            attendeeEmails: stringArrayValue(record["attendeeEmails"]) ?? [],
            speakerAliases: stringDictionaryValue(record["speakerAliases"]) ?? [:],
            conferencingURL: firstStringValue(in: record, keys: ["conferencingURL", "conferencingUrl"]),
            calendarName: stringValue(record["calendarName"]),
            recordingOrigin: stringValue(record["recordingOrigin"]),
            hasCaptureMetadata: metadataKeys.contains(where: { record[$0] != nil })
        )
    }

    private func parseStatsRecord(_ record: [String: Any]) -> WorkspaceSnapshot.StatsRecord {
        WorkspaceSnapshot.StatsRecord(
            totalWords: intValue(record["totalWords"]),
            totalDictations: intValue(record["totalDictations"]),
            longestDictation: intValue(record["longestDictation"]),
            streakDays: intValue(record["streakDays"]),
            lastUsedDate: stringValue(record["lastUsedDate"])
        )
    }

    private func parseTimestamp(_ value: String?) -> Date? {
        guard let value = value?.nilIfEmpty else { return nil }

        let fractionalFormatter = Self.makeImportTimestampFormatter(withFractionalSeconds: true)
        let standardFormatter = Self.makeImportTimestampFormatter(withFractionalSeconds: false)
        return Self.parseTimestamp(
            value,
            fractionalFormatter: fractionalFormatter,
            standardFormatter: standardFormatter
        )
    }

    nonisolated private static func parseDay(_ value: String?) -> Date? {
        parseDay(value, formatter: makeDayFormatter())
    }

    nonisolated private static func parseDay(_ value: String?, formatter: DateFormatter) -> Date? {
        guard let value = value?.nilIfEmpty else { return nil }
        return formatter.date(from: value)
    }

    nonisolated private static func currentDayStreak(from counts: [String: Int]) -> Int {
        let formatter = makeDayFormatter()
        let activeDays = counts
            .compactMap { key, count -> Date? in
                guard count > 0 else { return nil }
                return parseDay(key, formatter: formatter)
            }
            .sorted(by: >)

        guard let firstDay = activeDays.first else { return 0 }

        var streak = 1
        var previousDay = firstDay
        for day in activeDays.dropFirst() {
            let delta = Calendar.current.dateComponents([.day], from: day, to: previousDay).day ?? 0
            guard delta == 1 else { break }
            streak += 1
            previousDay = day
        }
        return streak
    }

    private func longestDayStreak(from counts: [String: Int]) -> Int {
        let formatter = Self.makeDayFormatter()
        let activeDays = counts
            .compactMap { key, count -> Date? in
                guard count > 0 else { return nil }
                return Self.parseDay(key, formatter: formatter)
            }
            .sorted()

        guard !activeDays.isEmpty else { return 0 }

        var longest = 1
        var current = 1

        for index in activeDays.indices.dropFirst() {
            let previousDay = activeDays[activeDays.index(before: index)]
            let day = activeDays[index]
            let delta = Calendar.current.dateComponents([.day], from: previousDay, to: day).day ?? 0
            if delta == 1 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }

        return longest
    }

    private func mapTriggerKey(_ value: String?) -> HotkeyTrigger? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        switch raw.lowercased() {
        case "fn", "globe":
            return .fn
        case "rightoption", "right_option", "right option", "option":
            return .rightOption
        default:
            return HotkeyTrigger(rawValue: raw)
        }
    }

    private func resolveAppName(bundleID: String) async -> String? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = appNameCache[bundleID] {
            return cached
        }

        let resolvedName = await Task.detached(priority: .utility) {
            Self.resolveAppNameOffMain(bundleID: bundleID)
        }.value ?? bundleID
        appNameCache[bundleID] = resolvedName
        return resolvedName
    }

    private nonisolated static func resolveAppNameOffMain(bundleID: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }

        let bundle = Bundle(url: appURL)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    private func autoMemoTitle(from text: String) -> String {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        let firstSentence = sentences.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
        return String(firstSentence.prefix(60))
    }

    private nonisolated static func workspaceAudioDirectories(relativeTo directory: URL) -> [URL] {
        Constants.workspaceAudioDirectories.map {
            directory.appendingPathComponent($0, isDirectory: true)
        }
    }

    private func existingWorkspaceDictation(
        timestamp: Date,
        text: String,
        duration: TimeInterval,
        bundleID: String,
        in entries: [ExistingDictationSnapshot]
    ) -> ExistingDictationSnapshot? {
        entries.first { entry in
            abs(entry.date.timeIntervalSince(timestamp)) < 1
                && entry.text == text
                && abs(entry.duration - duration) < 1
                && entry.bundleId == bundleID
        }
    }

    private func existingWorkspaceMemo(
        timestamp: Date,
        text: String,
        duration: TimeInterval,
        in memos: [ExistingMemoSnapshot]
    ) -> ExistingMemoSnapshot? {
        memos.first { memo in
            abs(memo.date.timeIntervalSince(timestamp)) < 1
                && memo.text == text
                && abs(memo.duration - duration) < 1
        }
    }

    private func updateExistingMemo(
        _ memo: MemoEntry,
        from record: WorkspaceSnapshot.VoiceNoteRecord,
        workspaceDirectories: [URL]
    ) async -> Bool {
        var didChange = false

        if memo.audioPath?.nilIfEmpty == nil,
           let audioURL = await resolveVoiceNoteAudioURL(
                for: record,
                workspaceDirectories: workspaceDirectories
           ),
           let importedAudioPath = memoManager.importAudio(from: audioURL, memoID: memo.id) {
            memo.audioPath = importedAudioPath
            didChange = true
        }

        if memo.distilledText?.nilIfEmpty == nil,
           let clarifiedText = record.clarifiedText?.nilIfEmpty {
            memo.distilledText = clarifiedText
            didChange = true
        }

        return didChange
    }

    private func resolveVoiceNoteAudioURL(
        for record: WorkspaceSnapshot.VoiceNoteRecord,
        workspaceDirectories: [URL]
    ) async -> URL? {
        await Task.detached(priority: .utility) {
            Self.resolveVoiceNoteAudioURLOffMain(
                for: record,
                workspaceDirectories: workspaceDirectories
            )
        }.value
    }

    private nonisolated static func resolveVoiceNoteAudioURLOffMain(
        for record: WorkspaceSnapshot.VoiceNoteRecord,
        workspaceDirectories: [URL]
    ) -> URL? {
        if let audioReference = record.audioReference?.nilIfEmpty {
            for candidateURL in candidateVoiceNoteAudioURLs(
                for: audioReference,
                workspaceDirectories: workspaceDirectories
            ) {
                if FileManager.default.fileExists(atPath: candidateURL.path),
                   isSupportedAudioFile(candidateURL) {
                    return candidateURL
                }
            }
        }

        guard record.hasAudio == true else { return nil }

        for directory in workspaceDirectories {
            for audioDirectory in workspaceAudioDirectories(relativeTo: directory)
            where FileManager.default.fileExists(atPath: audioDirectory.path) {
                if let audioURL = findVoiceNoteAudio(in: audioDirectory, recordID: record.id) {
                    return audioURL
                }
            }

            if let audioURL = findVoiceNoteAudio(in: directory, recordID: record.id) {
                return audioURL
            }
        }

        return nil
    }

    private nonisolated static func candidateVoiceNoteAudioURLs(
        for reference: String,
        workspaceDirectories: [URL]
    ) -> [URL] {
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReference.isEmpty else { return [] }

        var seen: Set<String> = []
        var candidates: [URL] = []

        func append(_ url: URL) {
            let standardizedURL = url.standardizedFileURL
            guard seen.insert(standardizedURL.path.lowercased()).inserted else { return }
            candidates.append(standardizedURL)
        }

        if trimmedReference.hasPrefix("file://"),
           let fileURL = URL(string: trimmedReference),
           fileURL.isFileURL {
            append(fileURL)
        }

        if trimmedReference.hasPrefix("/") {
            append(URL(fileURLWithPath: trimmedReference))
        }

        let basename = URL(fileURLWithPath: trimmedReference).lastPathComponent
        for directory in workspaceDirectories {
            append(directory.appendingPathComponent(trimmedReference))
            for audioDirectory in workspaceAudioDirectories(relativeTo: directory) {
                append(audioDirectory.appendingPathComponent(trimmedReference))
                append(audioDirectory.appendingPathComponent(basename))
            }
        }

        return candidates
    }

    private nonisolated static func findVoiceNoteAudio(in directory: URL, recordID: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        let normalizedRecordID = recordID.lowercased()

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if Constants.ignoredWorkspaceSearchDirectories.contains(fileURL.lastPathComponent.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true, isSupportedAudioFile(fileURL) else { continue }

            let baseName = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            let fileName = fileURL.lastPathComponent.lowercased()
            if baseName == normalizedRecordID || fileName.contains(normalizedRecordID) {
                return fileURL
            }
        }

        return nil
    }

    private nonisolated static func isSupportedAudioFile(_ url: URL) -> Bool {
        Constants.supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    private nonisolated static func exportSettingsSnapshot() -> ExportSettingsSnapshot {
        let triggerKey = Defaults[.hotkeyTrigger]
        let triggerKeys = [triggerKey] + Defaults[.hotkeyAlternateTriggers].filter { $0 != triggerKey }

        return ExportSettingsSnapshot(
            onboardingCompleted: Defaults[.onboardingCompleted],
            triggerKey: triggerKey,
            triggerKeys: triggerKeys,
            hotkeyMode: Defaults[.hotkeyMode],
            selectedModelId: Defaults[.selectedModelId],
            removeFillersEnabled: Defaults[.removeFillersEnabled],
            removeFalseStartsEnabled: Defaults[.removeFalseStartsEnabled],
            itnEnabled: Defaults[.itnEnabled],
            autoPunctuationEnabled: Defaults[.autoPunctuationEnabled],
            bulletPointsEnabled: Defaults[.bulletPointsEnabled],
            cloudProcessingEnabled: Defaults[.cloudProcessingEnabled],
            selectionTransformEnabled: Defaults[.selectionTransformEnabled],
            journalSummarizationEnabled: Defaults[.journalSummarizationEnabled],
            autoPasteEnabled: Defaults[.autoPasteEnabled],
            copyToClipboardEnabled: Defaults[.copyToClipboardEnabled],
            autoSendEnabled: Defaults[.autoSendEnabled],
            emailSignatureEnabled: Defaults[.emailSignatureEnabled],
            emailSignoffName: Defaults[.emailSignoffName],
            soundsEnabled: Defaults[.soundsEnabled],
            soundsVolume: Defaults[.soundsVolume],
            hotMicEnabled: Defaults[.hotMicEnabled],
            pauseMediaWhileRecording: Defaults[.pauseMediaWhileRecording],
            duckSystemAudioWhileRecording: Defaults[.duckSystemAudioWhileRecording],
            hotWord: Defaults[.hotWord],
            lowLatencyMode: Defaults[.lowLatencyMode],
            meetingSummarizationEnabled: Defaults[.meetingSummarizationEnabled],
            meetingRecordingEnabled: Defaults[.meetingRecordingEnabled],
            meetingJoinPromptEnabled: Defaults[.meetingJoinPromptEnabled],
            meetingAutoStartEnabled: Defaults[.meetingAutoStartEnabled],
            meetingAutoStopEnabled: Defaults[.meetingAutoStopEnabled],
            meetingUseCalendarHints: Defaults[.meetingUseCalendarHints],
            meetingSaveAudio: Defaults[.meetingSaveAudio],
            saveAudioEnabled: Defaults[.saveAudioEnabled],
            contextMetadataEnabled: Defaults[.contextMetadataEnabled],
            historyRetentionDays: Defaults[.historyRetentionDays],
            hipaaMode: Defaults[.hipaaMode],
            launchAtLogin: Defaults[.launchAtLogin],
            crashDiagnosticsEnabled: Defaults[.crashDiagnosticsEnabled],
            overlayMode: Defaults[.overlayMode],
            analyticsEnabled: Defaults[.analyticsEnabled],
            inputDeviceUID: Defaults[.inputDeviceUID],
            pinnedDisplayId: Defaults[.pinnedDisplayId],
            userId: Defaults[.userId],
            userEmail: Defaults[.userEmail],
            userDisplayName: Defaults[.userDisplayName],
            smartLinks: [],
            dictionaryWords: []
        )
    }

    private nonisolated static func workspaceSettingsJSON(
        from snapshot: ExportSettingsSnapshot,
        dictationHistory: [[String: Any]],
        voiceNotes: [[String: Any]],
        meetingHistory: [[String: Any]]
    ) -> [String: Any] {
        var json: [String: Any] = [:]

        json["triggerKey"] = snapshot.triggerKey
        json["triggerKeys"] = snapshot.triggerKeys
        json["hotkeyMode"] = snapshot.hotkeyMode
        json["sttModel"] = snapshot.selectedModelId
        json["removeFillerWords"] = snapshot.removeFillersEnabled
        json["removeFalseStarts"] = snapshot.removeFalseStartsEnabled
        json["itnEnabled"] = snapshot.itnEnabled
        json["punctuationEnabled"] = snapshot.autoPunctuationEnabled
        json["formatBulletPoints"] = snapshot.bulletPointsEnabled
        json["cloudProcessingEnabled"] = snapshot.cloudProcessingEnabled
        json["selectionTransformEnabled"] = snapshot.selectionTransformEnabled
        json["journalSummarizationEnabled"] = snapshot.journalSummarizationEnabled
        json["autoPaste"] = snapshot.autoPasteEnabled
        json["copyToClipboard"] = snapshot.copyToClipboardEnabled
        json["autoSend"] = snapshot.autoSendEnabled
        json["triggerKeySoundEnabled"] = snapshot.soundsEnabled
        json["triggerKeySoundVolume"] = snapshot.soundsVolume
        json["expressionSoundsEnabled"] = snapshot.soundsEnabled
        json["expressionSoundsVolume"] = snapshot.soundsVolume
        Self.writeMeetingSettings(from: snapshot, into: &json)

        json["pauseMediaWhileRecording"] = snapshot.pauseMediaWhileRecording
        json["duckSystemAudioWhileRecording"] = snapshot.duckSystemAudioWhileRecording
        json["hotWord"] = snapshot.hotWord
        json["hotMicWakePhrase"] = snapshot.hotWord
        json["lowLatencyMode"] = snapshot.lowLatencyMode
        json["overlayMode"] = snapshot.overlayMode
        json["smartLinks"] = codableJSONArray(snapshot.smartLinks)
        json["dictionaryWords"] = codableJSONArray(snapshot.dictionaryWords)
        json["dictationHistory"] = dictationHistory
        json["voiceNotes"] = voiceNotes
        json["meetingHistory"] = meetingHistory

        // dailyWordCounts and stats are computed off the main actor (in the
        // detached export task) to avoid blocking the UI with UserDefaults reads.

        for key in Constants.legacyAuthTokenKeys {
            json.removeValue(forKey: key)
        }

        return json
    }

    nonisolated private static func codableJSONArray<T: Encodable>(_ values: [T]) -> [[String: Any]] {
        guard !values.isEmpty else { return [] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(values),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    private func exportedDictationData() async -> (history: [[String: Any]], dailyWordCounts: [String: Int]) {
        guard let container = dataStore.container else { return ([], [:]) }
        let descriptor: FetchDescriptor<DictationEntry>
        if let cutoff = historyRetentionCutoff() {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.date >= cutoff }
            )
        } else {
            descriptor = FetchDescriptor()
        }
        // Fetch and serialize entirely in a background context so SwiftData
        // property faults don't block the main thread. Sort in memory instead
        // of asking SQLite to ORDER BY the whole history; diagnostics showed
        // SQLite sorter temp writes dominating periodic exports.
        return await Task.detached(priority: .utility) {
            let startedAt = ContinuousClock.now
            let bgContext = ModelContext(container)
            bgContext.autosaveEnabled = false
            guard let entries = try? bgContext.fetch(descriptor) else { return ([], [:]) }
            let sortedEntries = entries.sorted { $0.date > $1.date }
            let tsFormatter = Self.makeExportTimestampFormatter()
            let dayFmt = Self.makeDayFormatter()
            let history = Self.exportDictationHistory(sortedEntries, formatter: tsFormatter)
            let dailyWordCounts = Self.computeDailyWordCounts(sortedEntries, formatter: dayFmt)
            Self.logWorkspaceCollection(
                kind: "dictations",
                count: sortedEntries.count,
                milliseconds: DiagnosticTiming.milliseconds(from: startedAt)
            )
            return (history, dailyWordCounts)
        }.value
    }

    private func exportedMemoData() async -> [[String: Any]] {
        guard let container = dataStore.container else { return [] }
        let descriptor: FetchDescriptor<MemoEntry>
        if let cutoff = historyRetentionCutoff() {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.date >= cutoff }
            )
        } else {
            descriptor = FetchDescriptor()
        }
        return await Task.detached(priority: .utility) {
            let startedAt = ContinuousClock.now
            let bgContext = ModelContext(container)
            bgContext.autosaveEnabled = false
            guard let memos = try? bgContext.fetch(descriptor) else { return [] }
            let sortedMemos = memos.sorted { $0.date > $1.date }
            let exported = Self.exportVoiceNotes(sortedMemos, formatter: Self.makeExportTimestampFormatter())
            Self.logWorkspaceCollection(
                kind: "voiceNotes",
                count: sortedMemos.count,
                milliseconds: DiagnosticTiming.milliseconds(from: startedAt)
            )
            return exported
        }.value
    }

    private func exportedMeetingData() async -> [[String: Any]] {
        guard let container = dataStore.container else { return [] }
        let descriptor: FetchDescriptor<MeetingEntry>
        if let cutoff = historyRetentionCutoff() {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.startedAt >= cutoff }
            )
        } else {
            descriptor = FetchDescriptor()
        }
        return await Task.detached(priority: .utility) {
            let startedAt = ContinuousClock.now
            let bgContext = ModelContext(container)
            bgContext.autosaveEnabled = false
            guard let meetings = try? bgContext.fetch(descriptor) else { return [] }
            let exportableMeetings = meetings
                .filter { $0.activeJSONLPath == nil }
                .sorted { $0.startedAt > $1.startedAt }
            let exported = Self.exportMeetingHistory(
                exportableMeetings,
                formatter: Self.makeExportTimestampFormatter()
            )
            Self.logWorkspaceCollection(
                kind: "meetings",
                count: exportableMeetings.count,
                milliseconds: DiagnosticTiming.milliseconds(from: startedAt)
            )
            return exported
        }.value
    }

    /// Creates a per-task timestamp formatter. Foundation formatters are not
    /// thread-safe, so each detached task must use its own instance.
    nonisolated private static func makeExportTimestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }

    nonisolated private static func makeImportTimestampFormatter(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    nonisolated private static func parseTimestamp(
        _ value: String,
        fractionalFormatter: ISO8601DateFormatter,
        standardFormatter: ISO8601DateFormatter
    ) -> Date? {
        fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value)
    }

    nonisolated private static func makeDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    nonisolated private static func exportDictationHistory(_ entries: [DictationEntry], formatter: ISO8601DateFormatter) -> [[String: Any]] {
        entries.map { entry in
            let context = entry.capturedContext
            var record: [String: Any] = [
                "id": Self.workspaceRecordID(from: entry.externalID ?? Self.localDictationExternalID(for: entry.id)),
                "text": entry.rawTranscript?.nilIfEmpty ?? entry.text,
                "sentText": entry.text,
                "timestamp": formatter.string(from: entry.date),
                "app": context.bundleId ?? context.appName ?? "",
                "duration": Int((entry.duration * 1000.0).rounded()),
                "hasAudio": entry.audioPath?.nilIfEmpty != nil,
            ]
            if let windowTitle = context.windowTitle {
                record["windowTitle"] = windowTitle
            }
            if let url = context.browserURL {
                record["url"] = url
            }
            return record
        }
    }

    nonisolated private static func exportVoiceNotes(_ memos: [MemoEntry], formatter: ISO8601DateFormatter) -> [[String: Any]] {
        memos.map { memo in
            var record: [String: Any] = [
                "id": Self.workspaceRecordID(from: memo.externalID ?? Self.localMemoExternalID(for: memo.id)),
                "text": memo.text,
                "title": memo.displayTitle,
                "timestamp": formatter.string(from: memo.date),
                "duration": Int((memo.duration * 1000.0).rounded()),
                "hasAudio": memo.audioPath?.nilIfEmpty != nil,
            ]
            if let clarifiedText = memo.distilledText?.nilIfEmpty {
                record["clarifiedText"] = clarifiedText
            }
            if let audioPath = memo.audioPath?.nilIfEmpty {
                record["audioPath"] = audioPath
                record["audioRelativePath"] = audioPath
            }
            return record
        }
    }

    nonisolated static func exportMeetingHistory(_ meetings: [MeetingEntry], formatter: ISO8601DateFormatter) -> [[String: Any]] {
        meetings.map { entry in
            var record: [String: Any] = [
                "id": entry.id.uuidString.lowercased(),
                "title": entry.displayTitle,
                "timestamp": formatter.string(from: entry.startedAt),
                "duration": Int(entry.durationSeconds.rounded()),
                "wordCount": entry.wordCount,
            ]
            if let endedAt = entry.endedAt {
                record["endedAt"] = formatter.string(from: endedAt)
            }
            if let app = entry.detectedApp?.nilIfEmpty {
                record["app"] = app
            }
            if let notes = entry.userNotes?.nilIfEmpty {
                record["notes"] = notes
            }
            if let postMeetingNotes = entry.postMeetingNotes?.nilIfEmpty {
                record["postMeetingNotes"] = postMeetingNotes
            }
            if let summary = entry.summary?.nilIfEmpty {
                record["summary"] = summary
            }
            if let markdown = Self.loadMeetingMarkdownContent(for: entry)?.nilIfEmpty {
                record["markdown"] = markdown
            }
            if let calendarEventID = entry.calendarEventID?.nilIfEmpty {
                record["calendarEventID"] = calendarEventID
            }
            if let scheduledStartAt = entry.scheduledStartAt {
                record["scheduledStartAt"] = formatter.string(from: scheduledStartAt)
            }
            if let scheduledEndAt = entry.scheduledEndAt {
                record["scheduledEndAt"] = formatter.string(from: scheduledEndAt)
            }
            if let organizerName = entry.organizerName?.nilIfEmpty {
                record["organizerName"] = organizerName
            }
            if !entry.attendeeNames.isEmpty {
                record["attendeeNames"] = entry.attendeeNames
            }
            if !entry.attendeeEmails.isEmpty {
                record["attendeeEmails"] = entry.attendeeEmails
            }
            if !entry.speakerAliases.isEmpty {
                record["speakerAliases"] = entry.speakerAliases
            }
            if let conferencingURL = entry.conferencingURL?.nilIfEmpty {
                record["conferencingURL"] = conferencingURL
            }
            if let calendarName = entry.calendarName?.nilIfEmpty {
                record["calendarName"] = calendarName
            }
            if let recordingOrigin = entry.recordingOrigin?.rawValue {
                record["recordingOrigin"] = recordingOrigin
            }
            return record
        }
    }

    nonisolated private static func computeDailyWordCounts(_ entries: [DictationEntry], formatter: DateFormatter) -> [String: Int] {
        entries.reduce(into: [String: Int]()) { partialResult, entry in
            let key = formatter.string(from: entry.date)
            partialResult[key, default: 0] += entry.wordCount
        }
    }

    nonisolated private static func exportStats(dailyWordCounts: [String: Int]) -> [String: Any] {
        let formatter = makeDayFormatter()
        var stats: [String: Any] = [
            "totalWords": Defaults[.statsTotalWords],
            "totalDictations": Defaults[.statsTotalDictations],
            "longestDictation": Defaults[.statsLongestDictation],
            "streakDays": max(Defaults[.statsStreakDays], currentDayStreak(from: dailyWordCounts)),
        ]

        if let lastUsedDate = Defaults[.statsLastUsedDate] {
            stats["lastUsedDate"] = formatter.string(from: lastUsedDate)
        }

        return stats
    }

    nonisolated private static func loadMeetingMarkdownContent(for entry: MeetingEntry) -> String? {
        guard let markdownPath = entry.markdownPath?.nilIfEmpty else { return nil }
        let url: URL
        if markdownPath.hasPrefix("/") {
            url = URL(fileURLWithPath: markdownPath)
        } else {
            url = AppSupportPaths.resonantRoot().appendingPathComponent(markdownPath)
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

extension WorkspaceSyncEngine {
    typealias MeetingSettingsSnapshot = WorkspaceMeetingSettingsCodec.Snapshot

    nonisolated static func meetingSettingsSnapshot(from json: [String: Any]) -> MeetingSettingsSnapshot {
        WorkspaceMeetingSettingsCodec.decode(from: json)
    }

    @MainActor
    static func writeMeetingSettings(from settingsManager: SettingsManager, into json: inout [String: Any]) {
        WorkspaceMeetingSettingsCodec.encode(
            MeetingSettingsSnapshot(
                summarizationEnabled: settingsManager.meetingSummarizationEnabled,
                recordingEnabled: nil,
                joinPromptEnabled: nil,
                autoStartEnabled: nil,
                autoStopEnabled: nil,
                calendarHintsEnabled: nil,
                saveAudioEnabled: nil
            ),
            into: &json
        )
    }

    nonisolated private static func writeMeetingSettings(
        from snapshot: ExportSettingsSnapshot,
        into json: inout [String: Any]
    ) {
        WorkspaceMeetingSettingsCodec.encode(
            MeetingSettingsSnapshot(
                summarizationEnabled: snapshot.meetingSummarizationEnabled,
                recordingEnabled: nil,
                joinPromptEnabled: nil,
                autoStartEnabled: nil,
                autoStopEnabled: nil,
                calendarHintsEnabled: nil,
                saveAudioEnabled: nil
            ),
            into: &json
        )
    }

    @MainActor
    static func applyContinuouslyRoamingSettings(from snapshot: WorkspaceSnapshot, to settingsManager: SettingsManager) {
        if let pauseMediaWhileRecording = snapshot.pauseMediaWhileRecording,
           settingsManager.pauseMediaWhileRecording != pauseMediaWhileRecording {
            settingsManager.pauseMediaWhileRecording = pauseMediaWhileRecording
        }

        if let duckSystemAudioWhileRecording = snapshot.duckSystemAudioWhileRecording,
           settingsManager.duckSystemAudioWhileRecording != duckSystemAudioWhileRecording {
            settingsManager.duckSystemAudioWhileRecording = duckSystemAudioWhileRecording
        }

        if let meetingSummarizationEnabled = snapshot.meetingSummarizationEnabled,
           settingsManager.meetingSummarizationEnabled != meetingSummarizationEnabled {
            settingsManager.meetingSummarizationEnabled = meetingSummarizationEnabled
        }

    }

    nonisolated static func hotWordValue(from json: [String: Any]) -> String? {
        for key in Constants.legacyHotWordKeys {
            if let value = json[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated static func authTokenValue(from json: [String: Any]) -> String? {
        for key in Constants.legacyAuthTokenKeys {
            if let value = json[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated static func localDictationExternalID(for entryID: UUID) -> String {
        Constants.dictationExternalPrefix + entryID.uuidString.lowercased()
    }

    nonisolated static func localMemoExternalID(for memoID: UUID) -> String {
        Constants.memoExternalPrefix + memoID.uuidString.lowercased()
    }

    nonisolated static func workspaceRecordID(from externalID: String) -> String {
        if externalID.hasPrefix(Constants.dictationExternalPrefix) {
            return String(externalID.dropFirst(Constants.dictationExternalPrefix.count))
        }

        if externalID.hasPrefix(Constants.memoExternalPrefix) {
            return String(externalID.dropFirst(Constants.memoExternalPrefix.count))
        }

        return externalID
    }

}

private extension WorkspaceSyncEngine {
    struct ImportResult {
        var importedCount = 0
        var updatedCount = 0
        var importedDays: Set<Date> = []
        var syncStateChanged = false
        var hadFailure = false

        var didChange: Bool {
            importedCount > 0 || updatedCount > 0
        }
    }

    struct SyncState: Codable {
        var importedDictationIDs: [String] = []
        var importedMemoIDs: [String] = []
        var deletedMemoIDs: [String] = []
    }
}

struct WorkspaceSnapshot: Sendable {
    static let empty = WorkspaceSnapshot(
        onboardingCompleted: nil,
        triggerKey: nil,
        triggerKeys: nil,
        hotkeyMode: nil,
        sttModel: nil,
        removeFillerWords: nil,
        removeFalseStarts: nil,
        itnEnabled: nil,
        punctuationEnabled: nil,
        formatBulletPoints: nil,
        cloudProcessingEnabled: nil,
        selectionTransformEnabled: nil,
        journalSummarizationEnabled: nil,
        meetingSummarizationEnabled: nil,
        autoPaste: nil,
        copyToClipboard: nil,
        autoSend: nil,
        emailSignatureEnabled: nil,
        emailSignoffName: nil,
        triggerKeySoundEnabled: nil,
        triggerKeySoundVolume: nil,
        expressionSoundsEnabled: nil,
        expressionSoundsVolume: nil,
        overlayMode: nil,
        inputDeviceUID: nil,
        hotMicEnabled: nil,
        pauseMediaWhileRecording: nil,
        duckSystemAudioWhileRecording: nil,
        hotWord: nil,
        lowLatencyMode: nil,
        meetingRecordingEnabled: nil,
        meetingJoinPromptEnabled: nil,
        meetingAutoStartEnabled: nil,
        meetingAutoStopEnabled: nil,
        meetingUseCalendarHints: nil,
        meetingSaveAudio: nil,
        saveAudio: nil,
        saveContextMetadata: nil,
        historyRetentionDays: nil,
        hipaaMode: nil,
        launchAtLogin: nil,
        crashDiagnosticsEnabled: nil,
        analyticsEnabled: nil,
        authToken: nil,
        userId: nil,
        userEmail: nil,
        userDisplayName: nil,
        pinnedDisplayId: nil,
        smartLinks: [],
        hasSmartLinks: false,
        dictionaryWords: [],
        hasDictionaryWords: false,
        dictationHistory: [],
        voiceNotes: [],
        meetingHistory: [],
        stats: nil,
        dailyWordCounts: [:]
    )

    let onboardingCompleted: Bool?
    let triggerKey: String?
    let triggerKeys: [String]?
    let hotkeyMode: String?
    let sttModel: String?
    let removeFillerWords: Bool?
    let removeFalseStarts: Bool?
    let itnEnabled: Bool?
    let punctuationEnabled: Bool?
    let formatBulletPoints: Bool?
    let cloudProcessingEnabled: Bool?
    let selectionTransformEnabled: Bool?
    let journalSummarizationEnabled: Bool?
    let meetingSummarizationEnabled: Bool?
    let autoPaste: Bool?
    let copyToClipboard: Bool?
    let autoSend: Bool?
    let emailSignatureEnabled: Bool?
    let emailSignoffName: String?
    let triggerKeySoundEnabled: Bool?
    let triggerKeySoundVolume: Double?

    let expressionSoundsEnabled: Bool?
    let expressionSoundsVolume: Double?
    let overlayMode: String?
    let inputDeviceUID: String?
    let hotMicEnabled: Bool?
    let pauseMediaWhileRecording: Bool?
    let duckSystemAudioWhileRecording: Bool?
    let hotWord: String?
    let lowLatencyMode: Bool?
    let meetingRecordingEnabled: Bool?
    let meetingJoinPromptEnabled: Bool?
    let meetingAutoStartEnabled: Bool?
    let meetingAutoStopEnabled: Bool?
    let meetingUseCalendarHints: Bool?
    let meetingSaveAudio: Bool?
    let saveAudio: Bool?
    let saveContextMetadata: Bool?
    let historyRetentionDays: Int?
    let hipaaMode: Bool?
    let launchAtLogin: Bool?
    let crashDiagnosticsEnabled: Bool?
    let analyticsEnabled: Bool?
    let authToken: String?
    let userId: String?
    let userEmail: String?
    let userDisplayName: String?
    let pinnedDisplayId: Int?
    let smartLinks: [SmartLink]
    let hasSmartLinks: Bool
    let dictionaryWords: [DictionaryStore.WorkspaceWord]
    let hasDictionaryWords: Bool
    let dictationHistory: [DictationRecord]
    let voiceNotes: [VoiceNoteRecord]
    let meetingHistory: [MeetingRecord]
    let stats: StatsRecord?
    let dailyWordCounts: [String: Int]

    struct DictationRecord: Sendable {
        let id: String
        let text: String
        let sentText: String?
        let timestamp: String
        let app: String?
        let windowTitle: String?
        let url: String?
        let duration: Int?
    }

    struct VoiceNoteRecord: Sendable {
        let id: String
        let text: String
        let clarifiedText: String?
        let title: String?
        let timestamp: String
        let duration: Int?
        let hasAudio: Bool?
        let audioReference: String?
    }

    struct MeetingRecord: Sendable {
        let id: String
        let title: String?
        let timestamp: String
        let endedAt: String?
        let duration: Int?
        let wordCount: Int?
        let app: String?
        let notes: String?
        let postMeetingNotes: String?
        let summary: String?
        let markdown: String?
        let calendarEventID: String?
        let scheduledStartAt: String?
        let scheduledEndAt: String?
        let organizerName: String?
        let attendeeNames: [String]
        let attendeeEmails: [String]
        let speakerAliases: [String: String]
        let conferencingURL: String?
        let calendarName: String?
        let recordingOrigin: String?
        let hasCaptureMetadata: Bool
    }

    struct StatsRecord: Sendable {
        let totalWords: Int?
        let totalDictations: Int?
        let longestDictation: Int?
        let streakDays: Int?
        let lastUsedDate: String?
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
