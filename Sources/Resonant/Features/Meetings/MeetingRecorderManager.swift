@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Observation
import os
import SwiftData

/// Orchestrates meeting recording: detection → transcription → session storage → markdown export.
/// Owns the detector, transcription engine, session writer, and notepad.
/// Callbacks wired by AppState — same pattern as HotMicManager/DictationManager.
@MainActor
@Observable
final class MeetingRecorderManager {
    struct RecoveryResult: Sendable, Equatable {
        var recoveredCount = 0
        var missingCount = 0
        var recoveredWordCount = 0
    }

    // MARK: - Callbacks (wired by AppState)

    var onSessionStarted: ((MeetingSessionInfo) async -> Void)?
    var onSessionEnded: ((CompletedMeetingSession) async -> Void)?
    var onError: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSystemAudioSilent: (() -> Void)?
    var onSystemAudioRecovered: (() -> Void)?
    var onSystemAudioTransportDetected: ((MeetingAudioTransport) -> Void)?

    // MARK: - Observable State

    var isRecording: Bool { lifecycle.isRecording }
    var isFinalizing: Bool { lifecycle.isFinalizing }
    /// Set synchronously before the first `await` inside `startSession()` so
    /// that other entry points (e.g. `startDictation`) can detect an in-flight
    /// meeting startup and refuse to grab the mic during the race window.
    var isStartingSession: Bool { lifecycle.isStartingSession }
    var activeSession: MeetingSessionInfo? { lifecycle.activeSession }
    var recordingStartedAt: Date? { lifecycle.recordingStartedAt }
    private(set) var liveUtterances: [MeetingUtterance] = []
    private(set) var activeMicrophoneName: String?
    private(set) var activeMicrophoneUsesSystemDefault = true
    private(set) var lastUtteranceAt: Date?
    private(set) var systemAudioSilentSince: Date?
    private(set) var systemAudioStatus = "System audio"
    private(set) var captureMode: MeetingCaptureMode = .onlineCall

    /// Cap on the in-memory live transcript. The full transcript is always on
    /// disk via `MeetingSessionWriter`; this buffer is only what the panel renders.
    /// 500 ≈ ~30-40 minutes of two-speaker conversation; older lines drop off the
    /// view but persist in the JSONL.
    private static let liveUtteranceLimit = 500

    let notepad = MeetingNotepad()

    var recordingElapsed: TimeInterval {
        guard isRecording, let start = recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var isSystemAudioSilent: Bool {
        systemAudioSilentSince != nil
    }

    func secondsSinceLastUtterance(now: Date = Date()) -> TimeInterval? {
        guard let lastUtteranceAt else { return nil }
        return max(0, now.timeIntervalSince(lastUtteranceAt))
    }

    // MARK: - Private

    private var engine: MeetingTranscriptionEngine?
    private var sessionWriter: MeetingSessionWriter?
    private var audioRecorder: MeetingAudioRecorder?
    private var elapsedTimerTask: Task<Void, Never>?
    private var lifecycle = MeetingSessionLifecycle()
    private var workspaceClearPrepared = false

    private let log = Logger.resonant("MeetingRecorderManager")

    // MARK: - Init

    init() {}

    // MARK: - Session Lifecycle

    func startSession(
        detectedApp: MeetingApp? = nil,
        suggestedTitle: String? = nil,
        captureContext: MeetingCaptureContext? = nil,
        shouldContinue: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async {
        guard !workspaceClearPrepared, shouldContinue() else { return }
        guard lifecycle.beginStartingSession() else { return }
        defer { lifecycle.finishStartingSession() }

        let sessionID = UUID()
        let now = Date()
        let transcriptionBackendAtStart = SettingsManager.shared.meetingTranscriptionBackend.rawValue
        let resolvedCaptureMode = MeetingCaptureMode.resolve(
            detectedApp: detectedApp,
            captureContext: captureContext
        )

        // Create JSONL writer
        let writer: MeetingSessionWriter
        do {
            writer = try MeetingSessionWriter(sessionID: sessionID)
        } catch {
            log.error("Failed to create session writer: \(error.localizedDescription)")
            onError?("Could not start meeting recording.")
            return
        }
        sessionWriter = writer

        if SettingsManager.shared.meetingSaveAudio {
            do {
                let recorder = try MeetingAudioRecorder(sessionID: sessionID)
                recorder.onCaptureFailed = { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.onWarning?(message)
                    }
                }
                audioRecorder = recorder
            } catch {
                log.warning("Meeting audio capture unavailable: \(error.localizedDescription)")
                audioRecorder = nil
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail.isEmpty
                    ? "Meeting audio could not be saved. Continuing with transcript only."
                    : "Meeting audio could not be saved: \(detail). Continuing with transcript only."
                onWarning?(message)
            }
        } else {
            audioRecorder = nil
        }

        let jsonlRelativePath = await writer.relativePath
        guard shouldContinue(), !workspaceClearPrepared else {
            lifecycle.markStartFailed()
            _ = await writer.close()
            await writer.deleteFile()
            sessionWriter = nil
            audioRecorder?.discard()
            audioRecorder = nil
            return
        }

        let info = MeetingSessionInfo(
            id: sessionID,
            startedAt: now,
            detectedApp: detectedApp,
            suggestedTitle: (
                suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? captureContext?.effectiveTitle
            ),
            captureContext: captureContext,
            captureMode: resolvedCaptureMode,
            transcriptionBackendAtStart: transcriptionBackendAtStart,
            jsonlRelativePath: jsonlRelativePath,
            jsonlURL: AppSupportPaths.resonantRoot()
                .appendingPathComponent(jsonlRelativePath)
        )

        lifecycle.markRecordingStarted(info)
        liveUtterances = []
        activeMicrophoneName = nil
        activeMicrophoneUsesSystemDefault = true
        lastUtteranceAt = nil
        systemAudioSilentSince = nil
        captureMode = resolvedCaptureMode
        systemAudioStatus = resolvedCaptureMode == .room ? "Room audio" : "System audio"
        notepad.onChange = nil
        notepad.clear()

        // Start transcription engine
        let transcriptionEngine = MeetingTranscriptionEngine()
        transcriptionEngine.onUtterance = { [weak self, weak writer] utterance in
            if let self {
                self.lastUtteranceAt = Date()
                self.liveUtterances.append(utterance)
                self.log.info("Live meeting utterance appended speaker=\(utterance.speaker.storageKey, privacy: .public) words=\(utterance.text.split(separator: " ").count, privacy: .public) live_count=\(self.liveUtterances.count, privacy: .public)")
                let limit = Self.liveUtteranceLimit
                if self.liveUtterances.count > limit {
                    self.liveUtterances.removeFirst(self.liveUtterances.count - limit)
                }
            }
            guard let writer else { return }
            Task {
                await writer.append(utterance)
            }
        }
        transcriptionEngine.onFatalError = { [weak self] message in
            self?.onError?(message)
        }
        transcriptionEngine.onSystemAudioSilent = { [weak self] in
            if self?.systemAudioSilentSince == nil {
                self?.systemAudioSilentSince = Date()
            }
            self?.onSystemAudioSilent?()
        }
        transcriptionEngine.onSystemAudioRecovered = { [weak self] in
            self?.systemAudioSilentSince = nil
            self?.onSystemAudioRecovered?()
        }
        transcriptionEngine.onWarning = { [weak self] message in
            self?.onWarning?(message)
        }
        transcriptionEngine.onMicrophoneInputChanged = { [weak self] name, usesSystemDefault in
            guard let self else { return }
            self.activeMicrophoneName = name
            self.activeMicrophoneUsesSystemDefault = usesSystemDefault
            self.log.notice("Meeting microphone route active name=\(name, privacy: .public) system_default=\(usesSystemDefault, privacy: .public)")
        }
        engine = transcriptionEngine

        do {
            let meetingInputDeviceUID = SettingsManager.shared.meetingUseSelectedMicrophone
                ? SettingsManager.shared.inputDeviceUID
                : nil
            try await transcriptionEngine.start(
                inputDeviceUID: meetingInputDeviceUID,
                audioRecorder: audioRecorder,
                captureMode: resolvedCaptureMode,
                sessionStartedAt: now
            )
            if workspaceClearPrepared || !shouldContinue() {
                await discardSession()
                return
            }
            if let transport = transcriptionEngine.systemTransport {
                systemAudioStatus = transport.displayLabel
                onSystemAudioTransportDetected?(transport)
            }
        } catch {
            let shouldReportFailure = shouldContinue() && !workspaceClearPrepared
            log.error("Failed to start transcription: \(error.localizedDescription)")
            lifecycle.markStartFailed()
            activeMicrophoneName = nil
            activeMicrophoneUsesSystemDefault = true
            lastUtteranceAt = nil
            systemAudioSilentSince = nil
            systemAudioStatus = "System audio"
            captureMode = .onlineCall
            await transcriptionEngine.teardown()
            engine = nil
            if let writer = sessionWriter {
                _ = await writer.close()
                await writer.deleteFile()
            }
            sessionWriter = nil
            audioRecorder?.discard()
            audioRecorder = nil
            if shouldReportFailure {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                onError?(detail.isEmpty ? "Could not start meeting transcription." : detail)
            }
            return
        }

        // Elapsed timer for notch display
        elapsedTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRecording else { break }
                // Touch to trigger observation update
                _ = self.recordingElapsed
            }
        }

        log.info("Meeting session started: \(sessionID.uuidString)")
        await onSessionStarted?(info)
    }

    func endSession() async {
        guard let session = lifecycle.beginEndingSession() else {
            // Defensive cleanup even if state is inconsistent
            return
        }

        // Stop elapsed timer
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil

        // Teardown transcription engine (strict order)
        if let transcriptionEngine = engine {
            await transcriptionEngine.teardown()
        }
        engine = nil

        // Close session writer and get utterances
        let utterances: [MeetingUtterance]
        if let writer = sessionWriter {
            utterances = await writer.close()
        } else {
            utterances = []
        }
        let expectedAudio = audioRecorder != nil
        let recordingURL = audioRecorder?.finish()
        let shouldDeleteRecordingAfterSave = recordingURL != nil
        if expectedAudio && recordingURL == nil {
            // Init succeeded but finish() dropped the file — the recorder's
            // onCaptureFailed already fired for write/mix errors. This branch
            // also catches the "no samples captured" case, where the user gets
            // no warning otherwise.
            onWarning?("Meeting audio was not saved. Recording captured no audio.")
        }

        let completed = CompletedMeetingSession(
            id: session.id,
            startedAt: session.startedAt,
            endedAt: Date(),
            detectedApp: session.detectedApp,
            suggestedTitle: session.suggestedTitle,
            captureContext: session.captureContext,
            speakerAliases: [:],
            utterances: utterances,
            liveNotes: notepad.liveNotes,
            postMeetingNotes: notepad.postMeetingNotes,
            recordingURL: recordingURL,
            shouldDeleteRecordingAfterSave: shouldDeleteRecordingAfterSave
        )

        log.info("Meeting session ended: \(session.id.uuidString) — \(utterances.count) utterances, \(completed.wordCount) words")

        notepad.onChange = nil
        lifecycle.detachFinalizedSession()
        activeMicrophoneName = nil
        activeMicrophoneUsesSystemDefault = true
        lastUtteranceAt = nil
        systemAudioSilentSince = nil
        systemAudioStatus = "System audio"
        captureMode = .onlineCall
        // Drop the live transcript snapshot now that `completed` owns it; the
        // notepad is intentionally NOT cleared here because `onSessionEnded`
        // drives the post-meeting processing UI through `notepad.processingStages`,
        // which `notepad.clear()` would wipe. Stale notes/transcript bleeding
        // into the next session's detection prompt is suppressed in the View
        // (`MeetingScratchpadView` hides notes/transcript while phase == .detecting),
        // and `startSession` calls `notepad.clear()` before the next meeting boots.
        liveUtterances = []

        await onSessionEnded?(completed)

        // Hold `isFinalizing` true through the callback so a fast restart
        // (manual or auto-detect) cannot interleave a new session with the
        // old one's persistence/UI mutations. `startMeetingRecording` gates
        // on this flag.
        lifecycle.finishFinalizingSession()

        // Clean up JSONL after successful finalization
        if let writer = sessionWriter {
            await writer.deleteFile()
        }
        sessionWriter = nil
        audioRecorder = nil
    }

    /// Manual discard — stop without saving.
    func discardSession() async {
        guard lifecycle.beginDiscardingSession() != nil else { return }

        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil

        if let transcriptionEngine = engine {
            await transcriptionEngine.teardown()
        }
        engine = nil

        if let writer = sessionWriter {
            _ = await writer.close()
            await writer.deleteFile()
        }
        sessionWriter = nil
        audioRecorder?.discard()
        audioRecorder = nil

        lifecycle.finishDiscardingSession()
        notepad.onChange = nil
        liveUtterances = []
        activeMicrophoneName = nil
        activeMicrophoneUsesSystemDefault = true
        lastUtteranceAt = nil
        systemAudioSilentSince = nil
        systemAudioStatus = "System audio"
        captureMode = .onlineCall
        notepad.clear()

        log.info("Meeting session discarded")
    }

    /// Closes the meeting persistence boundary before workspace deletion.
    /// Existing start/finalization work is allowed to settle, then any live
    /// recording is discarded without invoking `onSessionEnded`. New sessions
    /// remain gated until `finishWorkspaceClear()` is called.
    func prepareForWorkspaceClear() async {
        workspaceClearPrepared = true

        while lifecycle.isStartingSession || lifecycle.isFinalizing {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if lifecycle.isRecording {
            await discardSession()
        }
    }

    func finishWorkspaceClear() {
        workspaceClearPrepared = false
    }

    // MARK: - Audio File Import

    /// Import a pre-recorded audio file and transcribe it through the meeting pipeline.
    /// Returns `true` if the import produced a completed session, `false` on any failure.
    @discardableResult
    func importAudioFile(url: URL, captureContext: MeetingCaptureContext? = nil) async -> Bool {
        guard !workspaceClearPrepared else { return false }
        guard lifecycle.beginImport() else {
            onError?("Cannot import while a meeting is recording.")
            return false
        }

        let backendKindAtStart = SettingsManager.shared.meetingTranscriptionBackend
        let transcriptionBackendAtStart = backendKindAtStart.rawValue
        let importedTitle = url.deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let resolvedCaptureContext = captureContext ?? .adHoc(
            title: importedTitle,
            recordingOrigin: .importedAudio
        )
        let startedAt = resolvedCaptureContext.scheduledStartAt ?? Date()
        log.info("Importing audio file: \(url.lastPathComponent)")

        let sessionID = UUID()
        let writer: MeetingSessionWriter
        do {
            writer = try MeetingSessionWriter(sessionID: sessionID)
        } catch {
            log.error("Failed to create session writer for import: \(error.localizedDescription)")
            onError?("Could not start import.")
            lifecycle.finishImport()
            return false
        }

        do {
            guard MeetingBackendDownloader.isDownloaded(backendKindAtStart) else {
                throw MeetingTranscriptionBackendError.modelNotDownloaded(backendKindAtStart)
            }
            let backend = MeetingBackendFactory.make(backendKindAtStart)
            try await backend.prepare { [weak self] status in
                self?.log.info("Import backend: \(status)")
            }
            defer { Task { await backend.tearDown() } }
            let vad = try await Task.detached(priority: .userInitiated) {
                try DictationVADSegmenter.makeCachedManager()
            }.value
            let diarizer = MeetingSpeakerDiarizer()
            defer { diarizer.cleanup() }
            do {
                try await diarizer.prepare(allowDownload: false)
            } catch {
                log.warning("Import speaker diarization unavailable: \(error.localizedDescription)")
                onWarning?(MeetingSpeakerDiarizer.unavailableWarningMessage())
            }

            let bufferStream = try Self.decodeAudioFile(url: url)
            let importedAudioDuration = try Self.audioDuration(url: url)
            let jsonlRelativePath = await writer.relativePath
            let info = MeetingSessionInfo(
                id: sessionID,
                startedAt: startedAt,
                detectedApp: nil,
                suggestedTitle: resolvedCaptureContext.effectiveTitle ?? importedTitle,
                captureContext: resolvedCaptureContext,
                captureMode: .importedAudio,
                transcriptionBackendAtStart: transcriptionBackendAtStart,
                jsonlRelativePath: jsonlRelativePath,
                jsonlURL: AppSupportPaths.resonantRoot()
                    .appendingPathComponent(jsonlRelativePath)
            )

            let transcriber = MeetingStreamingTranscriber(
                backend: backend,
                locale: MeetingTranscriptionEngine.locale(
                    forTranscriptionLanguage: SettingsManager.shared.transcriptionLanguage
                ),
                vadManager: vad,
                speaker: MeetingSpeaker.participant(id: "SPEAKER_0"),
                diarizer: diarizer
            ) { (text: String, speaker: MeetingSpeaker, segmentStartOffset: TimeInterval) in
                let timestamp = startedAt.addingTimeInterval(segmentStartOffset)
                Task {
                    await writer.append(MeetingUtterance(text: text, speaker: speaker, timestamp: timestamp))
                }
            }

            await onSessionStarted?(info)
            await transcriber.run(stream: bufferStream)

            let utterances = await writer.close()
            let endedAt = resolvedCaptureContext.scheduledEndAt.flatMap { $0 >= startedAt ? $0 : nil }
                ?? startedAt.addingTimeInterval(importedAudioDuration)

            let completed = CompletedMeetingSession(
                id: sessionID,
                startedAt: startedAt,
                endedAt: endedAt,
                detectedApp: nil,
                suggestedTitle: resolvedCaptureContext.effectiveTitle ?? importedTitle,
                captureContext: resolvedCaptureContext,
                speakerAliases: [:],
                utterances: utterances,
                liveNotes: "",
                postMeetingNotes: "",
                recordingURL: SettingsManager.shared.meetingSaveAudio ? url : nil,
                shouldDeleteRecordingAfterSave: false
            )

            log.info("Import complete: \(utterances.count) utterances, \(completed.wordCount) words")
            await onSessionEnded?(completed)

            // Match live session finalization: keep the lifecycle gate closed
            // until persistence/UI callbacks finish so another session cannot
            // interleave with import completion.
            lifecycle.finishImport()
            await writer.deleteFile()
            return true
        } catch {
            lifecycle.finishImport()
            log.error("Import failed: \(error.localizedDescription)")
            onError?("Import failed: \(error.localizedDescription)")
            _ = await writer.close()
            await writer.deleteFile()
            return false
        }
    }

    /// Decode an audio file to a stream of 16kHz mono Float32 buffers.
    private static func decodeAudioFile(url: URL) throws -> AsyncStream<AVAudioPCMBuffer> {
        let file = try AVAudioFile(forReading: url)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        return AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
                    continuation.finish()
                    return
                }

                let sourceFrameCapacity: AVAudioFrameCount = 8192
                let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
                let outputCapacity = AVAudioFrameCount(Double(sourceFrameCapacity) * ratio) + 64

                while file.framePosition < file.length {
                    guard let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: targetFormat,
                        frameCapacity: outputCapacity
                    ) else { break }

                    var error: NSError?
                    nonisolated(unsafe) var didProvideInput = false

                    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                        if didProvideInput {
                            outStatus.pointee = .endOfStream
                            return nil
                        }
                        guard let readBuffer = AVAudioPCMBuffer(
                            pcmFormat: file.processingFormat,
                            frameCapacity: sourceFrameCapacity
                        ) else {
                            outStatus.pointee = .endOfStream
                            return nil
                        }
                        do {
                            try file.read(into: readBuffer)
                            guard readBuffer.frameLength > 0 else {
                                outStatus.pointee = .endOfStream
                                return nil
                            }
                            didProvideInput = true
                            outStatus.pointee = .haveData
                            return readBuffer
                        } catch {
                            outStatus.pointee = .endOfStream
                            return nil
                        }
                    }

                    if let error {
                        print("[MeetingRecorderManager] Audio decode error: \(error)")
                        break
                    }

                    if outputBuffer.frameLength > 0 {
                        continuation.yield(outputBuffer)
                    } else {
                        break
                    }
                }

                continuation.finish()
            }
        }
    }

    private static func audioDuration(url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - Shutdown

    /// Called synchronously from AppState.shutdown(). Flushes the JSONL file handle.
    /// The JSONL remains on disk for crash recovery on next launch.
    func flushActiveSession() {
        guard let writer = sessionWriter else { return }
        Task.detached(priority: .utility) {
            await writer.flush()
        }
    }

    func teardown() async {
        if isRecording {
            await endSession()
        }
    }

    // MARK: - Crash Recovery

    func recoverOrphanedSessions(
        dataStore: DataStore,
        archiveWriter: ArchiveWriter
    ) async -> RecoveryResult {
        let descriptor = FetchDescriptor<MeetingEntry>(
            predicate: #Predicate { $0.activeJSONLPath != nil }
        )
        let orphans = await dataStore.fetchInBackground(descriptor)
        guard !orphans.isEmpty else { return RecoveryResult() }

        log.info("Found \(orphans.count) orphaned meeting session(s) — recovering")
        var result = RecoveryResult()

        for entry in orphans {
            guard let path = entry.activeJSONLPath else { continue }
            let entryID = entry.id
            let url = AppSupportPaths.resonantRoot().appendingPathComponent(path)

            if FileManager.default.fileExists(atPath: url.path) {
                let utterances = MeetingSessionWriter.reconstruct(from: url)

                let completed = CompletedMeetingSession(
                    id: entry.id,
                    startedAt: entry.startedAt,
                    endedAt: recoveredEndDate(for: entry, url: url),
                    detectedApp: entry.detectedApp.map { MeetingApp(bundleID: "", name: $0) },
                    suggestedTitle: entry.customTitle,
                    captureContext: entry.captureContext,
                    speakerAliases: entry.speakerAliases,
                    utterances: utterances,
                    liveNotes: entry.userNotes ?? "",
                    postMeetingNotes: entry.postMeetingNotes ?? "",
                    recordingURL: nil,
                    shouldDeleteRecordingAfterSave: false
                )

                let recoveredEntry = MeetingEntry(
                    id: entryID,
                    startedAt: entry.startedAt,
                    endedAt: completed.endedAt,
                    detectedApp: entry.detectedApp,
                    customTitle: entry.customTitle,
                    durationSeconds: completed.durationSeconds,
                    wordCount: completed.wordCount,
                    markdownPath: entry.markdownPath,
                    audioPath: entry.audioPath,
                    activeJSONLPath: nil,
                    userNotes: entry.userNotes,
                    postMeetingNotes: entry.postMeetingNotes,
                    summary: entry.summary,
                    calendarEventID: entry.calendarEventID,
                    scheduledStartAt: entry.scheduledStartAt,
                    scheduledEndAt: entry.scheduledEndAt,
                    organizerName: entry.organizerName,
                    attendeeNamesJSON: entry.attendeeNamesJSON,
                    attendeeEmailsJSON: entry.attendeeEmailsJSON,
                    speakerAliasesJSON: entry.speakerAliasesJSON,
                    conferencingURL: entry.conferencingURL,
                    calendarName: entry.calendarName,
                    recordingOriginRaw: entry.recordingOriginRaw
                )

                await archiveWriter.writeMeeting(session: completed, entry: recoveredEntry)
                let recoveredAudioPath = recoveredEntry.audioPath
                let recoveredMarkdownPath = recoveredEntry.markdownPath
                _ = await dataStore.performBackgroundWrite { context in
                    var descriptor = FetchDescriptor<MeetingEntry>(
                        predicate: #Predicate { $0.id == entryID }
                    )
                    descriptor.fetchLimit = 1
                    guard let persisted = try? context.fetch(descriptor).first else { return }
                    persisted.endedAt = completed.endedAt
                    persisted.wordCount = completed.wordCount
                    persisted.durationSeconds = completed.durationSeconds
                    persisted.activeJSONLPath = nil
                    persisted.audioPath = recoveredAudioPath
                    persisted.markdownPath = recoveredMarkdownPath
                }
                await Self.removeFileOffMain(url)
                // TODO: rebuild a mixed audio file from the mic/system stems
                // when `meetingSaveAudio` was on. For now we drop the audio
                // (transcript already recovered) and clean the stems so they
                // don't leak on disk.
                Self.removeOrphanedMeetingAudioStems(sessionID: entryID)

                log.info("Recovered orphaned session: \(entry.id.uuidString) — \(utterances.count) utterances")
                result.recoveredCount += 1
                result.recoveredWordCount += completed.wordCount
            } else {
                // JSONL gone — stub the entry
                _ = await dataStore.performBackgroundWrite { context in
                    var descriptor = FetchDescriptor<MeetingEntry>(
                        predicate: #Predicate { $0.id == entryID }
                    )
                    descriptor.fetchLimit = 1
                    guard let persisted = try? context.fetch(descriptor).first else { return }
                    persisted.endedAt = persisted.startedAt
                    persisted.durationSeconds = 0
                    persisted.activeJSONLPath = nil
                }
                Self.removeOrphanedMeetingAudioStems(sessionID: entryID)
                log.warning("Orphaned session JSONL missing: \(entry.id.uuidString)")
                result.missingCount += 1
            }
        }

        return result
    }

    // MARK: - Audio Levels (for notch display)

    var micLevel: Float {
        engine?.micLevel ?? 0
    }

    var systemLevel: Float {
        engine?.systemLevel ?? 0
    }

    private nonisolated static func removeFileOffMain(_ url: URL) async {
        await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }.value
    }

    /// Removes the per-channel mic/system/mix WAV files that `MeetingAudioRecorder`
    /// writes under `meetings-active/audio/` for an in-progress meeting. Called
    /// from crash recovery so a killed app doesn't leak audio stems on disk.
    private static func removeOrphanedMeetingAudioStems(sessionID: UUID) {
        let baseName = sessionID.uuidString.lowercased()
        let root = AppSupportPaths.resonantRoot()
            .appendingPathComponent("meetings-active/audio", isDirectory: true)
        for suffix in ["-mic.wav", "-system.wav", "-mix.wav"] {
            let url = root.appendingPathComponent(baseName + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func rebindActiveSession(
        to captureContext: MeetingCaptureContext,
        suggestedTitle: String? = nil
    ) {
        _ = lifecycle.rebindActiveSession(
            to: captureContext,
            suggestedTitle: suggestedTitle
        )
    }

    func switchMicrophoneInput(to inputDeviceUID: String?) {
        activeMicrophoneName = nil
        activeMicrophoneUsesSystemDefault = inputDeviceUID == nil
        engine?.switchMicrophoneInput(to: inputDeviceUID)
    }

    private func recoveredEndDate(for entry: MeetingEntry, url: URL) -> Date {
        if let endedAt = entry.endedAt {
            return endedAt
        }

        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let modifiedAt = values.contentModificationDate,
           modifiedAt >= entry.startedAt {
            return modifiedAt
        }

        return max(entry.startedAt, Date())
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
