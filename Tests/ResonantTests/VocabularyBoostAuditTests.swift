import XCTest
@testable import Resonant

@MainActor
final class VocabularyBoostAuditTests: XCTestCase {

    private func decision(
        _ outcome: VocabularyBoostAudit.Outcome,
        _ term: String,
        originalText: String = "design",
        guarded: Bool? = nil,
        source: VocabularyBoostTermSource? = nil,
        originalWasRealWord: Bool? = nil,
        originalScore: Float = -1,
        replacementScore: Float? = -0.5,
        similarity: Float = 0.6
    ) -> VocabularyBoostAudit.Decision {
        VocabularyBoostAudit.Decision(
            outcome: outcome,
            term: term,
            originalText: originalText,
            guarded: guarded ?? (outcome != .applied),
            source: source,
            originalWasRealWord: originalWasRealWord ?? (outcome != .applied),
            originalScore: originalScore,
            replacementScore: replacementScore,
            similarity: similarity
        )
    }

    // MARK: - Term projections

    func testAppliedAndVetoedTermProjections() {
        let audit = VocabularyBoostAudit(decisions: [
            decision(.applied, "Kubernetes"),
            decision(.vetoed, "Devin"),
            decision(.droppedWithVeto, "Convex"),
        ])
        XCTAssertEqual(audit.appliedTerms, ["Kubernetes"])
        XCTAssertEqual(audit.vetoedTerms, ["Devin"])
    }

    // MARK: - Correction signals (ground truth)

    func testRemovedAppliedTermCountsAsFalseApply() {
        let audit = VocabularyBoostAudit(decisions: [decision(.applied, "Devin")])
        let signals = audit.correctionSignals(
            pastedText: "meet Devin today",
            editedText: "meet design today"
        )
        XCTAssertEqual(signals.removedAppliedTermCount, 1)
        XCTAssertEqual(signals.insertedVetoedTermCount, 0)
    }

    func testInsertedVetoedTermCountsAsFalseVeto() {
        let audit = VocabularyBoostAudit(decisions: [decision(.vetoed, "Devin")])
        let signals = audit.correctionSignals(
            pastedText: "meet design today",
            editedText: "meet Devin today"
        )
        XCTAssertEqual(signals.insertedVetoedTermCount, 1)
        XCTAssertEqual(signals.removedAppliedTermCount, 0)
    }

    func testAppliedTermTheUserKeepsIsNotAFalseApply() {
        let audit = VocabularyBoostAudit(decisions: [decision(.applied, "Devin")])
        let signals = audit.correctionSignals(
            pastedText: "meet Devin today",
            editedText: "meet Devin tomorrow"
        )
        XCTAssertTrue(signals.isEmpty)
    }

    func testMultiWordTermMatchesAcrossWordsNotSubstrings() {
        let audit = VocabularyBoostAudit(decisions: [decision(.applied, "Devin Desktop")])
        // "Devinshire" must not satisfy the "Devin" token, and the two-word
        // term must appear as adjacent whole words.
        let noMatch = audit.correctionSignals(
            pastedText: "the Devinshire report", editedText: "the report"
        )
        XCTAssertTrue(noMatch.isEmpty)
        let match = audit.correctionSignals(
            pastedText: "open Devin Desktop now", editedText: "open the app now"
        )
        XCTAssertEqual(match.removedAppliedTermCount, 1)
    }

    // MARK: - Local persistence

    func testPersistedSummaryRoundTripsEveryDecisionField() throws {
        let audit = VocabularyBoostAudit(decisions: [decision(
            .applied,
            "Codex",
            originalText: "model",
            guarded: false,
            source: .autoLearned,
            originalWasRealWord: true,
            originalScore: -3.25,
            replacementScore: -1.75,
            similarity: 0.6
        )])
        let summary = VocabularyBoostAuditSummary(audit: audit)
        let data = try XCTUnwrap(summary.encodedData())
        let decoded = try XCTUnwrap(VocabularyBoostAuditSummary.decode(from: data))

        XCTAssertEqual(decoded, summary)
        let persisted = try XCTUnwrap(decoded.decisions.first)
        XCTAssertEqual(persisted.outcome, .applied)
        XCTAssertEqual(persisted.term, "Codex")
        XCTAssertEqual(persisted.originalText, "model")
        XCTAssertTrue(persisted.guarded)
        XCTAssertEqual(persisted.source, .autoLearned)
        XCTAssertTrue(persisted.originalWasRealWord)
        XCTAssertEqual(persisted.originalScore, -3.25)
        XCTAssertEqual(persisted.replacementScore, -1.75)
        XCTAssertEqual(persisted.similarity, 0.6, accuracy: 0.001)
    }

    func testPersistedSummaryEncodingHandlesNonFiniteCTCScores() throws {
        let summary = VocabularyBoostAuditSummary(audit: VocabularyBoostAudit(decisions: [decision(
            .vetoed,
            "Codex",
            originalScore: -.infinity,
            replacementScore: .infinity
        )]))

        let data = try XCTUnwrap(summary.encodedData())
        let decoded = try XCTUnwrap(VocabularyBoostAuditSummary.decode(from: data))
        XCTAssertEqual(decoded.decisions.first?.originalScore, -.infinity)
        XCTAssertEqual(decoded.decisions.first?.replacementScore, .infinity)
    }

    func testLegacyPersistedSummaryWithoutSourceStillDecodes() throws {
        let data = Data(#"{"decisions":[{"outcome":"vetoed","term":"Devin","originalText":"design","guarded":true,"originalWasRealWord":true,"originalScore":-2.0,"replacementScore":-1.0,"similarity":0.6,"falseApplyFeedback":null}]}"#.utf8)

        let decoded = try XCTUnwrap(VocabularyBoostAuditSummary.decode(from: data))

        XCTAssertEqual(decoded.decisions.first?.source, .screen)
    }

    func testDictationEntryStoresCodableAuditSummaryAndCorruptDataFailsOpen() {
        let summary = VocabularyBoostAuditSummary(audit: VocabularyBoostAudit(
            decisions: [decision(.applied, "Codex", originalText: "model")]
        ))
        let entry = DictationEntry(
            id: UUID(),
            text: "Codex",
            appName: "Notes",
            bundleId: "com.apple.Notes",
            wordCount: 1,
            duration: 1,
            mode: .dictation,
            date: Date(),
            vocabularyBoostAuditSummary: summary
        )

        XCTAssertEqual(entry.vocabularyBoostAuditSummary, summary)
        entry.vocabularyBoostAuditJSON = Data("not-json".utf8)
        XCTAssertNil(entry.vocabularyBoostAuditSummary)
    }

    // MARK: - Retroactive false applies

    func testFalseApplyFlagMatchesAppliedWrittenFormAndIsIdempotent() throws {
        var summary = VocabularyBoostAuditSummary(audit: VocabularyBoostAudit(decisions: [
            decision(.applied, "Codex", originalText: "model"),
            decision(.vetoed, "Codex", originalText: "model"),
            decision(.applied, "Convex", originalText: "context"),
        ]))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(summary.flagFalseApplies(
            matchingWrittenForm: "  codex ",
            reason: .dictionaryRemoved,
            recordedAt: timestamp
        ), 1)
        XCTAssertEqual(summary.flagFalseApplies(
            matchingWrittenForm: "Codex",
            reason: .dictionarySuppressed,
            recordedAt: timestamp.addingTimeInterval(1)
        ), 0)
        XCTAssertEqual(summary.decisions[0].falseApplyFeedback?.reason, .dictionaryRemoved)
        XCTAssertNil(summary.decisions[1].falseApplyFeedback)
        XCTAssertNil(summary.decisions[2].falseApplyFeedback)
    }

    func testDiagnosticLineExplainsOriginalSpanScoresAndFeedback() {
        var summary = VocabularyBoostAuditSummary(audit: VocabularyBoostAudit(decisions: [decision(
            .applied,
            "Codex",
            originalText: "model",
            guarded: false,
            originalWasRealWord: true,
            originalScore: -3.25,
            replacementScore: -1.75,
            similarity: 0.6
        )]))
        _ = summary.flagFalseApplies(
            matchingWrittenForm: "Codex",
            reason: .dictionaryRemoved,
            recordedAt: Date()
        )

        XCTAssertEqual(
            summary.decisions[0].diagnosticLine,
            "boost: applied Codex over \"model\" (source=manual, guarded=false, realWord=true, "
                + "originalScore=-3.25, replacementScore=-1.75, sim=0.60, "
                + "falseApply=dictionary_removed)"
        )
    }

    // MARK: - Analytics privacy boundary

    func testQualityBoostPropertiesContainOnlyRequestedAggregateCounts() {
        let sentinelTerm = "SENTINEL_PRIVATE_TERM"
        let sentinelOriginal = "SENTINEL_PRIVATE_ORIGINAL"
        let audit = VocabularyBoostAudit(decisions: [
            decision(.applied, sentinelTerm, originalText: sentinelOriginal, guarded: false),
            decision(.vetoed, "Guarded", guarded: true),
            decision(.vetoed, "Curated", guarded: false),
            decision(.droppedWithVeto, "Dropped", guarded: true),
        ])

        let properties = DictationQualityPipeline.boostProperties(for: audit.counts)
        XCTAssertEqual(properties, [
            "boost_applied_count": 1,
            "boost_vetoed_count": 2,
            "boost_dropped_with_veto_count": 1,
            "boost_guarded_veto_count": 1,
        ])
        XCTAssertFalse(String(describing: properties).contains(sentinelTerm))
        XCTAssertFalse(String(describing: properties).contains(sentinelOriginal))
        XCTAssertEqual(
            DictationQualityPipeline.boostProperties(for: .zero)["boost_applied_count"],
            0
        )
    }

    // MARK: - Sighting exclusion

    func testBoostInsertedTermDoesNotPromoteAsSighting() async {
        let store = PersonalizationMemoryStore()
        let context = ScreenContextBiasTestSupport.correctionContext(
            entities: [ScreenContextBiasTestSupport.screenEntity(
                value: "Priya Nadkarni", type: .personName, confidence: 0.9
            )]
        )
        let text = "thanks Priya Nadkarni, shipping today"
        let start = Date()

        // Three spaced, unedited pastes would normally cross the promotion
        // threshold — but every one is the boost echoing its own insertion,
        // so none may count.
        for offset in [0.0, 900.0, 1800.0] {
            await store.recordScreenEntityUsage(
                pastedText: text,
                editedText: text,
                context: context,
                boostInsertedTerms: ["priya nadkarni"],
                capabilities: .correctionDerivedMutations,
                now: start.addingTimeInterval(offset)
            )
        }
        XCTAssertFalse(
            store.recognitionBiasTerms().contains("Priya Nadkarni"),
            "a term the boost inserted itself must never self-promote"
        )
    }

    func testDeletingABoostInsertedTermStillDecays() async {
        let store = PersonalizationMemoryStore()
        let context = ScreenContextBiasTestSupport.correctionContext(
            entities: [ScreenContextBiasTestSupport.screenEntity(
                value: "Priya Nadkarni", type: .personName, confidence: 0.9
            )]
        )
        // The user deletes the boost-inserted name. Exclusion only blocks the
        // positive sighting branch; a deletion is a genuine rejection and must
        // still reach the decay path without error.
        await store.recordScreenEntityUsage(
            pastedText: "thanks Priya Nadkarni, shipping today",
            editedText: "thanks, shipping today",
            context: context,
            boostInsertedTerms: ["priya nadkarni"],
            capabilities: .correctionDerivedMutations
        )
        XCTAssertFalse(store.recognitionBiasTerms().contains("Priya Nadkarni"))
    }
}
