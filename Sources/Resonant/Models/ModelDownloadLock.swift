import Darwin
import FluidAudio
import Foundation
import os

/// Cross-process advisory lock over the shared FluidAudio model cache.
///
/// The app is unsandboxed, so the dev build (com.resonance.resonant.dev) and the
/// release build both write to `~/Library/Application Support/FluidAudio/Models`.
/// FluidAudio's downloader skips files that already exist and moves temp files
/// into place with no locking, so two concurrent downloads interleave one's
/// remove/move against the other's existence check and leave a half-written
/// bundle behind. A single `flock`'d file beside the cache serializes whole
/// downloads across processes.
enum ModelDownloadLock {

    private static let log = Logger.resonant("ModelDownloadLock")

    private static let lockFileName = ".resonant-download.lock"

    /// Runs `body` while holding the exclusive cache lock. If the lock can't be
    /// taken (unwritable cache parent, EOVERFLOW, …) the download proceeds
    /// unlocked — a contention risk beats refusing to install the model.
    ///
    /// The wait is unbounded here; it is bounded by the registry's preparing-phase
    /// stall watchdog, so a progress tick is emitted before blocking to measure
    /// that budget from the start of the wait rather than from the last real tick.
    static func withLock<T>(
        reportingWaitTo onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void,
        _ body: () async throws -> T
    ) async rethrows -> T {
        onProgress(ModelDownloadProgress(fraction: 0, phase: .preparing))
        let descriptor = await acquire()
        defer { release(descriptor) }
        return try await body()
    }

    /// `flock` blocks its thread for as long as the peer download runs, so it
    /// must not run on the cooperative pool (or the main actor).
    private static func acquire() async -> Int32? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: openAndLock())
            }
        }
    }

    private static func openAndLock() -> Int32? {
        let url = MLModelConfigurationUtils.defaultModelsDirectory()
            .appendingPathComponent(lockFileName)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            log.error("Model cache lock unavailable (open failed: \(errno, privacy: .public))")
            return nil
        }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                log.error("Model cache lock unavailable (flock failed: \(errno, privacy: .public))")
                close(descriptor)
                return nil
            }
        }
        return descriptor
    }

    private static func release(_ descriptor: Int32?) {
        guard let descriptor else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
