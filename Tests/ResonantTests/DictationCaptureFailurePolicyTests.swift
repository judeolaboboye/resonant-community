import XCTest
@testable import Resonant

final class DictationCaptureFailurePolicyTests: XCTestCase {

    func testUserActionErrorsOverrideShortCaptureHeuristics() {
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: TranscriberError.notLoaded,
            wallClockDurationMs: 120,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 800)
        )

        XCTAssertEqual(disposition, .userActionRequired)
    }

    func testShortNearEmptyCaptureIsSilentCancel() {
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 280,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 1_600)
        )

        XCTAssertEqual(disposition, .silentCancel)
    }

    func testShortButMeaningfulCaptureIsNotSilentCancel() {
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 280,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 4_800)
        )

        XCTAssertEqual(disposition, .audioUnrecognized)
    }

    func testBorderlineSingleWordCaptureIsNotSilentCancel() {
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 220,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 2_080)
        )

        XCTAssertEqual(disposition, .audioUnrecognized)
    }

    func testLongWallClockCaptureIsNotSilentCancelEvenWhenSparse() {
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 900,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 1_200)
        )

        XCTAssertEqual(disposition, .audioUnrecognized)
    }

    func testSilentCancelPresentationStaysHidden() {
        XCTAssertFalse(DictationCaptureFailurePolicy.shouldPresentCaptureFailure(.silentCancel))
    }

    func testAudioUnrecognizedPresentationIsAlwaysVisible() {
        XCTAssertTrue(DictationCaptureFailurePolicy.shouldPresentCaptureFailure(.audioUnrecognized))
    }

    func testUserActionErrorsAreAlwaysVisible() {
        XCTAssertTrue(DictationCaptureFailurePolicy.shouldPresentCaptureFailure(.userActionRequired))
    }

    func testDeliveryFallbackUsesCompactNoticeWhenDetailedNoticesAreDisabled() {
        XCTAssertEqual(
            DictationDeliveryFailurePolicy.presentation(
                copiedFallback: true,
                recoverableIssueNoticesEnabled: false
            ),
            .copiedFallbackNotice
        )
    }

    func testDeliveryFallbackUsesIssuePopupWhenDetailedNoticesAreEnabled() {
        XCTAssertEqual(
            DictationDeliveryFailurePolicy.presentation(
                copiedFallback: true,
                recoverableIssueNoticesEnabled: true
            ),
            .copiedFallbackIssue
        )
    }

    func testBlockingDeliveryFailureAlwaysUsesIssuePopup() {
        XCTAssertEqual(
            DictationDeliveryFailurePolicy.presentation(
                copiedFallback: false,
                recoverableIssueNoticesEnabled: false
            ),
            .blockingIssue
        )
        XCTAssertEqual(
            DictationDeliveryFailurePolicy.presentation(
                copiedFallback: false,
                recoverableIssueNoticesEnabled: true
            ),
            .blockingIssue
        )
    }
}

// MARK: - Near-silent short-press widening

extension DictationCaptureFailurePolicyTests {

    private func silenceDiagnostics(
        peakRMS: Float,
        speechSegmentCount: Int
    ) -> DictationAudioAnalyzer.Diagnostics {
        DictationAudioAnalyzer.Diagnostics(
            audioDurationSeconds: 0.7,
            peakRMS: peakRMS,
            truePeak: peakRMS * 2,
            clipRatio: 0,
            meanRMS: peakRMS / 2,
            noiseFloorRMS: 0.0002,
            thresholdRMS: 0.0009,
            frameCount: 70,
            speechSegmentCount: speechSegmentCount,
            voicedDurationSeconds: speechSegmentCount > 0 ? 0.3 : 0,
            segmenterSource: .energyFallback
        )
    }

    func testNearSilentShortPressIsSilentCancel() {
        // 700ms press, peak ~-60 dB, no speech segments: a fumbled trigger,
        // not a dictation worth an error strip.
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 700,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 11_200),
            silenceDiagnostics: silenceDiagnostics(peakRMS: 0.001, speechSegmentCount: 0)
        )

        XCTAssertEqual(disposition, .silentCancel)
    }

    func testNearSilentLongHoldStillShowsGuidance() {
        // Holding past the bound means the user was waiting on a mic that gave
        // them nothing — silence here would hide a real hardware problem.
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 1_500,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 24_000),
            silenceDiagnostics: silenceDiagnostics(peakRMS: 0.001, speechSegmentCount: 0)
        )

        XCTAssertEqual(disposition, .audioUnrecognized)
    }

    func testShortPressWithSpeechLevelAudioStillShowsGuidance() {
        // Speech-level peak (~-26 dB): the user said something — never
        // swallow that silently.
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 700,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 11_200),
            silenceDiagnostics: silenceDiagnostics(peakRMS: 0.05, speechSegmentCount: 0)
        )

        XCTAssertEqual(disposition, .audioUnrecognized)
    }

    func testShortQuietPressWithSpeechSegmentsStillShowsGuidance() {
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 700,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 11_200),
            silenceDiagnostics: silenceDiagnostics(peakRMS: 0.001, speechSegmentCount: 1)
        )

        XCTAssertEqual(disposition, .audioUnrecognized)
    }

    func testMissingSilenceDiagnosticsKeepsLegacyBehavior() {
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 700,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 11_200),
            silenceDiagnostics: nil
        )

        XCTAssertEqual(disposition, .audioUnrecognized)
    }

    func testUserActionErrorsAreNeverSilentCancelledByNearSilence() {
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: TranscriberError.notDownloaded,
            wallClockDurationMs: 700,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 11_200),
            silenceDiagnostics: silenceDiagnostics(peakRMS: 0.001, speechSegmentCount: 0)
        )

        XCTAssertEqual(disposition, .userActionRequired)
    }
}

// MARK: - Noise-relative tap detection (loud environments)

extension DictationCaptureFailurePolicyTests {

    private func noisyRoomDiagnostics(
        peakRMS: Float,
        noiseFloorRMS: Float,
        speechSegmentCount: Int = 0
    ) -> DictationAudioAnalyzer.Diagnostics {
        DictationAudioAnalyzer.Diagnostics(
            audioDurationSeconds: 0.7,
            peakRMS: peakRMS,
            truePeak: peakRMS * 2,
            clipRatio: 0,
            meanRMS: peakRMS / 2,
            noiseFloorRMS: noiseFloorRMS,
            thresholdRMS: noiseFloorRMS * 3,
            frameCount: 70,
            speechSegmentCount: speechSegmentCount,
            voicedDurationSeconds: speechSegmentCount > 0 ? 0.3 : 0,
            segmenterSource: .energyFallback
        )
    }

    func testNoisyRoomTapWithNoDynamicsIsSilentCancel() {
        // Machinery bed: peak -35 dB hugging a -38 dB floor (3 dB dynamics),
        // zero segments — the capture contains nothing but the room.
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 700,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 11_200),
            silenceDiagnostics: noisyRoomDiagnostics(peakRMS: 0.0178, noiseFloorRMS: 0.0126)
        )

        XCTAssertEqual(disposition, .silentCancel)
    }

    func testNoisyRoomTapWithSpeechDynamicsStillShowsGuidance() {
        // Peak -20 dB over a -40 dB floor: something rose well above the bed.
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 700,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 11_200),
            silenceDiagnostics: noisyRoomDiagnostics(peakRMS: 0.1, noiseFloorRMS: 0.01)
        )

        XCTAssertEqual(disposition, .audioUnrecognized)
    }

    func testNoisyRoomLongHoldStillShowsGuidance() {
        let disposition = DictationCaptureFailurePolicy.disposition(
            for: DictationError.emptyTranscription,
            wallClockDurationMs: 1_500,
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 24_000),
            silenceDiagnostics: noisyRoomDiagnostics(peakRMS: 0.0178, noiseFloorRMS: 0.0126)
        )

        XCTAssertEqual(disposition, .audioUnrecognized)
    }
}
