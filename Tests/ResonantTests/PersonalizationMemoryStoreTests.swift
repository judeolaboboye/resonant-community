import XCTest
@testable import Resonant

@MainActor
final class PersonalizationMemoryStoreTests: XCTestCase {
    func testFeedbackEventTracksEditsIndependentlyOfSafeCorrectionPairs() {
        let event = DictationFeedbackEvent(
            pastedText: "Ship this.",
            editedText: "Ship this!",
            rawTranscript: nil,
            corrections: [],
            context: CorrectionObservationContext(
                appName: nil,
                bundleId: nil,
                windowTitle: nil,
                browserURL: nil,
                contextPacket: nil
            ),
            capabilities: .correctionDerivedMutations
        )

        XCTAssertTrue(event.wasEdited)
        XCTAssertTrue(event.hadCorrection)
    }

    func testFeedbackWithoutCorrectionCapabilityCannotMutateStore() async {
        let store = PersonalizationMemoryStore()
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Alex - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await store.recordFeedback(DictationFeedbackEvent(
            pastedText: "ask jon smythe",
            editedText: "ask John Smythe",
            rawTranscript: "ask jon smythe",
            corrections: [
                StoredCorrectionPair(
                    spoken: "jon smythe",
                    written: "John Smythe",
                    spokenIsRealWord: false
                )
            ],
            context: context,
            capabilities: .none
        ))

        XCTAssertEqual(store.snapshot(for: surface), .empty)
        XCTAssertTrue(store.recognitionBiasTerms().isEmpty)
        let controls = await store.controlsSnapshot()
        XCTAssertTrue(controls.entities.isEmpty)
    }

    func testFeedbackCompatibilityInitializerFailsClosed() {
        let event = DictationFeedbackEvent(
            pastedText: "before",
            editedText: "after",
            rawTranscript: nil,
            corrections: [],
            context: CorrectionObservationContext(
                appName: nil,
                bundleId: nil,
                windowTitle: nil,
                browserURL: nil,
                contextPacket: nil
            )
        )

        XCTAssertEqual(event.capabilities, .none)
    }

    func testDirectMutationEntryPointsFailClosedWithoutMatchingCapabilities() async {
        let store = PersonalizationMemoryStore()
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "general - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await store.recordCorrection(
            spoken: "jon smythe",
            written: "John Smythe",
            spokenIsRealWord: false,
            context: context
        )
        await store.recordFormattingEditSignals(
            pastedText: "Sounds good.",
            editedText: "Sounds good",
            context: context
        )
        store.recordFormatCorrections(
            pasted: "the resonant team",
            edited: "the Resonant team",
            context: context
        )
        await store.recordStyleTransition(StyleTransitionFeedbackRequest(
            pastedText: "Sounds good",
            editedText: "sounds good",
            context: context,
            capabilities: .none
        ))
        await store.recordAutoSentDelivery(RawTranscriptHabitFeedbackRequest(
            rawTranscript: "sounds good",
            context: context,
            capabilities: .correctionDerivedMutations
        ))

        XCTAssertEqual(store.snapshot(for: surface), .empty)
        XCTAssertEqual(store.stylePolicy(for: surface), .inherit)
        XCTAssertNil(store.preferredWordCasing(for: "resonant"))
        let controls = await store.controlsSnapshot()
        XCTAssertTrue(controls.formatPreferences.isEmpty)
    }

    func testLearningEngineInterfaceRecordsFeedbackAndDashboardSnapshot() async {
        let store = PersonalizationMemoryStore()
        let learningEngine: PersonalizationLearningEngine = store
        let dashboardDataSource: PersonalizationDashboardDataSource = store
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Alex - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await learningEngine.recordFeedback(DictationFeedbackEvent(
            pastedText: "ask jon smythe",
            editedText: "ask John Smythe",
            rawTranscript: "ask jon smythe",
            corrections: [
                StoredCorrectionPair(
                    spoken: "jon smythe",
                    written: "John Smythe",
                    spokenIsRealWord: false
                )
            ],
            context: context,
            capabilities: .correctionDerivedMutations
        ))

        let snapshot = learningEngine.snapshot(for: surface)
        let dashboard = await dashboardDataSource.dashboardSnapshot()

        XCTAssertTrue(snapshot.biasTerms.contains("John Smythe"))
        XCTAssertEqual(dashboard.entityConsumers.eligible, 1)
        XCTAssertTrue(dashboard.topEntities.contains { $0.value == "John Smythe" })
    }

    func testControlInterfacePinsAndSuppressesLearnedEntity() async throws {
        let store = PersonalizationMemoryStore()
        let learningEngine: PersonalizationLearningEngine = store
        let controlDataSource: PersonalizationControlDataSource = store
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Alex - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await learningEngine.recordFeedback(DictationFeedbackEvent(
            pastedText: "ask jon smythe",
            editedText: "ask John Smythe",
            rawTranscript: nil,
            corrections: [
                StoredCorrectionPair(
                    spoken: "jon smythe",
                    written: "John Smythe",
                    spokenIsRealWord: false
                )
            ],
            context: context,
            capabilities: .correctionDerivedMutations
        ))

        let initial = await controlDataSource.controlsSnapshot()
        let entityID = try XCTUnwrap(initial.entities.first?.id)

        await controlDataSource.setEntityPinned(id: entityID, isPinned: true)
        let pinned = await controlDataSource.controlsSnapshot()
        XCTAssertTrue(pinned.entities.first { $0.id == entityID }?.isUserPinned == true)
        XCTAssertFalse(pinned.entities.first { $0.id == entityID }?.isSuppressed == true)

        await controlDataSource.setEntitySuppressed(id: entityID, isSuppressed: true)
        let suppressed = await controlDataSource.controlsSnapshot()
        XCTAssertTrue(suppressed.entities.first { $0.id == entityID }?.isSuppressed == true)
        XCTAssertFalse(suppressed.entities.first { $0.id == entityID }?.isUserPinned == true)
    }

    func testEvaluationEngineScoresRecentCorrectionEvents() {
        let events = [
            PersonalizationEvaluationInput(
                id: UUID(),
                timestamp: Date(),
                appName: "Slack",
                surfaceKind: "chat",
                pastedText: "ask jon smythe",
                editedText: "ask John Smythe",
                corrections: [
                    StoredCorrectionPair(
                        spoken: "jon smythe",
                        written: "John Smythe",
                        spokenIsRealWord: false
                    )
                ],
                hadCorrection: true
            ),
            PersonalizationEvaluationInput(
                id: UUID(),
                timestamp: Date(),
                appName: "Slack",
                surfaceKind: "chat",
                pastedText: "sounds good",
                editedText: "sounds good",
                corrections: [],
                hadCorrection: false
            ),
        ]

        let snapshot = PersonalizationEvaluationEngine.evaluate(
            events,
            outcomes: .unavailable
        )

        XCTAssertEqual(snapshot.correctionLogEventCount, 2)
        XCTAssertEqual(snapshot.editedCorrectionLogEventCount, 1)
        XCTAssertEqual(snapshot.outcomes, .unavailable)
        XCTAssertEqual(snapshot.topCorrections.first?.written, "John Smythe")
        XCTAssertGreaterThan(snapshot.averageNormalizedEditDistance, 0)
    }

    func testCorrectionCreatesScopedBiasEntity() async {
        let store = PersonalizationMemoryStore()
        let surface = SurfaceClassifier.classify(
            appName: "Chrome",
            bundleId: "com.google.chrome",
            windowTitle: "Follow up with Sarah Chen - Gmail",
            browserURL: "https://mail.google.com/mail/u/0/#inbox"
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await store.recordCorrection(
            spoken: "sarah shin",
            written: "Sarah Chen",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )

        let snapshot = store.snapshot(for: surface)

        XCTAssertTrue(snapshot.biasTerms.contains("Sarah Chen"))
        XCTAssertTrue(snapshot.entities.contains {
            $0.type == .personName
                && $0.value == "Sarah Chen"
                && $0.source == .correctionMemory
        })
    }

    func testReversedCorrectionSuppressesLearnedEntity() async {
        let store = PersonalizationMemoryStore()
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Alex - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await store.recordCorrection(
            spoken: "sarah shin",
            written: "Sarah Chen",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )
        await store.recordCorrection(
            spoken: "Sarah Chen",
            written: "sarah shin",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )

        let snapshot = store.snapshot(for: surface)

        XCTAssertFalse(snapshot.biasTerms.contains("Sarah Chen"))
    }

    func testChangedLearnedEntityDemotesPreviousOutput() async {
        let store = PersonalizationMemoryStore()
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Alex - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await store.recordCorrection(
            spoken: "sarah shin",
            written: "Sarah Chen",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )
        await store.recordCorrection(
            spoken: "Sarah Chen",
            written: "Sarah Cheung",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )

        let snapshot = store.snapshot(for: surface)

        XCTAssertFalse(snapshot.biasTerms.contains("Sarah Chen"))
        XCTAssertTrue(snapshot.biasTerms.contains("Sarah Cheung"))
    }

    func testCorrectionPreservesSocialHandleAndChannelPrefixes() async {
        let store = PersonalizationMemoryStore()
        let surface = SurfaceClassifier.classify(
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Post from @alex_dev / X",
            browserURL: "https://x.com/alex_dev/status/123"
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await store.recordCorrection(
            spoken: "at alex dev",
            written: "@alex_dev",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )
        await store.recordCorrection(
            spoken: "general",
            written: "#general",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )

        let snapshot = store.snapshot(for: surface)

        XCTAssertTrue(snapshot.entities.contains { $0.type == .personHandle && $0.value == "@alex_dev" })
        XCTAssertTrue(snapshot.entities.contains { $0.type == .chatChannel && $0.value == "#general" })
    }

    func testWebMemoryScopesBySiteInsteadOfBrowserApp() async {
        let store = PersonalizationMemoryStore()
        let chromeGmail = SurfaceClassifier.classify(
            appName: "Chrome",
            bundleId: "com.google.chrome",
            windowTitle: "Follow up with Sarah Chen - Gmail",
            browserURL: "https://mail.google.com/mail/u/0/#inbox"
        )
        let context = CorrectionObservationContext(
            appName: chromeGmail.appName,
            bundleId: chromeGmail.bundleId,
            windowTitle: chromeGmail.windowTitle,
            browserURL: chromeGmail.browserURL,
            contextPacket: nil
        )

        await store.recordCorrection(
            spoken: "sarah shin",
            written: "Sarah Chen",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )

        let safariGmail = SurfaceClassifier.classify(
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Follow up with Sarah Chen - Gmail",
            browserURL: "https://mail.google.com/mail/u/0/#inbox"
        )
        let unrelatedSite = SurfaceClassifier.classify(
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "X",
            browserURL: "https://x.com/home"
        )

        XCTAssertTrue(store.snapshot(for: safariGmail).biasTerms.contains("Sarah Chen"))
        XCTAssertFalse(store.snapshot(for: unrelatedSite).biasTerms.contains("Sarah Chen"))
    }

    func testDesktopMemoryRequiresMatchingAppScope() async {
        let store = PersonalizationMemoryStore()
        let slack = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Alex - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: slack.appName,
            bundleId: slack.bundleId,
            windowTitle: slack.windowTitle,
            browserURL: slack.browserURL,
            contextPacket: nil
        )

        await store.recordCorrection(
            spoken: "sarah shin",
            written: "Sarah Chen",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )

        let unknownSurface = SurfaceClassifier.classify(
            appName: "Unknown",
            bundleId: nil,
            windowTitle: "Untitled",
            browserURL: nil
        )

        XCTAssertFalse(store.snapshot(for: unknownSurface).biasTerms.contains("Sarah Chen"))
    }

    func testChatStyleUsesDirectTransitionsAndRawTranscriptHabits() async {
        let store = PersonalizationMemoryStore()
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "general - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        for text in ["Sounds good", "Works for me", "Let's do it tomorrow"] {
            await store.recordStyleTransition(StyleTransitionFeedbackRequest(
                pastedText: text,
                editedText: text.prefix(1).lowercased() + String(text.dropFirst()),
                context: context,
                capabilities: .correctionDerivedMutations
            ))
        }
        for text in ["sounds good", "works for me", "let's do it tomorrow"] {
            await store.recordAutoSentDelivery(RawTranscriptHabitFeedbackRequest(
                rawTranscript: text,
                context: context,
                capabilities: .rawTranscriptHabits
            ))
        }

        let snapshot = store.snapshot(for: surface)

        XCTAssertTrue(snapshot.styleHint?.contains("lowercase") == true)
        XCTAssertTrue(snapshot.styleHint?.contains("concise") == true)
    }

    func testVersionedProfileHoldoutKeepsAvailableMemoryButSelectsNoCandidates() async {
        let store = PersonalizationMemoryStore(profileAssignmentSeed: "unit-test-profile")
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "general - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await store.recordCorrection(
            spoken: "sarah shin",
            written: "Sarah Chen",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )
        for text in ["Sounds good", "Works for me", "Let's do it tomorrow"] {
            await store.recordStyleTransition(StyleTransitionFeedbackRequest(
                pastedText: text,
                editedText: text.prefix(1).lowercased() + String(text.dropFirst()),
                context: context,
                capabilities: .correctionDerivedMutations
            ))
        }

        let profile = PersonalizationProfileBuilder.build(
            surface: surface,
            snapshot: store.snapshot(for: surface),
            styleSampleCount: 3,
            seed: "unit-test-profile",
            holdoutRate: 100
        )

        XCTAssertEqual(profile.metadata.variant, .holdout)
        XCTAssertFalse(profile.metadata.isSelectedForPacket)
        XCTAssertGreaterThan(profile.metadata.availableEntityCount, 0)
        XCTAssertEqual(profile.metadata.selectedEntityCount, 0)
        XCTAssertTrue(profile.metadata.styleHintAvailable)
        XCTAssertFalse(profile.metadata.styleHintSelected)
        XCTAssertTrue(profile.availableSnapshot.biasTerms.contains("Sarah Chen"))
    }

    func testVersionedProfilePersonalizedVariantSelectsCandidates() async {
        let store = PersonalizationMemoryStore(profileAssignmentSeed: "unit-test-profile")
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "general - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await store.recordCorrection(
            spoken: "sarah shin",
            written: "Sarah Chen",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )

        let profile = PersonalizationProfileBuilder.build(
            surface: surface,
            snapshot: store.snapshot(for: surface),
            styleSampleCount: 0,
            seed: "unit-test-profile",
            holdoutRate: 0
        )

        XCTAssertEqual(profile.metadata.variant, .personalized)
        XCTAssertTrue(profile.metadata.isSelectedForPacket)
        XCTAssertEqual(profile.metadata.availableEntityCount, profile.metadata.selectedEntityCount)
    }

    func testContextPacketAttachesProfileMetadataAndHonorsHoldout() async {
        let store = PersonalizationMemoryStore(profileAssignmentSeed: "unit-test-profile")
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "general - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        await store.recordCorrection(
            spoken: "sarah shin",
            written: "Sarah Chen",
            spokenIsRealWord: false,
            context: context,
            capabilities: .correctionDerivedMutations
        )

        let profile = PersonalizationProfileBuilder.build(
            surface: surface,
            snapshot: store.snapshot(for: surface),
            styleSampleCount: 0,
            seed: "unit-test-profile",
            holdoutRate: 100
        )
        let packet = ContextPacketBuilder.build(
            transcript: "ask sarah",
            hot: ContextExtractor.HotContext(
                appName: "Slack",
                bundleId: "com.tinyspeck.slackmacgap",
                windowTitle: "general - Slack"
            ),
            personalizationProfile: profile
        )

        XCTAssertEqual(packet.personalizationProfile?.variant, .holdout)
        XCTAssertFalse(packet.entities.contains {
            $0.source == .correctionMemory && $0.value == "Sarah Chen"
        })
    }

    func testRepeatedListStrippingLearnsSuppressAutoLists() async {
        let store = PersonalizationMemoryStore()
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Alex - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        XCTAssertEqual(store.formattingPreferences(for: surface), .neutral)

        for _ in 0..<3 {
            await store.recordFormattingEditSignals(
                pastedText: "- Milk\n- Eggs\n- Bread",
                editedText: "Milk, eggs, bread",
                context: context,
                capabilities: .correctionDerivedMutations
            )
        }

        let preferences = store.formattingPreferences(for: surface)
        XCTAssertTrue(preferences.suppressAutoLists)
        XCTAssertFalse(preferences.omitTrailingPeriod)

        // A different surface is unaffected.
        let mailSurface = SurfaceClassifier.classify(
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "New Message",
            browserURL: nil
        )
        XCTAssertEqual(store.formattingPreferences(for: mailSurface), .neutral)
    }

    func testKeepingListsOutweighsOccasionalStrip() async {
        let store = PersonalizationMemoryStore()
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Alex - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        for _ in 0..<3 {
            await store.recordFormattingEditSignals(
                pastedText: "- Milk\n- Eggs",
                editedText: "Milk, eggs",
                context: context,
                capabilities: .correctionDerivedMutations
            )
        }
        for _ in 0..<2 {
            await store.recordFormattingEditSignals(
                pastedText: "Milk\nEggs",
                editedText: "- Milk\n- Eggs",
                context: context,
                capabilities: .correctionDerivedMutations
            )
        }

        // 3 strips vs 2 keeps fails the 2x dominance requirement.
        XCTAssertFalse(store.formattingPreferences(for: surface).suppressAutoLists)
    }

    func testRepeatedTrailingPeriodStrippingLearnsOmission() async {
        let store = PersonalizationMemoryStore()
        let surface = SurfaceClassifier.classify(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Alex - Slack",
            browserURL: nil
        )
        let context = CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )

        for index in 0..<3 {
            await store.recordFormattingEditSignals(
                pastedText: "Sounds good number \(index).",
                editedText: "Sounds good number \(index)",
                context: context,
                capabilities: .correctionDerivedMutations
            )
        }

        XCTAssertTrue(store.formattingPreferences(for: surface).omitTrailingPeriod)
    }

    func testConfigurationApplyingPreferencesPreservesGlobalGates() {
        let configuration = PostProcessingConfiguration(
            removeFillersEnabled: true,
            removeFalseStartsEnabled: true,
            itnEnabled: true,
            autoPunctuationEnabled: true,
            bulletPointsEnabled: true
        )

        var preferences = DictationFormattingPreferences()
        preferences.suppressAutoLists = true
        preferences.omitTrailingPeriod = true

        let adjusted = configuration.applying(preferences)
        XCTAssertTrue(
            adjusted.bulletPointsEnabled,
            "global list permission remains a distinct hard-veto signal"
        )
        XCTAssertEqual(adjusted.learnedStylePolicy.listMarkers, .omit)
        XCTAssertEqual(adjusted.learnedStylePolicy.trailingPeriod, .omit)
        XCTAssertFalse(adjusted.suppressTrailingPunctuation)
        XCTAssertTrue(adjusted.autoPunctuationEnabled, "learned policy cannot change the global gate")
        XCTAssertTrue(adjusted.itnEnabled)

        let untouched = configuration.applying(DictationFormattingPreferences.neutral)
        XCTAssertEqual(untouched, configuration)
    }
}
