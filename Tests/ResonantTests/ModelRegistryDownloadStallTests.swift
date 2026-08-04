import Foundation
import XCTest
@testable import Resonant

final class ModelRegistryDownloadStallTests: XCTestCase {

    @MainActor
    func testPrepareActiveTimesOutWhenDownloadStopsMakingProgress() async throws {
        let stalledModel = StalledDownloadTranscriber()
        defer { stalledModel.unblockDownload() }

        let registry = ModelRegistry(
            adapters: [stalledModel],
            downloadStallPolicy: ModelDownloadStallPolicy(
                downloadTimeoutSeconds: 0.05,
                preparingTimeoutSeconds: 0.05,
                pollIntervalNanoseconds: 5_000_000,
                loadTimeoutSeconds: 0.05
            )
        )

        let startedAt = Date()

        do {
            try await registry.prepareActive(source: .settings)
            XCTFail("Expected stalled download to time out")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("made no progress"),
                "Expected stall timeout error, got: \(error.localizedDescription)"
            )
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertFalse(registry.isDownloading)
        XCTAssertNotNil(registry.downloadError)

        guard case .failed(let message) = registry.preparationState else {
            XCTFail("Expected failed preparation state, got \(registry.preparationState)")
            return
        }
        XCTAssertTrue(message.contains("made no progress"))
    }

    /// The connecting / file-listing window is silent by design — the backend
    /// makes several HuggingFace API calls without emitting progress. It must be
    /// governed by the generous preparing budget, not the byte-transfer budget,
    /// or a slow-but-working listing gets killed (the reported 120s "nothing"
    /// onboarding failure).
    @MainActor
    func testPreparingPhaseIsNotKilledByDownloadStallBudget() async throws {
        let stalledModel = StalledDownloadTranscriber(stallPhase: .preparing)
        defer { stalledModel.unblockDownload() }

        let registry = ModelRegistry(
            adapters: [stalledModel],
            downloadStallPolicy: ModelDownloadStallPolicy(
                downloadTimeoutSeconds: 0.05,  // tiny — would fire at once if applied
                preparingTimeoutSeconds: 100,  // generous — listing must survive
                pollIntervalNanoseconds: 5_000_000,
                loadTimeoutSeconds: 0.05
            )
        )

        let task = Task { try await registry.prepareActive(source: .settings) }
        // Far longer than the download budget: had the preparing phase been held
        // to it, the watchdog would have fired many times over by now.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(registry.isDownloading, "Preparing phase should not hit the download stall budget")
        XCTAssertNil(registry.downloadError)

        stalledModel.unblockDownload()
        _ = try? await task.value
    }

    @MainActor
    func testPrepareActiveTimesOutAndPurgesCorruptCacheBeforeRetry() async throws {
        let model = LoadTimeoutTranscriber()
        let registry = ModelRegistry(
            adapters: [model],
            downloadStallPolicy: ModelDownloadStallPolicy(
                downloadTimeoutSeconds: 0.05,
                preparingTimeoutSeconds: 0.05,
                pollIntervalNanoseconds: 5_000_000,
                loadTimeoutSeconds: 0.05,
                loadDrainGraceSeconds: 0.5
            )
        )

        do {
            try await registry.prepareActive(source: .settings)
            XCTFail("Expected load timeout")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("taking too long to load"),
                "Expected load timeout error, got: \(error.localizedDescription)"
            )
        }

        XCTAssertFalse(registry.isDownloading)
        XCTAssertNotNil(registry.downloadError)
        XCTAssertEqual(model.purgeCallCount, 1)
        XCTAssertEqual(model.downloadCallCount, 2)

        guard case .failed(let message) = registry.preparationState else {
            XCTFail("Expected failed preparation state, got \(registry.preparationState)")
            return
        }
        XCTAssertTrue(message.contains("taking too long to load"))
    }

    /// The purge-and-redownload recovery writes into the very directory the
    /// abandoned load may still be writing to, so the load has to be stopped and
    /// drained before the timeout is reported.
    @MainActor
    func testLoadIsFullyStoppedBeforeRecoveryPurges() async throws {
        let model = DrainingLoadTranscriber()
        let registry = ModelRegistry(
            adapters: [model],
            downloadStallPolicy: ModelDownloadStallPolicy(
                downloadTimeoutSeconds: 0.05,
                preparingTimeoutSeconds: 0.05,
                pollIntervalNanoseconds: 5_000_000,
                loadTimeoutSeconds: 0.05,
                loadDrainGraceSeconds: 2
            )
        )

        _ = try? await registry.prepareActive(source: .settings)

        XCTAssertEqual(model.purgeCallCount, 1)
        XCTAssertEqual(model.loadWasRunningAtPurge, false)
    }

    @MainActor
    func testPrepareActiveRecoversAfterLoadFailure() async throws {
        let model = RecoveringLoadTranscriber()
        let registry = ModelRegistry(
            adapters: [model],
            downloadStallPolicy: ModelDownloadStallPolicy(
                downloadTimeoutSeconds: 0.05,
                preparingTimeoutSeconds: 0.05,
                pollIntervalNanoseconds: 5_000_000,
                loadTimeoutSeconds: 0.05
            )
        )

        try await registry.prepareActive(source: .settings)

        XCTAssertTrue(registry.activeIsReady)
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.purgeCallCount, 1)
        XCTAssertEqual(model.downloadCallCount, 2)
        XCTAssertNil(registry.downloadError)
        XCTAssertEqual(registry.preparationState, .ready)
    }

    @MainActor
    func testPreparationTelemetryEmitsOneStartAndOneSuccessWithRecoveryMetadata() async throws {
        let model = RecoveringLoadTranscriber()
        var events: [(String, [String: Any])] = []
        var ticks = [100.0, 102.25]
        let registry = ModelRegistry(
            adapters: [model],
            downloadStallPolicy: ModelDownloadStallPolicy(
                downloadTimeoutSeconds: 0.05,
                preparingTimeoutSeconds: 0.05,
                pollIntervalNanoseconds: 5_000_000,
                loadTimeoutSeconds: 0.05
            ),
            captureAnalytics: { events.append(($0, $1)) },
            monotonicTime: { ticks.removeFirst() }
        )

        try await registry.prepareActive(source: .onboardingDownload)

        XCTAssertEqual(events.map(\.0), ["model_prepare_started", "model_prepare_succeeded"])
        let success = events[1].1
        XCTAssertEqual(success["model_family"] as? String, "other")
        XCTAssertEqual(success["source"] as? String, "onboarding_download")
        XCTAssertEqual(success["duration_ms"] as? Int, 2_250)
        XCTAssertEqual(success["recovery_used"] as? Bool, true)
        XCTAssertEqual(success["download_performed"] as? Bool, true)
        XCTAssertNil(success["model_id"])
        XCTAssertNil(success["error"])
    }

    @MainActor
    func testConcurrentAndAlreadyReadyCallsDoNotEmitAdditionalLifecycleEvents() async throws {
        var readyEvents: [(String, [String: Any])] = []
        let readyRegistry = ModelRegistry(
            adapters: [ReadyTranscriber()],
            captureAnalytics: { readyEvents.append(($0, $1)) }
        )
        try await readyRegistry.prepareActive(source: .settings)
        XCTAssertTrue(readyEvents.isEmpty)

        let stalledModel = StalledDownloadTranscriber()
        var events: [(String, [String: Any])] = []
        var ticks = [10.0, 11.0]
        let registry = ModelRegistry(
            adapters: [stalledModel],
            downloadStallPolicy: ModelDownloadStallPolicy(
                downloadTimeoutSeconds: 5,
                preparingTimeoutSeconds: 5,
                pollIntervalNanoseconds: 5_000_000,
                loadTimeoutSeconds: 0.05
            ),
            captureAnalytics: { events.append(($0, $1)) },
            monotonicTime: { ticks.removeFirst() }
        )
        let first = Task { try? await registry.prepareActive(source: .settings) }
        while !registry.isDownloading {
            await Task.yield()
        }

        try await registry.prepareActive(source: .settings)
        XCTAssertEqual(events.map(\.0), ["model_prepare_started"])

        stalledModel.unblockDownload()
        await first.value
        XCTAssertEqual(events.map(\.0), ["model_prepare_started", "model_prepare_failed"])
    }

    @MainActor
    func testCancellationProducesOneBoundedFailureTerminal() async throws {
        let model = CancellationTranscriber()
        var events: [(String, [String: Any])] = []
        var ticks = [20.0, 20.5]
        let registry = ModelRegistry(
            adapters: [model],
            downloadStallPolicy: ModelDownloadStallPolicy(
                downloadTimeoutSeconds: 30,
                preparingTimeoutSeconds: 30,
                pollIntervalNanoseconds: 5_000_000,
                loadTimeoutSeconds: 0.05
            ),
            captureAnalytics: { events.append(($0, $1)) },
            monotonicTime: { ticks.removeFirst() }
        )
        let task = Task { try await registry.prepareActive(source: .settings) }
        while !registry.isDownloading {
            await Task.yield()
        }
        task.cancel()
        _ = try? await task.value

        XCTAssertEqual(events.map(\.0), ["model_prepare_started", "model_prepare_failed"])
        XCTAssertEqual(events[1].1["error_kind"] as? String, "cancelled")
        XCTAssertEqual(events[1].1["duration_ms"] as? Int, 500)
    }

    @MainActor
    func testPreflightDiskFailureReportsNoDownloadAndStructuredKind() async throws {
        var events: [(String, [String: Any])] = []
        var ticks = [30.0, 30.25]
        let registry = ModelRegistry(
            adapters: [CancellationTranscriber()],
            captureAnalytics: { events.append(($0, $1)) },
            monotonicTime: { ticks.removeFirst() },
            diskSpaceCheck: { _ in
                throw ModelDiskCapacityError(message: "not enough disk")
            }
        )

        _ = try? await registry.prepareActive(source: .onboardingDownload)

        XCTAssertEqual(events.map(\.0), ["model_prepare_started", "model_prepare_failed"])
        XCTAssertEqual(events[1].1["error_kind"] as? String, "insufficient_disk")
        XCTAssertEqual(events[1].1["download_performed"] as? Bool, false)
        XCTAssertEqual(events[1].1["download_retry_count"] as? Int, 0)
    }

    @MainActor
    func testThreeFailedDownloadAttemptsReportTwoRetries() async throws {
        let model = NetworkFailureTranscriber()
        var events: [(String, [String: Any])] = []
        var ticks = [40.0, 41.0]
        let registry = ModelRegistry(
            adapters: [model],
            captureAnalytics: { events.append(($0, $1)) },
            monotonicTime: { ticks.removeFirst() },
            waitBeforeDownloadRetry: { _ in }
        )

        _ = try? await registry.prepareActive(source: .settings)

        XCTAssertEqual(model.downloadCallCount, 3)
        XCTAssertEqual(events.map(\.0), ["model_prepare_started", "model_prepare_failed"])
        XCTAssertEqual(events[1].1["error_kind"] as? String, "offline")
        XCTAssertEqual(events[1].1["download_performed"] as? Bool, true)
        XCTAssertEqual(events[1].1["download_retry_count"] as? Int, 2)
    }

    func testModelFailureKindTaxonomyIsBoundedAndDiagnostic() {
        XCTAssertEqual(
            ModelPreparationTelemetry.failureKind(
                for: ModelDownloadStallError(modelDisplayName: "M", timeoutSeconds: 1)
            ),
            "download_stalled"
        )
        XCTAssertEqual(
            ModelPreparationTelemetry.failureKind(for: ModelLoadTimeoutError(modelDisplayName: "M")),
            "load_timed_out"
        )
        XCTAssertEqual(
            ModelPreparationTelemetry.failureKind(for: ModelIncompleteDownloadError(modelDisplayName: "M")),
            "incomplete_download"
        )
        XCTAssertEqual(
            ModelPreparationTelemetry.failureKind(for: URLError(.networkConnectionLost)),
            "network_lost"
        )
        XCTAssertEqual(
            ModelPreparationTelemetry.failureKind(for: TranscriberError.downloadFailed("raw detail")),
            "download_failed"
        )
    }

    @MainActor
    func testBackgroundPreparationNeverDownloadsMissingModel() async throws {
        let model = NetworkFailureTranscriber()
        let registry = ModelRegistry(adapters: [model])

        for source in [ModelPreparationSource.appLaunch, .hotkeyRecovery, .dictationStart, .unknown] {
            do {
                try await registry.prepareActive(source: source)
                XCTFail("Expected consent requirement for \(source.rawValue)")
            } catch is ModelDownloadConsentRequiredError {
                // Expected: only a visible Download/Retry action may acquire a model.
            }
        }

        XCTAssertEqual(model.downloadCallCount, 0)
    }
}

private final class ReadyTranscriber: Transcriber, @unchecked Sendable {
    let id = "parakeet-ready"
    let displayName = "Ready"
    let description = "Already loaded"
    let isLoaded = true
    let isDownloaded = true
    let requiresDownload = true
    let downloadSizeBytes: Int64 = 1
    let modelURL: URL? = nil
    let supportedLanguageCodes: Set<String> = []
    let supportsAutoLanguageDetection = true

    func download(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {}
    func load() async throws {}
    func transcribe(audioURL: URL, language: String?) async throws -> String { "" }
    func transcribe(audioSamples: [Float], language: String?) async throws -> String { "" }
    func unload() {}
}

private final class CancellationTranscriber: Transcriber, @unchecked Sendable {
    let id = "qwen-cancellation"
    let displayName = "Cancellation"
    let description = "Cancellation-aware download"
    let isLoaded = false
    let isDownloaded = false
    let requiresDownload = true
    let downloadSizeBytes: Int64 = 1
    let modelURL: URL? = nil
    let supportedLanguageCodes: Set<String> = []
    let supportsAutoLanguageDetection = true

    func download(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        onProgress(ModelDownloadProgress(fraction: 0, phase: .preparing))
        try await Task.sleep(for: .seconds(30))
    }

    func load() async throws {}
    func transcribe(audioURL: URL, language: String?) async throws -> String { "" }
    func transcribe(audioSamples: [Float], language: String?) async throws -> String { "" }
    func unload() {}
}

private final class NetworkFailureTranscriber: Transcriber, @unchecked Sendable {
    let id = "parakeet-network-failure"
    let displayName = "Network Failure"
    let description = "Always fails download"
    let isLoaded = false
    let isDownloaded = false
    let requiresDownload = true
    let downloadSizeBytes: Int64 = 1
    let modelURL: URL? = nil
    let supportedLanguageCodes: Set<String> = []
    let supportsAutoLanguageDetection = true
    private let lock = NSLock()
    private var downloadCallCountStorage = 0

    var downloadCallCount: Int { lock.withLock { downloadCallCountStorage } }

    func download(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        lock.withLock { downloadCallCountStorage += 1 }
        throw URLError(.notConnectedToInternet)
    }

    func load() async throws {}
    func transcribe(audioURL: URL, language: String?) async throws -> String { "" }
    func transcribe(audioSamples: [Float], language: String?) async throws -> String { "" }
    func unload() {}
}

private final class StalledDownloadTranscriber: Transcriber, @unchecked Sendable {
    let id = "stalled-download"
    let displayName = "Stalled Download"
    let description = "Test model that reports one progress update and then blocks"
    let isLoaded = false
    let isDownloaded = false
    let requiresDownload = true
    let downloadSizeBytes: Int64 = 1
    let modelURL: URL? = nil
    let supportedLanguageCodes: Set<String> = []
    let supportsAutoLanguageDetection = true

    private let gate = StalledDownloadGate()
    private let stallPhase: ModelDownloadProgress.Phase

    init(stallPhase: ModelDownloadProgress.Phase = .downloading) {
        self.stallPhase = stallPhase
    }

    func download(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        onProgress(ModelDownloadProgress(fraction: stallPhase == .downloading ? 0.1 : 0, phase: stallPhase))
        await gate.wait()
    }

    func load() async throws {
        XCTFail("Load should not be reached for a stalled incomplete download")
    }

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        throw TranscriberError.notLoaded
    }

    func transcribe(audioSamples: [Float], language: String?) async throws -> String {
        throw TranscriberError.notLoaded
    }

    func unload() {}

    func unblockDownload() {
        gate.open()
    }
}

private final class StalledDownloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            var shouldResume = false
            lock.withLock {
                if isOpen {
                    shouldResume = true
                } else {
                    self.continuation = continuation
                }
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let continuation = lock.withLock {
            isOpen = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class LoadTimeoutTranscriber: Transcriber, @unchecked Sendable {
    let id = "load-timeout"
    let displayName = "Load Timeout"
    let description = "Test model that downloads successfully and then hangs while loading"
    var isLoaded: Bool { lock.withLock { loaded } }
    var isDownloaded: Bool { lock.withLock { downloaded } }
    let requiresDownload = true
    let downloadSizeBytes: Int64 = 1
    let modelURL: URL? = nil
    let supportedLanguageCodes: Set<String> = []
    let supportsAutoLanguageDetection = true

    private let lock = NSLock()
    private var downloaded = false
    private var loaded = false
    private var downloadCallCountStorage = 0
    private var purgeCallCountStorage = 0

    var downloadCallCount: Int { lock.withLock { downloadCallCountStorage } }
    var purgeCallCount: Int { lock.withLock { purgeCallCountStorage } }

    func download(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        lock.withLock {
            downloadCallCountStorage += 1
            downloaded = true
        }
        onProgress(ModelDownloadProgress(fraction: 0.5, phase: .downloading))
        onProgress(ModelDownloadProgress(fraction: 1.0, phase: .downloading))
    }

    func load() async throws {
        while true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        throw TranscriberError.notLoaded
    }

    func transcribe(audioSamples: [Float], language: String?) async throws -> String {
        throw TranscriberError.notLoaded
    }

    func unload() {
        lock.withLock { loaded = false }
    }

    func purgeDownloadedModel() {
        lock.withLock {
            purgeCallCountStorage += 1
            downloaded = false
            loaded = false
        }
    }
}

private final class DrainingLoadTranscriber: Transcriber, @unchecked Sendable {
    let id = "draining-load"
    let displayName = "Draining Load"
    let description = "Test model whose load hangs but exits on cancellation"
    var isLoaded: Bool { false }
    var isDownloaded: Bool { lock.withLock { downloaded } }
    let requiresDownload = true
    let downloadSizeBytes: Int64 = 1
    let modelURL: URL? = nil
    let supportedLanguageCodes: Set<String> = []
    let supportsAutoLanguageDetection = true

    private let lock = NSLock()
    private var downloaded = false
    private var loadIsRunning = false
    private var purgeCallCountStorage = 0
    private var loadWasRunningAtPurgeStorage: Bool?

    var purgeCallCount: Int { lock.withLock { purgeCallCountStorage } }
    var loadWasRunningAtPurge: Bool? { lock.withLock { loadWasRunningAtPurgeStorage } }

    func download(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        lock.withLock { downloaded = true }
        onProgress(ModelDownloadProgress(fraction: 1.0, phase: .downloading))
    }

    func load() async throws {
        lock.withLock { loadIsRunning = true }
        defer { lock.withLock { loadIsRunning = false } }
        while true {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        throw TranscriberError.notLoaded
    }

    func transcribe(audioSamples: [Float], language: String?) async throws -> String {
        throw TranscriberError.notLoaded
    }

    func unload() {}

    func purgeDownloadedModel() {
        lock.withLock {
            purgeCallCountStorage += 1
            if loadWasRunningAtPurgeStorage == nil {
                loadWasRunningAtPurgeStorage = loadIsRunning
            }
            downloaded = false
        }
    }
}

private final class RecoveringLoadTranscriber: Transcriber, @unchecked Sendable {
    let id = "recovering-load"
    let displayName = "Recovering Load"
    let description = "Test model that fails once during load and then succeeds"
    var isLoaded: Bool { lock.withLock { loaded } }
    var isDownloaded: Bool { lock.withLock { downloaded } }
    let requiresDownload = true
    let downloadSizeBytes: Int64 = 1
    let modelURL: URL? = nil
    let supportedLanguageCodes: Set<String> = []
    let supportsAutoLanguageDetection = true

    private let lock = NSLock()
    private var downloaded = false
    private var loaded = false
    private var loadCallCountStorage = 0
    private var purgeCallCountStorage = 0
    private var downloadCallCountStorage = 0

    var downloadCallCount: Int { lock.withLock { downloadCallCountStorage } }
    var purgeCallCount: Int { lock.withLock { purgeCallCountStorage } }

    func download(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        lock.withLock {
            downloadCallCountStorage += 1
            downloaded = true
        }
        onProgress(ModelDownloadProgress(fraction: 1.0, phase: .downloading))
    }

    func load() async throws {
        let shouldThrow = lock.withLock {
            loadCallCountStorage += 1
            if loadCallCountStorage == 1 {
                return true
            }
            loaded = true
            return false
        }
        if shouldThrow {
            throw TranscriberError.transcriptionFailed("synthetic load failure")
        }
    }

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        throw TranscriberError.notLoaded
    }

    func transcribe(audioSamples: [Float], language: String?) async throws -> String {
        throw TranscriberError.notLoaded
    }

    func unload() {
        lock.withLock { loaded = false }
    }

    func purgeDownloadedModel() {
        lock.withLock {
            purgeCallCountStorage += 1
            downloaded = false
            loaded = false
        }
    }
}
