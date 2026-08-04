import Foundation

enum PersonalizationOutcomeStatus: String, CaseIterable, Codable, Sendable, Hashable {
    case pending
    case accepted
    case corrected

    case excludedDeliveryFailed = "excluded_delivery_failed"
    case excludedPartialDelivery = "excluded_partial_delivery"
    case excludedCopyOnly = "excluded_copy_only"
    case excludedAutoSent = "excluded_auto_sent"
    case excludedSelectionTransform = "excluded_selection_transform"

    case processMismatch = "process_mismatch"
    case targetMismatch = "target_mismatch"
    case sensitiveTarget = "sensitive_target"
    case insufficientIdentity = "insufficient_identity"
    case regionUnattributable = "region_unattributable"
    case baselineUnavailable = "baseline_unavailable"
    case targetNormalizedOrUnattributable = "target_normalized_or_unattributable"
    case readbackUnavailable = "readback_unavailable"
    case noFieldContent = "no_field_content"
    case observationCancelled = "observation_cancelled"
    case observationReplaced = "observation_replaced"
    case stale

    /// Fail-closed representation for an unreadable future/corrupt raw value.
    /// The store never writes this status through its public lifecycle API.
    case unknown

    var isObservable: Bool {
        self == .accepted || self == .corrected
    }

    var isExcluded: Bool {
        switch self {
        case .excludedDeliveryFailed, .excludedPartialDelivery, .excludedCopyOnly,
                .excludedAutoSent, .excludedSelectionTransform:
            return true
        case .pending, .accepted, .corrected, .processMismatch, .targetMismatch,
                .sensitiveTarget, .insufficientIdentity, .regionUnattributable,
                .baselineUnavailable, .targetNormalizedOrUnattributable,
                .readbackUnavailable, .noFieldContent, .observationCancelled,
                .observationReplaced, .stale, .unknown:
            return false
        }
    }

    var isReadbackTerminal: Bool {
        switch self {
        case .accepted, .corrected, .processMismatch, .targetMismatch,
                .sensitiveTarget, .insufficientIdentity, .regionUnattributable,
                .baselineUnavailable, .targetNormalizedOrUnattributable,
                .readbackUnavailable, .noFieldContent, .observationCancelled,
                .observationReplaced, .stale:
            return true
        case .pending, .excludedDeliveryFailed, .excludedPartialDelivery,
                .excludedCopyOnly, .excludedAutoSent,
                .excludedSelectionTransform, .unknown:
            return false
        }
    }
}

enum PersonalizationOutcomeReadbackMethod: String, CaseIterable, Codable, Sendable, Hashable {
    case notApplicable = "not_applicable"
    case retainedReceipt = "retained_receipt"
    case attributedSnapshot = "attributed_snapshot"
    case unavailable
}

/// Stable local grouping only. It deliberately contains no application, URL,
/// workspace, field, or profile identifier.
enum PersonalizationOutcomeSurface: String, CaseIterable, Codable, Sendable, Hashable {
    case email
    case chat
    case social
    case code
    case docs
    case task
    case browser
    case search
    case terminal
    case finder
    case form
    case other
    case unknown

    init(surfaceKind: SurfaceKind?) {
        guard let surfaceKind,
              let resolved = Self(rawValue: surfaceKind.rawValue) else {
            self = .unknown
            return
        }
        self = resolved
    }

    init(surfaceKindRaw: String?) {
        guard let surfaceKindRaw,
              let resolved = Self(rawValue: surfaceKindRaw.lowercased()) else {
            self = .unknown
            return
        }
        self = resolved
    }
}

enum PersonalizationOutcomeTargetProfile: String, CaseIterable, Codable, Sendable, Hashable {
    case aiCodingApp = "ai_coding_app"
    case terminal
    case codeEditor = "code_editor"
    case chat
    case email
    case browser
    case nativeApp = "native_app"
    case unknown

    static func classify(bundleIdentifier: String?) -> Self {
        Self(rawValue: PerformanceExperiments.targetProfile(bundleId: bundleIdentifier)) ?? .unknown
    }
}

enum PersonalizationOutcomeAssignmentVariant: String, CaseIterable, Codable, Sendable, Hashable {
    case personalized
    case holdout
    case unknown

    init(_ variant: PersonalizationProfileVariant?) {
        switch variant {
        case .personalized:
            self = .personalized
        case .holdout:
            self = .holdout
        case nil:
            self = .unknown
        }
    }
}

struct PersonalizationOutcomeExposure: Sendable, Equatable {
    static let maximumCount = 100
    static let maximumPolicyVersion = 10_000

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

    static let none = PersonalizationOutcomeExposure()

    init(
        assignmentVariant: PersonalizationOutcomeAssignmentVariant = .unknown,
        assignmentPolicyVersion: Int = 0,
        personalizationOpportunity: Bool = false,
        withheldByHoldout: Bool = false,
        packetEntityOfferedCount: Int = 0,
        packetStyleOffered: Bool = false,
        localLearnedEntityConsideredCount: Int = 0,
        localLearnedEntityMatchedCount: Int = 0,
        localLearnedEntityAppliedCount: Int = 0,
        localStyleApplied: Bool = false,
        cloudLearnedEntitySubmittedCount: Int = 0,
        cloudLearnedStyleSubmitted: Bool = false
    ) {
        self.assignmentVariant = assignmentVariant
        self.assignmentPolicyVersion = min(
            max(assignmentPolicyVersion, 0),
            Self.maximumPolicyVersion
        )
        let offered = Self.bounded(packetEntityOfferedCount)
        let considered = Self.bounded(localLearnedEntityConsideredCount)
        let matched = min(Self.bounded(localLearnedEntityMatchedCount), considered)
        let applied = min(Self.bounded(localLearnedEntityAppliedCount), matched)
        let submitted = Self.bounded(cloudLearnedEntitySubmittedCount)
        let anyConsumerExposure = offered > 0
            || packetStyleOffered
            || considered > 0
            || submitted > 0
            || cloudLearnedStyleSubmitted
        let anyLocalApplication = applied > 0 || localStyleApplied
        self.personalizationOpportunity = personalizationOpportunity || anyConsumerExposure
        self.withheldByHoldout = withheldByHoldout
            && assignmentVariant == .holdout
            && !anyConsumerExposure
            && !anyLocalApplication
        self.personalizationApplied = anyLocalApplication
        self.packetEntityOfferedCount = offered
        self.packetStyleOffered = packetStyleOffered
        self.localLearnedEntityConsideredCount = considered
        self.localLearnedEntityMatchedCount = matched
        self.localLearnedEntityAppliedCount = applied
        self.localStyleApplied = localStyleApplied
        self.cloudLearnedEntitySubmittedCount = submitted
        self.cloudLearnedStyleSubmitted = cloudLearnedStyleSubmitted
    }

    private static func bounded(_ count: Int) -> Int {
        min(max(count, 0), maximumCount)
    }
}

enum PersonalizationEditDistanceBucket: String, CaseIterable, Codable, Sendable, Hashable {
    case unavailable
    case none
    case upToFivePercent = "up_to_5_percent"
    case upToTwentyPercent = "up_to_20_percent"
    case upToHalf = "up_to_50_percent"
    case overHalf = "over_50_percent"

    static func classify(_ normalizedDistance: Double?) -> Self {
        guard let normalizedDistance, normalizedDistance.isFinite else { return .unavailable }
        switch max(normalizedDistance, 0) {
        case 0:
            return .none
        case ...0.05:
            return .upToFivePercent
        case ...0.20:
            return .upToTwentyPercent
        case ...0.50:
            return .upToHalf
        default:
            return .overHalf
        }
    }
}

enum PersonalizationCorrectionCountBucket: String, CaseIterable, Codable, Sendable, Hashable {
    case unavailable
    case zero
    case one
    case twoToThree = "two_to_three"
    case fourToSeven = "four_to_seven"
    case eightOrMore = "eight_or_more"

    static func classify(_ count: Int?) -> Self {
        guard let count, count >= 0 else { return .unavailable }
        switch count {
        case 0:
            return .zero
        case 1:
            return .one
        case 2...3:
            return .twoToThree
        case 4...7:
            return .fourToSeven
        default:
            return .eightOrMore
        }
    }
}

/// The complete set of route facts AppState may use to register a delivery.
/// Classification is intentionally centralized so callers cannot choose an
/// exclusion status ad hoc.
struct PersonalizationDeliveryRouteFacts: Sendable, Equatable {
    let delivered: Bool
    let partiallyDelivered: Bool
    let autoPasted: Bool
    let autoSent: Bool
    let copiedToClipboard: Bool
    let selectionTransformUsed: Bool

    init(
        delivered: Bool,
        partiallyDelivered: Bool,
        autoPasted: Bool,
        autoSent: Bool,
        copiedToClipboard: Bool,
        selectionTransformUsed: Bool
    ) {
        self.delivered = delivered
        self.partiallyDelivered = partiallyDelivered
        self.autoPasted = autoPasted
        self.autoSent = autoSent
        self.copiedToClipboard = copiedToClipboard
        self.selectionTransformUsed = selectionTransformUsed
    }
}

enum PersonalizationOutcomeRouteClassification: Sendable, Equatable {
    case pendingEligible
    case terminalExcluded(PersonalizationOutcomeStatus)
}

enum PersonalizationOutcomeClassifier {
    static func classify(
        _ facts: PersonalizationDeliveryRouteFacts
    ) -> PersonalizationOutcomeRouteClassification {
        if facts.partiallyDelivered {
            return .terminalExcluded(.excludedPartialDelivery)
        }
        guard facts.delivered else {
            return .terminalExcluded(.excludedDeliveryFailed)
        }
        guard facts.autoPasted else {
            return .terminalExcluded(.excludedCopyOnly)
        }
        if facts.selectionTransformUsed {
            return .terminalExcluded(.excludedSelectionTransform)
        }
        if facts.autoSent {
            return .terminalExcluded(.excludedAutoSent)
        }
        return .pendingEligible
    }
}

struct PersonalizationOutcomeRegistration: Sendable, Equatable {
    let deliveryAttemptID: UUID
    let routeFacts: PersonalizationDeliveryRouteFacts
    let readbackMethod: PersonalizationOutcomeReadbackMethod
    let surface: PersonalizationOutcomeSurface
    let targetProfile: PersonalizationOutcomeTargetProfile
    let exposure: PersonalizationOutcomeExposure

    init(
        deliveryAttemptID: UUID,
        routeFacts: PersonalizationDeliveryRouteFacts,
        readbackMethod: PersonalizationOutcomeReadbackMethod,
        surface: PersonalizationOutcomeSurface = .unknown,
        targetProfile: PersonalizationOutcomeTargetProfile = .unknown,
        exposure: PersonalizationOutcomeExposure = .none
    ) {
        self.deliveryAttemptID = deliveryAttemptID
        self.routeFacts = routeFacts
        self.readbackMethod = readbackMethod
        self.surface = surface
        self.targetProfile = targetProfile
        self.exposure = exposure
    }
}

struct PersonalizationOutcomeFinalization: Sendable, Equatable {
    let status: PersonalizationOutcomeStatus
    let readbackMethod: PersonalizationOutcomeReadbackMethod?
    let editDistanceBucket: PersonalizationEditDistanceBucket?
    let normalizedEditDistance: Double?
    let correctionCount: Int?

    init(
        status: PersonalizationOutcomeStatus,
        readbackMethod: PersonalizationOutcomeReadbackMethod? = nil,
        editDistanceBucket: PersonalizationEditDistanceBucket? = nil,
        normalizedEditDistance: Double? = nil,
        correctionCount: Int? = nil
    ) {
        self.status = status
        self.readbackMethod = readbackMethod
        self.editDistanceBucket = editDistanceBucket
        self.normalizedEditDistance = normalizedEditDistance
        self.correctionCount = correctionCount
    }

    static func accepted(
        readbackMethod: PersonalizationOutcomeReadbackMethod? = nil
    ) -> Self {
        Self(
            status: .accepted,
            readbackMethod: readbackMethod,
            normalizedEditDistance: 0,
            correctionCount: 0
        )
    }

    static func corrected(
        readbackMethod: PersonalizationOutcomeReadbackMethod? = nil,
        normalizedEditDistance: Double?,
        correctionCount: Int?
    ) -> Self {
        Self(
            status: .corrected,
            readbackMethod: readbackMethod,
            normalizedEditDistance: normalizedEditDistance,
            correctionCount: correctionCount
        )
    }

    static func corrected(
        readbackMethod: PersonalizationOutcomeReadbackMethod? = nil,
        editDistanceBucket: PersonalizationEditDistanceBucket,
        correctionCount: Int?
    ) -> Self {
        Self(
            status: .corrected,
            readbackMethod: readbackMethod,
            editDistanceBucket: editDistanceBucket,
            correctionCount: correctionCount
        )
    }

    static func unobservable(
        _ status: PersonalizationOutcomeStatus,
        readbackMethod: PersonalizationOutcomeReadbackMethod? = nil
    ) -> Self {
        Self(status: status, readbackMethod: readbackMethod)
    }
}

enum PersonalizationOutcomeRegistrationResult: Sendable, Equatable {
    case insertedPending
    case insertedTerminal(PersonalizationOutcomeStatus)
    case alreadyRegistered
    case persistenceUnavailable
    case suspended
}

enum PersonalizationOutcomeFinalizationResult: Sendable, Equatable {
    case finalized
    case alreadyFinalized
    case notFound
    case invalidStatus
    case persistenceUnavailable
    case suspended
}

struct PersonalizationOutcomeSetupResult: Sendable, Equatable {
    let succeeded: Bool
    let sweptExpiredCount: Int
    let scheduledPendingCount: Int

    static let unavailable = Self(
        succeeded: false,
        sweptExpiredCount: 0,
        scheduledPendingCount: 0
    )
}

struct PersonalizationOutcomeClock: Sendable {
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void

    static let live = PersonalizationOutcomeClock(
        now: { Date() },
        sleep: { interval in
            let bounded = max(interval, 0)
            let maximumSeconds = Double(UInt64.max) / 1_000_000_000
            let nanoseconds = UInt64(min(bounded, maximumSeconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    )
}
