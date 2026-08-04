import Foundation
import FluidAudio
import os

/// Wraps FluidAudio's Parakeet v3 model (CoreML / Apple Neural Engine).
final class FluidAudioAdapter: Transcriber, @unchecked Sendable {

    private static let log = Logger.resonant("FluidAudioAdapter")

    /// FluidAudio 0.13.x renamed the v3 cache folder. Keep the old name here so existing
    /// users can have their cache migrated in place instead of re-downloading ~470 MB.
    private static let legacyV3FolderName = "parakeet-tdt-0.6b-v3-coreml"

    let id = "parakeet-tdt-0.6b-v3"
    let displayName = "Parakeet v3"
    let description = "Best accuracy · Apple Neural Engine · ~700 MB"
    let downloadSizeBytes: Int64 = 735_000_000
    let modelURL: URL? = URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")
    let supportedLanguageCodes: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "ro",
        "pl", "cs", "sk", "sl", "hr", "bs",
        "ru", "uk", "be", "bg", "sr",
    ]
    let supportsAutoLanguageDetection = true
    let supportsDiskBackedURLTranscription = true

    private var asrManager: AsrManager?
    private var vocabularyBoostEngine: ParakeetVocabularyBoostEngine?
    private let lock = NSLock()

    init() {
        Self.migrateV3CacheFolderIfNeeded()
    }

    /// Installs (or removes) the engine that rescores decodes toward the
    /// user's vocabulary. The engine itself decides per-dictation whether it
    /// can run (terms available, CTC model downloaded, explicit English or a
    /// first-pass transcript confidently identified as English on device).
    func installVocabularyBoostEngine(_ engine: ParakeetVocabularyBoostEngine?) {
        lock.withLock { vocabularyBoostEngine = engine }
    }

    /// Vocabulary rescoring for in-memory decodes. The disk-backed URL route
    /// intentionally skips boosting: the CTC spotter needs the full sample
    /// array, and loading it would defeat that route's constant-memory point.
    private func applyVocabularyBoostIfAvailable(
        _ result: ASRResult,
        samples: [Float],
        languageHint: Language?,
        selectedLanguage: String?
    ) async -> (result: ASRResult, audit: VocabularyBoostAudit?) {
        guard let engine = lock.withLock({ vocabularyBoostEngine }) else { return (result, nil) }
        return await engine.rescoredResult(
            result,
            audioSamples: samples,
            languageHint: languageHint,
            selectedLanguage: selectedLanguage
        )
    }

    var isLoaded: Bool {
        lock.withLock { asrManager != nil }
    }

    var isDownloaded: Bool {
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        let fm = FileManager.default
        let requiredFiles = ModelNames.ASR.requiredModelsV3(precision: .int8)
            .union([ModelNames.ASR.vocabularyFile])
        return requiredFiles.allSatisfy { fileName in
            let url = dir.appendingPathComponent(fileName)
            if fileName.hasSuffix(".mlmodelc") {
                var isDirectory: ObjCBool = false
                // Interrupted downloads can leave the bundle and coremldata.bin without weights.
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                    && fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
                else {
                    return false
                }
                return fileExistsAndIsNonEmptyFile(url.appendingPathComponent("model.mil"), fileManager: fm)
                    && fileExistsAndIsNonEmptyFile(url.appendingPathComponent("weights/weight.bin"), fileManager: fm)
            }
            return fm.fileExists(atPath: url.path)
        }
    }

    /// One-shot migration for users who updated from a FluidAudio version < 0.13.x.
    /// Renames the legacy cache folder to the current name so the existing models are
    /// reused instead of triggering a silent ~470 MB re-download on first launch.
    ///
    /// Safe under all conditions:
    /// - If the new folder already exists, this is a no-op (keeps new, leaves legacy alone).
    /// - If the legacy folder doesn't exist, this is a no-op.
    /// - If the move fails, we fall through to FluidAudio's normal download path — same
    ///   behavior as if this migration had never run.
    private static func migrateV3CacheFolderIfNeeded() {
        let current = AsrModels.defaultCacheDirectory(for: .v3)
        let legacy = current.deletingLastPathComponent().appendingPathComponent(legacyV3FolderName)
        let fm = FileManager.default

        guard fm.fileExists(atPath: legacy.path) else { return }
        guard !fm.fileExists(atPath: current.path) else { return }

        do {
            try fm.moveItem(at: legacy, to: current)
            log.info("Migrated Parakeet v3 cache: \(legacyV3FolderName, privacy: .public) -> \(current.lastPathComponent, privacy: .public)")
        } catch {
            log.error("Parakeet v3 cache migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var requiresDownload: Bool { true }

    var onDiskCacheBytes: Int64 {
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [],
            errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    static func downloadFilesOnly(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        let parent = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
        try await ModelDownloadLock.withLock(reportingWaitTo: onProgress) {
            try await DownloadUtils.downloadRepo(.parakeetV3, to: parent, variant: ParakeetEncoderPrecision.int8.rawValue) { progress in
                onProgress(ModelDownloadProgress(progress))
            }
        }
    }

    func download(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        try await Self.downloadFilesOnly(onProgress: onProgress)
        onProgress(ModelDownloadProgress(fraction: 1.0, phase: .downloading))
    }

    func load() async throws {
        guard !isLoaded else { return }
        // FluidAudio's loadFromCache silently re-downloads any missing file —
        // a full 700 MB fetch with zero progress inside the registry's 240 s
        // load watchdog, which then times out, purges, and downloads again.
        // Fail fast instead so the registry's download path (progress UI,
        // stall watchdog, retries) owns the network work.
        guard isDownloaded else {
            throw TranscriberError.notDownloaded
        }
        let models = try await AsrModels.loadFromCache(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        lock.withLock { asrManager = manager }
    }

    func transcribe(audioURL: URL, language: String? = nil) async throws -> String {
        try await transcribeDetailed(audioURL: audioURL, language: language).text
    }

    func transcribeDetailed(audioURL: URL, language: String?) async throws -> DetailedTranscription {
        if !isLoaded {
            // Model was evicted or never fully initialised — attempt a warm reload
            // before giving up, so the user's dictation isn't lost.
            try await load()
        }
        guard let manager = lock.withLock({ asrManager }) else {
            throw TranscriberError.notLoaded
        }
        let languageHint = FluidAudioLanguageHint.map(language)
        let estimatedSampleCount = try TranscriberAudioSupport.estimatedSampleCount(from: audioURL)

        if estimatedSampleCount > TranscriberAudioSupport.maximumInMemorySampleCount,
           let engine = lock.withLock({ vocabularyBoostEngine }) {
            await engine.recordDiskBackedBypass(selectedLanguage: language)
        }

        if estimatedSampleCount < TranscriberAudioSupport.minimumSampleCount {
            return try await transcribePreparedInput(
                manager,
                audioURL: audioURL,
                languageHint: languageHint,
                selectedLanguage: language
            )
        }
        do {
            let result = try await transcribe(manager, audioURL: audioURL, language: languageHint)
            return try await resolvedTranscriptionOrPreparedRetry(
                from: result,
                manager: manager,
                audioURL: audioURL,
                languageHint: languageHint,
                selectedLanguage: language,
                originalSampleCount: estimatedSampleCount
            )
        } catch let cancellationError as CancellationError {
            throw cancellationError
        } catch {
            try Task.checkCancellation()
            if estimatedSampleCount > TranscriberAudioSupport.maximumInMemorySampleCount {
                Self.log.info("Parakeet disk-backed transcription failed; retrying disk-backed URL")
                let result = try await transcribe(manager, audioURL: audioURL, language: languageHint)
                return try await resolvedTranscriptionOrPreparedRetry(
                    from: result,
                    manager: manager,
                    audioURL: audioURL,
                    languageHint: languageHint,
                    selectedLanguage: language,
                    originalSampleCount: estimatedSampleCount,
                    allowsEmptyResultRetry: false
                )
            }
            if estimatedSampleCount > 0 {
                Self.log.info("Parakeet file transcription failed; retrying prepared samples")
                return try await transcribePreparedInput(
                    manager,
                    audioURL: audioURL,
                    languageHint: languageHint,
                    selectedLanguage: language
                )
            }
            // ANE timeouts and transient CoreML failures can occur under thermal
            // pressure or scheduler contention — retry once before giving up.
            let result = try await transcribe(manager, audioURL: audioURL, language: languageHint)
            return try await resolvedTranscriptionOrPreparedRetry(
                from: result,
                manager: manager,
                audioURL: audioURL,
                languageHint: languageHint,
                selectedLanguage: language,
                originalSampleCount: estimatedSampleCount,
                allowsEmptyResultRetry: false
            )
        }
    }

    func transcribe(audioSamples: [Float], language: String? = nil) async throws -> String {
        try await transcribeDetailed(audioSamples: audioSamples, language: language).text
    }

    func transcribeDetailed(audioSamples: [Float], language: String? = nil) async throws -> DetailedTranscription {
        if !isLoaded {
            try await load()
        }
        guard let manager = lock.withLock({ asrManager }) else {
            throw TranscriberError.notLoaded
        }

        let languageHint = FluidAudioLanguageHint.map(language)
        let preparedInput = try TranscriberAudioSupport.preparedInput(audioSamples)
        let result = try await FluidAudioRetryPolicy.retryOnce(
            operation: {
                try await self.transcribe(
                    manager,
                    samples: preparedInput.preparedSamples,
                    language: languageHint
                )
            },
            retry: {
                try await self.transcribe(
                    manager,
                    samples: preparedInput.preparedSamples,
                    language: languageHint
                )
            },
            shouldRetryResult: { result in
                result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )
        let boosted = await applyVocabularyBoostIfAvailable(
            result,
            samples: preparedInput.preparedSamples,
            languageHint: languageHint,
            selectedLanguage: language
        )
        var transcription = resolvedTranscription(
            from: boosted.result, preparedInput: preparedInput
        )
        transcription.boostAudit = boosted.audit
        return transcription
    }

    func unload() {
        lock.withLock { asrManager = nil }
    }

    func purgeDownloadedModel() {
        unload()

        let fm = FileManager.default
        let current = AsrModels.defaultCacheDirectory(for: .v3)
        let legacy = current.deletingLastPathComponent().appendingPathComponent(Self.legacyV3FolderName)

        Self.log.info("Purging Parakeet v3 cache")
        try? fm.removeItem(at: current)
        try? fm.removeItem(at: legacy)
    }

    private func resolvedText(from result: ASRResult) -> String {
        TranscriptionSpacingDebug.logSuspiciousSampleIfNeeded(result, source: "dictation")
        return result.text
    }

    private func resolvedTranscription(
        from result: ASRResult,
        originalSampleCount: Int
    ) -> DetailedTranscription {
        let transcription = rawDetailedTranscription(from: result)
        return DetailedTranscription(
            text: transcription.text,
            tokenTimings: TranscriberAudioSupport.normalizedTokenTimings(
                transcription.tokenTimings,
                originalSampleCount: originalSampleCount
            )
        )
    }

    private func resolvedTranscription(
        from result: ASRResult,
        preparedInput: TranscriberAudioSupport.PreparedInput
    ) -> DetailedTranscription {
        let transcription = rawDetailedTranscription(from: result)
        return DetailedTranscription(
            text: transcription.text,
            tokenTimings: TranscriberAudioSupport.normalizedTokenTimings(
                transcription.tokenTimings,
                for: preparedInput
            )
        )
    }

    private func rawDetailedTranscription(from result: ASRResult) -> DetailedTranscription {
        DetailedTranscription(
            text: resolvedText(from: result),
            tokenTimings: (result.tokenTimings ?? []).map {
                TranscriptTokenTiming(
                    token: $0.token,
                    startTime: Double($0.startTime),
                    endTime: Double($0.endTime)
                )
            }
        )
    }

    private func resolvedTranscriptionOrPreparedRetry(
        from result: ASRResult,
        manager: AsrManager,
        audioURL: URL,
        languageHint: Language?,
        selectedLanguage: String?,
        originalSampleCount: Int,
        allowsEmptyResultRetry: Bool = true
    ) async throws -> DetailedTranscription {
        let transcription = resolvedTranscription(
            from: result,
            originalSampleCount: originalSampleCount
        )
        guard transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return transcription
        }

        // Preserve FluidAudio's constant-memory URL route for long recordings.
        // Loading a full prepared array here would defeat the routing decision
        // made before inference and can multiply memory use for long memos.
        guard originalSampleCount <= TranscriberAudioSupport.maximumInMemorySampleCount else {
            guard allowsEmptyResultRetry else { return transcription }
            try Task.checkCancellation()
            Self.log.info("Parakeet disk-backed transcription returned empty; retrying disk-backed URL")
            let retryResult = try await transcribe(manager, audioURL: audioURL, language: languageHint)
            return resolvedTranscription(
                from: retryResult,
                originalSampleCount: originalSampleCount
            )
        }

        Self.log.info("Parakeet file transcription returned empty; retrying prepared samples")
        return try await transcribePreparedInput(
            manager,
            audioURL: audioURL,
            languageHint: languageHint,
            selectedLanguage: selectedLanguage
        )
    }

    private func transcribePreparedInput(
        _ manager: AsrManager,
        audioURL: URL,
        languageHint: Language?,
        selectedLanguage: String?
    ) async throws -> DetailedTranscription {
        let preparedInput = try TranscriberAudioSupport.preparedInput(from: audioURL)
        let result = try await FluidAudioRetryPolicy.retryOnce(
            operation: {
                try await self.transcribe(
                    manager,
                    samples: preparedInput.preparedSamples,
                    language: languageHint
                )
            },
            retry: {
                try await self.transcribe(
                    manager,
                    samples: preparedInput.preparedSamples,
                    language: languageHint
                )
            },
            shouldRetryResult: { result in
                result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )
        let boosted = await applyVocabularyBoostIfAvailable(
            result,
            samples: preparedInput.preparedSamples,
            languageHint: languageHint,
            selectedLanguage: selectedLanguage
        )
        var transcription = resolvedTranscription(
            from: boosted.result, preparedInput: preparedInput
        )
        transcription.boostAudit = boosted.audit
        return transcription
    }

    private func fileExistsAndIsNonEmptyFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0
        } catch {
            return false
        }
    }

    private func transcribe(_ manager: AsrManager, audioURL: URL, language: Language?) async throws -> ASRResult {
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audioURL, decoderState: &decoderState, language: language)
    }

    private func transcribe(_ manager: AsrManager, samples: [Float], language: Language?) async throws -> ASRResult {
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &decoderState, language: language)
    }
}

/// Centralizes Fluid's one-shot transient retry rule so cancellation can never
/// be mistaken for an ANE/Core ML failure and replayed.
enum FluidAudioRetryPolicy {
    static func retryOnce<Value>(
        operation: () async throws -> Value,
        retry: () async throws -> Value,
        shouldRetryResult: (Value) -> Bool = { _ in false }
    ) async throws -> Value {
        let value: Value
        do {
            value = try await operation()
        } catch let cancellationError as CancellationError {
            throw cancellationError
        } catch {
            try Task.checkCancellation()
            return try await retry()
        }

        guard shouldRetryResult(value) else { return value }
        try Task.checkCancellation()
        return try await retry()
    }
}

/// Maps Resonant's ISO 639-1 language strings to FluidAudio's script-aware
/// `Language` enum used by the v3 joint decoder. Returns `nil` for "auto",
/// unknown codes, or unsupported languages — the model then runs without
/// script bias.
enum FluidAudioLanguageHint {
    static func map(_ language: String?) -> Language? {
        guard let language, !language.isEmpty else { return nil }
        let normalized = language.lowercased()
        if normalized == "auto" { return nil }
        return Language(rawValue: normalized)
    }
}
