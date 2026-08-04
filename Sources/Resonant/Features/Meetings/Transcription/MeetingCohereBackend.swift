import FluidAudio
import Foundation
import os

/// Transcription backend for Cohere Transcribe (14 languages, batch CoreML).
/// Shares one loaded `CoherePipeline` across mic + system channels via
/// `MeetingSharedModelStore`.
///
/// Cohere has no auto-language detection — falls back to English when the
/// meeting locale doesn't match a supported code.
@available(macOS 15, *)
final class MeetingCohereBackend: MeetingTranscriptionBackend, @unchecked Sendable {

    let displayName = "Cohere Transcribe"

    private static let log = Logger.resonant("MeetingCohereBackend")

    private var pipeline: CoherePipeline?
    private var models: CoherePipeline.LoadedModels?
    private var holding = false
    private var loggedFallback = false

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        onStatus("Loading Cohere model...")
        let acquired = try await MeetingSharedModelStore.shared.acquireCohere()
        pipeline = acquired.0
        models = acquired.1
        holding = true
    }

    func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        guard let pipeline, let models else {
            throw MeetingTranscriptionBackendError.notPrepared
        }
        // VAD upstream caps segments well under Cohere's 35 s window — no chunking needed.
        let prepared = try TranscriberAudioSupport.preparedSamples(samples)
        let language = resolveLanguage(locale: locale)
        let result = try await pipeline.transcribe(audio: prepared, models: models, language: language)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func tearDown() async {
        guard holding else { return }
        holding = false
        pipeline = nil
        models = nil
        await MeetingSharedModelStore.shared.releaseCohere()
    }

    private func resolveLanguage(locale: Locale) -> CohereAsrConfig.Language {
        guard let code = locale.language.languageCode?.identifier.lowercased() else {
            return .english
        }
        if let match = CohereAsrConfig.Language(rawValue: code) {
            return match
        }
        if !loggedFallback {
            loggedFallback = true
            Self.log.info("Unsupported locale '\(code, privacy: .public)' for Cohere — falling back to English")
        }
        return .english
    }
}
