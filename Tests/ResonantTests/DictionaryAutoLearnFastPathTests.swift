import XCTest
@testable import Resonant

@MainActor
final class DictionaryAutoLearnFastPathTests: XCTestCase {
    @MainActor
    func testWorkspaceClearBarrierRejectsMutationsUntilResumed() async {
        let store = DictionaryStore()
        store.add(spoken: "alpha", written: "Alpha")
        await store.quiesceForWorkspaceClear()

        store.add(spoken: "beta", written: "Beta")
        XCTAssertEqual(store.allWords.map(\.spoken), ["alpha"])

        store.clearWorkspaceData()
        store.resumeAfterWorkspaceClear()
        store.add(spoken: "gamma", written: "Gamma")
        XCTAssertEqual(store.allWords.map(\.spoken), ["gamma"])
        await store.quiesceForWorkspaceClear()
    }


    // MARK: - Helpers

    /// Records `count` proper-noun corrections and returns whether the resulting
    /// entry is applied (i.e. present in the correction snapshot).
    private func isApplied(spoken: String, in store: DictionaryStore) -> Bool {
        store.correctionSnapshot().contains { $0.spoken == spoken.lowercased() }
    }

    // MARK: - Tier 0: proper noun learned after 1 correction

    func testProperNounLearnedAfterSingleCorrection() {
        let store = DictionaryStore()
        store.recordAutoCorrection(
            spoken: "grafanna",
            written: "Grafana",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )
        XCTAssertTrue(isApplied(spoken: "grafanna", in: store))
    }

    func testProperNounLearnedViaLazyClassificationWithoutFlag() {
        // Even when the caller does not pass writtenIsProperNoun, eligibility is
        // recomputed lazily from the written form.
        let store = DictionaryStore()
        store.recordAutoCorrection(
            spoken: "grafanna",
            written: "Grafana",
            spokenIsRealWord: false
        )
        XCTAssertTrue(isApplied(spoken: "grafanna", in: store))
    }

    // MARK: - Common real word still needs the tier-2 bar

    func testCommonRealWordNotLearnedAfterOne() {
        let store = DictionaryStore()
        // "their" → "there": written form is a common word, not a proper noun.
        store.recordAutoCorrection(
            spoken: "their",
            written: "there",
            spokenIsRealWord: true,
            writtenIsProperNoun: false
        )
        XCTAssertFalse(isApplied(spoken: "their", in: store))

        // Needs 5 total to apply.
        for _ in 0..<4 {
            store.recordAutoCorrection(
                spoken: "their",
                written: "there",
                spokenIsRealWord: true,
                writtenIsProperNoun: false
            )
        }
        XCTAssertTrue(isApplied(spoken: "their", in: store))
    }

    // MARK: - Non-word still needs 2

    func testNonWordStillNeedsTwo() {
        let store = DictionaryStore()
        // "definately" → "definitely": a non-word fix to a common word (not proper noun).
        store.recordAutoCorrection(
            spoken: "definately",
            written: "definitely",
            spokenIsRealWord: false,
            writtenIsProperNoun: false
        )
        XCTAssertFalse(isApplied(spoken: "definately", in: store))

        store.recordAutoCorrection(
            spoken: "definately",
            written: "definitely",
            spokenIsRealWord: false,
            writtenIsProperNoun: false
        )
        XCTAssertTrue(isApplied(spoken: "definately", in: store))
    }

    // MARK: - Ratio guard blocks fast path when seen-uncorrected is high

    func testRatioGuardBlocksFastPathWithHighUncorrectedCount() {
        let store = DictionaryStore()
        // Learn a proper noun once — it becomes eligible.
        store.recordAutoCorrection(
            spoken: "acme",
            written: "Acme",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )
        XCTAssertTrue(isApplied(spoken: "acme", in: store))

        // Now the user leaves "acme" alone many times — ratio drops below 0.5.
        for _ in 0..<3 {
            store.recordUncorrected(spoken: "acme")
        }
        // correctedCount=1, seenUncorrected=3 → ratio 0.25 < 0.5 fast-path guard.
        XCTAssertFalse(isApplied(spoken: "acme", in: store))
    }

    // MARK: - Notification fires exactly once when threshold crossed

    func testNotificationFiresOnceWhenThresholdCrossed() {
        let store = DictionaryStore()
        var received: [(spoken: String, written: String)] = []
        let token = NotificationCenter.default.addObserver(
            forName: DictionaryStore.didAutoLearnWordNotification,
            object: nil,
            queue: nil
        ) { note in
            let spoken = note.userInfo?["spoken"] as? String ?? ""
            let written = note.userInfo?["written"] as? String ?? ""
            received.append((spoken, written))
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // First correction crosses the tier-0 threshold → fires once.
        store.recordAutoCorrection(
            spoken: "nginx",
            written: "Nginx",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )
        // Second correction of the same already-eligible word → no new notification.
        store.recordAutoCorrection(
            spoken: "nginx",
            written: "Nginx",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.spoken, "nginx")
        XCTAssertEqual(received.first?.written, "Nginx")
    }

    func testNotificationFiresOnceForNonWordAtTierOneCrossing() {
        let store = DictionaryStore()
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: DictionaryStore.didAutoLearnWordNotification,
            object: nil,
            queue: nil
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // Non-word to common word: needs 2, so no notification on the first.
        store.recordAutoCorrection(
            spoken: "recieve",
            written: "receive",
            spokenIsRealWord: false,
            writtenIsProperNoun: false
        )
        XCTAssertEqual(count, 0)
        // Second crosses tier-1 → single notification.
        store.recordAutoCorrection(
            spoken: "recieve",
            written: "receive",
            spokenIsRealWord: false,
            writtenIsProperNoun: false
        )
        XCTAssertEqual(count, 1)
    }

    // MARK: - Case-only pairs share one key

    func testRepeatedCaseUpgradeIncrementsInsteadOfSuppressing() {
        // "iphone" → "iPhone" stores under the same key as its written form.
        // A repeat of the same correction must increment, not read as reversal.
        let store = DictionaryStore()
        store.recordAutoCorrection(
            spoken: "iphone",
            written: "iPhone",
            spokenIsRealWord: false,
            writtenIsProperNoun: false
        )
        XCTAssertFalse(isApplied(spoken: "iphone", in: store))
        store.recordAutoCorrection(
            spoken: "iphone",
            written: "iPhone",
            spokenIsRealWord: false,
            writtenIsProperNoun: false
        )
        XCTAssertTrue(isApplied(spoken: "iphone", in: store))
    }

    func testCaseFlipSuppressesStoredCasePreference() {
        let store = DictionaryStore()
        for _ in 0..<2 {
            store.recordAutoCorrection(
                spoken: "iphone",
                written: "iPhone",
                spokenIsRealWord: false,
                writtenIsProperNoun: false
            )
        }
        XCTAssertTrue(isApplied(spoken: "iphone", in: store))

        // The user changes "iPhone" back to "iphone" — stop applying.
        store.recordAutoCorrection(
            spoken: "iPhone",
            written: "iphone",
            spokenIsRealWord: false,
            writtenIsProperNoun: false
        )
        XCTAssertFalse(isApplied(spoken: "iphone", in: store))
    }

    // MARK: - Downcase preferences

    func testDowncasePreferenceAppliesAfterThreeExceptSentenceStarts() {
        let store = DictionaryStore()
        for index in 0..<3 {
            store.recordAutoCorrection(
                spoken: "Vibe",
                written: "vibe",
                spokenIsRealWord: true,
                writtenIsProperNoun: false
            )
            let expected = index == 2
            XCTAssertEqual(isApplied(spoken: "vibe", in: store), expected)
        }

        let output = store.applyCorrections(to: "Vibe coding is my Vibe. Vibe on")
        XCTAssertEqual(output, "Vibe coding is my vibe. Vibe on")
    }

    // MARK: - Seeing the corrected form is confirmation, not counter-evidence

    func testSeeingCorrectedFormDoesNotCountAgainstEntry() {
        let store = DictionaryStore()
        store.recordAutoCorrection(
            spoken: "acme",
            written: "Acme",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )
        XCTAssertTrue(isApplied(spoken: "acme", in: store))

        // Future pastes contain the corrected "Acme" — that must not erode the entry.
        for _ in 0..<5 {
            store.recordUncorrected(spoken: "Acme")
        }
        XCTAssertTrue(isApplied(spoken: "acme", in: store))
    }

    // MARK: - Declined suggestions

    func testDeclineSuggestionSuppressesWithoutApplying() {
        let store = DictionaryStore()
        store.declineSuggestion(spoken: "teece", written: "Thijs")
        XCTAssertTrue(store.hasEntry(spoken: "teece"))
        XCTAssertFalse(isApplied(spoken: "teece", in: store))

        // Even a later organic correction stays suppressed.
        store.recordAutoCorrection(
            spoken: "teece",
            written: "Thijs",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )
        XCTAssertFalse(isApplied(spoken: "teece", in: store))
    }

    // MARK: - Case-only edits don't learn dictionary pairs

    func testCaseOnlyEditIsNotAProperNoun() {
        // "The" and "the" differ only in case → not a proper noun candidate.
        XCTAssertFalse(CorrectionDiffEngine.isProperNoun(spoken: "the", written: "The"))
    }

    func testCaseOnlyDiffProducesNoCorrection() {
        // Diff engine already filters case-only downcasing noise.
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "The report is ready",
            edited: "the report is ready"
        )
        XCTAssertTrue(corrections.isEmpty)
    }

    // MARK: - Proper-noun classification

    func testProperNounDetectionForName() {
        // "grafanna" → "Grafana": capitalized, single token, and "grafana" is not a
        // common dictionary word — the shape of a deliberately introduced name.
        XCTAssertTrue(CorrectionDiffEngine.isProperNoun(spoken: "grafanna", written: "Grafana"))
    }

    func testCommonCapitalizedWordIsNotProperNoun() {
        // "there" is a common word even when the pair capitalizes it.
        XCTAssertFalse(CorrectionDiffEngine.isProperNoun(spoken: "their", written: "There"))
    }

    func testMultiTokenWrittenIsNotProperNoun() {
        XCTAssertFalse(CorrectionDiffEngine.isProperNoun(spoken: "foobar", written: "Foo Bar"))
    }

    func testExtractCorrectionsSurfacesProperNounFlag() {
        // "grafanna" → "Grafana": written lowercased ("grafana") is unknown, so the
        // engine should flag it as a proper noun for the fast path.
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "I use grafanna daily",
            edited: "I use Grafana daily"
        )
        XCTAssertEqual(corrections.count, 1)
        XCTAssertTrue(corrections.first?.writtenIsProperNoun ?? false)
    }

    // MARK: - Retroactive boost feedback

    func testRemovingActivePairRoutesPersistedFalseApplyCount() async {
        var decays: [(String, VocabularyBoostAuditSummary.FalseApplyReason)] = []
        var signals: [VocabularyBoostAudit.CorrectionSignals] = []
        let store = DictionaryStore(
            boostDecisionDecayer: { writtenForm, reason in
                decays.append((writtenForm, reason))
                return 2
            },
            boostCorrelationRecorder: { signals.append($0) }
        )
        store.add(spoken: "codec", written: "Codex")

        store.remove(spoken: "codec")
        await waitUntil { signals.count == 1 }

        XCTAssertEqual(decays.count, 1)
        XCTAssertEqual(decays.first?.0, "Codex")
        XCTAssertEqual(decays.first?.1, .dictionaryRemoved)
        XCTAssertEqual(signals.first?.removedAppliedTermCount, 2)
        XCTAssertEqual(signals.first?.insertedVetoedTermCount, 0)
    }

    func testSuppressingFormerlyActivePairStillDecaysAfterRatioFalls() async {
        var decays: [(String, VocabularyBoostAuditSummary.FalseApplyReason)] = []
        let store = DictionaryStore(
            boostDecisionDecayer: { writtenForm, reason in
                decays.append((writtenForm, reason))
                return 1
            }
        )
        store.recordAutoCorrection(
            spoken: "codec",
            written: "Codex",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )
        XCTAssertEqual(store.applyCorrections(to: "codec"), "Codex")
        store.recordUncorrected(spoken: "codec")
        store.recordUncorrected(spoken: "codec")
        XCTAssertEqual(store.applyCorrections(to: "codec"), "codec")

        store.suppress(spoken: "codec")
        await waitUntil { decays.count == 1 }

        XCTAssertEqual(decays.first?.0, "Codex")
        XCTAssertEqual(decays.first?.1, .dictionarySuppressed)
    }

    func testRemovingFormerlyActivePairStillDecaysAfterRatioFalls() async {
        var decays: [(String, VocabularyBoostAuditSummary.FalseApplyReason)] = []
        let store = DictionaryStore(
            boostDecisionDecayer: { writtenForm, reason in
                decays.append((writtenForm, reason))
                return 1
            }
        )
        store.recordAutoCorrection(
            spoken: "codec",
            written: "Codex",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )
        store.recordUncorrected(spoken: "codec")
        store.recordUncorrected(spoken: "codec")
        XCTAssertEqual(store.applyCorrections(to: "codec"), "codec")

        store.remove(spoken: "codec")
        await waitUntil { decays.count == 1 }

        XCTAssertEqual(decays.first?.0, "Codex")
        XCTAssertEqual(decays.first?.1, .dictionaryRemoved)
    }

    func testDuplicateWrittenAliasMustBecomeInactiveBeforeRemoveDecays() async {
        var decayedTerms: [String] = []
        let store = DictionaryStore(
            boostDecisionDecayer: { writtenForm, _ in
                decayedTerms.append(writtenForm)
                return 1
            }
        )
        store.add(spoken: "codec", written: "Codex")
        store.add(spoken: "code x", written: "Codex")

        store.remove(spoken: "codec")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(decayedTerms.isEmpty)

        store.remove(spoken: "code x")
        await waitUntil { decayedTerms.count == 1 }
        XCTAssertEqual(decayedTerms, ["Codex"])
    }

    func testDuplicateWrittenAliasMustBecomeInactiveBeforeSuppressDecays() async {
        var decayedTerms: [String] = []
        let store = DictionaryStore(
            boostDecisionDecayer: { writtenForm, _ in
                decayedTerms.append(writtenForm)
                return 1
            }
        )
        store.recordAutoCorrection(
            spoken: "codec",
            written: "Codex",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )
        store.recordAutoCorrection(
            spoken: "code x",
            written: "Codex",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )

        store.suppress(spoken: "codec")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(decayedTerms.isEmpty)

        store.suppress(spoken: "code x")
        await waitUntil { decayedTerms.count == 1 }
        XCTAssertEqual(decayedTerms, ["Codex"])
    }

    func testAtomicSpokenRenameKeepsWrittenTermWithoutDecay() async {
        var decayCount = 0
        let store = DictionaryStore(
            boostDecisionDecayer: { _, _ in
                decayCount += 1
                return 1
            }
        )
        store.add(spoken: "codec", written: "Codex")

        store.update(oldSpoken: "codec", spoken: "code x", written: "Codex")
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(decayCount, 0)
        XCTAssertEqual(store.allWords.map(\.spoken), ["code x"])
        XCTAssertEqual(store.allWords.map(\.written), ["Codex"])
    }

    func testDuplicateWrittenAliasMustBecomeInactiveBeforeReplacementDecays() async {
        var decays: [(String, VocabularyBoostAuditSummary.FalseApplyReason)] = []
        let store = DictionaryStore(
            boostDecisionDecayer: { writtenForm, reason in
                decays.append((writtenForm, reason))
                return 1
            }
        )
        store.add(spoken: "codec", written: "Codex")
        store.add(spoken: "code x", written: "Codex")

        store.update(oldSpoken: "codec", spoken: "codec", written: "Convex")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(decays.isEmpty)

        store.update(oldSpoken: "code x", spoken: "code x", written: "Codecs")
        await waitUntil { decays.count == 1 }
        XCTAssertEqual(decays.first?.0, "Codex")
        XCTAssertEqual(decays.first?.1, .dictionaryReplaced)
    }

    func testSpokenKeyCollisionDecaysBothWrittenFormsThatBecomeInactive() async {
        var decays: [(String, VocabularyBoostAuditSummary.FalseApplyReason)] = []
        let store = DictionaryStore(
            boostDecisionDecayer: { writtenForm, reason in
                decays.append((writtenForm, reason))
                return 1
            }
        )
        store.add(spoken: "codec", written: "Codex")
        store.add(spoken: "notion app", written: "Notion")

        store.update(oldSpoken: "codec", spoken: "notion app", written: "Convex")
        await waitUntil { decays.count == 2 }

        XCTAssertEqual(Set(decays.map(\.0)), Set(["Codex", "Notion"]))
        XCTAssertTrue(decays.allSatisfy { $0.1 == .dictionaryReplaced })
        XCTAssertEqual(store.allWords.map(\.written), ["Convex"])
    }

    func testInPlaceCorrectionReversalDoesNotDuplicateRetroactiveFeedback() async {
        var decayCount = 0
        let store = DictionaryStore(
            boostDecisionDecayer: { _, _ in
                decayCount += 1
                return 1
            }
        )
        store.recordAutoCorrection(
            spoken: "design",
            written: "Devin",
            spokenIsRealWord: true,
            writtenIsProperNoun: true
        )

        store.recordAutoCorrection(
            spoken: "Devin",
            written: "design",
            spokenIsRealWord: true
        )
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(decayCount, 0)
        XCTAssertTrue(store.allWords.first?.isSuppressed == true)
    }

    func testBoostFeedbackDecaysAreSerialized() async {
        var activeDecays = 0
        var maximumActiveDecays = 0
        var decayedTerms: [String] = []
        var signalCount = 0
        let store = DictionaryStore(
            boostDecisionDecayer: { writtenForm, _ in
                activeDecays += 1
                maximumActiveDecays = max(maximumActiveDecays, activeDecays)
                decayedTerms.append(writtenForm)
                try? await Task.sleep(for: .milliseconds(20))
                activeDecays -= 1
                return 1
            },
            boostCorrelationRecorder: { _ in signalCount += 1 }
        )
        store.add(spoken: "alpha", written: "AlphaTerm")
        store.add(spoken: "beta", written: "BetaTerm")

        store.remove(spoken: "alpha")
        store.remove(spoken: "beta")
        await waitUntil { signalCount == 2 }

        XCTAssertEqual(maximumActiveDecays, 1)
        XCTAssertEqual(decayedTerms, ["AlphaTerm", "BetaTerm"])
    }

    // MARK: - formatCorrectionSink seam

    func testFormatCorrectionSinkFailsClosedWithoutAttribution() async {
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager()
        )
        var sinkCalls: [(pasted: String, edited: String)] = []
        observer.formatCorrectionSink = { pasted, edited, _ in
            sinkCalls.append((pasted, edited))
        }

        let provider = StubAmbientProvider(content: "I met John today")
        observer.ambientFieldContentProvider = provider

        await observer.processWithAmbientFallback(
            makeObservation(pastedText: "I met john today"),
            fallbackStatus: .bypassed
        )

        XCTAssertTrue(sinkCalls.isEmpty)
    }

    func testFormatCorrectionSinkDoesNotFireWhenTextUnchanged() async {
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager()
        )
        var sinkCallCount = 0
        observer.formatCorrectionSink = { _, _, _ in sinkCallCount += 1 }

        let provider = StubAmbientProvider(content: "unchanged text here")
        observer.ambientFieldContentProvider = provider

        await observer.processWithAmbientFallback(
            makeObservation(pastedText: "unchanged text here"),
            fallbackStatus: .bypassed
        )

        XCTAssertEqual(sinkCallCount, 0)
    }

    // MARK: - Test doubles

    @MainActor
    private final class StubAmbientProvider: AmbientFieldContentProviding {
        let content: String?
        init(content: String?) { self.content = content }
        func currentFieldContent(for app: NSRunningApplication?) async -> String? {
            content
        }
    }

    private func makeObservation(pastedText: String) -> CorrectionObserver.PendingObservation {
        CorrectionObserver.PendingObservation(
            pastedText: pastedText,
            targetApp: nil,
            windowTitle: nil,
            browserURL: nil,
            rawTranscript: nil,
            contextPacket: nil,
            qualityTrace: nil,
            timestamp: Date()
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
