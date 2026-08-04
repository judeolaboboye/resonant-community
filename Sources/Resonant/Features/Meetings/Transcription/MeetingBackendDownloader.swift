import FluidAudio
import Foundation
import Observation

/// Drives downloads for local meeting backends from inside the Meetings
/// settings tab. Reuses the dictation `Transcriber` adapters so model files
/// land in the exact paths `MeetingSharedModelStore` reads from, and so the
/// Cohere vocab.json workaround in `CohereTranscribeAdapter.download` runs
/// regardless of which tab triggered the download. Cloud backends are treated
/// as already available and do not download model files.
@MainActor
@Observable
final class MeetingBackendDownloader {

    /// Backend currently downloading, or nil when idle.
    private(set) var activeKind: MeetingBackendKind?

    /// Fraction complete (0…1) for `activeKind`.
    private(set) var progress: Double = 0

    /// Last download error, cleared on a new attempt.
    private(set) var lastError: String?

    /// File-existence check. Cheap; safe to call in view body.
    static func isDownloaded(_ kind: MeetingBackendKind) -> Bool {
        guard DictationVADSegmenter.cachedModelURL() != nil else { return false }
        if kind == .deepgram { return true }
        guard let adapter = makeAdapter(kind) else { return false }
        return adapter.isDownloaded
    }

    /// Approximate on-disk size for the given backend, formatted for the UI.
    static func downloadSizeText(_ kind: MeetingBackendKind) -> String {
        switch kind {
        case .parakeet: return "~701 MB incl. VAD"
        case .qwen3: return "~1.7 GB incl. VAD"
        case .cohere: return "~2 GB incl. VAD"
        case .deepgram: return "~1 MB VAD helper"
        }
    }

    func clearError() {
        lastError = nil
    }

    /// Download the backend files. The meeting engine loads the selected model
    /// when a recording starts.
    func download(_ kind: MeetingBackendKind) async {
        guard activeKind == nil else { return }
        if kind == .cohere, AppRuntime.distributionFlavor == .community {
            lastError = "Cohere downloads are unavailable in Community builds while the derivative model terms remain ambiguous."
            return
        }
        if kind == .deepgram, !AppRuntime.hasHostedServices {
            lastError = "This build has no configured cloud transcription service."
            return
        }
        activeKind = kind
        progress = 0
        lastError = nil
        defer { activeKind = nil }

        do {
            switch kind {
            case .parakeet:
                try await FluidAudioAdapter.downloadFilesOnly { [weak self] update in
                    Task { @MainActor [weak self] in self?.progress = update.fraction }
                }
            case .qwen3:
                guard #available(macOS 15, *) else {
                    lastError = "Qwen3 requires macOS 15."
                    return
                }
                try await Qwen3AudioAdapter.downloadFilesOnly { [weak self] update in
                    Task { @MainActor [weak self] in self?.progress = update.fraction }
                }
            case .cohere:
                guard #available(macOS 15, *) else {
                    lastError = "Cohere requires macOS 15."
                    return
                }
                try await CohereTranscribeAdapter.downloadFilesOnly { [weak self] update in
                    Task { @MainActor [weak self] in self?.progress = update.fraction }
                }
            case .deepgram:
                break
            }
            // Meeting segmentation uses Silero VAD. It is intentionally tied
            // to this visible user action and never fetched during dictation.
            try await DictationVADSegmenter.downloadModelCache()
            guard Self.isDownloaded(kind) else {
                throw TranscriberError.downloadFailed("\(kind.displayName) files are incomplete.")
            }
            progress = 1
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func makeAdapter(_ kind: MeetingBackendKind) -> (any Transcriber)? {
        switch kind {
        case .parakeet:
            return FluidAudioAdapter()
        case .qwen3:
            if #available(macOS 15, *) { return Qwen3AudioAdapter() }
            return nil
        case .cohere:
            if #available(macOS 15, *) { return CohereTranscribeAdapter() }
            return nil
        case .deepgram:
            return nil
        }
    }
}
