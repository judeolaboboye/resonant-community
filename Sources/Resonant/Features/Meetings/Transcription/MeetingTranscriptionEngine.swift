@preconcurrency import AVFoundation
import CoreAudio
import FluidAudio
import Foundation
import os

/// Orchestrates dual-channel transcription for meeting recording.
/// Mic channel (You) uses AVAudioEngine for the system default mic and AVCaptureSession
/// for explicitly selected mics; system channel (Them) uses SystemAudioCapture.
/// Each channel runs VAD + batch ASR via MeetingStreamingTranscriber.
///
/// Follows the HotMicManager pattern: @MainActor, off-main audio setup, stored tasks.
@MainActor
final class MeetingTranscriptionEngine {

    /// Called on the main actor when a complete utterance is transcribed.
    var onUtterance: ((MeetingUtterance) -> Void)?

    /// Called when the engine detects a fatal audio failure it cannot recover from.
    var onFatalError: ((String) -> Void)?

    /// Called when the system-audio silence watchdog trips — i.e. the mic has been active
    /// for `systemSilenceTripSeconds` but the system channel has delivered zero level.
    var onSystemAudioSilent: (() -> Void)?

    /// Called when system audio returns after a silence trip within the same session.
    var onSystemAudioRecovered: (() -> Void)?

    /// Called when a non-fatal audio subsystem is unavailable (e.g. system audio tap
    /// denied by TCC). The meeting continues in a degraded mode — mic-only.
    var onWarning: ((String) -> Void)?

    /// Called when the mic route is chosen or changed by fallback.
    var onMicrophoneInputChanged: ((String, Bool) -> Void)?

    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0

    /// Resolved audio transport of the current system-audio output device.
    /// Populated in `start()` after `SystemAudioCapture.bufferStream()` succeeds.
    private(set) var systemTransport: MeetingAudioTransport?

    private var micCaptureSource: (any MeetingMicrophoneCaptureSource)?
    /// Stored as Any to avoid @available propagation — always SystemAudioCapture at runtime.
    private var systemCapture: Any?
    private var micTranscriberTask: Task<Void, Never>?
    private var systemTranscriberTask: Task<Void, Never>?
    private var micTranscriber: MeetingStreamingTranscriber?
    private var systemTranscriber: MeetingStreamingTranscriber?
    private var micLevelPollingTask: Task<Void, Never>?
    private var systemLevelPollingTask: Task<Void, Never>?
    private var systemSilenceWatchdogTask: Task<Void, Never>?
    private var systemSilenceStart: Date?
    private var systemSilenceWatchdogTripped = false
    private var micBackend: (any MeetingTranscriptionBackend)?
    private var systemBackend: (any MeetingTranscriptionBackend)?
    private var roomDiarizer: MeetingSpeakerDiarizer?

    /// Cached state used to rebuild the system-audio pipeline on device-switch restart
    /// without reloading backends or VAD models. Set in `start()`, cleared in `teardown()`.
    private var storedSystemVadManager: VadManager?
    private weak var storedAudioRecorder: MeetingAudioRecorder?
    private var storedLocale: Locale?
    private var isSystemCaptureRestarting = false

    /// Resolver for process-scoped taps. Nil when `meetingProcessScopedTapsEnabled`
    /// is off or on macOS 26+ (which handles bundle IDs via `CATapDescription.bundleIDs`).
    private var processResolver: MeetingAudioProcessResolver?
    /// True when the active capture is using a process-scoped tap (PID or bundle).
    private var usingProcessScope = false
    /// Watches for a meeting app to launch if none were running at session start.
    /// Active for 30 seconds on the legacy path; upgrades to process scope when one appears.
    private var processScopeBringUpTask: Task<Void, Never>?

    /// Shared state for mic audio health monitoring.
    private var micBufferTimestamp = OSAllocatedUnfairLock(initialState: Date())
    private var healthWatchdogTask: Task<Void, Never>?
    private var configChangeObserver: NSObjectProtocol?

    /// Stored for mic engine restart after audio configuration changes.
    private var storedInputDeviceUID: String?
    private var storedMicContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var storedMicLevelRef: OSAllocatedUnfairLock<Float>?
    private var transcriptionReferenceDate: Date?
    private var isRestarting = OSAllocatedUnfairLock(initialState: false)
    private var retriedMicWithSystemDefault = false

    /// Wallclock of the most recent successful mic engine start. Used to debounce the
    /// AVAudioEngine configuration-change notification that fires ~100ms after every
    /// `engine.start()` call during normal I/O unit setup — reacting to that notification
    /// would cause an infinite restart loop.
    private var lastMicEngineStartAt: Date?

    /// Pending mic-engine restart task. `restartMicEngine()` schedules a delayed
    /// rebuild; we hold the handle so `teardown()` can cancel it before it
    /// reopens the microphone after the meeting has stopped.
    private var pendingMicRestartTask: Task<Void, Never>?

    /// Set by `teardown()` so any in-flight restart task aborts before
    /// touching audio after the engine is supposed to be down. Without this,
    /// the 500ms restart delay can outlive the user pressing stop.
    private var isTornDown = false

    private let log = Logger.resonant("MeetingTranscriptionEngine")

    /// Maximum seconds without a mic buffer before we attempt a restart.
    private static let healthTimeoutSeconds: TimeInterval = 10

    /// Maximum consecutive restart attempts before giving up.
    private static let maxRestartAttempts = 3

    /// Cooldown window after an engine start during which configuration-change
    /// notifications are ignored as start-up noise rather than real device changes.
    private static let configChangeCooldownSeconds: TimeInterval = 3

    /// Seconds of continuous system-audio silence (with the mic actively picking up the
    /// user) before the watchdog trips. Covers Bluetooth-silent-tap, device-switch,
    /// TCC-gated-but-succeeded-creation, and attenuation failure modes with one signal.
    private static let systemSilenceTripSeconds: TimeInterval = 20

    /// Mic RMS level above which we consider the user "actively present". Below this
    /// we do not trip the watchdog — the user might simply be listening during a pause.
    private static let systemSilenceMicGate: Float = 0.01

    /// Grace window after engine start during which the watchdog ignores silence.
    /// The CoreAudio IO proc can take ~1-2s to start delivering buffers.
    private static let systemSilenceStartGraceSeconds: TimeInterval = 5

    // MARK: - Lifecycle

    func start(
        inputDeviceUID: String?,
        audioRecorder: MeetingAudioRecorder? = nil,
        captureMode: MeetingCaptureMode,
        sessionStartedAt: Date = Date()
    ) async throws {
        guard !isTornDown, !Task.isCancelled else { throw CancellationError() }
        log.info("Starting meeting transcription engine capture_mode=\(captureMode.rawValue, privacy: .public)")
        storedInputDeviceUID = inputDeviceUID
        retriedMicWithSystemDefault = false
        transcriptionReferenceDate = sessionStartedAt

        // Online calls use separate ASR instances for mic and system audio.
        // Room mode is mic-only mixed-room audio, so it avoids grabbing system
        // audio and avoids loading a second backend.
        let backendKind = SettingsManager.shared.meetingTranscriptionBackend
        guard MeetingBackendDownloader.isDownloaded(backendKind) else {
            throw MeetingTranscriptionBackendError.modelNotDownloaded(backendKind)
        }
        let mic = MeetingBackendFactory.make(backendKind)
        let sys = captureMode == .onlineCall ? MeetingBackendFactory.make(backendKind) : nil
        micBackend = mic
        systemBackend = sys
        try await mic.prepare { [weak self] status in
            self?.log.info("Mic backend: \(status)")
        }
        if let sys {
            try await sys.prepare { [weak self] status in
                self?.log.info("System backend: \(status)")
            }
        }

        let micVad = try await Task.detached(priority: .userInitiated) {
            try DictationVADSegmenter.makeCachedManager()
        }.value
        let sysVad: VadManager?
        if sys != nil {
            sysVad = try await Task.detached(priority: .userInitiated) {
                try DictationVADSegmenter.makeCachedManager()
            }.value
        } else {
            sysVad = nil
        }

        let locale = Self.locale(forTranscriptionLanguage: SettingsManager.shared.transcriptionLanguage)
        storedLocale = locale

        // --- Mic channel ---
        let micLevelRef = OSAllocatedUnfairLock(initialState: Float(0))
        storedMicLevelRef = micLevelRef
        let (micStream, micContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        storedMicContinuation = micContinuation

        let micDiarizer: MeetingSpeakerDiarizer?
        if captureMode.usesRoomMicrophoneDiarization {
            let diarizer = MeetingSpeakerDiarizer()
            do {
                try await diarizer.prepare(allowDownload: false)
                await enrollRoomVoiceProfileIfAvailable(on: diarizer)
                micDiarizer = diarizer
                roomDiarizer = diarizer
            } catch {
                diarizer.cleanup()
                micDiarizer = nil
                roomDiarizer = nil
                log.warning("Room speaker diarization unavailable: \(error.localizedDescription)")
                onWarning?(MeetingSpeakerDiarizer.unavailableWarningMessage())
            }
        } else {
            micDiarizer = nil
            roomDiarizer = nil
        }

        let micSpeaker: MeetingSpeaker = captureMode.usesRoomMicrophoneDiarization
            ? .participant(id: "SPEAKER_0")
            : .you
        let micChannelLabel = captureMode.usesRoomMicrophoneDiarization ? "room" : "mic"

        let micTranscriber = MeetingStreamingTranscriber(
            backend: mic,
            locale: locale,
            vadManager: micVad,
            speaker: micSpeaker,
            channelLabel: micChannelLabel,
            diarizer: micDiarizer,
            onAudioSamples: { samples, uptime in
                audioRecorder?.append(samples, channel: .mic, uptime: uptime)
            }
        ) { [weak self] (text: String, speaker: MeetingSpeaker, segmentStartOffset: TimeInterval) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let referenceDate = self.transcriptionReferenceDate ?? Date()
                let utterance = MeetingUtterance(
                    text: text,
                    speaker: speaker,
                    timestamp: referenceDate.addingTimeInterval(segmentStartOffset)
                )
                self.onUtterance?(utterance)
            }
        }
        self.micTranscriber = micTranscriber

        try await setupMicEngine(
            inputDeviceUID: inputDeviceUID,
            continuation: micContinuation,
            levelRef: micLevelRef
        )
        guard !isTornDown, !Task.isCancelled else {
            stopMicCaptureSource()
            throw CancellationError()
        }
        lastMicEngineStartAt = Date()
        micBufferTimestamp.withLock { $0 = Date() }

        micTranscriberTask = Task.detached { [micTranscriber] in
            await micTranscriber.run(stream: micStream)
        }

        micLevelPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { break }
                let level = micLevelRef.withLock { $0 }
                if self.micLevel != level {
                    self.micLevel = level
                }
            }
        }

        // --- Audio configuration change observer ---
        observeAudioConfigurationChanges()

        // --- Health watchdog ---
        startHealthWatchdog()

        guard captureMode == .onlineCall else {
            log.info("Meeting transcription engine started — room microphone channel active")
            return
        }

        // --- System audio channel ---
        guard #available(macOS 14.2, *) else {
            log.warning("System audio capture requires macOS 14.2+ — mic-only mode")
            return
        }

        guard let sys, let sysVad else {
            log.warning("System backend unavailable — continuing mic-only")
            return
        }

        storedSystemVadManager = sysVad
        storedAudioRecorder = audioRecorder

        let capture = SystemAudioCapture()
        systemCapture = capture

        let initialScope = resolveInitialCaptureScope()
        let captureStreams: SystemAudioCapture.CaptureStreams
        do {
            captureStreams = try await capture.bufferStream(scope: initialScope)
        } catch {
            log.error("System audio capture failed, continuing mic-only: \(error.localizedDescription)")
            systemCapture = nil
            systemTransport = nil
            usingProcessScope = false
            processScopeBringUpTask?.cancel()
            processResolver?.stop()
            processResolver = nil
            if let sys = systemBackend { await sys.tearDown() }
            systemBackend = nil
            onWarning?(error.localizedDescription)
            return
        }
        systemTransport = captureStreams.resolvedDeviceTransport
        usingProcessScope = !captureStreams.isDeviceScoped

        // Device-switch resilience only matters for device-scoped taps. Process-scoped
        // taps read pre-routing and are already immune to output changes.
        if captureStreams.isDeviceScoped {
            capture.startObservingDefaultOutputChanges { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleSystemAudioDeviceChanged()
                }
            }
        }

        processResolver?.onChange = { [weak self] resolved in
            Task { @MainActor [weak self] in
                await self?.handleProcessResolverChanged(resolved)
            }
        }

        // If process scope was requested but no meeting app was running, watch for
        // one to launch and upgrade the tap when it does.
        if SettingsManager.shared.meetingProcessScopedTapsEnabled,
           !usingProcessScope,
           processResolver != nil {
            startProcessScopeBringUpWatcher()
        }

        let systemTranscriber = MeetingStreamingTranscriber(
            backend: sys,
            locale: locale,
            vadManager: sysVad,
            speaker: MeetingSpeaker.them,
            channelLabel: "system",
            onAudioSamples: { samples, uptime in
                audioRecorder?.append(samples, channel: .system, uptime: uptime)
            }
        ) { [weak self] (text: String, speaker: MeetingSpeaker, segmentStartOffset: TimeInterval) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let referenceDate = self.transcriptionReferenceDate ?? Date()
                let utterance = MeetingUtterance(
                    text: text,
                    speaker: speaker,
                    timestamp: referenceDate.addingTimeInterval(segmentStartOffset)
                )
                self.onUtterance?(utterance)
            }
        }
        self.systemTranscriber = systemTranscriber

        systemTranscriberTask = Task.detached { [systemTranscriber] in
            await systemTranscriber.run(stream: captureStreams.systemAudio)
        }

        systemLevelPollingTask = Task { [weak self, weak capture] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let capture else { break }
                let level = capture.audioLevel
                if self.systemLevel != level {
                    self.systemLevel = level
                }
            }
        }

        startSystemSilenceWatchdog()

        log.info("Meeting transcription engine started — mic + system channels active")
    }

    nonisolated static func locale(forTranscriptionLanguage language: String) -> Locale {
        language == "auto" ? Locale.current : Locale(identifier: language)
    }

    private func enrollRoomVoiceProfileIfAvailable(on diarizer: MeetingSpeakerDiarizer) async {
        let store = MeetingVoiceProfileStore()
        guard store.hasEnrollment else { return }

        do {
            let rootURL = store.rootURL
            let enrollmentFileName = store.enrollmentFileName
            let samples = try await Task.detached(priority: .userInitiated) {
                try MeetingVoiceProfileStore(
                    rootURL: rootURL,
                    enrollmentFileName: enrollmentFileName
                ).loadEnrollmentSamples()
            }.value

            let didEnroll = try await Task.detached(priority: .userInitiated) {
                try diarizer.enrollLocalUserVoice(samples: samples)
            }.value

            if didEnroll {
                log.info("Room Mode Voice ID enrollment ready")
            } else {
                log.warning("Room Mode Voice ID enrollment skipped: no speaker slot")
            }
        } catch {
            log.warning("Room Mode Voice ID enrollment unavailable: \(error.localizedDescription)")
        }
    }

    // MARK: - System-Audio Silence Watchdog

    private func startSystemSilenceWatchdog() {
        systemSilenceStart = nil
        systemSilenceWatchdogTripped = false

        systemSilenceWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { break }
                self.tickSystemSilenceWatchdog()
            }
        }
    }

    private func tickSystemSilenceWatchdog() {
        guard let sessionStart = transcriptionReferenceDate else { return }
        guard Date().timeIntervalSince(sessionStart) > Self.systemSilenceStartGraceSeconds else { return }

        let micActive = micLevel > Self.systemSilenceMicGate
        let systemSilent = systemLevel == 0

        if !systemSilent, systemSilenceWatchdogTripped {
            systemSilenceWatchdogTripped = false
            systemSilenceStart = nil
            log.info("System audio recovered after silence trip")
            onSystemAudioRecovered?()
            return
        }

        guard micActive, systemSilent else {
            systemSilenceStart = nil
            return
        }

        if systemSilenceStart == nil {
            systemSilenceStart = Date()
            return
        }

        guard let silenceStart = systemSilenceStart,
              !systemSilenceWatchdogTripped,
              Date().timeIntervalSince(silenceStart) >= Self.systemSilenceTripSeconds
        else { return }

        systemSilenceWatchdogTripped = true
        log.warning("System audio silent for \(Int(Self.systemSilenceTripSeconds))s with active mic — tripping watchdog")
        onSystemAudioSilent?()
    }

    // MARK: - System Audio Device-Switch Handling

    /// Invoked when `kAudioHardwarePropertyDefaultOutputDevice` changes mid-session.
    /// Delegates to the shared restart path against the new default output.
    @available(macOS 14.2, *)
    private func handleSystemAudioDeviceChanged() async {
        log.warning("Default output device changed — restarting system audio tap")
        await restartSystemCapture(scope: .device(nil))
    }

    // MARK: - Process-Scoped Capture

    /// Decides which `CaptureScope` to use for the initial tap, based on the opt-in
    /// setting, running meeting apps, and OS version. On macOS 26+ we hand bundle IDs
    /// directly to `CATapDescription.bundleIDs`; on older systems we enumerate
    /// `NSWorkspace.runningApplications` and translate PIDs via the resolver.
    @available(macOS 14.2, *)
    private func resolveInitialCaptureScope() -> SystemAudioCapture.CaptureScope {
        guard SettingsManager.shared.meetingProcessScopedTapsEnabled else {
            return .device(nil)
        }

        if #available(macOS 26.0, *) {
            log.info("Process-scoped requested: using bundleIDs path (macOS 26+)")
            return .bundleIDs(MeetingAudioProcessResolver.knownMeetingBundleIDs)
        }

        let resolver = MeetingAudioProcessResolver()
        resolver.start()
        processResolver = resolver

        let initialIDs = resolver.current.ids
        guard !initialIDs.isEmpty else {
            log.info("Process-scoped requested but no meeting app running; falling back to device scope with bring-up watcher")
            return .device(nil)
        }

        log.info("Process-scoped requested: \(initialIDs.count) meeting process(es) resolved")
        return .processObjectIDs(initialIDs)
    }

    /// Called by the resolver when the set of running meeting apps changes.
    /// Restarts the system tap against the new PID list — no-op on macOS 26+.
    @available(macOS 14.2, *)
    private func handleProcessResolverChanged(_ resolved: MeetingAudioProcessResolver.ResolvedProcesses) async {
        guard !isSystemCaptureRestarting else { return }

        if !usingProcessScope {
            // First discovery — upgrade from device scope.
            if !resolved.ids.isEmpty {
                await upgradeToProcessScope(ids: resolved.ids)
            }
            return
        }

        // Already process-scoped: restart against new PID set (or fall back if empty).
        if resolved.ids.isEmpty {
            log.info("All meeting apps quit; leaving last-known process tap in place until new app appears")
            return
        }
        await restartSystemCapture(scope: .processObjectIDs(resolved.ids))
    }

    @available(macOS 14.2, *)
    private func startProcessScopeBringUpWatcher() {
        processScopeBringUpTask?.cancel()
        processScopeBringUpTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(30)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard !self.usingProcessScope,
                      let resolver = self.processResolver,
                      !resolver.current.ids.isEmpty
                else { continue }
                await self.upgradeToProcessScope(ids: resolver.current.ids)
                return
            }
        }
    }

    @available(macOS 14.2, *)
    private func upgradeToProcessScope(ids: [AudioObjectID]) async {
        guard !usingProcessScope, !ids.isEmpty else { return }
        log.info("Upgrading capture scope: device → processObjectIDs (\(ids.count))")
        await restartSystemCapture(scope: .processObjectIDs(ids))
        if usingProcessScope {
            processScopeBringUpTask?.cancel()
            processScopeBringUpTask = nil
        }
    }

    /// Shared restart path used by both default-output-device changes and scope
    /// upgrades. Tears down the existing system capture and re-spawns against the
    /// requested scope without touching the mic, backend, or VAD.
    @available(macOS 14.2, *)
    private func restartSystemCapture(scope: SystemAudioCapture.CaptureScope) async {
        guard !isSystemCaptureRestarting else { return }
        guard let sys = systemBackend,
              let sysVad = storedSystemVadManager
        else {
            log.debug("Scope restart ignored — no active system backend")
            return
        }

        isSystemCaptureRestarting = true
        defer { isSystemCaptureRestarting = false }

        systemTranscriberTask?.cancel()
        systemTranscriberTask = nil
        systemLevelPollingTask?.cancel()
        systemLevelPollingTask = nil

        if let oldCapture = systemCapture as? SystemAudioCapture {
            await oldCapture.stop()
        }
        systemCapture = nil

        let newCapture = SystemAudioCapture()
        systemCapture = newCapture

        let newStreams: SystemAudioCapture.CaptureStreams
        do {
            newStreams = try await newCapture.bufferStream(scope: scope)
        } catch {
            log.error("Scope restart failed: \(error.localizedDescription)")
            systemCapture = nil
            onSystemAudioSilent?()
            return
        }

        systemTransport = newStreams.resolvedDeviceTransport
        usingProcessScope = !newStreams.isDeviceScoped

        if newStreams.isDeviceScoped {
            newCapture.startObservingDefaultOutputChanges { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleSystemAudioDeviceChanged()
                }
            }
        }

        let audioRecorder = storedAudioRecorder
        let locale = storedLocale ?? Self.locale(forTranscriptionLanguage: SettingsManager.shared.transcriptionLanguage)
        let systemTranscriber = MeetingStreamingTranscriber(
            backend: sys,
            locale: locale,
            vadManager: sysVad,
            speaker: MeetingSpeaker.them,
            channelLabel: "system-restart",
            onAudioSamples: { samples, uptime in
                audioRecorder?.append(samples, channel: .system, uptime: uptime)
            }
        ) { [weak self] (text: String, speaker: MeetingSpeaker, segmentStartOffset: TimeInterval) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let referenceDate = self.transcriptionReferenceDate ?? Date()
                let utterance = MeetingUtterance(
                    text: text,
                    speaker: speaker,
                    timestamp: referenceDate.addingTimeInterval(segmentStartOffset)
                )
                self.onUtterance?(utterance)
            }
        }
        self.systemTranscriber = systemTranscriber

        systemTranscriberTask = Task.detached { [systemTranscriber] in
            await systemTranscriber.run(stream: newStreams.systemAudio)
        }

        systemLevelPollingTask = Task { [weak self, weak newCapture] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let newCapture else { break }
                let level = newCapture.audioLevel
                if self.systemLevel != level {
                    self.systemLevel = level
                }
            }
        }

        systemSilenceStart = nil
        systemSilenceWatchdogTripped = false

        let scopeLabel = newStreams.isDeviceScoped ? "device" : "process"
        log.info("System capture scope restart complete (scope: \(scopeLabel, privacy: .public))")
    }

    // MARK: - Audio Configuration Change Handling

    func switchMicrophoneInput(to inputDeviceUID: String?) {
        storedInputDeviceUID = inputDeviceUID
        retriedMicWithSystemDefault = false
        let routeLabel = inputDeviceUID == nil ? "system default" : "selected input"
        log.notice("Switching meeting microphone route to \(routeLabel, privacy: .public)")
        restartMicEngine()
    }

    /// Observes AVAudioEngine.configurationChangeNotification to handle audio device
    /// changes (Bluetooth disconnect, headphone plug/unplug, etc.) that silently stop
    /// the engine from producing buffers.
    private func observeAudioConfigurationChanges() {
        guard let notificationObject = micCaptureSource?.configurationChangeNotificationObject else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: notificationObject,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAudioConfigurationChange()
            }
        }
    }

    private func handleAudioConfigurationChange() {
        // AVAudioEngine posts a configuration-change notification ~100ms after every
        // engine.start() as its I/O unit initializes. Ignore notifications that arrive
        // within the cooldown window; the 10s health watchdog will still catch a
        // genuinely silent mic if this was a real device event.
        if let startedAt = lastMicEngineStartAt,
           Date().timeIntervalSince(startedAt) < Self.configChangeCooldownSeconds {
            log.debug("Audio configuration change inside start cooldown — ignoring")
            return
        }
        log.warning("Audio configuration changed — restarting mic engine")
        restartMicEngine()
    }

    /// Tears down the current mic source and rebuilds it, keeping the same
    /// stream continuation so the transcriber task keeps consuming seamlessly.
    private func restartMicEngine(attempt: Int = 1) {
        guard !isTornDown else { return }
        guard isRestarting.withLock({ guard !$0 else { return false }; $0 = true; return true }) else { return }
        guard let continuation = storedMicContinuation,
              let levelRef = storedMicLevelRef else {
            log.error("Cannot restart mic engine — missing continuation or level ref")
            isRestarting.withLock { $0 = false }
            return
        }

        // Remove old observer before tearing down
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        // Tear down current mic source
        stopMicCaptureSource()

        // Rebuild after a short delay to let the audio subsystem settle.
        // The handle is stored so `teardown()` can cancel a pending restart
        // before it reopens the microphone post-stop.
        pendingMicRestartTask?.cancel()
        pendingMicRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, !self.isTornDown else { return }

            do {
                try await self.setupMicEngine(
                    inputDeviceUID: self.storedInputDeviceUID,
                    continuation: continuation,
                    levelRef: levelRef
                )
                guard !self.isTornDown else {
                    // teardown raced ahead — undo the capture source we just started
                    self.stopMicCaptureSource()
                    self.isRestarting.withLock { $0 = false }
                    return
                }
                self.lastMicEngineStartAt = Date()
                self.observeAudioConfigurationChanges()
                self.micBufferTimestamp.withLock { $0 = Date() }
                self.isRestarting.withLock { $0 = false }
                self.log.info("Mic engine restarted successfully (attempt \(attempt))")
            } catch {
                self.isRestarting.withLock { $0 = false }
                self.log.error("Mic engine restart failed (attempt \(attempt)): \(error.localizedDescription)")

                if attempt < Self.maxRestartAttempts, !self.isTornDown {
                    // Exponential backoff: 1s, 2s, 4s
                    let delay = Double(1 << (attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, !self.isTornDown else { return }
                    self.restartMicEngine(attempt: attempt + 1)
                } else if !self.isTornDown {
                    self.log.error("Mic engine restart exhausted \(Self.maxRestartAttempts) attempts — recording may be degraded")
                    self.onFatalError?("Microphone stopped responding. Try stopping and restarting the recording.")
                }
            }
        }
    }

    // MARK: - Health Watchdog

    /// Periodically checks that mic buffers are still flowing. If no buffer arrives
    /// for `healthTimeoutSeconds`, triggers a mic engine restart.
    private func startHealthWatchdog() {
        healthWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { break }

                let lastBuffer = self.micBufferTimestamp.withLock { $0 }
                let elapsed = Date().timeIntervalSince(lastBuffer)

                if elapsed > Self.healthTimeoutSeconds && !self.isRestarting.withLock({ $0 }) {
                    if self.storedInputDeviceUID != nil,
                       !self.retriedMicWithSystemDefault {
                        self.retriedMicWithSystemDefault = true
                        self.storedInputDeviceUID = nil
                        self.log.error("No mic buffer for \(Int(elapsed))s from selected input — retrying with system default microphone")
                        self.onWarning?("Selected microphone is not delivering audio. Retrying with the system default microphone.")
                    } else {
                        self.log.error("No mic buffer for \(Int(elapsed))s — attempting restart")
                    }
                    self.restartMicEngine()
                }
            }
        }
    }

    // MARK: - Teardown

    /// Strict teardown order: cancel consumers → stop audio sources → release backends.
    func teardown() async {
        log.info("Tearing down meeting transcription engine")
        // Set first so any in-flight restart task aborts before touching audio.
        isTornDown = true

        // Remove config change observer
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        // Cancel any pending mic-engine restart so it can't reopen the mic
        // after we've torn down. Without this, a 500ms restart delay scheduled
        // moments before stop can race ahead and reactivate the microphone.
        pendingMicRestartTask?.cancel()
        pendingMicRestartTask = nil

        // Cancel health watchdog
        healthWatchdogTask?.cancel()
        healthWatchdogTask = nil

        // 1. Cancel consumer tasks
        micTranscriberTask?.cancel()
        micTranscriberTask = nil
        systemTranscriberTask?.cancel()
        systemTranscriberTask = nil
        micTranscriber = nil
        systemTranscriber = nil
        micLevelPollingTask?.cancel()
        micLevelPollingTask = nil
        systemLevelPollingTask?.cancel()
        systemLevelPollingTask = nil
        systemSilenceWatchdogTask?.cancel()
        systemSilenceWatchdogTask = nil
        processScopeBringUpTask?.cancel()
        processScopeBringUpTask = nil
        processResolver?.stop()
        processResolver = nil

        // 2. Stop mic source (removeTap/stop session → nil)
        stopMicCaptureSource()

        // 3. Stop system capture (finishes stream continuation)
        if #available(macOS 14.2, *), let capture = systemCapture as? SystemAudioCapture {
            await capture.stop()
        }
        systemCapture = nil

        // 4. Release backends after capture is already stopped. Shared-model
        // release can take a moment, so keep it off the user-visible stop path.
        let mic = micBackend
        let sys = systemBackend
        roomDiarizer?.cleanup()
        roomDiarizer = nil
        micBackend = nil
        systemBackend = nil
        if mic != nil || sys != nil {
            Task.detached(priority: .utility) {
                if let mic { await mic.tearDown() }
                if let sys { await sys.tearDown() }
            }
        }

        // 5. Clear stored state
        storedMicContinuation = nil
        storedMicLevelRef = nil
        transcriptionReferenceDate = nil
        storedSystemVadManager = nil
        storedAudioRecorder = nil
        storedLocale = nil
        isSystemCaptureRestarting = false
        usingProcessScope = false
        retriedMicWithSystemDefault = false

        micLevel = 0
        systemLevel = 0
        systemTransport = nil
        systemSilenceStart = nil
        systemSilenceWatchdogTripped = false
    }

    // MARK: - Mic Engine Setup

    /// Sets up the mic source through a small capture interface. The engine owns
    /// orchestration; the source owns hardware-specific capture details.
    private func setupMicEngine(
        inputDeviceUID: String?,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        levelRef: OSAllocatedUnfairLock<Float>
    ) async throws {
        let permissionStatus = MeetingMicrophoneCapturePermission.statusDescription()
        log.notice("Mic setup requested permission=\(permissionStatus, privacy: .public) selected_uid_present=\((inputDeviceUID != nil), privacy: .public)")

        guard await MeetingMicrophoneCapturePermission.ensureMicrophoneAccess() else {
            log.error("Mic setup blocked: microphone permission is not authorized")
            throw MeetingAudioCaptureError.microphonePermissionDenied
        }
        // Permission can suspend while teardown wins. Re-check before even
        // constructing a source so a retired meeting cannot enqueue a fresh
        // microphone open after the permission sheet resolves.
        guard MeetingMicrophoneCaptureStartPolicy.shouldBeginSourceStart(
            isTornDown: isTornDown,
            isTaskCancelled: Task.isCancelled
        ) else { throw CancellationError() }

        let context = MeetingMicrophoneCaptureContext(
            continuation: continuation,
            levelRef: levelRef,
            bufferTimestamp: micBufferTimestamp,
            log: log
        )
        let route = MeetingMicrophoneCaptureRoute.resolve(inputDeviceUID: inputDeviceUID)
        let source = MeetingMicrophoneCaptureSourceFactory.make(
            inputDeviceUID: inputDeviceUID,
            context: context
        )

        do {
            try await startMicCaptureSource(source)
            onMicrophoneInputChanged?(source.displayName, source.usesSystemDefault)
            log.notice("Mic capture source started system_default=\(source.usesSystemDefault, privacy: .public)")
            return
        } catch {
            guard !isTornDown, !Task.isCancelled else { throw CancellationError() }
            guard !route.usesSystemDefault else { throw error }
            retriedMicWithSystemDefault = true
            storedInputDeviceUID = nil
            onWarning?("Selected microphone could not start. Using the system default microphone.")
            log.error("Selected mic capture source failed: \(error.localizedDescription)")
        }

        let fallback = MeetingMicrophoneCaptureSourceFactory.make(
            inputDeviceUID: nil,
            context: context
        )
        try await startMicCaptureSource(fallback)
        onMicrophoneInputChanged?(fallback.displayName, fallback.usesSystemDefault)
        log.notice("Mic capture source started system_default=true")
    }

    /// Installs ownership before suspension so teardown can always enqueue a
    /// stop behind an in-flight source start on the shared lifecycle queue.
    private func startMicCaptureSource(
        _ source: any MeetingMicrophoneCaptureSource
    ) async throws {
        guard MeetingMicrophoneCaptureStartPolicy.shouldBeginSourceStart(
            isTornDown: isTornDown,
            isTaskCancelled: Task.isCancelled
        ) else { throw CancellationError() }

        micCaptureSource = source
        do {
            try await source.start()
        } catch {
            discardMicCaptureSource(source)
            throw error
        }

        guard MeetingMicrophoneCaptureStartPolicy.shouldRetainStartedSource(
            isTornDown: isTornDown,
            isTaskCancelled: Task.isCancelled,
            isStillCurrent: isCurrentMicCaptureSource(source)
        ) else {
            discardMicCaptureSource(source)
            throw CancellationError()
        }
    }

    private func isCurrentMicCaptureSource(
        _ source: any MeetingMicrophoneCaptureSource
    ) -> Bool {
        guard let current = micCaptureSource else { return false }
        return current === source
    }

    private func discardMicCaptureSource(
        _ source: any MeetingMicrophoneCaptureSource
    ) {
        source.stop()
        if isCurrentMicCaptureSource(source) {
            micCaptureSource = nil
        }
    }

    private func stopMicCaptureSource() {
        let source = micCaptureSource
        micCaptureSource = nil
        source?.stop()
    }
}

enum MeetingMicrophoneCaptureStartPolicy {
    static func shouldBeginSourceStart(
        isTornDown: Bool,
        isTaskCancelled: Bool
    ) -> Bool {
        !isTornDown && !isTaskCancelled
    }

    static func shouldRetainStartedSource(
        isTornDown: Bool,
        isTaskCancelled: Bool,
        isStillCurrent: Bool
    ) -> Bool {
        !isTornDown && !isTaskCancelled && isStillCurrent
    }
}
