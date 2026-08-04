import XCTest
@testable import Resonant

final class AnalyticsEventSanitizerTests: XCTestCase {

    func testRedactsFreeformSupportText() {
        let properties = AnalyticsEventSanitizer.sanitizedProperties([
            "description": "My private bug report text",
            "prompt": "Sensitive dictated content",
            "severity": "should-fix",
        ])

        XCTAssertEqual(properties["description"] as? String, AnalyticsEventSanitizer.redactedPlaceholder)
        XCTAssertEqual(properties["prompt"] as? String, AnalyticsEventSanitizer.redactedPlaceholder)
        XCTAssertEqual(properties["severity"] as? String, "should-fix")
    }

    func testPreservesQualityMetricFieldsWhenPayloadIsCapped() {
        var input: [String: Any] = Dictionary(
            uniqueKeysWithValues: (0..<120).map { index in
                ("aaa_filler_\(index)", index)
            }
        )
        input["accepted_readback"] = true
        input["quality_evaluable"] = true
        input["readback_status"] = "accepted"
        input["zero_edit_proxy"] = true
        input["boost_applied_count"] = 2
        input["boost_vetoed_count"] = 3
        input["boost_dropped_with_veto_count"] = 1
        input["boost_guarded_veto_count"] = 2

        let properties = AnalyticsEventSanitizer.sanitizedProperties(input)

        XCTAssertLessThanOrEqual(properties.count, 80)
        XCTAssertEqual(properties["accepted_readback"] as? Bool, true)
        XCTAssertEqual(properties["quality_evaluable"] as? Bool, true)
        XCTAssertEqual(properties["readback_status"] as? String, "accepted")
        XCTAssertEqual(properties["zero_edit_proxy"] as? Bool, true)
        XCTAssertEqual(properties["boost_applied_count"] as? Int, 2)
        XCTAssertEqual(properties["boost_vetoed_count"] as? Int, 3)
        XCTAssertEqual(properties["boost_dropped_with_veto_count"] as? Int, 1)
        XCTAssertEqual(properties["boost_guarded_veto_count"] as? Int, 2)
    }

    func testPreservesConfidenceMetricFieldsWhenPayloadIsCapped() {
        var input: [String: Any] = Dictionary(
            uniqueKeysWithValues: (0..<120).map { index in
                ("aaa_filler_\(index)", index)
            }
        )
        input["confidence_overall_bucket"] = "high"
        input["confidence_recognition_bucket"] = "high"
        input["confidence_rewrite_bucket"] = "medium"
        input["confidence_delivery_bucket"] = "high"
        input["confidence_reasons"] = "segment_recovery_used"
        input["postproc_changed_stage_count"] = 2

        let properties = AnalyticsEventSanitizer.sanitizedProperties(input)

        XCTAssertLessThanOrEqual(properties.count, 80)
        XCTAssertEqual(properties["confidence_overall_bucket"] as? String, "high")
        XCTAssertEqual(properties["confidence_recognition_bucket"] as? String, "high")
        XCTAssertEqual(properties["confidence_rewrite_bucket"] as? String, "medium")
        XCTAssertEqual(properties["confidence_delivery_bucket"] as? String, "high")
        XCTAssertEqual(properties["confidence_reasons"] as? String, "segment_recovery_used")
        XCTAssertEqual(properties["postproc_changed_stage_count"] as? Int, 2)
    }

    func testClassifiesCancelledCloudFailuresAsDroppable() {
        let errorProperties = AnalyticsEventSanitizer.errorProperties(for: URLError(.cancelled))

        XCTAssertEqual(errorProperties["error_kind"] as? String, "cancelled")
        XCTAssertTrue(
            AnalyticsEventSanitizer.shouldDropCapturedEvent(
                eventName: "cloud_processing_failed",
                properties: errorProperties
            )
        )
    }

    func testUsesStructuredConvexErrorProperties() {
        let errorProperties = AnalyticsEventSanitizer.errorProperties(
            for: ConvexError.serverError("[Request ID: abc123] Server Error")
        )

        XCTAssertEqual(errorProperties["error_kind"] as? String, "server_error")
        XCTAssertEqual(errorProperties["error_domain"] as? String, "ConvexError")
        XCTAssertEqual(errorProperties["error_type"] as? String, "ConvexError.serverError")
        XCTAssertNil(errorProperties["error"])
    }

    func testVocabularyBoostDecisionUsesMetricOnlyAllowlist() {
        let properties = AnalyticsEventSanitizer.sanitizedProperties([
            "analytics_source": "resonant_swift",
            "outcome": "vetoed",
            "term_source": "auto_learned",
            "original_was_real_word": true,
            "original_score": -3.0,
            "replacement_score": -1.0,
            "mode": "dictation",
            "term": "SENTINEL_PRIVATE_TERM",
            "matched_term": "SENTINEL_PRIVATE_MATCH",
            "original_text": "SENTINEL_PRIVATE_TRANSCRIPT",
            "unexpected_future_field": "SENTINEL_PRIVATE_FUTURE",
        ], eventName: "vocabulary_boost_decision")

        XCTAssertEqual(properties["term_source"] as? String, "auto_learned")
        XCTAssertEqual(properties["outcome"] as? String, "vetoed")
        XCTAssertNil(properties["term"])
        XCTAssertNil(properties["matched_term"])
        XCTAssertNil(properties["original_text"])
        XCTAssertNil(properties["unexpected_future_field"])
        XCTAssertFalse(String(describing: properties).contains("SENTINEL_PRIVATE"))
    }

    func testDictationQualityUsesClosedMetricOnlyAllowlist() {
        var input: [String: Any] = Dictionary(
            uniqueKeysWithValues: (0..<120).map { index in
                ("unexpected_\(index)", "SENTINEL_PRIVATE_UNKNOWN_\(index)")
            }
        )
        input["schema_version"] = 4
        input["readback_status"] = "accepted"
        input["context_personalization_policy"] = "context_personalization"
        input["context_personalization_assigned_variant"] = "personalized"
        input["context_personalization_opportunity"] = true
        input["context_personalization_packet_entity_offered_count"] = 2
        input["context_personalization_local_entity_considered_count"] = 2
        input["context_personalization_local_entity_matched_count"] = 1
        input["context_personalization_local_entity_applied_count"] = 1
        input["context_personalization_cloud_entity_submitted_count"] = 2
        input["context_personalization_applied"] = true
        input["install_id"] = "SENTINEL_PRIVATE_INSTALL_ID"
        input["dictation_id"] = "SENTINEL_PRIVATE_DICTATION_ID"
        input["profile_hash"] = "SENTINEL_PRIVATE_PROFILE_HASH"
        input["surface_hash"] = "SENTINEL_PRIVATE_SURFACE_HASH"
        input["target_fingerprint"] = "SENTINEL_PRIVATE_FINGERPRINT"
        input["raw_transcript"] = "SENTINEL_PRIVATE_TRANSCRIPT"
        input["learned_terms"] = ["SENTINEL_PRIVATE_TERM"]

        let properties = AnalyticsEventSanitizer.sanitizedProperties(
            input,
            eventName: "dictation_quality_v1"
        )

        XCTAssertEqual(properties["context_personalization_policy"] as? String, "context_personalization")
        XCTAssertEqual(properties["context_personalization_assigned_variant"] as? String, "personalized")
        XCTAssertEqual(properties["context_personalization_opportunity"] as? Bool, true)
        XCTAssertEqual(properties["context_personalization_packet_entity_offered_count"] as? Int, 2)
        XCTAssertEqual(properties["context_personalization_local_entity_applied_count"] as? Int, 1)
        XCTAssertEqual(properties["context_personalization_cloud_entity_submitted_count"] as? Int, 2)
        XCTAssertEqual(properties["context_personalization_applied"] as? Bool, true)
        for forbidden in [
            "install_id", "dictation_id", "profile_hash", "surface_hash",
            "target_fingerprint", "raw_transcript", "learned_terms", "unexpected_0",
        ] {
            XCTAssertNil(properties[forbidden], "unexpected key survived: \(forbidden)")
        }
        XCTAssertFalse(String(describing: properties).contains("SENTINEL_PRIVATE"))
    }

    func testVocabularyAttemptUsesClosedCountOnlyAllowlist() {
        let properties = AnalyticsEventSanitizer.sanitizedProperties([
            "schema_version": 1,
            "pipeline_name": "vocabulary_boost_attempt",
            "attempt_total_count": 1,
            "skip_unsupported_adapter_count": 1,
            "install_id": "SENTINEL_PRIVATE_INSTALL_ID",
            "term": "SENTINEL_PRIVATE_TERM",
            "transcript": "SENTINEL_PRIVATE_TRANSCRIPT",
            "download_error": "SENTINEL_PRIVATE_DOWNLOAD_ERROR",
            "model_path": "SENTINEL_PRIVATE_MODEL_PATH",
            "unexpected_future_field": "SENTINEL_PRIVATE_FUTURE",
        ], eventName: VocabularyBoostAttemptTelemetry.eventName)

        XCTAssertEqual(properties["attempt_total_count"] as? Int, 1)
        XCTAssertEqual(properties["skip_unsupported_adapter_count"] as? Int, 1)
        for forbidden in [
            "install_id", "term", "transcript", "download_error",
            "model_path", "unexpected_future_field",
        ] {
            XCTAssertNil(properties[forbidden], "unexpected key survived: \(forbidden)")
        }
        XCTAssertFalse(String(describing: properties).contains("SENTINEL_PRIVATE"))
    }

    func testClosedSchemasPreserveTheirCompleteAllowedPropertiesAndRejectSentinels() throws {
        let eventNames = [
            "dictation_quality_v1",
            OnboardingAnalytics.Event.started.rawValue,
            ModelPreparationTelemetry.Event.started.rawValue,
            ModelPreparationTelemetry.Event.succeeded.rawValue,
            ModelPreparationTelemetry.Event.failed.rawValue,
        ]

        for eventName in eventNames {
            let allowed = try XCTUnwrap(AnalyticsEventSanitizer.allowedPropertyKeys(for: eventName))
            var input = Dictionary(uniqueKeysWithValues: allowed.map { ($0, "safe_metric") })
            input["install_id"] = "SENTINEL_PRIVATE_INSTALL_ID"
            input["dictation_id"] = "SENTINEL_PRIVATE_DICTATION_ID"
            input["model"] = "SENTINEL_PRIVATE_MODEL_ID"
            input["model_id"] = "SENTINEL_PRIVATE_MODEL_ID"
            input["model_path"] = "SENTINEL_PRIVATE_MODEL_PATH"
            input["landed_bundle_id"] = "SENTINEL_PRIVATE_BUNDLE_ID"
            input["marketing_attribution_id"] = "SENTINEL_PRIVATE_ATTRIBUTION"
            input["raw_transcript"] = "SENTINEL_PRIVATE_TRANSCRIPT"
            input["error"] = "SENTINEL_PRIVATE_ERROR"
            input["unexpected_future_field"] = "SENTINEL_PRIVATE_FUTURE"

            let properties = AnalyticsEventSanitizer.sanitizedProperties(
                input,
                eventName: eventName
            )

            XCTAssertEqual(Set(properties.keys), allowed, "schema mismatch for \(eventName)")
            XCTAssertLessThanOrEqual(
                properties.count,
                AnalyticsEventSanitizer.propertyLimit(for: eventName)
            )
            XCTAssertFalse(
                String(describing: properties).contains("SENTINEL_PRIVATE"),
                "private sentinel survived for \(eventName)"
            )
        }
    }
}
