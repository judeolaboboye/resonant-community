import ApplicationServices
import XCTest
@testable import Resonant

@MainActor
final class CorrectionObserverTests: XCTestCase {
    func testReadbackStatusesOnlyAcceptAcceptedAndCorrectedAsEvaluable() {
        XCTAssertTrue(DictationQualityReadbackStatus.accepted.isEvaluable)
        XCTAssertTrue(DictationQualityReadbackStatus.corrected.isEvaluable)
        XCTAssertFalse(DictationQualityReadbackStatus.stale.isEvaluable)
        XCTAssertFalse(DictationQualityReadbackStatus.bypassed.isEvaluable)
        XCTAssertFalse(DictationQualityReadbackStatus.noFieldContent.isEvaluable)
        XCTAssertFalse(DictationQualityReadbackStatus.regionNotFound.isEvaluable)
        XCTAssertFalse(DictationQualityReadbackStatus.observationReplaced.isEvaluable)
        XCTAssertFalse(DictationQualityReadbackStatus.observationCancelled.isEvaluable)
        XCTAssertFalse(DictationQualityReadbackStatus.autoSent.isEvaluable)
    }

    func testStoreRecoveryDeadlineIsStrictlyLaterThanObserverDeadline() {
        XCTAssertGreaterThan(
            PersonalizationOutcomeStore.defaultMaximumObservationAge,
            CorrectionObserver.defaultMaximumObservationAge
        )
    }

    func testEveryRejectedFinalizationFailsClosedForQualityAndMutation() async {
        let deniedResults: [PersonalizationOutcomeFinalizationResult] = [
            .alreadyFinalized,
            .notFound,
            .invalidStatus,
            .persistenceUnavailable,
            .suspended,
        ]

        for deniedResult in deniedResults {
            let dictionaryStore = DictionaryStore()
            let learningEngine = RecordingLearningEngine()
            var qualityStatuses: [DictationQualityReadbackStatus] = []
            var formatCount = 0
            var suggestionCount = 0
            var boostCount = 0
            let observer = CorrectionObserver(
                dictionaryStore: dictionaryStore,
                pasteManager: PasteManager(),
                personalizationLearningEngine: learningEngine,
                qualityRecorder: { _, status, _, _, _, _ in
                    qualityStatuses.append(status)
                },
                boostCorrelationRecorder: { _ in boostCount += 1 },
                outcomeRecorder: { _ in deniedResult }
            )
            observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }
            observer.learnSuggestionSink = { _ in suggestionCount += 1 }
            let provider = StubAmbientFieldProvider(content: "Codex uses grafanna daily")
            observer.ambientFieldContentProvider = provider

            let started = await observer.observe(
                deliveryOutcome: makeWholeFieldOutcome(
                    pastedText: "Codex uses grafanna daily"
                ),
                targetApp: nil,
                boostAudit: makeAppliedCodexAudit(),
                capabilities: .correctionDerivedMutations,
                appliedStylePolicy: AppliedStylePolicy(openingCase: .lowercase)
            )
            XCTAssertTrue(started, "result: \(deniedResult)")
            provider.content = "Model uses Grafana daily"
            await observer.flushBeforeDictation()

            XCTAssertTrue(qualityStatuses.isEmpty, "result: \(deniedResult)")
            XCTAssertEqual(formatCount, 0, "result: \(deniedResult)")
            XCTAssertEqual(suggestionCount, 0, "result: \(deniedResult)")
            XCTAssertEqual(boostCount, 0, "result: \(deniedResult)")
            XCTAssertTrue(learningEngine.events.isEmpty, "result: \(deniedResult)")
            XCTAssertTrue(
                dictionaryStore.correctionSnapshot().isEmpty,
                "result: \(deniedResult)"
            )
        }
    }

    func testRecoveryExpiryWinsBeforeLateCorrectionAndBlocksEveryMutation() async throws {
        let now = Date(timeIntervalSince1970: 2_500_000_000)
        let attemptID = UUID()
        let (directoryURL, dataStore) = try await makeOutcomeDataStore(
            label: "RecoveryExpiryWins"
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let saved = await dataStore.save(PersonalizationOutcome(
            deliveryAttemptID: attemptID,
            createdAt: now.addingTimeInterval(-11),
            finalizedAt: nil,
            status: .pending,
            readbackMethod: .attributedSnapshot,
            surface: .docs,
            targetProfile: .nativeApp,
            readbackEligible: true,
            observable: false,
            exposure: .none
        ))
        XCTAssertTrue(saved)

        let outcomeStore = PersonalizationOutcomeStore(
            maximumObservationAge: 10,
            clock: PersonalizationOutcomeClock(
                now: { now },
                sleep: PersonalizationOutcomeClock.live.sleep
            )
        )
        let setup = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertEqual(setup.sweptExpiredCount, 1)

        let dictionaryStore = DictionaryStore()
        let learningEngine = RecordingLearningEngine()
        var qualityStatuses: [DictationQualityReadbackStatus] = []
        var formatCount = 0
        var suggestionCount = 0
        var boostCount = 0
        let observer = CorrectionObserver(
            dictionaryStore: dictionaryStore,
            pasteManager: PasteManager(),
            personalizationLearningEngine: learningEngine,
            qualityRecorder: { _, status, _, _, _, _ in
                qualityStatuses.append(status)
            },
            boostCorrelationRecorder: { _ in boostCount += 1 },
            outcomeRecorder: { outcome in
                await outcomeStore.finalize(
                    attemptID: outcome.deliveryAttemptID,
                    with: DeliveryPersonalizationRouter.finalization(for: outcome)
                )
            }
        )
        observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }
        observer.learnSuggestionSink = { _ in suggestionCount += 1 }
        let provider = StubAmbientFieldProvider(content: "Codex uses grafanna daily")
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: makeWholeFieldOutcome(
                pastedText: "Codex uses grafanna daily",
                attemptID: attemptID
            ),
            targetApp: nil,
            boostAudit: makeAppliedCodexAudit(),
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: AppliedStylePolicy(openingCase: .lowercase)
        )
        XCTAssertTrue(started)
        provider.content = "Model uses Grafana daily"
        await observer.flushBeforeDictation()

        let records = await outcomeStore.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.deliveryAttemptID, attemptID)
        XCTAssertEqual(records.first?.status, .stale)
        XCTAssertTrue(qualityStatuses.isEmpty)
        XCTAssertEqual(formatCount, 0)
        XCTAssertEqual(suggestionCount, 0)
        XCTAssertEqual(boostCount, 0)
        XCTAssertTrue(learningEngine.events.isEmpty)
        XCTAssertTrue(dictionaryStore.correctionSnapshot().isEmpty)
        await outcomeStore.quiesceForWorkspaceClear()
    }

    func testObserverFinalizationWinsAndMutatesExactlyOnce() async throws {
        let attemptID = UUID()
        let (directoryURL, dataStore) = try await makeOutcomeDataStore(
            label: "ObserverFinalizationWins"
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let outcomeStore = PersonalizationOutcomeStore()
        let setup = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertTrue(setup.succeeded)
        let registration = await outcomeStore.register(
            makeOutcomeRegistration(attemptID: attemptID)
        )
        XCTAssertEqual(registration, .insertedPending)

        let dictionaryStore = DictionaryStore()
        let learningEngine = RecordingLearningEngine()
        let finalizationBlocker = BlockingOutcomeRecorder()
        var qualityStatuses: [DictationQualityReadbackStatus] = []
        var formatCount = 0
        var boostCount = 0
        let observer = CorrectionObserver(
            dictionaryStore: dictionaryStore,
            pasteManager: PasteManager(),
            personalizationLearningEngine: learningEngine,
            qualityRecorder: { _, status, _, _, _, _ in
                qualityStatuses.append(status)
            },
            boostCorrelationRecorder: { _ in boostCount += 1 },
            outcomeRecorder: { outcome in
                await finalizationBlocker.record()
                return await outcomeStore.finalize(
                    attemptID: outcome.deliveryAttemptID,
                    with: DeliveryPersonalizationRouter.finalization(for: outcome)
                )
            }
        )
        observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }
        let provider = StubAmbientFieldProvider(content: "Codex uses grafanna daily")
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: makeWholeFieldOutcome(
                pastedText: "Codex uses grafanna daily",
                attemptID: attemptID
            ),
            targetApp: nil,
            boostAudit: makeAppliedCodexAudit(),
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: AppliedStylePolicy(openingCase: .lowercase)
        )
        XCTAssertTrue(started)
        provider.content = "Model uses Grafana daily"
        let flush = Task { @MainActor in
            await observer.flushBeforeDictation()
        }
        await finalizationBlocker.waitUntilEntered()

        let pendingRecords = await outcomeStore.records()
        XCTAssertEqual(pendingRecords.map(\.status), [.pending])
        XCTAssertTrue(qualityStatuses.isEmpty)
        XCTAssertEqual(formatCount, 0)
        XCTAssertEqual(boostCount, 0)
        XCTAssertTrue(learningEngine.events.isEmpty)
        XCTAssertTrue(dictionaryStore.correctionSnapshot().isEmpty)

        finalizationBlocker.release()
        await flush.value
        await observer.flushBeforeDictation()

        let records = await outcomeStore.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.deliveryAttemptID, attemptID)
        XCTAssertEqual(records.first?.status, .corrected)
        XCTAssertEqual(qualityStatuses, [.corrected])
        XCTAssertEqual(formatCount, 1)
        XCTAssertEqual(boostCount, 1)
        XCTAssertEqual(learningEngine.events.count, 1)
        XCTAssertTrue(
            dictionaryStore.correctionSnapshot().contains { correction in
                correction.spoken == "grafanna" && correction.written == "Grafana"
            }
        )
        await outcomeStore.quiesceForWorkspaceClear()
    }

    func testObserveRecordsReplacedOutcomeBeforeStartingNextObservation() {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            qualityRecorder: { _, status, pastedText, editedText, correctionCount, observationAgeMs in
                capturedStatuses.append(status)
                XCTAssertNil(pastedText)
                XCTAssertNil(editedText)
                XCTAssertNil(correctionCount)
                XCTAssertNotNil(observationAgeMs)
            }
        )

        observer.observe(pastedText: "first", targetApp: nil)
        observer.observe(pastedText: "second", targetApp: nil)

        XCTAssertEqual(capturedStatuses, [.observationReplaced])
    }

    func testCancelRecordsCancelledOutcomeForPendingObservation() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            qualityRecorder: { _, status, pastedText, editedText, correctionCount, observationAgeMs in
                capturedStatuses.append(status)
                XCTAssertNil(pastedText)
                XCTAssertNil(editedText)
                XCTAssertNil(correctionCount)
                XCTAssertNotNil(observationAgeMs)
            }
        )

        observer.observe(pastedText: "pending", targetApp: nil)
        await observer.cancel()
        await observer.cancel()

        XCTAssertEqual(capturedStatuses, [.observationCancelled])
    }

    func testCancelAndWaitDrainsFlushThroughSuspendedOutcomeCallback() async {
        let blocker = BlockingOutcomeRecorder()
        let completion = CompletionProbe()
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            outcomeRecorder: { _ in
                await blocker.record()
                return .finalized
            }
        )
        let provider = StubAmbientFieldProvider(content: "Alpha beta.")
        observer.ambientFieldContentProvider = provider
        let started = await startSafeObservation(
            observer,
            provider: provider,
            pastedText: "Alpha beta.",
            capabilities: .none
        )
        XCTAssertTrue(started)

        let flush = Task { @MainActor in
            await observer.flushBeforeDictation()
        }
        await blocker.waitUntilEntered()

        let cancellation = Task { @MainActor in
            await observer.cancelAndWait()
            completion.markComplete()
        }
        await observer.waitUntilObservationFlushDrainHasWaiterForTesting()

        XCTAssertEqual(observer.observationFlushDrainWaiterCountForTesting, 1)
        XCTAssertEqual(observer.activeObservationFlushCountForTesting, 1)
        XCTAssertGreaterThan(observer.activeTerminalProcessingCountForTesting, 0)
        XCTAssertFalse(completion.isComplete)

        blocker.release()
        await flush.value
        await cancellation.value

        XCTAssertTrue(completion.isComplete)
        XCTAssertEqual(observer.activeObservationFlushCountForTesting, 0)
        XCTAssertEqual(observer.observationFlushDrainWaiterCountForTesting, 0)
        XCTAssertEqual(observer.activeTerminalProcessingCountForTesting, 0)
        XCTAssertEqual(observer.terminalProcessingDrainWaiterCountForTesting, 0)
    }

    func testCancelAndWaitDrainsDirectValidationOutcomeRecording() async {
        let blocker = BlockingOutcomeRecorder()
        let completion = CompletionProbe()
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            outcomeRecorder: { _ in
                await blocker.record()
                return .finalized
            }
        )
        let invalidOutcome = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            requestedText: "Alpha beta.",
            effectiveInsertedText: "Alpha beta.",
            targetObservedSettledText: "Alpha beta.",
            deliveryAttribution: nil
        )

        let validation = Task { @MainActor in
            await observer.observe(
                deliveryOutcome: invalidOutcome,
                targetApp: nil,
                capabilities: .none,
                appliedStylePolicy: .none
            )
        }
        await blocker.waitUntilEntered()

        let cancellation = Task { @MainActor in
            await observer.cancelAndWait()
            completion.markComplete()
        }
        await observer.waitUntilObservationAdmissionDrainHasWaiterForTesting()

        XCTAssertEqual(observer.observationAdmissionDrainWaiterCountForTesting, 1)
        XCTAssertEqual(observer.activeObservationAdmissionCountForTesting, 1)
        XCTAssertGreaterThan(observer.activeTerminalProcessingCountForTesting, 0)
        XCTAssertFalse(completion.isComplete)

        blocker.release()
        let validationResult = await validation.value
        XCTAssertFalse(validationResult)
        await cancellation.value

        XCTAssertTrue(completion.isComplete)
        XCTAssertEqual(observer.activeObservationAdmissionCountForTesting, 0)
        XCTAssertEqual(observer.observationAdmissionDrainWaiterCountForTesting, 0)
        XCTAssertEqual(observer.activeTerminalProcessingCountForTesting, 0)
        XCTAssertEqual(observer.terminalProcessingDrainWaiterCountForTesting, 0)
    }

    func testCancelAndWaitJoinsCancelledOverwrittenFlushBeforeClearBoundary() async throws {
        let attemptID = UUID()
        let originalText = "Codex uses grafanna daily"
        let correctedText = "Model uses Grafana daily"
        let (directoryURL, dataStore) = try await makeOutcomeDataStore(
            label: "OverwrittenFlushClear"
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let outcomeStore = PersonalizationOutcomeStore()
        let setup = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertTrue(setup.succeeded)
        let registration = await outcomeStore.register(
            makeOutcomeRegistration(attemptID: attemptID)
        )
        XCTAssertEqual(registration, .insertedPending)

        let dictionaryStore = DictionaryStore()
        let learningEngine = RecordingLearningEngine()
        let completion = CompletionProbe()
        var qualityStatuses: [DictationQualityReadbackStatus] = []
        var formatCount = 0
        var boostCount = 0
        let observer = CorrectionObserver(
            dictionaryStore: dictionaryStore,
            pasteManager: PasteManager(),
            personalizationLearningEngine: learningEngine,
            qualityRecorder: { _, status, _, _, _, _ in
                qualityStatuses.append(status)
            },
            boostCorrelationRecorder: { _ in boostCount += 1 },
            outcomeRecorder: { outcome in
                await outcomeStore.finalize(
                    attemptID: outcome.deliveryAttemptID,
                    with: DeliveryPersonalizationRouter.finalization(for: outcome)
                )
            }
        )
        observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }
        let provider = NonCooperativeFlushSnapshotProvider(
            initialContent: originalText,
            terminalContent: correctedText
        )
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: makeWholeFieldOutcome(
                pastedText: originalText,
                attemptID: attemptID
            ),
            targetApp: nil,
            boostAudit: makeAppliedCodexAudit(),
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: .none
        )
        XCTAssertTrue(started)
        await observer.captureProvisionalSampleForTesting()
        XCTAssertEqual(provider.requestCount, 2)

        // Model AppState retaining only one flush handle: A is cancelled and
        // overwritten while its continuation deliberately ignores cancellation.
        var retainedFlushTask: Task<Void, Never>? = Task { @MainActor in
            await observer.flushBeforeDictation()
        }
        await provider.waitUntilTerminalReadBlocked()

        XCTAssertEqual(provider.requestCount, 3)
        XCTAssertEqual(observer.activeObservationFlushCountForTesting, 1)
        XCTAssertNil(observer.pendingDeliveryAttemptIDForTesting)
        XCTAssertFalse(observer.hasOwnedObservationTasksForTesting)

        retainedFlushTask?.cancel()
        retainedFlushTask = Task { @MainActor in
            await observer.flushBeforeDictation()
        }
        if let retainedFlushTask {
            await retainedFlushTask.value
        }
        retainedFlushTask = nil

        // The no-pending replacement flush exits, but cancelled A remains
        // observer-owned until the non-cooperative read actually returns.
        XCTAssertEqual(observer.activeObservationFlushCountForTesting, 1)
        let clear = Task { @MainActor in
            await observer.cancelAndWait()
            completion.markComplete()
        }
        await observer.waitUntilObservationFlushDrainHasWaiterForTesting()

        XCTAssertFalse(completion.isComplete)
        XCTAssertEqual(observer.activeObservationFlushCountForTesting, 1)
        XCTAssertEqual(observer.observationFlushDrainWaiterCountForTesting, 1)
        XCTAssertEqual(observer.activeTerminalProcessingCountForTesting, 0)

        provider.releaseTerminalRead()
        await clear.value

        let records = await outcomeStore.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.deliveryAttemptID, attemptID)
        XCTAssertEqual(records.first?.status, .corrected)
        XCTAssertEqual(qualityStatuses, [.corrected])
        XCTAssertEqual(formatCount, 1)
        XCTAssertEqual(boostCount, 1)
        XCTAssertEqual(learningEngine.events.count, 1)
        XCTAssertTrue(dictionaryStore.correctionSnapshot().contains { correction in
            correction.spoken == "grafanna" && correction.written == "Grafana"
        })

        XCTAssertTrue(completion.isComplete)
        XCTAssertNil(observer.pendingDeliveryAttemptIDForTesting)
        XCTAssertFalse(observer.hasOwnedObservationTasksForTesting)
        XCTAssertEqual(observer.activeObservationFlushCountForTesting, 0)
        XCTAssertEqual(observer.activeObservationAdmissionCountForTesting, 0)
        XCTAssertEqual(observer.activeTerminalProcessingCountForTesting, 0)
        XCTAssertEqual(observer.observationFlushDrainWaiterCountForTesting, 0)
        XCTAssertEqual(observer.observationAdmissionDrainWaiterCountForTesting, 0)
        XCTAssertEqual(observer.terminalProcessingDrainWaiterCountForTesting, 0)

        // Cross the actor's write-suspension boundary and prove no quality or
        // learning sink can run after the observer join has completed.
        let sinkCountsAtClearBoundary = (
            qualityStatuses.count,
            formatCount,
            boostCount,
            learningEngine.events.count,
            dictionaryStore.correctionSnapshot().count
        )
        await outcomeStore.quiesceForWorkspaceClear()
        await outcomeStore.completeWorkspaceClear()
        await observer.cancelAndWait()
        XCTAssertEqual(qualityStatuses.count, sinkCountsAtClearBoundary.0)
        XCTAssertEqual(formatCount, sinkCountsAtClearBoundary.1)
        XCTAssertEqual(boostCount, sinkCountsAtClearBoundary.2)
        XCTAssertEqual(learningEngine.events.count, sinkCountsAtClearBoundary.3)
        XCTAssertEqual(
            dictionaryStore.correctionSnapshot().count,
            sinkCountsAtClearBoundary.4
        )
    }

    func testOlderReceiptAdmissionCannotOverwriteNewerObservationAfterReplacementAwait() async throws {
        let oldAttemptID = UUID()
        let staleCandidateAttemptID = UUID()
        let newestAttemptID = UUID()
        let attemptIDs = [oldAttemptID, staleCandidateAttemptID, newestAttemptID]
        let (directoryURL, dataStore) = try await makeOutcomeDataStore(
            label: "ReceiptAdmissionOrdering"
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let outcomeStore = PersonalizationOutcomeStore()
        let setup = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertTrue(setup.succeeded)
        for attemptID in attemptIDs {
            let registration = await outcomeStore.register(
                makeOutcomeRegistration(attemptID: attemptID)
            )
            XCTAssertEqual(registration, .insertedPending)
        }

        let replacementBlocker = SelectiveOutcomeBlocker(
            blockedAttemptID: oldAttemptID
        )
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            outcomeRecorder: { outcome in
                await replacementBlocker.blockIfNeeded(outcome)
                return await outcomeStore.finalize(
                    attemptID: outcome.deliveryAttemptID,
                    with: DeliveryPersonalizationRouter.finalization(for: outcome)
                )
            }
        )
        let oldFixture = try makeReceiptObservationFixture(text: "old")
        let staleFixture = try makeReceiptObservationFixture(text: "stale candidate")
        let newestFixture = try makeReceiptObservationFixture(text: "newest")

        await observer.observe(
            deliveryReceipt: oldFixture.receipt,
            deliveryAttribution: oldFixture.attribution,
            deliveryAttemptID: oldAttemptID,
            capabilities: .none,
            appliedStylePolicy: .none
        )
        XCTAssertEqual(observer.pendingDeliveryAttemptIDForTesting, oldAttemptID)

        let staleAdmission = Task { @MainActor in
            await observer.observe(
                deliveryReceipt: staleFixture.receipt,
                deliveryAttribution: staleFixture.attribution,
                deliveryAttemptID: staleCandidateAttemptID,
                capabilities: .none,
                appliedStylePolicy: .none
            )
        }
        await replacementBlocker.waitUntilBlocked()

        await observer.observe(
            deliveryReceipt: newestFixture.receipt,
            deliveryAttribution: newestFixture.attribution,
            deliveryAttemptID: newestAttemptID,
            capabilities: .none,
            appliedStylePolicy: .none
        )
        XCTAssertEqual(observer.pendingDeliveryAttemptIDForTesting, newestAttemptID)
        XCTAssertTrue(observer.hasOwnedObservationTasksForTesting)

        replacementBlocker.release()
        await staleAdmission.value

        XCTAssertEqual(observer.pendingDeliveryAttemptIDForTesting, newestAttemptID)
        XCTAssertTrue(observer.hasOwnedObservationTasksForTesting)
        await observer.cancelAndWait()

        let records = await outcomeStore.records()
        let statuses = Dictionary(uniqueKeysWithValues: records.map {
            ($0.deliveryAttemptID, $0.status)
        })
        XCTAssertEqual(records.count, attemptIDs.count)
        XCTAssertEqual(statuses[oldAttemptID], .observationReplaced)
        XCTAssertEqual(statuses[staleCandidateAttemptID], .observationReplaced)
        XCTAssertEqual(statuses[newestAttemptID], .observationCancelled)
        XCTAssertFalse(records.contains { $0.status == .pending })
        XCTAssertNil(observer.pendingDeliveryAttemptIDForTesting)
        XCTAssertFalse(observer.hasOwnedObservationTasksForTesting)
        XCTAssertEqual(observer.activeObservationAdmissionCountForTesting, 0)
        await outcomeStore.quiesceForWorkspaceClear()
    }

    func testBlockedSnapshotAdmissionCannotReplaceNewerReceiptObservation() async throws {
        let staleSnapshotAttemptID = UUID()
        let newestReceiptAttemptID = UUID()
        let attemptIDs = [staleSnapshotAttemptID, newestReceiptAttemptID]
        let (directoryURL, dataStore) = try await makeOutcomeDataStore(
            label: "SnapshotAdmissionOrdering"
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let outcomeStore = PersonalizationOutcomeStore()
        let setup = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertTrue(setup.succeeded)
        for attemptID in attemptIDs {
            let registration = await outcomeStore.register(
                makeOutcomeRegistration(attemptID: attemptID)
            )
            XCTAssertEqual(registration, .insertedPending)
        }

        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            outcomeRecorder: { outcome in
                await outcomeStore.finalize(
                    attemptID: outcome.deliveryAttemptID,
                    with: DeliveryPersonalizationRouter.finalization(for: outcome)
                )
            }
        )
        let snapshotProvider = BlockingSnapshotProvider(content: "snapshot candidate")
        observer.ambientFieldContentProvider = snapshotProvider
        let receiptFixture = try makeReceiptObservationFixture(text: "newest receipt")

        let staleAdmission = Task { @MainActor in
            await observer.observe(
                deliveryOutcome: makeWholeFieldOutcome(
                    pastedText: "snapshot candidate",
                    attemptID: staleSnapshotAttemptID
                ),
                targetApp: nil,
                capabilities: .none,
                appliedStylePolicy: .none
            )
        }
        await snapshotProvider.waitUntilBlocked()

        await observer.observe(
            deliveryReceipt: receiptFixture.receipt,
            deliveryAttribution: receiptFixture.attribution,
            deliveryAttemptID: newestReceiptAttemptID,
            capabilities: .none,
            appliedStylePolicy: .none
        )
        XCTAssertEqual(observer.pendingDeliveryAttemptIDForTesting, newestReceiptAttemptID)

        snapshotProvider.release()
        let staleAdmissionStarted = await staleAdmission.value
        XCTAssertFalse(staleAdmissionStarted)
        XCTAssertEqual(observer.pendingDeliveryAttemptIDForTesting, newestReceiptAttemptID)
        XCTAssertTrue(observer.hasOwnedObservationTasksForTesting)
        await observer.cancelAndWait()

        let records = await outcomeStore.records()
        let statuses = Dictionary(uniqueKeysWithValues: records.map {
            ($0.deliveryAttemptID, $0.status)
        })
        XCTAssertEqual(records.count, attemptIDs.count)
        XCTAssertEqual(statuses[staleSnapshotAttemptID], .observationReplaced)
        XCTAssertEqual(statuses[newestReceiptAttemptID], .observationCancelled)
        XCTAssertFalse(records.contains { $0.status == .pending })
        XCTAssertNil(observer.pendingDeliveryAttemptIDForTesting)
        XCTAssertFalse(observer.hasOwnedObservationTasksForTesting)
        XCTAssertEqual(observer.activeObservationAdmissionCountForTesting, 0)
        await outcomeStore.quiesceForWorkspaceClear()
    }

    func testCancelAndWaitInvalidatesAndJoinsBlockedSnapshotAdmission() async throws {
        let attemptID = UUID()
        let (directoryURL, dataStore) = try await makeOutcomeDataStore(
            label: "SnapshotAdmissionClear"
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let outcomeStore = PersonalizationOutcomeStore()
        let setup = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertTrue(setup.succeeded)
        let registration = await outcomeStore.register(
            makeOutcomeRegistration(attemptID: attemptID)
        )
        XCTAssertEqual(registration, .insertedPending)

        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            outcomeRecorder: { outcome in
                await outcomeStore.finalize(
                    attemptID: outcome.deliveryAttemptID,
                    with: DeliveryPersonalizationRouter.finalization(for: outcome)
                )
            }
        )
        let snapshotProvider = BlockingSnapshotProvider(content: "blocked admission")
        observer.ambientFieldContentProvider = snapshotProvider
        let completion = CompletionProbe()

        let admission = Task { @MainActor in
            await observer.observe(
                deliveryOutcome: makeWholeFieldOutcome(
                    pastedText: "blocked admission",
                    attemptID: attemptID
                ),
                targetApp: nil,
                capabilities: .none,
                appliedStylePolicy: .none
            )
        }
        await snapshotProvider.waitUntilBlocked()
        XCTAssertEqual(observer.activeObservationAdmissionCountForTesting, 1)

        let cancellation = Task { @MainActor in
            await observer.cancelAndWait()
            completion.markComplete()
        }
        await observer.waitUntilObservationAdmissionDrainHasWaiterForTesting()

        XCTAssertFalse(completion.isComplete)
        XCTAssertEqual(observer.observationAdmissionDrainWaiterCountForTesting, 1)
        XCTAssertNil(observer.pendingDeliveryAttemptIDForTesting)
        XCTAssertFalse(observer.hasOwnedObservationTasksForTesting)

        snapshotProvider.release()
        let admissionStarted = await admission.value
        XCTAssertFalse(admissionStarted)
        await cancellation.value

        let records = await outcomeStore.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.deliveryAttemptID, attemptID)
        XCTAssertEqual(records.first?.status, .observationReplaced)
        XCTAssertTrue(completion.isComplete)
        XCTAssertEqual(observer.activeObservationAdmissionCountForTesting, 0)
        XCTAssertEqual(observer.observationAdmissionDrainWaiterCountForTesting, 0)
        XCTAssertNil(observer.pendingDeliveryAttemptIDForTesting)
        XCTAssertFalse(observer.hasOwnedObservationTasksForTesting)
        await outcomeStore.quiesceForWorkspaceClear()
    }

    func testPendingObservationCompatibilityInitializerFailsClosed() {
        XCTAssertEqual(
            makeObservation(pastedText: "alpha beta").capabilities,
            .none
        )
    }

    // MARK: - Ambient fallback

    @MainActor
    private final class StubAmbientFieldProvider: AmbientFieldContentProviding {
        var content: String?
        var processIdentifier: pid_t = 42
        var bundleIdentifier: String? = "com.example.editor"
        var targetFingerprint: ContextTargetFingerprint? = CorrectionObserverTests.fingerprint()
        private(set) var requestCount = 0

        init(content: String?) {
            self.content = content
        }

        func currentFieldContent(for app: NSRunningApplication?) async -> String? {
            requestCount += 1
            return content
        }

        func correctionHotSnapshot(
            for app: NSRunningApplication?
        ) async -> CorrectionHotSnapshot? {
            requestCount += 1
            guard let content else { return nil }
            return CorrectionHotSnapshot(
                fullFieldContent: content,
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                isSensitiveInput: targetFingerprint?.isSensitiveInput,
                targetFingerprint: targetFingerprint
            )
        }
    }

    @MainActor
    private final class SuspendingAmbientFieldProvider: AmbientFieldContentProviding {
        private(set) var requestCount = 0
        private var suspendedContinuation: CheckedContinuation<String?, Never>?

        func currentFieldContent(for app: NSRunningApplication?) async -> String? {
            requestCount += 1
            if requestCount == 2 {
                return await withCheckedContinuation { continuation in
                    suspendedContinuation = continuation
                }
            }
            return "Alpha beta!"
        }

        func correctionHotSnapshot(
            for app: NSRunningApplication?
        ) async -> CorrectionHotSnapshot? {
            requestCount += 1
            if requestCount == 2 {
                let content = await withCheckedContinuation { continuation in
                    suspendedContinuation = continuation
                }
                guard let content else { return nil }
                return Self.snapshot(content)
            }
            return Self.snapshot(requestCount == 1 ? "Alpha beta." : "Alpha beta!")
        }

        func resumeSuspendedReadback() {
            suspendedContinuation?.resume(returning: "Alpha beta!")
            suspendedContinuation = nil
        }

        private static func snapshot(_ content: String) -> CorrectionHotSnapshot {
            CorrectionHotSnapshot(
                fullFieldContent: content,
                processIdentifier: 42,
                bundleIdentifier: "com.example.editor",
                isSensitiveInput: false,
                targetFingerprint: CorrectionObserverTests.fingerprint()
            )
        }
    }

    @MainActor
    private final class BlockingSnapshotProvider: AmbientFieldContentProviding {
        private let content: String
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private(set) var didBlock = false

        init(content: String) {
            self.content = content
        }

        func correctionHotSnapshot(
            for app: NSRunningApplication?
        ) async -> CorrectionHotSnapshot? {
            didBlock = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            return CorrectionHotSnapshot(
                fullFieldContent: content,
                processIdentifier: 42,
                bundleIdentifier: "com.example.editor",
                isSensitiveInput: false,
                targetFingerprint: CorrectionObserverTests.fingerprint()
            )
        }

        func waitUntilBlocked() async {
            guard !didBlock else { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    /// The first read establishes the no-receipt baseline and the second seeds
    /// a provisional digest. The third models production's detached AX
    /// extraction: caller cancellation does not resume or abort it, so only the
    /// explicit release can finish flush A.
    @MainActor
    private final class NonCooperativeFlushSnapshotProvider: AmbientFieldContentProviding {
        private let initialContent: String
        private let terminalContent: String
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private(set) var requestCount = 0
        private(set) var terminalReadIsBlocked = false

        init(initialContent: String, terminalContent: String) {
            self.initialContent = initialContent
            self.terminalContent = terminalContent
        }

        func correctionHotSnapshot(
            for app: NSRunningApplication?
        ) async -> CorrectionHotSnapshot? {
            requestCount += 1
            if requestCount == 3 {
                terminalReadIsBlocked = true
                let waiters = entryWaiters
                entryWaiters.removeAll()
                waiters.forEach { $0.resume() }
                // Deliberately do not inspect Task.isCancelled.
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
            return Self.snapshot(
                requestCount <= 2 ? initialContent : terminalContent
            )
        }

        func waitUntilTerminalReadBlocked() async {
            guard !terminalReadIsBlocked else { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func releaseTerminalRead() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }

        private static func snapshot(_ content: String) -> CorrectionHotSnapshot {
            CorrectionHotSnapshot(
                fullFieldContent: content,
                processIdentifier: 42,
                bundleIdentifier: "com.example.editor",
                isSensitiveInput: false,
                targetFingerprint: CorrectionObserverTests.fingerprint()
            )
        }
    }

    @MainActor
    private final class SelectiveOutcomeBlocker {
        private let blockedAttemptID: UUID
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private(set) var didBlock = false

        init(blockedAttemptID: UUID) {
            self.blockedAttemptID = blockedAttemptID
        }

        func blockIfNeeded(_ outcome: CorrectionObservationOutcome) async {
            guard outcome.deliveryAttemptID == blockedAttemptID, !didBlock else {
                return
            }
            didBlock = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilBlocked() async {
            guard !didBlock else { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    @MainActor
    private final class RecordingLearningEngine: PersonalizationLearningEngine {
        private(set) var events: [DictationFeedbackEvent] = []

        func snapshot(for surface: SurfaceDescriptor) -> PersonalizationMemorySnapshot {
            .empty
        }

        func profile(for surface: SurfaceDescriptor) -> VersionedPersonalizationProfile {
            PersonalizationProfileBuilder.build(
                surface: surface,
                snapshot: .empty,
                styleSampleCount: 0,
                seed: "correction-observer-tests",
                holdoutRate: 0
            )
        }

        func recordFeedback(_ event: DictationFeedbackEvent) async {
            events.append(event)
        }
    }

    @MainActor
    private final class BlockingOutcomeRecorder {
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private(set) var didEnter = false

        func record() async {
            didEnter = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilEntered() async {
            guard !didEnter else { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    @MainActor
    private final class CompletionProbe {
        private(set) var isComplete = false

        func markComplete() {
            isComplete = true
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

    private struct ReceiptObservationFixture {
        let receipt: PasteManager.DeliveryReceipt
        let attribution: PasteManager.DeliveryAttribution
    }

    private func makeReceiptObservationFixture(
        text: String
    ) throws -> ReceiptObservationFixture {
        let baseline = "prefix old suffix"
        let selectedRange = (baseline as NSString).range(of: "old")
        let postDeliveryField = (baseline as NSString).replacingCharacters(
            in: selectedRange,
            with: text
        )
        let insertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: baseline,
            selectedRange: SelectionRange(
                location: selectedRange.location,
                length: selectedRange.length
            ),
            postDeliveryValue: postDeliveryField
        ))
        let attribution = try XCTUnwrap(PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetFingerprint: Self.fingerprint(),
            anchor: insertion.anchor,
            preDeliveryFieldUTF16Length: (baseline as NSString).length
        ))
        let receipt = PasteManager.DeliveryReceipt(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetObservedInsertedText: text,
            anchor: insertion.anchor,
            element: AXUIElementCreateSystemWide(),
            windowTitle: nil,
            browserURL: nil
        )
        return ReceiptObservationFixture(
            receipt: receipt,
            attribution: attribution
        )
    }

    @discardableResult
    private func startSafeObservation(
        _ observer: CorrectionObserver,
        provider: StubAmbientFieldProvider,
        pastedText: String,
        capabilities: LearningCapabilities = .correctionDerivedMutations,
        boostAudit: VocabularyBoostAudit? = nil
    ) async -> Bool {
        provider.content = pastedText
        return await observer.observe(
            deliveryOutcome: makeWholeFieldOutcome(pastedText: pastedText),
            targetApp: nil,
            boostAudit: boostAudit,
            capabilities: capabilities,
            appliedStylePolicy: .none
        )
    }

    private func makeWholeFieldOutcome(
        pastedText: String,
        attemptID: UUID = UUID()
    ) -> PasteManager.DeliveryOutcome {
        let insertion = PasteManager.makeUTF16InsertionAnchor(
            baselineValue: "",
            selectedRange: nil,
            postDeliveryValue: pastedText
        )!
        let attribution = PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetFingerprint: Self.fingerprint(),
            anchor: insertion.anchor,
            preDeliveryFieldUTF16Length: 0
        )!
        let outcome = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            deliveryAttemptID: attemptID,
            effectiveInsertedText: pastedText,
            targetObservedSettledText: pastedText,
            deliveryAttribution: attribution
        )
        return outcome
    }

    private func makeAppliedCodexAudit() -> VocabularyBoostAudit {
        VocabularyBoostAudit(decisions: [
            VocabularyBoostAudit.Decision(
                outcome: .applied,
                term: "Codex",
                originalText: "code ex",
                guarded: false,
                originalWasRealWord: false,
                originalScore: 0,
                replacementScore: 1,
                similarity: 1
            )
        ])
    }

    private func makeOutcomeRegistration(
        attemptID: UUID
    ) -> PersonalizationOutcomeRegistration {
        PersonalizationOutcomeRegistration(
            deliveryAttemptID: attemptID,
            routeFacts: PersonalizationDeliveryRouteFacts(
                delivered: true,
                partiallyDelivered: false,
                autoPasted: true,
                autoSent: false,
                copiedToClipboard: false,
                selectionTransformUsed: false
            ),
            readbackMethod: .attributedSnapshot,
            surface: .docs,
            targetProfile: .nativeApp,
            exposure: .none
        )
    }

    private func makeOutcomeDataStore(
        label: String
    ) async throws -> (URL, Resonant.DataStore) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let dataStore = Resonant.DataStore(
            storeURLOverride: directoryURL.appendingPathComponent("Resonant.store")
        )
        await dataStore.setup()
        XCTAssertTrue(dataStore.isReady)
        XCTAssertNil(dataStore.setupError)
        return (directoryURL, dataStore)
    }

    private static func fingerprint(
        selectedRange: String? = "0:0"
    ) -> ContextTargetFingerprint {
        ContextTargetFingerprint(
            role: "AXTextArea",
            subrole: "AXStandardTextArea",
            isSensitiveInput: false,
            identifierToken: "field-id",
            titleToken: "title-token",
            descriptionToken: "description-token",
            placeholderToken: "placeholder-token",
            helpToken: "help-token",
            frameBucket: "1:2:3:4",
            selectedRangeBucket: selectedRange
        )
    }

    func testContentOnlyAmbientFallbackFailsClosed() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        var capturedEditedText: String?
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            qualityRecorder: { _, status, _, editedText, _, _ in
                capturedStatuses.append(status)
                capturedEditedText = editedText
            }
        )
        let provider = StubAmbientFieldProvider(content: "ask John Smythe about it")
        observer.ambientFieldContentProvider = provider

        await observer.processWithAmbientFallback(
            makeObservation(pastedText: "ask jon smythe about it"),
            fallbackStatus: .bypassed
        )

        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertEqual(capturedStatuses, [.regionNotFound])
        XCTAssertNil(capturedEditedText)
    }

    func testAttributedHotSnapshotRecordsAcceptedWhenTextUnchanged() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            },
            outcomeRecorder: { _ in .finalized }
        )
        let provider = StubAmbientFieldProvider(content: "exactly what was pasted")
        observer.ambientFieldContentProvider = provider

        let started = await startSafeObservation(
            observer,
            provider: provider,
            pastedText: "exactly what was pasted",
            capabilities: .none
        )
        XCTAssertTrue(started)
        await observer.flushBeforeDictation()

        XCTAssertEqual(capturedStatuses, [.accepted])
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testAmbientFallbackFallsThroughToOriginalStatus() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            }
        )
        let provider = StubAmbientFieldProvider(content: nil)
        observer.ambientFieldContentProvider = provider

        await observer.processWithAmbientFallback(
            makeObservation(pastedText: "anything"),
            fallbackStatus: .bypassed
        )

        XCTAssertEqual(capturedStatuses, [.regionNotFound])
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testAmbientFallbackWithoutProviderRecordsOriginalStatus() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            }
        )

        await observer.processWithAmbientFallback(
            makeObservation(pastedText: "anything"),
            fallbackStatus: .noFieldContent
        )

        XCTAssertEqual(capturedStatuses, [.regionNotFound])
    }

    func testAnchoredRegionRequiresClosedBoundariesOrExplicitWholeFieldOwnership() throws {
        let baseline = "prefix old suffix"
        let oldRange = (baseline as NSString).range(of: "old")
        let closedInsertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: baseline,
            selectedRange: SelectionRange(
                location: oldRange.location,
                length: oldRange.length
            ),
            postDeliveryValue: "prefix hello suffix"
        ))

        XCTAssertEqual(
            CorrectionObserver.evaluableAnchoredRegion(
                original: "hello",
                fieldContent: "prefix hullo suffix",
                anchor: closedInsertion.anchor,
                ownership: .closedBoundaries
            ),
            "hullo"
        )

        let openInsertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: "prefix ",
            selectedRange: nil,
            postDeliveryValue: "prefix hello"
        ))
        XCTAssertFalse(openInsertion.anchor.hasClosedBoundaries)
        XCTAssertEqual(
            CorrectionObserver.evaluableAnchoredRegion(
                original: "hello",
                fieldContent: "prefix hello",
                anchor: openInsertion.anchor,
                ownership: .weakOpenBoundary
            ),
            "hello"
        )
        XCTAssertNil(CorrectionObserver.evaluableAnchoredRegion(
            original: "hello",
            fieldContent: "prefix hullo",
            anchor: openInsertion.anchor,
            ownership: .weakOpenBoundary
        ))
        XCTAssertNil(CorrectionObserver.evaluableAnchoredRegion(
            original: "hello",
            fieldContent: "prefix hello continued suffix",
            anchor: closedInsertion.anchor,
            ownership: .closedBoundaries
        ))

        let rewriteInsertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: "prefix old words suffix",
            selectedRange: SelectionRange(location: 7, length: 9),
            postDeliveryValue: "prefix ship now suffix"
        ))
        XCTAssertNil(CorrectionObserver.evaluableAnchoredRegion(
            original: "ship now",
            fieldContent: "prefix wait here suffix",
            anchor: rewriteInsertion.anchor,
            ownership: .closedBoundaries
        ))

        let wholeFieldBaseline = "replace me"
        let wholeFieldInsertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: wholeFieldBaseline,
            selectedRange: SelectionRange(
                location: 0,
                length: (wholeFieldBaseline as NSString).length
            ),
            postDeliveryValue: "hello"
        ))
        let wholeFieldAttribution = try XCTUnwrap(PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetFingerprint: Self.fingerprint(),
            anchor: wholeFieldInsertion.anchor,
            preDeliveryFieldUTF16Length: (wholeFieldBaseline as NSString).length
        ))
        let wholeFieldOwnership = CorrectionObserver.receiptRegionOwnership(
            anchor: wholeFieldInsertion.anchor,
            deliveryAttribution: wholeFieldAttribution
        )
        XCTAssertEqual(wholeFieldOwnership, .explicitlyOwnedWholeField)
        XCTAssertEqual(
            CorrectionObserver.evaluableAnchoredRegion(
                original: "hello",
                fieldContent: "hullo",
                anchor: wholeFieldInsertion.anchor,
                ownership: wholeFieldOwnership
            ),
            "hullo"
        )
        XCTAssertEqual(
            CorrectionObserver.receiptRegionOwnership(
                anchor: openInsertion.anchor,
                deliveryAttribution: PasteManager.makeDeliveryAttribution(
                    targetProcessIdentifier: 42,
                    targetBundleIdentifier: "com.example.editor",
                    targetFingerprint: Self.fingerprint(),
                    anchor: openInsertion.anchor,
                    preDeliveryFieldUTF16Length: ("prefix " as NSString).length
                )
            ),
            .weakOpenBoundary
        )
    }

    func testPendingObservationActuallyExpiresWithoutRetainingReadback() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            readbackDelay: .seconds(1),
            maximumObservationAge: 0.02,
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            }
        )

        observer.observe(pastedText: "private field content", targetApp: nil)
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(capturedStatuses, [.stale])
    }

    func testStaleExpiryReadbackCannotClearReplacementObservation() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            readbackDelay: .milliseconds(30),
            maximumObservationAge: 0.05,
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            },
            outcomeRecorder: { _ in .finalized }
        )
        let provider = SuspendingAmbientFieldProvider()
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: makeWholeFieldOutcome(pastedText: "Alpha beta."),
            targetApp: nil,
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: .none
        )
        XCTAssertTrue(started)
        for _ in 0..<100 where provider.requestCount < 2 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        guard provider.requestCount == 2 else {
            XCTFail("Expected expiry readback to suspend")
            return
        }

        observer.observe(pastedText: "Replacement observation", targetApp: nil)
        provider.resumeSuspendedReadback()
        try? await Task.sleep(for: .milliseconds(5))
        await observer.cancel()

        XCTAssertEqual(capturedStatuses, [.observationReplaced, .observationCancelled])
    }

    func testReceiptReadbackNeverFallsBackToAmbientOrFocusedField() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            }
        )
        let provider = StubAmbientFieldProvider(content: "unrelated focused field")
        observer.ambientFieldContentProvider = provider
        let receipt = PasteManager.DeliveryReceipt(
            targetProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            targetBundleIdentifier: nil,
            targetObservedInsertedText: "dictated text",
            anchor: PasteManager.UTF16InsertionAnchor(
                replacedRange: SelectionRange(location: 0, length: 0),
                prefix: "",
                suffix: ""
            ),
            element: AXUIElementCreateSystemWide(),
            windowTitle: nil,
            browserURL: nil
        )

        observer.observe(deliveryReceipt: receipt)
        await observer.flushBeforeDictation()

        XCTAssertEqual(capturedStatuses, [.bypassed])
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testTimerReadbackIsProvisionalAndTerminalFlushReadsFreshText() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let learningEngine = RecordingLearningEngine()
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            personalizationLearningEngine: learningEngine,
            readbackDelay: .milliseconds(40),
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            },
            outcomeRecorder: { _ in .finalized }
        )
        let provider = StubAmbientFieldProvider(content: "Alpha beta.")
        observer.ambientFieldContentProvider = provider

        let started = await startSafeObservation(
            observer,
            provider: provider,
            pastedText: "Alpha beta."
        )
        XCTAssertTrue(started)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(capturedStatuses.isEmpty)
        XCTAssertEqual(learningEngine.events.count, 0)
        XCTAssertEqual(provider.requestCount, 2)

        provider.content = "Alpha beta!"
        await observer.flushBeforeDictation()

        XCTAssertEqual(provider.requestCount, 3)
        XCTAssertEqual(capturedStatuses, [.corrected])
        XCTAssertEqual(learningEngine.events.first?.editedText, "Alpha beta!")
        XCTAssertTrue(learningEngine.events.first?.wasEdited == true)
    }

    func testStableDigestSamplesFinalizeStandaloneCorrectionAtExpiry() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let learningEngine = RecordingLearningEngine()
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            personalizationLearningEngine: learningEngine,
            readbackDelay: .milliseconds(15),
            maximumObservationAge: 0.09,
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            },
            outcomeRecorder: { _ in .finalized }
        )
        let provider = StubAmbientFieldProvider(content: "Alpha beta.")
        observer.ambientFieldContentProvider = provider

        let started = await startSafeObservation(
            observer,
            provider: provider,
            pastedText: "Alpha beta."
        )
        XCTAssertTrue(started)
        provider.content = "Alpha beta!"
        try? await Task.sleep(for: .milliseconds(140))

        XCTAssertEqual(capturedStatuses, [.corrected])
        XCTAssertEqual(learningEngine.events.first?.editedText, "Alpha beta!")
        XCTAssertGreaterThanOrEqual(provider.requestCount, 4)
    }

    func testStableReceiptDigestAllowsExplicitWholeFieldOwnedCorrectionOnNextDictation() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let fieldContent = "hullo"
        let fingerprint = Self.fingerprint()
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            readbackDelay: .milliseconds(15),
            receiptReadback: { _ in
                CorrectionReceiptSnapshot(
                    fullFieldContent: fieldContent,
                    processIdentifier: 42,
                    bundleIdentifier: "com.example.editor",
                    isSensitiveInput: false,
                    targetFingerprint: fingerprint
                )
            },
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            }
        )
        let receipt = PasteManager.DeliveryReceipt(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetObservedInsertedText: "hello",
            anchor: PasteManager.UTF16InsertionAnchor(
                replacedRange: SelectionRange(location: 0, length: 0),
                prefix: "",
                suffix: ""
            ),
            element: AXUIElementCreateSystemWide(),
            windowTitle: nil,
            browserURL: nil
        )
        let attribution = PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetFingerprint: fingerprint,
            anchor: receipt.anchor,
            preDeliveryFieldUTF16Length: 0
        )
        XCTAssertEqual(attribution?.wholeFieldOwned, true)
        XCTAssertEqual(
            CorrectionObserver.receiptRegionOwnership(
                anchor: receipt.anchor,
                deliveryAttribution: attribution
            ),
            .explicitlyOwnedWholeField
        )

        observer.observe(
            deliveryReceipt: receipt,
            deliveryAttribution: attribution
        )
        try? await Task.sleep(for: .milliseconds(25))
        await observer.flushBeforeDictation()

        XCTAssertEqual(fieldContent, "hullo")
        XCTAssertEqual(capturedStatuses, [.corrected])
    }

    func testLateEditFinalizesEarlyOnceFieldStabilizes() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let learningEngine = RecordingLearningEngine()
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            personalizationLearningEngine: learningEngine,
            readbackDelay: .milliseconds(20),
            maximumObservationAge: 0.4,
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            },
            outcomeRecorder: { _ in .finalized }
        )
        let provider = StubAmbientFieldProvider(content: "Alpha beta.")
        observer.ambientFieldContentProvider = provider

        let started = await startSafeObservation(
            observer,
            provider: provider,
            pastedText: "Alpha beta."
        )
        XCTAssertTrue(started)

        // Let the first sample capture the unedited field, then edit.
        try? await Task.sleep(for: .milliseconds(60))
        provider.content = "Alpha beta!"

        // Two stable samples after the change should finalize well before the
        // 400ms horizon.
        for _ in 0..<100 where capturedStatuses.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(capturedStatuses, [.corrected])
        XCTAssertEqual(learningEngine.events.first?.editedText, "Alpha beta!")

        // Expiry must not double-fire afterwards.
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(capturedStatuses, [.corrected])
    }

    func testNearMissNameFeedsSuggestionSinkNotDictionary() async {
        let dictionaryStore = DictionaryStore()
        let observer = CorrectionObserver(
            dictionaryStore: dictionaryStore,
            pasteManager: PasteManager(),
            outcomeRecorder: { _ in .finalized }
        )
        var suggestions: [CorrectionDiffEngine.Candidate] = []
        observer.learnSuggestionSink = { suggestions.append($0) }

        let provider = StubAmbientFieldProvider(content: "I met teece today")
        observer.ambientFieldContentProvider = provider

        let started = await startSafeObservation(
            observer,
            provider: provider,
            pastedText: "I met teece today"
        )
        XCTAssertTrue(started)
        provider.content = "I met Thijs today"
        await observer.flushBeforeDictation()

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.spoken, "teece")
        XCTAssertEqual(suggestions.first?.written, "Thijs")
        XCTAssertFalse(dictionaryStore.hasEntry(spoken: "teece"))
    }

    func testSuggestionSinkSkipsPairsAlreadyTracked() async {
        let dictionaryStore = DictionaryStore()
        dictionaryStore.declineSuggestion(spoken: "teece", written: "Thijs")
        let observer = CorrectionObserver(
            dictionaryStore: dictionaryStore,
            pasteManager: PasteManager(),
            outcomeRecorder: { _ in .finalized }
        )
        var suggestionCount = 0
        observer.learnSuggestionSink = { _ in suggestionCount += 1 }

        let provider = StubAmbientFieldProvider(content: "I met teece today")
        observer.ambientFieldContentProvider = provider

        let started = await startSafeObservation(
            observer,
            provider: provider,
            pastedText: "I met teece today"
        )
        XCTAssertTrue(started)
        provider.content = "I met Thijs today"
        await observer.flushBeforeDictation()

        XCTAssertEqual(suggestionCount, 0)
    }

    func testChangedTextWithNoSafeWordPairIsCorrectedWithoutNegativeReinforcement() async {
        var capturedStatuses: [DictationQualityReadbackStatus] = []
        let dictionaryStore = DictionaryStore()
        dictionaryStore.recordAutoCorrection(
            spoken: "grafanna",
            written: "Grafana",
            spokenIsRealWord: false,
            writtenIsProperNoun: true
        )
        XCTAssertTrue(dictionaryStore.correctionSnapshot().contains { $0.spoken == "grafanna" })

        let learningEngine = RecordingLearningEngine()
        let observer = CorrectionObserver(
            dictionaryStore: dictionaryStore,
            pasteManager: PasteManager(),
            personalizationLearningEngine: learningEngine,
            qualityRecorder: { _, status, _, _, _, _ in
                capturedStatuses.append(status)
            },
            outcomeRecorder: { _ in .finalized }
        )
        let provider = StubAmbientFieldProvider(content: "grafanna grafanna.")
        observer.ambientFieldContentProvider = provider

        let started = await startSafeObservation(
            observer,
            provider: provider,
            pastedText: "grafanna grafanna."
        )
        XCTAssertTrue(started)
        provider.content = "grafanna grafanna!"
        await observer.flushBeforeDictation()

        XCTAssertEqual(capturedStatuses, [.corrected])
        XCTAssertEqual(learningEngine.events.first?.corrections, [])
        XCTAssertTrue(learningEngine.events.first?.wasEdited == true)
        XCTAssertTrue(dictionaryStore.correctionSnapshot().contains { $0.spoken == "grafanna" })
    }
}
