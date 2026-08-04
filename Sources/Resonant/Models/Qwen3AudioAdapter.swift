import FluidAudio
import Foundation
import os

/// Wraps FluidAudio's Qwen3-ASR model (CoreML / Apple Neural Engine).
/// Supports 30 languages with optional language hinting.
@available(macOS 15, *)
final class Qwen3AudioAdapter: Transcriber, @unchecked Sendable {

    private static let log = Logger.resonant("Qwen3AudioAdapter")

    let id = "qwen3-asr-0.6b"
    let displayName = "Qwen3 ASR"
    let description = "30 languages · Apple Neural Engine · ~1.7 GB"
    let downloadSizeBytes: Int64 = 1_750_000_000
    let modelURL: URL? = URL(string: "https://huggingface.co/FluidInference/qwen3-asr-0.6b-coreml")
    let supportedLanguageCodes: Set<String> = [
        "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it",
        "ko", "ru", "th", "vi", "ja", "tr", "hi", "ms", "nl", "sv",
        "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
    ]
    let supportsAutoLanguageDetection = true

    private var manager: Qwen3AsrManager?
    private let lock = NSLock()

    var isLoaded: Bool {
        lock.withLock { manager != nil }
    }

    var isDownloaded: Bool {
        let dir = Qwen3AsrModels.defaultCacheDirectory()
        let fm = FileManager.default
        let modelDirectories = [
            ModelNames.Qwen3ASR.audioEncoderFile,
            ModelNames.Qwen3ASR.decoderStatefulFile,
        ]
        let modelBundlesReady = modelDirectories.allSatisfy { fileName in
            let url = dir.appendingPathComponent(fileName)
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
        }
        return modelBundlesReady
            && fm.fileExists(atPath: dir.appendingPathComponent(ModelNames.Qwen3ASR.embeddingsFile).path)
            && fm.fileExists(atPath: dir.appendingPathComponent("vocab.json").path)
    }

    var requiresDownload: Bool { true }

    static func downloadFilesOnly(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        try await ModelDownloadLock.withLock(reportingWaitTo: onProgress) {
            _ = try await Qwen3AsrModels.download(variant: .f32) { progress in
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
        let dir = Qwen3AsrModels.defaultCacheDirectory()
        let mgr = Qwen3AsrManager()
        try await mgr.loadModels(from: dir)
        lock.withLock { manager = mgr }
    }

    func transcribe(audioURL: URL, language: String? = nil) async throws -> String {
        if !isLoaded {
            try await load()
        }
        guard let mgr = lock.withLock({ manager }) else {
            throw TranscriberError.notLoaded
        }

        let preparedInput = try TranscriberAudioSupport.preparedInput(from: audioURL)
        let langHint: String? = (language == nil || language == "auto") ? nil : language
        let text = try await mgr.transcribe(audioSamples: preparedInput.preparedSamples, language: langHint)
        return text
    }

    func transcribe(audioSamples: [Float], language: String? = nil) async throws -> String {
        if !isLoaded {
            try await load()
        }
        guard let mgr = lock.withLock({ manager }) else {
            throw TranscriberError.notLoaded
        }

        let preparedSamples = try TranscriberAudioSupport.preparedSamples(audioSamples)
        let langHint: String? = (language == nil || language == "auto") ? nil : language
        return try await mgr.transcribe(audioSamples: preparedSamples, language: langHint)
    }

    func unload() {
        lock.withLock { manager = nil }
    }

    /// Without this the registry's load-failure recovery re-runs the same failing
    /// load against the same corrupt cache, so a truncated bundle is unrecoverable
    /// from inside the app.
    func purgeDownloadedModel() {
        unload()
        Self.log.info("Purging Qwen3 ASR cache")
        try? FileManager.default.removeItem(at: Qwen3AsrModels.defaultCacheDirectory())
    }
}
