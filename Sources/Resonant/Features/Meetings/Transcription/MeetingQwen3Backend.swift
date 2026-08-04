import FluidAudio
import Foundation

/// Transcription backend for Qwen3-ASR (30 languages, batch CoreML).
/// Shares one loaded `Qwen3AsrManager` across mic + system channels via
/// `MeetingSharedModelStore`.
@available(macOS 15, *)
final class MeetingQwen3Backend: MeetingTranscriptionBackend, @unchecked Sendable {

    let displayName = "Qwen3 ASR"

    private var manager: Qwen3AsrManager?
    private var holding = false

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        onStatus("Loading Qwen3 model...")
        manager = try await MeetingSharedModelStore.shared.acquireQwen3()
        holding = true
    }

    func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        guard let manager else {
            throw MeetingTranscriptionBackendError.notPrepared
        }
        let prepared = try TranscriberAudioSupport.preparedSamples(samples)
        let resolvedHint = locale.language.languageCode?.identifier
        let text = try await manager.transcribe(audioSamples: prepared, language: resolvedHint)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func tearDown() async {
        guard holding else { return }
        holding = false
        manager = nil
        await MeetingSharedModelStore.shared.releaseQwen3()
    }
}
