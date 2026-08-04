import XCTest
@testable import Resonant

@MainActor
final class DictationQualityExposureTests: XCTestCase {
    func testQualityPropertiesSeparateAssignmentOpportunityWithholdingAndConsumers() {
        let holdout = ContextPersonalizationExposure(
            policyVersion: 2,
            configuredHoldoutRate: 25,
            assignedVariant: .holdout,
            personalizationOpportunity: true,
            withheldByHoldout: true
        )
        let properties = DictationQualityPipeline.readbackProperties(
            trace: trace(exposure: holdout),
            status: .accepted,
            pastedText: "SENTINEL_PRIVATE_PASTED_TEXT",
            editedText: "SENTINEL_PRIVATE_EDITED_TEXT",
            correctionCount: 500,
            observationAgeMs: 900_000
        )

        XCTAssertEqual(properties["context_personalization_policy"] as? String, "context_personalization")
        XCTAssertEqual(properties["context_personalization_assigned_variant"] as? String, "holdout")
        XCTAssertEqual(properties["context_personalization_opportunity"] as? Bool, true)
        XCTAssertEqual(properties["context_personalization_withheld_by_holdout"] as? Bool, true)
        XCTAssertEqual(properties["context_personalization_applied"] as? Bool, false)
        XCTAssertEqual(properties["correction_count"] as? Int, 100)
        XCTAssertEqual(properties["observation_age_ms"] as? Int, 300_000)
        XCTAssertNil(properties["dictation_id"])
        XCTAssertNil(properties["model"])
        XCTAssertEqual(properties["model_family"] as? String, "other")
        XCTAssertFalse(String(describing: properties).contains("SENTINEL_PRIVATE"))
    }

    func testFortyOfferedWithoutConsumerUseDoesNotClaimApplication() {
        let exposure = ContextPersonalizationExposure(
            policyVersion: 2,
            configuredHoldoutRate: 0,
            assignedVariant: .personalized,
            personalizationOpportunity: true,
            packetEntityOfferedCount: 40,
            packetStyleOffered: true
        )
        let properties = DictationQualityPipeline.contextPersonalizationProperties(
            exposure: exposure
        )

        XCTAssertEqual(properties["context_personalization_packet_entity_offered_count"] as? Int, 40)
        XCTAssertEqual(properties["context_personalization_packet_style_offered"] as? Bool, true)
        XCTAssertEqual(properties["context_personalization_local_entity_applied_count"] as? Int, 0)
        XCTAssertEqual(properties["context_personalization_cloud_entity_submitted_count"] as? Int, 0)
        XCTAssertEqual(properties["context_personalization_cloud_style_submitted"] as? Bool, false)
        XCTAssertEqual(properties["context_personalization_applied"] as? Bool, false)
    }

    func testLocalApplicationAndCloudSubmissionRemainDistinct() {
        let exposure = ContextPersonalizationExposure(
            assignedVariant: .personalized,
            packetEntityOfferedCount: 3,
            packetStyleOffered: true,
            localLearnedEntityConsideredCount: 3,
            localLearnedEntityMatchedCount: 1,
            localLearnedEntityAppliedCount: 1,
            cloudLearnedEntitySubmittedCount: 2,
            cloudLearnedStyleSubmitted: true
        )
        let properties = DictationQualityPipeline.contextPersonalizationProperties(
            exposure: exposure
        )

        XCTAssertEqual(properties["context_personalization_local_entity_considered_count"] as? Int, 3)
        XCTAssertEqual(properties["context_personalization_local_entity_matched_count"] as? Int, 1)
        XCTAssertEqual(properties["context_personalization_local_entity_applied_count"] as? Int, 1)
        XCTAssertEqual(properties["context_personalization_cloud_entity_submitted_count"] as? Int, 2)
        XCTAssertEqual(properties["context_personalization_cloud_style_submitted"] as? Bool, true)
        XCTAssertEqual(properties["context_personalization_applied"] as? Bool, true)
    }

    private func trace(
        exposure: ContextPersonalizationExposure
    ) -> DictationQualityTrace {
        DictationQualityTrace(
            dictationID: "SENTINEL_PRIVATE_DICTATION_ID",
            mode: "dictation",
            model: "SENTINEL_PRIVATE_MODEL_ID",
            targetBundleId: "com.tinyspeck.slackmacgap",
            surfaceKind: SurfaceKind.chat.rawValue,
            pasteDeliveryMode: "clipboard",
            autoPaste: true,
            autoSend: false,
            copyToClipboard: false,
            cloudProcessingEnabled: true,
            lowLatencyMode: false,
            selectionTransformUsed: false,
            cleanup: .notApplicable,
            transform: .notApplicable,
            confidence: nil,
            contextPersonalization: exposure,
            boostCounts: .zero,
            latencies: .init(event: nil)
        )
    }
}
