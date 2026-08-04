import CoreML
import FluidAudio
import Foundation
import os

/// Wraps FluidAudio's Cohere Transcribe (cache-external CoreML) — encoder-decoder
/// ASR with hard-coded language conditioning across 14 languages. FluidAudio
/// handles long audio with overlapping windows and token-level stitching.
final class CohereTranscribeAdapter: Transcriber, @unchecked Sendable {

    private static let log = Logger.resonant("CohereTranscribeAdapter")

    let id = "cohere-transcribe-q8"
    let displayName = "Cohere Transcribe (Beta)"
    let description = "14 languages · ANE · ~2 GB"
    let downloadSizeBytes: Int64 = 2_000_000_000
    let modelURL: URL? = URL(string: "https://huggingface.co/FluidInference/cohere-transcribe-03-2026-coreml")
    let supportedLanguageCodes: Set<String> = [
        "en", "fr", "de", "es", "it", "pt", "nl",
        "pl", "el", "ar", "ja", "zh", "vi", "ko",
    ]
    let supportsAutoLanguageDetection = false

    private let lock = NSLock()
    private var pipeline: CoherePipeline?
    private var loadedModels: CoherePipeline.LoadedModels?

    /// Cohere has no language-ID; pick a default when caller doesn't specify one.
    /// English is the lowest-WER setting on the published benchmarks.
    private static let fallbackLanguage: CohereAsrConfig.Language = .english

    var isLoaded: Bool {
        lock.withLock { loadedModels != nil }
    }

    var isDownloaded: Bool {
        let dir = Self.modelDirectory()
        let fm = FileManager.default
        return ModelNames.CohereTranscribe.requiredModels.allSatisfy {
            let url = dir.appendingPathComponent($0)
            if $0.hasSuffix(".mlmodelc") {
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                    && fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
            }
            return fm.fileExists(atPath: url.path)
        }
    }

    var requiresDownload: Bool { true }

    /// File-only download. Used by both the dictation `download(...)` flow
    /// and the meeting tab's downloader so neither path triggers a wasted
    /// `loadFromDisk()` against weights that the meeting `MeetingSharedModelStore`
    /// will load fresh anyway.
    static func downloadFilesOnly(
        onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        try await ModelDownloadLock.withLock(reportingWaitTo: onProgress) {
            // FluidAudio's downloadRepo walks only the `q8/` subPath and then
            // verifies every entry in `requiredModels` is on disk — including
            // `vocab.json`, which lives at the repo root. Stage it first so
            // the post-download check passes.
            try await ensureVocabPresent()
            let parent = parentDirectory()
            try await DownloadUtils.downloadRepo(.cohereTranscribeCoreml, to: parent) { progress in
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
        try await loadFromDisk()
    }

    func transcribe(audioURL: URL, language: String? = nil) async throws -> String {
        if !isLoaded { try await load() }
        let prepared = try TranscriberAudioSupport.preparedInput(from: audioURL)
        return try await runTranscription(samples: prepared.preparedSamples, language: language)
    }

    func transcribe(audioSamples: [Float], language: String? = nil) async throws -> String {
        if !isLoaded { try await load() }
        let prepared = try TranscriberAudioSupport.preparedSamples(audioSamples)
        return try await runTranscription(samples: prepared, language: language)
    }

    func unload() {
        lock.withLock {
            pipeline = nil
            loadedModels = nil
        }
    }

    /// Without this the registry's load-failure recovery re-runs the same failing
    /// load against the same corrupt cache, so a truncated bundle is unrecoverable
    /// from inside the app.
    func purgeDownloadedModel() {
        unload()
        Self.log.info("Purging Cohere Transcribe cache")
        try? FileManager.default.removeItem(at: Self.modelDirectory())
    }

    // MARK: - Internals

    private func loadFromDisk() async throws {
        let dir = Self.modelDirectory()
        let models = try await CoherePipeline.loadModels(
            encoderDir: dir,
            decoderDir: dir,
            vocabDir: dir
        )
        let pipeline = CoherePipeline()
        lock.withLock {
            self.pipeline = pipeline
            self.loadedModels = models
        }
    }

    private func runTranscription(samples: [Float], language: String?) async throws -> String {
        let (pipeline, models) = lock.withLock { (self.pipeline, self.loadedModels) }
        guard let pipeline, let models else {
            throw TranscriberError.notLoaded
        }
        let lang = Self.mapLanguage(language)

        let result = try await pipeline.transcribeLong(audio: samples, models: models, language: lang)
        return result.text
    }

    private static func mapLanguage(_ language: String?) -> CohereAsrConfig.Language {
        guard let language, !language.isEmpty else { return fallbackLanguage }
        let normalized = language.lowercased()
        if normalized == "auto" { return fallbackLanguage }
        return CohereAsrConfig.Language(rawValue: normalized) ?? fallbackLanguage
    }

    private static func parentDirectory() -> URL {
        MLModelConfigurationUtils.defaultModelsDirectory()
    }

    private static func modelDirectory() -> URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .cohereTranscribeCoreml)
    }

    private static func ensureVocabPresent() async throws {
        let dir = modelDirectory()
        let dest = dir.appendingPathComponent(ModelNames.CohereTranscribe.vocab)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // URL components are compile-time constants; force-unwrap is safe.
        let url = URL(
            string: "https://huggingface.co/FluidInference/cohere-transcribe-03-2026-coreml/resolve/main/\(ModelNames.CohereTranscribe.vocab)"
        )!
        let data = try await DownloadUtils.fetchHuggingFaceFile(from: url, description: ModelNames.CohereTranscribe.vocab)
        try data.write(to: dest, options: .atomic)
    }
}
