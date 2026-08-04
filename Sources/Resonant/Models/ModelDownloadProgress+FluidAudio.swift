import FluidAudio
import Foundation

extension ModelDownloadProgress {
    /// Bridges FluidAudio's `DownloadProgress` into the backend-agnostic type
    /// the rest of the app consumes. All three CoreML adapters (Parakeet, Qwen3,
    /// Cohere) fetch through `DownloadUtils`, so this single mapping covers them.
    ///
    /// `DownloadUtils.downloadRepo` compresses byte progress into 0.0–0.5 and
    /// reserves 0.5–1.0 for a CoreML compile step that only its `loadModels`
    /// entry point runs — the app never does, so an unscaled fraction leaves the
    /// bar frozen at 50% for a completed download. Rescale each phase back onto
    /// its own full 0…1 range.
    init(_ fluid: DownloadUtils.DownloadProgress) {
        let phase: Phase
        let fraction: Double
        switch fluid.phase {
        case .listing:
            phase = .preparing
            fraction = fluid.fractionCompleted
        case .downloading:
            phase = .downloading
            fraction = min(fluid.fractionCompleted * 2, 1)
        case .compiling:
            phase = .finalizing
            fraction = min(max((fluid.fractionCompleted - 0.5) * 2, 0), 1)
        }
        self.init(fraction: fraction, phase: phase)
    }
}
