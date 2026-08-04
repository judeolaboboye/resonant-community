import Foundation

/// Serializes asynchronous sleep/wake service transitions and gives every
/// suspension boundary a cheap ownership check.
///
/// AppKit can deliver a wake while sleep cleanup is still awaiting another
/// actor. The newer transition waits for its predecessor to retire, while the
/// predecessor observes that its generation is stale and performs no further
/// side effects. This guarantees that the final service state matches the most
/// recent power notification.
@MainActor
final class SystemPowerTransitionCoordinator {
    typealias OwnershipCheck = @MainActor @Sendable () -> Bool
    typealias Operation = @MainActor @Sendable (OwnershipCheck) async -> Void

    private var generation: UInt64 = 0
    private var pendingTransition: Task<Void, Never>?

    func enqueue(_ operation: @escaping Operation) {
        generation &+= 1
        let operationGeneration = generation
        let predecessor = pendingTransition

        pendingTransition = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self,
                  !Task.isCancelled,
                  self.generation == operationGeneration else { return }

            let stillOwnsTransition: OwnershipCheck = { [weak self] in
                guard !Task.isCancelled, let self else { return false }
                return self.generation == operationGeneration
            }
            await operation(stillOwnsTransition)
        }
    }

    /// Retires all scheduled post-await effects (used by terminal shutdown).
    func invalidate() {
        generation &+= 1
        pendingTransition?.cancel()
    }

    /// Deterministic drain seam for state-machine tests.
    func waitForIdle() async {
        await pendingTransition?.value
    }
}
