import Foundation

enum DictationConfidenceBucket: String, Sendable, Equatable {
    case high
    case medium
    case low
    case unknown
}

struct DictationConfidenceScore: Sendable, Equatable {
    let score: Double
    let bucket: DictationConfidenceBucket

    init(_ score: Double) {
        let clamped = min(1, max(0, score))
        self.score = clamped
        switch clamped {
        case 0.92...:
            bucket = .high
        case 0.70..<0.92:
            bucket = .medium
        default:
            bucket = .low
        }
    }
}

enum DictationConfidenceReason: String, Sendable, Equatable, Hashable {
    case noCaptureDiagnostics = "no_capture_diagnostics"
    case noRecognitionDiagnostics = "no_recognition_diagnostics"
    case lowVoicedRatio = "low_voiced_ratio"
    case noSpeechSegments = "no_speech_segments"
    case fallbackSegmenterUsed = "fallback_segmenter_used"
    case transcriptTooShortForAudio = "transcript_too_short_for_audio"
    case lowWordsPerSecond = "low_words_per_second"
    case highWordsPerSecond = "high_words_per_second"
    case segmentRecoveryAttempted = "segment_recovery_attempted"
    case segmentRecoveryUsed = "segment_recovery_used"
    case noPostProcessingTrace = "no_post_processing_trace"
    case postProcessingLargeDelta = "post_processing_large_delta"
    case manyLocalRepairs = "many_local_repairs"
    case cloudCleanupRejected = "cloud_cleanup_rejected"
    case cloudCleanupFallback = "cloud_cleanup_fallback"
    case cloudCleanupFailed = "cloud_cleanup_failed"
    case sanitizerRejected = "sanitizer_rejected"
    case selectionTransformUsed = "selection_transform_used"
    case contextGroundingReduced = "context_grounding_reduced"
    case copyOnly = "copy_only"
    case autoSentNotEvaluable = "auto_sent_not_evaluable"
    case readbackUnsupportedTarget = "readback_unsupported_target"
    case directTypingDelivery = "direct_typing_delivery"
    case terminalTarget = "terminal_target"
}

struct DictationConfidenceSnapshot: Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let overall: DictationConfidenceScore
    let recognition: DictationConfidenceScore
    let rewrite: DictationConfidenceScore
    let delivery: DictationConfidenceScore
    /// Compatibility predicate for the correction-derived channel.
    let learningEligible: Bool
    /// Recognition/rewrite-only predicate for content habits. Delivery score
    /// and auto-send state intentionally do not participate.
    let rawTranscriptHabitEligible: Bool
    let learningCapabilities: LearningCapabilities
    let autoSendEligible: Bool
    let reasons: [DictationConfidenceReason]
    let voicedRatioBucket: String?
    let wordsPerSecondBucket: String?
    let segmentRecoveryAttempted: Bool?
    let segmentRecoveryUsed: Bool?
    let segmenterSource: String?
    let postProcessingChanged: Bool?
    let postProcessingChangedStageCount: Int?
    let postProcessingChangedStages: [String]?

    var reasonCodes: [String] {
        reasons.map(\.rawValue)
    }
}

enum DictationConfidenceEngine {
    struct Input: Sendable {
        var captureDiagnostics: DictationCaptureDiagnostics?
        var recognitionDiagnostics: DictationAudioAnalyzer.Diagnostics?
        var segmentRecoveryTrace: DictationSegmentRecoveryTrace?
        var rawTranscript: String
        var postProcessingTrace: PostProcessingTrace?
        var contextPacket: ContextPacket?
        var cleanup: DictationQualityTrace.Cleanup
        var transform: DictationQualityTrace.Transform
        var selectionTransformUsed: Bool
        var targetBundleId: String?
        var windowTitle: String?
        var browserURL: String?
        var pasteDeliveryMode: PasteDeliveryMode
        var shouldPaste: Bool
        var shouldCopy: Bool
        var shouldSend: Bool
    }

    static func evaluate(_ input: Input) -> DictationConfidenceSnapshot {
        var reasons: [DictationConfidenceReason] = []
        var seenReasons = Set<DictationConfidenceReason>()

        func addReason(_ reason: DictationConfidenceReason) {
            guard !seenReasons.contains(reason) else { return }
            seenReasons.insert(reason)
            reasons.append(reason)
        }

        let recognitionScore = recognitionScore(input: input, addReason: addReason)
        let rewriteScore = rewriteScore(input: input, addReason: addReason)
        let deliveryScore = deliveryScore(input: input, addReason: addReason)
        let overallScore = min(recognitionScore, rewriteScore, deliveryScore)

        let recognition = DictationConfidenceScore(recognitionScore)
        let rewrite = DictationConfidenceScore(rewriteScore)
        let delivery = DictationConfidenceScore(deliveryScore)
        let overall = DictationConfidenceScore(overallScore)
        let rawTranscriptHabitEligible = recognition.bucket != .low
            && rewrite.bucket != .low
        let correctionDerivedEligible = overall.bucket != .low
            && delivery.bucket != .low
            && !input.shouldSend
            && !input.selectionTransformUsed
        let learningCapabilities = LearningCapabilities.resolving(
            correctionDerivedEligible: correctionDerivedEligible,
            rawTranscriptHabitEligible: rawTranscriptHabitEligible,
            autoSent: input.shouldSend,
            selectionTransformUsed: input.selectionTransformUsed
        )

        return DictationConfidenceSnapshot(
            schemaVersion: DictationConfidenceSnapshot.schemaVersion,
            overall: overall,
            recognition: recognition,
            rewrite: rewrite,
            delivery: delivery,
            learningEligible: learningCapabilities.allowsCorrectionDerivedMutations,
            rawTranscriptHabitEligible: rawTranscriptHabitEligible,
            learningCapabilities: learningCapabilities,
            autoSendEligible: overall.bucket == .high && delivery.bucket == .high,
            reasons: reasons,
            voicedRatioBucket: voicedRatioBucket(input.recognitionDiagnostics),
            wordsPerSecondBucket: wordsPerSecondBucket(
                transcript: input.rawTranscript,
                diagnostics: input.recognitionDiagnostics,
                captureDiagnostics: input.captureDiagnostics
            ),
            segmentRecoveryAttempted: input.segmentRecoveryTrace?.attempted,
            segmentRecoveryUsed: input.segmentRecoveryTrace?.used,
            segmenterSource: input.segmentRecoveryTrace?.segmenterSource
                ?? input.recognitionDiagnostics?.segmenterSource.rawValue,
            postProcessingChanged: input.postProcessingTrace?.changed,
            postProcessingChangedStageCount: input.postProcessingTrace?.changedStageCount,
            postProcessingChangedStages: input.postProcessingTrace?.changedStageNames
        )
    }

    private static func recognitionScore(
        input: Input,
        addReason: (DictationConfidenceReason) -> Void
    ) -> Double {
        var score = 1.0

        if input.captureDiagnostics == nil {
            score -= 0.12
            addReason(.noCaptureDiagnostics)
        }

        guard let diagnostics = input.recognitionDiagnostics else {
            score -= 0.18
            addReason(.noRecognitionDiagnostics)
            return score
        }

        let duration = max(diagnostics.audioDurationSeconds, input.captureDiagnostics?.duration ?? 0)
        let voicedRatio = duration > 0 ? diagnostics.voicedDurationSeconds / duration : 0
        if diagnostics.speechSegmentCount == 0 {
            score -= 0.30
            addReason(.noSpeechSegments)
        }
        if duration >= 1.0, voicedRatio < 0.08 {
            score -= 0.22
            addReason(.lowVoicedRatio)
        } else if duration >= 2.0, voicedRatio < 0.16 {
            score -= 0.12
            addReason(.lowVoicedRatio)
        }
        if diagnostics.segmenterSource == .energyFallback {
            score -= 0.04
            addReason(.fallbackSegmenterUsed)
        }

        let wordCount = Self.wordCount(input.rawTranscript)
        if duration >= 4.0, wordCount <= 2 {
            score -= 0.22
            addReason(.transcriptTooShortForAudio)
        }

        let speechDuration = max(diagnostics.voicedDurationSeconds, duration, 1)
        let wordsPerSecond = Double(wordCount) / speechDuration
        if duration >= 3.0, wordCount > 0, wordsPerSecond < 0.6 {
            score -= 0.12
            addReason(.lowWordsPerSecond)
        }
        if wordsPerSecond > 5.5 {
            score -= 0.10
            addReason(.highWordsPerSecond)
        }

        if input.segmentRecoveryTrace?.attempted == true {
            score -= 0.08
            addReason(.segmentRecoveryAttempted)
        }
        if input.segmentRecoveryTrace?.used == true {
            score -= 0.08
            addReason(.segmentRecoveryUsed)
        }

        return score
    }

    private static func rewriteScore(
        input: Input,
        addReason: (DictationConfidenceReason) -> Void
    ) -> Double {
        var score = 1.0

        guard !input.selectionTransformUsed else {
            addReason(.selectionTransformUsed)
            return 0.72
        }

        if let trace = input.postProcessingTrace {
            let rawCount = max(1, trace.rawCharacterCount)
            let finalCount = trace.finalCharacterCount
            let deltaRatio = Double(abs(finalCount - rawCount)) / Double(rawCount)
            if rawCount >= 20, deltaRatio > 0.45 {
                score -= 0.18
                addReason(.postProcessingLargeDelta)
            }
            if trace.changedStageCount >= 5 {
                score -= 0.12
                addReason(.manyLocalRepairs)
            } else if trace.changedStageCount >= 3 {
                score -= 0.06
                addReason(.manyLocalRepairs)
            }
        } else {
            score -= 0.08
            addReason(.noPostProcessingTrace)
        }

        switch input.cleanup.status {
        case .accepted, .skipped, .notApplicable:
            break
        case .rejected:
            score -= 0.20
            addReason(.cloudCleanupRejected)
        case .failed:
            score -= 0.18
            addReason(.cloudCleanupFailed)
        case .fallbackLocal:
            score -= 0.12
            addReason(.cloudCleanupFallback)
        }

        if input.cleanup.sanitizerRejectReason != nil {
            score -= 0.15
            addReason(.sanitizerRejected)
        }

        if input.contextPacket?.safetyFlags.contains(.groundingDisabled) == true
            || input.contextPacket?.safetyFlags.contains(.containsUntrustedVisibleText) == true {
            score -= 0.04
            addReason(.contextGroundingReduced)
        }

        return score
    }

    private static func deliveryScore(
        input: Input,
        addReason: (DictationConfidenceReason) -> Void
    ) -> Double {
        var score = 1.0

        if !input.shouldPaste {
            if input.shouldCopy {
                score -= 0.25
                addReason(.copyOnly)
            } else {
                score -= 0.20
            }
        }

        if input.shouldSend {
            score -= 0.35
            addReason(.autoSentNotEvaluable)
        }

        if AccessibilityPlaceholderFilter.shouldBypassCorrectionReadback(
            bundleID: input.targetBundleId,
            windowTitle: input.windowTitle,
            browserURL: input.browserURL
        ) {
            score -= 0.20
            addReason(.readbackUnsupportedTarget)
        }

        switch input.pasteDeliveryMode {
        case .automatic, .accessibility:
            break
        case .clipboard:
            score -= 0.05
        case .directTyping:
            score -= 0.12
            addReason(.directTypingDelivery)
        }

        if PerformanceExperiments.targetProfile(bundleId: input.targetBundleId) == "terminal" {
            score -= 0.10
            addReason(.terminalTarget)
        }

        return score
    }

    private static func voicedRatioBucket(_ diagnostics: DictationAudioAnalyzer.Diagnostics?) -> String? {
        guard let diagnostics else { return nil }
        let duration = max(diagnostics.audioDurationSeconds, 0.001)
        return ratioBucket(diagnostics.voicedDurationSeconds / duration)
    }

    private static func wordsPerSecondBucket(
        transcript: String,
        diagnostics: DictationAudioAnalyzer.Diagnostics?,
        captureDiagnostics: DictationCaptureDiagnostics?
    ) -> String? {
        let duration = max(
            diagnostics?.voicedDurationSeconds ?? 0,
            diagnostics?.audioDurationSeconds ?? 0,
            captureDiagnostics?.duration ?? 0
        )
        guard duration > 0 else { return nil }
        let value = Double(wordCount(transcript)) / duration
        switch value {
        case ..<0:
            return "unknown"
        case 0:
            return "0"
        case 0..<0.5:
            return "0-0.5"
        case 0.5..<1.0:
            return "0.5-1.0"
        case 1.0..<2.5:
            return "1.0-2.5"
        case 2.5..<4.0:
            return "2.5-4.0"
        default:
            return "4.0+"
        }
    }

    private static func ratioBucket(_ value: Double) -> String {
        switch value {
        case ..<0:
            return "unknown"
        case 0:
            return "0"
        case 0..<0.10:
            return "0-0.10"
        case 0.10..<0.25:
            return "0.10-0.25"
        case 0.25..<0.50:
            return "0.25-0.50"
        case 0.50..<0.75:
            return "0.50-0.75"
        default:
            return "0.75+"
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
