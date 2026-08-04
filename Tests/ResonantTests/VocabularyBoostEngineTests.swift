import XCTest
import FluidAudio
@testable import Resonant

final class VocabularyBoostEngineTests: XCTestCase {

    // MARK: - Term normalization

    func testDropsShortNumericAndDuplicateTerms() {
        let terms = ParakeetVocabularyBoostEngine.normalizedTerms([
            "Kubernetes",
            "kubernetes",     // case-insensitive duplicate
            "AI",             // too short
            "  Convex  ",     // trimmed
            "12345",          // no letters
            "",
            "PostHog"
        ])

        XCTAssertEqual(terms, ["Kubernetes", "Convex", "PostHog"])
    }

    func testPreservesProviderOrderAndCapsTermCount() {
        let raw = (0..<300).map { "term\($0)word" }
        let terms = ParakeetVocabularyBoostEngine.normalizedTerms(raw)

        XCTAssertEqual(terms.count, ParakeetVocabularyBoostEngine.maximumTermCount)
        XCTAssertEqual(terms.first, "term0word")
        XCTAssertEqual(terms.last, "term\(ParakeetVocabularyBoostEngine.maximumTermCount - 1)word")
    }

    func testKeepsHyphenatedAndAccentedTerms() {
        let terms = ParakeetVocabularyBoostEngine.normalizedTerms([
            "Häagen-Dazs",
            "e-mail"
        ])

        XCTAssertEqual(terms, ["Häagen-Dazs", "e-mail"])
    }

    func testHigherPrivilegeDuplicateUpgradesSourceEvenAfterCap() {
        var raw = (0..<ParakeetVocabularyBoostEngine.maximumTermCount).map {
            VocabularyBoostTerm(text: "term\($0)word", source: .screen)
        }
        raw.append(VocabularyBoostTerm(text: "TERM0WORD", source: .manual))
        raw.append(VocabularyBoostTerm(text: "overflowword", source: .manual))

        let terms = ParakeetVocabularyBoostEngine.normalizedTerms(raw)

        XCTAssertEqual(terms.count, ParakeetVocabularyBoostEngine.maximumTermCount)
        XCTAssertEqual(terms.first, VocabularyBoostTerm(text: "term0word", source: .manual))
        XCTAssertFalse(terms.contains { $0.text == "overflowword" })
    }

    @MainActor
    func testDictionaryTermsCarryAutoLearnedAndManualPrivilege() {
        let dictionary = DictionaryStore()
        for _ in 0..<DictionaryStore.tier1Threshold {
            dictionary.recordAutoCorrection(
                spoken: "dvinn",
                written: "Devin",
                spokenIsRealWord: false,
                writtenIsProperNoun: true
            )
        }
        XCTAssertEqual(
            dictionary.vocabularyBoostTerms(),
            [VocabularyBoostTerm(text: "Devin", source: .autoLearned)]
        )

        dictionary.add(spoken: "devon", written: "Devin")

        XCTAssertEqual(
            dictionary.vocabularyBoostTerms(),
            [VocabularyBoostTerm(text: "Devin", source: .manual)]
        )
    }

    // MARK: - Decode admission gate

    /// The reported field failure: one correction of "Tees → Thijs" made
    /// "Thijs" a permanent acoustic competitor that then overwrote spoken
    /// "things". The proper-noun fast path may rewrite that exact token in the
    /// text layer, but reaching the decode costs the real-word evidence bar.
    @MainActor
    func testSingleProperNounCorrectionDoesNotReachTheDecode() {
        let dictionary = DictionaryStore()
        dictionary.recordAutoCorrection(
            spoken: "tees",
            written: "Thijs",
            spokenIsRealWord: true,
            writtenIsProperNoun: true
        )

        XCTAssertTrue(dictionary.vocabularyBoostTerms().isEmpty)
        // ...while the exact pair still applies as post-processing text.
        XCTAssertEqual(dictionary.applyCorrections(to: "call tees"), "call Thijs")
        XCTAssertEqual(dictionary.cloudDictionaryTerms(), ["Thijs"])
    }

    /// A non-word misrecognition is the shape the decode boost exists for, so
    /// it clears at the lower tier-1 bar.
    @MainActor
    func testRepeatedNonWordCorrectionReachesTheDecode() {
        let dictionary = DictionaryStore()
        for _ in 0..<DictionaryStore.tier1Threshold {
            dictionary.recordAutoCorrection(
                spoken: "xjs",
                written: "nextjs",
                spokenIsRealWord: false,
                writtenIsProperNoun: false
            )
        }

        XCTAssertEqual(
            dictionary.vocabularyBoostTerms(),
            [VocabularyBoostTerm(text: "nextjs", source: .autoLearned)]
        )
    }

    /// The fast path also relaxes the *ratio* (0.5 vs 0.6), so clearing the
    /// standard count alone would still let a name the user accepts half the
    /// time bias the decode. Both halves of the standard bar must apply.
    @MainActor
    func testProperNounNeedsTheStandardRatioNotTheFastPathRatio() {
        let dictionary = DictionaryStore()
        for _ in 0..<DictionaryStore.tier2Threshold {
            dictionary.recordAutoCorrection(
                spoken: "rainier",
                written: "Reinier",
                spokenIsRealWord: true,
                writtenIsProperNoun: true
            )
        }
        // Left uncorrected just as often: ratio 0.5 clears the fast path but
        // not the 0.6 standard bar.
        for _ in 0..<DictionaryStore.tier2Threshold {
            dictionary.recordUncorrected(spoken: "rainier")
        }

        XCTAssertEqual(dictionary.cloudDictionaryTerms(), ["Reinier"])
        XCTAssertTrue(dictionary.vocabularyBoostTerms().isEmpty)
    }

    /// Case-only preferences carry no acoustic information, so they never
    /// belong in the rescorer's vocabulary however well confirmed.
    @MainActor
    func testCaseOnlyPreferenceNeverReachesTheDecode() {
        let dictionary = DictionaryStore()
        for _ in 0..<(DictionaryStore.caseDowncaseThreshold + 1) {
            dictionary.recordAutoCorrection(
                spoken: "Vibe",
                written: "vibe",
                spokenIsRealWord: true,
                writtenIsProperNoun: false
            )
        }

        XCTAssertTrue(dictionary.vocabularyBoostTerms().isEmpty)
    }

    /// Explicit curation still reaches the decode on the first entry — the
    /// runtime veto, not the admission gate, is what keeps it off real speech.
    @MainActor
    func testManualEntryReachesTheDecodeImmediately() {
        let dictionary = DictionaryStore()
        dictionary.add(spoken: "clawed", written: "Claude")

        XCTAssertEqual(
            dictionary.vocabularyBoostTerms(),
            [VocabularyBoostTerm(text: "Claude", source: .manual)]
        )
    }

    // MARK: - Language gate

    func testLanguageSelectionSeparatesExplicitEnglishAutoAndUnsupportedLanguages() {
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.languageMode(for: "en"),
            .explicitEnglish
        )
        for selection in [nil, "", "auto", " AUTO "] as [String?] {
            XCTAssertEqual(
                VocabularyBoostAttemptRouter.languageMode(for: selection),
                .automaticConditional
            )
        }
        for code in ["de", "fr", "ru", "uk"] {
            XCTAssertNil(VocabularyBoostAttemptRouter.languageMode(for: code))
        }
    }

    /// FluidAudio still receives nil for its own Auto decode. Vocabulary
    /// boosting applies the separate transcript-language decision afterwards.
    func testAutoMapsToNilHint() {
        XCTAssertNil(FluidAudioLanguageHint.map("auto"))
    }

    func testEveryPreflightExitReportsTypedSkipReason() {
        let eligible = VocabularyBoostEngineRuntimeConfiguration(
            enabled: true,
            lowLatencyMode: false
        )
        let scenarios: [(String, VocabularyBoostEnginePreflightDecision)] = [
            (
                "disabled",
                VocabularyBoostAttemptRouter.enginePreflight(
                    configuration: .init(enabled: false, lowLatencyMode: false),
                    selectedLanguage: "en",
                    hasTokenTimings: true,
                    transcriptIsEmpty: false,
                    eligibleTermCount: 1,
                    helperModelDownloaded: true
                )
            ),
            (
                "low latency",
                VocabularyBoostAttemptRouter.enginePreflight(
                    configuration: .init(enabled: true, lowLatencyMode: true),
                    selectedLanguage: "en",
                    hasTokenTimings: true,
                    transcriptIsEmpty: false,
                    eligibleTermCount: 1,
                    helperModelDownloaded: true
                )
            ),
            (
                "unsupported language",
                VocabularyBoostAttemptRouter.enginePreflight(
                    configuration: eligible,
                    selectedLanguage: "de",
                    hasTokenTimings: true,
                    transcriptIsEmpty: false,
                    eligibleTermCount: 1,
                    helperModelDownloaded: true
                )
            ),
            (
                "missing timings",
                VocabularyBoostAttemptRouter.enginePreflight(
                    configuration: eligible,
                    selectedLanguage: "en",
                    hasTokenTimings: false,
                    transcriptIsEmpty: false,
                    eligibleTermCount: 1,
                    helperModelDownloaded: true
                )
            ),
            (
                "empty transcript",
                VocabularyBoostAttemptRouter.enginePreflight(
                    configuration: eligible,
                    selectedLanguage: "en",
                    hasTokenTimings: true,
                    transcriptIsEmpty: true,
                    eligibleTermCount: 1,
                    helperModelDownloaded: true
                )
            ),
            (
                "no terms",
                VocabularyBoostAttemptRouter.enginePreflight(
                    configuration: eligible,
                    selectedLanguage: "en",
                    hasTokenTimings: true,
                    transcriptIsEmpty: false,
                    eligibleTermCount: 0,
                    helperModelDownloaded: true
                )
            ),
            (
                "missing model",
                VocabularyBoostAttemptRouter.enginePreflight(
                    configuration: eligible,
                    selectedLanguage: "en",
                    hasTokenTimings: true,
                    transcriptIsEmpty: false,
                    eligibleTermCount: 1,
                    helperModelDownloaded: false
                )
            ),
        ]
        let expectedReasons: [VocabularyBoostAttemptSkipReason] = [
            .disabled,
            .lowLatencyMode,
            .unsupportedLanguage,
            .missingTokenTimings,
            .emptyTranscript,
            .noEligibleTerms,
            .modelUnavailable,
        ]

        for ((name, decision), reason) in zip(scenarios, expectedReasons) {
            XCTAssertEqual(decision, .skip(reason), name)
        }

        XCTAssertEqual(
            VocabularyBoostAttemptRouter.enginePreflight(
                configuration: eligible,
                selectedLanguage: "en",
                hasTokenTimings: true,
                transcriptIsEmpty: false,
                eligibleTermCount: 1,
                helperModelDownloaded: true
            ),
            .proceed(.explicitEnglish)
        )
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.enginePreflight(
                configuration: eligible,
                selectedLanguage: "auto",
                hasTokenTimings: true,
                transcriptIsEmpty: false,
                eligibleTermCount: 1,
                automaticLanguageDetection: VocabularyBoostLanguageDetection(
                    classification: .confidentlyEnglish,
                    confidence: 0.96
                ),
                helperModelDownloaded: true
            ),
            .proceed(.automaticConditional)
        )
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.enginePreflight(
                configuration: eligible,
                selectedLanguage: "auto",
                hasTokenTimings: true,
                transcriptIsEmpty: false,
                eligibleTermCount: 1,
                automaticLanguageDetection: VocabularyBoostLanguageDetection(
                    classification: .uncertain,
                    confidence: 0.61
                ),
                helperModelDownloaded: true
            ),
            .skip(.languageDetectionUncertain)
        )
    }

    @MainActor
    func testAutoConfidentEnglishEntersCTCAssetBoundaryExactlyOnce() async {
        let detectorCalls = VocabularyBoostInvocationCounter()
        let modelAvailabilityCalls = VocabularyBoostInvocationCounter()
        let assetCalls = VocabularyBoostInvocationCounter()
        let recorder = VocabularyBoostAttemptRecorder()
        let engine = ParakeetVocabularyBoostEngine(
            termsProvider: {
                [VocabularyBoostTerm(text: "Kubernetes", source: .manual)]
            },
            modelDownloadedProvider: {
                modelAvailabilityCalls.increment()
                return true
            },
            languageDetector: VocabularyBoostLanguageDetector { _ in
                detectorCalls.increment()
                return VocabularyBoostLanguageDetection(
                    classification: .confidentlyEnglish,
                    confidence: 0.97
                )
            },
            assetPreparationOverride: { _ in
                assetCalls.increment()
                return false
            },
            attemptRecorder: recorder
        )
        let firstPass = vocabularyBoostFirstPassResult(
            text: "Please deploy the Kubernetes service after the database migration finishes."
        )

        let output = await engine.rescoredResult(
            firstPass,
            audioSamples: [0],
            languageHint: nil,
            selectedLanguage: "auto"
        )

        XCTAssertEqual(output.result.text, firstPass.text)
        XCTAssertNil(output.audit)
        XCTAssertEqual(detectorCalls.value, 1)
        XCTAssertEqual(modelAvailabilityCalls.value, 1)
        XCTAssertEqual(assetCalls.value, 1)
        let counts = await recorder.snapshot()
        XCTAssertEqual(
            counts.count(for: .attempted(
                result: .processingFailure,
                language: .automaticConditional
            )),
            1
        )
    }

    @MainActor
    func testAutoGermanAndFrenchSkipBeforeAssetsWithManualAndContactTerms() async {
        let modelAvailabilityCalls = VocabularyBoostInvocationCounter()
        let assetCalls = VocabularyBoostInvocationCounter()
        let recorder = VocabularyBoostAttemptRecorder()
        let engine = ParakeetVocabularyBoostEngine(
            termsProvider: {
                [
                    VocabularyBoostTerm(text: "Kubernetes", source: .manual),
                    VocabularyBoostTerm(text: "Marguerite", source: .contact),
                ]
            },
            modelDownloadedProvider: {
                modelAvailabilityCalls.increment()
                return true
            },
            languageDetector: VocabularyBoostLanguageDetector { _ in
                VocabularyBoostLanguageDetection(
                    classification: .confidentlyNonEnglish,
                    confidence: 0.98
                )
            },
            assetPreparationOverride: { _ in
                assetCalls.increment()
                return true
            },
            attemptRecorder: recorder
        )
        let transcripts = [
            "Bitte veröffentliche den Bericht erst nach der letzten sorgfältigen Prüfung.",
            "Veuillez publier le rapport seulement après la dernière vérification complète.",
        ]

        for transcript in transcripts {
            let firstPass = vocabularyBoostFirstPassResult(text: transcript)
            let output = await engine.rescoredResult(
                firstPass,
                audioSamples: [0],
                languageHint: nil,
                selectedLanguage: "auto"
            )
            XCTAssertEqual(output.result.text, transcript)
            XCTAssertNil(output.audit)
        }

        XCTAssertEqual(modelAvailabilityCalls.value, 0)
        XCTAssertEqual(assetCalls.value, 0)
        let counts = await recorder.snapshot()
        XCTAssertEqual(counts.count(for: .skipped(.unsupportedLanguage)), 2)
    }

    @MainActor
    func testAutoUncertainSkipsBeforeAssetsWithManualAndContactTerms() async {
        let modelAvailabilityCalls = VocabularyBoostInvocationCounter()
        let assetCalls = VocabularyBoostInvocationCounter()
        let recorder = VocabularyBoostAttemptRecorder()
        let engine = ParakeetVocabularyBoostEngine(
            termsProvider: {
                [
                    VocabularyBoostTerm(text: "Kubernetes", source: .manual),
                    VocabularyBoostTerm(text: "Marguerite", source: .contact),
                ]
            },
            modelDownloadedProvider: {
                modelAvailabilityCalls.increment()
                return true
            },
            languageDetector: VocabularyBoostLanguageDetector { _ in
                VocabularyBoostLanguageDetection(
                    classification: .uncertain,
                    confidence: 0.52
                )
            },
            assetPreparationOverride: { _ in
                assetCalls.increment()
                return true
            },
            attemptRecorder: recorder
        )
        let firstPass = vocabularyBoostFirstPassResult(text: "Ja, okay, ship it tomorrow.")

        let output = await engine.rescoredResult(
            firstPass,
            audioSamples: [0],
            languageHint: nil,
            selectedLanguage: "auto"
        )

        XCTAssertEqual(output.result.text, firstPass.text)
        XCTAssertNil(output.audit)
        XCTAssertEqual(modelAvailabilityCalls.value, 0)
        XCTAssertEqual(assetCalls.value, 0)
        let counts = await recorder.snapshot()
        XCTAssertEqual(counts.count(for: .skipped(.languageDetectionUncertain)), 1)
    }

    @MainActor
    func testExplicitEnglishBypassesDetectorWhileExplicitNonEnglishSkips() async {
        let detectorCalls = VocabularyBoostInvocationCounter()
        let modelAvailabilityCalls = VocabularyBoostInvocationCounter()
        let assetCalls = VocabularyBoostInvocationCounter()
        let recorder = VocabularyBoostAttemptRecorder()
        let engine = ParakeetVocabularyBoostEngine(
            termsProvider: {
                [VocabularyBoostTerm(text: "Kubernetes", source: .manual)]
            },
            modelDownloadedProvider: {
                modelAvailabilityCalls.increment()
                return true
            },
            languageDetector: VocabularyBoostLanguageDetector { _ in
                detectorCalls.increment()
                return VocabularyBoostLanguageDetection(
                    classification: .uncertain,
                    confidence: 0
                )
            },
            assetPreparationOverride: { _ in
                assetCalls.increment()
                return false
            },
            attemptRecorder: recorder
        )
        let firstPass = vocabularyBoostFirstPassResult(
            text: "Please deploy the Kubernetes service after the database migration finishes."
        )

        _ = await engine.rescoredResult(
            firstPass,
            audioSamples: [0],
            languageHint: FluidAudioLanguageHint.map("en"),
            selectedLanguage: "en"
        )
        let nonEnglish = await engine.rescoredResult(
            firstPass,
            audioSamples: [0],
            languageHint: FluidAudioLanguageHint.map("de"),
            selectedLanguage: "de"
        )

        XCTAssertEqual(nonEnglish.result.text, firstPass.text)
        XCTAssertNil(nonEnglish.audit)
        XCTAssertEqual(detectorCalls.value, 0)
        XCTAssertEqual(modelAvailabilityCalls.value, 1)
        XCTAssertEqual(assetCalls.value, 1)
        let counts = await recorder.snapshot()
        XCTAssertEqual(
            counts.count(for: .attempted(
                result: .processingFailure,
                language: .explicitEnglish
            )),
            1
        )
        XCTAssertEqual(counts.count(for: .skipped(.unsupportedLanguage)), 1)
    }

    @MainActor
    func testAutoPrewarmCannotLoadAssetsBeforeTranscriptLanguageDecision() async {
        let modelAvailabilityCalls = VocabularyBoostInvocationCounter()
        let assetCalls = VocabularyBoostInvocationCounter()
        let engine = ParakeetVocabularyBoostEngine(
            termsProvider: {
                [VocabularyBoostTerm(text: "Kubernetes", source: .manual)]
            },
            modelDownloadedProvider: {
                modelAvailabilityCalls.increment()
                return true
            },
            assetPreparationOverride: { _ in
                assetCalls.increment()
                return true
            }
        )

        await engine.prewarm(selectedLanguage: "auto")
        XCTAssertEqual(modelAvailabilityCalls.value, 0)
        XCTAssertEqual(assetCalls.value, 0)

        await engine.prewarm(selectedLanguage: "en")
        XCTAssertEqual(modelAvailabilityCalls.value, 1)
        XCTAssertEqual(assetCalls.value, 1)
    }

    func testLocalLanguageDetectorTreatsShortInputAsUncertain() {
        let detection = VocabularyBoostLanguageDetector.localNaturalLanguage
            .detect("Please ship this.")

        XCTAssertEqual(detection.classification, .uncertain)
        XCTAssertEqual(detection.confidence, 0)
    }

    // MARK: - Screen-term replacement veto

    /// The reported field failure: dictating "design" inside the Devin app
    /// must not become "Devin" just because the name is on screen.
    func testScreenTermCannotOverwriteRealWordWithSystemLexicon() {
        XCTAssertTrue(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "design",
            replacement: "Devin",
            isRealWord: { FragmentedWordRepair.isRealWord($0, language: "en") }
        ))
    }

    func testScreenTermStillFixesNonWordMisrecognition() {
        XCTAssertFalse(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "dvin",
            replacement: "Devin",
            isRealWord: { FragmentedWordRepair.isRealWord($0, language: "en") }
        ))
    }

    /// The shipped field failure: "codec → Codex" in the learned dictionary
    /// made "Codex" a curated boost term, and the rescorer's 0.55 acoustic
    /// gate let it overwrite spoken "model" (similarity 0.60). A curated
    /// term earns its license from the spoken forms the user actually
    /// corrected, so a distant real word must keep the decode.
    func testAutoLearnedTermCannotOverwriteDistantRealWord() {
        XCTAssertTrue(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "model",
            replacement: "Codex",
            isRealWord: { FragmentedWordRepair.isRealWord($0, language: "en") }
        ))
    }

    /// Curated terms keep decode-level power over their orthographic
    /// near-neighbors — a casing/diacritic-level match is exactly the
    /// misrecognition shape the user taught the pair for.
    func testAutoLearnedTermMayReplaceNearNeighborRealWord() {
        XCTAssertFalse(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "granola",
            replacement: "Granola",
            isRealWord: { _ in true }
        ))
    }

    func testAutoLearnedThingToThijsIsVetoed() {
        XCTAssertTrue(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "thing",
            replacement: "Thijs",
            isRealWord: { _ in true }
        ))
    }

    func testAutoLearnedTermStillFixesNonWordMisrecognition() {
        XCTAssertFalse(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "kodeks",
            replacement: "Codex",
            isRealWord: { $0 != "kodeks" }
        ))
    }

    func testAutoLearnedNameStillFixesNonWordMisrecognition() {
        XCTAssertFalse(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "teez",
            replacement: "Thijs",
            isRealWord: { _ in false }
        ))
    }

    /// A manually curated term used to keep an unconditional privilege over
    /// single real words, which is exactly how "model" kept decoding as
    /// "Codex". Curation makes the term real; it does not make *this* span a
    /// misrecognition.
    func testManualSingleWordCannotOverwriteDistantRealWord() {
        XCTAssertTrue(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "model",
            replacement: "Codex",
            isRealWord: { _ in true }
        ))
    }

    func testManualTermCannotOverwriteDistantMultiWordRealSpan() {
        XCTAssertTrue(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "kind of hard",
            replacement: "Kind regards",
            isRealWord: { _ in true }
        ))
    }

    func testManualTermMayReplaceMultiWordNearNeighbor() {
        XCTAssertFalse(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "kind regards",
            replacement: "Kind regards",
            isRealWord: { _ in true }
        ))
    }

    func testManualTermStillFixesNonWord() {
        XCTAssertFalse(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "Kindergarts",
            replacement: "Kind regards",
            isRealWord: { _ in false }
        ))
    }

    /// Imported contacts held the last remaining exemption. An address book
    /// says the name exists, not that the user just said it.
    func testContactTermCannotOverwriteDistantRealSpan() {
        XCTAssertTrue(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "kind of hard",
            replacement: "Kind Regards",
            isRealWord: { _ in true }
        ))
    }

    /// A contact name still wins where the decode produced no real word — the
    /// case the boost exists for.
    func testContactTermStillFixesNonWordMisrecognition() {
        XCTAssertFalse(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "margeriet",
            replacement: "Marguerite",
            isRealWord: { _ in false }
        ))
    }

    // MARK: - Orthographic similarity

    func testOrthographicSimilarityMatchesKnownPairs() {
        XCTAssertEqual(
            ParakeetVocabularyBoostEngine.orthographicSimilarity("model", "Codex"),
            0.6, accuracy: 0.001
        )
        XCTAssertEqual(
            ParakeetVocabularyBoostEngine.orthographicSimilarity("design", "Devin"),
            2.0 / 3.0, accuracy: 0.001
        )
    }

    func testOrthographicSimilarityIgnoresCaseAndPunctuation() {
        XCTAssertEqual(
            ParakeetVocabularyBoostEngine.orthographicSimilarity("e-mail,", "EMAIL"),
            1.0, accuracy: 0.001
        )
    }

    func testVetoIsIndependentOfReplacementCasingAndWhitespace() {
        XCTAssertTrue(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "design",
            replacement: "  DEVIN ",
            isRealWord: { _ in true }
        ))
    }

    func testMultiWordSpanOfRealWordsIsVetoed() {
        XCTAssertTrue(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "the design",
            replacement: "Devin Desktop",
            isRealWord: { _ in true }
        ))
    }

    func testSpanContainingNonWordIsReplaceable() {
        XCTAssertFalse(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "the dvin",
            replacement: "Devin Desktop",
            isRealWord: { $0 != "dvin" }
        ))
    }

    func testTrailingPunctuationDoesNotHideARealWord() {
        var checked: [String] = []
        XCTAssertTrue(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "design,",
            replacement: "Devin",
            isRealWord: { checked.append($0); return true }
        ))
        XCTAssertEqual(checked, ["design"])
    }

    func testNilReplacementIsNeverVetoed() {
        XCTAssertFalse(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "design",
            replacement: nil,
            isRealWord: { _ in true }
        ))
    }

    /// The language gate is conservative but the later spell-check veto stays
    /// independently locale-aware for code-switching and proper names.
    func testAutoLanguageResolvesNonEnglishRealWord() throws {
        let available = NSSpellChecker.shared.availableLanguages
        try XCTSkipUnless(
            available.contains { $0.hasPrefix("de") } && available.contains { $0.hasPrefix("en") },
            "requires German + English system dictionaries"
        )
        // "Entwurf" (German for draft/design) is not an English word, so the
        // forced-"en" path would misclassify it as a non-word.
        XCTAssertFalse(FragmentedWordRepair.isRealWord("Entwurf", language: "en"))
        XCTAssertTrue(FragmentedWordRepair.isRealWord("Entwurf", language: nil))
        XCTAssertTrue(ParakeetVocabularyBoostEngine.replacementVetoed(
            original: "Entwurf",
            replacement: "Devin",
            isRealWord: { FragmentedWordRepair.isRealWord($0, language: nil) }
        ))
    }
}

private func vocabularyBoostFirstPassResult(text: String) -> ASRResult {
    ASRResult(
        text: text,
        confidence: 0.9,
        duration: 1,
        processingTime: 0.1,
        tokenTimings: [
            TokenTiming(
                token: "token",
                tokenId: 1,
                startTime: 0,
                endTime: 0.5,
                confidence: 0.9
            ),
        ]
    )
}

private final class VocabularyBoostInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
