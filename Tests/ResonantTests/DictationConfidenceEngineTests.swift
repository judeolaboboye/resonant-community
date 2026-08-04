import XCTest
@testable import Resonant

final class DictationConfidenceEngineTests: XCTestCase {

    func testGoodDictationScoresHighInShadowMode() {
        let snapshot = DictationConfidenceEngine.evaluate(goodInput())

        XCTAssertEqual(snapshot.overall.bucket, .high)
        XCTAssertEqual(snapshot.recognition.bucket, .high)
        XCTAssertEqual(snapshot.rewrite.bucket, .high)
        XCTAssertEqual(snapshot.delivery.bucket, .high)
        XCTAssertTrue(snapshot.learningEligible)
        XCTAssertTrue(snapshot.rawTranscriptHabitEligible)
        XCTAssertEqual(
            snapshot.learningCapabilities,
            [.correctionDerivedMutations, .rawTranscriptHabits]
        )
        XCTAssertTrue(snapshot.autoSendEligible)
    }

    func testSparseAudioAndTranscriptScoresLowRecognition() {
        var input = goodInput()
        input.rawTranscript = "Ok"
        input.captureDiagnostics = DictationCaptureDiagnostics(sampleCount: 96_000)
        input.recognitionDiagnostics = DictationAudioAnalyzer.Diagnostics(
            audioDurationSeconds: 6.0,
            peakRMS: 0.001,
            truePeak: 0.003,
            clipRatio: 0,
            meanRMS: 0.0002,
            noiseFloorRMS: 0.0001,
            thresholdRMS: 0.0009,
            frameCount: 600,
            speechSegmentCount: 0,
            voicedDurationSeconds: 0,
            segmenterSource: .sileroVAD
        )

        let snapshot = DictationConfidenceEngine.evaluate(input)

        XCTAssertEqual(snapshot.recognition.bucket, .low)
        XCTAssertEqual(snapshot.overall.bucket, .low)
        XCTAssertFalse(snapshot.rawTranscriptHabitEligible)
        XCTAssertFalse(snapshot.learningCapabilities.allowsRawTranscriptHabits)
        XCTAssertTrue(snapshot.reasons.contains(.noSpeechSegments))
        XCTAssertTrue(snapshot.reasons.contains(.transcriptTooShortForAudio))
    }

    func testAutoSendIsNotEvaluableForDeliveryConfidence() {
        var input = goodInput()
        input.shouldSend = true

        let snapshot = DictationConfidenceEngine.evaluate(input)

        XCTAssertEqual(snapshot.delivery.bucket, .low)
        XCTAssertEqual(snapshot.overall.bucket, .low)
        XCTAssertFalse(snapshot.learningEligible)
        XCTAssertTrue(snapshot.rawTranscriptHabitEligible)
        XCTAssertEqual(snapshot.learningCapabilities, .rawTranscriptHabits)
        XCTAssertTrue(snapshot.reasons.contains(.autoSentNotEvaluable))
    }

    func testSelectionTransformDisablesBothLearningChannels() {
        var input = goodInput()
        input.selectionTransformUsed = true

        let snapshot = DictationConfidenceEngine.evaluate(input)

        XCTAssertFalse(snapshot.learningEligible)
        XCTAssertTrue(snapshot.rawTranscriptHabitEligible)
        XCTAssertEqual(snapshot.learningCapabilities, .none)
        XCTAssertTrue(snapshot.reasons.contains(.selectionTransformUsed))
    }

    func testRawTranscriptHabitEligibilityIgnoresDeliveryConfidence() {
        var input = goodInput()
        input.shouldPaste = false
        input.shouldCopy = true
        input.shouldSend = true
        input.pasteDeliveryMode = .directTyping

        let snapshot = DictationConfidenceEngine.evaluate(input)

        XCTAssertEqual(snapshot.delivery.bucket, .low)
        XCTAssertTrue(snapshot.rawTranscriptHabitEligible)
        XCTAssertEqual(snapshot.learningCapabilities, .rawTranscriptHabits)
    }

    func testSegmentRecoveryUsedLowersRecognitionConfidence() {
        var input = goodInput()
        input.segmentRecoveryTrace = .attempted(
            outcome: "used",
            used: true,
            originalTranscript: "This",
            recoveredTranscript: "This is the recovered transcript",
            speechSegmentCount: 3,
            voicedDurationSeconds: 3.0,
            segmenterSource: DictationAudioAnalyzer.SegmentationSource.sileroVAD.rawValue
        )

        let snapshot = DictationConfidenceEngine.evaluate(input)

        XCTAssertEqual(snapshot.recognition.bucket, .medium)
        XCTAssertTrue(snapshot.reasons.contains(.segmentRecoveryAttempted))
        XCTAssertTrue(snapshot.reasons.contains(.segmentRecoveryUsed))
        XCTAssertEqual(snapshot.segmentRecoveryUsed, true)
    }

    private func goodInput() -> DictationConfidenceEngine.Input {
        let text = "Please send the updated launch notes today."
        return DictationConfidenceEngine.Input(
            captureDiagnostics: DictationCaptureDiagnostics(sampleCount: 40_000),
            recognitionDiagnostics: DictationAudioAnalyzer.Diagnostics(
                audioDurationSeconds: 2.5,
                peakRMS: 0.03,
                truePeak: 0.05,
                clipRatio: 0,
                meanRMS: 0.012,
                noiseFloorRMS: 0.001,
                thresholdRMS: 0.003,
                frameCount: 250,
                speechSegmentCount: 1,
                voicedDurationSeconds: 1.9,
                segmenterSource: .sileroVAD
            ),
            segmentRecoveryTrace: .skipped(
                outcome: "not_needed",
                originalTranscript: text,
                speechSegmentCount: 1,
                voicedDurationSeconds: 1.9,
                segmenterSource: DictationAudioAnalyzer.SegmentationSource.sileroVAD.rawValue
            ),
            rawTranscript: text,
            postProcessingTrace: PostProcessingTrace(
                rawCharacterCount: text.count,
                finalCharacterCount: text.count,
                rawLengthBucket: PostProcessingTrace.lengthBucket(text.count),
                finalLengthBucket: PostProcessingTrace.lengthBucket(text.count),
                changed: false,
                stageChanges: []
            ),
            contextPacket: nil,
            cleanup: .skipped(reason: "cloud_disabled"),
            transform: .notApplicable,
            selectionTransformUsed: false,
            targetBundleId: "com.apple.mail",
            windowTitle: nil,
            browserURL: nil,
            pasteDeliveryMode: .automatic,
            shouldPaste: true,
            shouldCopy: false,
            shouldSend: false
        )
    }
}
