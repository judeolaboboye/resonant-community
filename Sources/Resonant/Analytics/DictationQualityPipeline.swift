import Foundation
import os

struct DictationQualityTrace: Sendable, Equatable {
    enum CleanupStatus: String, Sendable {
        case notApplicable = "not_applicable"
        case skipped
        case accepted
        case rejected
        case failed
        case fallbackLocal = "fallback_local"
    }

    enum TransformStatus: String, Sendable {
        case notApplicable = "not_applicable"
        case attempted
        case succeeded
        case failed
    }

    struct Cleanup: Sendable, Equatable {
        var status: CleanupStatus
        var profile: String?
        var listIntent: String?
        var attempted: Bool
        var accepted: Bool?
        var path: String?
        var fallbackReason: String?
        var sanitizerRejectReason: String?
        var clientDurationMs: Int?
        var serverDurationMs: Int?
        var qualityPolicy: String?
        var qualityIssues: [String] = []
        var qualityIssuesAfterLocalRepair: [String] = []
        var qualityLocalRepairApplied: Bool = false
        var qualityIssuesAfterRepair: [String] = []
        var qualityRepairAttempted: Bool = false
        var qualityRepairAccepted: Bool?
        var qualityRepairRejectReason: String?
        var qualityRepairClientDurationMs: Int?
        var qualityRepairServerDurationMs: Int?
        var contextPersonalizationCloudEntitySubmittedCount: Int = 0
        var contextPersonalizationCloudStyleSubmitted: Bool = false

        static let notApplicable = Cleanup(
            status: .notApplicable,
            profile: nil,
            listIntent: nil,
            attempted: false,
            accepted: nil,
            path: nil,
            fallbackReason: nil,
            sanitizerRejectReason: nil,
            clientDurationMs: nil,
            serverDurationMs: nil
        )

        static func skipped(reason: String, profile: String? = nil, listIntent: String? = nil) -> Cleanup {
            Cleanup(
                status: .skipped,
                profile: profile,
                listIntent: listIntent,
                attempted: false,
                accepted: nil,
                path: nil,
                fallbackReason: reason,
                sanitizerRejectReason: nil,
                clientDurationMs: nil,
                serverDurationMs: nil
            )
        }

        static func fallbackLocal(reason: String, profile: String? = nil, listIntent: String? = nil) -> Cleanup {
            Cleanup(
                status: .fallbackLocal,
                profile: profile,
                listIntent: listIntent,
                attempted: false,
                accepted: false,
                path: nil,
                fallbackReason: reason,
                sanitizerRejectReason: nil,
                clientDurationMs: nil,
                serverDurationMs: nil
            )
        }

        /// Merge with max/OR so a primary request and its repair/fallback do
        /// not double-count the same learned payload values.
        mutating func recordCloudContextSubmission(
            _ submission: CloudContextPersonalizationSubmission
        ) {
            contextPersonalizationCloudEntitySubmittedCount = min(
                max(
                    contextPersonalizationCloudEntitySubmittedCount,
                    submission.learnedEntitySubmittedCount
                ),
                ContextPersonalizationExposure.maximumCount
            )
            contextPersonalizationCloudStyleSubmitted =
                contextPersonalizationCloudStyleSubmitted || submission.learnedStyleSubmitted
        }

        var contextPersonalizationCloudSubmission: CloudContextPersonalizationSubmission {
            CloudContextPersonalizationSubmission(
                learnedEntitySubmittedCount: contextPersonalizationCloudEntitySubmittedCount,
                learnedStyleSubmitted: contextPersonalizationCloudStyleSubmitted
            )
        }
    }

    struct Transform: Sendable, Equatable {
        var status: TransformStatus
        var attempted: Bool
        var succeeded: Bool?
        var failureReason: String?
        var clientDurationMs: Int?

        static let notApplicable = Transform(
            status: .notApplicable,
            attempted: false,
            succeeded: nil,
            failureReason: nil,
            clientDurationMs: nil
        )
    }

    struct Latencies: Sendable, Equatable {
        var totalMs: Int?
        var transcriptionMs: Int?
        var postProcessMs: Int?
        var resolveDeliveryMs: Int?
        var cloudCleanupMs: Int?
        var transformMs: Int?
        var pasteSetupMs: Int?
        var pasteMs: Int?

        init(event: PerformanceExperiments.DictationLatencyEvent?) {
            totalMs = event?.totalMs
            transcriptionMs = event?.transcriptionMs
            postProcessMs = event?.postProcessMs
            resolveDeliveryMs = event?.resolveDeliveryMs
            cloudCleanupMs = event?.cloudCleanupMs
            transformMs = event?.transformMs
            pasteSetupMs = event?.pasteSetupMs
            pasteMs = event?.pasteMs
        }
    }

    var dictationID: String?
    var mode: String
    var model: String?
    var targetBundleId: String?
    var surfaceKind: String?
    var pasteDeliveryMode: String
    var autoPaste: Bool
    var autoSend: Bool
    var copyToClipboard: Bool
    var cloudProcessingEnabled: Bool
    var lowLatencyMode: Bool
    var selectionTransformUsed: Bool
    var cleanup: Cleanup
    var transform: Transform
    var confidence: DictationConfidenceSnapshot?
    /// Final, text-free context-personalization exposure built at the physical
    /// delivery boundary from packet offers and actual consumer provenance.
    var contextPersonalization: ContextPersonalizationExposure? = nil
    /// Term-free vocabulary-boost totals. Raw audit decisions intentionally
    /// never enter the quality pipeline's untyped property dictionary.
    var boostCounts: VocabularyBoostAudit.Counts
    var latencies: Latencies
}

enum DictationQualityReadbackStatus: String, Sendable {
    case accepted
    case corrected
    case stale
    case bypassed
    case noFieldContent = "no_field_content"
    case regionNotFound = "region_not_found"
    case observationReplaced = "observation_replaced"
    case observationCancelled = "observation_cancelled"
    case autoSent = "auto_sent"
    /// The outcome actor could not accept the registration, so no readback was
    /// started. Emitted so a broken personalization store stays visible in
    /// telemetry instead of silently removing the dictation from the feed.
    case personalizationUnavailable = "personalization_unavailable"

    var isEvaluable: Bool {
        switch self {
        case .accepted, .corrected:
            return true
        case .stale, .bypassed, .noFieldContent, .regionNotFound, .observationReplaced,
                .observationCancelled, .autoSent, .personalizationUnavailable:
            return false
        }
    }
}

@MainActor
enum DictationQualityPipeline {
    private static let log = Logger.resonant("DictationQuality")

    static func recordReadback(
        trace: DictationQualityTrace?,
        status: DictationQualityReadbackStatus,
        pastedText: String?,
        editedText: String?,
        correctionCount: Int?,
        observationAgeMs: Int?
    ) {
        guard let trace else { return }

        let properties = readbackProperties(
            trace: trace,
            status: status,
            pastedText: pastedText,
            editedText: editedText,
            correctionCount: correctionCount,
            observationAgeMs: observationAgeMs
        )
        logConfidence(trace.confidence, status: status)
        AnalyticsManager.shared.capture("dictation_quality_v1", properties: properties)
    }

    /// Pure event-property seam used by integration and privacy tests. Text is
    /// consumed only to derive bounded metrics and is never returned.
    static func readbackProperties(
        trace: DictationQualityTrace,
        status: DictationQualityReadbackStatus,
        pastedText: String?,
        editedText: String?,
        correctionCount: Int?,
        observationAgeMs: Int?
    ) -> [String: Any] {

        let editDistance: Double?
        if let pastedText, let editedText {
            editDistance = PersonalizationEvaluationEngine.normalizedEditDistance(
                from: pastedText,
                to: editedText
            )
        } else {
            editDistance = nil
        }

        var properties: [String: Any] = [
            "schema_version": 4,
            "pipeline_name": "dictation_quality",
            "measurement_point": "post_paste_readback",
            "delivery_status": "delivered",
            "mode": trace.mode,
            "target_profile": PerformanceExperiments.targetProfile(bundleId: trace.targetBundleId),
            "paste_delivery_mode": trace.pasteDeliveryMode,
            "auto_paste_enabled": trace.autoPaste,
            "auto_send_enabled": trace.autoSend,
            "copy_to_clipboard_enabled": trace.copyToClipboard,
            "cloud_processing_enabled": trace.cloudProcessingEnabled,
            "low_latency_mode": trace.lowLatencyMode,
            "selection_transform_used": trace.selectionTransformUsed,
            "cleanup_status": trace.cleanup.status.rawValue,
            "cleanup_attempted": trace.cleanup.attempted,
            "transform_status": trace.transform.status.rawValue,
            "transform_attempted": trace.transform.attempted,
            "readback_status": status.rawValue,
            "quality_evaluable": status.isEvaluable,
            "readback_evaluable": status.isEvaluable,
            "accepted_readback": status == .accepted,
            "corrected_readback": status == .corrected,
            "zero_edit_proxy": status == .accepted
        ]

        properties["model_family"] = AnalyticsModelFamily.classify(modelID: trace.model)

        for (key, value) in boostProperties(for: trace.boostCounts) {
            properties[key] = value
        }

        for (key, value) in contextPersonalizationProperties(
            exposure: trace.contextPersonalization
        ) {
            properties[key] = value
        }

        add("surface_kind", trace.surfaceKind, to: &properties)
        add("cleanup_profile", trace.cleanup.profile, to: &properties)
        add("cleanup_list_intent", trace.cleanup.listIntent, to: &properties)
        add("cleanup_path", trace.cleanup.path, to: &properties)
        add("cleanup_fallback_reason", trace.cleanup.fallbackReason, to: &properties)
        add("cleanup_sanitizer_reject_reason", trace.cleanup.sanitizerRejectReason, to: &properties)
        add("cleanup_accepted", trace.cleanup.accepted, to: &properties)
        add("cleanup_client_duration_ms", trace.cleanup.clientDurationMs, to: &properties)
        add("cleanup_server_duration_ms", trace.cleanup.serverDurationMs, to: &properties)
        add("quality_policy", trace.cleanup.qualityPolicy, to: &properties)
        if !trace.cleanup.qualityIssues.isEmpty {
            properties["quality_lint_issues"] = trace.cleanup.qualityIssues
        }
        if !trace.cleanup.qualityIssuesAfterLocalRepair.isEmpty {
            properties["quality_lint_issues_after_local_repair"] = trace.cleanup.qualityIssuesAfterLocalRepair
        }
        properties["quality_local_repair_applied"] = trace.cleanup.qualityLocalRepairApplied
        if !trace.cleanup.qualityIssuesAfterRepair.isEmpty {
            properties["quality_lint_issues_after_repair"] = trace.cleanup.qualityIssuesAfterRepair
        }
        properties["quality_repair_attempted"] = trace.cleanup.qualityRepairAttempted
        add("quality_repair_accepted", trace.cleanup.qualityRepairAccepted, to: &properties)
        add("quality_repair_reject_reason", trace.cleanup.qualityRepairRejectReason, to: &properties)
        add("quality_repair_client_duration_ms", trace.cleanup.qualityRepairClientDurationMs, to: &properties)
        add("quality_repair_server_duration_ms", trace.cleanup.qualityRepairServerDurationMs, to: &properties)
        add("transform_succeeded", trace.transform.succeeded, to: &properties)
        add("transform_failure_reason", trace.transform.failureReason, to: &properties)
        add("transform_client_duration_ms", trace.transform.clientDurationMs, to: &properties)
        add("confidence_schema_version", trace.confidence?.schemaVersion, to: &properties)
        add("confidence_overall_bucket", trace.confidence?.overall.bucket.rawValue, to: &properties)
        add("confidence_recognition_bucket", trace.confidence?.recognition.bucket.rawValue, to: &properties)
        add("confidence_rewrite_bucket", trace.confidence?.rewrite.bucket.rawValue, to: &properties)
        add("confidence_delivery_bucket", trace.confidence?.delivery.bucket.rawValue, to: &properties)
        add("confidence_reason_count", trace.confidence.map { min($0.reasons.count, 8) }, to: &properties)
        add("learning_eligible", trace.confidence?.learningEligible, to: &properties)
        add("auto_send_eligible", trace.confidence?.autoSendEligible, to: &properties)
        add("confidence_reasons", trace.confidence.map { confidenceReasons($0) }, to: &properties)
        add("voiced_ratio_bucket", trace.confidence?.voicedRatioBucket, to: &properties)
        add("words_per_second_bucket", trace.confidence?.wordsPerSecondBucket, to: &properties)
        add("segment_recovery_attempted", trace.confidence?.segmentRecoveryAttempted, to: &properties)
        add("segment_recovery_used", trace.confidence?.segmentRecoveryUsed, to: &properties)
        add("segmenter_source", trace.confidence?.segmenterSource, to: &properties)
        add("postproc_changed", trace.confidence?.postProcessingChanged, to: &properties)
        add("postproc_changed_stage_count", trace.confidence?.postProcessingChangedStageCount, to: &properties)
        add(
            "postproc_changed_stages",
            trace.confidence?.postProcessingChangedStages.map { $0.joined(separator: ",") },
            to: &properties
        )
        add("observation_age_ms", observationAgeMs.map { min(max($0, 0), 300_000) }, to: &properties)
        add("correction_count", correctionCount.map { min(max($0, 0), 100) }, to: &properties)
        add("normalized_edit_distance", editDistance.map { rounded($0) }, to: &properties)
        add("normalized_edit_distance_bucket", editDistance.map(editDistanceBucket), to: &properties)
        add("pasted_length_bucket", pastedText.map { lengthBucket($0.count) }, to: &properties)
        add("edited_length_bucket", editedText.map { lengthBucket($0.count) }, to: &properties)
        add("total_ms", trace.latencies.totalMs, to: &properties)
        add("transcription_ms", trace.latencies.transcriptionMs, to: &properties)
        add("post_process_ms", trace.latencies.postProcessMs, to: &properties)
        add("resolve_delivery_ms", trace.latencies.resolveDeliveryMs, to: &properties)
        add("cloud_cleanup_ms", trace.latencies.cloudCleanupMs, to: &properties)
        add("transform_ms", trace.latencies.transformMs, to: &properties)
        add("paste_setup_ms", trace.latencies.pasteSetupMs, to: &properties)
        add("paste_ms", trace.latencies.pasteMs, to: &properties)

        for assignment in PerformanceExperiments.shared.activeAssignments() {
            properties["experiment_\(assignment.experiment.rawValue)"] = assignment.variant
        }

        return properties
    }

    /// Exact analytics boundary for boost observability. This accepts only the
    /// aggregate value type, so term/original strings cannot be attached by
    /// accident when the surrounding event dictionary evolves.
    static func boostProperties(
        for counts: VocabularyBoostAudit.Counts
    ) -> [String: Int] {
        [
            "boost_applied_count": counts.applied,
            "boost_vetoed_count": counts.vetoed,
            "boost_dropped_with_veto_count": counts.droppedWithVeto,
            "boost_guarded_veto_count": counts.guardedVeto,
        ]
    }

    static func contextPersonalizationProperties(
        exposure: ContextPersonalizationExposure?
    ) -> [String: Any] {
        guard let exposure else { return [:] }
        return [
            "context_personalization_policy": ContextPersonalizationPolicy.name,
            "context_personalization_policy_version": min(
                max(exposure.policyVersion, 0),
                ContextPersonalizationExposure.maximumPolicyVersion
            ),
            "context_personalization_holdout_rate": min(
                max(exposure.configuredHoldoutRate, 0),
                100
            ),
            "context_personalization_assigned_variant": exposure.assignedVariant.rawValue,
            "context_personalization_opportunity": exposure.personalizationOpportunity,
            "context_personalization_withheld_by_holdout": exposure.withheldByHoldout,
            "context_personalization_packet_entity_offered_count": min(
                max(exposure.packetEntityOfferedCount, 0),
                ContextPersonalizationExposure.maximumCount
            ),
            "context_personalization_packet_style_offered": exposure.packetStyleOffered,
            "context_personalization_local_entity_considered_count": min(
                max(exposure.localLearnedEntityConsideredCount, 0),
                ContextPersonalizationExposure.maximumCount
            ),
            "context_personalization_local_entity_matched_count": min(
                max(exposure.localLearnedEntityMatchedCount, 0),
                ContextPersonalizationExposure.maximumCount
            ),
            "context_personalization_local_entity_applied_count": min(
                max(exposure.localLearnedEntityAppliedCount, 0),
                ContextPersonalizationExposure.maximumCount
            ),
            "context_personalization_local_style_applied": exposure.localStyleApplied,
            "context_personalization_cloud_entity_submitted_count": min(
                max(exposure.cloudLearnedEntitySubmittedCount, 0),
                ContextPersonalizationExposure.maximumCount
            ),
            "context_personalization_cloud_style_submitted": exposure.cloudLearnedStyleSubmitted,
            "context_personalization_applied": exposure.personalizationApplied,
        ]
    }

    private static func add(_ key: String, _ value: Any?, to properties: inout [String: Any]) {
        guard let value else { return }
        properties[key] = value
    }

    private static func confidenceReasons(_ confidence: DictationConfidenceSnapshot) -> String {
        confidence.reasonCodes
            .prefix(8)
            .joined(separator: ",")
    }

    private static func logConfidence(
        _ confidence: DictationConfidenceSnapshot?,
        status: DictationQualityReadbackStatus
    ) {
        guard let confidence else {
            log.info("dictation_quality_v1 confidence=missing readback=\(status.rawValue, privacy: .public) evaluable=\(status.isEvaluable, privacy: .public)")
            return
        }

        log.info(
            "dictation_quality_v1 confidence overall=\(confidence.overall.bucket.rawValue, privacy: .public) recognition=\(confidence.recognition.bucket.rawValue, privacy: .public) rewrite=\(confidence.rewrite.bucket.rawValue, privacy: .public) delivery=\(confidence.delivery.bucket.rawValue, privacy: .public) readback=\(status.rawValue, privacy: .public) evaluable=\(status.isEvaluable, privacy: .public) reasons=\(confidenceReasons(confidence), privacy: .public)"
        )
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    private static func editDistanceBucket(_ value: Double) -> String {
        switch value {
        case ..<0:
            return "unknown"
        case 0:
            return "0"
        case 0..<0.02:
            return "0-0.02"
        case 0.02..<0.05:
            return "0.02-0.05"
        case 0.05..<0.10:
            return "0.05-0.10"
        case 0.10..<0.25:
            return "0.10-0.25"
        default:
            return "0.25+"
        }
    }

    private static func lengthBucket(_ count: Int) -> String {
        switch count {
        case ..<0:
            return "unknown"
        case 0:
            return "0"
        case 1...40:
            return "1-40"
        case 41...120:
            return "41-120"
        case 121...400:
            return "121-400"
        case 401...1000:
            return "401-1000"
        default:
            return "1000+"
        }
    }
}

/// One-outcome analytics boundary for runtime vocabulary-boost attempts.
/// AppState may attach `capture(_:)` to the recorder's outcome hook. Cumulative
/// snapshots remain local-only: sending them remotely on every update would
/// double-count earlier attempts. Neither this builder nor its closed schema
/// can represent a term, transcript, model path, download error, or identifier.
enum VocabularyBoostAttemptTelemetry {
    static let eventName = "vocabulary_boost_attempt_v1"

    static var metricPropertyKeys: Set<String> {
        var keys: Set<String> = [
            "schema_version",
            "pipeline_name",
            "attempt_total_count",
        ]
        for reason in VocabularyBoostAttemptSkipReason.allCases {
            keys.insert(skipKey(reason))
        }
        for result in VocabularyBoostAttemptResult.allCases {
            for language in VocabularyBoostAttemptLanguageMode.allCases {
                keys.insert(attemptKey(result: result, language: language))
            }
        }
        return keys
    }

    static func properties(for outcome: VocabularyBoostAttemptOutcome) -> [String: Any] {
        var properties: [String: Any] = [
            "schema_version": 1,
            "pipeline_name": "vocabulary_boost_attempt",
            "attempt_total_count": 1,
        ]
        switch outcome {
        case .skipped(let reason):
            properties[skipKey(reason)] = 1
        case .attempted(let result, let language):
            properties[attemptKey(result: result, language: language)] = 1
        }
        return properties
    }

    @MainActor
    static func capture(_ outcome: VocabularyBoostAttemptOutcome) {
        AnalyticsManager.shared.capture(eventName, properties: properties(for: outcome))
    }

    private static func skipKey(_ reason: VocabularyBoostAttemptSkipReason) -> String {
        "skip_\(reason.rawValue)_count"
    }

    private static func attemptKey(
        result: VocabularyBoostAttemptResult,
        language: VocabularyBoostAttemptLanguageMode
    ) -> String {
        "attempt_\(language.rawValue)_\(result.rawValue)_count"
    }

}
