import Foundation
import SwiftData

extension DataStore {
    /// A dictionary action is strong counter-evidence for recent boost applies,
    /// but not for arbitrarily old decisions that may have been correct at the
    /// time. Seven days keeps the signal tied to the behavior the user is
    /// plausibly reacting to.
    nonisolated static let vocabularyBoostFeedbackLookback: TimeInterval = 7 * 24 * 60 * 60

    /// Flags recent, previously-unflagged applied decisions matching a
    /// dictionary written form. Returns zero on an unavailable store, corrupt
    /// audit JSON, or save failure so dictionary actions always fail open.
    func flagRecentVocabularyBoostFalseApplies(
        writtenForm: String,
        reason: VocabularyBoostAuditSummary.FalseApplyReason,
        now: Date = Date(),
        lookback: TimeInterval = vocabularyBoostFeedbackLookback
    ) async -> Int {
        let writtenKey = VocabularyBoostAuditSummary.normalizedTermKey(writtenForm)
        guard !writtenKey.isEmpty else { return 0 }
        let cutoff = now.addingTimeInterval(-max(0, lookback))

        return await performBackgroundWrite { context in
            let descriptor = FetchDescriptor<DictationEntry>(
                predicate: #Predicate<DictationEntry> { entry in
                    entry.date >= cutoff
                }
            )
            let entries = try context.fetch(descriptor)
            var flaggedCount = 0
            for entry in entries {
                guard var summary = entry.vocabularyBoostAuditSummary else { continue }
                let count = summary.flagFalseApplies(
                    matchingWrittenForm: writtenKey,
                    reason: reason,
                    recordedAt: now
                )
                guard count > 0, let encoded = summary.encodedData() else { continue }
                entry.vocabularyBoostAuditJSON = encoded
                flaggedCount += count
            }
            return flaggedCount
        } ?? 0
    }
}
