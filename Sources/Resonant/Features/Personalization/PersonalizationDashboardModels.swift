import Foundation

enum PersonalizationOutcomeSummaryState: Sendable, Equatable {
    case unavailable
    case available(PersonalizationOutcomeSummary)

    var summary: PersonalizationOutcomeSummary? {
        guard case let .available(summary) = self else { return nil }
        return summary
    }
}

struct PersonalizationEntityConsumerCounts: Sendable, Equatable {
    var learningCandidates: Int
    /// Prompt-only eligibility. Recognition-eligible rows also qualify for
    /// prompt context but are counted separately so each row appears once.
    var promptEligible: Int
    var recognitionEligible: Int
    /// Global recognizer capability for the current runtime. This does not
    /// claim that any specific eligible row survived source priority/capping.
    var recognizerAvailability: PersonalizationRecognizerAvailability
    var suppressed: Int

    var eligible: Int { promptEligible + recognitionEligible }

    static let zero = PersonalizationEntityConsumerCounts(
        learningCandidates: 0,
        promptEligible: 0,
        recognitionEligible: 0,
        recognizerAvailability: .notEligible,
        suppressed: 0
    )
}

struct PersonalizationFormatConsumerCounts: Sendable, Equatable {
    var learningCandidates: Int
    var formatterEligible: Int
    var suppressed: Int

    static let zero = PersonalizationFormatConsumerCounts(
        learningCandidates: 0,
        formatterEligible: 0,
        suppressed: 0
    )
}

struct PersonalizationStyleConsumerCounts: Sendable, Equatable {
    /// Writing-habit rows with evidence that has not activated either consumer.
    var learningCandidates: Int
    /// Unique rows eligible for at least one consumer.
    var eligibleWritingHabits: Int
    /// Unique rows currently available to at least one consumer.
    var availableWritingHabits: Int
    /// Rows with a non-inherit local policy family.
    var localPolicyEligible: Int
    /// Rows with at least one local policy family that survives global gates.
    var localPolicyAvailable: Int
    /// Number of local policy families blocked by a hard global gate.
    var localPolicyVetoedFamilies: Int
    /// Number of local policy families whose live gate is unavailable.
    var localPolicyUnknownFamilies: Int
    /// Rows with a non-empty structured cloud style hint.
    var cloudStyleEligible: Int
    /// Cloud-eligible rows for which cleanup is currently ready.
    var cloudStyleAvailable: Int
    /// Cloud-eligible rows for which cleanup is not currently ready.
    var cloudStyleUnavailable: Int

    static let zero = PersonalizationStyleConsumerCounts(
        learningCandidates: 0,
        eligibleWritingHabits: 0,
        availableWritingHabits: 0,
        localPolicyEligible: 0,
        localPolicyAvailable: 0,
        localPolicyVetoedFamilies: 0,
        localPolicyUnknownFamilies: 0,
        cloudStyleEligible: 0,
        cloudStyleAvailable: 0,
        cloudStyleUnavailable: 0
    )
}

struct PersonalizationDashboardSnapshot: Sendable, Equatable {
    var capturedAt: Date
    var runtimeContext: PersonalizationConsumerRuntimeContext
    var entityConsumers: PersonalizationEntityConsumerCounts
    var formatConsumers: PersonalizationFormatConsumerCounts
    var styleConsumers: PersonalizationStyleConsumerCounts
    var correctionLogEventCount: Int
    var outcomes: PersonalizationOutcomeSummaryState
    var topEntities: [PersonalizationEntitySummary]
    var topStyles: [PersonalizationStyleSummary]
    var recentEvents: [PersonalizationCorrectionEventSummary]
    var auditWarnings: [String]

    static let empty = PersonalizationDashboardSnapshot(
        capturedAt: Date(),
        runtimeContext: .unavailable,
        entityConsumers: .zero,
        formatConsumers: .zero,
        styleConsumers: .zero,
        correctionLogEventCount: 0,
        outcomes: .unavailable,
        topEntities: [],
        topStyles: [],
        recentEvents: [],
        auditWarnings: []
    )
}

struct PersonalizationControlsSnapshot: Sendable, Equatable {
    var capturedAt: Date
    var runtimeContext: PersonalizationConsumerRuntimeContext
    var entityConsumers: PersonalizationEntityConsumerCounts
    var formatConsumers: PersonalizationFormatConsumerCounts
    var styleConsumers: PersonalizationStyleConsumerCounts
    var entities: [PersonalizationEntitySummary]
    var styles: [PersonalizationStyleSummary]
    var formatPreferences: [PersonalizationFormatPreferenceSummary]
    var evaluation: PersonalizationEvaluationSnapshot

    static let empty = PersonalizationControlsSnapshot(
        capturedAt: Date(),
        runtimeContext: .unavailable,
        entityConsumers: .zero,
        formatConsumers: .zero,
        styleConsumers: .zero,
        entities: [],
        styles: [],
        formatPreferences: [],
        evaluation: .empty
    )
}

struct PersonalizationFormatPreferenceSummary: Identifiable, Sendable, Equatable {
    var id: UUID
    var category: String
    var scope: String
    var preferredValue: String
    var confidence: Double
    var positiveCount: Int
    var negativeCount: Int
    var isSuppressed: Bool
    var eligibility: PersonalizationFormatEligibilityState
    var lastSeenAt: Date
}

struct PersonalizationEntitySummary: Identifiable, Sendable, Equatable {
    var id: UUID
    var value: String
    var type: String
    var scope: String
    var confidence: Double
    var positiveCount: Int
    var negativeCount: Int
    var isUserPinned: Bool
    var isSuppressed: Bool
    var eligibility: PersonalizationEntityEligibilityState
    /// Whole-recognizer capability shown beside this row's pure eligibility.
    /// It is not term-loaded or term-applied provenance.
    var recognizerAvailability: PersonalizationRecognizerAvailability
    var source: String
    var lastSeenAt: Date
}

struct PersonalizationStyleSummary: Identifiable, Sendable, Equatable {
    var id: UUID
    var scope: String
    var evidenceCount: Int
    var consumerState: PersonalizationStyleConsumerState
    var summary: String
    var lastSeenAt: Date
}

struct PersonalizationCorrectionEventSummary: Identifiable, Sendable, Equatable {
    var id: UUID
    var timestamp: Date
    var appName: String?
    var surfaceKind: String?
    var hadCorrection: Bool
    var correctionCount: Int
    var rawTranscriptPreview: String?
    var pastedTextPreview: String
    var editedTextPreview: String
}
