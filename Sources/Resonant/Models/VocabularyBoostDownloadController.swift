import Foundation
import Observation

/// Observable single-flight owner for the CTC helper-model download.
///
/// Operational publication is generation-gated. Cancelling a run invalidates
/// its generation before asking the task to stop, so a non-cooperative
/// downloader cannot publish stale progress or failure. A fresh positive disk
/// check may still publish `.ready` while idle because readiness describes the
/// installed helper files, independently of feature applicability.
@MainActor
@Observable
final class VocabularyBoostDownloadController {
    typealias DownloadOperation = @Sendable () async throws -> Void
    typealias AvailabilityCheck = @Sendable () -> Bool

    private(set) var state: VocabularyBoostHelperDownloadState

    /// Compatibility accessor for surfaces that need a sentence. The value is
    /// always derived from the bounded category; raw Error text is never kept.
    var failureDescription: String? {
        guard case .failed(let category) = state else { return nil }
        return category.detail
    }

    @ObservationIgnored private let isDownloaded: AvailabilityCheck
    @ObservationIgnored private let download: DownloadOperation
    @ObservationIgnored private var activeTask: Task<Result<Void, Error>, Never>?
    @ObservationIgnored private var activeRunID: UUID?

    init(
        isDownloaded: @escaping AvailabilityCheck,
        download: @escaping DownloadOperation
    ) {
        self.isDownloaded = isDownloaded
        self.download = download
        state = isDownloaded() ? .ready : .absent
    }

    /// Refreshes installed state without starting network work. Helper assets
    /// are acquired only from the visible Download/Retry controls.
    func reconcileAutomaticDownload(isEligible: Bool, cancelInFlightOnLoss: Bool = true) async {
        _ = isEligible
        _ = cancelInFlightOnLoss
        _ = publishReadyIfInstalledAndIdle()
    }

    /// Explicit, user-visible prefetch. It is intentionally independent of
    /// applicability and still uses the same single-flight operation.
    func startManualDownload() async {
        await startIfNeeded()
    }

    /// Starts or joins the current download. Concurrent callers await one
    /// operation; a failed run leaves no task behind, so manual retry is clean.
    private func startIfNeeded() async {
        if let activeTask {
            _ = await activeTask.value
            return
        }

        if publishReadyIfInstalledAndIdle() {
            return
        }

        let runID = UUID()
        activeRunID = runID
        state = .downloading

        let operation = download
        let task = Task<Result<Void, Error>, Never> {
            await Self.runBoundedDownload(operation)
        }
        activeTask = task

        let result = await task.value
        guard activeRunID == runID else {
            // The stale operation result has no authority. Physical helper
            // availability is different: when no newer generation is active,
            // a fresh positive disk fact is safe to expose as lifecycle truth.
            _ = publishReadyIfInstalledAndIdle()
            return
        }
        activeTask = nil
        activeRunID = nil

        if publishReadyIfInstalledAndIdle() {
            return
        }

        switch result {
        case .success:
            state = .failed(.incomplete)
        case .failure(let error as CancellationError):
            _ = error
            state = .absent
        case .failure(let error):
            state = .failed(Self.failureCategory(for: error))
        }
    }

    /// Invalidates publication synchronously before cancellation reaches the
    /// operation. A late result remains operationally stale, but its waiter may
    /// reconcile a fresh positive disk fact after every newer run is idle.
    func cancel() {
        invalidateActiveRun()
    }

    private func invalidateActiveRun() {
        activeRunID = nil
        let task = activeTask
        activeTask = nil
        task?.cancel()
        state = .absent
    }

    func retry() async {
        await startManualDownload()
    }

    /// Publishes only immutable positive availability. A false check must not
    /// erase a newer bounded failure or fabricate absence, and an active
    /// generation keeps ownership of its visible `.downloading` state.
    @discardableResult
    private func publishReadyIfInstalledAndIdle() -> Bool {
        guard activeTask == nil, activeRunID == nil, isDownloaded() else {
            return false
        }
        state = .ready
        return true
    }

    /// The helper download has no internal deadline: a hung transfer would pin
    /// `.downloading` forever, and `startIfNeeded`'s single-flight join means
    /// "Retry" would silently await the same hung task. Poll a first-wins
    /// completion box (mirroring ModelRegistry's watchdogs — a task group
    /// cannot exit while a non-cooperative child is still awaiting) and
    /// abandon the operation at the deadline.
    nonisolated private static func runBoundedDownload(
        _ operation: @escaping DownloadOperation,
        timeoutSeconds: TimeInterval = 900
    ) async -> Result<Void, Error> {
        let completion = DownloadCompletionBox()
        let opTask = Task.detached(priority: .utility) {
            do {
                try await operation()
                completion.finish(.success(()))
            } catch {
                completion.finish(.failure(error))
            }
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if let result = completion.currentResult() {
                return result
            }
            if Task.isCancelled {
                await Self.cancelAndDrain(opTask, completion: completion)
                return .failure(CancellationError())
            }
            if Date() >= deadline {
                await Self.cancelAndDrain(opTask, completion: completion)
                return .failure(URLError(.timedOut))
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Returning while the physical operation is still writing would let a
    /// subsequent retry start a second download into the same cache directory
    /// — two writers racing cancellation cleanup. URLSession cancellation
    /// lands promptly, so wait a bounded grace period for the operation to
    /// actually terminate before releasing single-flight ownership.
    nonisolated private static func cancelAndDrain(
        _ opTask: Task<Void, Never>,
        completion: DownloadCompletionBox,
        graceSeconds: TimeInterval = 10
    ) async {
        opTask.cancel()
        let grace = Date().addingTimeInterval(graceSeconds)
        while completion.currentResult() == nil, Date() < grace {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    nonisolated private static func failureCategory(
        for error: Error
    ) -> VocabularyBoostHelperFailureCategory {
        let bridged = error as NSError
        if bridged.domain == NSURLErrorDomain {
            return .network
        }
        if bridged.domain == NSCocoaErrorDomain || bridged.domain == NSPOSIXErrorDomain {
            return .storage
        }
        return .unknown
    }
}

private final class DownloadCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        lock.withLock {
            guard self.result == nil else { return }
            self.result = result
        }
    }

    func currentResult() -> Result<Void, Error>? {
        lock.withLock { result }
    }
}
