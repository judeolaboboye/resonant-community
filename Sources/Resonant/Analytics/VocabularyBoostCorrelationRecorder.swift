import Foundation

/// Shared count-only feedback boundary for both immediate pasted-region edits
/// and retroactive dictionary invalidations. Raw boost terms never cross it.
@MainActor
enum VocabularyBoostCorrelationRecorder {
    static func record(_ signals: VocabularyBoostAudit.CorrectionSignals) {
        guard !signals.isEmpty else { return }
        AnalyticsManager.shared.capture("vocabulary_boost_correction", properties: [
            "applied_terms_removed": signals.removedAppliedTermCount,
            "vetoed_terms_inserted": signals.insertedVetoedTermCount,
        ])
    }
}
