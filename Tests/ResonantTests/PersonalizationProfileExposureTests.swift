import XCTest
@testable import Resonant

final class PersonalizationProfileExposureTests: XCTestCase {
    func testDefaultPolicyIsNamedVersionedAndHasZeroHoldout() {
        let profile = PersonalizationProfileBuilder.build(
            surface: surface,
            snapshot: .empty,
            styleSampleCount: 0,
            seed: "stable-assignment"
        )

        XCTAssertEqual(PersonalizationProfileBuilder.assignmentPolicyName, "context_personalization")
        XCTAssertEqual(PersonalizationProfileBuilder.defaultHoldoutRate, 0)
        XCTAssertEqual(profile.metadata.assignmentPolicyName, "context_personalization")
        XCTAssertEqual(profile.metadata.assignmentPolicyVersion, ContextPersonalizationPolicy.version)
        XCTAssertEqual(profile.metadata.holdoutRate, 0)
        XCTAssertEqual(profile.metadata.assignedVariant, .personalized)
    }

    func testInjectableNonzeroAssignmentIsDeterministic() {
        let first = PersonalizationProfileBuilder.build(
            surface: surface,
            snapshot: .empty,
            styleSampleCount: 0,
            seed: "deterministic-seed",
            holdoutRate: 37
        )
        let second = PersonalizationProfileBuilder.build(
            surface: surface,
            snapshot: .empty,
            styleSampleCount: 0,
            seed: "deterministic-seed",
            holdoutRate: 37
        )

        XCTAssertEqual(first.metadata.holdoutBucket, second.metadata.holdoutBucket)
        XCTAssertEqual(first.metadata.variant, second.metadata.variant)
        XCTAssertEqual(first.metadata.holdoutRate, 37)
        XCTAssertEqual(
            first.metadata.variant == .holdout,
            first.metadata.holdoutBucket < 37
        )
    }

    func testExposureNormalizesCountsPolicyAndImpossibleWithholding() throws {
        let exposure = ContextPersonalizationExposure(
            policyName: "SENTINEL_PRIVATE_POLICY",
            policyVersion: 50_000,
            configuredHoldoutRate: 400,
            assignedVariant: .holdout,
            personalizationOpportunity: true,
            withheldByHoldout: true,
            packetEntityOfferedCount: 500,
            localLearnedEntityConsideredCount: 500,
            localLearnedEntityMatchedCount: 500,
            localLearnedEntityAppliedCount: 500,
            cloudLearnedEntitySubmittedCount: 500
        )

        XCTAssertEqual(exposure.policyName, "context_personalization")
        XCTAssertEqual(exposure.policyVersion, ContextPersonalizationExposure.maximumPolicyVersion)
        XCTAssertEqual(exposure.configuredHoldoutRate, 100)
        XCTAssertEqual(exposure.packetEntityOfferedCount, 100)
        XCTAssertEqual(exposure.localLearnedEntityAppliedCount, 100)
        XCTAssertEqual(exposure.cloudLearnedEntitySubmittedCount, 100)
        XCTAssertTrue(exposure.personalizationApplied)
        XCTAssertFalse(exposure.withheldByHoldout)

        let outcome = exposure.outcomeExposure
        XCTAssertEqual(outcome.assignmentVariant, .holdout)
        XCTAssertTrue(outcome.personalizationApplied)
        XCTAssertFalse(outcome.withheldByHoldout)
        XCTAssertEqual(outcome.localLearnedEntityAppliedCount, 100)
        XCTAssertEqual(outcome.cloudLearnedEntitySubmittedCount, 100)
    }

    func testOfferedPayloadImpliesOpportunityButNotApplication() {
        let exposure = ContextPersonalizationExposure(
            assignedVariant: .personalized,
            personalizationOpportunity: false,
            packetEntityOfferedCount: 1
        )

        XCTAssertTrue(exposure.personalizationOpportunity)
        XCTAssertFalse(exposure.personalizationApplied)
        XCTAssertFalse(exposure.withheldByHoldout)
    }

    private var surface: SurfaceDescriptor {
        SurfaceDescriptor(
            kind: .chat,
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "general - Slack",
            browserURL: nil,
            siteHost: nil,
            siteName: nil,
            fieldKind: .compose,
            conversationLabel: nil,
            documentLabel: nil,
            projectLabel: nil
        )
    }
}
