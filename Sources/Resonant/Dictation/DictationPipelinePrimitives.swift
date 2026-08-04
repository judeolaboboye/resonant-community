import Foundation

enum DictationRecordingRetentionPolicy {
    /// The caller owns the finalized file until it is durably persisted or a
    /// recovery marker proves that it is safe to discard.
    case recoverable

    /// The pipeline owns the file and removes it whenever processing exits.
    /// Command captures use this because they are never represented by a
    /// recovery marker and must not accumulate raw voice data on disk.
    case ephemeral

    var deletesRecordingWhenPipelineExits: Bool {
        self == .ephemeral
    }

    func deletesRecordingAfterFailedFinalization(cancellationRequested: Bool) -> Bool {
        cancellationRequested || self == .ephemeral
    }
}

enum DictationShutdownCleanupPolicy {
    static func shouldDeleteRecorderArtifacts(
        isRecording: Bool,
        isStartingRecording: Bool,
        isFinishingCapture: Bool,
        hasRecoveryOwnership: Bool
    ) -> Bool {
        !isRecording
            && !isStartingRecording
            && !isFinishingCapture
            && !hasRecoveryOwnership
    }
}

enum DictationRecordingFileDeletion {
    static func removeIfPresent(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return !fileManager.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }
}

/// Tracks ownership of the single capture-start continuation. Audio cleanup can
/// finish before the cancelled AppState coroutine resumes, so a later capture
/// must be protected from stale success, error, and watchdog callbacks.
struct CaptureStartAttemptOwnership {
    private(set) var activeID: UUID?

    mutating func begin(id: UUID = UUID()) -> UUID {
        activeID = id
        return id
    }

    func owns(_ id: UUID) -> Bool {
        activeID == id
    }

    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }

    mutating func cancel() {
        activeID = nil
    }
}

enum DictationCancellationJoinPolicy {
    /// Pipeline work can be non-cooperative inside CoreML. Any live pipeline is
    /// retired asynchronously just like an unfinished audio start so Escape can
    /// return while AppState keeps the no-overlap barrier raised.
    static func requiresDeferredRetirement(
        hasPendingAudioFinalization: Bool,
        hasActivePipeline: Bool
    ) -> Bool {
        hasPendingAudioFinalization || hasActivePipeline
    }

    /// Once a result task exists, the terminal URL/recovery marker have moved
    /// out of the recorder pipeline and must be finalized by that result task.
    static func resultTaskOwnsTerminalArtifacts(hasActiveResultTask: Bool) -> Bool {
        hasActiveResultTask
    }
}

/// Completes only after the AppState stop/finalization coroutine has run all of
/// its catch/defer cleanup. Backend retirement alone is insufficient because
/// task waiter resume order is unspecified.
actor CaptureFinalizationRetirement {
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isComplete else { return }
        await withCheckedContinuation { continuation in
            if isComplete {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func complete() {
        guard !isComplete else { return }
        isComplete = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

/// A once gate used by latency races where the losing operation must not keep
/// the caller inside a structured-concurrency scope.
actor FirstResultGate<Value: Sendable> {
    private enum State {
        case pending(CheckedContinuation<Value, Never>?)
        case resolved(Value)
    }

    private var state: State = .pending(nil)

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        switch state {
        case .resolved:
            return false
        case .pending(let continuation):
            state = .resolved(value)
            continuation?.resume(returning: value)
            return true
        }
    }

    func value() async -> Value {
        switch state {
        case .resolved(let value):
            return value
        case .pending:
            return await withCheckedContinuation { continuation in
                switch state {
                case .resolved(let value):
                    continuation.resume(returning: value)
                case .pending:
                    state = .pending(continuation)
                }
            }
        }
    }
}

enum DictationAsyncDeadline {
    private enum ThrowingOutcome<Value: Sendable>: @unchecked Sendable {
        case success(Value)
        case failure(Error)
    }

    /// Waits for an independently-owned task without allowing that task's
    /// non-cooperative work to trap a cancelled caller. The source task is left
    /// alive for any other metadata consumer.
    static func valueUnlessCancelled<T: Sendable>(
        _ task: Task<T, Never>
    ) async -> T? {
        let gate = FirstResultGate<T?>()
        Task {
            let value = await task.value
            _ = await gate.resolve(value)
        }
        return await withTaskCancellationHandler {
            await gate.value()
        } onCancel: {
            Task { _ = await gate.resolve(nil) }
        }
    }

    /// Runs throwing work in an independently owned task so cancellation can
    /// stop the caller from waiting even when a synchronous decoder ignores
    /// cooperative cancellation. The source task remains alive to release its
    /// eventual value and resources normally.
    static func throwingValueUnlessCancelled<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let source = Task<ThrowingOutcome<T>, Never> {
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }

        guard let outcome = await valueUnlessCancelled(source) else {
            throw CancellationError()
        }
        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    /// Returns a task's value only when it arrives before the deadline. The
    /// supplied task is never cancelled: it is also attached to persisted
    /// metadata and may be consumed after this latency-sensitive call returns.
    static func valueIfReady<T: Sendable>(
        _ task: Task<T, Never>?,
        timeoutNanoseconds: UInt64
    ) async -> T? {
        guard let task else { return nil }

        let gate = FirstResultGate<T?>()
        Task {
            let value = await task.value
            _ = await gate.resolve(value)
        }
        let timeoutObserver = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            _ = await gate.resolve(nil)
        }

        let result = await withTaskCancellationHandler {
            await gate.value()
        } onCancel: {
            Task { _ = await gate.resolve(nil) }
        }
        timeoutObserver.cancel()
        return result
    }
}

/// Decides how a capture interacts with a not-yet-ready local model. Capture is
/// model-independent, so a trigger press while the model is still loading should
/// record now and wait briefly at stop time instead of failing upfront — the
/// dominant "model_not_ready" failures are bursts right after launch/wake where
/// the model becomes ready seconds later.
enum DictationModelReadinessPolicy {
    /// Bound on the post-stop wait for an in-flight model preparation. Loads
    /// settle in seconds; multi-minute downloads are still rejected at start.
    static let stopWaitSeconds: TimeInterval = 20
    static let pollIntervalNanoseconds: UInt64 = 50_000_000

    enum StartDisposition: Equatable {
        /// Model is loaded (or loading) — start recording normally.
        case proceed
        /// Model files exist but nothing is loading them — start recording and
        /// kick preparation so the model is ready by stop time.
        case proceedAndPrepare
        /// The model cannot become ready soon (none selected, mid-download,
        /// failed, not downloaded) — keep the upfront error.
        case reject
    }

    static func startDisposition(
        hasActiveModel: Bool,
        isLoaded: Bool,
        isDownloaded: Bool,
        preparationState: ModelPreparationState
    ) -> StartDisposition {
        guard hasActiveModel else { return .reject }
        if isLoaded { return .proceed }
        switch preparationState {
        case .loading:
            return .proceed
        case .downloading, .failed:
            return .reject
        case .idle, .ready:
            // `.ready` with an unloaded model is the post-select() race — treat
            // it like idle and re-kick preparation when the files exist.
            return isDownloaded ? .proceedAndPrepare : .reject
        }
    }

    /// Stop-time wait predicate: keep waiting only while a registry preparation
    /// is actually in flight. When nothing is preparing, the transcriber's own
    /// self-load (or failure) should take over immediately rather than racing a
    /// concurrent registry load.
    static func shouldKeepWaiting(
        isLoaded: Bool,
        isPreparing: Bool,
        now: Date,
        deadline: Date
    ) -> Bool {
        !isLoaded && isPreparing && now < deadline
    }
}

/// Rolling window of normalized recording levels (AudioRecorder's 0…1 scale,
/// linear in dB via level = (dB + 60) / 60, one tick per ~100 ms poll).
/// Distinguishes a steady loud background bed — machinery or AC keeps the
/// *minimum* elevated with little movement — from speech, whose peaks rise
/// well above whatever bed exists. Lets the recording strip point at the
/// environment while the user can still fix it, instead of after the failure.
struct RecordingLevelWindow: Sendable {
    static let capacity = 20 // ~2 s at the 100 ms level tick
    /// -45 dB on the linear map — the same elevated-floor bar the failure
    /// diagnostics use (`Diagnostics.elevatedNoiseFloorDb`).
    static let steadyBedMinimumLevel: Float = 0.25
    /// Under ~7 dB of movement across the window: nothing speech-like above the bed.
    static let steadyBedMaximumDynamics: Float = 0.12
    /// At/above ~9 dB of movement: the user is audibly speaking over the bed.
    static let speechDynamicsThreshold: Float = 0.15
    static let minimumSamplesForJudgment = 12

    private(set) var samples: [Float] = []

    mutating func append(_ level: Float) {
        samples.append(level)
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    mutating func reset() {
        samples.removeAll()
    }

    var indicatesSteadyLoudBed: Bool {
        guard samples.count >= Self.minimumSamplesForJudgment,
              let minLevel = samples.min(),
              let maxLevel = samples.max()
        else { return false }
        return minLevel >= Self.steadyBedMinimumLevel
            && maxLevel - minLevel < Self.steadyBedMaximumDynamics
    }

    var indicatesSpeechDynamics: Bool {
        guard samples.count >= 4,
              let minLevel = samples.min(),
              let maxLevel = samples.max()
        else { return false }
        return maxLevel - minLevel >= Self.speechDynamicsThreshold
    }
}

/// Labels an empty transcription honestly. The old bar reused
/// `DetectionConfig.default`'s 0.45 s minimum, so a short real word that ASR
/// whiffed on was reported as "No speech detected." — gaslighting the ~20% of
/// no-speech failures that carry speech-level audio. Any detected segment at or
/// above the pre-transcription gate's minimum counts as speech.
enum DictationEmptyResultClassification {
    static func isSpeechDetected(
        speechSegmentCount: Int,
        voicedDurationSeconds: TimeInterval
    ) -> Bool {
        speechSegmentCount > 0
            && voicedDurationSeconds
                >= DictationAudioAnalyzer.DetectionConfig.preTranscriptionGate.minimumSpeechDuration
    }
}

/// One recovery decode for short clips whose audio contains detectable speech
/// but whose full-clip decode produced no text: long silent margins or a
/// clipped onset can drown a one-word utterance in the batch decode. Pure
/// window math lives here so it can be unit-tested; the async orchestration
/// stays in DictationManager.
enum DictationVoicedWindowRetry {
    /// Clips at/above this bound use the segment-recovery machinery instead.
    static let maximumClipDurationSeconds = DictationSegmentRecovery.minimumClipDuration
    static let paddingSampleCount = 4_000 // 250 ms @ 16 kHz
    /// Skip when trimming removes less than this — the retry would repeat the
    /// full-clip decode the adapter has already retried internally.
    static let minimumTrimmedSampleCount = 3_200 // 200 ms @ 16 kHz

    static func shouldAttempt(clipDuration: TimeInterval) -> Bool {
        clipDuration > 0 && clipDuration < maximumClipDurationSeconds
    }

    static func windowBounds(
        segments: [DictationAudioAnalyzer.SpeechSegment],
        sampleCount: Int
    ) -> Range<Int>? {
        guard let firstStart = segments.map(\.startSample).min(),
              let lastEnd = segments.map(\.endSample).max()
        else { return nil }
        let start = max(0, firstStart - paddingSampleCount)
        let end = min(sampleCount, max(start, lastEnd + paddingSampleCount))
        guard start < end else { return nil }
        guard sampleCount - (end - start) >= minimumTrimmedSampleCount else { return nil }
        return start..<end
    }
}

enum DictationAudioRouting {
    /// FluidAudio's default URL route becomes disk-backed above this boundary.
    /// Keep the same boundary before allocating any app-owned full-file arrays.
    static let maximumCanonicalSampleCount = TranscriberAudioSupport.maximumInMemorySampleCount

    static func shouldLoadCanonicalSamples(
        estimatedSampleCount: Int,
        supportsDiskBackedURLTranscription: Bool
    ) -> Bool {
        !supportsDiskBackedURLTranscription
            || estimatedSampleCount <= maximumCanonicalSampleCount
    }

    static func loadCanonicalSamplesIfNeeded(
        from url: URL,
        estimatedSampleCount: Int,
        supportsDiskBackedURLTranscription: Bool,
        loader: @escaping @Sendable (URL) async throws -> [Float]
    ) async throws -> [Float]? {
        guard shouldLoadCanonicalSamples(
            estimatedSampleCount: estimatedSampleCount,
            supportsDiskBackedURLTranscription: supportsDiskBackedURLTranscription
        ) else {
            return nil
        }
        return try await DictationAsyncDeadline.throwingValueUnlessCancelled {
            try await loader(url)
        }
    }
}
