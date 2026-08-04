import XCTest
@testable import Resonant

@MainActor
final class FormatPreferenceStoreTests: XCTestCase {
    private func makeContext(
        host: String = "example.com",
        surfaceKind: SurfaceKind = .browser
    ) -> CorrectionObservationContext {
        let surface = SurfaceClassifier.classify(
            appName: "Chrome",
            bundleId: "com.google.chrome",
            windowTitle: "Notes",
            browserURL: "https://\(host)/page"
        )
        return CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            contextPacket: nil
        )
    }

    private func learnResonantCasing(
        in store: PersonalizationMemoryStore,
        context: CorrectionObservationContext
    ) {
        store.recordFormatCorrections(
            pasted: "the resonant team met",
            edited: "the Resonant team met",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        store.recordFormatCorrections(
            pasted: "our resonant work shipped",
            edited: "our Resonant work shipped",
            context: context,
            capabilities: .correctionDerivedMutations
        )
    }

    func testTwoConsistentURLRevertsSuppressExpansionForHost() {
        let store = PersonalizationMemoryStore()
        let context = makeContext(host: "substack.com")

        store.recordFormatCorrections(
            pasted: "check out substack.com now",
            edited: "check out Substack now",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        XCTAssertFalse(store.shouldSuppressSiteDomainExpansion(host: "substack.com"))

        store.recordFormatCorrections(
            pasted: "read on substack.com later",
            edited: "read on Substack later",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        XCTAssertTrue(store.shouldSuppressSiteDomainExpansion(host: "substack.com"))
        XCTAssertFalse(store.shouldSuppressSiteDomainExpansion(host: "other.com"))
    }

    func testMissingCapabilityCannotCreateFormatPreference() async {
        let store = PersonalizationMemoryStore()
        let context = makeContext()

        for _ in 0..<3 {
            store.recordFormatCorrections(
                pasted: "the resonant team met",
                edited: "the Resonant team met",
                context: context
            )
            store.recordFormatCorrections(
                pasted: "call 555-123-4567 today",
                edited: "call (555) 123-4567 today",
                context: context,
                capabilities: .none
            )
        }

        XCTAssertNil(store.preferredWordCasing(for: "resonant"))
        XCTAssertNil(store.preferredPhoneStyle())
        let controls = await store.controlsSnapshot()
        XCTAssertTrue(controls.formatPreferences.isEmpty)
    }

    func testContradictingEditDecaysPreference() {
        let store = PersonalizationMemoryStore()
        let context = makeContext()

        // Establish a parenthesized phone-style preference (2 consistent reformats).
        store.recordFormatCorrections(
            pasted: "call 555-123-4567 today",
            edited: "call (555) 123-4567 today",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        store.recordFormatCorrections(
            pasted: "dial 555-987-6543 now",
            edited: "dial (555) 987-6543 now",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        XCTAssertEqual(store.preferredPhoneStyle(), "parenthesized")

        // Contradict repeatedly with a different style (dotted) for the same
        // category+scope — the parenthesized preference decays out.
        for _ in 0..<3 {
            store.recordFormatCorrections(
                pasted: "reach 555-111-2222 anytime",
                edited: "reach 555.111.2222 anytime",
                context: context,
                capabilities: .correctionDerivedMutations
            )
        }
        // Parenthesized has decayed below threshold; dotted now dominates.
        XCTAssertEqual(store.preferredPhoneStyle(), "dotted")
    }

    func testPhoneStylePreferenceEmergesAfterTwoConsistentReformats() {
        let store = PersonalizationMemoryStore()
        let context = makeContext()

        store.recordFormatCorrections(
            pasted: "call 555-123-4567 today",
            edited: "call (555) 123-4567 today",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        XCTAssertNil(store.preferredPhoneStyle())

        store.recordFormatCorrections(
            pasted: "dial 555-987-6543 now",
            edited: "dial (555) 987-6543 now",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        XCTAssertEqual(store.preferredPhoneStyle(), "parenthesized")
    }

    func testEmailCasingPreferenceEmerges() {
        let store = PersonalizationMemoryStore()
        let context = makeContext()

        store.recordFormatCorrections(
            pasted: "email Alex@Example.com now",
            edited: "email alex@example.com now",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        XCTAssertNil(store.preferredEmailCasing())

        store.recordFormatCorrections(
            pasted: "cc Alex@Example.com please",
            edited: "cc alex@example.com please",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        XCTAssertEqual(store.preferredEmailCasing(), "alex@example.com")
    }

    func testWordCasingPreferenceEmergesForSpecificWord() {
        let store = PersonalizationMemoryStore()
        let context = makeContext()

        store.recordFormatCorrections(
            pasted: "the resonant team met",
            edited: "the Resonant team met",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        XCTAssertNil(store.preferredWordCasing(for: "resonant"))

        store.recordFormatCorrections(
            pasted: "our resonant work shipped",
            edited: "our Resonant work shipped",
            context: context,
            capabilities: .correctionDerivedMutations
        )
        XCTAssertEqual(store.preferredWordCasing(for: "resonant"), "Resonant")
        XCTAssertNil(store.preferredWordCasing(for: "unrelated"))
    }

    func testFormatPreferenceCanBeSuppressedAndRestored() async throws {
        let store = PersonalizationMemoryStore()
        let context = makeContext()
        learnResonantCasing(in: store, context: context)
        let initialSnapshot = await store.controlsSnapshot()
        let id = try XCTUnwrap(
            initialSnapshot.formatPreferences.first {
                $0.category == FormatCorrectionCategory.wordCasing.rawValue
                    && $0.preferredValue == "Resonant"
            }?.id
        )

        await store.setFormatPreferenceSuppressed(id: id, isSuppressed: true)

        XCTAssertNil(store.preferredWordCasing(for: "resonant"))
        XCTAssertNil(store.formattingPreferences(for: context.surface).learnedWordCasings["resonant"])
        var snapshot = await store.controlsSnapshot()
        XCTAssertEqual(snapshot.formatConsumers.suppressed, 1)
        XCTAssertTrue(try XCTUnwrap(snapshot.formatPreferences.first { $0.id == id }).isSuppressed)

        await store.setFormatPreferenceSuppressed(id: id, isSuppressed: false)

        XCTAssertEqual(store.preferredWordCasing(for: "resonant"), "Resonant")
        snapshot = await store.controlsSnapshot()
        XCTAssertEqual(snapshot.formatConsumers.formatterEligible, 1)
        XCTAssertFalse(try XCTUnwrap(snapshot.formatPreferences.first { $0.id == id }).isSuppressed)
    }

    func testDictionarySuppressionCascadesToMatchingWordCasing() {
        let memory = PersonalizationMemoryStore()
        let context = makeContext()
        learnResonantCasing(in: memory, context: context)
        let dictionary = DictionaryStore()
        dictionary.onWordSuppressed = { [weak memory] spoken, written in
            memory?.suppressMatchingWordCasingPreference(spoken: spoken, written: written)
        }
        dictionary.add(spoken: "resonant", written: "Resonant")

        dictionary.suppress(spoken: "resonant")

        XCTAssertNil(memory.preferredWordCasing(for: "resonant"))
        XCTAssertNil(memory.formattingPreferences(for: context.surface).learnedWordCasings["resonant"])
    }

    func testSuppressedDictionaryCasingSuppressesPreferenceLearnedLater() async throws {
        let memory = PersonalizationMemoryStore()
        let dictionary = DictionaryStore()
        memory.dictionaryCasingSuppressionProvider = { [weak dictionary] preferredValue in
            dictionary?.hasSuppressedCasingMapping(preferredValue: preferredValue) ?? false
        }
        dictionary.add(spoken: "resonant", written: "Resonant")
        dictionary.suppress(spoken: "resonant")

        let context = makeContext()
        learnResonantCasing(in: memory, context: context)

        XCTAssertNil(memory.preferredWordCasing(for: "resonant"))
        XCTAssertNil(memory.formattingPreferences(for: context.surface).learnedWordCasings["resonant"])
        let snapshot = await memory.controlsSnapshot()
        let preference = try XCTUnwrap(
            snapshot.formatPreferences.first { $0.preferredValue == "Resonant" }
        )
        XCTAssertTrue(preference.isSuppressed)
        XCTAssertEqual(snapshot.formatConsumers.suppressed, 1)
    }

    func testLegacyReconciliationSuppressesExistingDictionaryCasing() async {
        let memory = PersonalizationMemoryStore(
            formatPreferenceReconciliationVersionForNewRecords: 0
        )
        let context = makeContext()
        learnResonantCasing(in: memory, context: context)
        let dictionary = DictionaryStore()
        dictionary.add(spoken: "resonant", written: "Resonant")
        dictionary.suppress(spoken: "resonant")
        XCTAssertEqual(memory.preferredWordCasing(for: "resonant"), "Resonant")

        await memory.reconcileSuppressedDictionaryCasings(dictionary.allWords)

        XCTAssertNil(memory.preferredWordCasing(for: "resonant"))
        let snapshot = await memory.controlsSnapshot()
        XCTAssertEqual(snapshot.formatConsumers.suppressed, 1)
    }

    func testReconciliationRepairsCurrentVersionAfterMissedCascade() async {
        let memory = PersonalizationMemoryStore()
        let context = makeContext()
        learnResonantCasing(in: memory, context: context)
        let dictionary = DictionaryStore()
        dictionary.add(spoken: "resonant", written: "Resonant")
        dictionary.suppress(spoken: "resonant")
        XCTAssertEqual(memory.preferredWordCasing(for: "resonant"), "Resonant")

        await memory.reconcileSuppressedDictionaryCasings(dictionary.allWords)

        XCTAssertNil(memory.preferredWordCasing(for: "resonant"))
    }

    func testRestoredCasingSurvivesUnrelatedWorkspaceMerge() async throws {
        let memory = PersonalizationMemoryStore()
        let context = makeContext()
        learnResonantCasing(in: memory, context: context)
        let dictionary = DictionaryStore()
        dictionary.onWordSuppressed = { [weak memory] spoken, written in
            memory?.suppressMatchingWordCasingPreference(spoken: spoken, written: written)
        }
        dictionary.add(spoken: "resonant", written: "Resonant")
        dictionary.suppress(spoken: "resonant")
        let suppressedSnapshot = await memory.controlsSnapshot()
        let id = try XCTUnwrap(
            suppressedSnapshot.formatPreferences.first {
                $0.preferredValue == "Resonant"
            }?.id
        )
        await memory.setFormatPreferenceSuppressed(id: id, isSuppressed: false)
        await memory.reconcileSuppressedDictionaryCasings(dictionary.allWords)
        XCTAssertEqual(memory.preferredWordCasing(for: "resonant"), "Resonant")

        var remote = dictionary.workspaceSnapshot()
        remote.append(DictionaryStore.WorkspaceWord(word: DictionaryWord(
            spoken: "convexx",
            written: "Convex"
        )))
        dictionary.mergeWorkspaceWords(remote)

        XCTAssertEqual(memory.preferredWordCasing(for: "resonant"), "Resonant")
    }

    func testPersistedFormatSuppressionFieldsHaveMigrationDefaults() {
        let model = LearnedFormatPreference(
            categoryRaw: FormatCorrectionCategory.wordCasing.rawValue,
            scopeKey: FormatCorrectionClassifier.globalScope,
            preferredValue: "Resonant",
            positiveCount: 2,
            confidence: 0.64
        )

        XCTAssertFalse(model.isSuppressed)
        XCTAssertEqual(model.suppressionReconciliationVersion, 0)
    }

    func testPruningRespectsCap() {
        let store = PersonalizationMemoryStore()
        let context = makeContext()

        // Create > 200 distinct, active urlExpansionRevert rows (one per host,
        // reinforced twice so each clears the active threshold).
        for index in 0..<260 {
            for _ in 0..<2 {
                store.recordFormatCorrections(
                    pasted: "visit brand\(index).com today",
                    edited: "visit Brand\(index) today",
                    context: context,
                    capabilities: .correctionDerivedMutations
                )
            }
        }

        // Cap is 200: the earliest (lowest lastSeenAt) rows are dropped while the
        // most recent survive.
        XCTAssertFalse(store.shouldSuppressSiteDomainExpansion(host: "brand0.com"))
        XCTAssertTrue(store.shouldSuppressSiteDomainExpansion(host: "brand259.com"))
    }

    func testControlsSnapshotKeepsSuppressedPreferenceVisiblePastEightyActiveRows() async throws {
        let store = PersonalizationMemoryStore()
        let context = makeContext()

        for index in 0..<81 {
            for _ in 0..<2 {
                store.recordFormatCorrections(
                    pasted: "visit visible\(index).com today",
                    edited: "visit Visible\(index) today",
                    context: context,
                    capabilities: .correctionDerivedMutations
                )
            }
        }
        learnResonantCasing(in: store, context: context)
        var snapshot = await store.controlsSnapshot()
        let casingID = try XCTUnwrap(
            snapshot.formatPreferences.first { $0.preferredValue == "Resonant" }?.id
        )

        await store.setFormatPreferenceSuppressed(id: casingID, isSuppressed: true)
        snapshot = await store.controlsSnapshot()

        XCTAssertGreaterThan(snapshot.formatConsumers.formatterEligible, 80)
        XCTAssertEqual(snapshot.formatPreferences.count, 82)
        XCTAssertTrue(try XCTUnwrap(
            snapshot.formatPreferences.first { $0.id == casingID }
        ).isSuppressed)
    }

    func testPruningPreservesExplicitlySuppressedPreference() async throws {
        let store = PersonalizationMemoryStore()
        let context = makeContext()
        learnResonantCasing(in: store, context: context)
        var snapshot = await store.controlsSnapshot()
        let casingID = try XCTUnwrap(
            snapshot.formatPreferences.first { $0.preferredValue == "Resonant" }?.id
        )
        await store.setFormatPreferenceSuppressed(id: casingID, isSuppressed: true)

        for index in 0..<205 {
            for _ in 0..<2 {
                store.recordFormatCorrections(
                    pasted: "visit retained\(index).com today",
                    edited: "visit Retained\(index) today",
                    context: context,
                    capabilities: .correctionDerivedMutations
                )
            }
        }
        learnResonantCasing(in: store, context: context)

        XCTAssertNil(store.preferredWordCasing(for: "resonant"))
        snapshot = await store.controlsSnapshot()
        XCTAssertEqual(snapshot.formatPreferences.count, 200)
        XCTAssertTrue(try XCTUnwrap(
            snapshot.formatPreferences.first { $0.id == casingID }
        ).isSuppressed)
    }

    func testFormattingPreferencesCarryLearnedFormatFields() {
        let store = PersonalizationMemoryStore()
        let context = makeContext(host: "substack.com")

        for _ in 0..<2 {
            store.recordFormatCorrections(
                pasted: "check out substack.com now",
                edited: "check out Substack now",
                context: context,
                capabilities: .correctionDerivedMutations
            )
            store.recordFormatCorrections(
                pasted: "call me at 555-123-4567",
                edited: "call me at (555) 123-4567",
                context: context,
                capabilities: .correctionDerivedMutations
            )
            store.recordFormatCorrections(
                pasted: "open the figma file",
                edited: "open the Figma file",
                context: context,
                capabilities: .correctionDerivedMutations
            )
        }

        let preferences = store.formattingPreferences(for: context.surface)
        XCTAssertTrue(preferences.suppressedDomainExpansionHosts.contains("substack.com"))
        XCTAssertEqual(preferences.preferredPhoneStyle, "parenthesized")
        XCTAssertEqual(preferences.learnedWordCasings["figma"], "Figma")
    }
}
