import Foundation
import SwiftData
import XCTest
@testable import Resonant

final class DataStoreTests: XCTestCase {

    @MainActor
    func testLegacyPersonalizationFixtureOpensWithoutQuarantine() async throws {
        let fixture = try LegacyPersonalizationStoreFixture.makeCopy()
        defer { fixture.remove() }

        let unopenedFamily = DataStore.storeFamilyURLs(for: fixture.storeURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unopenedFamily[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unopenedFamily[1].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unopenedFamily[2].path))

        do {
            let store = DataStore(storeURLOverride: fixture.storeURL)
            await store.setup()

            XCTAssertTrue(store.isReady)
            XCTAssertNil(store.setupError)
            XCTAssertNotNil(store.container)
        }

        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: fixture.directoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(directoryContents.contains {
            $0.lastPathComponent.hasPrefix("Resonant-corrupt-")
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.storeURL.path))
    }

    @MainActor
    func testLegacyFixturePreservesEntitiesStylesCorrectionsAndNonPunctuationRules() async throws {
        let fixture = try LegacyPersonalizationStoreFixture.makeCopy()
        defer { fixture.remove() }

        let store = DataStore(storeURLOverride: fixture.storeURL)
        await store.setup()
        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.setupError)

        let entities = store.fetch(FetchDescriptor<LearnedContextEntity>())
        XCTAssertEqual(entities.count, 1)
        let entity = try XCTUnwrap(entities.first)
        XCTAssertEqual(entity.id, LegacyPersonalizationStoreFixture.Baseline.entityID)
        XCTAssertEqual(entity.type, "personName")
        XCTAssertEqual(entity.value, "Ada Lovelace")
        XCTAssertEqual(entity.normalizedValue, "ada lovelace")
        XCTAssertEqual(entity.aliasesJSON, #"["Ada","Countess of Lovelace"]"#)
        XCTAssertEqual(entity.spokenFormsJSON, #"["ay da love lace"]"#)
        XCTAssertEqual(entity.appScope, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(entity.siteScope, "example.com")
        XCTAssertEqual(entity.surfaceKind, "chat")
        XCTAssertEqual(entity.projectScope, "analytical-engine")
        XCTAssertEqual(entity.confidence, 0.875, accuracy: 0.000_001)
        XCTAssertEqual(entity.positiveCount, 7)
        XCTAssertEqual(entity.negativeCount, 2)
        XCTAssertEqual(entity.source, "correctionMemory")
        XCTAssertTrue(entity.isUserPinned)
        XCTAssertFalse(entity.isSuppressed)
        XCTAssertEqual(entity.createdAt.timeIntervalSince1970, 1_700_000_001, accuracy: 0.001)
        XCTAssertEqual(entity.lastSeenAt.timeIntervalSince1970, 1_700_000_101, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(entity.lastUsedAt).timeIntervalSince1970,
            1_700_000_201,
            accuracy: 0.001
        )

        let profiles = store.fetch(FetchDescriptor<LearnedStyleProfile>())
        XCTAssertEqual(profiles.count, 1)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, LegacyPersonalizationStoreFixture.Baseline.styleProfileID)
        XCTAssertEqual(
            profile.scopeKey,
            "chat|com.tinyspeck.slackmacgap|example.com|analytical-engine"
        )
        XCTAssertEqual(profile.surfaceKind, "chat")
        XCTAssertEqual(profile.appScope, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(profile.siteScope, "example.com")
        XCTAssertEqual(profile.projectScope, "analytical-engine")
        XCTAssertEqual(profile.sampleCount, 13)
        XCTAssertEqual(profile.acceptedCount, 8)
        XCTAssertEqual(profile.correctedCount, 5)
        XCTAssertEqual(profile.lowercaseOpeningCount, 4)
        XCTAssertEqual(profile.sentenceCaseOpeningCount, 9)
        XCTAssertEqual(profile.greetingCount, 3)
        XCTAssertEqual(profile.signoffCount, 2)
        XCTAssertEqual(profile.shortMessageCount, 6)
        XCTAssertEqual(profile.paragraphBreakCount, 1)
        XCTAssertEqual(profile.finalPunctuationCount, 10)
        XCTAssertEqual(profile.totalWords, 144)
        XCTAssertEqual(profile.listMarkersStrippedCount, 2)
        XCTAssertEqual(profile.listMarkersKeptCount, 7)
        XCTAssertEqual(profile.trailingPunctuationStrippedCount, 3)
        XCTAssertEqual(profile.autoSentSampleCount, 5)
        XCTAssertEqual(profile.autoSentGreetingCount, 1)
        XCTAssertEqual(profile.autoSentSignoffCount, 1)
        XCTAssertEqual(profile.autoSentShortMessageCount, 4)
        XCTAssertEqual(profile.autoSentParagraphBreakCount, 2)
        XCTAssertEqual(profile.directLowercaseOpeningCount, 0)
        XCTAssertEqual(profile.directSentenceCaseOpeningCount, 0)
        XCTAssertEqual(profile.directListOmissionCount, 0)
        XCTAssertEqual(profile.directListRequirementCount, 0)
        XCTAssertEqual(profile.directTrailingPeriodOmissionCount, 0)
        XCTAssertEqual(profile.directTrailingPeriodRequirementCount, 0)
        XCTAssertEqual(profile.appliedPolicyConfirmationCount, 0)
        XCTAssertEqual(profile.authoredHabitSampleCount, 0)
        XCTAssertEqual(profile.rawTranscriptHabitSampleCount, 0)
        XCTAssertEqual(profile.createdAt.timeIntervalSince1970, 1_700_000_002, accuracy: 0.001)
        XCTAssertEqual(profile.lastSeenAt.timeIntervalSince1970, 1_700_000_102, accuracy: 0.001)

        let preferences = store.fetch(FetchDescriptor<LearnedFormatPreference>())
        XCTAssertEqual(preferences.count, 1)
        XCTAssertFalse(preferences.contains { $0.categoryRaw == "punctuation" })
        XCTAssertTrue(store.obsoletePunctuationRetirementCompleted)
        XCTAssertEqual(store.retiredObsoletePunctuationRowCount, 1)

        let wordCasing = try XCTUnwrap(preferences.first {
            $0.id == LegacyPersonalizationStoreFixture.Baseline.wordCasingPreferenceID
        })
        XCTAssertEqual(wordCasing.categoryRaw, "wordCasing")
        XCTAssertEqual(wordCasing.scopeKey, "global")
        XCTAssertEqual(wordCasing.preferredValue, "SwiftData")
        XCTAssertEqual(wordCasing.positiveCount, 6)
        XCTAssertEqual(wordCasing.negativeCount, 2)
        XCTAssertEqual(wordCasing.confidence, 0.75, accuracy: 0.000_001)
        XCTAssertTrue(wordCasing.isSuppressed)
        XCTAssertEqual(wordCasing.suppressionReconciliationVersion, 1)
        XCTAssertEqual(wordCasing.createdAt.timeIntervalSince1970, 1_700_000_004, accuracy: 0.001)
        XCTAssertEqual(wordCasing.lastSeenAt.timeIntervalSince1970, 1_700_000_104, accuracy: 0.001)

        let events = store.fetch(FetchDescriptor<DictationCorrectionEvent>())
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.id, LegacyPersonalizationStoreFixture.Baseline.correctionEventID)
        XCTAssertEqual(event.timestamp.timeIntervalSince1970, 1_700_000_005, accuracy: 0.001)
        XCTAssertEqual(event.appName, "Slack")
        XCTAssertEqual(event.bundleId, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(event.windowTitle, "Ada - Legacy Fixture")
        XCTAssertEqual(event.browserURL, "https://example.com/legacy")
        XCTAssertEqual(event.surfaceKind, "chat")
        XCTAssertEqual(event.rawTranscriptPreview, "message ay da love lace")
        XCTAssertEqual(event.pastedTextPreview, "Message ay da love lace.")
        XCTAssertEqual(event.editedTextPreview, "Message Ada Lovelace")
        XCTAssertEqual(
            event.correctionsJSON,
            #"[{"spoken":"ay da love lace","spokenIsRealWord":false,"written":"Ada Lovelace"}]"#
        )
        XCTAssertEqual(event.corrections, [
            StoredCorrectionPair(
                spoken: "ay da love lace",
                written: "Ada Lovelace",
                spokenIsRealWord: false
            ),
        ])
        XCTAssertTrue(event.hadCorrection)

        let dictionaryWords = store.fetch(FetchDescriptor<DictionaryWord>())
        XCTAssertEqual(dictionaryWords.count, 1)
        let dictionaryWord = try XCTUnwrap(dictionaryWords.first)
        XCTAssertEqual(dictionaryWord.id, LegacyPersonalizationStoreFixture.Baseline.dictionaryWordID)
        XCTAssertEqual(dictionaryWord.spoken, "swift data")
        XCTAssertEqual(dictionaryWord.written, "SwiftData")
        XCTAssertEqual(dictionaryWord.createdAt.timeIntervalSince1970, 1_700_000_006, accuracy: 0.001)
        XCTAssertEqual(dictionaryWord.correctedCount, 4)
        XCTAssertEqual(dictionaryWord.seenUncorrectedCount, 1)
        XCTAssertTrue(dictionaryWord.isAutoLearned)
        XCTAssertFalse(dictionaryWord.isSuppressed)
        XCTAssertFalse(dictionaryWord.spokenIsRealWord)
        XCTAssertEqual(dictionaryWord.lastSeenAt.timeIntervalSince1970, 1_700_000_106, accuracy: 0.001)

        let dictations = store.fetch(FetchDescriptor<DictationEntry>())
        XCTAssertEqual(dictations.count, 1)
        let dictation = try XCTUnwrap(dictations.first)
        XCTAssertEqual(dictation.id, LegacyPersonalizationStoreFixture.Baseline.dictationID)
        XCTAssertEqual(dictation.externalID, "legacy-external-dictation-007")
        XCTAssertEqual(dictation.text, "Unrelated dictation history survives migration.")
        XCTAssertEqual(dictation.appName, "Notes")
        XCTAssertEqual(dictation.bundleId, "com.apple.Notes")
        XCTAssertEqual(dictation.windowTitle, "Migration Notes")
        XCTAssertEqual(dictation.browserURL, "https://example.net/history")
        XCTAssertEqual(dictation.codeFileName, "LegacyFixture.swift")
        XCTAssertEqual(dictation.slackRecipient, "migration-team")
        XCTAssertEqual(dictation.wordCount, 5)
        XCTAssertEqual(dictation.duration, 4.25, accuracy: 0.000_001)
        XCTAssertEqual(dictation.mode, DictationMode.dictation.rawValue)
        XCTAssertEqual(dictation.dictationMode, .dictation)
        XCTAssertEqual(dictation.date.timeIntervalSince1970, 1_700_000_007, accuracy: 0.001)
        XCTAssertEqual(dictation.audioPath, "audio/legacy-fixture.m4a")
        XCTAssertEqual(dictation.rawTranscript, "unrelated dictation history survives migration")
        XCTAssertEqual(dictation.deliveredText, "Unrelated dictation history survives migration.")
        XCTAssertEqual(dictation.selectedText, "previous selection")
        XCTAssertEqual(dictation.autoPasted, true)
        XCTAssertEqual(dictation.copiedToClipboard, false)
        XCTAssertEqual(dictation.autoSent, false)
        XCTAssertEqual(
            dictation.focusedFieldContent,
            "Before unrelated dictation history survives migration."
        )
        XCTAssertEqual(
            dictation.visibleTextSnippetsJSON,
            #"["Migration Notes","Unrelated history"]"#
        )
        XCTAssertEqual(dictation.visibleTextSnippets, ["Migration Notes", "Unrelated history"])
        XCTAssertNil(dictation.vocabularyBoostAuditJSON)
        XCTAssertNil(dictation.vocabularyBoostAuditSummary)

        XCTAssertTrue(store.fetch(FetchDescriptor<MemoEntry>()).isEmpty)
        XCTAssertTrue(store.fetch(FetchDescriptor<JournalDay>()).isEmpty)
        XCTAssertTrue(store.fetch(FetchDescriptor<MeetingEntry>()).isEmpty)
        XCTAssertTrue(store.fetch(FetchDescriptor<AmbientContextSnapshot>()).isEmpty)
        XCTAssertTrue(store.fetch(FetchDescriptor<PersonalizationOutcome>()).isEmpty)
    }

    @MainActor
    func testPunctuationRetirementDeletesOnlyObsoleteGlobalRowsAndIsIdempotent() async throws {
        enum SimulatedFailure: Error { case beforeSave }

        let fixture = try LegacyPersonalizationStoreFixture.makeCopy()
        defer { fixture.remove() }

        do {
            let failing = DataStore(
                storeURLOverride: fixture.storeURL,
                obsoletePunctuationRetirementPreSaveHook: {
                    throw SimulatedFailure.beforeSave
                }
            )
            await failing.setup()

            XCTAssertTrue(failing.isReady, "migration failure must not block normal storage")
            XCTAssertFalse(failing.obsoletePunctuationRetirementCompleted)
            let rows = failing.fetch(FetchDescriptor<LearnedFormatPreference>())
            XCTAssertEqual(rows.count, 2, "the failed delete transaction must roll back")
            XCTAssertTrue(rows.contains {
                $0.id == LegacyPersonalizationStoreFixture.Baseline.punctuationPreferenceID
            })
            XCTAssertTrue(rows.contains {
                $0.id == LegacyPersonalizationStoreFixture.Baseline.wordCasingPreferenceID
            })
        }

        do {
            let retry = DataStore(storeURLOverride: fixture.storeURL)
            await retry.setup()
            XCTAssertTrue(retry.obsoletePunctuationRetirementCompleted)
            XCTAssertEqual(retry.retiredObsoletePunctuationRowCount, 1)
            let rows = retry.fetch(FetchDescriptor<LearnedFormatPreference>())
            XCTAssertEqual(rows.map(\.id), [LegacyPersonalizationStoreFixture.Baseline.wordCasingPreferenceID])
        }

        do {
            let secondRun = DataStore(storeURLOverride: fixture.storeURL)
            await secondRun.setup()
            XCTAssertTrue(secondRun.obsoletePunctuationRetirementCompleted)
            XCTAssertEqual(secondRun.retiredObsoletePunctuationRowCount, 0)
            let rows = secondRun.fetch(FetchDescriptor<LearnedFormatPreference>())
            XCTAssertEqual(rows.map(\.id), [LegacyPersonalizationStoreFixture.Baseline.wordCasingPreferenceID])
            XCTAssertEqual(secondRun.fetch(FetchDescriptor<LearnedContextEntity>()).count, 1)
            XCTAssertEqual(secondRun.fetch(FetchDescriptor<LearnedStyleProfile>()).count, 1)
            XCTAssertEqual(secondRun.fetch(FetchDescriptor<DictationCorrectionEvent>()).count, 1)
            XCTAssertEqual(secondRun.fetch(FetchDescriptor<DictionaryWord>()).count, 1)
            XCTAssertEqual(secondRun.fetch(FetchDescriptor<DictationEntry>()).count, 1)
        }
    }

    @MainActor
    func testPersonalizationOutcomesParticipateInRetentionAndWorkspaceClear() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DataStore(
            storeURLOverride: root.appendingPathComponent("OutcomeLifecycle.store")
        )
        await store.setup()
        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.setupError)

        let now = Date()
        let oldID = UUID()
        let recentID = UUID()
        let oldSaved = await store.save(PersonalizationOutcome(
            deliveryAttemptID: oldID,
            createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60),
            finalizedAt: now.addingTimeInterval(-40 * 24 * 60 * 60),
            status: .excludedCopyOnly,
            readbackMethod: .notApplicable,
            surface: .unknown,
            targetProfile: .unknown,
            readbackEligible: false,
            observable: false,
            exposure: .none
        ))
        let recentSaved = await store.save(PersonalizationOutcome(
            deliveryAttemptID: recentID,
            createdAt: now,
            finalizedAt: now,
            status: .excludedAutoSent,
            readbackMethod: .notApplicable,
            surface: .chat,
            targetProfile: .chat,
            readbackEligible: false,
            observable: false,
            exposure: .none
        ))
        XCTAssertTrue(oldSaved)
        XCTAssertTrue(recentSaved)

        await store.purgeOldEntries(olderThan: 30)
        let retainedIDs = await store.fetchMappedInBackground(
            FetchDescriptor<PersonalizationOutcome>()
        ) { $0.deliveryAttemptID }
        XCTAssertEqual(retainedIDs, [recentID])

        let cleared = await store.clearWorkspaceData()
        XCTAssertTrue(cleared)
        let remainingIDs = await store.fetchMappedInBackground(
            FetchDescriptor<PersonalizationOutcome>()
        ) { $0.deliveryAttemptID }
        XCTAssertTrue(remainingIDs.isEmpty)
    }

    @MainActor
    func testJournalDaysParticipateInRetention() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DataStore(storeURLOverride: root.appendingPathComponent("JournalRetention.store"))
        await store.setup()
        XCTAssertTrue(store.isReady)

        let now = Date()
        let oldID = UUID()
        let recentID = UUID()
        let oldSaved = await store.save(JournalDay(
            id: oldID,
            date: now.addingTimeInterval(-40 * 24 * 60 * 60)
        ))
        let recentSaved = await store.save(JournalDay(id: recentID, date: now))
        XCTAssertTrue(oldSaved)
        XCTAssertTrue(recentSaved)

        await store.purgeOldEntries(olderThan: 30)

        let retainedIDs = await store.fetchMappedInBackground(FetchDescriptor<JournalDay>()) { $0.id }
        XCTAssertEqual(retainedIDs, [recentID])
    }

    @MainActor
    func testOptionalVocabularyBoostAuditPersistsAcrossOnDiskContainerReopen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("AuditMigration.store")
        let schema = Schema([DictationEntry.self])
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: true
        )
        let auditedID = UUID()
        let legacyID = UUID()
        let audit = VocabularyBoostAudit(decisions: [VocabularyBoostAudit.Decision(
            outcome: .applied,
            term: "Codex",
            originalText: "model",
            guarded: false,
            originalWasRealWord: true,
            originalScore: -3.25,
            replacementScore: -1.75,
            similarity: 0.6
        )])

        do {
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            context.insert(DictationEntry(
                id: auditedID,
                text: "Codex",
                appName: "Notes",
                bundleId: "com.apple.Notes",
                wordCount: 1,
                duration: 1,
                mode: .dictation,
                date: Date(),
                vocabularyBoostAuditSummary: VocabularyBoostAuditSummary(audit: audit)
            ))
            context.insert(DictationEntry(
                id: legacyID,
                text: "No audit",
                appName: "Notes",
                bundleId: "com.apple.Notes",
                wordCount: 2,
                duration: 1,
                mode: .dictation,
                date: Date()
            ))
            try context.save()
        }

        do {
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            let entries = try context.fetch(FetchDescriptor<DictationEntry>())
            let audited = try XCTUnwrap(entries.first { $0.id == auditedID })
            let legacy = try XCTUnwrap(entries.first { $0.id == legacyID })
            XCTAssertEqual(audited.vocabularyBoostAuditSummary?.decisions.first?.term, "Codex")
            XCTAssertEqual(audited.vocabularyBoostAuditSummary?.decisions.first?.originalText, "model")
            XCTAssertNil(legacy.vocabularyBoostAuditJSON)
            XCTAssertNil(legacy.vocabularyBoostAuditSummary)
        }
    }

    @MainActor
    func testRecentVocabularyBoostFalseAppliesPersistRespectLookbackAndAreIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("BoostFeedback.store")
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let recentID = UUID()
        let expiredID = UUID()
        let recentAudit = VocabularyBoostAudit(decisions: [
            VocabularyBoostAudit.Decision(
                outcome: .applied,
                term: "Codex",
                originalText: "model",
                guarded: false,
                originalWasRealWord: true,
                originalScore: -3.25,
                replacementScore: -1.75,
                similarity: 0.6
            ),
            VocabularyBoostAudit.Decision(
                outcome: .vetoed,
                term: "Codex",
                originalText: "model",
                guarded: true,
                originalWasRealWord: true,
                originalScore: -3.25,
                replacementScore: -1.75,
                similarity: 0.6
            ),
            VocabularyBoostAudit.Decision(
                outcome: .applied,
                term: "Convex",
                originalText: "context",
                guarded: false,
                originalWasRealWord: true,
                originalScore: -2,
                replacementScore: -1,
                similarity: 0.7
            ),
        ])
        let expiredAudit = VocabularyBoostAudit(decisions: [VocabularyBoostAudit.Decision(
            outcome: .applied,
            term: "Codex",
            originalText: "model",
            guarded: false,
            originalWasRealWord: true,
            originalScore: -3.25,
            replacementScore: -1.75,
            similarity: 0.6
        )])

        var store: Resonant.DataStore? = Resonant.DataStore(storeURLOverride: storeURL)
        await store?.setup()
        XCTAssertTrue(store?.isReady == true)
        let savedRecent = await store?.save(DictationEntry(
            id: recentID,
            text: "Codex and Convex",
            appName: "Notes",
            bundleId: "com.apple.Notes",
            wordCount: 3,
            duration: 1,
            mode: .dictation,
            date: now.addingTimeInterval(-60 * 60),
            vocabularyBoostAuditSummary: VocabularyBoostAuditSummary(audit: recentAudit)
        ))
        let savedExpired = await store?.save(DictationEntry(
            id: expiredID,
            text: "Codex",
            appName: "Notes",
            bundleId: "com.apple.Notes",
            wordCount: 1,
            duration: 1,
            mode: .dictation,
            date: now.addingTimeInterval(-8 * 24 * 60 * 60),
            vocabularyBoostAuditSummary: VocabularyBoostAuditSummary(audit: expiredAudit)
        ))
        XCTAssertEqual(savedRecent, true)
        XCTAssertEqual(savedExpired, true)

        let flagged = await store?.flagRecentVocabularyBoostFalseApplies(
            writtenForm: "  codex ",
            reason: .dictionaryRemoved,
            now: now
        )
        let repeated = await store?.flagRecentVocabularyBoostFalseApplies(
            writtenForm: "Codex",
            reason: .dictionarySuppressed,
            now: now
        )
        XCTAssertEqual(flagged, 1)
        XCTAssertEqual(repeated, 0)

        store = nil
        let reopened = Resonant.DataStore(storeURLOverride: storeURL)
        await reopened.setup()
        XCTAssertTrue(reopened.isReady)
        let persistedRecent = try XCTUnwrap(reopened.dictationEntry(id: recentID))
        let persistedExpired = try XCTUnwrap(reopened.dictationEntry(id: expiredID))
        let recentDecisions = try XCTUnwrap(persistedRecent.vocabularyBoostAuditSummary?.decisions)
        XCTAssertEqual(recentDecisions[0].falseApplyFeedback?.reason, .dictionaryRemoved)
        XCTAssertNil(recentDecisions[1].falseApplyFeedback)
        XCTAssertNil(recentDecisions[2].falseApplyFeedback)
        XCTAssertNil(
            persistedExpired.vocabularyBoostAuditSummary?.decisions.first?.falseApplyFeedback
        )
    }

    @MainActor
    func testRecoveryFetchThrowsWhenStoreIsUnavailable() {
        let store = DataStore()
        XCTAssertThrowsError(
            try store.fetchForRecovery(FetchDescriptor<DictationEntry>())
        )
    }

    @MainActor
    func testClearWorkspaceFailsClosedWhenStoreIsUnavailable() async {
        let store = DataStore()
        let cleared = await store.clearWorkspaceData()
        XCTAssertFalse(cleared)
    }

    @MainActor
    func testSetupIsIdempotentAndKeepsTheReadyContainer() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataStoreSetup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = DataStore(
            storeURLOverride: directoryURL.appendingPathComponent("Resonant.store")
        )
        await store.setup()
        let firstContainer = try XCTUnwrap(store.container)

        await store.setup()

        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.setupError)
        XCTAssertTrue(store.container === firstContainer)
    }

    @MainActor
    func testIdempotentSetupRetriesIncompletePunctuationRetirementWithoutRecreatingContainer() async throws {
        enum SimulatedFailure: Error { case firstSave }

        let fixture = try LegacyPersonalizationStoreFixture.makeCopy()
        defer { fixture.remove() }
        var retirementAttemptCount = 0
        let store = DataStore(
            storeURLOverride: fixture.storeURL,
            obsoletePunctuationRetirementPreSaveHook: {
                retirementAttemptCount += 1
                if retirementAttemptCount == 1 {
                    throw SimulatedFailure.firstSave
                }
            }
        )

        await store.setup()
        let firstContainer = try XCTUnwrap(store.container)
        XCTAssertTrue(store.isReady)
        XCTAssertFalse(store.obsoletePunctuationRetirementCompleted)

        await store.setup()

        XCTAssertTrue(store.container === firstContainer)
        XCTAssertTrue(store.obsoletePunctuationRetirementCompleted)
        XCTAssertEqual(retirementAttemptCount, 2)
        XCTAssertEqual(
            store.fetch(FetchDescriptor<LearnedFormatPreference>()).map(\.categoryRaw),
            ["wordCasing"]
        )
    }

    func testStoreFamilyURLsIncludeMainFileAndSQLiteSidecars() {
        let storeURL = URL(fileURLWithPath: "/tmp/Resonant.store")

        XCTAssertEqual(
            DataStore.storeFamilyURLs(for: storeURL),
            [
                storeURL,
                URL(fileURLWithPath: "/tmp/Resonant.store-shm"),
                URL(fileURLWithPath: "/tmp/Resonant.store-wal"),
            ]
        )
    }

    func testQuarantineCorruptStoreFamilyMovesStoreAndSidecars() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let storeURL = tempDirectory.appendingPathComponent("Resonant.store")
        let storeFamily = DataStore.storeFamilyURLs(for: storeURL)
        for (index, fileURL) in storeFamily.enumerated() {
            try "payload-\(index)".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let backupBaseURL = DataStore.quarantineCorruptStoreFamily(
            at: storeURL,
            fileManager: .default,
            timestamp: 123
        )

        XCTAssertEqual(
            backupBaseURL,
            tempDirectory.appendingPathComponent("Resonant-corrupt-123.store")
        )
        XCTAssertFalse(storeFamily.contains { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupBaseURL!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupBaseURL!.path + "-shm"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupBaseURL!.path + "-wal"))
    }
}
