import Accelerate
@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os

/// Streams a best-effort live transcript into the notch while the user is
/// dictating. Purely cosmetic: the delivered text still comes from the batch
/// decode at stop time, so preview text may lag or differ slightly — it exists
/// to make dictation feel alive instead of a silent "Listening…" strip.
///
/// Deliberately simpler than HotMicManager: no health watchdog, no engine
/// restarts. A preview that dies mid-recording just stops updating; it must
/// never delay, break, or contend with the capture path. All failures are
/// logged and swallowed.
@MainActor
final class DictationLivePreviewController {

    /// Fired with the combined confirmed+volatile transcript (may be empty).
    var onPreviewText: ((String) -> Void)?

    private let log = Logger.resonant("DictationLivePreview")

    private var streamingManager: SlidingWindowAsrManager?
    private var audioEngine: AVAudioEngine?
    private var updateConsumerTask: Task<Void, Never>?
    /// Bumped on every begin/end so a slow async setup can't install a tap for
    /// a session that already ended.
    private var sessionGeneration: UInt64 = 0
    private var isSettingUp = false

    /// Whether preview should run for this capture. Requires the loaded local
    /// Parakeet model (the streaming manager reuses its cached files — never
    /// trigger a load/download from the recording path).
    static func isEligible(
        settings: SettingsManager,
        modelRegistry: ModelRegistry
    ) -> Bool {
        guard settings.liveTranscriptPreviewEnabled else { return false }
        guard let active = modelRegistry.active as? FluidAudioAdapter, active.isLoaded else {
            return false
        }
        return true
    }

    /// Starts a preview session for the recording that just began. Runs its
    /// heavy setup asynchronously; call-and-forget from the start path.
    func begin(inputDeviceUID: String?) {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        guard !isSettingUp else { return }
        isSettingUp = true

        Task { @MainActor [weak self] in
            defer { self?.isSettingUp = false }
            guard let self, self.sessionGeneration == generation else { return }
            do {
                try await self.setUpSession(generation: generation, inputDeviceUID: inputDeviceUID)
            } catch {
                self.log.info("Live preview unavailable: \(error.localizedDescription, privacy: .public)")
                self.tearDownPipeline()
            }
        }
    }

    /// Ends the session and clears the preview text.
    func end() {
        sessionGeneration &+= 1
        tearDownPipeline()
        onPreviewText?("")
        // The streaming manager stays loaded across dictations so the next
        // begin() is cheap; reset just clears its transcript state.
        if let manager = streamingManager {
            Task { try? await manager.reset() }
        }
    }

    private func setUpSession(generation: UInt64, inputDeviceUID: String?) async throws {
        let manager: SlidingWindowAsrManager
        if let existing = streamingManager {
            // Mirror HotMicManager's pause/resume contract: `startStreaming`
            // runs once per manager lifetime; a reused manager only needs its
            // transcript state cleared.
            manager = existing
            try await manager.reset()
        } else {
            // Same cached files as the batch adapter — mmapped weights, no
            // download, no duplicate compile.
            let models = try await Task.detached(priority: .utility) {
                try await AsrModels.loadFromCache(version: .v3)
            }.value
            guard sessionGeneration == generation else { return }
            let created = SlidingWindowAsrManager(config: .streaming)
            try await created.loadModels(models)
            guard sessionGeneration == generation else {
                await created.cancel()
                return
            }
            try await created.startStreaming(source: .microphone)
            guard sessionGeneration == generation else {
                await created.cancel()
                return
            }
            streamingManager = created
            manager = created
        }

        let engine = try await Task.detached(priority: .utility) {
            let engine = AVAudioEngine()
            if let uid = inputDeviceUID {
                HotMicManager.setInputDevice(uid: uid, on: engine)
            }
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak manager] buffer, _ in
                guard let manager else { return }
                Task { await manager.streamAudio(buffer) }
            }
            try engine.start()
            return engine
        }.value
        guard sessionGeneration == generation else {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? await manager.reset()
            return
        }
        audioEngine = engine
        startConsumingUpdates(from: manager, generation: generation)
    }

    private func startConsumingUpdates(from manager: SlidingWindowAsrManager, generation: UInt64) {
        updateConsumerTask?.cancel()
        updateConsumerTask = Task { [weak self] in
            let updates = await manager.transcriptionUpdates
            for await _ in updates {
                guard !Task.isCancelled else { break }
                guard let self, self.sessionGeneration == generation else { break }
                let confirmed = await manager.confirmedTranscript
                let volatile = await manager.volatileTranscript
                guard self.sessionGeneration == generation else { break }
                let display = [confirmed, volatile]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                self.onPreviewText?(display)
            }
        }
    }

    private func tearDownPipeline() {
        updateConsumerTask?.cancel()
        updateConsumerTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    /// Fully releases the streaming model (e.g. when the preview setting turns
    /// off) so the memory is reclaimed.
    func unload() async {
        sessionGeneration &+= 1
        tearDownPipeline()
        if let manager = streamingManager {
            await manager.cancel()
        }
        streamingManager = nil
    }
}
