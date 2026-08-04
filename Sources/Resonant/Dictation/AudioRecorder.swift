@preconcurrency import AVFoundation
import Foundation
import ObjCExceptionCatcher

/// Records mic audio as linear PCM CAF in app-owned recovery storage.
/// CAF supports an open-ended data chunk during recording, so a hard process
/// kill leaves materially more recoverable audio than an unfinalized MP4/AAC
/// container in the purgeable system temporary directory.
/// Fires onLevelUpdate at ~20 Hz during recording.
@MainActor
final class AudioRecorder: NSObject {

    var onLevelUpdate: ((Float) async -> Void)?
    var onWarmSessionReadyChange: ((Bool) -> Void)?

    private var levelTimer: Task<Void, Never>?
    private let captureQueue = AudioCaptureHardwareCoordinator.lifecycleQueue
    nonisolated private let warmRequestGenerationGate = AudioWarmRequestGenerationGate()
    private var captureLifecycle = AudioCaptureLifecycleStateMachine()
    private var activeCapture: AudioCaptureContext?

    // Live warm-session AVFoundation objects are confined to `captureQueue`: created,
    // retained, and released ONLY inside captureQueue blocks. `nonisolated(unsafe)` opts them
    // out of the class's MainActor isolation so the serial queue is the sole synchronizer,
    // guaranteeing the prior input's KVO removeObserver on the shared AVCaptureDevice can
    // never run on another thread concurrently with a new input's -[AVCaptureDevice open:].
    nonisolated(unsafe) private var warmSessionQueueOnly: AVCaptureSession?
    nonisolated(unsafe) private var warmInputQueueOnly: AVCaptureDeviceInput?
    nonisolated(unsafe) private var warmSessionGenerationQueueOnly: UInt64?
    nonisolated(unsafe) private var warmSessionDeviceUIDQueueOnly: String?

    // MainActor-only metadata — never touches an AV object off the capture queue.
    private var warmSessionReadyFlag = false
    private var warmSessionDeviceUID: String?
    private var warmSessionIntent: WarmUpIntent?

    // Monotonic, MainActor-only token. Bumped on every warmUp/teardown/promotion so a
    // superseded in-flight build can't flip readiness for a session that's being torn down.
    private var warmGeneration: UInt64 = 0

    /// Whether the most recent `start(...)` call promoted a warm capture session.
    /// Reset at the top of every `start(...)` so analytics reflects the active recording.
    private(set) var didUseWarmSession: Bool = false
    /// Input device the most recent capture resolved to, for failure telemetry:
    /// the persistent-silence cohort can't be diagnosed without knowing which
    /// device delivered the silence. Reset on next start.
    private(set) var lastCaptureDeviceName: String?
    private(set) var lastCaptureDeviceIsSystemDefault: Bool?

    /// Dead-capture watchdog rebuilds performed during the most recent capture,
    /// for telemetry. Reset on next start.
    private(set) var lastCaptureRestartCount: Int = 0
    /// Fired after each dead-capture watchdog rebuild with whether the fresh
    /// session started recording.
    var onDeadCaptureRestart: ((Bool) -> Void)?

    private static let minimumSystemDefaultRecordingDuration: TimeInterval = 0.3
    private static let minimumCaptureSessionRecordingDuration: TimeInterval = 0.3
    private static let captureSessionStartGraceDuration: TimeInterval = 1.0
    private static let captureSessionStartAcknowledgementTimeoutNanoseconds: UInt64 = 1_000_000_000
    private static let startupCancellationJoinTimeoutNanoseconds: UInt64 = 250_000_000
    private static let deadCaptureRestartSettleTimeout: TimeInterval = 2.0

    /// 16 kHz mono 16-bit little-endian linear PCM — the transcriber's native input.
    private static let captureAudioSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    // MARK: - Warm session

    /// Why a warm session is being requested. `.persistent` keeps the historical
    /// contract (a standing live session — and its mic-in-use indicator — only
    /// when the user opted into low-latency mode). `.imminentCapture` is the
    /// speculative build at dictation trigger time: the mic is expected to be
    /// live within moments anyway, so the session may ramp for every user; it
    /// is torn down when the capture finishes without promoting it.
    enum WarmUpIntent: Equatable {
        case persistent
        case imminentCapture

        static func merged(
            existing: WarmUpIntent?,
            requested: WarmUpIntent
        ) -> WarmUpIntent {
            if existing == .persistent || requested == .persistent {
                return .persistent
            }
            return .imminentCapture
        }
    }

    /// Bounded window `start(...)` grants an in-flight speculative warm build
    /// before falling back to a cold path. A promoted running session records
    /// immediately; a cold start pays device-open plus hardware ramp, so a
    /// short wait is usually cheaper than falling back.
    enum WarmPromotionWaitPolicy {
        static let pollIntervalNanoseconds: UInt64 = 10_000_000

        static func waitBudget(isSystemDefaultMic: Bool) -> Duration {
            // Cold fallback for the default mic (AVAudioRecorder) is cheaper
            // than a fresh AVCaptureSession, so it gets a tighter budget.
            isSystemDefaultMic ? .milliseconds(200) : .milliseconds(400)
        }
    }

    @discardableResult
    private func advanceWarmGeneration() -> UInt64 {
        warmGeneration &+= 1
        warmRequestGenerationGate.publish(warmGeneration)
        return warmGeneration
    }

    func warmUp(selectedInputDeviceUID: String?, intent: WarmUpIntent = .persistent) {
        let isSystemDefault = selectedInputDeviceUID == nil
            || selectedInputDeviceUID == AVCaptureDevice.default(for: .audio)?.uniqueID

        // Persistent warming of the default mic is reserved for low-latency
        // mode. Custom mics always warm; an imminent capture may warm anything.
        if intent == .persistent, isSystemDefault, !SettingsManager.shared.lowLatencyMode {
            teardownWarmSession()
            return
        }

        // A speculative build must never trigger the microphone TCC prompt —
        // that belongs to the explicit capture start.
        if intent == .imminentCapture,
           AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            return
        }

        // Resolve to a concrete UID so the warm session and subsequent recording can match.
        let resolvedUID = selectedInputDeviceUID ?? AVCaptureDevice.default(for: .audio)?.uniqueID

        if warmSessionReadyFlag, warmSessionDeviceUID == resolvedUID {
            // A capture-time speculative request may reuse a persistent warm
            // session, but must not downgrade its ownership. Otherwise a
            // failed capture start leaves the session live while AppState is
            // told that low-latency warming is no longer ready.
            let mergedIntent = WarmUpIntent.merged(
                existing: warmSessionIntent,
                requested: intent
            )
            warmSessionIntent = mergedIntent
            onWarmSessionReadyChange?(mergedIntent == .persistent)
            return
        }

        // Supersede any in-flight create/teardown and record the desired state. The generation
        // is read only on the MainActor; it gates the readiness flip below so a superseded
        // build can't mark a session "ready" after a newer warmUp/teardown.
        let generation = advanceWarmGeneration()
        warmSessionReadyFlag = false
        warmSessionDeviceUID = resolvedUID
        warmSessionIntent = intent
        onWarmSessionReadyChange?(false)

        let requestedInputDeviceUID = selectedInputDeviceUID
        captureQueue.async { [weak self] in
            guard let self else { return }

            // This must be the first lifecycle decision in the block. Wake or
            // hardware recovery publishes a newer generation synchronously,
            // allowing queued work to exit before any AVFoundation touch.
            guard self.warmRequestGenerationGate.isCurrent(generation) else { return }

            // Release the prior warm session/input on THIS serial queue before opening a new
            // device, so the old input's KVO removeObserver on the shared AVCaptureDevice can
            // never run on another thread concurrently with a new input's -[AVCaptureDevice open:].
            self.releaseWarmSessionObjectsOnQueue()

            guard let device = AudioInputDeviceManager.resolveCaptureDevice(uid: requestedInputDeviceUID) else {
                Task { @MainActor in self.markWarmSessionFailed(generation: generation) }
                return
            }

            var input: AVCaptureDeviceInput?
            var inputCreationFailed = false
            // Invalidation can race a block that has already begun releasing
            // its previous session. Run the crashing initializer through the
            // second generation seam itself, before creating/configuring a
            // session. An initializer already executing is the only work that
            // cannot be cancelled.
            guard self.warmRequestGenerationGate.performIfCurrent(
                generation,
                operation: {
                    inputCreationFailed = ObjCTryCatch {
                        input = try? AVCaptureDeviceInput(device: device)
                    } != nil
                }
            ) else { return }
            // On any failure the local `session`/`input` are released here on captureQueue as
            // the closure returns — no AVFoundation object ever crosses to the main thread.
            guard !inputCreationFailed, let createdInput = input else {
                Task { @MainActor in self.markWarmSessionFailed(generation: generation) }
                return
            }
            // `publish` makes a newer generation visible even when it had to
            // wait for an already-running initializer. Do not proceed to
            // session configuration after such an in-flight invalidation.
            guard self.warmRequestGenerationGate.isCurrent(generation) else { return }

            let session = AVCaptureSession()
            session.beginConfiguration()
            guard session.canAddInput(createdInput) else {
                session.commitConfiguration()
                Task { @MainActor in self.markWarmSessionFailed(generation: generation) }
                return
            }
            session.addInput(createdInput)
            session.commitConfiguration()

            session.startRunning()
            guard session.isRunning else {
                Task { @MainActor in self.markWarmSessionFailed(generation: generation) }
                return
            }

            // The live objects live only in queue-confined storage; they are released only on
            // this serial queue (in releaseWarmSessionObjectsOnQueue or promotion).
            self.warmSessionQueueOnly = session
            self.warmInputQueueOnly = createdInput
            self.warmSessionGenerationQueueOnly = generation
            self.warmSessionDeviceUIDQueueOnly = resolvedUID

            // Hand only the generation token (a value) back to the MainActor to flip readiness;
            // no AVFoundation object is captured by this @MainActor hop.
            Task { @MainActor in self.markWarmSessionReady(generation: generation) }
        }
    }

    func teardownWarmSession() {
        // Supersede any in-flight warm create and clear MainActor-visible readiness.
        advanceWarmGeneration()
        warmSessionReadyFlag = false
        warmSessionDeviceUID = nil
        warmSessionIntent = nil
        onWarmSessionReadyChange?(false)

        // Release the live AV objects on the serial queue so the input's KVO removeObserver on
        // the shared device never runs on the main thread.
        captureQueue.async { [weak self] in
            self?.releaseWarmSessionObjectsOnQueue()
        }
    }

    /// Waits until all previously submitted warm lifecycle work and teardown
    /// have drained. Call `teardownWarmSession()` synchronously before awaiting
    /// this barrier when establishing a release-before-open boundary.
    func waitForWarmSessionTeardown() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.releaseWarmSessionObjectsOnQueue()
                continuation.resume()
            }
        }
    }

    /// Releases the queue-confined warm session/input. MUST be called on `captureQueue`.
    nonisolated private func releaseWarmSessionObjectsOnQueue() {
        if let session = warmSessionQueueOnly, session.isRunning {
            session.stopRunning()
        }
        warmSessionQueueOnly = nil
        warmInputQueueOnly = nil
        warmSessionGenerationQueueOnly = nil
        warmSessionDeviceUIDQueueOnly = nil
    }

    /// Flips warm readiness on only if this build wasn't superseded. MainActor-isolated.
    private func markWarmSessionReady(generation: UInt64) {
        guard warmGeneration == generation else { return }
        warmSessionReadyFlag = true
        if warmSessionIntent == .persistent {
            onWarmSessionReadyChange?(true)
        }
    }

    /// Clears warm readiness for a failed build unless a newer build/teardown superseded it.
    private func markWarmSessionFailed(generation: UInt64) {
        guard warmGeneration == generation else { return }
        warmSessionReadyFlag = false
        warmSessionDeviceUID = nil
        warmSessionIntent = nil
        onWarmSessionReadyChange?(false)
    }

    // MARK: - Start

    func start(
        selectedInputDeviceUID: String?,
        outputURL: URL? = nil,
        recordingRetention: DictationRecordingRetentionPolicy = .recoverable
    ) async throws -> URL {
        didUseWarmSession = false
        lastCaptureDeviceName = nil
        lastCaptureDeviceIsSystemDefault = nil
        lastCaptureRestartCount = 0

        // A completed context stays installed so late stop/cancel callers can still join
        // its cached terminal operation. It is retired only when the next start begins.
        if captureLifecycle.phase == .terminal {
            if let terminalContext = activeCapture,
               terminalContext.recordingRetention == .ephemeral
                || terminalContext.cancellationRequested {
                _ = deleteRecordingIfNeeded(
                    terminalContext,
                    url: terminalContext.outputURL
                )
            }
            guard captureLifecycle.reset() else { throw AudioRecorderError.startFailed }
            activeCapture = nil
        }
        guard let generation = captureLifecycle.beginStart() else {
            throw AudioRecorderError.startFailed
        }

        let context = AudioCaptureContext(
            generation: generation,
            recordingRetention: recordingRetention
        )
        activeCapture = context

        return try await withTaskCancellationHandler {
            let url = try await context.startOperation.value { [weak self, weak context] in
                guard let self, let context else { throw CancellationError() }
                return try await self.performStart(
                    context: context,
                    selectedInputDeviceUID: selectedInputDeviceUID,
                    outputURL: outputURL ?? self.reserveRecoveryCaptureURL()
                )
            }
            if Task.isCancelled || context.cancellationRequested {
                await cancel(context: context)
                throw CancellationError()
            }
            return url
        } onCancel: {
            // A caller-side timeout/cancellation must not abandon a recorder that is still
            // being constructed. Finalization joins the cached start task, then tears down
            // and deletes that generation's provisional file.
            Task { @MainActor [weak self, weak context] in
                guard let self, let context, self.owns(context) else { return }
                await self.cancel(context: context)
            }
        }
    }

    private func performStart(
        context: AudioCaptureContext,
        selectedInputDeviceUID: String?,
        outputURL: URL
    ) async throws -> URL {
        // Outside low-latency mode no live session may outlast the capture
        // attempt: a speculative (imminent-capture) warm build that was not
        // promoted would otherwise keep the mic open — and the mic-in-use
        // indicator lit — after the recording ends or fails. The generation
        // bump also strands any still-in-flight build, whose stored session is
        // then released by the FIFO capture queue.
        defer {
            if !SettingsManager.shared.lowLatencyMode {
                teardownWarmSession()
            }
        }
        do {
            guard await Self.ensureMicrophoneAccess() else {
                SentryManager.shared.microphoneError(AudioRecorderError.microphonePermissionDenied)
                throw AudioRecorderError.microphonePermissionDenied
            }
            guard owns(context) else { throw CancellationError() }
            guard !context.cancellationRequested else { throw CancellationError() }

            let resolvedDeviceName = AudioInputDeviceManager.resolveCaptureDevice(
                uid: selectedInputDeviceUID
            )?.localizedName
            SentryManager.shared.micCaptureStart(deviceName: resolvedDeviceName)

            // If we have a running warm session (custom mic OR default mic via low-latency),
            // promote it through the capture-session path. Otherwise fall through to
            // AVAudioRecorder for the default mic — zero regression for users not opted in.
            let defaultMicUID = AVCaptureDevice.default(for: .audio)?.uniqueID
            let resolvedUID = selectedInputDeviceUID ?? defaultMicUID
            lastCaptureDeviceName = resolvedDeviceName
                ?? AVCaptureDevice.default(for: .audio)?.localizedName
            lastCaptureDeviceIsSystemDefault = selectedInputDeviceUID == nil
                || selectedInputDeviceUID == defaultMicUID

            // A speculative warm build for this device may still be ramping —
            // grant it a bounded window before paying for a cold start.
            if !warmSessionReadyFlag, warmSessionDeviceUID == resolvedUID, resolvedUID != nil {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(
                    by: WarmPromotionWaitPolicy.waitBudget(
                        isSystemDefaultMic: resolvedUID == defaultMicUID
                    )
                )
                while !warmSessionReadyFlag,
                      warmSessionDeviceUID == resolvedUID,
                      clock.now < deadline,
                      owns(context),
                      !context.cancellationRequested,
                      !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: WarmPromotionWaitPolicy.pollIntervalNanoseconds)
                }
                guard owns(context) else { throw CancellationError() }
                guard !context.cancellationRequested else { throw CancellationError() }
            }

            let shouldResolveMatchingWarmBuild = AudioWarmPromotionPolicy
                .shouldResolveOnCaptureQueue(
                    requestedDeviceUID: warmSessionDeviceUID,
                    captureDeviceUID: resolvedUID
                )

            let url: URL
            if shouldResolveMatchingWarmBuild, let deviceUID = resolvedUID {
                // The MainActor readiness hop can lose the bounded race even though the
                // matching warm build is immediately ahead of us on captureQueue. Resolve
                // that generation on the queue: promote it if it completed, otherwise
                // retire its objects before constructing the cold capture-session fallback.
                context.backend = .captureSession
                url = try await startCaptureSessionRecording(
                    selectedInputDeviceUID: deviceUID,
                    outputURL: outputURL,
                    context: context
                )
            } else if let selectedInputDeviceUID,
                      selectedInputDeviceUID != defaultMicUID {
                // Treat an explicitly selected default microphone the same as "System Default".
                context.backend = .captureSession
                url = try await startCaptureSessionRecording(
                    selectedInputDeviceUID: selectedInputDeviceUID,
                    outputURL: outputURL,
                    context: context
                )
            } else {
                context.backend = .systemDefault
                url = try await startSystemDefaultRecording(
                    outputURL: outputURL,
                    context: context
                )
            }

            guard owns(context), captureLifecycle.captureDidStart(context.generation) else {
                cleanupCaptureResources(context, deleteRecording: true)
                throw CancellationError()
            }
            return url
        } catch {
            cleanupCaptureResources(context, deleteRecording: true)
            if owns(context), !context.finalizationOperation.isStarted {
                _ = captureLifecycle.markTerminal(context.generation)
            }
            throw AudioCaptureStartupErrorPolicy.errorToThrow(
                error,
                cancellationRequested: context.cancellationRequested || Task.isCancelled
            )
        }
    }

    private func startSystemDefaultRecording(
        outputURL: URL,
        context: AudioCaptureContext
    ) async throws -> URL {
        stopLevelPolling()

        let url = outputURL
        context.outputURL = url
        let stopDelegate = RecorderStopDelegate()
        stopDelegate.onFinish = { [weak self, weak context] success in
            Task { @MainActor [weak self, weak context] in
                guard let self, let context else { return }
                self.handleRecorderFinished(
                    successfully: success,
                    outputURL: url,
                    context: context
                )
            }
        }

        let settings = Self.captureAudioSettings

        let rec: AVAudioRecorder = try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                do {
                    let recorder = try AVAudioRecorder(url: url, settings: settings)
                    recorder.isMeteringEnabled = true
                    recorder.delegate = stopDelegate
                    recorder.prepareToRecord()

                    guard recorder.record() else {
                        throw AudioRecorderError.startFailed
                    }
                    continuation.resume(returning: recorder)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        guard owns(context) else {
            stopDelegate.onFinish = nil
            captureQueue.async {
                if rec.isRecording {
                    rec.stop()
                }
            }
            throw CancellationError()
        }

        context.recorder = rec
        context.recorderStopDelegate = stopDelegate
        context.recordingStartedAt = Date()

        startLevelPolling()
        return url
    }

    private func startCaptureSessionRecording(
        selectedInputDeviceUID: String,
        outputURL: URL,
        context: AudioCaptureContext
    ) async throws -> URL {
        stopLevelPolling()

        let url = outputURL
        context.outputURL = url
        context.captureDeviceUID = selectedInputDeviceUID

        let startBarrier = AudioCaptureStartBarrier(generation: context.generation)
        context.captureStartBarrier = startBarrier
        let recordingDelegate = CaptureRecordingDelegate(startBarrier: startBarrier)
        recordingDelegate.onFinish = { [weak self, weak context] finishedURL, error in
            Task { @MainActor [weak self, weak context] in
                guard let self, let context else { return }
                self.handleCaptureRecordingFinished(
                    outputURL: finishedURL,
                    error: error,
                    context: context
                )
            }
        }

        let audioSettings = Self.captureAudioSettings

        // Capture the exact matching warm generation before superseding its MainActor
        // readiness notification. The FIFO capture queue can then promote that generation
        // even if the bounded MainActor poll lost the completion race.
        let warmPromotionGeneration = warmSessionDeviceUID == selectedInputDeviceUID
            ? warmGeneration
            : nil
        advanceWarmGeneration()
        warmSessionReadyFlag = false
        warmSessionDeviceUID = nil
        warmSessionIntent = nil
        onWarmSessionReadyChange?(false)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                var sessionForCleanup: AVCaptureSession?
                var outputForCleanup: AVCaptureAudioFileOutput?
                do {
                    let session: AVCaptureSession
                    let input: AVCaptureDeviceInput
                    let didPromoteWarmSession: Bool

                    if AudioWarmPromotionPolicy.canPromote(
                        requestedGeneration: warmPromotionGeneration,
                        requestedDeviceUID: selectedInputDeviceUID,
                        builtGeneration: self.warmSessionGenerationQueueOnly,
                        builtDeviceUID: self.warmSessionDeviceUIDQueueOnly
                    ),
                       let promotedSession = self.warmSessionQueueOnly,
                       let promotedInput = self.warmInputQueueOnly,
                       promotedSession.isRunning {
                        session = promotedSession
                        input = promotedInput
                        didPromoteWarmSession = true
                        // Ownership transfers to the active recording; clear queue-confined refs.
                        self.warmSessionQueueOnly = nil
                        self.warmInputQueueOnly = nil
                        self.warmSessionGenerationQueueOnly = nil
                        self.warmSessionDeviceUIDQueueOnly = nil
                    } else {
                        // Not promoting (or warm objects gone): release any stale warm objects
                        // on this queue, then build fresh ones.
                        self.releaseWarmSessionObjectsOnQueue()
                        didPromoteWarmSession = false

                        let device = AudioInputDeviceManager.resolveCaptureDevice(uid: selectedInputDeviceUID)
                        guard let device else {
                            throw AudioRecorderError.noInputDevice
                        }

                        input = try AVCaptureDeviceInput(device: device)
                        session = AVCaptureSession()
                        session.beginConfiguration()
                        guard session.canAddInput(input) else {
                            session.commitConfiguration()
                            throw AudioRecorderError.startFailed
                        }
                        session.addInput(input)
                        session.commitConfiguration()
                        session.startRunning()
                    }
                    sessionForCleanup = session

                    guard session.isRunning else {
                        throw AudioRecorderError.startFailed
                    }

                    session.beginConfiguration()
                    let output = AVCaptureAudioFileOutput()
                    outputForCleanup = output
                    output.audioSettings = audioSettings
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw AudioRecorderError.startFailed
                    }
                    session.addOutput(output)
                    session.commitConfiguration()

                    output.metadata = [] // Reduce likelihood of _avMetadataToID3Metadata crash

                    // AVCaptureAudioFileOutput.startRecording can throw an uncatchable
                    // NSException in _avMetadataToID3Metadata on macOS 15+.
                    // Wrap in ObjC @try/@catch to prevent a hard crash.
                    if ObjCTryCatch({
                        output.startRecording(to: url, outputFileType: .caf, recordingDelegate: recordingDelegate)
                    }) != nil {
                        session.removeOutput(output)
                        throw AudioRecorderError.startFailed
                    }

                    Task { @MainActor in
                        guard self.owns(context),
                              !context.cancellationRequested,
                              context.captureStartBarrier === startBarrier else {
                            _ = startBarrier.resolve(.cancelled)
                            recordingDelegate.onFinish = nil
                            self.captureQueue.async {
                                if output.isRecording {
                                    output.stopRecording()
                                }
                                if session.isRunning {
                                    session.stopRunning()
                                }
                                withExtendedLifetime((session, input, output)) {}
                            }
                            if context.cancellationRequested {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(throwing: AudioRecorderError.startFailed)
                            }
                            return
                        }

                        context.captureSession = session
                        context.captureInput = input
                        context.captureFileOutput = output
                        context.captureRecordingDelegate = recordingDelegate
                        self.didUseWarmSession = didPromoteWarmSession
                        continuation.resume(returning: ())
                    }
                } catch {
                    recordingDelegate.onFinish = nil
                    _ = startBarrier.resolve(.cancelled)
                    if let outputForCleanup, outputForCleanup.isRecording {
                        outputForCleanup.stopRecording()
                    }
                    if let sessionForCleanup, sessionForCleanup.isRunning {
                        sessionForCleanup.stopRunning()
                    }
                    Task { @MainActor in
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        let startOutcome = await startBarrier.wait(
            timeoutNanoseconds: Self.captureSessionStartAcknowledgementTimeoutNanoseconds
        )
        switch startOutcome {
        case .started(let startedURL, let startedAt):
            guard startedURL.standardizedFileURL == url.standardizedFileURL else {
                throw AudioRecorderError.startFailed
            }
            guard owns(context),
                  !context.cancellationRequested,
                  startBarrier.generation == context.generation,
                  context.captureStartBarrier === startBarrier,
                  context.captureFileOutput != nil else {
                if context.cancellationRequested {
                    throw CancellationError()
                }
                throw AudioRecorderError.startFailed
            }
            context.recordingStartedAt = startedAt
            startLevelPolling()
            return url
        case .finishedBeforeStart(let reason):
            throw AudioRecorderError.finishFailed(reason)
        case .timedOut:
            throw AudioRecorderError.finishFailed("recording start was not acknowledged")
        case .cancelled:
            throw CancellationError()
        }
    }

    func reserveRecoveryCaptureURL() throws -> URL {
        let directory = AppSupportPaths.resonantRoot()
            .appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory.appendingPathComponent(
            "resonant_recording_\(UUID().uuidString).caf"
        )
    }

    // MARK: - Stop

    func stop() async throws -> URL? {
        guard let context = activeCapture else { return nil }
        guard captureLifecycle.requestFinalization(context.generation, intent: .stop) else {
            return nil
        }

        do {
            let result = try await sharedFinalization(for: context)
            if context.cancellationRequested {
                throw CancellationError()
            }
            switch result {
            case .finished(let url):
                return url
            case .cancelled:
                throw CancellationError()
            }
        } catch {
            if error is CancellationError || context.cancellationRequested {
                throw CancellationError()
            }
            reportCaptureFailureOnce(error, context: context)
            throw error
        }
    }

    /// Cancels the active capture. A returned task means startup did not
    /// quiesce inside the bounded join; callers must keep new capture blocked
    /// until that task completes, while remaining free to update UI immediately.
    @discardableResult
    func cancel() async -> Task<Void, Never>? {
        guard let context = activeCapture else { return nil }
        let startupIsIncomplete = context.startOperation.isStarted
            && !context.startOperation.isCompleted
        context.cancellationRequested = true
        _ = context.captureStartBarrier?.resolve(.cancelled)
        guard captureLifecycle.requestFinalization(context.generation, intent: .cancel) else {
            deleteRecordingIfNeeded(context, url: context.outputURL)
            return nil
        }

        let completion = Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            await self.cancel(context: context)
        }
        if startupIsIncomplete {
            // The startup watchdog must not wait forever for a blocking
            // permission or AVFoundation start call. The retained context and
            // completion task still own eventual cleanup and deletion. Return
            // that task so AppState can remain busy until ownership is retired.
            let didJoin = await AudioCaptureCancellationJoin.wait(
                for: completion,
                timeoutNanoseconds: Self.startupCancellationJoinTimeoutNanoseconds
            )
            return didJoin ? nil : completion
        } else {
            await completion.value
            return nil
        }
    }

    private func cancel(context: AudioCaptureContext) async {
        guard owns(context) else {
            deleteRecordingIfNeeded(context, url: context.outputURL)
            return
        }
        context.cancellationRequested = true
        _ = context.captureStartBarrier?.resolve(.cancelled)
        guard captureLifecycle.requestFinalization(context.generation, intent: .cancel) else {
            deleteRecordingIfNeeded(context, url: context.outputURL)
            return
        }
        do {
            _ = try await sharedFinalization(for: context)
        } catch {}
        deleteRecordingIfNeeded(context, url: context.outputURL)
    }

    private func sharedFinalization(
        for context: AudioCaptureContext
    ) async throws -> AudioCaptureFinalizationResult {
        try await context.finalizationOperation.value { [weak self, weak context] in
            guard let self, let context else { return .cancelled }
            return try await self.completeFinalization(context)
        }
    }

    private func completeFinalization(
        _ context: AudioCaptureContext
    ) async throws -> AudioCaptureFinalizationResult {
        do {
            guard try await context.startOperation.existingValue() != nil else {
                throw AudioRecorderError.startFailed
            }

            let url: URL?
            if let backendCompletion = context.backendCompletion {
                url = try backendCompletion.get()
            } else {
                switch context.backend {
                case .captureSession:
                    url = try await stopCaptureSessionRecording(context: context)
                case .systemDefault:
                    url = try await stopSystemDefaultRecording(context: context)
                case nil:
                    throw AudioRecorderError.startFailed
                }
            }

            cleanupCaptureResources(context, deleteRecording: false)
            if context.cancellationRequested {
                deleteRecordingIfNeeded(context, url: url ?? context.outputURL)
                markTerminalIfCurrent(context)
                return .cancelled
            }

            markTerminalIfCurrent(context)
            return .finished(url)
        } catch {
            cleanupCaptureResources(
                context,
                deleteRecording: context.recordingRetention
                    .deletesRecordingAfterFailedFinalization(
                        cancellationRequested: context.cancellationRequested
                    )
            )
            markTerminalIfCurrent(context)
            if context.cancellationRequested {
                return .cancelled
            }
            throw error
        }
    }

    // MARK: - Level metering (10 Hz)

    private func startLevelPolling() {
        stopLevelPolling()
        levelTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.restartDeadCaptureIfNeeded()
                if let callback = self.onLevelUpdate {
                    let normalized = self.currentAudioLevel()
                    await callback(normalized)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopLevelPolling() {
        levelTimer?.cancel()
        levelTimer = nil
    }

    private func currentAudioLevel() -> Float {
        guard let context = activeCapture else { return 0 }

        if let recorder = context.recorder {
            recorder.updateMeters()
            return Self.normalizedAudioPower(recorder.averagePower(forChannel: 0))
        }

        let capturePower = context.captureFileOutput?
            .connection(with: .audio)?
            .audioChannels
            .map(\.averagePowerLevel)
            .max() ?? -160
        return Self.normalizedAudioPower(capturePower)
    }

    // MARK: - Dead-capture watchdog

    /// Level polling calls this each tick. A capture-session backend whose file
    /// output stops accruing media while wall clock advances is the
    /// persistent-silence cohort: the session claims to run but the device
    /// delivers no frames, so every second spoken into it is lost. Only a cold
    /// session rebuild recovers the capture, and the dead file held nothing but
    /// zeros, so a rebuild discards no real audio.
    private func restartDeadCaptureIfNeeded() {
        guard let context = activeCapture,
              owns(context),
              captureLifecycle.phase == .recording,
              context.backend == .captureSession,
              !context.backendRestartInFlight,
              !context.finalizationOperation.isStarted,
              !context.cancellationRequested,
              context.backendCompletion == nil,
              let output = context.captureFileOutput,
              output.isRecording,
              let recordingStartedAt = context.recordingStartedAt
        else { return }

        guard DeadCaptureRestartPolicy.shouldRestart(
            elapsedSeconds: Date().timeIntervalSince(recordingStartedAt),
            recordedSeconds: output.recordedDuration.seconds,
            restartsSoFar: context.backendRestartCount
        ) else { return }

        context.backendRestartCount += 1
        context.backendRestartInFlight = true
        beginDeadCaptureRestart(context: context)
    }

    private func beginDeadCaptureRestart(context: AudioCaptureContext) {
        guard let outputURL = try? reserveRecoveryCaptureURL() else {
            finishDeadCaptureRestart(context: context, promoted: false)
            return
        }

        let restartBarrier = AudioCaptureStartBarrier(generation: context.generation)
        let restartDelegate = CaptureRecordingDelegate(startBarrier: restartBarrier)
        restartDelegate.onFinish = { [weak self, weak context] finishedURL, error in
            Task { @MainActor [weak self, weak context] in
                guard let self, let context else { return }
                self.handleCaptureRecordingFinished(
                    outputURL: finishedURL,
                    error: error,
                    context: context
                )
            }
        }
        let deviceUID = context.captureDeviceUID
        let audioSettings = Self.captureAudioSettings

        captureQueue.async { [weak self] in
            guard let self else { return }
            var builtSession: AVCaptureSession?
            var builtInput: AVCaptureDeviceInput?
            var builtOutput: AVCaptureAudioFileOutput?
            var started = false

            build: do {
                guard let device = AudioInputDeviceManager.resolveCaptureDevice(uid: deviceUID) else {
                    break build
                }
                let session = AVCaptureSession()
                session.beginConfiguration()
                var input: AVCaptureDeviceInput?
                let exception = ObjCTryCatch {
                    input = try? AVCaptureDeviceInput(device: device)
                }
                guard exception == nil, let createdInput = input, session.canAddInput(createdInput) else {
                    session.commitConfiguration()
                    break build
                }
                session.addInput(createdInput)
                session.commitConfiguration()
                session.startRunning()
                builtSession = session
                builtInput = createdInput
                guard session.isRunning else { break build }

                session.beginConfiguration()
                let output = AVCaptureAudioFileOutput()
                output.audioSettings = audioSettings
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    break build
                }
                session.addOutput(output)
                session.commitConfiguration()
                builtOutput = output

                output.metadata = [] // Reduce likelihood of _avMetadataToID3Metadata crash
                guard ObjCTryCatch({
                    output.startRecording(to: outputURL, outputFileType: .caf, recordingDelegate: restartDelegate)
                }) == nil else { break build }
                started = true
            }

            if started, let session = builtSession, let input = builtInput, let output = builtOutput {
                Task { @MainActor in
                    await self.promoteDeadCaptureRestart(
                        context: context,
                        session: session,
                        input: input,
                        output: output,
                        delegate: restartDelegate,
                        barrier: restartBarrier,
                        outputURL: outputURL
                    )
                }
            } else {
                // Local AV objects are released here on captureQueue as the
                // closure returns; a session retains its input until then.
                restartDelegate.onFinish = nil
                _ = restartBarrier.resolve(.cancelled)
                if let builtOutput, builtOutput.isRecording {
                    builtOutput.stopRecording()
                }
                if let builtSession, builtSession.isRunning {
                    builtSession.stopRunning()
                }
                Task { @MainActor in
                    self.finishDeadCaptureRestart(context: context, promoted: false)
                }
            }
        }
    }

    private func promoteDeadCaptureRestart(
        context: AudioCaptureContext,
        session: AVCaptureSession,
        input: AVCaptureDeviceInput,
        output: AVCaptureAudioFileOutput,
        delegate: CaptureRecordingDelegate,
        barrier: AudioCaptureStartBarrier,
        outputURL: URL
    ) async {
        let outcome = await barrier.wait(
            timeoutNanoseconds: Self.captureSessionStartAcknowledgementTimeoutNanoseconds
        )

        // Retire the dead backend only after the fresh one acknowledged its
        // start and the capture is still live: an abandoned rebuild must leave
        // the old objects in place so stop/cancel finalize them as before.
        if case .started(let startedURL, let startedAt) = outcome,
           startedURL.standardizedFileURL == outputURL.standardizedFileURL,
           owns(context),
           !context.cancellationRequested,
           !context.finalizationOperation.isStarted,
           context.backendCompletion == nil {
            let oldSession = context.captureSession
            let oldInput = context.captureInput
            let oldOutput = context.captureFileOutput
            let oldURL = context.outputURL
            context.captureRecordingDelegate?.onFinish = nil
            context.captureSession = session
            context.captureInput = input
            context.captureFileOutput = output
            context.captureRecordingDelegate = delegate
            context.captureStartBarrier = barrier
            context.outputURL = outputURL
            context.recordingStartedAt = startedAt
            lastCaptureRestartCount += 1

            captureQueue.async {
                if let oldOutput, oldOutput.isRecording {
                    oldOutput.stopRecording()
                }
                if let oldSession, oldSession.isRunning {
                    oldSession.stopRunning()
                }
                if let oldURL {
                    _ = DictationRecordingFileDeletion.removeIfPresent(oldURL)
                }
                withExtendedLifetime((oldSession, oldInput, oldOutput)) {}
            }
            finishDeadCaptureRestart(context: context, promoted: true)
        } else {
            delegate.onFinish = nil
            _ = barrier.resolve(.cancelled)
            captureQueue.async {
                if output.isRecording {
                    output.stopRecording()
                }
                if session.isRunning {
                    session.stopRunning()
                }
                withExtendedLifetime((session, input, output)) {}
            }
            finishDeadCaptureRestart(context: context, promoted: false)
        }
    }

    private func finishDeadCaptureRestart(context: AudioCaptureContext, promoted: Bool) {
        context.backendRestartInFlight = false
        onDeadCaptureRestart?(promoted)
    }

    /// Finalization must not race a rebuild that is mid-swap: wait for the
    /// in-flight attempt to settle so `captureFileOutput` is the output that
    /// will actually deliver the finish callback.
    private func waitForDeadCaptureRestartToSettle(_ context: AudioCaptureContext) async {
        let deadline = Date().addingTimeInterval(Self.deadCaptureRestartSettleTimeout)
        while context.backendRestartInFlight, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func stopCaptureSessionRecording(context: AudioCaptureContext) async throws -> URL? {
        if let backendCompletion = context.backendCompletion {
            return try backendCompletion.get()
        }

        await waitForDeadCaptureRestartToSettle(context)
        if let backendCompletion = context.backendCompletion {
            return try backendCompletion.get()
        }

        guard let captureFileOutput = context.captureFileOutput else {
            return context.outputURL
        }

        await ensureMinimumRecordingDuration(context)
        if let backendCompletion = context.backendCompletion {
            return try backendCompletion.get()
        }

        if !captureFileOutput.isRecording {
            let didStart = await waitForCaptureSessionRecordingToStart(
                captureFileOutput,
                context: context
            )
            if let backendCompletion = context.backendCompletion {
                return try backendCompletion.get()
            }
            guard didStart, context.captureFileOutput === captureFileOutput else {
                throw AudioRecorderError.finishFailed("recording never started")
            }
        }

        guard captureFileOutput.isRecording else {
            throw AudioRecorderError.finishFailed("recording stopped before finalization")
        }

        return try await withCheckedThrowingContinuation { continuation in
            context.captureStopContinuation = continuation
            captureQueue.async {
                captureFileOutput.stopRecording()
            }
        }
    }

    private func stopSystemDefaultRecording(context: AudioCaptureContext) async throws -> URL? {
        stopLevelPolling()
        if let backendCompletion = context.backendCompletion {
            return try backendCompletion.get()
        }

        await ensureMinimumRecordingDuration(context)
        if let backendCompletion = context.backendCompletion {
            return try backendCompletion.get()
        }

        guard let recorder = context.recorder else {
            return context.outputURL
        }

        guard recorder.isRecording else {
            return context.outputURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            context.recorderStopContinuation = continuation
            captureQueue.async {
                recorder.stop()
            }
        }
    }

    private func handleRecorderFinished(
        successfully: Bool,
        outputURL expectedOutputURL: URL,
        context: AudioCaptureContext
    ) {
        guard context.backendCompletion == nil else { return }
        let continuation = context.recorderStopContinuation
        context.recorderStopContinuation = nil
        context.recordingStartedAt = nil

        let result: Result<URL, Error>
        if successfully {
            result = .success(expectedOutputURL)
            continuation?.resume(returning: expectedOutputURL)
        } else {
            let error = AudioRecorderError.finishFailed("recording did not finish successfully")
            result = .failure(error)
            continuation?.resume(throwing: error)
        }
        context.backendCompletion = result

        // During an explicit finalization, keep every AV object and delegate retained
        // until the shared operation observes this result and marks the generation terminal.
        guard !context.finalizationOperation.isStarted else { return }
        if case .failure(let error) = result {
            reportCaptureFailureOnce(error, context: context)
        }
        cleanupCaptureResources(
            context,
            deleteRecording: !successfully
                && context.recordingRetention.deletesRecordingAfterFailedFinalization(
                    cancellationRequested: context.cancellationRequested
                )
        )
        markTerminalIfCurrent(context)
    }

    private func handleCaptureRecordingFinished(
        outputURL: URL,
        error: Error?,
        context: AudioCaptureContext
    ) {
        guard context.backendCompletion == nil else { return }
        let continuation = context.captureStopContinuation
        context.captureStopContinuation = nil
        context.recordingStartedAt = nil

        let result: Result<URL, Error>
        let finishedSuccessfully = error.map { recordingFinishedSuccessfully(with: $0) } ?? true
        if let error, !finishedSuccessfully {
            let finishError = AudioRecorderError.finishFailed(error.localizedDescription)
            result = .failure(finishError)
            continuation?.resume(throwing: finishError)
        } else {
            result = .success(outputURL)
            continuation?.resume(returning: outputURL)
        }
        context.backendCompletion = result

        guard !context.finalizationOperation.isStarted else { return }
        if case .failure(let finishError) = result {
            reportCaptureFailureOnce(finishError, context: context)
        }
        cleanupCaptureResources(
            context,
            deleteRecording: !finishedSuccessfully
                && context.recordingRetention.deletesRecordingAfterFailedFinalization(
                    cancellationRequested: context.cancellationRequested
                )
        )
        markTerminalIfCurrent(context)
    }

    private func cleanupCaptureResources(
        _ context: AudioCaptureContext,
        deleteRecording: Bool
    ) {
        if activeCapture === context {
            stopLevelPolling()
        }

        let teardownError = AudioRecorderError.finishFailed("recording session torn down")
        if let continuation = context.recorderStopContinuation {
            context.recorderStopContinuation = nil
            continuation.resume(throwing: teardownError)
        }
        if let continuation = context.captureStopContinuation {
            context.captureStopContinuation = nil
            continuation.resume(throwing: teardownError)
        }

        let recorder = context.recorder
        context.recorder = nil
        context.recorderStopDelegate?.onFinish = nil
        context.recorderStopDelegate = nil

        let session = context.captureSession
        let input = context.captureInput
        let output = context.captureFileOutput
        let startBarrier = context.captureStartBarrier
        context.captureSession = nil
        context.captureInput = nil
        context.captureFileOutput = nil
        context.captureRecordingDelegate?.onFinish = nil
        context.captureRecordingDelegate = nil
        context.captureStartBarrier = nil
        context.recordingStartedAt = nil
        _ = startBarrier?.resolve(.cancelled)

        if recorder != nil || session != nil || input != nil || output != nil {
            captureQueue.async {
                if let recorder, recorder.isRecording {
                    recorder.stop()
                }
                if let output, output.isRecording {
                    output.stopRecording()
                }
                if let session, session.isRunning {
                    session.stopRunning()
                }
                withExtendedLifetime((recorder, session, input, output)) {}
            }
        }

        if deleteRecording {
            deleteRecordingIfNeeded(context, url: context.outputURL)
        }
    }

    @discardableResult
    private func deleteRecordingIfNeeded(_ context: AudioCaptureContext, url: URL?) -> Bool {
        guard let url else { return true }
        if context.didDeleteRecording {
            return !FileManager.default.fileExists(atPath: url.path)
        }
        let deleted = DictationRecordingFileDeletion.removeIfPresent(url)
        context.didDeleteRecording = deleted
        return deleted
    }

    private func reportCaptureFailureOnce(_ error: Error, context: AudioCaptureContext) {
        guard !context.didReportFailure else { return }
        context.didReportFailure = true
        SentryManager.shared.micCaptureError(error)
    }

    private func owns(_ context: AudioCaptureContext) -> Bool {
        activeCapture === context && captureLifecycle.isCurrent(context.generation)
    }

    private func markTerminalIfCurrent(_ context: AudioCaptureContext) {
        guard owns(context) else { return }
        _ = captureLifecycle.markTerminal(context.generation)
    }

    private func recordingFinishedSuccessfully(with error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true
    }

    private func ensureMinimumRecordingDuration(_ context: AudioCaptureContext) async {
        guard let recordingStartedAt = context.recordingStartedAt else { return }

        let minimumDuration: TimeInterval
        switch context.backend {
        case .systemDefault:
            minimumDuration = Self.minimumSystemDefaultRecordingDuration
        case .captureSession:
            minimumDuration = Self.minimumCaptureSessionRecordingDuration
        case nil:
            return
        }

        let elapsed = Date().timeIntervalSince(recordingStartedAt)
        let remaining = minimumDuration - elapsed
        guard remaining > 0 else { return }

        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    private func waitForCaptureSessionRecordingToStart(
        _ output: AVCaptureAudioFileOutput,
        context: AudioCaptureContext
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.captureSessionStartGraceDuration)
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            guard owns(context) else { return false }
            guard context.captureFileOutput === output else { return false }
            if output.isRecording { return true }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return owns(context)
            && context.captureFileOutput === output
            && output.isRecording
    }

    nonisolated static func normalizedAudioPower(_ power: Float) -> Float {
        guard power.isFinite else { return 0 }
        let floor: Float = -60
        return max(0, min(1, (power - floor) / abs(floor)))
    }

    private static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

enum AudioCaptureCancellationJoin {
    static func wait(
        for completion: Task<Void, Never>,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        let observer = Task<Bool, Never> {
            await completion.value
            return true
        }
        return await DictationAsyncDeadline.valueIfReady(
            observer,
            timeoutNanoseconds: timeoutNanoseconds
        ) ?? false
    }
}

enum AudioCaptureStartupErrorPolicy {
    static func errorToThrow(
        _ error: Error,
        cancellationRequested: Bool
    ) -> Error {
        cancellationRequested ? CancellationError() : error
    }
}

enum AudioWarmPromotionPolicy {
    /// A matching in-flight build is resolved on captureQueue even when its MainActor
    /// readiness notification arrives just after the bounded speculative-warm wait.
    static func shouldResolveOnCaptureQueue(
        requestedDeviceUID: String?,
        captureDeviceUID: String?
    ) -> Bool {
        guard let requestedDeviceUID, let captureDeviceUID else { return false }
        return requestedDeviceUID == captureDeviceUID
    }

    /// Queue-confined AVFoundation objects may be promoted only for the exact warm
    /// generation and microphone selected by this capture attempt.
    static func canPromote(
        requestedGeneration: UInt64?,
        requestedDeviceUID: String,
        builtGeneration: UInt64?,
        builtDeviceUID: String?
    ) -> Bool {
        guard let requestedGeneration, let builtGeneration, let builtDeviceUID else {
            return false
        }
        return requestedGeneration == builtGeneration
            && requestedDeviceUID == builtDeviceUID
    }
}

/// Watchdog policy for the persistent-silence cohort. A healthy microphone
/// advances the file output's recorded duration in lockstep with wall clock
/// even in a silent room — silence is still delivered frames — so a recorded
/// duration pinned near zero this deep into a capture proves the device is
/// delivering nothing, and only a cold session rebuild can save the dictation.
enum DeadCaptureRestartPolicy {
    /// Long enough that a slow first buffer or start acknowledgement can't
    /// trip the watchdog on a healthy capture.
    static let minimumElapsedSeconds: TimeInterval = 2.5
    /// Well below any healthy capture at `minimumElapsedSeconds` (≥ ~2 s
    /// recorded) yet far above what dead sessions accrue (tens of ms).
    static let maximumRecordedSeconds: TimeInterval = 0.5
    /// One rebuild per capture: a second dead session means the device itself
    /// is gone and further restarts would only churn.
    static let maximumRestartsPerCapture = 1

    static func shouldRestart(
        elapsedSeconds: TimeInterval,
        recordedSeconds: TimeInterval,
        restartsSoFar: Int
    ) -> Bool {
        guard restartsSoFar < maximumRestartsPerCapture else { return false }
        guard elapsedSeconds >= minimumElapsedSeconds else { return false }
        let recorded = recordedSeconds.isFinite ? recordedSeconds : 0
        return recorded < maximumRecordedSeconds
    }
}

enum AudioCaptureStartOutcome: Equatable, Sendable {
    case started(URL, Date)
    case finishedBeforeStart(String)
    case timedOut
    case cancelled
}

/// Thread-safe one-shot acknowledgement for one capture generation. AVCapture delegate
/// callbacks resolve it synchronously, so callback ordering is preserved even when the
/// MainActor is busy. Timeout and cancellation also resolve the same gate exactly once.
final class AudioCaptureStartBarrier: @unchecked Sendable {
    let generation: UInt64

    private let lock = NSLock()
    private var outcome: AudioCaptureStartOutcome?
    private var continuation: CheckedContinuation<AudioCaptureStartOutcome, Never>?

    init(generation: UInt64) {
        self.generation = generation
    }

    @discardableResult
    func resolve(_ outcome: AudioCaptureStartOutcome) -> Bool {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return false
        }
        self.outcome = outcome
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: outcome)
        return true
    }

    func wait(timeoutNanoseconds: UInt64) async -> AudioCaptureStartOutcome {
        let timeoutTask = Task<Void, Never> { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            _ = self?.resolve(.timedOut)
        }

        let result = await withTaskCancellationHandler {
            await value()
        } onCancel: { [weak self] in
            _ = self?.resolve(.cancelled)
        }
        timeoutTask.cancel()
        return result
    }

    private func value() async -> AudioCaptureStartOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            precondition(self.continuation == nil, "capture start barrier supports one waiter")
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// Caches one actor-isolated asynchronous operation so reentrant and late callers
/// share the same result. An in-flight operation cannot be reset out from under waiters.
@MainActor
final class SharedAsyncOperation<Success: Sendable> {
    private var task: Task<Success, Error>?
    private var completed = false

    var isStarted: Bool { task != nil }
    var isCompleted: Bool { completed }

    func value(
        starting operation: @escaping @MainActor @Sendable () async throws -> Success
    ) async throws -> Success {
        if let task {
            return try await observe(task)
        }

        let task = Task { @MainActor in
            try await operation()
        }
        self.task = task
        return try await observe(task)
    }

    func existingValue() async throws -> Success? {
        guard let task else { return nil }
        return try await observe(task)
    }

    @discardableResult
    func reset() -> Bool {
        guard task == nil || completed else { return false }
        task = nil
        completed = false
        return true
    }

    private func observe(_ task: Task<Success, Error>) async throws -> Success {
        do {
            let value = try await task.value
            completed = true
            return value
        } catch {
            completed = true
            throw error
        }
    }
}

enum AudioCaptureLifecyclePhase: Equatable, Sendable {
    case idle
    case starting
    case recording
    case finalizing
    case terminal
}

enum AudioCaptureFinalizationIntent: Sendable {
    case stop
    case cancel
}

/// Pure lifecycle seam used by AudioRecorder to prohibit overlapping starts while
/// allowing every stop/cancel caller for one generation to join its terminal operation.
struct AudioCaptureLifecycleStateMachine: Sendable {
    private var nextGeneration: UInt64 = 0
    private(set) var generation: UInt64?
    private(set) var phase: AudioCaptureLifecyclePhase = .idle
    private(set) var cancellationRequested = false

    mutating func beginStart() -> UInt64? {
        guard phase == .idle else { return nil }
        nextGeneration &+= 1
        generation = nextGeneration
        phase = .starting
        cancellationRequested = false
        return nextGeneration
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        self.generation == generation && phase != .idle
    }

    @discardableResult
    mutating func captureDidStart(_ generation: UInt64) -> Bool {
        guard self.generation == generation else { return false }
        switch phase {
        case .starting:
            phase = .recording
            return true
        case .finalizing:
            // A stop/cancel arrived while AVFoundation was still starting. Keep the
            // finalizing phase; its shared task will stop the newly retained backend.
            return true
        case .idle, .recording, .terminal:
            return false
        }
    }

    @discardableResult
    mutating func requestFinalization(
        _ generation: UInt64,
        intent: AudioCaptureFinalizationIntent
    ) -> Bool {
        guard self.generation == generation else { return false }
        if intent == .cancel {
            cancellationRequested = true
        }

        switch phase {
        case .starting, .recording:
            phase = .finalizing
            return true
        case .finalizing, .terminal:
            return true
        case .idle:
            return false
        }
    }

    @discardableResult
    mutating func markTerminal(_ generation: UInt64) -> Bool {
        guard self.generation == generation, phase != .idle else { return false }
        phase = .terminal
        return true
    }

    /// Resets only idle or fully terminal state. Active/finalizing ownership can never
    /// be discarded, which keeps delegates and continuations reachable until completion.
    @discardableResult
    mutating func reset() -> Bool {
        guard phase == .idle || phase == .terminal else { return false }
        generation = nil
        phase = .idle
        cancellationRequested = false
        return true
    }
}

private enum AudioCaptureBackend: Sendable {
    case systemDefault
    case captureSession
}

private enum AudioCaptureFinalizationResult: Sendable {
    case finished(URL?)
    case cancelled
}

/// Owns every resource associated with one capture generation. AudioRecorder retains
/// a terminal context until the next start so late stop/cancel calls share its result.
@MainActor
private final class AudioCaptureContext {
    let generation: UInt64
    let recordingRetention: DictationRecordingRetentionPolicy
    let startOperation = SharedAsyncOperation<URL>()
    let finalizationOperation = SharedAsyncOperation<AudioCaptureFinalizationResult>()

    var backend: AudioCaptureBackend?
    var outputURL: URL?
    var recordingStartedAt: Date?
    var backendCompletion: Result<URL, Error>?
    var cancellationRequested = false
    var didDeleteRecording = false
    var didReportFailure = false

    var recorder: AVAudioRecorder?
    var recorderStopDelegate: RecorderStopDelegate?
    var recorderStopContinuation: CheckedContinuation<URL, Error>?

    var captureSession: AVCaptureSession?
    var captureInput: AVCaptureDeviceInput?
    var captureFileOutput: AVCaptureAudioFileOutput?
    var captureRecordingDelegate: CaptureRecordingDelegate?
    var captureStartBarrier: AudioCaptureStartBarrier?
    var captureStopContinuation: CheckedContinuation<URL, Error>?

    /// Device UID this capture recorded from, kept so the dead-capture
    /// watchdog can rebuild a session for the same microphone.
    var captureDeviceUID: String?
    var backendRestartCount = 0
    var backendRestartInFlight = false

    init(
        generation: UInt64,
        recordingRetention: DictationRecordingRetentionPolicy
    ) {
        self.generation = generation
        self.recordingRetention = recordingRetention
    }
}

enum AudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case startFailed
    case noInputDevice
    case finishFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required."
        case .startFailed:
            return "Recording could not start."
        case .noInputDevice:
            return "No microphone input device is available."
        case .finishFailed(let reason):
            return "Recording could not finish: \(reason)"
        }
    }
}

private final class CaptureRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let startBarrier: AudioCaptureStartBarrier
    var onFinish: ((URL, Error?) -> Void)?

    init(startBarrier: AudioCaptureStartBarrier) {
        self.startBarrier = startBarrier
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        _ = startBarrier.resolve(.started(outputFileURL, Date()))
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        _ = startBarrier.resolve(
            .finishedBeforeStart(
                error?.localizedDescription ?? "recording finished before start acknowledgement"
            )
        )
        onFinish?(outputFileURL, error)
    }
}

private final class RecorderStopDelegate: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    var onFinish: ((Bool) -> Void)?

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        onFinish?(flag)
    }
}
