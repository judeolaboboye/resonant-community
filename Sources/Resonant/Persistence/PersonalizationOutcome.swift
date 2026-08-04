import Foundation
import SwiftData

/// One local, text-free delivery outcome. Raw strings are restricted to the
/// bounded enums in `PersonalizationOutcomeContracts`; no transcript, target
/// identifier, application metadata, or field content is stored here.
@Model
final class PersonalizationOutcome {
    @Attribute(.unique) var deliveryAttemptID: UUID
    var createdAt: Date
    var finalizedAt: Date?
    var statusRaw: String
    var readbackMethodRaw: String
    var surfaceRaw: String
    var targetProfileRaw: String
    var readbackEligible: Bool
    var observable: Bool
    var assignmentVariantRaw: String = "unknown"
    var assignmentPolicyVersion: Int = 0
    var personalizationOpportunity: Bool = false
    var withheldByHoldout: Bool = false
    var personalizationApplied: Bool = false
    var packetEntityOfferedCount: Int = 0
    var packetStyleOffered: Bool = false
    var localLearnedEntityConsideredCount: Int = 0
    var localLearnedEntityMatchedCount: Int = 0
    var localLearnedEntityAppliedCount: Int = 0
    var localStyleApplied: Bool = false
    var cloudLearnedEntitySubmittedCount: Int = 0
    var cloudLearnedStyleSubmitted: Bool = false
    var editDistanceBucketRaw: String
    var correctionCountBucketRaw: String

    init(
        deliveryAttemptID: UUID,
        createdAt: Date,
        finalizedAt: Date?,
        status: PersonalizationOutcomeStatus,
        readbackMethod: PersonalizationOutcomeReadbackMethod,
        surface: PersonalizationOutcomeSurface,
        targetProfile: PersonalizationOutcomeTargetProfile,
        readbackEligible: Bool,
        observable: Bool,
        exposure: PersonalizationOutcomeExposure,
        editDistanceBucket: PersonalizationEditDistanceBucket = .unavailable,
        correctionCountBucket: PersonalizationCorrectionCountBucket = .unavailable
    ) {
        self.deliveryAttemptID = deliveryAttemptID
        self.createdAt = createdAt
        self.finalizedAt = finalizedAt
        statusRaw = status.rawValue
        readbackMethodRaw = readbackMethod.rawValue
        surfaceRaw = surface.rawValue
        targetProfileRaw = targetProfile.rawValue
        self.readbackEligible = readbackEligible
        self.observable = observable
        assignmentVariantRaw = exposure.assignmentVariant.rawValue
        assignmentPolicyVersion = exposure.assignmentPolicyVersion
        personalizationOpportunity = exposure.personalizationOpportunity
        withheldByHoldout = exposure.withheldByHoldout
        personalizationApplied = exposure.personalizationApplied
        packetEntityOfferedCount = exposure.packetEntityOfferedCount
        packetStyleOffered = exposure.packetStyleOffered
        localLearnedEntityConsideredCount = exposure.localLearnedEntityConsideredCount
        localLearnedEntityMatchedCount = exposure.localLearnedEntityMatchedCount
        localLearnedEntityAppliedCount = exposure.localLearnedEntityAppliedCount
        localStyleApplied = exposure.localStyleApplied
        cloudLearnedEntitySubmittedCount = exposure.cloudLearnedEntitySubmittedCount
        cloudLearnedStyleSubmitted = exposure.cloudLearnedStyleSubmitted
        editDistanceBucketRaw = editDistanceBucket.rawValue
        correctionCountBucketRaw = correctionCountBucket.rawValue
    }

    var status: PersonalizationOutcomeStatus {
        get { PersonalizationOutcomeStatus(rawValue: statusRaw) ?? .unknown }
        set { statusRaw = newValue.rawValue }
    }

    var readbackMethod: PersonalizationOutcomeReadbackMethod {
        get { PersonalizationOutcomeReadbackMethod(rawValue: readbackMethodRaw) ?? .unavailable }
        set { readbackMethodRaw = newValue.rawValue }
    }

    var surface: PersonalizationOutcomeSurface {
        PersonalizationOutcomeSurface(rawValue: surfaceRaw) ?? .unknown
    }

    var targetProfile: PersonalizationOutcomeTargetProfile {
        PersonalizationOutcomeTargetProfile(rawValue: targetProfileRaw) ?? .unknown
    }

    var assignmentVariant: PersonalizationOutcomeAssignmentVariant {
        PersonalizationOutcomeAssignmentVariant(rawValue: assignmentVariantRaw) ?? .unknown
    }

    var editDistanceBucket: PersonalizationEditDistanceBucket {
        get { PersonalizationEditDistanceBucket(rawValue: editDistanceBucketRaw) ?? .unavailable }
        set { editDistanceBucketRaw = newValue.rawValue }
    }

    var correctionCountBucket: PersonalizationCorrectionCountBucket {
        get { PersonalizationCorrectionCountBucket(rawValue: correctionCountBucketRaw) ?? .unavailable }
        set { correctionCountBucketRaw = newValue.rawValue }
    }
}
