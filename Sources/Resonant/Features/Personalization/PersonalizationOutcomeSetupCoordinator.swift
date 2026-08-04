import Foundation
import Observation

enum PersonalizationOutcomeSetupFailureCategory: String, Sendable, Equatable, CaseIterable {
    case localStorageNotReady = "local_storage_not_ready"
    case outcomeBootstrapUnavailable = "outcome_bootstrap_unavailable"
}

enum PersonalizationOutcomeSetupState: Sendable, Equatable {
    case notStarted
    case settingUp
    case available
    case unavailable(PersonalizationOutcomeSetupFailureCategory)
}

/// App-owned, single-flight setup authority for local personalization outcomes.
///
/// The coordinator deliberately owns no persistence actor of its own. Both
/// bootstrap and the installed summary provider capture the same lifetime
/// `PersonalizationOutcomeStore` supplied by AppState.
@MainActor
@Observable
final class PersonalizationOutcomeSetupCoordinator {
    struct Dependencies {
        let isDataStoreReady: @MainActor () -> Bool
        let setupDataStore: @MainActor () async -> Void
        let setupOutcomeStore: @MainActor () async -> PersonalizationOutcomeSetupResult
        let attachOutcomeSummaryProvider: @MainActor () -> Void
        let detachOutcomeSummaryProvider: @MainActor () -> Void
        let didJoinActiveRun: @MainActor () -> Void
        let didSuspendForWorkspaceClear: @MainActor () -> Void

        init(
            isDataStoreReady: @escaping @MainActor () -> Bool,
            setupDataStore: @escaping @MainActor () async -> Void,
            setupOutcomeStore: @escaping @MainActor () async -> PersonalizationOutcomeSetupResult,
            attachOutcomeSummaryProvider: @escaping @MainActor () -> Void,
            detachOutcomeSummaryProvider: @escaping @MainActor () -> Void,
            didJoinActiveRun: @escaping @MainActor () -> Void = {},
            didSuspendForWorkspaceClear: @escaping @MainActor () -> Void = {}
        ) {
            self.isDataStoreReady = isDataStoreReady
            self.setupDataStore = setupDataStore
            self.setupOutcomeStore = setupOutcomeStore
            self.attachOutcomeSummaryProvider = attachOutcomeSummaryProvider
            self.detachOutcomeSummaryProvider = detachOutcomeSummaryProvider
            self.didJoinActiveRun = didJoinActiveRun
            self.didSuspendForWorkspaceClear = didSuspendForWorkspaceClear
        }
    }

    private(set) var state: PersonalizationOutcomeSetupState = .notStarted

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private var isWorkspaceSetupSuspended = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    convenience init(
        dataStore: DataStore,
        outcomeStore: PersonalizationOutcomeStore,
        controlDataSource: PersonalizationControlDataSource
    ) {
        self.init(dependencies: Dependencies(
            isDataStoreReady: {
                dataStore.isReady
            },
            setupDataStore: {
                await dataStore.setup()
            },
            setupOutcomeStore: {
                await outcomeStore.setup(dataStore: dataStore)
            },
            attachOutcomeSummaryProvider: {
                controlDataSource.attachOutcomeSummaryProvider { [outcomeStore] in
                    await outcomeStore.summary()
                }
            },
            detachOutcomeSummaryProvider: {
                controlDataSource.detachOutcomeSummaryProvider()
            }
        ))
    }

    /// Initial launch and explicit Retry both enter this path. Concurrent
    /// callers join one run, and an available coordinator is idempotent.
    @discardableResult
    func setupOrRetry() async -> PersonalizationOutcomeSetupState {
        if state == .available {
            return state
        }
        guard !isWorkspaceSetupSuspended else { return state }
        if let activeTask {
            dependencies.didJoinActiveRun()
            await activeTask.value
            return state
        }

        let runID = UUID()
        activeRunID = runID
        state = .settingUp
        dependencies.detachOutcomeSummaryProvider()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSetup(runID: runID)
        }
        activeTask = task
        await task.value
        return state
    }

    /// Closes setup admission and joins any launch/retry run before the
    /// delivery router suspends the outcome actor for destructive clear.
    func quiesceForWorkspaceClear() async {
        isWorkspaceSetupSuspended = true
        dependencies.didSuspendForWorkspaceClear()
        if let activeTask {
            await activeTask.value
        }
    }

    /// Reopens setup admission only after the delivery router has resumed its
    /// shared outcome actor on both clear success and abort paths.
    func resumeAfterWorkspaceClear() {
        isWorkspaceSetupSuspended = false
    }

    private func performSetup(runID: UUID) async {
        if !dependencies.isDataStoreReady() {
            await dependencies.setupDataStore()
        }

        guard activeRunID == runID else { return }
        guard dependencies.isDataStoreReady() else {
            finish(
                runID: runID,
                state: .unavailable(.localStorageNotReady),
                shouldAttachProvider: false
            )
            return
        }

        let result = await dependencies.setupOutcomeStore()
        guard activeRunID == runID else { return }
        guard result.succeeded else {
            finish(
                runID: runID,
                state: .unavailable(.outcomeBootstrapUnavailable),
                shouldAttachProvider: false
            )
            return
        }

        finish(
            runID: runID,
            state: .available,
            shouldAttachProvider: true
        )
    }

    private func finish(
        runID: UUID,
        state newState: PersonalizationOutcomeSetupState,
        shouldAttachProvider: Bool
    ) {
        guard activeRunID == runID else { return }
        if shouldAttachProvider {
            dependencies.attachOutcomeSummaryProvider()
        } else {
            dependencies.detachOutcomeSummaryProvider()
        }
        state = newState
        activeRunID = nil
        activeTask = nil
    }
}
