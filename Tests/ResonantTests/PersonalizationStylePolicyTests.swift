import Foundation
import XCTest
@testable import Resonant

@MainActor
final class PersonalizationStylePolicyTests: XCTestCase {
    private func surface(
        appName: String = "Slack",
        bundleId: String = "com.tinyspeck.slackmacgap"
    ) -> SurfaceDescriptor {
        SurfaceClassifier.classify(
            appName: appName,
            bundleId: bundleId,
            windowTitle: "general - \(appName)",
            browserURL: nil
        )
    }

    private func context(for surface: SurfaceDescriptor) -> CorrectionObservationContext {
        CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )
    }

    private func packet(
        for surface: SurfaceDescriptor,
        fieldKind: FieldKind? = nil
    ) -> ContextPacket {
        var packetSurface = surface
        if let fieldKind {
            packetSurface.fieldKind = fieldKind
        }
        return ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: packetSurface,
            intent: DictationIntent(
                kind: .plainDictation,
                confidence: 1,
                allowsBiasTerms: true,
                allowsStyleHint: true,
                allowsSelectedTextGrounding: true,
                allowsVisibleContextGrounding: true,
                allowsMemoryGrounding: true,
                evidence: []
            ),
            entities: [],
            styleHint: nil,
            selectedTextPreview: nil,
            focusedFieldPreview: nil,
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
    }

    private func record(
        _ store: PersonalizationMemoryStore,
        pasted: String,
        edited: String,
        surface: SurfaceDescriptor,
        applied: AppliedStylePolicy = .none,
        capabilities: LearningCapabilities = .correctionDerivedMutations
    ) async {
        await store.recordStyleTransition(StyleTransitionFeedbackRequest(
            pastedText: pasted,
            editedText: edited,
            context: context(for: surface),
            capabilities: capabilities,
            appliedStylePolicy: applied
        ))
    }

    func testDirectionalActivationTruthTable() {
        XCTAssertEqual(
            StylePolicy.resolve(evidence: StylePolicyEvidence(lowercaseOpening: 2)).openingCase,
            .inherit,
            "2-vs-0 is below the minimum"
        )
        XCTAssertEqual(
            StylePolicy.resolve(evidence: StylePolicyEvidence(lowercaseOpening: 3)).openingCase,
            .lowercase,
            "3-vs-0 activates"
        )
        XCTAssertEqual(
            StylePolicy.resolve(evidence: StylePolicyEvidence(
                lowercaseOpening: 3,
                sentenceCaseOpening: 2
            )).openingCase,
            .inherit,
            "3-vs-2 lacks a 2:1 lead"
        )
        XCTAssertEqual(
            StylePolicy.resolve(evidence: StylePolicyEvidence(
                lowercaseOpening: 4,
                sentenceCaseOpening: 2
            )).openingCase,
            .lowercase,
            "4-vs-2 activates at exactly 2:1"
        )
        XCTAssertEqual(
            StylePolicy.resolve(evidence: StylePolicyEvidence(
                lowercaseOpening: 4,
                sentenceCaseOpening: 4
            )).openingCase,
            .inherit,
            "a tie is conflict, not a policy"
        )
        XCTAssertEqual(
            StylePolicy.resolve(evidence: StylePolicyEvidence(
                trailingPeriodOmission: 3,
                trailingPeriodRequirement: 2
            )).trailingPeriod,
            .inherit
        )
        XCTAssertEqual(
            StylePolicy.resolve(evidence: StylePolicyEvidence(
                listOmission: 3,
                listRequirement: 6
            )).listMarkers,
            .require,
            "later opposite evidence can reverse direction"
        )
    }

    func testDirectOppositeEditsDeactivateThenReverseOpeningPolicy() async {
        let store = PersonalizationMemoryStore()
        let target = surface()

        for index in 0..<3 {
            await record(
                store,
                pasted: "Message \(index)",
                edited: "message \(index)",
                surface: target
            )
        }
        XCTAssertEqual(store.stylePolicy(for: target).openingCase, .lowercase)

        for index in 0..<2 {
            await record(
                store,
                pasted: "reply \(index)",
                edited: "Reply \(index)",
                surface: target
            )
        }
        XCTAssertEqual(store.stylePolicy(for: target).openingCase, .inherit)

        for index in 2..<6 {
            await record(
                store,
                pasted: "reply \(index)",
                edited: "Reply \(index)",
                surface: target
            )
        }
        XCTAssertEqual(store.stylePolicy(for: target).openingCase, .sentenceCase)
    }

    func testUnchangedOutputCannotOriginatePolicyAndConfirmsOnlyAppliedActiveRule() async {
        let store = PersonalizationMemoryStore()
        let target = surface()

        for _ in 0..<5 {
            await record(
                store,
                pasted: "formatter output",
                edited: "formatter output",
                surface: target,
                applied: AppliedStylePolicy(openingCase: .lowercase)
            )
        }
        XCTAssertEqual(store.stylePolicy(for: target), .inherit)
        XCTAssertEqual(store.stylePolicyEvidence(for: target), StylePolicyEvidence())

        for index in 0..<3 {
            await record(
                store,
                pasted: "Message \(index)",
                edited: "message \(index)",
                surface: target
            )
        }
        let evidenceBeforeConfirmation = store.stylePolicyEvidence(for: target)
        await record(
            store,
            pasted: "already lowercase",
            edited: "already lowercase",
            surface: target,
            applied: AppliedStylePolicy(openingCase: .lowercase)
        )
        await record(
            store,
            pasted: "wrong metadata",
            edited: "wrong metadata",
            surface: target,
            applied: AppliedStylePolicy(openingCase: .sentenceCase)
        )

        XCTAssertEqual(store.stylePolicy(for: target).openingCase, .lowercase)
        var expectedEvidence = evidenceBeforeConfirmation
        expectedEvidence.appliedPolicyConfirmations += 1
        XCTAssertEqual(store.stylePolicyEvidence(for: target), expectedEvidence)
    }

    func testStylePolicyIsSurfaceScopedAndFeedsLocalAndCloudConsumers() async {
        let store = PersonalizationMemoryStore()
        let slack = surface()
        let mail = surface(appName: "Mail", bundleId: "com.apple.mail")

        for index in 0..<3 {
            await record(
                store,
                pasted: "Sounds good \(index).",
                edited: "sounds good \(index).",
                surface: slack
            )
        }

        let policy = store.stylePolicy(for: slack)
        XCTAssertEqual(policy.openingCase, .lowercase)
        XCTAssertEqual(store.formattingPreferences(for: slack).stylePolicy, policy)
        XCTAssertTrue(store.snapshot(for: slack).styleHint?.contains("lowercase opening") == true)
        XCTAssertEqual(store.stylePolicy(for: mail), .inherit)
        XCTAssertEqual(store.formattingPreferences(for: mail).stylePolicy, .inherit)
    }

    func testRealPostProcessorKeepsSemanticQuestionsOutsideLearnedPeriodOmission() async {
        let settings = SettingsManager.shared
        let originalRemoveFillersEnabled = settings.removeFillersEnabled
        let originalRemoveFalseStartsEnabled = settings.removeFalseStartsEnabled
        let originalITNEnabled = settings.itnEnabled
        let originalAutoPunctuationEnabled = settings.autoPunctuationEnabled
        let originalBulletPointsEnabled = settings.bulletPointsEnabled
        defer {
            settings.removeFillersEnabled = originalRemoveFillersEnabled
            settings.removeFalseStartsEnabled = originalRemoveFalseStartsEnabled
            settings.itnEnabled = originalITNEnabled
            settings.autoPunctuationEnabled = originalAutoPunctuationEnabled
            settings.bulletPointsEnabled = originalBulletPointsEnabled
        }
        settings.removeFillersEnabled = false
        settings.removeFalseStartsEnabled = false
        settings.itnEnabled = false
        settings.autoPunctuationEnabled = true
        settings.bulletPointsEnabled = false

        let store = PersonalizationMemoryStore()
        let mail = surface(appName: "Mail", bundleId: "com.apple.mail")
        let docs = surface(appName: "Pages", bundleId: "com.apple.pages")
        XCTAssertEqual(mail.kind, .email)
        XCTAssertEqual(docs.kind, .docs)
        for index in 0..<3 {
            await record(
                store,
                pasted: "Status \(index).",
                edited: "Status \(index)",
                surface: mail
            )
        }
        XCTAssertEqual(store.stylePolicy(for: mail).trailingPeriod, .omit)
        XCTAssertEqual(store.stylePolicy(for: docs), .inherit)

        let processor = PostProcessor(dictionaryStore: DictionaryStore())
        processor.formattingPreferenceProvider = store

        let inferredQuestion = await processor.processDetailed(
            "can you ship the update",
            contextPacket: packet(for: mail)
        )
        XCTAssertEqual(inferredQuestion.text, "Can you ship the update?")
        XCTAssertEqual(
            inferredQuestion.styleApplicationProvenance.trailingPeriod?.policy,
            .omit
        )
        XCTAssertEqual(
            inferredQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let periodTerminatedQuestion = await processor.processDetailed(
            "can you ship the update.",
            contextPacket: packet(for: mail)
        )
        XCTAssertEqual(periodTerminatedQuestion.text, "Can you ship the update?")
        XCTAssertEqual(
            periodTerminatedQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let existingQuestion = await processor.processDetailed(
            "can you ship the update?",
            contextPacket: packet(for: mail)
        )
        XCTAssertEqual(existingQuestion.text, "Can you ship the update?")
        XCTAssertEqual(
            existingQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let omittedStatement = await processor.processDetailed(
            "ship the update.",
            contextPacket: packet(for: mail)
        )
        XCTAssertEqual(omittedStatement.text, "Ship the update")
        XCTAssertEqual(
            omittedStatement.styleApplicationProvenance.trailingPeriod?.disposition,
            .changed
        )

        let flattenedQuestion = await processor.processDetailed(
            "status update\ncan you verify",
            contextPacket: packet(for: mail, fieldKind: .subject)
        )
        XCTAssertEqual(flattenedQuestion.text, "Status update; Can you verify?")
        XCTAssertEqual(
            flattenedQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let flattenedStatement = await processor.processDetailed(
            "can you verify\nstatus update",
            contextPacket: packet(for: mail, fieldKind: .subject)
        )
        XCTAssertEqual(flattenedStatement.text, "Can you verify; Status update")
        XCTAssertEqual(
            flattenedStatement.styleApplicationProvenance.trailingPeriod?.disposition,
            .alreadyConformed
        )

        let noPolicyStatement = await processor.processDetailed(
            "ship the update",
            contextPacket: packet(for: docs)
        )
        XCTAssertEqual(noPolicyStatement.text, "Ship the update.")
        XCTAssertNil(noPolicyStatement.styleApplicationProvenance.trailingPeriod)

        settings.autoPunctuationEnabled = false
        let vetoedQuestion = await processor.processDetailed(
            "can you ship the update",
            contextPacket: packet(for: mail)
        )
        XCTAssertEqual(vetoedQuestion.text, "Can you ship the update")
        XCTAssertEqual(
            vetoedQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .vetoed
        )
        let vetoedExistingPeriod = await processor.processDetailed(
            "can you ship the update.",
            contextPacket: packet(for: mail)
        )
        XCTAssertEqual(vetoedExistingPeriod.text, "Can you ship the update.")
    }

    func testTrailingPeriodAdditionsActivateRequireThenOppositeEditsReverse() async {
        let store = PersonalizationMemoryStore()
        let target = surface()

        for index in 0..<3 {
            await record(
                store,
                pasted: "Status \(index)",
                edited: "Status \(index).",
                surface: target
            )
        }
        XCTAssertEqual(store.stylePolicy(for: target).trailingPeriod, .require)
        XCTAssertEqual(
            store.formattingPreferences(for: target).stylePolicy.trailingPeriod,
            .require
        )

        for index in 0..<2 {
            await record(
                store,
                pasted: "Reply \(index).",
                edited: "Reply \(index)",
                surface: target
            )
        }
        XCTAssertEqual(store.stylePolicy(for: target).trailingPeriod, .inherit)

        for index in 2..<6 {
            await record(
                store,
                pasted: "Reply \(index).",
                edited: "Reply \(index)",
                surface: target
            )
        }
        XCTAssertEqual(store.stylePolicy(for: target).trailingPeriod, .omit)
    }

    func testRuntimeAndControlsUseSameTrailingPeriodActivationThreshold() async {
        let store = PersonalizationMemoryStore()
        let target = surface()

        for index in 0..<2 {
            await record(
                store,
                pasted: "Status \(index)",
                edited: "Status \(index).",
                surface: target
            )
        }
        XCTAssertEqual(store.stylePolicy(for: target).trailingPeriod, .inherit)
        XCTAssertEqual(
            store.formattingPreferences(for: target).stylePolicy.trailingPeriod,
            .inherit
        )
        var controls = await store.controlsSnapshot()
        XCTAssertEqual(
            controls.styles.first?.summary,
            "Collecting writing-habit evidence."
        )
        XCTAssertTrue(controls.formatPreferences.isEmpty)

        await record(
            store,
            pasted: "Status 2",
            edited: "Status 2.",
            surface: target
        )

        XCTAssertEqual(store.stylePolicy(for: target).trailingPeriod, .require)
        XCTAssertEqual(
            store.formattingPreferences(for: target).stylePolicy.trailingPeriod,
            .require
        )
        controls = await store.controlsSnapshot()
        XCTAssertTrue(controls.styles.first?.summary.contains("include a trailing period") == true)
        XCTAssertTrue(
            controls.formatPreferences.isEmpty,
            "surface period policy must not recreate an obsolete global punctuation row"
        )
    }

    func testRawAutoSendHabitsNeverCreateCaseListOrPunctuationPolicy() async {
        let store = PersonalizationMemoryStore()
        let target = surface()
        let targetContext = context(for: target)

        for transcript in [
            "sounds good",
            "on my way",
            "will do",
        ] {
            await store.recordAutoSentDelivery(RawTranscriptHabitFeedbackRequest(
                rawTranscript: transcript,
                context: targetContext,
                capabilities: .rawTranscriptHabits
            ))
        }

        XCTAssertEqual(store.stylePolicy(for: target), .inherit)
        XCTAssertEqual(store.formattingPreferences(for: target).stylePolicy, .inherit)
        XCTAssertTrue(store.snapshot(for: target).styleHint?.contains("concise") == true)
    }

    func testMissingOrWrongCapabilityBlocksEveryStyleMutationRequest() async {
        let store = PersonalizationMemoryStore()
        let target = surface()

        for index in 0..<3 {
            await record(
                store,
                pasted: "Message \(index).",
                edited: "message \(index)",
                surface: target,
                capabilities: .none
            )
            await store.recordAutoSentDelivery(RawTranscriptHabitFeedbackRequest(
                rawTranscript: "sounds good",
                context: context(for: target),
                capabilities: .correctionDerivedMutations
            ))
        }

        XCTAssertEqual(store.stylePolicy(for: target), .inherit)
        XCTAssertNil(store.snapshot(for: target).styleHint)
    }

    func testDirectEvidenceAndHabitProvenancePersistAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("StylePolicy.store")
        let target = surface()

        do {
            let dataStore = DataStore(storeURLOverride: storeURL)
            await dataStore.setup()
            XCTAssertTrue(dataStore.isReady)
            let memory = PersonalizationMemoryStore()
            memory.setup(store: dataStore)

            for index in 0..<3 {
                await record(
                    memory,
                    pasted: "Message \(index)",
                    edited: "message \(index)",
                    surface: target
                )
            }
            await record(
                memory,
                pasted: "already lowercase",
                edited: "already lowercase",
                surface: target,
                applied: AppliedStylePolicy(openingCase: .lowercase)
            )
            await memory.recordAutoSentDelivery(RawTranscriptHabitFeedbackRequest(
                rawTranscript: "on my way",
                context: context(for: target),
                capabilities: .rawTranscriptHabits
            ))
            await memory.saveChanges()
        }

        let reopenedDataStore = DataStore(storeURLOverride: storeURL)
        await reopenedDataStore.setup()
        let reopenedMemory = PersonalizationMemoryStore()
        reopenedMemory.setup(store: reopenedDataStore)

        XCTAssertEqual(reopenedMemory.stylePolicy(for: target).openingCase, .lowercase)
        XCTAssertEqual(
            reopenedMemory.stylePolicyEvidence(for: target),
            StylePolicyEvidence(lowercaseOpening: 3, appliedPolicyConfirmations: 1)
        )
        XCTAssertTrue(reopenedMemory.snapshot(for: target).styleHint?.contains("concise") == true)
    }

    func testCloudOrSelectionReplacementCannotInheritLocalOpeningProvenance() {
        let provenance = StyleApplicationProvenance(
            openingCase: StyleRuleApplication(.lowercase, disposition: .changed)
        )
        let outcome = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            requestedText: "Hello.",
            effectiveInsertedText: "Hello."
        )

        let applied = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: provenance,
            localPostProcessedText: "hello.",
            resolvedText: "Hello.",
            requestedDeliveryText: "Hello.",
            stageTrace: StyleDeliveryStageTrace(
                cloudOrSelectionReplacedPostProcessing: true
            ),
            deliveryOutcome: outcome
        )

        XCTAssertEqual(applied, .none)
    }

    func testNonConfirmableLocalDispositionsNeverBecomeAppliedPolicy() {
        for disposition in [
            StyleRuleApplicationDisposition.inapplicable,
            .vetoed,
            .notManifested,
        ] {
            let applied = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
                provenance: StyleApplicationProvenance(
                    openingCase: StyleRuleApplication(.lowercase, disposition: disposition),
                    listMarkers: StyleRuleApplication(.omit, disposition: disposition),
                    trailingPeriod: StyleRuleApplication(.require, disposition: disposition)
                ),
                localPostProcessedText: "first write tests second ship safely.",
                resolvedText: "first write tests second ship safely.",
                requestedDeliveryText: "first write tests second ship safely.",
                stageTrace: .localOnly,
                deliveryOutcome: PasteManager.DeliveryOutcome(
                    delivered: true,
                    receipt: nil,
                    requestedText: "first write tests second ship safely.",
                    effectiveInsertedText: "first write tests second ship safely."
                )
            )
            XCTAssertEqual(applied, .none, "\(disposition) must fail closed")
        }
    }

    func testFinalResolverRejectsSemanticQuestionsForBothPeriodPolicies() {
        func resolve(
            _ text: String,
            policy: TrailingPeriodPolicy
        ) -> AppliedStylePolicy {
            StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
                provenance: StyleApplicationProvenance(
                    trailingPeriod: StyleRuleApplication(
                        policy,
                        disposition: .alreadyConformed
                    )
                ),
                localPostProcessedText: text,
                resolvedText: text,
                requestedDeliveryText: text,
                stageTrace: .localOnly,
                deliveryOutcome: PasteManager.DeliveryOutcome(
                    delivered: true,
                    receipt: nil,
                    requestedText: text,
                    effectiveInsertedText: text
                )
            )
        }

        XCTAssertNil(resolve("Can you ship", policy: .omit).trailingPeriod)
        XCTAssertNil(resolve("Can you ship.", policy: .require).trailingPeriod)
        XCTAssertNil(
            resolve("Status sent; Can you verify", policy: .omit).trailingPeriod
        )
        XCTAssertNil(
            resolve("Context: Can you verify", policy: .omit).trailingPeriod
        )
        XCTAssertNil(
            resolve("Thinking… Can you verify", policy: .omit).trailingPeriod
        )
        XCTAssertNil(
            resolve(
                "We operate in the U.S. Can you verify",
                policy: .omit
            ).trailingPeriod
        )
        XCTAssertNil(
            resolve("Are you in the U.S.", policy: .require).trailingPeriod
        )
        XCTAssertNil(
            resolve("Didn't you see it", policy: .omit).trailingPeriod
        )
        XCTAssertNil(
            resolve("Has the deploy finished", policy: .omit).trailingPeriod
        )
        XCTAssertEqual(
            resolve("Can you verify; Status sent", policy: .omit).trailingPeriod,
            .omit
        )
        XCTAssertEqual(
            resolve("Can you verify: Status sent", policy: .omit).trailingPeriod,
            .omit
        )
        XCTAssertEqual(
            resolve("Can you verify… Status sent", policy: .omit).trailingPeriod,
            .omit
        )

        XCTAssertEqual(resolve("Should work now", policy: .omit).trailingPeriod, .omit)
        XCTAssertEqual(resolve("Should work now.", policy: .require).trailingPeriod, .require)
    }

    func testFinalListMarkerRequiresOpportunityAndManifestation() {
        let ordinaryProse = "Please ship the ordinary update."
        let falseCandidate = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: StyleApplicationProvenance(
                listMarkers: StyleRuleApplication(.omit, disposition: .alreadyConformed)
            ),
            localPostProcessedText: ordinaryProse,
            resolvedText: ordinaryProse,
            requestedDeliveryText: ordinaryProse,
            stageTrace: .localOnly,
            deliveryOutcome: PasteManager.DeliveryOutcome(
                delivered: true,
                receipt: nil,
                requestedText: ordinaryProse,
                effectiveInsertedText: ordinaryProse
            )
        )
        XCTAssertNil(falseCandidate.listMarkers)

        let listShapedProse = "First write tests second ship safely."
        let omitted = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: StyleApplicationProvenance(
                listMarkers: StyleRuleApplication(.omit, disposition: .alreadyConformed)
            ),
            localPostProcessedText: listShapedProse,
            resolvedText: listShapedProse,
            requestedDeliveryText: listShapedProse,
            stageTrace: .localOnly,
            deliveryOutcome: PasteManager.DeliveryOutcome(
                delivered: true,
                receipt: nil,
                requestedText: listShapedProse,
                effectiveInsertedText: listShapedProse
            )
        )
        XCTAssertEqual(omitted.listMarkers, .omit)

        let requiredList = "1. Write tests\n2. Ship safely"
        let required = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: StyleApplicationProvenance(
                listMarkers: StyleRuleApplication(.require, disposition: .changed)
            ),
            localPostProcessedText: requiredList,
            resolvedText: requiredList,
            requestedDeliveryText: requiredList,
            stageTrace: .localOnly,
            deliveryOutcome: PasteManager.DeliveryOutcome(
                delivered: true,
                receipt: nil,
                requestedText: requiredList,
                effectiveInsertedText: requiredList
            )
        )
        XCTAssertEqual(required.listMarkers, .require)
    }

    func testFinalResolverRechecksSmartLinkSignatureAndDuplicateClosingStagesPerFamily() {
        let provenance = StyleApplicationProvenance(
            openingCase: StyleRuleApplication(.sentenceCase, disposition: .alreadyConformed),
            trailingPeriod: StyleRuleApplication(.require, disposition: .alreadyConformed)
        )
        let smartLinkRequest = "[Docs](https://example.com)."
        let smartLinkOutcome = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            requestedText: smartLinkRequest,
            effectiveInsertedText: "Docs."
        )
        let afterSmartLink = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: provenance,
            localPostProcessedText: "Docs.",
            resolvedText: "Docs.",
            requestedDeliveryText: smartLinkRequest,
            stageTrace: StyleDeliveryStageTrace(smartLinksChangedText: true),
            deliveryOutcome: smartLinkOutcome
        )
        XCTAssertEqual(afterSmartLink.openingCase, .sentenceCase)
        XCTAssertEqual(afterSmartLink.trailingPeriod, .require)

        let signedRequest = "Docs.\n\nSent with [Resonant](https://example.com)"
        let signedOutcome = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            requestedText: signedRequest,
            effectiveInsertedText: "Docs.\n\nSent with Resonant"
        )
        let afterSignature = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: provenance,
            localPostProcessedText: "Docs.",
            resolvedText: "Docs.",
            requestedDeliveryText: signedRequest,
            stageTrace: StyleDeliveryStageTrace(signatureChangedText: true),
            deliveryOutcome: signedOutcome
        )
        XCTAssertEqual(afterSignature.openingCase, .sentenceCase)
        XCTAssertNil(afterSignature.trailingPeriod)

        let duplicateClosingLocal = "Hello.\n\nBest,\nTom"
        let duplicateClosingOutcome = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            requestedText: "Hello.",
            effectiveInsertedText: "Hello."
        )
        let afterDuplicateClosing = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: StyleApplicationProvenance(
                openingCase: StyleRuleApplication(.sentenceCase, disposition: .alreadyConformed)
            ),
            localPostProcessedText: duplicateClosingLocal,
            resolvedText: duplicateClosingLocal,
            requestedDeliveryText: "Hello.",
            stageTrace: StyleDeliveryStageTrace(duplicateClosingChangedText: true),
            deliveryOutcome: duplicateClosingOutcome
        )
        XCTAssertEqual(afterDuplicateClosing.openingCase, .sentenceCase)
    }

    func testUnchangedReadbackConfirmsOnlyApplicableFinalMarkerForCurrentPolicy() async {
        let store = PersonalizationMemoryStore()
        let target = surface()
        for index in 0..<3 {
            await record(
                store,
                pasted: "Message \(index)",
                edited: "message \(index)",
                surface: target
            )
        }
        XCTAssertEqual(store.stylePolicy(for: target).openingCase, .lowercase)
        let before = store.stylePolicyEvidence(for: target)
        let provenance = StyleApplicationProvenance(
            openingCase: StyleRuleApplication(.lowercase, disposition: .changed)
        )

        let invalidated = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: provenance,
            localPostProcessedText: "local output.",
            resolvedText: "Cloud output.",
            requestedDeliveryText: "Cloud output.",
            stageTrace: StyleDeliveryStageTrace(
                cloudOrSelectionReplacedPostProcessing: true
            ),
            deliveryOutcome: PasteManager.DeliveryOutcome(
                delivered: true,
                receipt: nil,
                requestedText: "Cloud output.",
                effectiveInsertedText: "Cloud output."
            )
        )
        await record(
            store,
            pasted: "Cloud output.",
            edited: "Cloud output.",
            surface: target,
            applied: invalidated
        )
        XCTAssertEqual(store.stylePolicyEvidence(for: target), before)

        let confirmed = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: provenance,
            localPostProcessedText: "local output.",
            resolvedText: "local output.",
            requestedDeliveryText: "local output.",
            stageTrace: .localOnly,
            deliveryOutcome: PasteManager.DeliveryOutcome(
                delivered: true,
                receipt: nil,
                requestedText: "local output.",
                effectiveInsertedText: "local output."
            )
        )
        XCTAssertEqual(confirmed.openingCase, .lowercase)
        await record(
            store,
            pasted: "local output.",
            edited: "local output.",
            surface: target,
            applied: confirmed
        )
        var expected = before
        expected.appliedPolicyConfirmations += 1
        XCTAssertEqual(store.stylePolicyEvidence(for: target), expected)
    }
}
