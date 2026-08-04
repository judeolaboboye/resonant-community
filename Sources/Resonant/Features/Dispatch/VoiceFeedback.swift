import AppKit
import AVFoundation
import FluidAudio
import Foundation
import os

/// Local text-to-speech feedback using Kokoro ANE TTS.
@MainActor
final class VoiceFeedback {

    private static let log = Logger.resonant("VoiceFeedback")

    private var ttsManager: KokoroAneManager?
    private var audioPlayer: AVAudioPlayer?
    private var onSpeechFinished: (() -> Void)?
    private var currentSynthesisTask: Task<Void, Never>?
    private(set) var isSpeaking = false

    private let voiceName = "af_heart"
    var volume: Float = 0.8
    var enabled = true

    /// Initialize the Kokoro TTS engine. Call once during app setup.
    func initialize() async {
        do {
            let manager = KokoroAneManager(defaultVoice: voiceName)
            try await manager.initialize(preloadVoices: Set([voiceName]))
            ttsManager = manager
            Self.log.info("Kokoro TTS initialized")
        } catch {
            Self.log.error("Kokoro TTS init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Speak the given text. Calls `onFinished` when playback completes.
    func speak(_ text: String, onFinished: (() -> Void)? = nil) {
        guard enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onFinished?()
            return
        }

        // Cancel any in-flight synthesis/playback before starting new speech.
        // Clear the old callback first so the cancellation cleanup doesn't
        // fire the NEW callback (the race Devin Review caught).
        let previousCallback = onSpeechFinished
        onSpeechFinished = nil
        stopInternal(fireCallback: false)
        previousCallback?()

        onSpeechFinished = onFinished
        isSpeaking = true

        currentSynthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let manager = self.ttsManager else {
                    Self.log.warning("Kokoro TTS not initialized, skipping speech")
                    self.finishSpeaking(completedPlayback: false)
                    return
                }

                let audioData = try await manager.synthesize(text: text, voice: self.voiceName)
                guard !Task.isCancelled else {
                    self.finishSpeaking(completedPlayback: false)
                    return
                }

                let player = try AVAudioPlayer(data: audioData)
                player.volume = self.volume
                self.audioPlayer = player
                guard player.play() else {
                    self.finishSpeaking(completedPlayback: false)
                    return
                }

                // Poll until playback finishes (AVAudioPlayer has no async API).
                while player.isPlaying && !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                }

                self.finishSpeaking(completedPlayback: !Task.isCancelled)
            } catch {
                if !Task.isCancelled {
                    Self.log.error("TTS synthesis failed: \(error.localizedDescription, privacy: .public)")
                }
                self.finishSpeaking(completedPlayback: false)
            }
        }
    }

    func stop() {
        stopInternal(fireCallback: true)
    }

    private func stopInternal(fireCallback: Bool) {
        currentSynthesisTask?.cancel()
        currentSynthesisTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
        if fireCallback {
            let callback = onSpeechFinished
            onSpeechFinished = nil
            callback?()
        }
    }

    private func finishSpeaking(completedPlayback: Bool) {
        isSpeaking = false
        audioPlayer = nil
        currentSynthesisTask = nil
        let callback = onSpeechFinished
        onSpeechFinished = nil
        if completedPlayback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        callback?()
    }
}
