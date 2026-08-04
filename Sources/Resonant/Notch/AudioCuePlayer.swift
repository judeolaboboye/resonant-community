import AVFoundation
import Foundation
import ObjCExceptionCatcher

/// Synthesized audio cues — no audio files needed.
final class AudioCuePlayer {

    static let shared: AudioCuePlayer = {
        let player = AudioCuePlayer()
        // Pre-warm the engine so the first play() doesn't race the IO cycle.
        playbackQueue.async { _ = player.ensureCueEngine() }
        return player
    }()

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var cueFormat: AVAudioFormat?
    /// Set when the engine was just (re)started — cleared after one IO cycle settles.
    private var engineColdStart = false

    var volume: Float = 0.6
    var enabled = true

    // MARK: - Public cues

    func playStart() {
        enqueueCue { $0.makeClick(frequency: 420, durationMs: 58, decay: 0.55) }
    }

    func playStop() {
        enqueueCue { $0.makeClick(frequency: 320, durationMs: 64, decay: 0.65) }
    }

    func playLock() {
        enqueueCue { $0.makeChord(frequencies: [523, 659, 784], durationMs: 110) }
    }

    func playSuccess() {
        enqueueCue { $0.makeChord(frequencies: [440, 554, 659], durationMs: 160) }
    }

    func playWarning() {
        enqueueCue { $0.makeChord(frequencies: [440, 523], durationMs: 120) }
    }

    func playError() {
        enqueueCue { $0.makeClick(frequency: 180, durationMs: 80, decay: 0.4) }
    }

    func playAgentStart() {
        enqueueCue {
            $0.makeAgentGesture(
                frequencies: [294, 587, 1175],
                durationMs: 150,
                rises: true,
                shimmer: 0.9
            )
        }
    }

    func playAgentSuccess() {
        enqueueCue {
            $0.makeAgentGesture(
                frequencies: [440, 660, 880, 1320],
                durationMs: 190,
                rises: true,
                shimmer: 1.0
            )
        }
    }

    func playAgentFailure() {
        enqueueCue {
            $0.makeAgentGesture(
                frequencies: [392, 294, 196],
                durationMs: 170,
                rises: false,
                shimmer: 0.38
            )
        }
    }

    // MARK: - Buffer synthesis

    private func makeClick(frequency: Double, durationMs: Int, decay: Double) -> AVAudioPCMBuffer? {
        guard let format = ensureCueFormat() else { return nil }

        let frameCount = AVAudioFrameCount(format.sampleRate * Double(durationMs) / 1000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let data = buffer.floatChannelData?[0]
        else {
            return nil
        }

        buffer.frameLength = frameCount

        for i in 0..<Int(frameCount) {
            let t = Double(i) / format.sampleRate
            let duration = Double(durationMs) / 1000
            let x = min(1, max(0, t / max(duration, 0.001)))
            let attack = 1 - exp(-x * 42)
            let release = pow(max(0, 1 - x), 1.6)
            let envelope = attack * release * exp(-t * decay * 8)
            let osc = sin(2 * .pi * frequency * t)
            data[i] = Float(osc * envelope * 0.72) * volume
        }

        return buffer
    }

    private func makeChord(frequencies: [Double], durationMs: Int) -> AVAudioPCMBuffer? {
        guard let format = ensureCueFormat() else { return nil }

        let frameCount = AVAudioFrameCount(format.sampleRate * Double(durationMs) / 1000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let data = buffer.floatChannelData?[0]
        else {
            return nil
        }

        buffer.frameLength = frameCount

        for i in 0..<Int(frameCount) {
            let t = Double(i) / format.sampleRate
            let envelope = exp(-t * 12) * (1 - exp(-t * 80))
            var sample: Double = 0
            for (idx, freq) in frequencies.enumerated() {
                let stagger = Double(idx) * 0.02
                let localT = max(0, t - stagger)
                sample += sin(2 * .pi * freq * localT)
            }
            data[i] = Float(sample / Double(frequencies.count) * envelope) * volume
        }

        return buffer
    }

    private func makeAgentGesture(
        frequencies: [Double],
        durationMs: Int,
        rises: Bool,
        shimmer: Double
    ) -> AVAudioPCMBuffer? {
        guard let format = ensureCueFormat() else { return nil }

        let frameCount = AVAudioFrameCount(format.sampleRate * Double(durationMs) / 1000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let data = buffer.floatChannelData?[0]
        else {
            return nil
        }

        buffer.frameLength = frameCount

        let duration = Double(durationMs) / 1000
        for i in 0..<Int(frameCount) {
            let t = Double(i) / format.sampleRate
            let x = min(1, max(0, t / max(duration, 0.001)))
            let attack = 1 - exp(-x * 18)
            let release = pow(max(0, 1 - x), 1.35)
            let envelope = attack * release
            let sweep = rises ? (0.96 + x * 0.12) : (1.07 - x * 0.18)
            var sample: Double = 0

            for (idx, frequency) in frequencies.enumerated() {
                let phaseDrift = sin(2 * .pi * (4.0 + Double(idx) * 1.7) * t) * 0.35 * shimmer
                let partial = sin(2 * .pi * frequency * sweep * t + phaseDrift)
                let delayedX = max(0, x - Double(idx) * 0.04)
                let partialEnvelope = min(1, delayedX * 12)
                sample += partial * partialEnvelope
            }

            sample /= max(1, Double(frequencies.count))

            let glassFrequency = rises
                ? 1_480 + 420 * x
                : 1_280 - 380 * x
            let glass = sin(2 * .pi * glassFrequency * t) * exp(-x * 5.4) * 0.18 * shimmer
            let softNoise = sin(2 * .pi * 73 * t) * sin(2 * .pi * 131 * t) * 0.018 * shimmer
            let mixed = (sample * 0.72 + glass + softNoise) * envelope

            data[i] = Float(max(-0.95, min(0.95, mixed))) * volume
        }

        return buffer
    }

    // MARK: - Playback

    private static let playbackQueue = DispatchQueue(label: "com.resonance.audiocue", qos: .userInitiated)

    private func enqueueCue(_ makeBuffer: @escaping (AudioCuePlayer) -> AVAudioPCMBuffer?) {
        guard enabled else { return }
        Self.playbackQueue.async { [self] in
            guard enabled, let buffer = makeBuffer(self) else { return }
            guard ensureCueEngine(),
                  let playerNode,
                  let engine,
                  engine.isRunning
            else {
                return
            }

            // Engine was just (re)started — IO cycle may not be ready yet.
            // Skip this play to avoid an uncatchable NSException crash.
            // The engine will be ready for the next cue.
            if engineColdStart {
                engineColdStart = false
                return
            }

            if playerNode.isPlaying {
                playerNode.stop()
            }

            playerNode.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)

            // AVAudioPlayerNode.play() can throw an uncatchable NSException
            // if the engine's IO graph changes mid-call (e.g. mic engine starting).
            // Wrap in ObjC @try/@catch to prevent a crash.
            let exception = ObjCTryCatch {
                playerNode.play()
            }
            if let exception {
                print("[AudioCuePlayer] Caught exception during play: \(exception.name.rawValue) — \(exception.reason ?? "unknown")")
                // Tear down so the next cue rebuilds cleanly.
                self.tearDownEngine()
            }
        }
    }

    private func tearDownEngine() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        cueFormat = nil
    }

    private func ensureCueFormat() -> AVAudioFormat? {
        if cueFormat == nil {
            _ = ensureCueEngine()
        }
        return cueFormat
    }

    private func ensureCueEngine() -> Bool {
        if engine == nil || playerNode == nil || cueFormat == nil {
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            let outputFormat = engine.outputNode.outputFormat(forBus: 0)
            let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 44_100

            guard let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                return false
            }

            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: monoFormat)
            engine.prepare()

            self.engine = engine
            self.playerNode = playerNode
            cueFormat = monoFormat
        }

        guard let engine else {
            return false
        }

        if !engine.isRunning {
            do {
                try engine.start()
                engineColdStart = true
            } catch {
                print("[AudioCuePlayer] Failed to start cue engine: \(error.localizedDescription)")
                return false
            }
        }

        return true
    }
}
