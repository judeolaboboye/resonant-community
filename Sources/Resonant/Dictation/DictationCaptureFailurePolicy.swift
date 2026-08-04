import Foundation

enum DictationCaptureFailureDisposition: Equatable {
    case silentCancel
    case userActionRequired
    case audioUnrecognized
}

enum DictationCaptureFailurePolicy {
    static let shortWallClockThresholdMs = 500
    static let minimumMeaningfulCaptureDurationMs = 120
    /// A sub-second press whose audio never rose above the near-silence
    /// ceiling and produced zero speech segments is a fumbled/accidental
    /// trigger, not a dictation worth an error strip. Longer holds keep the
    /// visible guidance: the user was clearly waiting on a mic that gave
    /// them nothing, and silence there would hide a real hardware problem.
    static let nearSilentWallClockThresholdMs = 900
    static let nearSilentPeakDbCeiling: Float = -50
    /// Noise-relative twin of the absolute ceiling: in a loud room (machinery,
    /// AC) the peak never drops below -50 dB, but a fumbled tap still shows —
    /// zero speech segments with the peak hugging the steady noise bed means
    /// the capture contains nothing but the room.
    static let nearSilentDynamicsCeilingDb: Float = 6

    static func disposition(
        for error: Error,
        wallClockDurationMs: Int?,
        captureDiagnostics: DictationCaptureDiagnostics?,
        silenceDiagnostics: DictationAudioAnalyzer.Diagnostics? = nil
    ) -> DictationCaptureFailureDisposition {
        if requiresUserAction(error) {
            return .userActionRequired
        }

        if shouldTreatAsSilentCancel(
            wallClockDurationMs: wallClockDurationMs,
            captureDiagnostics: captureDiagnostics
        ) {
            return .silentCancel
        }

        if isNearSilentShortPress(
            wallClockDurationMs: wallClockDurationMs,
            silenceDiagnostics: silenceDiagnostics
        ) {
            return .silentCancel
        }

        return .audioUnrecognized
    }

    static func isNearSilentShortPress(
        wallClockDurationMs: Int?,
        silenceDiagnostics: DictationAudioAnalyzer.Diagnostics?
    ) -> Bool {
        guard let wallClockDurationMs,
              wallClockDurationMs < nearSilentWallClockThresholdMs,
              let diagnostics = silenceDiagnostics,
              diagnostics.speechSegmentCount == 0,
              diagnostics.peakDb.isFinite
        else {
            return false
        }
        if diagnostics.peakDb < nearSilentPeakDbCeiling {
            return true
        }
        return diagnostics.noiseFloorDb.isFinite
            && diagnostics.peakDb - diagnostics.noiseFloorDb < nearSilentDynamicsCeilingDb
    }

    static func shouldTreatAsSilentCancel(
        wallClockDurationMs: Int?,
        captureDiagnostics: DictationCaptureDiagnostics?
    ) -> Bool {
        guard let wallClockDurationMs else {
            return captureDiagnostics?.durationMilliseconds ?? 0 < minimumMeaningfulCaptureDurationMs
        }

        guard wallClockDurationMs < shortWallClockThresholdMs else {
            return false
        }

        if let captureDiagnostics {
            return captureDiagnostics.durationMilliseconds < minimumMeaningfulCaptureDurationMs
        }

        return true
    }

    static func shouldPresentCaptureFailure(
        _ disposition: DictationCaptureFailureDisposition
    ) -> Bool {
        disposition != .silentCancel
    }

    private static func requiresUserAction(_ error: Error) -> Bool {
        if case DictationError.noModelSelected = error { return true }
        if case TranscriberError.notLoaded = error { return true }
        if case TranscriberError.notDownloaded = error { return true }
        return false
    }
}

enum DictationDeliveryFailurePresentation: Equatable {
    case copiedFallbackNotice
    case copiedFallbackIssue
    case blockingIssue
}

enum DictationDeliveryFailurePolicy {
    static func presentation(
        copiedFallback: Bool,
        recoverableIssueNoticesEnabled: Bool
    ) -> DictationDeliveryFailurePresentation {
        guard copiedFallback else {
            return .blockingIssue
        }

        return recoverableIssueNoticesEnabled ? .copiedFallbackIssue : .copiedFallbackNotice
    }
}
