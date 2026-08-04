import FluidAudio
import Foundation

/// Transcription backend for Parakeet-TDT v3 (multilingual batch ASR).
/// Ported from OpenOats ParakeetBackend — adapted for Resonant.
/// @unchecked Sendable: asrManager is written once in prepare() before any transcribe() calls.
final class MeetingParakeetBackend: MeetingTranscriptionBackend, @unchecked Sendable {

    let displayName = "Parakeet TDT v3"
    private var asrManager: AsrManager?

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        onStatus("Loading Parakeet model...")
        let models = try await AsrModels.loadFromCache(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.asrManager = asr
    }

    func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        guard let asrManager else {
            throw MeetingTranscriptionBackendError.notPrepared
        }
        let preparedSamples = try TranscriberAudioSupport.preparedSamples(samples)
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let language = FluidAudioLanguageHint.map(locale.language.languageCode?.identifier)
        let result = try await asrManager.transcribe(preparedSamples, decoderState: &decoderState, language: language)
        TranscriptionSpacingDebug.logSuspiciousSampleIfNeeded(result, source: "meeting")

        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func tearDown() async {
        asrManager = nil
    }
}
