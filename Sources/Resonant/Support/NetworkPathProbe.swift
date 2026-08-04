import Foundation
import Network

/// One-shot snapshot of the current network path, for decisions like
/// "should we start a large background download unprompted?"
enum NetworkPathProbe {

    /// True when the active path is metered (personal hotspot, cellular) or
    /// in Low Data Mode. If the monitor never reports within `timeout`, this
    /// resolves to `false` — an inconclusive probe should not disable the
    /// behavior it guards.
    static func currentPathIsExpensive(timeout: Duration = .seconds(2)) async -> Bool {
        let monitor = NWPathMonitor()
        let result: Bool = await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                guard gate.claim() else { return }
                continuation.resume(returning: false)
            }
            monitor.pathUpdateHandler = { path in
                guard gate.claim() else { return }
                timeoutTask.cancel()
                continuation.resume(returning: path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "com.resonant.network-path-probe"))
        }
        monitor.cancel()
        return result
    }

    /// The timeout and pathUpdateHandler race, and the handler can fire more
    /// than once; whoever claims first resumes the continuation.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let isFirst = !resumed
            resumed = true
            return isFirst
        }
    }
}
