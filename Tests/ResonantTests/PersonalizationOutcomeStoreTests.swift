import Foundation
import SwiftData
import XCTest
@testable import Resonant

@MainActor
final class PersonalizationOutcomeStoreTests: XCTestCase {
    private struct Harness {
        let directoryURL: URL
        let dataStore: Resonant.DataStore
        let outcomeStore: PersonalizationOutcomeStore
    }

    func testDeliveryRouteClassifierTruthTable() {
        let cases: [(
            facts: PersonalizationDeliveryRouteFacts,
            expected: PersonalizationOutcomeRouteClassification
        )] = [
            (
                Self.facts(
                    delivered: false,
                    partiallyDelivered: false,
                    autoPasted: false
                ),
                .terminalExcluded(.excludedDeliveryFailed)
            ),
            (
                Self.facts(
                    delivered: false,
                    partiallyDelivered: true,
                    autoPasted: false
                ),
                .terminalExcluded(.excludedPartialDelivery)
            ),
            (
                Self.facts(delivered: true, autoPasted: false, copiedToClipboard: true),
                .terminalExcluded(.excludedCopyOnly)
            ),
            (
                Self.facts(delivered: true, autoPasted: true, autoSent: true),
                .terminalExcluded(.excludedAutoSent)
            ),
            (
                Self.facts(delivered: true, autoPasted: true, selectionTransformUsed: true),
                .terminalExcluded(.excludedSelectionTransform)
            ),
            (
                Self.facts(
                    delivered: true,
                    autoPasted: true,
                    autoSent: true,
                    selectionTransformUsed: true
                ),
                .terminalExcluded(.excludedSelectionTransform)
            ),
            (
                Self.facts(delivered: true, autoPasted: true),
                .pendingEligible
            ),
            // A successful paste can still have used the clipboard as its
            // transport. Only a copy-only route is excluded.
            (
                Self.facts(delivered: true, autoPasted: true, copiedToClipboard: true),
                .pendingEligible
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                PersonalizationOutcomeClassifier.classify(testCase.facts),
                testCase.expected
            )
        }
    }

    func testStatusTruthTableIsBoundedAndFailClosed() {
        XCTAssertEqual(
            Set(PersonalizationOutcomeStatus.allCases.filter(\.isObservable)),
            Set([.accepted, .corrected])
        )
        XCTAssertEqual(
            Set(PersonalizationOutcomeStatus.allCases.filter(\.isExcluded)),
            Set([
                .excludedDeliveryFailed,
                .excludedPartialDelivery,
                .excludedCopyOnly,
                .excludedAutoSent,
                .excludedSelectionTransform,
            ])
        )
        XCTAssertFalse(PersonalizationOutcomeStatus.pending.isReadbackTerminal)
        XCTAssertFalse(PersonalizationOutcomeStatus.unknown.isReadbackTerminal)
        XCTAssertTrue(PersonalizationOutcomeStatus.accepted.isReadbackTerminal)
        XCTAssertTrue(PersonalizationOutcomeStatus.stale.isReadbackTerminal)
    }

    func testNDeliveryAttemptsProduceExactlyNFinalizedRows() async throws {
        try await withHarness { harness in
            let excludedCases: [PersonalizationDeliveryRouteFacts] = [
                Self.facts(delivered: false, autoPasted: false),
                Self.facts(delivered: false, partiallyDelivered: true, autoPasted: false),
                Self.facts(delivered: true, autoPasted: false, copiedToClipboard: true),
                Self.facts(delivered: true, autoPasted: true, autoSent: true),
                Self.facts(delivered: true, autoPasted: true, selectionTransformUsed: true),
            ]
            var expectedStatuses = Set<PersonalizationOutcomeStatus>()

            for (index, routeFacts) in excludedCases.enumerated() {
                let id = UUID()
                let result = await harness.outcomeStore.register(
                    Self.registration(
                        id: id,
                        facts: routeFacts,
                        surface: index.isMultiple(of: 2) ? .unknown : .chat
                    )
                )
                guard case let .insertedTerminal(status) = result else {
                    XCTFail("Expected terminal insertion, got \(result)")
                    continue
                }
                expectedStatuses.insert(status)
            }

            let terminalReadbacks = PersonalizationOutcomeStatus.allCases.filter(
                \.isReadbackTerminal
            )
            for (index, status) in terminalReadbacks.enumerated() {
                let id = UUID()
                let registrationResult = await harness.outcomeStore.register(
                    Self.registration(
                        id: id,
                        surface: index.isMultiple(of: 2) ? .chat : .email
                    )
                )
                XCTAssertEqual(registrationResult, .insertedPending)

                let finalization: PersonalizationOutcomeFinalization
                switch status {
                case .accepted:
                    finalization = .accepted(readbackMethod: .retainedReceipt)
                case .corrected:
                    finalization = .corrected(
                        readbackMethod: .attributedSnapshot,
                        normalizedEditDistance: 0.24,
                        correctionCount: 2
                    )
                default:
                    finalization = .unobservable(status)
                }
                let finalizationResult = await harness.outcomeStore.finalize(
                    attemptID: id,
                    with: finalization
                )
                XCTAssertEqual(finalizationResult, .finalized)
                expectedStatuses.insert(status)
            }

            let records = await harness.outcomeStore.records()
            let expectedCount = excludedCases.count + terminalReadbacks.count
            XCTAssertEqual(records.count, expectedCount)
            XCTAssertEqual(Set(records.map(\.status)), expectedStatuses)
            XCTAssertTrue(records.allSatisfy { $0.status != .pending })
            XCTAssertTrue(records.allSatisfy { $0.finalizedAt != nil })
            XCTAssertTrue(records.allSatisfy { $0.observable == $0.status.isObservable })
            XCTAssertTrue(records.allSatisfy {
                $0.readbackEligible == !$0.status.isExcluded
            })
            XCTAssertEqual(Set(records.map(\.deliveryAttemptID)).count, expectedCount)
        }
    }

    func testConcurrentSameIDFinalizationRaceCommitsOneTerminalResult() async throws {
        try await withHarness { harness in
            let attemptID = UUID()
            let registrationResult = await harness.outcomeStore.register(
                Self.registration(id: attemptID)
            )
            XCTAssertEqual(registrationResult, .insertedPending)

            let candidates: [PersonalizationOutcomeFinalization] = [
                .accepted(readbackMethod: .retainedReceipt),
                .corrected(
                    readbackMethod: .attributedSnapshot,
                    normalizedEditDistance: 0.3,
                    correctionCount: 3
                ),
                .unobservable(.targetMismatch),
                .unobservable(.observationCancelled),
                .unobservable(.stale),
            ]
            let results = await withTaskGroup(
                of: PersonalizationOutcomeFinalizationResult.self,
                returning: [PersonalizationOutcomeFinalizationResult].self
            ) { group in
                for index in 0..<50 {
                    let candidate = candidates[index % candidates.count]
                    group.addTask {
                        await harness.outcomeStore.finalize(
                            attemptID: attemptID,
                            with: candidate
                        )
                    }
                }
                var values: [PersonalizationOutcomeFinalizationResult] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }

            XCTAssertEqual(results.filter { $0 == .finalized }.count, 1)
            XCTAssertEqual(results.filter { $0 == .alreadyFinalized }.count, 49)
            let records = await harness.outcomeStore.records()
            XCTAssertEqual(records.count, 1)
            XCTAssertNotEqual(records[0].status, .pending)
            XCTAssertNotNil(records[0].finalizedAt)
            let duplicateResult = await harness.outcomeStore.finalize(
                attemptID: attemptID,
                with: .accepted()
            )
            XCTAssertEqual(duplicateResult, .alreadyFinalized)
        }
    }

    func testPendingRowsRemainInCoverageDenominatorAndSurfaceSummaries() async throws {
        try await withHarness { harness in
            let acceptedID = UUID()
            let correctedID = UUID()
            let pendingID = UUID()
            let excludedID = UUID()

            for (id, surface) in [
                (acceptedID, PersonalizationOutcomeSurface.chat),
                (correctedID, .email),
                (pendingID, .chat),
            ] {
                let registrationResult = await harness.outcomeStore.register(
                    Self.registration(id: id, surface: surface)
                )
                XCTAssertEqual(registrationResult, .insertedPending)
            }
            let excludedResult = await harness.outcomeStore.register(
                Self.registration(
                    id: excludedID,
                    facts: Self.facts(
                        delivered: true,
                        autoPasted: false,
                        copiedToClipboard: true
                    ),
                    surface: .unknown
                )
            )
            XCTAssertEqual(excludedResult, .insertedTerminal(.excludedCopyOnly))
            let acceptedResult = await harness.outcomeStore.finalize(
                attemptID: acceptedID,
                with: .accepted()
            )
            XCTAssertEqual(acceptedResult, .finalized)
            let correctedResult = await harness.outcomeStore.finalize(
                attemptID: correctedID,
                with: .corrected(
                    normalizedEditDistance: 0.1,
                    correctionCount: 1
                )
            )
            XCTAssertEqual(correctedResult, .finalized)

            let summary = await harness.outcomeStore.summary()
            XCTAssertEqual(summary.global.attemptCount, 4)
            XCTAssertEqual(summary.global.pendingCount, 1)
            XCTAssertEqual(summary.global.excludedCount, 1)
            XCTAssertEqual(summary.global.coverage.numerator, 2)
            XCTAssertEqual(summary.global.coverage.denominator, 3)
            XCTAssertEqual(summary.global.coverage.value, 2.0 / 3.0, accuracy: 0.000_001)
            XCTAssertEqual(summary.global.observedNoEditRate.numerator, 1)
            XCTAssertEqual(summary.global.observedNoEditRate.denominator, 2)
            XCTAssertEqual(summary.global.observedNoEditRate.value, 0.5, accuracy: 0.000_001)
            XCTAssertEqual(summary.global.exclusionCounts[.excludedCopyOnly], 1)

            let chat = try XCTUnwrap(summary.surfaces.first { $0.surface == .chat })
            XCTAssertEqual(chat.population.coverage.numerator, 1)
            XCTAssertEqual(chat.population.coverage.denominator, 2)
            XCTAssertEqual(chat.population.pendingCount, 1)

            let unknown = try XCTUnwrap(summary.surfaces.first { $0.surface == .unknown })
            XCTAssertEqual(unknown.population.excludedCount, 1)
            XCTAssertEqual(unknown.population.coverage.denominator, 0)
        }
    }

    func testSetupSweepsExpiredPendingAndSchedulesUnexpiredRows() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sleeper = ControlledOutcomeSleeper()
        let clock = PersonalizationOutcomeClock(
            now: { now },
            sleep: { interval in try await sleeper.sleep(interval) }
        )
        let (directoryURL, dataStore) = try await makeDataStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let expiredID = UUID()
        let liveID = UUID()
        let savedExpired = await dataStore.save(Self.pendingModel(
            id: expiredID,
            createdAt: now.addingTimeInterval(-11),
            surface: .chat
        ))
        XCTAssertTrue(savedExpired)
        let savedLive = await dataStore.save(Self.pendingModel(
            id: liveID,
            createdAt: now.addingTimeInterval(-2),
            surface: .email
        ))
        XCTAssertTrue(savedLive)

        let outcomeStore = PersonalizationOutcomeStore(
            maximumObservationAge: 10,
            clock: clock
        )
        let setup = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertEqual(setup.sweptExpiredCount, 1)
        XCTAssertEqual(setup.scheduledPendingCount, 1)
        await sleeper.waitForCallCount(1)
        let launchIntervals = await sleeper.recordedIntervals()
        XCTAssertEqual(launchIntervals, [8])

        var records = await outcomeStore.records()
        XCTAssertEqual(records.first { $0.deliveryAttemptID == expiredID }?.status, .stale)
        XCTAssertNotNil(records.first { $0.deliveryAttemptID == expiredID }?.finalizedAt)
        XCTAssertEqual(records.first { $0.deliveryAttemptID == liveID }?.status, .pending)
        XCTAssertNil(records.first { $0.deliveryAttemptID == liveID }?.finalizedAt)

        await sleeper.resumeAll()
        let expiredLive = await waitForRecord(
            in: outcomeStore,
            attemptID: liveID,
            status: .stale
        )
        XCTAssertNotNil(expiredLive)
        records = await outcomeStore.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.status == .stale })
        await outcomeStore.quiesceForWorkspaceClear()
    }

    func testOwnedExpiryUsesInjectedClockAndSleeper() async throws {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let sleeper = ControlledOutcomeSleeper()
        let clock = PersonalizationOutcomeClock(
            now: { now },
            sleep: { interval in try await sleeper.sleep(interval) }
        )
        try await withHarness(maximumObservationAge: 9, clock: clock) { harness in
            let attemptID = UUID()
            let registrationResult = await harness.outcomeStore.register(
                Self.registration(id: attemptID)
            )
            XCTAssertEqual(registrationResult, .insertedPending)
            await sleeper.waitForCallCount(1)
            let intervals = await sleeper.recordedIntervals()
            XCTAssertEqual(intervals, [9])

            await sleeper.resumeAll()
            let record = await waitForRecord(
                in: harness.outcomeStore,
                attemptID: attemptID,
                status: .stale
            )
            XCTAssertEqual(record?.createdAt, now)
            XCTAssertEqual(record?.finalizedAt, now)
            XCTAssertFalse(record?.observable ?? true)
            XCTAssertTrue(record?.readbackEligible ?? false)
        }
    }

    func testQuiesceJoinsTimersAndResumeReschedulesPendingExpiry() async throws {
        let now = Date(timeIntervalSince1970: 2_200_000_000)
        let sleeper = ControlledOutcomeSleeper()
        let clock = PersonalizationOutcomeClock(
            now: { now },
            sleep: { interval in try await sleeper.sleep(interval) }
        )
        try await withHarness(maximumObservationAge: 12, clock: clock) { harness in
            let attemptID = UUID()
            let registrationResult = await harness.outcomeStore.register(
                Self.registration(id: attemptID)
            )
            XCTAssertEqual(registrationResult, .insertedPending)
            await sleeper.waitForCallCount(1)

            await harness.outcomeStore.quiesceForWorkspaceClear()
            let suspendedRegistration = await harness.outcomeStore.register(
                Self.registration(id: UUID())
            )
            XCTAssertEqual(suspendedRegistration, .suspended)
            let suspendedFinalization = await harness.outcomeStore.finalize(
                attemptID: attemptID,
                with: .accepted()
            )
            XCTAssertEqual(suspendedFinalization, .suspended)

            await harness.outcomeStore.resumeAfterWorkspaceClear()
            await sleeper.waitForCallCount(2)
            let resumedIntervals = await sleeper.recordedIntervals()
            XCTAssertEqual(resumedIntervals.count, 2)
            await sleeper.resumeAll()
            let expired = await waitForRecord(
                in: harness.outcomeStore,
                attemptID: attemptID,
                status: .stale
            )
            XCTAssertNotNil(expired)
        }
    }

    func testMissingAnalyticsTraceCannotSuppressLocalOutcome() async throws {
        try await withHarness { harness in
            let attemptID = UUID()
            // Registration intentionally has no analytics/quality-trace field.
            let registrationResult = await harness.outcomeStore.register(
                Self.registration(
                    id: attemptID,
                    exposure: PersonalizationOutcomeExposure(
                        assignmentVariant: .personalized,
                        assignmentPolicyVersion: 7,
                        personalizationOpportunity: true,
                        packetEntityOfferedCount: 40,
                        packetStyleOffered: true,
                        localLearnedEntityConsideredCount: 4,
                        localLearnedEntityMatchedCount: 4,
                        localLearnedEntityAppliedCount: 4,
                        cloudLearnedEntitySubmittedCount: 200,
                        cloudLearnedStyleSubmitted: true
                    )
                )
            )
            XCTAssertEqual(registrationResult, .insertedPending)
            let finalizationResult = await harness.outcomeStore.finalize(
                attemptID: attemptID,
                with: .corrected(
                    normalizedEditDistance: 0.6,
                    correctionCount: 99
                )
            )
            XCTAssertEqual(finalizationResult, .finalized)

            let records = await harness.outcomeStore.records()
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.status, .corrected)
            XCTAssertEqual(record.assignmentPolicyVersion, 7)
            XCTAssertEqual(record.packetEntityOfferedCount, 40)
            XCTAssertEqual(record.localLearnedEntityAppliedCount, 4)
            XCTAssertEqual(
                record.cloudLearnedEntitySubmittedCount,
                PersonalizationOutcomeExposure.maximumCount
            )
            XCTAssertTrue(record.personalizationApplied)
            XCTAssertEqual(record.editDistanceBucket, .overHalf)
            XCTAssertEqual(record.correctionCountBucket, .eightOrMore)
        }
    }

    func testTerminalOutcomePersistsAcrossContainerReopen() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutcomeReopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("Resonant.store")
        let attemptID = UUID()

        var firstDataStore: Resonant.DataStore? = Resonant.DataStore(storeURLOverride: storeURL)
        await firstDataStore?.setup()
        let firstOutcomeStore = PersonalizationOutcomeStore()
        let firstSetup = await firstOutcomeStore.setup(dataStore: try XCTUnwrap(firstDataStore))
        XCTAssertTrue(firstSetup.succeeded)
        let registrationResult = await firstOutcomeStore.register(
            Self.registration(id: attemptID, surface: .docs)
        )
        XCTAssertEqual(registrationResult, .insertedPending)
        let finalizationResult = await firstOutcomeStore.finalize(
            attemptID: attemptID,
            with: .accepted(readbackMethod: .retainedReceipt)
        )
        XCTAssertEqual(finalizationResult, .finalized)
        await firstOutcomeStore.quiesceForWorkspaceClear()
        firstDataStore = nil

        let reopenedDataStore = Resonant.DataStore(storeURLOverride: storeURL)
        await reopenedDataStore.setup()
        XCTAssertTrue(reopenedDataStore.isReady)
        XCTAssertNil(reopenedDataStore.setupError)
        let reopenedOutcomeStore = PersonalizationOutcomeStore()
        let reopenedSetup = await reopenedOutcomeStore.setup(dataStore: reopenedDataStore)
        XCTAssertTrue(reopenedSetup.succeeded)
        XCTAssertEqual(reopenedSetup.scheduledPendingCount, 0)
        let reopenedRecords = await reopenedOutcomeStore.records()
        let record = try XCTUnwrap(reopenedRecords.first)
        XCTAssertEqual(record.deliveryAttemptID, attemptID)
        XCTAssertEqual(record.status, .accepted)
        XCTAssertEqual(record.surface, .docs)
        XCTAssertEqual(record.readbackMethod, .retainedReceipt)
        XCTAssertNotNil(record.finalizedAt)
        await reopenedOutcomeStore.quiesceForWorkspaceClear()
    }

    func testSameOutcomeActorCanRetryAfterTheSameDataStoreBecomesReady() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutcomeSetupRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let dataStore = Resonant.DataStore(
            storeURLOverride: directoryURL.appendingPathComponent("Resonant.store")
        )
        let outcomeStore = PersonalizationOutcomeStore()

        let unavailable = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertEqual(unavailable, .unavailable)

        await dataStore.setup()
        XCTAssertTrue(dataStore.isReady)
        let available = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertTrue(available.succeeded)

        let attemptID = UUID()
        let registration = await outcomeStore.register(Self.registration(
            id: attemptID,
            facts: Self.facts(
                delivered: true,
                autoPasted: false,
                copiedToClipboard: true
            )
        ))
        XCTAssertEqual(registration, .insertedTerminal(.excludedCopyOnly))
        let records = await outcomeStore.records()
        XCTAssertEqual(records.map(\.deliveryAttemptID), [attemptID])
        await outcomeStore.quiesceForWorkspaceClear()
    }

    func testLegacyBaselineMigratesWithDefaultedExposureFields() async throws {
        let fixture = try LegacyPersonalizationStoreFixture.makeCopy()
        defer { fixture.remove() }
        let dataStore = Resonant.DataStore(storeURLOverride: fixture.storeURL)
        await dataStore.setup()
        XCTAssertTrue(dataStore.isReady)
        XCTAssertNil(dataStore.setupError)

        let outcomeStore = PersonalizationOutcomeStore()
        let setup = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertTrue(setup.succeeded)
        let attemptID = UUID()
        let registration = await outcomeStore.register(Self.registration(
            id: attemptID,
            facts: Self.facts(
                delivered: true,
                autoPasted: false,
                copiedToClipboard: true
            )
        ))
        XCTAssertEqual(registration, .insertedTerminal(.excludedCopyOnly))

        let records = await outcomeStore.records()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.packetEntityOfferedCount, 0)
        XCTAssertEqual(record.localLearnedEntityAppliedCount, 0)
        XCTAssertEqual(record.cloudLearnedEntitySubmittedCount, 0)
        XCTAssertFalse(record.personalizationApplied)
        await outcomeStore.quiesceForWorkspaceClear()
    }

    func testRetentionAndWorkspaceClearRemoveOutcomeRows() async throws {
        let mutableNow = LockedOutcomeNow(Date().addingTimeInterval(-40 * 24 * 60 * 60))
        let clock = PersonalizationOutcomeClock(
            now: { mutableNow.value() },
            sleep: PersonalizationOutcomeClock.live.sleep
        )
        try await withHarness(clock: clock) { harness in
            let oldID = UUID()
            let recentID = UUID()
            let excludedFacts = Self.facts(
                delivered: true,
                autoPasted: false,
                copiedToClipboard: true
            )
            let oldResult = await harness.outcomeStore.register(
                Self.registration(id: oldID, facts: excludedFacts)
            )
            XCTAssertEqual(oldResult, .insertedTerminal(.excludedCopyOnly))
            mutableNow.set(Date())
            let recentResult = await harness.outcomeStore.register(
                Self.registration(id: recentID, facts: excludedFacts)
            )
            XCTAssertEqual(recentResult, .insertedTerminal(.excludedCopyOnly))

            await harness.dataStore.purgeOldEntries(olderThan: 30)
            var records = await harness.outcomeStore.records()
            XCTAssertEqual(records.map(\.deliveryAttemptID), [recentID])

            await harness.outcomeStore.quiesceForWorkspaceClear()
            let cleared = await harness.dataStore.clearWorkspaceData()
            XCTAssertTrue(cleared)
            await harness.outcomeStore.completeWorkspaceClear()
            records = await harness.outcomeStore.records()
            XCTAssertTrue(records.isEmpty)
        }
    }

    func testOutcomeSchemaContainsOnlyBoundedTextFreeFields() throws {
        let schema = Schema([PersonalizationOutcome.self])
        let entity = try XCTUnwrap(schema.entities.first)
        let propertyNames = Set(entity.properties.map(\.name))
        XCTAssertEqual(propertyNames, Set([
            "deliveryAttemptID",
            "createdAt",
            "finalizedAt",
            "statusRaw",
            "readbackMethodRaw",
            "surfaceRaw",
            "targetProfileRaw",
            "readbackEligible",
            "observable",
            "assignmentVariantRaw",
            "assignmentPolicyVersion",
            "personalizationOpportunity",
            "withheldByHoldout",
            "personalizationApplied",
            "packetEntityOfferedCount",
            "packetStyleOffered",
            "localLearnedEntityConsideredCount",
            "localLearnedEntityMatchedCount",
            "localLearnedEntityAppliedCount",
            "localStyleApplied",
            "cloudLearnedEntitySubmittedCount",
            "cloudLearnedStyleSubmitted",
            "editDistanceBucketRaw",
            "correctionCountBucketRaw",
        ]))

        let forbiddenFragments = [
            "text", "transcript", "content", "bundle", "appname", "url",
            "fingerprint", "profilehash", "surfacehash", "identifier",
        ]
        for name in propertyNames {
            let normalized = name.lowercased()
            XCTAssertFalse(
                forbiddenFragments.contains { normalized.contains($0) },
                "Unexpected user-text/identifier field: \(name)"
            )
        }
        XCTAssertEqual(
            Set(PersonalizationOutcomeStatus.allCases.map(\.rawValue)).count,
            PersonalizationOutcomeStatus.allCases.count
        )
        XCTAssertEqual(
            Set(PersonalizationOutcomeSurface.allCases.map(\.rawValue)).count,
            PersonalizationOutcomeSurface.allCases.count
        )
    }

    private func withHarness(
        maximumObservationAge: TimeInterval = 120,
        clock: PersonalizationOutcomeClock = .live,
        _ body: (Harness) async throws -> Void
    ) async throws {
        let (directoryURL, dataStore) = try await makeDataStore()
        let outcomeStore = PersonalizationOutcomeStore(
            maximumObservationAge: maximumObservationAge,
            clock: clock
        )
        let setup = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertTrue(setup.succeeded)

        do {
            try await body(Harness(
                directoryURL: directoryURL,
                dataStore: dataStore,
                outcomeStore: outcomeStore
            ))
            await outcomeStore.quiesceForWorkspaceClear()
            try? FileManager.default.removeItem(at: directoryURL)
        } catch {
            await outcomeStore.quiesceForWorkspaceClear()
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    private func makeDataStore() async throws -> (URL, Resonant.DataStore) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutcomeStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let dataStore = Resonant.DataStore(
            storeURLOverride: directoryURL.appendingPathComponent("Resonant.store")
        )
        await dataStore.setup()
        XCTAssertTrue(dataStore.isReady)
        XCTAssertNil(dataStore.setupError)
        return (directoryURL, dataStore)
    }

    nonisolated private static func facts(
        delivered: Bool,
        partiallyDelivered: Bool = false,
        autoPasted: Bool,
        autoSent: Bool = false,
        copiedToClipboard: Bool = false,
        selectionTransformUsed: Bool = false
    ) -> PersonalizationDeliveryRouteFacts {
        PersonalizationDeliveryRouteFacts(
            delivered: delivered,
            partiallyDelivered: partiallyDelivered,
            autoPasted: autoPasted,
            autoSent: autoSent,
            copiedToClipboard: copiedToClipboard,
            selectionTransformUsed: selectionTransformUsed
        )
    }

    nonisolated private static func registration(
        id: UUID,
        facts: PersonalizationDeliveryRouteFacts = PersonalizationDeliveryRouteFacts(
            delivered: true,
            partiallyDelivered: false,
            autoPasted: true,
            autoSent: false,
            copiedToClipboard: false,
            selectionTransformUsed: false
        ),
        surface: PersonalizationOutcomeSurface = .unknown,
        exposure: PersonalizationOutcomeExposure = .none
    ) -> PersonalizationOutcomeRegistration {
        PersonalizationOutcomeRegistration(
            deliveryAttemptID: id,
            routeFacts: facts,
            readbackMethod: .attributedSnapshot,
            surface: surface,
            targetProfile: .nativeApp,
            exposure: exposure
        )
    }

    nonisolated private static func pendingModel(
        id: UUID,
        createdAt: Date,
        surface: PersonalizationOutcomeSurface
    ) -> PersonalizationOutcome {
        PersonalizationOutcome(
            deliveryAttemptID: id,
            createdAt: createdAt,
            finalizedAt: nil,
            status: .pending,
            readbackMethod: .attributedSnapshot,
            surface: surface,
            targetProfile: .nativeApp,
            readbackEligible: true,
            observable: false,
            exposure: .none
        )
    }

    private func waitForRecord(
        in store: PersonalizationOutcomeStore,
        attemptID: UUID,
        status: PersonalizationOutcomeStatus
    ) async -> PersonalizationOutcomeRecord? {
        for _ in 0..<500 {
            let record = await store.records().first {
                $0.deliveryAttemptID == attemptID
            }
            if record?.status == status {
                return record
            }
            await Task.yield()
        }
        return await store.records().first { $0.deliveryAttemptID == attemptID }
    }
}

private actor ControlledOutcomeSleeper {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
    }

    private var intervals: [TimeInterval] = []
    private var waiters: [UUID: Waiter] = [:]
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(_ interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                intervals.append(interval)
                waiters[id] = Waiter(continuation: continuation)
                resumeSatisfiedCallCountWaiters()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard intervals.count < count else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func recordedIntervals() -> [TimeInterval] {
        intervals
    }

    func resumeAll() {
        let continuations = waiters.values.map(\.continuation)
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }

    private func resumeSatisfiedCallCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in callCountWaiters {
            if intervals.count >= count {
                continuation.resume()
            } else {
                remaining.append((count, continuation))
            }
        }
        callCountWaiters = remaining
    }
}

private final class LockedOutcomeNow: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func value() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }
}
