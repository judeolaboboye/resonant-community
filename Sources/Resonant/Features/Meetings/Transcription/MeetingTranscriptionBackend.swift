import Foundation

/// A transcribed speech sub-segment, optionally carrying backend-provided
/// speaker attribution and offsets relative to the submitted audio segment.
struct MeetingTranscriptionSegment: Sendable, Equatable {
    let text: String
    let speaker: MeetingSpeaker?
    let startOffset: TimeInterval?
    let endOffset: TimeInterval?

    init(
        text: String,
        speaker: MeetingSpeaker? = nil,
        startOffset: TimeInterval? = nil,
        endOffset: TimeInterval? = nil
    ) {
        self.text = text
        self.speaker = speaker
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

/// Unified interface for transcription backends used by meeting recording.
/// Each backend handles its own model lifecycle and transcription logic.
/// Ported from OpenOats TranscriptionBackend protocol.
protocol MeetingTranscriptionBackend: Sendable {
    /// Human-readable name for UI display.
    var displayName: String { get }

    /// Prepare the backend for use (load models, etc.).
    /// Must complete before any call to transcribe().
    func prepare(onStatus: @Sendable (String) -> Void) async throws

    /// Transcribe a segment of Float32 audio samples at 16kHz mono.
    /// Returns the transcribed text, or empty string if no speech detected.
    func transcribe(_ samples: [Float], locale: Locale) async throws -> String

    /// Transcribe a segment and return any backend-provided speaker-aware sub-segments.
    func transcribeSegments(_ samples: [Float], locale: Locale) async throws -> [MeetingTranscriptionSegment]

    /// Release any shared resources (ref-counted model handles, etc.).
    /// Called from the engine teardown path. Safe to call without a prior `prepare`.
    func tearDown() async
}

extension MeetingTranscriptionBackend {
    func transcribeSegments(_ samples: [Float], locale: Locale) async throws -> [MeetingTranscriptionSegment] {
        let text = try await transcribe(samples, locale: locale)
        return [MeetingTranscriptionSegment(text: text)]
    }

    func tearDown() async {}
}

enum MeetingTranscriptionBackendError: LocalizedError {
    case notPrepared
    case modelNotDownloaded(MeetingBackendKind)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "Transcription backend not prepared."
        case .modelNotDownloaded(let kind):
            return "\(kind.displayName) model isn't downloaded yet. Open Settings → Meetings → Transcription model to download it."
        }
    }
}
