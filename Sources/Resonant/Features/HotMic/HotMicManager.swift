import Accelerate
@preconcurrency import AVFoundation
import CoreAudio
import FluidAudio
import Foundation
import os

@MainActor
final class HotMicManager {

    var onPasteTriggered: ((String) async -> Void)?
    var onStateUpdate: ((Float, String) -> Void)?
    var onFatalError: ((String) -> Void)?

    private(set) var isActive = false
    private(set) var isPaused = false
    private(set) var audioLevel: Float = 0

    private let postProcessor: PostProcessor
    private var audioEngine: AVAudioEngine?
    private var streamingManager: SlidingWindowAsrManager?
    private var updateConsumerTask: Task<Void, Never>?
    private var levelPollingTask: Task<Void, Never>?
    private var isProcessingPaste = false
    private var lastLevelUpdate = Date.distantPast

    private var storedInputDeviceUID: String?
    private var storedLevelRef: OSAllocatedUnfairLock<Float>?
    private var configChangeObserver: NSObjectProtocol?
    private var healthWatchdogTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var isStarting = false
    private var isStopping = false
    private var startupDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var bufferTimestamp = OSAllocatedUnfairLock(initialState: Date())
    private var isRestarting = OSAllocatedUnfairLock(initialState: false)
    private var lastEngineStartAt: Date?

    private let log = Logger.resonant("HotMicManager")

    private static let healthTimeoutSeconds: TimeInterval = 10
    private static let maxRestartAttempts = 3
    private static let configChangeCooldownSeconds: TimeInterval = 3

    init(postProcessor: PostProcessor) {
        self.postProcessor = postProcessor
    }

    // MARK: - Lifecycle

    func start(inputDeviceUID: String?) async throws {
        guard !isActive, !isPaused, !isStarting, !isStopping else { return }
        isStarting = true
        let generation = lifecycleGeneration
        defer { finishStartupTransition() }

        let models = try await Task.detached(priority: .userInitiated) {
            try await AsrModels.loadFromCache(version: .v3)
        }.value
        guard generation == lifecycleGeneration, !Task.isCancelled else { return }

        let manager = SlidingWindowAsrManager(config: .streaming)
        do {
            try await manager.loadModels(models)
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                await manager.cancel()
                return
            }
            try await manager.startStreaming(source: .microphone)
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                await manager.cancel()
                return
            }
            streamingManager = manager

            storedInputDeviceUID = inputDeviceUID
            try await setupAudioEngineOffMain(inputDeviceUID: inputDeviceUID)
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                teardownPipeline()
                await manager.cancel()
                streamingManager = nil
                return
            }
            lastEngineStartAt = Date()
            startConsumingUpdates(from: manager)
            observeAudioConfigurationChanges()
            startHealthWatchdog()

            isActive = true
            isPaused = false
            SentryManager.shared.hotMicToggled(enabled: true)
        } catch {
            let failedTasks = teardownPipeline()
            await manager.cancel()
            for task in failedTasks {
                await task.value
            }
            streamingManager = nil
            guard generation == lifecycleGeneration else { return }
            throw error
        }
    }

    func stop() async {
        if isStopping {
            await waitForStopCompletion()
            return
        }
        guard isActive || isPaused || isStarting || streamingManager != nil else { return }
        isStopping = true
        lifecycleGeneration &+= 1
        isActive = false
        isPaused = false

        let pipelineTasks = teardownPipeline()
        let manager = streamingManager
        await manager?.cancel()
        await waitForStartupCompletion()
        for task in pipelineTasks {
            await task.value
        }
        // A start may have reached audio setup before observing the generation
        // change. Retire anything it installed while this stop was suspended.
        let latePipelineTasks = teardownPipeline()
        await streamingManager?.cancel()
        for task in latePipelineTasks {
            await task.value
        }
        streamingManager = nil
        isActive = false
        isPaused = false
        audioLevel = 0
        storedInputDeviceUID = nil
        storedLevelRef = nil
        SentryManager.shared.hotMicToggled(enabled: false)
        finishStopTransition()
    }

    /// Explicit clear/shutdown spelling for callers that require a fully
    /// retired startup, restart, consumer, and audio pipeline boundary.
    func stopAndWait() async {
        await stop()
    }

    func pause() async {
        guard isActive, !isPaused else { return }
        isPaused = true
        isActive = false

        let pipelineTasks = teardownPipeline()
        try? await streamingManager?.reset()
        for task in pipelineTasks {
            await task.value
        }
    }

    func resume() async throws {
        guard isPaused, let manager = streamingManager, !isStarting, !isStopping else { return }
        isStarting = true
        let generation = lifecycleGeneration
        defer { finishStartupTransition() }
        let staleTasks = teardownPipeline()
        for task in staleTasks {
            await task.value
        }
        guard generation == lifecycleGeneration, !Task.isCancelled else { return }

        do {
            try await manager.reset()
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            let uid = SettingsManager.shared.inputDeviceUID
            storedInputDeviceUID = uid
            try await setupAudioEngineOffMain(inputDeviceUID: uid)
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                teardownPipeline()
                return
            }
            lastEngineStartAt = Date()
            startConsumingUpdates(from: manager)
            observeAudioConfigurationChanges()
            startHealthWatchdog()
            isPaused = false
            isActive = true
        } catch {
            let failedPipelineTasks = teardownPipeline()
            for task in failedPipelineTasks {
                await task.value
            }
            guard generation == lifecycleGeneration else { return }
            SentryManager.shared.hotMicError(error)
            isPaused = true
            isActive = false
            throw error
        }
    }

    private func finishStartupTransition() {
        isStarting = false
        let waiters = startupDrainWaiters
        startupDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForStartupCompletion() async {
        guard isStarting else { return }
        await withCheckedContinuation { continuation in
            startupDrainWaiters.append(continuation)
        }
    }

    private func finishStopTransition() {
        isStopping = false
        let waiters = stopDrainWaiters
        stopDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForStopCompletion() async {
        guard isStopping else { return }
        await withCheckedContinuation { continuation in
            stopDrainWaiters.append(continuation)
        }
    }

    // MARK: - Update handling & hot word detection

    private func handleUpdate(_ update: SlidingWindowTranscriptionUpdate) async {
        guard let manager = streamingManager, !isProcessingPaste else { return }

        let hotWord = SettingsManager.shared.hotWord
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !hotWord.isEmpty else { return }

        let confirmed = await manager.confirmedTranscript
        let volatile = await manager.volatileTranscript
        let displayText = [confirmed, volatile]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        onStateUpdate?(audioLevel, displayText)

        let searchText = displayText.lowercased()
        guard let range = searchText.range(of: hotWord, options: .backwards) else { return }
        SentryManager.shared.hotMicWakeDetected()

        let payloadEnd = searchText.distance(from: searchText.startIndex, to: range.lowerBound)
        let rawPayload = String(displayText.prefix(payloadEnd))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawPayload.isEmpty else {
            await resetAndClearDisplay(manager)
            return
        }

        isProcessingPaste = true
        defer { isProcessingPaste = false }

        let finalText = await postProcessor.process(rawPayload)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !finalText.isEmpty else {
            await resetAndClearDisplay(manager)
            return
        }

        SentryManager.shared.hotMicDispatch(wordCount: finalText.split(separator: " ").count)
        await onPasteTriggered?(finalText)
        await resetAndClearDisplay(manager)
    }

    // MARK: - Private helpers

    private func startConsumingUpdates(from manager: SlidingWindowAsrManager) {
        updateConsumerTask = Task { [weak self] in
            let updateStream = await manager.transcriptionUpdates
            for await update in updateStream {
                guard !Task.isCancelled else { break }
                await self?.handleUpdate(update)
            }
        }
    }

    @discardableResult
    private func teardownPipeline() -> [Task<Void, Never>] {
        let tasks = [
            healthWatchdogTask,
            levelPollingTask,
            updateConsumerTask,
            restartTask,
        ].compactMap { $0 }
        tasks.forEach { $0.cancel() }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        healthWatchdogTask = nil
        levelPollingTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        updateConsumerTask = nil
        restartTask = nil
        isRestarting.withLock { $0 = false }
        return tasks
    }

    private func resetAndClearDisplay(_ manager: SlidingWindowAsrManager) async {
        try? await manager.reset()
        onStateUpdate?(audioLevel, "")
    }

    // MARK: - AVAudioEngine

    /// Builds and starts the audio engine off the main thread so `engine.start()`
    /// (which synchronously initialises audio hardware) cannot hang the UI.
    private func setupAudioEngineOffMain(inputDeviceUID: String?) async throws {
        let manager = streamingManager
        let levelRef = storedLevelRef ?? OSAllocatedUnfairLock(initialState: Float(0))
        storedLevelRef = levelRef
        let timestampRef = bufferTimestamp

        let engine = try await Task.detached(priority: .userInitiated) {
            let engine = AVAudioEngine()

            if let uid = inputDeviceUID {
                Self.setInputDevice(uid: uid, on: engine)
            }

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak manager] buffer, _ in
                timestampRef.withLock { $0 = Date() }

                guard let manager else { return }

                Task { await manager.streamAudio(buffer) }

                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = vDSP_Length(buffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, frameLength)
                let level = min(1.0, rms * 5.0)
                levelRef.withLock { $0 = level }
            }

            try engine.start()
            return engine
        }.value

        audioEngine = engine
        bufferTimestamp.withLock { $0 = Date() }

        levelPollingTask?.cancel()
        levelPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.isActive || self.isPaused == false else { continue }
                self.audioLevel = levelRef.withLock { $0 }
            }
        }
    }

    // MARK: - Resilience

    private func observeAudioConfigurationChanges() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        if let startedAt = lastEngineStartAt,
           Date().timeIntervalSince(startedAt) < Self.configChangeCooldownSeconds {
            log.debug("Audio configuration change inside start cooldown — ignoring")
            return
        }
        log.warning("Audio configuration changed — restarting hot mic engine")
        restartEngine()
    }

    private func startHealthWatchdog() {
        healthWatchdogTask?.cancel()
        healthWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { break }
                guard self.isActive else { continue }

                let lastBuffer = self.bufferTimestamp.withLock { $0 }
                let elapsed = Date().timeIntervalSince(lastBuffer)
                let restarting = self.isRestarting.withLock { $0 }

                if elapsed > Self.healthTimeoutSeconds, !restarting {
                    self.log.warning("No hot mic buffer for \(Int(elapsed))s — attempting restart")
                    self.restartEngine()
                }
            }
        }
    }

    private func restartEngine(attempt: Int = 1) {
        guard isRestarting.withLock({ guard !$0 else { return false }; $0 = true; return true }) else { return }
        guard isActive else {
            isRestarting.withLock { $0 = false }
            return
        }

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil

        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.isActive, !Task.isCancelled else {
                self?.isRestarting.withLock { $0 = false }
                return
            }

            do {
                try await self.setupAudioEngineOffMain(inputDeviceUID: self.storedInputDeviceUID)
                guard self.isActive, !Task.isCancelled else {
                    self.teardownPipeline()
                    return
                }
                self.lastEngineStartAt = Date()
                self.observeAudioConfigurationChanges()
                self.bufferTimestamp.withLock { $0 = Date() }
                self.isRestarting.withLock { $0 = false }
                self.log.info("Hot mic engine restarted successfully (attempt \(attempt))")
            } catch {
                self.isRestarting.withLock { $0 = false }
                self.log.error("Hot mic engine restart failed (attempt \(attempt)): \(error.localizedDescription)")
                SentryManager.shared.hotMicError(error)

                if attempt < Self.maxRestartAttempts {
                    let delay = Double(1 << (attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    self.restartEngine(attempt: attempt + 1)
                } else {
                    self.log.error("Hot mic engine restart exhausted \(Self.maxRestartAttempts) attempts")
                    self.onFatalError?("Microphone stopped responding. Toggle hot mic off and on to recover.")
                }
            }
        }
    }

    /// Shared with DictationLivePreviewController — binds an AVAudioEngine's
    /// input to a specific CoreAudio device by UID.
    nonisolated static func setInputDevice(uid: String, on engine: AVAudioEngine) {
        var propSize: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize)
        let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &devices)

        var targetDeviceID: AudioDeviceID = 0
        for id in devices {
            var uidValue: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidValue) == noErr,
               let uidValue,
               (uidValue.takeUnretainedValue() as String) == uid {
                targetDeviceID = id
                break
            }
        }

        guard targetDeviceID != 0 else { return }

        if let audioUnit = engine.inputNode.audioUnit {
            var deviceID = targetDeviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
    }
}
