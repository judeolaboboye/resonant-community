import Foundation

struct PersonalizationOutcomeRate: Sendable, Equatable {
    let numerator: Int
    let denominator: Int

    var value: Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }
}

struct PersonalizationOutcomePopulationSummary: Sendable, Equatable {
    let attemptCount: Int
    let terminalCount: Int
    let pendingCount: Int
    let excludedCount: Int
    let unobservableCount: Int
    let acceptedCount: Int
    let correctedCount: Int
    let statusCounts: [PersonalizationOutcomeStatus: Int]
    let exclusionCounts: [PersonalizationOutcomeStatus: Int]
    let coverage: PersonalizationOutcomeRate
    let observedNoEditRate: PersonalizationOutcomeRate
}

struct PersonalizationOutcomeSurfaceSummary: Identifiable, Sendable, Equatable {
    let surface: PersonalizationOutcomeSurface
    let population: PersonalizationOutcomePopulationSummary

    var id: PersonalizationOutcomeSurface { surface }
}

struct PersonalizationOutcomeSummary: Sendable, Equatable {
    let capturedAt: Date
    let global: PersonalizationOutcomePopulationSummary
    let surfaces: [PersonalizationOutcomeSurfaceSummary]

    static func make(
        records: [PersonalizationOutcomeRecord],
        capturedAt: Date
    ) -> Self {
        let grouped = Dictionary(grouping: records, by: \.surface)
        let surfaces = grouped
            .map { surface, records in
                PersonalizationOutcomeSurfaceSummary(
                    surface: surface,
                    population: population(for: records)
                )
            }
            .sorted { $0.surface.rawValue < $1.surface.rawValue }

        return Self(
            capturedAt: capturedAt,
            global: population(for: records),
            surfaces: surfaces
        )
    }

    private static func population(
        for records: [PersonalizationOutcomeRecord]
    ) -> PersonalizationOutcomePopulationSummary {
        var statusCounts: [PersonalizationOutcomeStatus: Int] = [:]
        for record in records {
            statusCounts[record.status, default: 0] += 1
        }

        let pendingCount = statusCounts[.pending, default: 0]
        let excludedRecords = records.filter { !$0.readbackEligible }
        let eligibleRecords = records.filter(\.readbackEligible)
        let observableCount = eligibleRecords.filter(\.observable).count
        let acceptedCount = statusCounts[.accepted, default: 0]
        let correctedCount = statusCounts[.corrected, default: 0]
        let noEditDenominator = acceptedCount + correctedCount
        let exclusionCounts = statusCounts.filter { status, _ in status.isExcluded }

        return PersonalizationOutcomePopulationSummary(
            attemptCount: records.count,
            terminalCount: records.count - pendingCount,
            pendingCount: pendingCount,
            excludedCount: excludedRecords.count,
            unobservableCount: eligibleRecords.filter {
                $0.status != .pending && !$0.observable
            }.count,
            acceptedCount: acceptedCount,
            correctedCount: correctedCount,
            statusCounts: statusCounts,
            exclusionCounts: exclusionCounts,
            coverage: PersonalizationOutcomeRate(
                numerator: observableCount,
                denominator: eligibleRecords.count
            ),
            observedNoEditRate: PersonalizationOutcomeRate(
                numerator: acceptedCount,
                denominator: noEditDenominator
            )
        )
    }
}

struct PersonalizationOutcomeRecord: Sendable, Equatable {
    let deliveryAttemptID: UUID
    let createdAt: Date
    let finalizedAt: Date?
    let status: PersonalizationOutcomeStatus
    let readbackMethod: PersonalizationOutcomeReadbackMethod
    let surface: PersonalizationOutcomeSurface
    let targetProfile: PersonalizationOutcomeTargetProfile
    let readbackEligible: Bool
    let observable: Bool
    let assignmentVariant: PersonalizationOutcomeAssignmentVariant
    let assignmentPolicyVersion: Int
    let personalizationOpportunity: Bool
    let withheldByHoldout: Bool
    let personalizationApplied: Bool
    let packetEntityOfferedCount: Int
    let packetStyleOffered: Bool
    let localLearnedEntityConsideredCount: Int
    let localLearnedEntityMatchedCount: Int
    let localLearnedEntityAppliedCount: Int
    let localStyleApplied: Bool
    let cloudLearnedEntitySubmittedCount: Int
    let cloudLearnedStyleSubmitted: Bool
    let editDistanceBucket: PersonalizationEditDistanceBucket
    let correctionCountBucket: PersonalizationCorrectionCountBucket

    init(model: PersonalizationOutcome) {
        deliveryAttemptID = model.deliveryAttemptID
        createdAt = model.createdAt
        finalizedAt = model.finalizedAt
        status = model.status
        readbackMethod = model.readbackMethod
        surface = model.surface
        targetProfile = model.targetProfile
        readbackEligible = model.readbackEligible
        observable = model.observable
        assignmentVariant = model.assignmentVariant
        assignmentPolicyVersion = model.assignmentPolicyVersion
        personalizationOpportunity = model.personalizationOpportunity
        withheldByHoldout = model.withheldByHoldout
        personalizationApplied = model.personalizationApplied
        packetEntityOfferedCount = model.packetEntityOfferedCount
        packetStyleOffered = model.packetStyleOffered
        localLearnedEntityConsideredCount = model.localLearnedEntityConsideredCount
        localLearnedEntityMatchedCount = model.localLearnedEntityMatchedCount
        localLearnedEntityAppliedCount = model.localLearnedEntityAppliedCount
        localStyleApplied = model.localStyleApplied
        cloudLearnedEntitySubmittedCount = model.cloudLearnedEntitySubmittedCount
        cloudLearnedStyleSubmitted = model.cloudLearnedStyleSubmitted
        editDistanceBucket = model.editDistanceBucket
        correctionCountBucket = model.correctionCountBucket
    }
}
