import Foundation
import SwiftData

/// Owns the complete local delivery-outcome lifecycle. Registration,
/// pending-state persistence, expiry tasks, and terminal transitions all pass
/// through this actor so repeated or racing completion cannot create a second
/// row or overwrite the first terminal result.
actor PersonalizationOutcomeStore {
    /// Recovery horizon for attempts orphaned by a crash/relaunch. The live
    /// observer owns the ordinary 120-second decision window, so this fallback
    /// must be strictly later; correctness still relies on finalize's atomic
    /// first-writer-wins result rather than timing separation.
    static let defaultMaximumObservationAge: TimeInterval = 180
    static let maximumAllowedObservationAge: TimeInterval = 5 * 60

    private enum AttemptState: Sendable, Equatable {
        case registering
        case pending(createdAt: Date)
        case finalizing(createdAt: Date)
        case terminal
    }

    private enum PersistedRegistrationResult: Sendable {
        case insertedPending(createdAt: Date)
        case insertedTerminal
        case existingPending(createdAt: Date)
        case existingTerminal
    }

    private enum PersistedFinalizationResult: Sendable {
        case finalized
        case alreadyFinalized
        case notFound
    }

    private struct BootstrapRecord: Sendable {
        let deliveryAttemptID: UUID
        let createdAt: Date
        let isPending: Bool
    }

    private struct BootstrapResult: Sendable {
        let records: [BootstrapRecord]
        let sweptExpiredCount: Int
    }

    private let maximumObservationAge: TimeInterval
    private let clock: PersonalizationOutcomeClock

    private var dataStore: DataStore?
    private var isReady = false
    private var isWorkspaceWriteSuspended = false
    private var attemptStates: [UUID: AttemptState] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var activePersistenceCount = 0
    private var persistenceDrainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        maximumObservationAge: TimeInterval = defaultMaximumObservationAge,
        clock: PersonalizationOutcomeClock = .live
    ) {
        self.maximumObservationAge = min(
            max(maximumObservationAge, 0.001),
            Self.maximumAllowedObservationAge
        )
        self.clock = clock
    }

    /// Loads persisted state, atomically marks expired pending rows stale, and
    /// schedules every still-live pending row. A failed setup can be retried.
    @discardableResult
    func setup(dataStore: DataStore) async -> PersonalizationOutcomeSetupResult {
        if isReady {
            return PersonalizationOutcomeSetupResult(
                succeeded: true,
                sweptExpiredCount: 0,
                scheduledPendingCount: expiryTasks.count
            )
        }

        self.dataStore = dataStore
        let now = clock.now()
        let maximumObservationAge = maximumObservationAge
        beginPersistence()
        let bootstrap = await dataStore.performBackgroundWrite { context -> BootstrapResult in
            let models = try context.fetch(FetchDescriptor<PersonalizationOutcome>())
            var records: [BootstrapRecord] = []
            records.reserveCapacity(models.count)
            var sweptExpiredCount = 0

            for model in models {
                let age = max(0, now.timeIntervalSince(model.createdAt))
                let pendingIsConsistent = model.status == .pending && model.finalizedAt == nil
                if model.status == .pending,
                   (!pendingIsConsistent || age >= maximumObservationAge) {
                    model.status = .stale
                    model.finalizedAt = now
                    model.observable = false
                    model.editDistanceBucket = .unavailable
                    model.correctionCountBucket = .unavailable
                    sweptExpiredCount += 1
                } else if model.status != .pending, model.finalizedAt == nil {
                    // Repair a partially committed future/corrupt terminal row
                    // without changing its bounded classification.
                    model.finalizedAt = model.createdAt
                    model.observable = model.status.isObservable
                }

                records.append(BootstrapRecord(
                    deliveryAttemptID: model.deliveryAttemptID,
                    createdAt: model.createdAt,
                    isPending: model.status == .pending && model.finalizedAt == nil
                ))
            }

            return BootstrapResult(
                records: records,
                sweptExpiredCount: sweptExpiredCount
            )
        }
        endPersistence()

        guard let bootstrap else {
            self.dataStore = nil
            return .unavailable
        }

        attemptStates = Dictionary(
            uniqueKeysWithValues: bootstrap.records.map { record in
                (
                    record.deliveryAttemptID,
                    record.isPending
                        ? AttemptState.pending(createdAt: record.createdAt)
                        : AttemptState.terminal
                )
            }
        )
        isReady = true

        var scheduledPendingCount = 0
        if !isWorkspaceWriteSuspended {
            for record in bootstrap.records where record.isPending {
                scheduleExpiry(
                    attemptID: record.deliveryAttemptID,
                    createdAt: record.createdAt
                )
                scheduledPendingCount += 1
            }
        }

        return PersonalizationOutcomeSetupResult(
            succeeded: true,
            sweptExpiredCount: bootstrap.sweptExpiredCount,
            scheduledPendingCount: scheduledPendingCount
        )
    }

    /// Inserts exactly one row immediately. Eligible delivery routes enter the
    /// pending population; all exclusions are terminal on the initial insert.
    @discardableResult
    func register(
        _ registration: PersonalizationOutcomeRegistration
    ) async -> PersonalizationOutcomeRegistrationResult {
        guard isReady, let dataStore else { return .persistenceUnavailable }
        guard !isWorkspaceWriteSuspended else { return .suspended }
        guard attemptStates[registration.deliveryAttemptID] == nil else {
            return .alreadyRegistered
        }

        let classification = PersonalizationOutcomeClassifier.classify(
            registration.routeFacts
        )
        let createdAt = clock.now()
        let status: PersonalizationOutcomeStatus
        let finalizedAt: Date?
        let readbackEligible: Bool
        let readbackMethod: PersonalizationOutcomeReadbackMethod
        switch classification {
        case .pendingEligible:
            status = .pending
            finalizedAt = nil
            readbackEligible = true
            readbackMethod = registration.readbackMethod == .notApplicable
                ? .unavailable
                : registration.readbackMethod
        case let .terminalExcluded(excludedStatus):
            status = excludedStatus
            finalizedAt = createdAt
            readbackEligible = false
            readbackMethod = .notApplicable
        }

        let modelValues = PersonalizationOutcomeRecordValues(
            deliveryAttemptID: registration.deliveryAttemptID,
            createdAt: createdAt,
            finalizedAt: finalizedAt,
            status: status,
            readbackMethod: readbackMethod,
            surface: registration.surface,
            targetProfile: registration.targetProfile,
            readbackEligible: readbackEligible,
            observable: false,
            exposure: registration.exposure
        )

        attemptStates[registration.deliveryAttemptID] = .registering
        beginPersistence()
        let persisted = await dataStore.performBackgroundWrite { context -> PersistedRegistrationResult in
            let attemptID = registration.deliveryAttemptID
            var descriptor = FetchDescriptor<PersonalizationOutcome>(
                predicate: #Predicate { $0.deliveryAttemptID == attemptID }
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                if existing.status == .pending, existing.finalizedAt == nil {
                    return .existingPending(createdAt: existing.createdAt)
                }
                return .existingTerminal
            }

            context.insert(modelValues.makeModel())
            if status == .pending {
                return .insertedPending(createdAt: createdAt)
            }
            return .insertedTerminal
        }
        endPersistence()

        guard let persisted else {
            attemptStates.removeValue(forKey: registration.deliveryAttemptID)
            return .persistenceUnavailable
        }

        switch persisted {
        case let .insertedPending(persistedCreatedAt):
            attemptStates[registration.deliveryAttemptID] = .pending(
                createdAt: persistedCreatedAt
            )
            if !isWorkspaceWriteSuspended {
                scheduleExpiry(
                    attemptID: registration.deliveryAttemptID,
                    createdAt: persistedCreatedAt
                )
            }
            return .insertedPending

        case .insertedTerminal:
            attemptStates[registration.deliveryAttemptID] = .terminal
            return .insertedTerminal(status)

        case let .existingPending(persistedCreatedAt):
            attemptStates[registration.deliveryAttemptID] = .pending(
                createdAt: persistedCreatedAt
            )
            if !isWorkspaceWriteSuspended {
                scheduleExpiry(
                    attemptID: registration.deliveryAttemptID,
                    createdAt: persistedCreatedAt
                )
            }
            return .alreadyRegistered

        case .existingTerminal:
            attemptStates[registration.deliveryAttemptID] = .terminal
            return .alreadyRegistered
        }
    }

    /// Atomically transitions one pending row to one terminal readback result.
    /// Repeated, racing, and late completions are ignored.
    @discardableResult
    func finalize(
        attemptID: UUID,
        with finalization: PersonalizationOutcomeFinalization
    ) async -> PersonalizationOutcomeFinalizationResult {
        guard finalization.status.isReadbackTerminal else { return .invalidStatus }
        guard isReady, let dataStore else { return .persistenceUnavailable }
        guard !isWorkspaceWriteSuspended else { return .suspended }

        let createdAt: Date
        switch attemptStates[attemptID] {
        case let .pending(persistedCreatedAt):
            createdAt = persistedCreatedAt
        case .finalizing, .terminal:
            return .alreadyFinalized
        case .registering, nil:
            return .notFound
        }

        attemptStates[attemptID] = .finalizing(createdAt: createdAt)
        if let expiryTask = expiryTasks.removeValue(forKey: attemptID) {
            expiryTask.cancel()
        }

        let finalizedAt = clock.now()
        let buckets = Self.buckets(for: finalization)
        beginPersistence()
        let persisted = await dataStore.performBackgroundWrite { context -> PersistedFinalizationResult in
            var descriptor = FetchDescriptor<PersonalizationOutcome>(
                predicate: #Predicate { $0.deliveryAttemptID == attemptID }
            )
            descriptor.fetchLimit = 1
            guard let model = try context.fetch(descriptor).first else {
                return .notFound
            }
            guard model.status == .pending, model.finalizedAt == nil else {
                return .alreadyFinalized
            }

            model.status = finalization.status
            model.finalizedAt = finalizedAt
            model.observable = finalization.status.isObservable
            if let method = finalization.readbackMethod,
               method != .notApplicable {
                model.readbackMethod = method
            }
            model.editDistanceBucket = buckets.editDistance
            model.correctionCountBucket = buckets.correctionCount
            return .finalized
        }
        endPersistence()

        guard let persisted else {
            attemptStates[attemptID] = .pending(createdAt: createdAt)
            if !isWorkspaceWriteSuspended {
                scheduleExpiry(attemptID: attemptID, createdAt: createdAt)
            }
            return .persistenceUnavailable
        }

        switch persisted {
        case .finalized:
            attemptStates[attemptID] = .terminal
            return .finalized
        case .alreadyFinalized:
            attemptStates[attemptID] = .terminal
            return .alreadyFinalized
        case .notFound:
            attemptStates.removeValue(forKey: attemptID)
            return .notFound
        }
    }

    /// Text-free records for local UI/reporting and focused verification.
    func records() async -> [PersonalizationOutcomeRecord] {
        guard isReady, let dataStore else { return [] }
        return await dataStore.fetchMappedInBackground(
            FetchDescriptor<PersonalizationOutcome>(
                sortBy: [SortDescriptor(\.createdAt)]
            )
        ) { model in
            PersonalizationOutcomeRecord(model: model)
        }
    }

    func summary() async -> PersonalizationOutcomeSummary {
        PersonalizationOutcomeSummary.make(
            records: await records(),
            capturedAt: clock.now()
        )
    }

    /// Establishes the destructive-clear boundary: no new registrations or
    /// finalizations are admitted, every timeout is cancelled and joined, and
    /// every persistence operation admitted before suspension is joined.
    func quiesceForWorkspaceClear() async {
        isWorkspaceWriteSuspended = true
        let tasks = Array(expiryTasks.values)
        expiryTasks.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        if activePersistenceCount > 0 {
            await withCheckedContinuation { continuation in
                persistenceDrainWaiters.append(continuation)
            }
        }
    }

    /// Call after the central DataStore clear succeeds.
    func completeWorkspaceClear() {
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        attemptStates.removeAll()
        isWorkspaceWriteSuspended = false
    }

    /// Call when a multi-store clear aborts. Existing pending attempts remain
    /// denominator-visible and receive a fresh bounded expiry task.
    func resumeAfterWorkspaceClear() {
        isWorkspaceWriteSuspended = false
        for (attemptID, state) in attemptStates {
            guard case let .pending(createdAt) = state else { continue }
            scheduleExpiry(attemptID: attemptID, createdAt: createdAt)
        }
    }

    private func expire(attemptID: UUID) async {
        expiryTasks.removeValue(forKey: attemptID)
        _ = await finalize(
            attemptID: attemptID,
            with: .unobservable(.stale)
        )
    }

    private func scheduleExpiry(attemptID: UUID, createdAt: Date) {
        guard isReady, !isWorkspaceWriteSuspended,
              expiryTasks[attemptID] == nil,
              case .pending = attemptStates[attemptID] else {
            return
        }

        let elapsed = max(0, clock.now().timeIntervalSince(createdAt))
        let remaining = max(0, maximumObservationAge - elapsed)
        let clock = clock
        expiryTasks[attemptID] = Task { [weak self] in
            do {
                try await clock.sleep(remaining)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expire(attemptID: attemptID)
        }
    }

    private func beginPersistence() {
        activePersistenceCount += 1
    }

    private func endPersistence() {
        activePersistenceCount = max(0, activePersistenceCount - 1)
        guard activePersistenceCount == 0 else { return }
        let waiters = persistenceDrainWaiters
        persistenceDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private nonisolated static func buckets(
        for finalization: PersonalizationOutcomeFinalization
    ) -> (
        editDistance: PersonalizationEditDistanceBucket,
        correctionCount: PersonalizationCorrectionCountBucket
    ) {
        switch finalization.status {
        case .accepted:
            return (.none, .zero)
        case .corrected:
            return (
                finalization.editDistanceBucket
                    ?? .classify(finalization.normalizedEditDistance),
                .classify(finalization.correctionCount)
            )
        case .pending, .excludedDeliveryFailed, .excludedPartialDelivery,
                .excludedCopyOnly, .excludedAutoSent,
                .excludedSelectionTransform, .processMismatch,
                .targetMismatch, .sensitiveTarget, .insufficientIdentity,
                .regionUnattributable, .baselineUnavailable,
                .targetNormalizedOrUnattributable, .readbackUnavailable,
                .noFieldContent, .observationCancelled,
                .observationReplaced, .stale, .unknown:
            return (.unavailable, .unavailable)
        }
    }
}

/// Sendable copy used to construct a SwiftData model inside the background
/// context that owns it.
private struct PersonalizationOutcomeRecordValues: Sendable {
    let deliveryAttemptID: UUID
    let createdAt: Date
    let finalizedAt: Date?
    let status: PersonalizationOutcomeStatus
    let readbackMethod: PersonalizationOutcomeReadbackMethod
    let surface: PersonalizationOutcomeSurface
    let targetProfile: PersonalizationOutcomeTargetProfile
    let readbackEligible: Bool
    let observable: Bool
    let exposure: PersonalizationOutcomeExposure

    func makeModel() -> PersonalizationOutcome {
        PersonalizationOutcome(
            deliveryAttemptID: deliveryAttemptID,
            createdAt: createdAt,
            finalizedAt: finalizedAt,
            status: status,
            readbackMethod: readbackMethod,
            surface: surface,
            targetProfile: targetProfile,
            readbackEligible: readbackEligible,
            observable: observable,
            exposure: exposure
        )
    }
}
