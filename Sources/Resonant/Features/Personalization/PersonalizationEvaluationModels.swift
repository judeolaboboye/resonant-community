import Foundation

/// Input from the bounded correction log. These rows can support local edit
/// diagnostics, but they are not the denominator for delivery outcomes.
struct PersonalizationEvaluationInput: Sendable, Equatable {
    var id: UUID
    var timestamp: Date
    var appName: String?
    var surfaceKind: String?
    var pastedText: String
    var editedText: String
    var corrections: [StoredCorrectionPair]
    var hadCorrection: Bool
}

struct PersonalizationEvaluationSnapshot: Sendable, Equatable {
    var capturedAt: Date
    var outcomes: PersonalizationOutcomeSummaryState
    var correctionLogEventCount: Int
    var editedCorrectionLogEventCount: Int
    var averageNormalizedEditDistance: Double
    var averageCorrectionPairsPerLogEvent: Double
    var topCorrections: [PersonalizationCorrectionTermSummary]

    static let empty = PersonalizationEvaluationSnapshot(
        capturedAt: Date(),
        outcomes: .unavailable,
        correctionLogEventCount: 0,
        editedCorrectionLogEventCount: 0,
        averageNormalizedEditDistance: 0,
        averageCorrectionPairsPerLogEvent: 0,
        topCorrections: []
    )
}

struct PersonalizationCorrectionTermSummary: Identifiable, Sendable, Equatable {
    var id: String
    var spoken: String
    var written: String
    var count: Int
}
