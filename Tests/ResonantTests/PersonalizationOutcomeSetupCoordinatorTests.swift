import Foundation
import XCTest
@testable import Resonant

@MainActor
final class PersonalizationOutcomeSetupCoordinatorTests: XCTestCase {
    func testUnreadyLocalStoragePublishesBoundedCategoryAndSkipsOutcomeBootstrap() async {
        let spy = SetupSpy(dataStoreReady: false)
        spy.dataStoreSetupResults = [false]
        let coordinator = spy.makeCoordinator()

        let state = await coordinator.setupOrRetry()

        XCTAssertEqual(state, .unavailable(.localStorageNotReady))
        XCTAssertEqual(coordinator.state, .unavailable(.localStorageNotReady))
        XCTAssertEqual(spy.dataStoreSetupCount, 1)
        XCTAssertEqual(spy.outcomeSetupCount, 0)
        XCTAssertEqual(spy.attachCount, 0)
        XCTAssertFalse(spy.providerAttached)
        XCTAssertEqual(
            Set(PersonalizationOutcomeSetupFailureCategory.allCases.map(\.rawValue)),
            Set([
                "local_storage_not_ready",
                "outcome_bootstrap_unavailable",
            ])
        )
    }

    func testRetryReadiesDataStoreThenBootstrapsAndAttachesInOrder() async {
        let spy = SetupSpy(dataStoreReady: false)
        spy.dataStoreSetupResults = [false, true]
        let coordinator = spy.makeCoordinator()

        let firstState = await coordinator.setupOrRetry()
        XCTAssertEqual(firstState, .unavailable(.localStorageNotReady))
        spy.events.removeAll()

        let retryState = await coordinator.setupOrRetry()
        XCTAssertEqual(retryState, .available)
        XCTAssertEqual(
            spy.events,
            ["detach", "data_store_setup", "outcome_setup", "attach"]
        )
        XCTAssertEqual(spy.dataStoreSetupCount, 2)
        XCTAssertEqual(spy.outcomeSetupCount, 1)
        XCTAssertEqual(spy.attachCount, 1)
        XCTAssertTrue(spy.providerAttached)
    }

    func testReadyDataStoreRetriesOnlyOutcomeBootstrapAndPersistentFailureStaysDetached() async {
        let spy = SetupSpy(dataStoreReady: true)
        spy.outcomeSetupResults = [.unavailable, .unavailable]
        let coordinator = spy.makeCoordinator()

        let firstState = await coordinator.setupOrRetry()
        let retryState = await coordinator.setupOrRetry()
        XCTAssertEqual(firstState, .unavailable(.outcomeBootstrapUnavailable))
        XCTAssertEqual(retryState, .unavailable(.outcomeBootstrapUnavailable))

        XCTAssertEqual(spy.dataStoreSetupCount, 0)
        XCTAssertEqual(spy.outcomeSetupCount, 2)
        XCTAssertEqual(spy.attachCount, 0)
        XCTAssertFalse(spy.providerAttached)
    }

    func testTwoConcurrentRetriesJoinOneOutcomeBootstrap() async {
        let blocker = OutcomeBootstrapBlocker()
        let joinObserver = OutcomeSetupJoinObserver()
        let spy = SetupSpy(dataStoreReady: true)
        spy.blockingOutcomeBootstrap = blocker
        spy.joinObserver = joinObserver
        let coordinator = spy.makeCoordinator()

        let first = Task { @MainActor in
            await coordinator.setupOrRetry()
        }
        await blocker.waitUntilStarted()
        XCTAssertEqual(coordinator.state, .settingUp)

        let second = Task { @MainActor in
            await coordinator.setupOrRetry()
        }
        await joinObserver.waitUntilJoined()
        XCTAssertEqual(spy.outcomeSetupCount, 1)
        XCTAssertEqual(coordinator.state, .settingUp)

        blocker.release(.success)
        let firstState = await first.value
        let secondState = await second.value

        XCTAssertEqual(firstState, .available)
        XCTAssertEqual(secondState, .available)
        XCTAssertEqual(spy.outcomeSetupCount, 1)
        XCTAssertEqual(spy.attachCount, 1)
    }

    func testAvailableSetupIsIdempotentAndDoesNotReattach() async {
        let spy = SetupSpy(dataStoreReady: true)
        let coordinator = spy.makeCoordinator()

        let firstState = await coordinator.setupOrRetry()
        let repeatedState = await coordinator.setupOrRetry()
        XCTAssertEqual(firstState, .available)
        XCTAssertEqual(repeatedState, .available)

        XCTAssertEqual(spy.dataStoreSetupCount, 0)
        XCTAssertEqual(spy.outcomeSetupCount, 1)
        XCTAssertEqual(spy.attachCount, 1)
        XCTAssertTrue(spy.providerAttached)
    }

    func testWorkspaceClearSuspendsNewSetupAndJoinsTheActiveBootstrap() async {
        let blocker = OutcomeBootstrapBlocker()
        let quiesceObserver = OutcomeSetupJoinObserver()
        let spy = SetupSpy(dataStoreReady: true)
        spy.blockingOutcomeBootstrap = blocker
        spy.quiesceObserver = quiesceObserver
        let coordinator = spy.makeCoordinator()

        let setup = Task { @MainActor in
            await coordinator.setupOrRetry()
        }
        await blocker.waitUntilStarted()

        let quiesce = Task { @MainActor in
            await coordinator.quiesceForWorkspaceClear()
        }
        await quiesceObserver.waitUntilJoined()

        let rejectedDuringClear = await coordinator.setupOrRetry()
        XCTAssertEqual(rejectedDuringClear, .settingUp)
        XCTAssertEqual(spy.outcomeSetupCount, 1)

        blocker.release(.success)
        let setupState = await setup.value
        XCTAssertEqual(setupState, .available)
        await quiesce.value
        XCTAssertEqual(spy.attachCount, 1)

        coordinator.resumeAfterWorkspaceClear()
        let repeated = await coordinator.setupOrRetry()
        XCTAssertEqual(repeated, .available)
        XCTAssertEqual(spy.outcomeSetupCount, 1)
    }

    func testLiveCoordinatorProviderReadsTheSameOutcomeActorItBootstrapped() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutcomeSetup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let dataStore = Resonant.DataStore(
            storeURLOverride: directoryURL.appendingPathComponent("Resonant.store")
        )
        let outcomeStore = PersonalizationOutcomeStore()
        let memoryStore = PersonalizationMemoryStore()
        let coordinator = PersonalizationOutcomeSetupCoordinator(
            dataStore: dataStore,
            outcomeStore: outcomeStore,
            controlDataSource: memoryStore
        )

        let setupState = await coordinator.setupOrRetry()
        XCTAssertEqual(setupState, .available)
        let attemptID = UUID()
        let registration = PersonalizationOutcomeRegistration(
            deliveryAttemptID: attemptID,
            routeFacts: PersonalizationDeliveryRouteFacts(
                delivered: true,
                partiallyDelivered: false,
                autoPasted: false,
                autoSent: false,
                copiedToClipboard: true,
                selectionTransformUsed: false
            ),
            readbackMethod: .notApplicable,
            surface: .unknown,
            targetProfile: .unknown,
            exposure: .none
        )
        let registrationResult = await outcomeStore.register(registration)
        XCTAssertEqual(registrationResult, .insertedTerminal(.excludedCopyOnly))

        let controls = await memoryStore.controlsSnapshot()
        let summary = try XCTUnwrap(controls.evaluation.outcomes.summary)
        XCTAssertEqual(summary.global.attemptCount, 1)
        XCTAssertEqual(
            summary.global.statusCounts[.excludedCopyOnly],
            1
        )
        await outcomeStore.quiesceForWorkspaceClear()
    }
}

@MainActor
private final class SetupSpy {
    var dataStoreReady: Bool
    var dataStoreSetupResults: [Bool] = []
    var outcomeSetupResults: [PersonalizationOutcomeSetupResult] = []
    var blockingOutcomeBootstrap: OutcomeBootstrapBlocker?
    var joinObserver: OutcomeSetupJoinObserver?
    var quiesceObserver: OutcomeSetupJoinObserver?

    private(set) var dataStoreSetupCount = 0
    private(set) var outcomeSetupCount = 0
    private(set) var attachCount = 0
    private(set) var detachCount = 0
    private(set) var providerAttached = false
    var events: [String] = []

    init(dataStoreReady: Bool) {
        self.dataStoreReady = dataStoreReady
    }

    func makeCoordinator() -> PersonalizationOutcomeSetupCoordinator {
        PersonalizationOutcomeSetupCoordinator(dependencies: .init(
            isDataStoreReady: {
                self.dataStoreReady
            },
            setupDataStore: {
                self.dataStoreSetupCount += 1
                self.events.append("data_store_setup")
                if !self.dataStoreSetupResults.isEmpty {
                    self.dataStoreReady = self.dataStoreSetupResults.removeFirst()
                }
            },
            setupOutcomeStore: {
                self.outcomeSetupCount += 1
                self.events.append("outcome_setup")
                if let blockingOutcomeBootstrap = self.blockingOutcomeBootstrap {
                    return await blockingOutcomeBootstrap.run()
                }
                if !self.outcomeSetupResults.isEmpty {
                    return self.outcomeSetupResults.removeFirst()
                }
                return .success
            },
            attachOutcomeSummaryProvider: {
                self.attachCount += 1
                self.providerAttached = true
                self.events.append("attach")
            },
            detachOutcomeSummaryProvider: {
                self.detachCount += 1
                self.providerAttached = false
                self.events.append("detach")
            },
            didJoinActiveRun: {
                self.joinObserver?.didJoin()
            },
            didSuspendForWorkspaceClear: {
                self.quiesceObserver?.didJoin()
            }
        ))
    }
}

@MainActor
private final class OutcomeBootstrapBlocker {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation:
        CheckedContinuation<PersonalizationOutcomeSetupResult, Never>?

    func run() async -> PersonalizationOutcomeSetupResult {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release(_ result: PersonalizationOutcomeSetupResult) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

@MainActor
private final class OutcomeSetupJoinObserver {
    private var didObserveJoin = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func didJoin() {
        didObserveJoin = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }

    func waitUntilJoined() async {
        guard !didObserveJoin else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private extension PersonalizationOutcomeSetupResult {
    static let success = Self(
        succeeded: true,
        sweptExpiredCount: 0,
        scheduledPendingCount: 0
    )
}
