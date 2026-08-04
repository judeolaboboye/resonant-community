import XCTest
@testable import Resonant

@MainActor
final class PersonalizationConsumerStateTests: XCTestCase {
    func testEntityEvidenceEligibilityRemainsDistinctFromRuntimeAvailability() async throws {
        let store = PersonalizationMemoryStore()
        let surface = Self.surface(appName: "Slack", bundleID: "com.example.slack")
        let context = Self.context(for: surface)

        await Self.recordCustomTerm(in: store, context: context)
        var controls = await store.controlsSnapshot()
        var entity = try XCTUnwrap(controls.entities.first { $0.value == "Resonantia" })
        XCTAssertEqual(entity.eligibility, .learning)
        XCTAssertEqual(entity.recognizerAvailability, .notEligible)
        XCTAssertFalse(store.snapshot(for: surface).biasTerms.contains("Resonantia"))
        XCTAssertFalse(store.recognitionBiasTerms().contains("Resonantia"))

        await Self.recordCustomTerm(in: store, context: context)
        controls = await store.controlsSnapshot()
        entity = try XCTUnwrap(controls.entities.first { $0.value == "Resonantia" })
        XCTAssertEqual(entity.eligibility, .promptEligible)
        XCTAssertEqual(entity.recognizerAvailability, .notEligible)
        XCTAssertTrue(store.snapshot(for: surface).biasTerms.contains("Resonantia"))
        XCTAssertFalse(store.recognitionBiasTerms().contains("Resonantia"))

        await Self.recordCustomTerm(in: store, context: context)
        controls = await store.controlsSnapshot()
        entity = try XCTUnwrap(controls.entities.first { $0.value == "Resonantia" })
        XCTAssertEqual(entity.eligibility, .recognitionEligible)
        XCTAssertEqual(entity.recognizerAvailability, .runtimeUnavailable)
        XCTAssertTrue(store.snapshot(for: surface).biasTerms.contains("Resonantia"))
        XCTAssertTrue(store.recognitionBiasTerms().contains("Resonantia"))
        XCTAssertEqual(controls.entityConsumers.recognitionEligible, 1)
        XCTAssertEqual(controls.entityConsumers.recognizerAvailability, .runtimeUnavailable)
        XCTAssertEqual(controls.entityConsumers.learningCandidates, 0)

        await store.setEntitySuppressed(id: entity.id, isSuppressed: true)
        controls = await store.controlsSnapshot()
        entity = try XCTUnwrap(controls.entities.first { $0.id == entity.id })
        XCTAssertEqual(entity.eligibility, .suppressed)
        XCTAssertEqual(entity.recognizerAvailability, .notEligible)
        XCTAssertEqual(controls.entityConsumers.suppressed, 1)
        XCTAssertFalse(store.snapshot(for: surface).biasTerms.contains("Resonantia"))
        XCTAssertFalse(store.recognitionBiasTerms().contains("Resonantia"))
    }

    func testSameRecognitionEligibleRowTracksEveryLiveVocabularyGateAndTotals() async throws {
        let store = PersonalizationMemoryStore()
        let surface = Self.surface(appName: "Slack", bundleID: "com.example.slack")
        let context = Self.context(for: surface)
        for _ in 0..<3 {
            await Self.recordCustomTerm(in: store, context: context)
        }

        let source = RuntimeContextSource(Self.runtimeContext())
        store.attachConsumerRuntimeContextProvider { source.read() }

        let cases: [(String, PersonalizationConsumerRuntimeContext, PersonalizationRecognizerAvailability)] = [
            (
                "feature off",
                Self.runtimeContext(enabled: false),
                .featureOff
            ),
            (
                "unsupported adapter",
                Self.runtimeContext(liveAdapterSupportsBoosting: false),
                .unsupportedAdapter
            ),
            (
                "explicit non-English",
                Self.runtimeContext(selectedLanguage: "de"),
                .unsupportedLanguage
            ),
            (
                "low latency",
                Self.runtimeContext(lowLatencyMode: true),
                .lowLatencyPaused
            ),
            (
                "no eligible terms",
                Self.runtimeContext(eligibleTermCount: 0),
                .noEligibleTerms
            ),
            (
                "helper absent",
                Self.runtimeContext(helper: .absent),
                .helperAbsent
            ),
            (
                "helper downloading",
                Self.runtimeContext(helper: .downloading),
                .helperDownloading
            ),
            (
                "helper failed",
                Self.runtimeContext(helper: .failed(.network)),
                .helperFailed(.network)
            ),
            (
                "explicit English ready",
                Self.runtimeContext(),
                .available
            ),
            (
                "Auto ready remains conditional",
                Self.runtimeContext(selectedLanguage: "auto"),
                .automaticLanguageConditional
            ),
        ]

        for (label, runtime, expected) in cases {
            source.value = runtime
            let controls = await store.controlsSnapshot()
            let entity = try XCTUnwrap(
                controls.entities.first { $0.value == "Resonantia" },
                label
            )
            XCTAssertEqual(entity.eligibility, .recognitionEligible, label)
            XCTAssertEqual(entity.recognizerAvailability, expected, label)
            XCTAssertEqual(controls.runtimeContext, runtime, label)
            XCTAssertEqual(controls.entityConsumers.recognitionEligible, 1, label)
            XCTAssertEqual(
                controls.entityConsumers.recognizerAvailability,
                expected,
                "row and summary must share one global recognizer resolution: \(label)"
            )
        }

        XCTAssertEqual(source.readCount, cases.count)
    }

    func testEntityScopeMismatchUsesSamePromptEligibilityPredicate() async {
        let store = PersonalizationMemoryStore()
        let slack = Self.surface(appName: "Slack", bundleID: "com.example.slack")
        let mail = Self.surface(appName: "Mail", bundleID: "com.example.mail")
        let context = Self.context(for: slack)

        await store.recordCorrection(
            spoken: "jon smith",
            written: "John Smith",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )

        let controls = await store.controlsSnapshot()
        XCTAssertEqual(controls.entities.first?.eligibility, .promptEligible)
        XCTAssertTrue(store.snapshot(for: slack).biasTerms.contains("John Smith"))
        XCTAssertFalse(store.snapshot(for: mail).biasTerms.contains("John Smith"))
    }

    func testFormatDashboardStateTracksFormatterEligibilityPredicate() async throws {
        let store = PersonalizationMemoryStore()
        let surface = Self.surface(appName: "Slack", bundleID: "com.example.slack")
        let context = Self.context(for: surface)

        store.recordFormatCorrections(
            pasted: "the resonant team",
            edited: "the Resonant team",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        var controls = await store.controlsSnapshot()
        var preference = try XCTUnwrap(controls.formatPreferences.first)
        XCTAssertEqual(preference.eligibility, .learning)
        XCTAssertNil(store.preferredWordCasing(for: "resonant"))

        store.recordFormatCorrections(
            pasted: "our resonant work",
            edited: "our Resonant work",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        controls = await store.controlsSnapshot()
        preference = try XCTUnwrap(controls.formatPreferences.first)
        XCTAssertEqual(preference.eligibility, .formatterEligible)
        XCTAssertEqual(controls.formatConsumers.formatterEligible, 1)
        XCTAssertEqual(store.preferredWordCasing(for: "resonant"), "Resonant")

        await store.setFormatPreferenceSuppressed(id: preference.id, isSuppressed: true)
        controls = await store.controlsSnapshot()
        preference = try XCTUnwrap(controls.formatPreferences.first)
        XCTAssertEqual(preference.eligibility, .suppressed)
        XCTAssertEqual(controls.formatConsumers.suppressed, 1)
        XCTAssertNil(store.preferredWordCasing(for: "resonant"))
    }

    func testCloudEligibleStyleRowTracksCleanupAvailabilityWithoutClaimingUse() async throws {
        let store = PersonalizationMemoryStore()
        let chat = Self.surface(appName: "Slack", bundleID: "com.example.slack")
        let chatContext = Self.context(for: chat)

        for text in ["sounds good", "works for me", "ship it tomorrow"] {
            await store.recordAutoSentDelivery(RawTranscriptHabitFeedbackRequest(
                rawTranscript: text,
                context: chatContext,
                capabilities: .rawTranscriptHabits
            ))
        }

        let cases: [(PersonalizationCloudCleanupAvailability, Bool)] = [
            (.disabled, false),
            (.signedOut, false),
            (.lowLatencyPaused, false),
            (.eligible, true),
            (.polishVerbatim, false),
        ]

        for (cloud, isAvailable) in cases {
            let runtime = Self.runtimeContext(cloudAvailability: cloud)
            store.attachConsumerRuntimeContextProvider { runtime }
            let controls = await store.controlsSnapshot()
            let style = try XCTUnwrap(controls.styles.first)
            XCTAssertTrue(style.consumerState.isCloudStyleEligible)
            XCTAssertEqual(style.consumerState.cloudAvailability, cloud)
            XCTAssertEqual(style.consumerState.isCloudStyleAvailable, isAvailable)
            XCTAssertEqual(controls.styleConsumers.cloudStyleEligible, 1)
            XCTAssertEqual(controls.styleConsumers.cloudStyleAvailable, isAvailable ? 1 : 0)
            XCTAssertEqual(controls.styleConsumers.cloudStyleUnavailable, isAvailable ? 0 : 1)
        }
    }

    /// Binds the Settings mirror to the real pipeline. Asserting `resolve`
    /// against its own hand-written table proved nothing: the mirror had
    /// drifted to four of the pipeline's gates while still claiming parity.
    /// Every non-eligible verdict here must correspond to a pipeline run that
    /// stayed local, and `.eligible` must correspond to one that did not.
    @MainActor
    func testCloudAvailabilityAgreesWithTheRealCleanupPipeline() async {
        // Long enough to clear the short-dictation bypass, so the only thing
        // varying between cases is the gate under test.
        let transcript = """
        The launch plan has three parts. First we need to finish the creator brief and make sure \
        the talking points are accurate. Second we need to confirm the production timeline so \
        everyone knows when drafts are due. Third we need to package the reporting plan so the \
        team can see what is working and what still needs another pass before we ship it.
        """
        let verbatim = DictationPolishSettings(chat: .verbatim, email: .verbatim, other: .verbatim)

        let cases: [(
            name: String,
            cloudProcessingEnabled: Bool,
            lowLatencyMode: Bool,
            isLoggedIn: Bool,
            polish: DictationPolishSettings,
            expected: PersonalizationCloudCleanupAvailability
        )] = [
            ("all open", true, false, true, .standard, .eligible),
            ("cloud off", false, false, true, .standard, .disabled),
            ("signed out", true, false, false, .standard, .signedOut),
            ("instant on", true, true, true, .standard, .lowLatencyPaused),
            ("verbatim everywhere", true, false, true, verbatim, .polishVerbatim),
        ]

        for testCase in cases {
            let resolved = PersonalizationCloudCleanupAvailability.resolve(
                cloudProcessingEnabled: testCase.cloudProcessingEnabled,
                lowLatencyMode: testCase.lowLatencyMode,
                isLoggedIn: testCase.isLoggedIn,
                polishSettings: testCase.polish
            )
            XCTAssertEqual(resolved, testCase.expected, "mirror verdict for \(testCase.name)")

            var pipeline = DictationCleanupPipeline(
                convexClient: ConvexClient(authManager: AuthManager()),
                cloudProcessingEnabled: testCase.cloudProcessingEnabled,
                lowLatencyMode: testCase.lowLatencyMode,
                isLoggedIn: testCase.isLoggedIn,
                fallbackSenderName: nil,
                recentTexts: []
            )
            pipeline.polishSettings = testCase.polish
            pipeline.cleanupResultProvider = {
                ConvexClient.DictationCleanupResult(
                    text: transcript,
                    trace: DictationQualityTrace.Cleanup(
                        status: .accepted,
                        profile: "default",
                        listIntent: "none",
                        attempted: true,
                        accepted: true,
                        path: "test-primary",
                        fallbackReason: nil,
                        sanitizerRejectReason: nil,
                        clientDurationMs: 1,
                        serverDurationMs: 1
                    )
                )
            }

            let outcome = await pipeline.resolve(
                transcript: transcript,
                result: Self.cleanupTranscriptionResult(text: transcript),
                emailMode: .nonEmail
            )

            XCTAssertEqual(
                outcome.cleanup.attempted,
                testCase.expected == .eligible,
                "mirror says \(testCase.expected) but the pipeline attempted="
                    + "\(outcome.cleanup.attempted) for \(testCase.name)"
            )
        }
    }

    func testListAndPeriodPoliciesRespectGlobalGatesInRowsAndTotals() async throws {
        let store = PersonalizationMemoryStore()
        let chat = Self.surface(appName: "Slack", bundleID: "com.example.slack")
        let context = Self.context(for: chat)

        for index in 0..<3 {
            await store.recordStyleTransition(StyleTransitionFeedbackRequest(
                pastedText: "Status \(index)",
                editedText: "Status \(index).",
                context: context,
                capabilities: .correctionDerivedMutations
            ))
            await store.recordStyleTransition(StyleTransitionFeedbackRequest(
                pastedText: "first \(index)\nsecond \(index)",
                editedText: "- first \(index)\n- second \(index)",
                context: context,
                capabilities: .correctionDerivedMutations
            ))
        }
        XCTAssertEqual(store.stylePolicy(for: chat).trailingPeriod, .require)
        XCTAssertEqual(store.stylePolicy(for: chat).listMarkers, .require)

        let gated = Self.runtimeContext(
            cloudAvailability: .disabled,
            autoPunctuationEnabled: false,
            bulletPointsEnabled: false
        )
        store.attachConsumerRuntimeContextProvider { gated }
        var controls = await store.controlsSnapshot()
        var style = try XCTUnwrap(controls.styles.first)
        XCTAssertEqual(style.consumerState.localPolicyEligibleFamilyCount, 2)
        XCTAssertEqual(style.consumerState.localPolicyAvailableFamilyCount, 0)
        XCTAssertEqual(style.consumerState.localPolicyVetoedFamilyCount, 2)
        XCTAssertFalse(style.consumerState.isLocalPolicyAvailable)
        XCTAssertEqual(controls.styleConsumers.localPolicyEligible, 1)
        XCTAssertEqual(controls.styleConsumers.localPolicyAvailable, 0)
        XCTAssertEqual(controls.styleConsumers.localPolicyVetoedFamilies, 2)
        XCTAssertEqual(controls.styleConsumers.availableWritingHabits, 0)

        let ready = Self.runtimeContext(
            cloudAvailability: .disabled,
            autoPunctuationEnabled: true,
            bulletPointsEnabled: true
        )
        store.attachConsumerRuntimeContextProvider { ready }
        controls = await store.controlsSnapshot()
        style = try XCTUnwrap(controls.styles.first)
        XCTAssertEqual(style.consumerState.localPolicyEligibleFamilyCount, 2)
        XCTAssertEqual(style.consumerState.localPolicyAvailableFamilyCount, 2)
        XCTAssertEqual(style.consumerState.localPolicyVetoedFamilyCount, 0)
        XCTAssertTrue(style.consumerState.isLocalPolicyAvailable)
        XCTAssertEqual(controls.styleConsumers.localPolicyEligible, 1)
        XCTAssertEqual(controls.styleConsumers.localPolicyAvailable, 1)
        XCTAssertEqual(controls.styleConsumers.localPolicyVetoedFamilies, 0)
        XCTAssertEqual(controls.styleConsumers.availableWritingHabits, 1)
    }

    private static func recordCustomTerm(
        in store: PersonalizationMemoryStore,
        context: CorrectionObservationContext
    ) async {
        await store.recordCorrection(
            spoken: "reson an tia",
            written: "Resonantia",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )
    }

    private static func runtimeContext(
        enabled: Bool = true,
        liveAdapterSupportsBoosting: Bool = true,
        lowLatencyMode: Bool = false,
        selectedLanguage: String = "en",
        eligibleTermCount: Int = 1,
        helper: VocabularyBoostHelperDownloadState = .ready,
        cloudAvailability: PersonalizationCloudCleanupAvailability = .eligible,
        autoPunctuationEnabled: Bool = true,
        bulletPointsEnabled: Bool = true
    ) -> PersonalizationConsumerRuntimeContext {
        PersonalizationConsumerRuntimeContext(
            vocabularyBoost: VocabularyBoostRuntimeState.resolve(
                enabled: enabled,
                liveAdapterSupportsBoosting: liveAdapterSupportsBoosting,
                lowLatencyMode: lowLatencyMode,
                selectedLanguage: selectedLanguage,
                eligibleTermCount: eligibleTermCount,
                helperDownloadState: helper
            ),
            cloudCleanup: cloudAvailability,
            formatterGates: PersonalizationFormatterRuntimeGates(
                autoPunctuationEnabled: autoPunctuationEnabled,
                bulletPointsEnabled: bulletPointsEnabled
            )
        )
    }

    private static func surface(appName: String, bundleID: String) -> SurfaceDescriptor {
        SurfaceClassifier.classify(
            appName: appName,
            bundleId: bundleID,
            windowTitle: "general",
            browserURL: nil
        )
    }

    private static func context(for surface: SurfaceDescriptor) -> CorrectionObservationContext {
        CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )
    }

    /// A plain non-email note surface, so the cleanup pipeline's email and
    /// profile branches stay out of the gate comparison.
    private static func cleanupTranscriptionResult(text: String) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            rawTranscript: text,
            duration: 12,
            captureDiagnostics: nil,
            recordingURL: nil,
            selectedText: nil,
            selectedRange: nil,
            targetApp: "Notes",
            targetBundleId: "com.apple.Notes",
            windowTitle: "Project update",
            browserURL: nil,
            codeFileName: nil,
            slackRecipient: nil,
            focusedFieldContent: nil,
            visibleTextSnippets: nil,
            contextPacket: nil
        )
    }
}

@MainActor
private final class RuntimeContextSource {
    var value: PersonalizationConsumerRuntimeContext
    private(set) var readCount = 0

    init(_ value: PersonalizationConsumerRuntimeContext) {
        self.value = value
    }

    func read() -> PersonalizationConsumerRuntimeContext {
        readCount += 1
        return value
    }
}
