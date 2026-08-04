import Foundation

/// Process-wide serializer for AVCapture microphone lifecycle work.
///
/// `AVCaptureDeviceInput` installs and removes private KVO observations on its
/// device while opening and releasing. Keeping every input construction,
/// session stop, and final input release on this queue prevents dictation and
/// meeting capture from mutating that shared device lifecycle concurrently.
enum AudioCaptureHardwareCoordinator {
    static let lifecycleQueue = DispatchQueue(
        label: "com.resonance.resonant.audio-capture",
        qos: .userInitiated
    )
}

/// Thread-safe publication gate for queued warm-session requests.
///
/// MainActor code publishes the newest generation synchronously. A lifecycle
/// block must pass `performIfCurrent` before touching AVFoundation, so work that
/// was queued before wake/device recovery can self-veto when it finally runs.
final class AudioWarmRequestGenerationGate: @unchecked Sendable {
    private let stateLock = NSLock()
    private let inputConstructionLock = NSLock()
    private var latestGeneration: UInt64 = 0

    func publish(_ generation: UInt64) {
        // Publish the veto before waiting for an input constructor that may
        // already be in flight. That lets the constructor's caller observe the
        // new generation immediately after initialization and abandon the rest
        // of the session build. Waiting here also means that once this method
        // returns, no older AVCaptureDeviceInput initializer is still running.
        stateLock.lock()
        latestGeneration = generation
        stateLock.unlock()

        inputConstructionLock.lock()
        inputConstructionLock.unlock()
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        let isCurrent = latestGeneration == generation
        stateLock.unlock()
        return isCurrent
    }

    @discardableResult
    func performIfCurrent(
        _ generation: UInt64,
        operation: () -> Void
    ) -> Bool {
        // The generation check and the crashing AVCaptureDeviceInput
        // initializer form one linearizable claim. `publish` can still make a
        // newer generation visible while the initializer is running, but it
        // cannot return until this seam has completed.
        inputConstructionLock.lock()
        defer { inputConstructionLock.unlock() }
        guard isCurrent(generation) else { return false }
        operation()
        return true
    }
}

/// One-shot stop veto for an asynchronously enqueued capture-source start.
///
/// `stop()` may run before an async protocol hop reaches the lifecycle queue.
/// Publishing through this gate first ensures the delayed block cannot open an
/// input after its empty stop block has already been queued.
final class AudioCaptureStartGate: @unchecked Sendable {
    private let stateLock = NSLock()
    private let inputConstructionLock = NSLock()
    private var isStopped = false

    func publishStop() {
        stateLock.lock()
        isStopped = true
        stateLock.unlock()

        // Do not return to the caller while an input initializer that claimed
        // this source before the stop publication is still executing.
        inputConstructionLock.lock()
        inputConstructionLock.unlock()
    }

    var allowsStart: Bool {
        stateLock.lock()
        let allowsStart = !isStopped
        stateLock.unlock()
        return allowsStart
    }

    @discardableResult
    func performInputConstructionIfAllowed(
        _ operation: () throws -> Void
    ) rethrows -> Bool {
        inputConstructionLock.lock()
        defer { inputConstructionLock.unlock() }
        guard allowsStart else { return false }
        try operation()
        return true
    }
}
