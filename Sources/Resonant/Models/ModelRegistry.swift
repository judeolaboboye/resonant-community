import Foundation
import Observation

enum ModelPreparationState: Equatable {
    case idle
    case downloading(progress: Double)
    case loading
    case ready
    case failed(message: String)

    var isPreparing: Bool {
        switch self {
        case .downloading, .loading:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    var notchStatus: (stage: String, progress: Double) {
        switch self {
        case .downloading(let progress):
            return ("Downloading local model...", min(max(progress * 0.8, 0), 0.8))
        case .loading:
            return ("Loading local model...", 0.9)
        case .ready:
            return ("Local model ready", 1)
        case .failed:
            return ("Model failed to load", 0)
        case .idle:
            return ("Preparing local model...", 0)
        }
    }
}

/// Central registry of available STT models.
/// SettingsManager stores the selected model ID; this resolves it to a live adapter.
@MainActor
@Observable
final class ModelRegistry {

    private(set) var all: [any Transcriber]
    private(set) var active: (any Transcriber)?

    // Download state
    var downloadProgress: Double = 0
    var downloadPhase: ModelDownloadProgress.Phase = .preparing
    var isDownloading = false
    var downloadError: String?
    var preparationState: ModelPreparationState = .idle

    /// User-facing status for the active preparation, or nil when not preparing.
    /// Surfaces the otherwise-silent "connecting / listing files" window so the
    /// UI isn't stuck on a frozen "0%" while the model is actually being fetched.
    var preparationStatusText: String? {
        guard isDownloading else { return nil }
        switch preparationState {
        case .loading:
            return "Loading local model…"
        default:
            return downloadPhase.statusText
        }
    }
    private var activePreparationRunID: UUID?
    private let downloadStallPolicy: ModelDownloadStallPolicy
    private let captureAnalytics: (_ event: String, _ properties: [String: Any]) -> Void
    private let monotonicTime: () -> TimeInterval
    private let diskSpaceCheck: (any Transcriber) throws -> Void
    private let waitBeforeDownloadRetry: @Sendable (_ retryNumber: Int) async throws -> Void

    init(
        adapters: [any Transcriber]? = nil,
        downloadStallPolicy: ModelDownloadStallPolicy = .default,
        captureAnalytics: ((_ event: String, _ properties: [String: Any]) -> Void)? = nil,
        monotonicTime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        diskSpaceCheck: ((any Transcriber) throws -> Void)? = nil,
        waitBeforeDownloadRetry: (@Sendable (_ retryNumber: Int) async throws -> Void)? = nil
    ) {
        let adapters = adapters ?? Self.makeDefaultAdapters()
        all = adapters
        active = adapters.first
        self.downloadStallPolicy = downloadStallPolicy
        self.captureAnalytics = captureAnalytics ?? { event, properties in
            AnalyticsManager.shared.capture(event, properties: properties)
        }
        self.monotonicTime = monotonicTime
        self.diskSpaceCheck = diskSpaceCheck ?? { model in
            try Self.ensureDiskSpace(for: model)
        }
        self.waitBeforeDownloadRetry = waitBeforeDownloadRetry ?? { retryNumber in
            try await Task.sleep(for: .seconds(retryNumber == 1 ? 5 : 15))
        }
    }

    private static func makeDefaultAdapters() -> [any Transcriber] {
        var adapters: [any Transcriber] = [
            FluidAudioAdapter(),
        ]
        if #available(macOS 15, *) {
            adapters.append(Qwen3AudioAdapter())
            // The Community distribution does not offer Cohere until the
            // derivative model's redistribution terms are unambiguous.
            if AppRuntime.distributionFlavor == .official {
                adapters.append(CohereTranscribeAdapter())
            }
        }
        return adapters
    }

    func select(id: String, persistSelection: Bool = true) {
        guard !isDownloading else { return }
        if let match = all.first(where: { $0.id == id }) {
            active = match
            preparationState = match.isLoaded ? .ready : .idle
            downloadProgress = match.isDownloaded ? 1 : 0
            downloadError = nil
            if persistSelection {
                SettingsManager.shared.selectedModelId = match.id
            }
        }
    }

    /// Load the active model. Downloads first if needed.
    /// Heavy work (CoreML compilation) runs on a detached task so the main actor stays responsive.
    /// - Parameter onProgress: Called with (stage description, progress 0…1) as loading advances.
    func prepareActive(
        source: ModelPreparationSource = .unknown,
        onProgress: (@Sendable (String, Double) -> Void)? = nil
    ) async throws {
        guard !isDownloading else { return }
        guard let model = active else { return }
        if model.isLoaded {
            preparationState = .ready
            return
        }

        if !model.isDownloaded, !source.permitsModelDownload {
            let error = ModelDownloadConsentRequiredError(modelDisplayName: model.displayName)
            downloadError = error.localizedDescription
            preparationState = .failed(message: error.localizedDescription)
            throw error
        }

        let runID = UUID()
        let startedAt = monotonicTime()
        let downloadRequired = !model.isDownloaded
        var phase = downloadRequired ? "download" : "load"
        activePreparationRunID = runID
        isDownloading = true
        preparationState = model.isDownloaded ? .loading : .downloading(progress: 0)
        downloadProgress = model.isDownloaded ? 1 : 0
        downloadPhase = .preparing
        downloadError = nil
        captureAnalytics(
            ModelPreparationTelemetry.Event.started.rawValue,
            ModelPreparationTelemetry.properties(
                modelID: model.id,
                source: source,
                phase: phase,
                downloadRequired: downloadRequired
            )
        )
        defer {
            if activePreparationRunID == runID {
                isDownloading = false
                activePreparationRunID = nil
            }
        }

        var didAttemptRecovery = false
        var didInvokeDownload = false
        var downloadInvocationCount = 0
        var downloadRetryCount = 0

        do {
            while true {
                if !model.isDownloaded {
                    phase = "download"
                    try diskSpaceCheck(model)
                    SentryManager.shared.downloadStart(modelId: model.id)
                    do {
                        didInvokeDownload = true
                        downloadInvocationCount += 1
                        try await runModelDownloadWithStallTimeout(
                            modelDisplayName: model.displayName,
                            policy: downloadStallPolicy
                        ) { markProgress in
                            try await model.download { update in
                                markProgress(update.phase)
                                Task { @MainActor [weak self = self] in
                                    guard self?.activePreparationRunID == runID else { return }
                                    self?.downloadPhase = update.phase
                                    self?.downloadProgress = update.fraction
                                    self?.preparationState = .downloading(progress: update.fraction)
                                    onProgress?(update.phase.statusText, update.fraction * 0.8)
                                }
                            }
                        }
                    } catch let error as CancellationError {
                        throw error
                    } catch let error as ModelDownloadStallError {
                        // A stall already burned its full silence budget with
                        // zero progress — surface it now; the retry button and
                        // the hotkey re-kick own recovery.
                        SentryManager.shared.downloadError(modelId: model.id, error: error)
                        throw error
                    } catch {
                        // One transient HF 429/503 or dropped connection must
                        // not fail the whole install. Completed files are
                        // skipped on the next pass, so retrying is cheap.
                        SentryManager.shared.downloadError(modelId: model.id, error: error)
                        guard downloadInvocationCount < 3 else { throw error }
                        downloadRetryCount += 1
                        onProgress?("Retrying download…", downloadProgress * 0.8)
                        try await waitBeforeDownloadRetry(downloadRetryCount)
                        continue
                    }
                    SentryManager.shared.downloadComplete(modelId: model.id)
                    guard model.isDownloaded else {
                        throw ModelIncompleteDownloadError(modelDisplayName: model.displayName)
                    }
                }
                phase = "load"
                SentryManager.shared.modelLoad(modelId: model.id)
                preparationState = .loading
                onProgress?("Loading local model…", 0.9)
                do {
                    if !model.isLoaded {
                        try await runModelLoadWithTimeout(
                            modelDisplayName: model.displayName,
                            timeoutSeconds: downloadStallPolicy.loadTimeoutSeconds,
                            drainGraceSeconds: downloadStallPolicy.loadDrainGraceSeconds
                        ) {
                            try await model.load()
                        }
                    }
                    preparationState = .ready
                    SentryManager.shared.modelReady(modelId: model.id)
                    break
                } catch let error as CancellationError {
                    throw error
                } catch {
                    // A corrupt cache may require a fresh download. Only do
                    // that while servicing the user's visible Download/Retry
                    // action; launch and hotkey paths remain network-silent.
                    guard source.permitsModelDownload else {
                        throw error
                    }
                    guard !didAttemptRecovery else {
                        throw error
                    }
                    didAttemptRecovery = true
                    phase = "download"
                    model.purgeDownloadedModel()
                    downloadProgress = 0
                    downloadPhase = .preparing
                    downloadError = nil
                    preparationState = .downloading(progress: 0)
                    onProgress?("Downloading local model…", 0)
                    continue
                }
            }
            captureAnalytics(
                ModelPreparationTelemetry.Event.succeeded.rawValue,
                ModelPreparationTelemetry.properties(
                    modelID: model.id,
                    source: source,
                    phase: phase,
                    downloadRequired: downloadRequired,
                    additional: [
                        "download_performed": didInvokeDownload,
                        "duration_ms": elapsedMilliseconds(since: startedAt),
                        "download_retry_count": downloadRetryCount,
                        "recovery_used": didAttemptRecovery,
                    ]
                )
            )
        } catch {
            // Breadcrumbs only ship attached to an event, and onboarding's
            // callers all `try?` — without a real capture here, every
            // first-run install failure is invisible in telemetry.
            if !AnalyticsEventSanitizer.isCancellation(error) {
                SentryManager.shared.modelError(modelId: model.id, error: error)
                SentryManager.shared.captureException(error, context: [
                    "model_id": model.id,
                    "phase": phase,
                    "download_attempts": downloadInvocationCount
                ])
            }
            captureAnalytics(
                ModelPreparationTelemetry.Event.failed.rawValue,
                ModelPreparationTelemetry.properties(
                    modelID: model.id,
                    source: source,
                    phase: phase,
                    downloadRequired: downloadRequired,
                    additional: [
                        "download_performed": didInvokeDownload,
                        "duration_ms": elapsedMilliseconds(since: startedAt),
                        "download_retry_count": downloadRetryCount,
                        "recovery_used": didAttemptRecovery,
                        "error_kind": ModelPreparationTelemetry.failureKind(for: error),
                    ]
                )
            )
            downloadError = error.localizedDescription
            preparationState = .failed(message: error.localizedDescription)
            throw error
        }
    }

    private func elapsedMilliseconds(since startedAt: TimeInterval) -> Int {
        max(0, Int((monotonicTime() - startedAt) * 1_000))
    }

    var activeIsReady: Bool { active?.isLoaded ?? false }

    /// A 700 MB download onto a nearly-full disk fails with a raw Cocoa error
    /// and, worse, the load-phase self-heal then churns the same 700 MB
    /// forever. Refuse up front with copy the user can act on.
    private static func ensureDiskSpace(for model: any Transcriber) throws {
        let headroomBytes: Int64 = 300_000_000
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let supportURL,
              let values = try? supportURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else {
            return  // Capacity unknowable — don't block the install on it.
        }
        let remaining = max(0, model.downloadSizeBytes - model.onDiskCacheBytes)
        let required = remaining + headroomBytes
        if available < required {
            let neededGB = Double(required) / 1_000_000_000
            throw ModelDiskCapacityError(message: String(
                format: "Not enough free disk space — about %.1f GB is needed. Free up space, then retry.",
                neededGB
            ))
        }
    }
}

struct ModelDownloadStallPolicy: Sendable {
    /// Stall budget for the byte-transfer phase, where the backend emits a
    /// progress tick per downloaded chunk. Silence here really does mean a
    /// hung transfer.
    let downloadTimeoutSeconds: TimeInterval
    /// Stall budget for the preparing (connecting / file-listing) and finalizing
    /// phases. The backend makes several sequential HuggingFace API calls while
    /// listing files and emits no progress in between, so this window is silent
    /// by design — a slow or rate-limited listing must not be misread as a hung
    /// download. Hence a far more generous budget than the byte-transfer phase.
    let preparingTimeoutSeconds: TimeInterval
    let pollIntervalNanoseconds: UInt64
    let loadTimeoutSeconds: TimeInterval
    /// How long the load watchdog waits for the abandoned load task to actually
    /// stop after the deadline fires. The caller's recovery purges and re-fetches
    /// the same cache directory, so control must not return while the load — which
    /// can itself download and write files — is still running.
    let loadDrainGraceSeconds: TimeInterval

    init(
        downloadTimeoutSeconds: TimeInterval,
        preparingTimeoutSeconds: TimeInterval,
        pollIntervalNanoseconds: UInt64,
        loadTimeoutSeconds: TimeInterval,
        loadDrainGraceSeconds: TimeInterval = 15
    ) {
        self.downloadTimeoutSeconds = downloadTimeoutSeconds
        self.preparingTimeoutSeconds = preparingTimeoutSeconds
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.loadTimeoutSeconds = loadTimeoutSeconds
        self.loadDrainGraceSeconds = loadDrainGraceSeconds
    }

    static let `default` = ModelDownloadStallPolicy(
        downloadTimeoutSeconds: 120,
        preparingTimeoutSeconds: 300,
        pollIntervalNanoseconds: 250_000_000,
        loadTimeoutSeconds: 240
    )

    func timeoutSeconds(for phase: ModelDownloadProgress.Phase) -> TimeInterval {
        switch phase {
        case .downloading:
            return downloadTimeoutSeconds
        case .preparing, .finalizing:
            return preparingTimeoutSeconds
        }
    }
}

struct ModelDownloadStallError: LocalizedError {
    let modelDisplayName: String
    let timeoutSeconds: TimeInterval

    var errorDescription: String? {
        "\(modelDisplayName) download made no progress for \(Int(timeoutSeconds)) seconds. Try again."
    }
}

private final class ModelDownloadActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgressAt = Date()
    // Until the first tick arrives the backend is contacting the host and
    // listing files, so treat the initial phase as `.preparing`.
    private var phase: ModelDownloadProgress.Phase = .preparing

    func markProgress(phase: ModelDownloadProgress.Phase) {
        lock.withLock {
            lastProgressAt = Date()
            self.phase = phase
        }
    }

    /// The current phase if it has exceeded its (phase-specific) stall budget,
    /// otherwise nil.
    func stalledPhase(policy: ModelDownloadStallPolicy) -> ModelDownloadProgress.Phase? {
        lock.withLock {
            let elapsed = Date().timeIntervalSince(lastProgressAt)
            return elapsed >= policy.timeoutSeconds(for: phase) ? phase : nil
        }
    }
}

private final class ModelDownloadCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        lock.withLock {
            guard self.result == nil else { return }
            self.result = result
        }
    }

    func currentResult() -> Result<Void, Error>? {
        lock.withLock {
            result
        }
    }
}

struct ModelLoadTimeoutError: LocalizedError {
    let modelDisplayName: String

    var errorDescription: String? {
        "\(modelDisplayName) is taking too long to load. Try again."
    }
}

struct ModelDiskCapacityError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct ModelIncompleteDownloadError: LocalizedError {
    let modelDisplayName: String

    var errorDescription: String? {
        "\(modelDisplayName) files are incomplete."
    }
}

struct ModelDownloadConsentRequiredError: LocalizedError {
    let modelDisplayName: String

    var errorDescription: String? {
        "(modelDisplayName) is not downloaded. Open Settings and choose Download."
    }
}

private func runModelDownloadWithStallTimeout(
    modelDisplayName: String,
    policy: ModelDownloadStallPolicy,
    operation: @escaping @Sendable (_ markProgress: @escaping @Sendable (ModelDownloadProgress.Phase) -> Void) async throws -> Void
) async throws {
    let activity = ModelDownloadActivity()
    let completion = ModelDownloadCompletion()
    let downloadTask = Task.detached(priority: .userInitiated) {
        do {
            try Task.checkCancellation()
            try await operation { phase in
                activity.markProgress(phase: phase)
            }
            completion.finish(.success(()))
        } catch {
            completion.finish(.failure(error))
        }
    }
    defer { downloadTask.cancel() }

    while true {
        if let result = completion.currentResult() {
            try result.get()
            return
        }

        if let stalledPhase = activity.stalledPhase(policy: policy) {
            throw ModelDownloadStallError(
                modelDisplayName: modelDisplayName,
                timeoutSeconds: policy.timeoutSeconds(for: stalledPhase)
            )
        }

        try await Task.sleep(nanoseconds: policy.pollIntervalNanoseconds)
    }
}

// Deliberately NOT a task group: a group cannot exit until every child
// finishes, and a child awaiting a load that ignores cancellation (CoreML
// compilation, or `Task.value`, which never throws on waiter cancellation)
// would block the timeout from ever propagating — the watchdog itself would
// hang. Mirror the download watchdog instead: poll a first-wins completion
// box and, at the deadline, cancel the load task and drain it for a bounded
// grace period so no writer outlives the call.
private func runModelLoadWithTimeout(
    modelDisplayName: String,
    timeoutSeconds: TimeInterval,
    drainGraceSeconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    let completion = ModelDownloadCompletion()
    let loadTask = Task.detached(priority: .userInitiated) {
        do {
            try await operation()
            completion.finish(.success(()))
        } catch {
            completion.finish(.failure(error))
        }
    }
    defer { loadTask.cancel() }

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while true {
        if let result = completion.currentResult() {
            try result.get()
            return
        }
        if Date() >= deadline {
            // The abandoned load may still be writing into the model cache —
            // FluidAudio's load re-downloads whatever is missing — while the
            // caller's recovery purges that same directory and starts a fresh
            // download into it. Stop the load and wait for it to actually
            // terminate before handing back control.
            loadTask.cancel()
            let graceDeadline = Date().addingTimeInterval(drainGraceSeconds)
            while completion.currentResult() == nil, !Task.isCancelled, Date() < graceDeadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            // A load that finished anyway during the drain is a real success;
            // reporting a timeout would purge a healthy cache.
            if let result = completion.currentResult(), case .success = result {
                return
            }
            try Task.checkCancellation()
            throw ModelLoadTimeoutError(modelDisplayName: modelDisplayName)
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
}
