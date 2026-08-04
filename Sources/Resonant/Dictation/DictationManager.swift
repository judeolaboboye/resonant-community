import Foundation
import AppKit
import os

@MainActor
private final class DictationCancellationToken {
    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    func check() throws {
        if isCancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }
}

/// Orchestrates: start recording → stop → transcribe → post-process → return result.
/// Knows only about Transcriber protocol — never about FluidAudio directly.
@MainActor
final class DictationManager {

    typealias CanonicalAudioLoader = @Sendable (URL) async throws -> [Float]

    private let log = Logger.resonant("DictationManager")

    private let audioRecorder: AudioRecorder
    private let modelRegistry: ModelRegistry
    private let postProcessor: PostProcessor
    private let contextExtractor: ContextExtractor
    private let personalizationLearningEngine: PersonalizationLearningEngine?
    private let canonicalAudioLoader: CanonicalAudioLoader

    private var recordingURL: URL?
    private var recordingStart: Date?
    private(set) var lastCaptureDiagnostics: DictationCaptureDiagnostics?
    /// Wall-clock length of the most recent capture, kept alongside
    /// `lastCaptureDiagnostics` so callers can tell a short press from a
    /// device that stopped delivering audio mid-recording.
    private(set) var lastCaptureWallDurationSeconds: TimeInterval?
    private(set) var lastSilenceDiagnostics: DictationAudioAnalyzer.Diagnostics?
    /// Which stage produced `lastSilenceDiagnostics`: "pre_transcription_gate"
    /// (audio rejected before ASR ran) or "post_transcription" (ASR ran and
    /// returned nothing). Telemetry needs the split — the two have different
    /// fixes — and dB heuristics can't reconstruct it after the fact.
    private(set) var lastSilenceDiagnosticsReason: String?
    private(set) var lastFailureDiscardedRecording = false
    private(set) var lastFailedRecordingStash: FailedRecordingStash?
    private var activeCancellationToken: DictationCancellationToken?
    private var activePipeline: (id: UUID, task: Task<TranscriptionResult, Error>)?

    /// Whether the most recent recording used a warm capture session. Reset on next start.
    var lastDidUseWarmSession: Bool { audioRecorder.didUseWarmSession }

    /// Integrity of the most recent capture: how much of the wall-clock
    /// recording actually reached the file. `.intact` when unknown (no capture
    /// yet, or diagnostics unavailable).
    var lastCaptureIntegrity: DictationCaptureIntegrity {
        guard let wallSeconds = lastCaptureWallDurationSeconds,
              let diagnostics = lastCaptureDiagnostics else {
            return .intact
        }
        return DictationCaptureIntegrityPolicy.assessment(
            wallSeconds: wallSeconds,
            capturedSeconds: diagnostics.duration
        )
    }

    init(
        audioRecorder: AudioRecorder,
        modelRegistry: ModelRegistry,
        postProcessor: PostProcessor,
        contextExtractor: ContextExtractor,
        personalizationLearningEngine: PersonalizationLearningEngine? = nil,
        canonicalAudioLoader: @escaping CanonicalAudioLoader = { url in
            try await DictationManager.loadCanonicalAudio(from: url)
        }
    ) {
        self.audioRecorder = audioRecorder
        self.modelRegistry = modelRegistry
        self.postProcessor = postProcessor
        self.contextExtractor = contextExtractor
        self.personalizationLearningEngine = personalizationLearningEngine
        self.canonicalAudioLoader = canonicalAudioLoader
    }

    nonisolated private static func loadCanonicalAudio(from url: URL) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) {
            try DictationAudioAnalyzer.loadMono16kSamples(from: url)
        }.value
    }

    // MARK: - Recording

    @discardableResult
    func startRecording(
        selectedInputDeviceUID: String?,
        outputURL: URL? = nil,
        recordingRetention: DictationRecordingRetentionPolicy = .recoverable
    ) async throws -> URL {
        guard activePipeline == nil else {
            throw AudioRecorderError.startFailed
        }
        recordingStart = Date()
        lastCaptureDiagnostics = nil
        lastCaptureWallDurationSeconds = nil
        lastSilenceDiagnostics = nil
        lastSilenceDiagnosticsReason = nil
        lastFailureDiscardedRecording = false
        lastFailedRecordingStash = nil
        SentryManager.shared.dictationStart()
        let url = try await audioRecorder.start(
            selectedInputDeviceUID: selectedInputDeviceUID,
            outputURL: outputURL,
            recordingRetention: recordingRetention
        )
        recordingURL = url
        return url
    }

    func stopAndTranscribe(
        targetApplication: NSRunningApplication?,
        preloadedHotContext: Task<ContextExtractor.HotContext, Never>? = nil,
        activeRecipientContext: ActiveRecipientContext? = nil,
        fallbackSelectedText: String? = nil,
        fallbackSelectedRange: SelectionRange? = nil,
        extractColdContext: Bool = true,
        latencyLogger: DictationLatencyLogger? = nil,
        onCaptureStopped: (() -> Void)? = nil,
        onModelWaitBegan: (() -> Void)? = nil,
        recordingRetention: DictationRecordingRetentionPolicy = .recoverable
    ) async throws -> TranscriptionResult {
        if let activePipeline {
            return try await activePipeline.task.value
        }

        let pipelineID = UUID()
        let task = Task { @MainActor [self] in
            try await performStopAndTranscribe(
                targetApplication: targetApplication,
                preloadedHotContext: preloadedHotContext,
                activeRecipientContext: activeRecipientContext,
                fallbackSelectedText: fallbackSelectedText,
                fallbackSelectedRange: fallbackSelectedRange,
                extractColdContext: extractColdContext,
                latencyLogger: latencyLogger,
                onCaptureStopped: onCaptureStopped,
                onModelWaitBegan: onModelWaitBegan,
                recordingRetention: recordingRetention
            )
        }
        activePipeline = (pipelineID, task)
        defer {
            if activePipeline?.id == pipelineID {
                activePipeline = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Re-runs the full transcription pipeline on an already-captured clip —
    /// the retry affordance for a failed dictation. The pre-transcription
    /// speech gate is bypassed: the user has explicitly vouched for the audio,
    /// so the recognizer gets a full chance even where the gate would reject.
    func retryTranscribeRecordedClip(
        at url: URL,
        duration: TimeInterval,
        targetApplication: NSRunningApplication?,
        latencyLogger: DictationLatencyLogger? = nil,
        onModelWaitBegan: (() -> Void)? = nil
    ) async throws -> TranscriptionResult {
        if let activePipeline {
            return try await activePipeline.task.value
        }

        let pipelineID = UUID()
        let task = Task { @MainActor [self] in
            try await performStopAndTranscribe(
                targetApplication: targetApplication,
                preloadedHotContext: nil,
                activeRecipientContext: nil,
                fallbackSelectedText: nil,
                fallbackSelectedRange: nil,
                extractColdContext: true,
                latencyLogger: latencyLogger,
                onCaptureStopped: nil,
                onModelWaitBegan: onModelWaitBegan,
                recordingRetention: .recoverable,
                acquireRecording: { url },
                recordedDurationOverride: duration,
                bypassesPreTranscriptionGate: true,
                deletesRecordingOnCancellation: false
            )
        }
        activePipeline = (pipelineID, task)
        defer {
            if activePipeline?.id == pipelineID {
                activePipeline = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performStopAndTranscribe(
        targetApplication: NSRunningApplication?,
        preloadedHotContext: Task<ContextExtractor.HotContext, Never>?,
        activeRecipientContext: ActiveRecipientContext?,
        fallbackSelectedText: String?,
        fallbackSelectedRange: SelectionRange?,
        extractColdContext: Bool,
        latencyLogger: DictationLatencyLogger?,
        onCaptureStopped: (() -> Void)?,
        onModelWaitBegan: (() -> Void)? = nil,
        recordingRetention: DictationRecordingRetentionPolicy,
        acquireRecording: (() async throws -> URL?)? = nil,
        recordedDurationOverride: TimeInterval? = nil,
        bypassesPreTranscriptionGate: Bool = false,
        deletesRecordingOnCancellation: Bool = true
    ) async throws -> TranscriptionResult {
        let cancellationToken = DictationCancellationToken()
        activeCancellationToken = cancellationToken
        defer {
            if activeCancellationToken === cancellationToken {
                activeCancellationToken = nil
            }
        }

        latencyLogger?.mark("captureStopStart")
        let acquiredURL: URL?
        if let acquireRecording {
            acquiredURL = try await acquireRecording()
        } else {
            acquiredURL = try await audioRecorder.stop()
        }
        guard let url = acquiredURL else {
            throw DictationError.noRecording
        }
        var pipelineCompletedSuccessfully = false
        defer {
            if recordingRetention.deletesRecordingWhenPipelineExits {
                try? FileManager.default.removeItem(at: url)
                if !pipelineCompletedSuccessfully {
                    lastFailureDiscardedRecording = !FileManager.default.fileExists(atPath: url.path)
                }
            }
        }
        var coldTask: Task<ContextExtractor.ColdContext, Never>?
        do {
            try cancellationToken.check()
        } catch {
            if deletesRecordingOnCancellation {
                _ = DictationRecordingFileDeletion.removeIfPresent(url)
            }
            throw error
        }
        latencyLogger?.mark("captureStopEnd")
        onCaptureStopped?()

        let duration = recordedDurationOverride ?? Date().timeIntervalSince(recordingStart ?? Date())
        recordingURL = nil
        recordingStart = nil
        let estimatedCaptureDiagnostics: DictationCaptureDiagnostics
        do {
            estimatedCaptureDiagnostics = try await Task.detached(priority: .userInitiated) {
                try TranscriberAudioSupport.captureDiagnostics(from: url)
            }.value
        } catch {
            let captureError = AudioRecorderError.finishFailed("recording file could not be read")
            SentryManager.shared.micCaptureError(captureError)
            throw captureError
        }
        guard let transcriber = modelRegistry.active else {
            throw DictationError.noModelSelected
        }
        // The capture was accepted while the model was still preparing (launch/
        // wake bursts). The audio is safely on disk — wait briefly for the
        // in-flight registry load instead of failing the user's words, and
        // avoid racing it with the transcriber's own self-load.
        if !transcriber.isLoaded, modelRegistry.preparationState.isPreparing {
            onModelWaitBegan?()
            latencyLogger?.mark("modelWaitStart")
            let deadline = Date().addingTimeInterval(DictationModelReadinessPolicy.stopWaitSeconds)
            while DictationModelReadinessPolicy.shouldKeepWaiting(
                isLoaded: transcriber.isLoaded,
                isPreparing: modelRegistry.preparationState.isPreparing,
                now: Date(),
                deadline: deadline
            ) {
                try cancellationToken.check()
                try? await Task.sleep(nanoseconds: DictationModelReadinessPolicy.pollIntervalNanoseconds)
            }
            latencyLogger?.mark("modelWaitEnd")
        }
        let canonicalSamples: [Float]?
        do {
            canonicalSamples = try await DictationAudioRouting.loadCanonicalSamplesIfNeeded(
                from: url,
                estimatedSampleCount: estimatedCaptureDiagnostics.sampleCount,
                supportsDiskBackedURLTranscription: transcriber.supportsDiskBackedURLTranscription,
                loader: canonicalAudioLoader
            )
        } catch is CancellationError {
            if deletesRecordingOnCancellation {
                _ = DictationRecordingFileDeletion.removeIfPresent(url)
            }
            throw CancellationError()
        } catch {
            let captureError = AudioRecorderError.finishFailed("recording file could not be decoded")
            SentryManager.shared.micCaptureError(captureError)
            throw captureError
        }
        try cancellationToken.check()

        let captureDiagnostics = DictationCaptureDiagnostics(
            sampleCount: canonicalSamples?.count ?? estimatedCaptureDiagnostics.sampleCount,
            sampleRate: DictationAudioAnalyzer.sampleRate
        )
        latencyLogger?.mark("captureDiagnosticsEnd")
        lastCaptureDiagnostics = captureDiagnostics
        lastCaptureWallDurationSeconds = duration
        let settings = SettingsManager.shared
        let captureRichContext = settings.contextMetadataEnabled
        let language = settings.transcriptionLanguage
        let lowLatencyMode = settings.lowLatencyMode

        log.info(
            "Dictation capture duration_s=\(duration, privacy: .public) captured_duration_ms=\(captureDiagnostics.durationMilliseconds, privacy: .public) captured_samples=\(captureDiagnostics.sampleCount, privacy: .public)"
        )

        guard captureDiagnostics.sampleCount > 0 else {
            let captureError = AudioRecorderError.finishFailed("recording file contained no audio")
            SentryManager.shared.micCaptureError(captureError)
            discardFailedRecording(at: url)
            throw captureError
        }

        do {
            var recognitionDiagnostics: DictationAudioAnalyzer.Diagnostics?
            if let canonicalSamples {
                do {
                    let gateDiagnostics = try await Task.detached(priority: .userInitiated) {
                        try DictationAudioAnalyzer.preTranscriptionGateDiagnostics(
                            audioSamples: canonicalSamples
                        )
                    }.value
                    recognitionDiagnostics = gateDiagnostics
                    if !bypassesPreTranscriptionGate,
                       DictationAudioAnalyzer.shouldRejectBeforeTranscription(gateDiagnostics) {
                        recordSilenceDiagnostics(
                            gateDiagnostics,
                            duration: duration,
                            reason: "pre_transcription_gate"
                        )
                        throw DictationError.emptyTranscription
                    }
                } catch DictationError.emptyTranscription {
                    throw DictationError.emptyTranscription
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    log.debug("Pre-transcription speech gate unavailable: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                log.info("Skipping full-buffer speech gate for disk-backed long-form capture")
            }

            // Hot context: prefer the preloaded handle so the extract has run
            // during speech and the stop path is a cache read. Falls back to a
            // fresh extract if no preload exists.
            let extractor = self.contextExtractor
            let hotContextTask: Task<ContextExtractor.HotContext, Never> = preloadedHotContext
                ?? Task.detached(priority: .userInitiated) {
                    await extractor.extractHot(from: targetApplication)
                }

            // Start rich context as soon as hot context is available so the
            // tree walk can overlap transcription. It is only used for output
            // when already ready by post-processing time; otherwise it still
            // attaches to persisted metadata after paste.
            if captureRichContext && extractColdContext {
                coldTask = Task.detached(priority: .utility) {
                    let hot = await hotContextTask.value
                    return await extractor.extractCold(
                        from: targetApplication,
                        bundleId: hot.bundleId,
                        windowTitle: hot.windowTitle,
                        browserURL: hot.browserURL
                    )
                }
            } else {
                coldTask = nil
            }

            // Raw transcription
            try cancellationToken.check()
            latencyLogger?.mark("txStart")
            var detailedTranscription: DetailedTranscription
            if let canonicalSamples {
                detailedTranscription = try await transcriber.transcribeDetailed(
                    audioSamples: canonicalSamples,
                    language: language
                )
            } else {
                detailedTranscription = try await transcriber.transcribeDetailed(
                    audioURL: url,
                    language: language
                )
            }
            try cancellationToken.check()
            latencyLogger?.mark("txEnd")
            // An empty full-clip decode on a short capture gets one voiced-window
            // retry before the pipeline can conclude "no speech".
            if let canonicalSamples,
               detailedTranscription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let retried = await retranscribeVoicedWindow(
                   samples: canonicalSamples,
                   clipDuration: captureDiagnostics.duration,
                   transcriber: transcriber,
                   language: language,
                   cancellationToken: cancellationToken,
                   latencyLogger: latencyLogger
               ) {
                detailedTranscription = retried
            }
            let rawText = detailedTranscription.text
            try cancellationToken.check()
            latencyLogger?.mark("recoveryStart")
            let segmentRecoveryResult: DictationSegmentRecoveryResult
            let rawTextIsEmpty = rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if canonicalSamples == nil {
                segmentRecoveryResult = DictationSegmentRecoveryResult(
                    recoveredTranscript: nil,
                    trace: .skipped(
                        outcome: "skipped_disk_backed_long_form",
                        originalTranscript: rawText
                    )
                )
            } else if !DictationSegmentRecovery.shouldAnalyzeAudio(
                clipDuration: captureDiagnostics.duration
            ) {
                segmentRecoveryResult = DictationSegmentRecoveryResult(
                    recoveredTranscript: nil,
                    trace: .skipped(
                        outcome: "skipped_short_clip",
                        originalTranscript: rawText
                    )
                )
            } else if lowLatencyMode && !rawTextIsEmpty {
                segmentRecoveryResult = DictationSegmentRecoveryResult(
                    recoveredTranscript: nil,
                    trace: .skipped(
                        outcome: "skipped_low_latency",
                        originalTranscript: rawText
                    )
                )
            } else {
                segmentRecoveryResult = try await recoverSegmentedTranscriptIfNeeded(
                    audioSamples: canonicalSamples!,
                    initialTranscript: rawText,
                    duration: captureDiagnostics.duration,
                    transcriber: transcriber,
                    language: language,
                    cancellationToken: cancellationToken
                )
            }
            try cancellationToken.check()
            latencyLogger?.mark("recoveryEnd")
            latencyLogger?.mark("ctxAwaitStart")
            guard var resolvedHot = await DictationAsyncDeadline.valueUnlessCancelled(
                hotContextTask
            ) else {
                throw CancellationError()
            }
            resolvedHot.activeRecipient = activeRecipientContext
            try cancellationToken.check()
            latencyLogger?.mark("ctxAwaitEnd")
            latencyLogger?.setTargetBundleId(resolvedHot.bundleId)
            let resolvedSelection = Self.resolvedSelection(
                liveText: resolvedHot.selectedText,
                liveRange: resolvedHot.selectedRange,
                fallbackText: fallbackSelectedText,
                fallbackRange: fallbackSelectedRange
            )

            // Post-process
            let transcriptToProcess = segmentRecoveryResult.recoveredTranscript ?? rawText
            try cancellationToken.check()
            let coldForProcessing = await DictationAsyncDeadline.valueIfReady(
                coldTask,
                timeoutNanoseconds: 15_000_000
            )
            try cancellationToken.check()
            let surface = SurfaceClassifier.classify(hot: resolvedHot)
            let contextPacket = ContextPacketBuilder.build(
                transcript: transcriptToProcess,
                hot: resolvedHot,
                cold: coldForProcessing,
                selectedTextOverride: resolvedSelection.selectedText,
                personalizationProfile: personalizationLearningEngine?.profile(for: surface)
            )
            // Timings only align with the original decode — a recovered
            // transcript came from a different pass, so segmentation skips it.
            let candidateTimings = segmentRecoveryResult.recoveredTranscript == nil
                ? detailedTranscription.tokenTimings
                : []
            let timingsForProcessing = PauseSegmenter.timingsStrictlyAlign(
                transcriptToProcess,
                timings: candidateTimings
            ) ? candidateTimings : []
            // Pause-annotated copy of the raw transcript for cloud cleanup —
            // built here because this is the last point where text and
            // timings still align.
            let pauseAnnotatedTranscript = PauseSegmenter.annotate(
                transcriptToProcess,
                timings: timingsForProcessing
            )
            let postProcessingResult = await postProcessor.processDetailed(
                transcriptToProcess,
                contextPacket: contextPacket,
                tokenTimings: timingsForProcessing,
                language: language
            )
            var text = postProcessingResult.text
            try cancellationToken.check()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            latencyLogger?.mark("postProcEnd")

            guard !text.isEmpty else {
                let diagnostics = await logSilenceDiagnostics(
                    audioSamples: canonicalSamples,
                    duration: duration
                )
                try cancellationToken.check()
                throw emptyTextError(for: diagnostics)
            }

            let wordCount = text.split(separator: " ").count
            SentryManager.shared.dictationEnd(duration: duration, wordCount: wordCount)

            let result = TranscriptionResult(
                text: text,
                rawTranscript: transcriptToProcess,
                pauseAnnotatedTranscript: pauseAnnotatedTranscript,
                duration: duration,
                captureDiagnostics: captureDiagnostics,
                recognitionDiagnostics: recognitionDiagnostics,
                segmentRecoveryTrace: segmentRecoveryResult.trace,
                postProcessingTrace: postProcessingResult.trace,
                contextEntityRepairProvenance: postProcessingResult.contextEntityRepairProvenance,
                styleApplicationProvenance: postProcessingResult.styleApplicationProvenance,
                recordingURL: url,
                selectedText: resolvedSelection.selectedText,
                selectedRange: resolvedSelection.selectedRange,
                targetApp: resolvedHot.appName.nilIfEmpty,
                targetBundleId: resolvedHot.bundleId.nilIfEmpty,
                windowTitle: resolvedHot.windowTitle.nilIfEmpty,
                browserURL: resolvedHot.browserURL.nilIfEmpty,
                codeFileName: nil,
                slackRecipient: nil,
                focusedFieldContent: resolvedHot.focusedFieldContent.nilIfEmpty,
                visibleTextSnippets: nil,
                contextPacket: contextPacket,
                coldContextTask: coldTask,
                vocabularyBoostAudit: segmentRecoveryResult.recoveredTranscript == nil
                    ? detailedTranscription.boostAudit
                    : nil
            )
            pipelineCompletedSuccessfully = true
            return result
        } catch is CancellationError {
            coldTask?.cancel()
            if deletesRecordingOnCancellation {
                _ = DictationRecordingFileDeletion.removeIfPresent(url)
            }
            throw CancellationError()
        } catch {
            coldTask?.cancel()
            if shouldCaptureSilenceDiagnostics(for: error) {
                _ = await logSilenceDiagnostics(
                    audioSamples: canonicalSamples,
                    duration: duration
                )
            }
            // Diagnostics run independently so a cancelled pipeline does not
            // wait for a non-cooperative FFT/VAD pass. Preserve cancellation
            // truth instead of reporting the earlier decode/no-speech error.
            do {
                try cancellationToken.check()
            } catch {
                if deletesRecordingOnCancellation {
                    _ = DictationRecordingFileDeletion.removeIfPresent(url)
                }
                throw CancellationError()
            }
            if let diagnostics = lastSilenceDiagnostics,
               DictationAudioAnalyzer.shouldRejectBeforeTranscription(diagnostics) {
                discardFailedRecording(at: url)
            }
            // Whatever survived on disk is retryable — the user's words are
            // worth one more decode attempt on explicit request.
            if recordingRetention == .recoverable,
               FileManager.default.fileExists(atPath: url.path) {
                lastFailedRecordingStash = FailedRecordingStash(url: url, duration: duration)
            }
            SentryManager.shared.dictationError(error)
            throw error
        }
    }

    /// A failed dictation's surviving audio, kept addressable for one-tap
    /// retry. Cleared when a new capture starts (the file itself is reclaimed
    /// by the recovery-store orphan purge on next launch).
    struct FailedRecordingStash: Equatable {
        let url: URL
        let duration: TimeInterval

        var fileStillExists: Bool {
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    private func discardFailedRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        lastFailureDiscardedRecording = !FileManager.default.fileExists(atPath: url.path)
    }

    static func resolvedSelection(
        liveText: String?,
        liveRange: SelectionRange?,
        fallbackText: String?,
        fallbackRange: SelectionRange?
    ) -> (selectedText: String?, selectedRange: SelectionRange?) {
        let normalizedLiveText = normalizedSelectionText(liveText)
        let normalizedFallbackText = normalizedSelectionText(fallbackText)

        guard let normalizedLiveText else {
            guard let normalizedFallbackText else {
                return (nil, nil)
            }
            return (normalizedFallbackText, fallbackRange)
        }

        if let liveRange {
            return (normalizedLiveText, liveRange)
        }

        if normalizedFallbackText == normalizedLiveText {
            return (normalizedLiveText, fallbackRange)
        }

        return (normalizedLiveText, nil)
    }

    private static func normalizedSelectionText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Cancels owned work. A returned task represents non-cooperative audio or
    /// model work that is still retiring; the caller must keep capture/model
    /// reuse unavailable until it completes.
    @discardableResult
    func cancel() async -> Task<Void, Never>? {
        let pipelineID = activePipeline?.id
        let pipelineTask = activePipeline?.task
        let cancellationToken = activeCancellationToken
        pipelineTask?.cancel()
        cancellationToken?.cancel()
        let pendingAudioFinalization = await audioRecorder.cancel()
        recordingURL = nil
        recordingStart = nil
        lastCaptureDiagnostics = nil
        lastCaptureWallDurationSeconds = nil

        if DictationCancellationJoinPolicy.requiresDeferredRetirement(
            hasPendingAudioFinalization: pendingAudioFinalization != nil,
            hasActivePipeline: pipelineTask != nil
        ) {
            return Task { @MainActor [weak self] in
                if let pendingAudioFinalization {
                    await pendingAudioFinalization.value
                }
                if let pipelineTask {
                    _ = try? await pipelineTask.value
                }
                guard let self else { return }
                if self.activePipeline?.id == pipelineID {
                    self.activePipeline = nil
                }
                if self.activeCancellationToken === cancellationToken {
                    self.activeCancellationToken = nil
                }
            }
        }
        if activePipeline?.id == pipelineID {
            activePipeline = nil
        }
        if activeCancellationToken === cancellationToken {
            activeCancellationToken = nil
        }
        return nil
    }

    func cleanup(preserveRecoveryArtifact: Bool) {
        guard !preserveRecoveryArtifact else { return }
        activePipeline?.task.cancel()
        activeCancellationToken?.cancel()
        Task {
            _ = await audioRecorder.cancel()
        }
    }

    private func logSilenceDiagnostics(
        audioSamples: [Float]?,
        duration: TimeInterval
    ) async -> DictationAudioAnalyzer.Diagnostics? {
        guard let audioSamples else {
            log.info("No-speech diagnostics skipped for disk-backed long-form capture")
            return nil
        }
        let diagnosticsTask = Task.detached(priority: .userInitiated) {
            await DictationAudioAnalyzer.diagnose(audioSamples: audioSamples)
        }
        let diagnostics = await withTaskCancellationHandler {
            await DictationAsyncDeadline.valueUnlessCancelled(diagnosticsTask) ?? nil
        } onCancel: {
            diagnosticsTask.cancel()
        }
        guard let diagnostics else {
            log.info("No-speech diagnostics unavailable (failed to load audio)")
            return nil
        }
        recordSilenceDiagnostics(diagnostics, duration: duration, reason: "post_transcription")
        return diagnostics
    }

    private func recordSilenceDiagnostics(
        _ diagnostics: DictationAudioAnalyzer.Diagnostics,
        duration: TimeInterval,
        reason: String
    ) {
        lastSilenceDiagnostics = diagnostics
        lastSilenceDiagnosticsReason = reason
        log.info(
            "No-speech diagnostics reason=\(reason, privacy: .public) duration_s=\(duration, privacy: .public) audio_s=\(diagnostics.audioDurationSeconds, privacy: .public) peak_db=\(diagnostics.peakDb, privacy: .public) true_peak_db=\(diagnostics.truePeakDb, privacy: .public) clip_ratio=\(diagnostics.clipRatio, privacy: .public) mean_db=\(diagnostics.meanDb, privacy: .public) noise_floor_db=\(diagnostics.noiseFloorDb, privacy: .public) threshold_db=\(diagnostics.thresholdDb, privacy: .public) frames=\(diagnostics.frameCount, privacy: .public) segments=\(diagnostics.speechSegmentCount, privacy: .public) voiced_s=\(diagnostics.voicedDurationSeconds, privacy: .public) segmenter=\(diagnostics.segmenterSource.rawValue, privacy: .public)"
        )
    }

    private func shouldCaptureSilenceDiagnostics(for error: Error) -> Bool {
        switch error {
        case DictationError.emptyTranscription,
             DictationError.speechDetectedButNoText,
             DictationError.noModelSelected,
             TranscriberError.notLoaded,
             TranscriberError.notDownloaded:
            return false
        default:
            return true
        }
    }

    private func emptyTextError(
        for diagnostics: DictationAudioAnalyzer.Diagnostics?
    ) -> DictationError {
        guard let diagnostics else { return .emptyTranscription }
        if DictationEmptyResultClassification.isSpeechDetected(
            speechSegmentCount: diagnostics.speechSegmentCount,
            voicedDurationSeconds: diagnostics.voicedDurationSeconds
        ) {
            return .speechDetectedButNoText
        }
        return .emptyTranscription
    }

    /// One recovery decode for a short clip whose full-clip decode produced no
    /// text: re-run ASR on just the voiced window (±250 ms) so long silent
    /// margins or a clipped onset can't drown a one-word utterance. Returns nil
    /// when the retry isn't sensible or also produced nothing.
    private func retranscribeVoicedWindow(
        samples: [Float],
        clipDuration: TimeInterval,
        transcriber: any Transcriber,
        language: String?,
        cancellationToken: DictationCancellationToken,
        latencyLogger: DictationLatencyLogger?
    ) async -> DetailedTranscription? {
        guard DictationVoicedWindowRetry.shouldAttempt(clipDuration: clipDuration) else { return nil }
        guard (try? cancellationToken.check()) != nil else { return nil }
        let segmentation = try? await DictationAudioAnalyzer.segmentSpeechSamples(in: samples)
        guard let segments = segmentation?.speechSegments,
              let window = DictationVoicedWindowRetry.windowBounds(
                  segments: segments,
                  sampleCount: samples.count
              )
        else { return nil }
        guard (try? cancellationToken.check()) != nil else { return nil }
        latencyLogger?.mark("emptyRetryStart")
        defer { latencyLogger?.mark("emptyRetryEnd") }
        guard let retried = try? await transcriber.transcribeDetailed(
            audioSamples: Array(samples[window]),
            language: language
        ) else { return nil }
        guard !retried.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        log.info("Voiced-window retry recovered a transcript from an empty full-clip decode (window_samples=\(window.count, privacy: .public) of \(samples.count, privacy: .public))")
        // Window-relative token timings don't align with the full capture; drop
        // them. The boost audit is text-based (applied/vetoed term names), so it
        // stays valid and must survive — else this retry's boost-inserted terms
        // escape sighting exclusion and telemetry.
        return DetailedTranscription(
            text: retried.text,
            tokenTimings: [],
            boostAudit: retried.boostAudit
        )
    }

    private func recoverSegmentedTranscriptIfNeeded(
        audioSamples: [Float],
        initialTranscript: String,
        duration: TimeInterval,
        transcriber: any Transcriber,
        language: String?,
        cancellationToken: DictationCancellationToken
    ) async throws -> DictationSegmentRecoveryResult {
        let trimmedTranscript = initialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalWordCount = trimmedTranscript.split(separator: " ").count

        let analysis: DictationAudioAnalyzer.Analysis
        do {
            let analysisTask = Task.detached(priority: .userInitiated) {
                try await DictationAudioAnalyzer.analyze(audioSamples: audioSamples)
            }
            analysis = try await withTaskCancellationHandler {
                try await DictationAsyncDeadline.throwingValueUnlessCancelled {
                    try await analysisTask.value
                }
            } onCancel: {
                analysisTask.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("Dictation audio analysis failed: \(error.localizedDescription, privacy: .public)")
            return DictationSegmentRecoveryResult(
                recoveredTranscript: nil,
                trace: .skipped(
                    outcome: "analysis_failed",
                    originalTranscript: trimmedTranscript
                )
            )
        }
        try cancellationToken.check()

        log.info(
            "Initial dictation transcript words=\(originalWordCount, privacy: .public) duration_s=\(duration, privacy: .public) speech_segments=\(analysis.speechSegments.count, privacy: .public) voiced_s=\(analysis.voicedDuration, privacy: .public) segmenter=\(analysis.segmentationSource.rawValue, privacy: .public)"
        )

        guard DictationSegmentRecovery.shouldAttemptSegmentRecovery(
            originalTranscript: trimmedTranscript,
            clipDuration: duration,
            speechSegments: analysis.speechSegments
        ) else {
            return DictationSegmentRecoveryResult(
                recoveredTranscript: nil,
                trace: .skipped(
                    outcome: "not_needed",
                    originalTranscript: trimmedTranscript,
                    speechSegmentCount: analysis.speechSegments.count,
                    voicedDurationSeconds: analysis.voicedDuration,
                    segmenterSource: analysis.segmentationSource.rawValue
                )
            )
        }

        log.info("Attempting segmented dictation recovery")

        var recoveredSegments: [String] = []
        recoveredSegments.reserveCapacity(analysis.speechSegments.count)

        for segment in analysis.speechSegments {
            try cancellationToken.check()
            let segmentSamples = DictationAudioAnalyzer.slice(samples: analysis.samples, for: segment)

            do {
                let recoveredText = try await transcriber.transcribe(
                    audioSamples: segmentSamples,
                    language: language
                )
                try cancellationToken.check()
                let trimmedSegment = recoveredText.trimmingCharacters(in: .whitespacesAndNewlines)
                let segmentWordCount = trimmedSegment.split(separator: " ").count
                if !trimmedSegment.isEmpty {
                    recoveredSegments.append(trimmedSegment)
                }
                log.debug(
                    "Recovered segment start_s=\(segment.startTime, privacy: .public) end_s=\(segment.endTime, privacy: .public) words=\(segmentWordCount, privacy: .public)"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error(
                    "Segment recovery failed start_s=\(segment.startTime, privacy: .public) end_s=\(segment.endTime, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let recoveredTranscript = DictationSegmentRecovery.combine(recoveredSegments)
        guard DictationSegmentRecovery.shouldPreferRecoveredTranscript(
            originalTranscript: trimmedTranscript,
            recoveredTranscript: recoveredTranscript
        ) else {
            log.info("Segmented recovery kept original transcript")
            return DictationSegmentRecoveryResult(
                recoveredTranscript: nil,
                trace: .attempted(
                    outcome: "kept_original",
                    used: false,
                    originalTranscript: trimmedTranscript,
                    recoveredTranscript: recoveredTranscript,
                    speechSegmentCount: analysis.speechSegments.count,
                    voicedDurationSeconds: analysis.voicedDuration,
                    segmenterSource: analysis.segmentationSource.rawValue
                )
            )
        }

        let recoveredWordCount = recoveredTranscript.split(separator: " ").count
        log.info(
            "Segmented recovery selected words_before=\(originalWordCount, privacy: .public) words_after=\(recoveredWordCount, privacy: .public)"
        )
        return DictationSegmentRecoveryResult(
            recoveredTranscript: recoveredTranscript,
            trace: .attempted(
                outcome: "used",
                used: true,
                originalTranscript: trimmedTranscript,
                recoveredTranscript: recoveredTranscript,
                speechSegmentCount: analysis.speechSegments.count,
                voicedDurationSeconds: analysis.voicedDuration,
                segmenterSource: analysis.segmentationSource.rawValue
            )
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array {
    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}

// MARK: - Errors

enum DictationError: LocalizedError {
    case noRecording
    case noModelSelected
    case transcriptionFailed
    case emptyTranscription
    case speechDetectedButNoText

    var errorDescription: String? {
        switch self {
        case .noRecording: "No active recording to transcribe."
        case .noModelSelected: "No transcription model selected."
        case .transcriptionFailed: "Transcription failed."
        case .emptyTranscription: "No speech detected."
        case .speechDetectedButNoText: "Speech detected, but no text was produced."
        }
    }
}
