import Foundation

/// How much of a recording's wall-clock time actually reached the capture
/// file. A flaky USB hub or a mic that stops delivering frames produces a
/// file dramatically shorter than the time the user spent talking; content
/// heuristics (clipping, silence, noise) run on such a fragment misdiagnose
/// badly — a 2 ms session-start pop reads as "very loud and clipping".
enum DictationCaptureIntegrity: Equatable {
    /// The file covers (roughly) the whole recording.
    case intact
    /// The device delivered audio for only part of the recording: the
    /// captured tail may transcribe, but earlier words are gone.
    case truncated(capturedSeconds: TimeInterval, wallSeconds: TimeInterval)
    /// The device delivered essentially nothing — typically a few
    /// milliseconds of start transient, or a fully empty file.
    case starved(capturedSeconds: TimeInterval, wallSeconds: TimeInterval)
}

enum DictationCaptureIntegrityPolicy {
    /// Below this wall-clock length a short file can't be blamed on the
    /// device: quick taps and instant stops legitimately capture little.
    static let minimumAssessableWallSeconds: TimeInterval = 1.5
    /// At or below this the file holds a start transient, not speech — the
    /// device never delivered (observed field stubs run 2–4 ms).
    static let starvedCapturedSecondsCeiling: TimeInterval = 0.35
    /// Captured/wall fraction under which enough speech is missing to
    /// warrant a warning even when transcription of the tail succeeded.
    static let truncatedCaptureFraction: Double = 0.5
    /// And at least this much audio must actually be missing.
    static let truncatedMissingSecondsFloor: TimeInterval = 1.0

    static func assessment(
        wallSeconds: TimeInterval,
        capturedSeconds: TimeInterval
    ) -> DictationCaptureIntegrity {
        guard wallSeconds.isFinite,
              capturedSeconds.isFinite,
              wallSeconds >= minimumAssessableWallSeconds else {
            return .intact
        }
        let captured = max(0, capturedSeconds)
        if captured <= starvedCapturedSecondsCeiling {
            return .starved(capturedSeconds: captured, wallSeconds: wallSeconds)
        }
        if captured < wallSeconds * truncatedCaptureFraction,
           wallSeconds - captured >= truncatedMissingSecondsFloor {
            return .truncated(capturedSeconds: captured, wallSeconds: wallSeconds)
        }
        return .intact
    }
}
