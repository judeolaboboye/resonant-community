import XCTest
@testable import Resonant

@MainActor
final class ScreenContextBiasTests: XCTestCase {
    // MARK: - Decode bias term selection

    func testDecodeBiasTermsFiltersToSafeNameLikeEntities() {
        let entities = [
            screenEntity(value: "Priya Nadkarni", type: .personName, confidence: 0.9),
            screenEntity(value: "priya nadkarni", type: .personName, confidence: 0.4),
            screenEntity(value: "Resonant", type: .customTerm, confidence: 0.7),
            screenEntity(value: "Ana", type: .personName, confidence: 0.95),
            screenEntity(value: "Card Holder", type: .personName, confidence: 0.95, isSensitive: true),
            screenEntity(value: "Blocked Person", type: .personName, confidence: 0.95, trustTier: .blocked),
            screenEntity(value: "Meta Person", type: .personName, confidence: 0.95, trustTier: .metadataOnly),
            screenEntity(value: "notes.txt", type: .fileName, confidence: 0.95),
        ]

        XCTAssertEqual(
            ScreenContextBiasTerms.decodeBiasTerms(from: entities),
            ["Priya Nadkarni", "Resonant"]
        )
    }

    func testDecodeBiasTermsCapAndDeterministicOrderOnTiedScores() {
        let entities = (0..<20).map { index in
            screenEntity(
                value: String(format: "Person%02d Surname", index),
                type: .personName,
                confidence: 0.5
            )
        }

        let terms = ScreenContextBiasTerms.decodeBiasTerms(from: entities)

        XCTAssertEqual(terms.count, ScreenContextBiasTerms.maximumTermCount)
        XCTAssertEqual(terms, terms.sorted())
    }

    func testSessionBeginClearsPreviousTargetTerms() {
        let session = ScreenContextBiasSession()
        session.update(entities: [
            screenEntity(value: "Priya Nadkarni", type: .personName, confidence: 0.9),
        ])
        XCTAssertEqual(session.terms, ["Priya Nadkarni"])

        session.begin()
        XCTAssertTrue(session.terms.isEmpty)
    }

    func testSessionEndOnlyClearsOwnGeneration() {
        let session = ScreenContextBiasSession()
        session.begin()
        let firstGeneration = session.generation
        session.update(entities: [
            screenEntity(value: "Priya Nadkarni", type: .personName, confidence: 0.9),
        ])

        // A next capture re-begins while the first capture's stop is still
        // post-processing: the first capture's stale end must not wipe the
        // new capture's terms.
        session.begin()
        session.update(entities: [
            screenEntity(value: "Xavier Boulanger", type: .personName, confidence: 0.9),
        ])
        session.end(ifGeneration: firstGeneration)
        XCTAssertEqual(session.terms, ["Xavier Boulanger"])

        session.end(ifGeneration: session.generation)
        XCTAssertTrue(session.terms.isEmpty)
    }

    func testLateRecipientPreservesBaseTermsWithoutStartingVocabularyRebuild() {
        let session = ScreenContextBiasSession()
        var termChangeCount = 0
        session.onTermsChanged = {
            termChangeCount += 1
        }
        session.begin()
        let generation = session.generation
        let fingerprint = ContextTargetFingerprint(
            role: "AXTextArea",
            identifierToken: "composer-a"
        )
        XCTAssertTrue(session.bindTarget(
            fingerprint: fingerprint,
            ifGeneration: generation
        ))
        XCTAssertTrue(session.updateBase(
            entities: [
                screenEntity(value: "Resonant", type: .customTerm, confidence: 0.9),
            ],
            ifGeneration: generation
        ))
        let baseTermChangeCount = termChangeCount

        let recipient = ActiveRecipientContext(
            fullName: "Henri Enguerran Badoux",
            firstName: "Henri",
            confidence: 0.96
        )
        XCTAssertTrue(session.publishRecipient(
            recipient,
            ifGeneration: generation,
            targetFingerprint: fingerprint
        ))

        XCTAssertEqual(session.terms, ["Resonant"])
        XCTAssertEqual(session.activeRecipient, recipient)
        XCTAssertEqual(termChangeCount, baseTermChangeCount)
    }

    func testSnapshotSealRejectsLateAndMismatchedRecipientPublication() {
        let session = ScreenContextBiasSession()
        session.begin()
        let generation = session.generation
        let fingerprint = ContextTargetFingerprint(
            role: "AXTextArea",
            identifierToken: "composer-a"
        )
        let otherFingerprint = ContextTargetFingerprint(
            role: "AXTextArea",
            identifierToken: "composer-b"
        )
        XCTAssertTrue(session.bindTarget(
            fingerprint: fingerprint,
            ifGeneration: generation
        ))

        let recipient = ActiveRecipientContext(
            fullName: "Henri Enguerran Badoux",
            firstName: "Henri",
            confidence: 0.96
        )
        XCTAssertFalse(session.publishRecipient(
            recipient,
            ifGeneration: generation,
            targetFingerprint: otherFingerprint
        ))
        XCTAssertNil(session.snapshotAndSealRecipient(ifGeneration: generation))
        XCTAssertFalse(session.publishRecipient(
            recipient,
            ifGeneration: generation,
            targetFingerprint: fingerprint
        ))
        XCTAssertNil(session.activeRecipient)
        XCTAssertTrue(session.terms.isEmpty)

        XCTAssertTrue(session.end(ifGeneration: generation))
        XCTAssertFalse(session.publishRecipient(
            recipient,
            ifGeneration: generation,
            targetFingerprint: fingerprint
        ))
    }

    // MARK: - Sighting promotion into durable memory

    func testSpacedScreenSightingsPromoteNameIntoRecognitionBias() async {
        let store = PersonalizationMemoryStore()
        let context = correctionContext(
            entities: [screenEntity(value: "Priya Nadkarni", type: .personName, confidence: 0.9)]
        )
        let text = "thanks Priya Nadkarni, shipping today"
        let start = Date()

        await store.recordScreenEntityUsage(
            pastedText: text,
            editedText: text,
            context: context,
            capabilities: .correctionDerivedMutations,
            now: start
        )
        XCTAssertFalse(
            store.recognitionBiasTerms().contains("Priya Nadkarni"),
            "one sighting must not be enough to rewrite the decode"
        )

        // Back-to-back pastes are one session: the decode can insert an
        // on-screen term itself, so an instant echo must not count.
        await store.recordScreenEntityUsage(
            pastedText: text,
            editedText: text,
            context: context,
            capabilities: .correctionDerivedMutations,
            now: start.addingTimeInterval(30)
        )
        XCTAssertFalse(store.recognitionBiasTerms().contains("Priya Nadkarni"))

        await store.recordScreenEntityUsage(
            pastedText: text,
            editedText: text,
            context: context,
            capabilities: .correctionDerivedMutations,
            now: start.addingTimeInterval(900)
        )
        XCTAssertTrue(store.recognitionBiasTerms().contains("Priya Nadkarni"))
    }

    func testSameEventCorrectionIsNotDoubleCountedAsSighting() async {
        let store = PersonalizationMemoryStore()
        let engine: PersonalizationLearningEngine = store
        let entities = [screenEntity(value: "Priya Nadkarni", type: .personName, confidence: 0.9)]

        // The user corrects the name once while it is also on screen: the
        // correction path records it, and the sighting pass must not add a
        // second confirmation for the same user action.
        await engine.recordFeedback(DictationFeedbackEvent(
            pastedText: "ask pria nadkarni",
            editedText: "ask Priya Nadkarni",
            rawTranscript: "ask pria nadkarni",
            corrections: [
                StoredCorrectionPair(
                    spoken: "pria nadkarni",
                    written: "Priya Nadkarni",
                    spokenIsRealWord: false
                )
            ],
            context: correctionContext(entities: entities),
            capabilities: .correctionDerivedMutations
        ))

        XCTAssertFalse(
            store.recognitionBiasTerms().contains("Priya Nadkarni"),
            "a single correction event must not cross the decode-rewrite threshold"
        )
    }

    func testMultiWordCommonPhraseIsNotLearned() async {
        let store = PersonalizationMemoryStore()
        let controls: PersonalizationControlDataSource = store
        let context = correctionContext(
            entities: [screenEntity(value: "Meeting Notes", type: .personName, confidence: 0.9)]
        )
        let text = "adding to Meeting Notes now"

        await store.recordScreenEntityUsage(
            pastedText: text,
            editedText: text,
            context: context,
            capabilities: .correctionDerivedMutations,
            now: Date()
        )

        let snapshot = await controls.controlsSnapshot()
        XCTAssertTrue(snapshot.entities.isEmpty)
    }

    func testCommonDictionaryWordSightingIsNeverLearned() async {
        let store = PersonalizationMemoryStore()
        let engine: PersonalizationLearningEngine = store
        let controls: PersonalizationControlDataSource = store
        let event = feedbackEvent(
            pastedText: "close the window please",
            editedText: "close the window please",
            entities: [screenEntity(value: "window", type: .customTerm, confidence: 0.9)]
        )

        await engine.recordFeedback(event)
        await engine.recordFeedback(event)
        await engine.recordFeedback(event)

        let snapshot = await controls.controlsSnapshot()
        XCTAssertTrue(snapshot.entities.isEmpty)
        XCTAssertTrue(store.recognitionBiasTerms().isEmpty)
    }

    func testRepeatedDeletionsSuppressSightedTermAndBlockResurrection() async {
        let store = PersonalizationMemoryStore()
        let engine: PersonalizationLearningEngine = store
        let controls: PersonalizationControlDataSource = store
        let entities = [screenEntity(value: "Priya Nadkarni", type: .personName, confidence: 0.9)]
        let deletionEvent = feedbackEvent(
            pastedText: "ping Priya Nadkarni about it",
            editedText: "ping about it",
            entities: entities
        )

        await engine.recordFeedback(feedbackEvent(
            pastedText: "thanks Priya Nadkarni",
            editedText: "thanks Priya Nadkarni",
            entities: entities
        ))

        // One deletion is a rephrase, not a rejection: demoted, not dead.
        await engine.recordFeedback(deletionEvent)
        let afterOne = await controls.controlsSnapshot()
        XCTAssertEqual(
            afterOne.entities.first { $0.value == "Priya Nadkarni" }?.isSuppressed,
            false
        )
        XCTAssertTrue(store.recognitionBiasTerms().isEmpty)

        // A second deletion is a real signal.
        await engine.recordFeedback(deletionEvent)
        let afterTwo = await controls.controlsSnapshot()
        XCTAssertEqual(
            afterTwo.entities.first { $0.value == "Priya Nadkarni" }?.isSuppressed,
            true
        )

        await engine.recordFeedback(feedbackEvent(
            pastedText: "thanks Priya Nadkarni",
            editedText: "thanks Priya Nadkarni",
            entities: entities
        ))
        XCTAssertTrue(store.recognitionBiasTerms().isEmpty)
    }

    func testSightingReinforcesCorrectionRecordAcrossTypeMismatch() async {
        let store = PersonalizationMemoryStore()
        let engine: PersonalizationLearningEngine = store
        let controls: PersonalizationControlDataSource = store

        // The correction path types a single token via entityType(for:)
        // (customTerm), while the screen packet's NER tags the same value as
        // a person name — the sighting must reinforce the correction record,
        // not mint a parallel one.
        await engine.recordFeedback(DictationFeedbackEvent(
            pastedText: "ask nadkarni",
            editedText: "ask Nadkarni",
            rawTranscript: "ask nadkarni",
            corrections: [
                StoredCorrectionPair(
                    spoken: "nadkarni",
                    written: "Nadkarni",
                    spokenIsRealWord: false
                )
            ],
            context: correctionContext(entities: []),
            capabilities: .correctionDerivedMutations
        ))

        let context = correctionContext(
            entities: [screenEntity(value: "Nadkarni", type: .personName, confidence: 0.9)]
        )
        await store.recordScreenEntityUsage(
            pastedText: "ping Nadkarni",
            editedText: "ping Nadkarni",
            context: context,
            capabilities: .correctionDerivedMutations,
            now: Date()
        )

        let snapshot = await controls.controlsSnapshot()
        XCTAssertEqual(snapshot.entities.filter { $0.value == "Nadkarni" }.count, 1)
    }

    func testContainsWholeTermRespectsBoundariesAndCase() {
        XCTAssertTrue(PersonalizationMemoryStore.containsWholeTerm("Priya", in: "thanks Priya!"))
        XCTAssertTrue(PersonalizationMemoryStore.containsWholeTerm("C3PO", in: "ask C3PO."))
        XCTAssertFalse(PersonalizationMemoryStore.containsWholeTerm("Priya", in: "thanks Priyanka"))
        XCTAssertFalse(PersonalizationMemoryStore.containsWholeTerm("priya", in: "thanks Priya"))
    }

    // MARK: - Fixtures

    private func screenEntity(
        value: String,
        type: ContextEntityType,
        confidence: Double,
        source: EvidenceSource = .visibleSnippet,
        trustTier: ContextTrustTier = .biasTerm,
        isSensitive: Bool = false
    ) -> ContextEntity {
        ScreenContextBiasTestSupport.screenEntity(
            value: value,
            type: type,
            confidence: confidence,
            source: source,
            trustTier: trustTier,
            isSensitive: isSensitive
        )
    }

    private func feedbackEvent(
        pastedText: String,
        editedText: String,
        entities: [ContextEntity]
    ) -> DictationFeedbackEvent {
        DictationFeedbackEvent(
            pastedText: pastedText,
            editedText: editedText,
            rawTranscript: nil,
            corrections: [],
            context: correctionContext(entities: entities),
            capabilities: .correctionDerivedMutations
        )
    }

    private func correctionContext(entities: [ContextEntity]) -> CorrectionObservationContext {
        ScreenContextBiasTestSupport.correctionContext(entities: entities)
    }
}
