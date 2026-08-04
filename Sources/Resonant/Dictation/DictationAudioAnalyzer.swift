@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import os

enum DictationAudioAnalyzer {
    static let sampleRate = 16_000
    // Keep the pre-ASR gate conservative: adaptive segmentation can miss clips
    // that are mostly continuous speech, so only reject captures that are too
    // short to contain useful speech or sit at low background-noise levels.
    private static let preTranscriptionNoSpeechPeakRMS: Float = 0.002
    private static let minimumPotentialSpeechDuration: TimeInterval = 0.12
    /// Absolute sample magnitude treated as saturated. Decoders can round true
    /// full-scale clips to just under 1.0, so this sits slightly below 1.0.
    static let clippingSampleThreshold: Float = 0.98
    private static let defaultSegmenter = DictationVADSegmenter()
    private static let vadSegmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.45,
        minSilenceDuration: 0.7,
        maxSpeechDuration: 14.0,
        speechPadding: 0.12,
        silenceThresholdForSplit: 0.3,
        negativeThreshold: nil,
        negativeThresholdOffset: 0.15,
        minSilenceAtMaxSpeech: 0.12,
        useMaxPossibleSilenceAtMaxSpeech: true
    )

    struct SpeechSegment: Equatable, Sendable {
        let startSample: Int
        let endSample: Int

        var durationSamples: Int {
            max(0, endSample - startSample)
        }

        var startTime: TimeInterval {
            Double(startSample) / Double(DictationAudioAnalyzer.sampleRate)
        }

        var endTime: TimeInterval {
            Double(endSample) / Double(DictationAudioAnalyzer.sampleRate)
        }

        var durationSeconds: TimeInterval {
            Double(durationSamples) / Double(DictationAudioAnalyzer.sampleRate)
        }
    }

    struct DetectionConfig: Sendable {
        var frameSize = 320
        var hopSize = 160
        var thresholdMultiplier: Float = 3.0
        var noiseFloorPercentile: Double = 0.2
        var minimumEnergyThreshold: Float = 0.0009
        var minimumSpeechDuration: TimeInterval = 0.45
        var minimumSplitSilence: TimeInterval = 0.7
        var leadingPadding: TimeInterval = 0.12
        var trailingPadding: TimeInterval = 0.18

        static let `default` = DetectionConfig()

        static var preTranscriptionGate: DetectionConfig {
            var config = DetectionConfig()
            config.minimumSpeechDuration = 0.18
            config.minimumSplitSilence = 0.25
            config.leadingPadding = 0
            config.trailingPadding = 0
            return config
        }
    }

    struct Analysis: Sendable {
        let samples: [Float]
        let speechSegments: [SpeechSegment]
        let segmentationSource: SegmentationSource

        var voicedDuration: TimeInterval {
            speechSegments.reduce(0) { $0 + $1.durationSeconds }
        }
    }

    struct SegmentationResult: Sendable {
        let speechSegments: [SpeechSegment]
        let source: SegmentationSource
    }

    enum SegmentationSource: String, Sendable {
        case sileroVAD = "silero_vad"
        case energyFallback = "energy_fallback"
    }

    struct Diagnostics: Sendable, Equatable {
        let audioDurationSeconds: TimeInterval
        let peakRMS: Float
        /// Largest absolute sample value (not a windowed RMS). Unlike `peakRMS`,
        /// this exposes per-sample saturation that 20 ms RMS averaging hides.
        let truePeak: Float
        /// Fraction of samples sitting at/above `clippingSampleThreshold` — the
        /// signature of an over-driven mic clipping on loud speech.
        let clipRatio: Float
        let meanRMS: Float
        let noiseFloorRMS: Float
        let thresholdRMS: Float
        let frameCount: Int
        let speechSegmentCount: Int
        let voicedDurationSeconds: TimeInterval
        let segmenterSource: SegmentationSource

        /// A capture is treated as clipping when a meaningful fraction of samples
        /// saturate, the true peak is pinned to full scale, or the loudest frame is
        /// very hot. Used to give a shouting user the *correct* guidance (back off /
        /// lower input) instead of telling them to speak closer.
        static let clippingRatioThreshold: Float = 0.01

        /// Noise floor above which the background is treated as genuinely loud
        /// (a running AC/fan, not a quiet room). Below this we never blame noise.
        static let elevatedNoiseFloorDb: Float = -45
        /// Peak-to-floor gap below which speech is considered buried in the noise.
        /// A clean dictation sits 30+ dB above its floor; a constant loud background
        /// collapses this even while the user speaks normally.
        static let lowSignalToNoiseDb: Float = 15

        static func toDecibels(_ rms: Float) -> Float {
            guard rms.isFinite, rms > 0 else { return -120 }
            let decibels = 20 * log10f(rms)
            guard decibels.isFinite else { return -120 }
            return decibels
        }

        var peakDb: Float { Self.toDecibels(peakRMS) }
        var truePeakDb: Float { Self.toDecibels(truePeak) }
        var meanDb: Float { Self.toDecibels(meanRMS) }
        var noiseFloorDb: Float { Self.toDecibels(noiseFloorRMS) }
        var thresholdDb: Float { Self.toDecibels(thresholdRMS) }

        var indicatesClipping: Bool {
            clipRatio >= Self.clippingRatioThreshold
                || truePeakDb > -1
                || (peakDb.isFinite && peakDb > -10)
        }

        /// Peak-to-noise-floor gap in dB. The headroom speech has above the constant
        /// background; small values mean the voice barely rises out of the noise.
        var signalToNoiseDb: Float {
            let snr = peakDb - noiseFloorDb
            return snr.isFinite ? snr : 0
        }

        /// True when the background noise floor is genuinely loud *and* speech fails
        /// to rise clearly above it — the "loud AC drowning out the voice" case,
        /// distinct from clipping (too loud) and a dead mic (too quiet). Lets the
        /// failure copy point at the environment instead of a generic "no speech".
        var indicatesHighBackgroundNoise: Bool {
            noiseFloorDb.isFinite
                && noiseFloorDb > Self.elevatedNoiseFloorDb
                && signalToNoiseDb < Self.lowSignalToNoiseDb
        }

        /// Message-layer bar for pointing the user at the environment. Looser
        /// than `indicatesHighBackgroundNoise` — which stays strict so the
        /// analytics flag keeps its meaning — because only ~9% of failures
        /// with an elevated floor cleared the strict SNR bar, leaving the rest
        /// with generic "no speech" copy in exactly the room where "move away
        /// from the noise" is the advice that helps.
        static let guidanceSignalToNoiseDb: Float = 20
        static let dominantNoiseFloorDb: Float = -40

        var warrantsBackgroundNoiseGuidance: Bool {
            guard noiseFloorDb.isFinite else { return false }
            if noiseFloorDb >= Self.dominantNoiseFloorDb { return true }
            return noiseFloorDb > Self.elevatedNoiseFloorDb
                && signalToNoiseDb < Self.guidanceSignalToNoiseDb
        }
    }

    static func analyze(
        audioURL: URL,
        segmenter: any DictationSpeechSegmenting = defaultSegmenter,
        fallbackConfig: DetectionConfig = .default
    ) async throws -> Analysis {
        let samples = try loadMono16kSamples(from: audioURL)
        return try await analyze(
            audioSamples: samples,
            segmenter: segmenter,
            fallbackConfig: fallbackConfig
        )
    }

    /// Analyze canonical 16 kHz PCM without adding recognition padding or
    /// attenuating its level. Non-finite values are replaced with silence so
    /// energy/VAD math stays finite while sample offsets remain unchanged.
    static func analyze(
        audioSamples: [Float],
        segmenter: any DictationSpeechSegmenting = defaultSegmenter,
        fallbackConfig: DetectionConfig = .default
    ) async throws -> Analysis {
        let samples = sanitizedAnalysisSamples(audioSamples)
        guard !samples.isEmpty else {
            throw TranscriberError.transcriptionFailed("Audio too short")
        }
        let segmentation = try await segmentSanitizedSpeechSamples(
            in: samples,
            segmenter: segmenter,
            fallbackConfig: fallbackConfig
        )
        return Analysis(
            samples: samples,
            speechSegments: segmentation.speechSegments,
            segmentationSource: segmentation.source
        )
    }

    static func segmentSpeechSamples(
        in samples: [Float],
        segmenter: any DictationSpeechSegmenting = defaultSegmenter,
        fallbackConfig: DetectionConfig = .default
    ) async throws -> SegmentationResult {
        let analysisSamples = sanitizedAnalysisSamples(samples)
        return try await segmentSanitizedSpeechSamples(
            in: analysisSamples,
            segmenter: segmenter,
            fallbackConfig: fallbackConfig
        )
    }

    private static func segmentSanitizedSpeechSamples(
        in analysisSamples: [Float],
        segmenter: any DictationSpeechSegmenting,
        fallbackConfig: DetectionConfig
    ) async throws -> SegmentationResult {
        try Task.checkCancellation()
        do {
            let vadSegments = try await segmenter.segment(
                samples: analysisSamples,
                config: vadSegmentationConfig
            )
            try Task.checkCancellation()
            let mappedSegments = speechSegments(
                from: vadSegments,
                sampleCount: analysisSamples.count
            )
            if !mappedSegments.isEmpty {
                return SegmentationResult(speechSegments: mappedSegments, source: .sileroVAD)
            }
        } catch let cancellationError as CancellationError {
            throw cancellationError
        } catch {
            Logger.resonant("DictationVADSegmenter").warning(
                "VAD segmentation failed; using energy fallback: \(error.localizedDescription, privacy: .public)"
            )
        }

        try Task.checkCancellation()
        let fallbackSegments = detectSpeechSegments(in: analysisSamples, config: fallbackConfig)
        return SegmentationResult(speechSegments: fallbackSegments, source: .energyFallback)
    }

    /// Computes silence/VAD diagnostics for the captured clip. Used to surface
    /// *which gate* rejected speech when transcription comes back empty —
    /// peakRMS tells you whether the mic was hot, threshold/noiseFloor tells
    /// you what the energy gate required, segmentCount tells you whether VAD
    /// found anything.
    static func diagnose(
        audioURL: URL,
        segmenter: any DictationSpeechSegmenting = defaultSegmenter,
        fallbackConfig: DetectionConfig = .default
    ) async -> Diagnostics? {
        guard let samples = try? loadMono16kSamples(from: audioURL), !samples.isEmpty else {
            return nil
        }
        return await diagnose(
            audioSamples: samples,
            segmenter: segmenter,
            fallbackConfig: fallbackConfig
        )
    }

    static func diagnose(
        audioSamples: [Float],
        segmenter: any DictationSpeechSegmenting = defaultSegmenter,
        fallbackConfig: DetectionConfig = .default
    ) async -> Diagnostics? {
        let samples = sanitizedAnalysisSamples(audioSamples)
        guard !samples.isEmpty else { return nil }
        let segmentation: SegmentationResult
        do {
            segmentation = try await segmentSanitizedSpeechSamples(
                in: samples,
                segmenter: segmenter,
                fallbackConfig: fallbackConfig
            )
        } catch {
            return nil
        }
        return diagnostics(
            for: samples,
            segmentation: segmentation,
            fallbackConfig: fallbackConfig
        )
    }

    static func preTranscriptionGateDiagnostics(audioURL: URL) throws -> Diagnostics {
        let samples = try loadMono16kSamples(from: audioURL)
        return try preTranscriptionGateDiagnostics(audioSamples: samples)
    }

    static func preTranscriptionGateDiagnostics(audioSamples: [Float]) throws -> Diagnostics {
        let samples = sanitizedAnalysisSamples(audioSamples)
        let config = DetectionConfig.preTranscriptionGate
        let segmentation = SegmentationResult(
            speechSegments: detectSpeechSegments(in: samples, config: config),
            source: .energyFallback
        )
        guard let diagnostics = diagnostics(
            for: samples,
            segmentation: segmentation,
            fallbackConfig: config
        ) else {
            throw TranscriberError.transcriptionFailed("Audio too short")
        }
        return diagnostics
    }

    static func shouldRejectBeforeTranscription(_ diagnostics: Diagnostics) -> Bool {
        guard diagnostics.speechSegmentCount == 0 else { return false }

        if diagnostics.audioDurationSeconds < minimumPotentialSpeechDuration {
            return true
        }

        return diagnostics.audioDurationSeconds >= DetectionConfig.preTranscriptionGate.minimumSpeechDuration
            && diagnostics.peakRMS < preTranscriptionNoSpeechPeakRMS
    }

    static func diagnostics(
        for samples: [Float],
        segmentation: SegmentationResult,
        fallbackConfig: DetectionConfig = .default
    ) -> Diagnostics? {
        guard !samples.isEmpty else { return nil }
        let frames = rmsFrames(samples, frameSize: fallbackConfig.frameSize, hopSize: fallbackConfig.hopSize)
        let peak = frames.max() ?? 0
        var truePeak: Float = 0
        var clippedSampleCount = 0
        var finiteSampleCount = 0
        for sample in samples {
            guard sample.isFinite else { continue }
            let magnitude = abs(sample)
            finiteSampleCount += 1
            if magnitude > truePeak { truePeak = magnitude }
            if magnitude >= clippingSampleThreshold { clippedSampleCount += 1 }
        }
        let clipRatio = finiteSampleCount > 0
            ? Float(clippedSampleCount) / Float(finiteSampleCount)
            : 0
        let mean = frames.isEmpty ? 0 : frames.reduce(0, +) / Float(frames.count)
        let threshold = frames.isEmpty
            ? fallbackConfig.minimumEnergyThreshold
            : speechThreshold(for: frames, config: fallbackConfig)
        let noiseFloor: Float
        if frames.isEmpty {
            noiseFloor = 0
        } else {
            let sorted = frames.sorted()
            let index = min(
                sorted.count - 1,
                max(0, Int(Double(sorted.count - 1) * fallbackConfig.noiseFloorPercentile))
            )
            noiseFloor = sorted[index]
        }
        let voiced = segmentation.speechSegments.reduce(0) { $0 + $1.durationSeconds }
        return Diagnostics(
            audioDurationSeconds: Double(samples.count) / Double(sampleRate),
            peakRMS: peak,
            truePeak: truePeak,
            clipRatio: clipRatio,
            meanRMS: mean,
            noiseFloorRMS: noiseFloor,
            thresholdRMS: threshold,
            frameCount: frames.count,
            speechSegmentCount: segmentation.speechSegments.count,
            voicedDurationSeconds: voiced,
            segmenterSource: segmentation.source
        )
    }

    static func loadMono16kSamples(from audioURL: URL) throws -> [Float] {
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        guard !samples.isEmpty else {
            throw TranscriberError.transcriptionFailed("Audio too short")
        }
        return samples
    }

    static func sanitizedAnalysisSamples(_ samples: [Float]) -> [Float] {
        samples.map { $0.isFinite ? $0 : 0 }
    }

    static func detectSpeechSegments(
        in samples: [Float],
        config: DetectionConfig = .default
    ) -> [SpeechSegment] {
        guard !samples.isEmpty else { return [] }

        let frameEnergies = rmsFrames(samples, frameSize: config.frameSize, hopSize: config.hopSize)
        guard !frameEnergies.isEmpty else { return [] }

        let threshold = speechThreshold(for: frameEnergies, config: config)
        let minimumSpeechFrames = max(
            1,
            Int((config.minimumSpeechDuration * Double(sampleRate) / Double(config.hopSize)).rounded(.up))
        )
        let splitSilenceFrames = max(
            1,
            Int((config.minimumSplitSilence * Double(sampleRate) / Double(config.hopSize)).rounded(.up))
        )
        let leadingPaddingFrames = max(
            0,
            Int((config.leadingPadding * Double(sampleRate) / Double(config.hopSize)).rounded(.up))
        )
        let trailingPaddingFrames = max(
            0,
            Int((config.trailingPadding * Double(sampleRate) / Double(config.hopSize)).rounded(.up))
        )

        var segments: [SpeechSegment] = []
        var currentStartFrame: Int?
        var trailingSilenceFrames = 0

        func appendSegment(startFrame: Int, endFrame: Int) {
            guard endFrame - startFrame >= minimumSpeechFrames else { return }

            let startSample = max(0, startFrame * config.hopSize)
            let endSample = min(
                samples.count,
                max(startSample, endFrame * config.hopSize + config.frameSize)
            )

            guard endSample > startSample else { return }

            if let last = segments.last, startSample <= last.endSample {
                segments[segments.count - 1] = SpeechSegment(
                    startSample: last.startSample,
                    endSample: max(last.endSample, endSample)
                )
            } else {
                segments.append(SpeechSegment(startSample: startSample, endSample: endSample))
            }
        }

        for (index, energy) in frameEnergies.enumerated() {
            let isSpeech = energy >= threshold

            if isSpeech {
                if currentStartFrame == nil {
                    currentStartFrame = max(0, index - leadingPaddingFrames)
                }
                trailingSilenceFrames = 0
                continue
            }

            guard let startFrame = currentStartFrame else { continue }
            trailingSilenceFrames += 1

            if trailingSilenceFrames >= splitSilenceFrames {
                let endFrame = min(
                    frameEnergies.count,
                    index - trailingSilenceFrames + 1 + trailingPaddingFrames
                )
                appendSegment(startFrame: startFrame, endFrame: endFrame)
                currentStartFrame = nil
                trailingSilenceFrames = 0
            }
        }

        if let startFrame = currentStartFrame {
            appendSegment(
                startFrame: startFrame,
                endFrame: min(frameEnergies.count, frameEnergies.count + trailingPaddingFrames)
            )
        }

        return segments
    }

    static func slice(samples: [Float], for segment: SpeechSegment) -> [Float] {
        let start = max(0, min(segment.startSample, samples.count))
        let end = max(start, min(segment.endSample, samples.count))
        return Array(samples[start..<end])
    }

    static func speechSegments(from vadSegments: [VadSegment], sampleCount: Int) -> [SpeechSegment] {
        vadSegments.compactMap { segment in
            let startSample = max(0, min(segment.startSample(sampleRate: sampleRate), sampleCount))
            let endSample = max(startSample, min(segment.endSample(sampleRate: sampleRate), sampleCount))
            guard endSample > startSample else { return nil }
            return SpeechSegment(startSample: startSample, endSample: endSample)
        }
    }

    private static func rmsFrames(_ samples: [Float], frameSize: Int, hopSize: Int) -> [Float] {
        guard frameSize > 0, hopSize > 0 else { return [] }
        if samples.count <= frameSize {
            return [rms(samples)]
        }

        var values: [Float] = []
        values.reserveCapacity(((samples.count - frameSize) / hopSize) + 1)

        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frameSize)
            values.append(rms(Array(samples[start..<end])))
            if end == samples.count { break }
            start += hopSize
        }

        return values
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = Float.zero
        var finiteSampleCount = 0
        for sample in samples {
            guard sample.isFinite else { continue }
            let squared = sample * sample
            guard squared.isFinite else { continue }
            sum += squared
            finiteSampleCount += 1
        }
        guard finiteSampleCount > 0 else { return 0 }
        return sqrt(sum / Float(finiteSampleCount))
    }

    private static func speechThreshold(
        for frameEnergies: [Float],
        config: DetectionConfig
    ) -> Float {
        let sorted = frameEnergies.sorted()
        let percentileIndex = min(
            sorted.count - 1,
            max(0, Int(Double(sorted.count - 1) * config.noiseFloorPercentile))
        )
        let noiseFloor = sorted[percentileIndex]
        return max(config.minimumEnergyThreshold, noiseFloor * config.thresholdMultiplier)
    }
}

protocol DictationSpeechSegmenting: Sendable {
    func segment(samples: [Float], config: VadSegmentationConfig) async throws -> [VadSegment]
}

actor DictationVADSegmenter: DictationSpeechSegmenting {
    typealias ModelURLProvider = @Sendable () -> URL?
    typealias ModelLoader = @Sendable (URL) throws -> MLModel

    private let log = Logger.resonant("DictationVADSegmenter")
    private let modelURLProvider: ModelURLProvider
    private let modelLoader: ModelLoader
    private var manager: VadManager?
    private var loadingTask: Task<VadManager, Error>?
    private var loadingGeneration: UUID?

    init(
        modelURLProvider: @escaping ModelURLProvider = { DictationVADSegmenter.cachedModelURL() },
        modelLoader: @escaping ModelLoader = { try MLModel(contentsOf: $0) }
    ) {
        self.modelURLProvider = modelURLProvider
        self.modelLoader = modelLoader
    }

    func segment(samples: [Float], config: VadSegmentationConfig) async throws -> [VadSegment] {
        try Task.checkCancellation()
        let manager = try await resolveManager()
        let segments = try await manager.segmentSpeech(samples, config: config)
        try Task.checkCancellation()
        return segments
    }

    private func resolveManager() async throws -> VadManager {
        if let manager {
            return manager
        }

        if let loadingTask {
            let generation = loadingGeneration
            do {
                let manager = try await DictationAsyncDeadline.throwingValueUnlessCancelled {
                    try await loadingTask.value
                }
                settleLoadingTask(.success(manager), generation: generation)
                try Task.checkCancellation()
                return manager
            } catch let cancellationError as CancellationError where Task.isCancelled {
                // This waiter was cancelled, but the detached cache load is
                // shared. Leave it installed so another caller can settle it.
                throw cancellationError
            } catch {
                settleLoadingTask(.failure(error), generation: generation)
                throw error
            }
        }

        let modelURLProvider = self.modelURLProvider
        let modelLoader = self.modelLoader
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let modelURL = modelURLProvider() else {
                throw DictationVADSegmenterError.cachedModelUnavailable
            }
            let model = try modelLoader(modelURL)
            try Task.checkCancellation()
            return VadManager(config: .default, vadModel: model)
        }
        let generation = UUID()
        loadingTask = task
        loadingGeneration = generation
        Task { [weak self] in
            let result = await task.result
            await self?.settleLoadingTask(result, generation: generation)
        }

        do {
            let manager = try await DictationAsyncDeadline.throwingValueUnlessCancelled {
                try await task.value
            }
            settleLoadingTask(.success(manager), generation: generation)
            try Task.checkCancellation()
            return manager
        } catch let cancellationError as CancellationError where Task.isCancelled {
            // The detached cache load is shared and may already have completed;
            // cancellation belongs to this caller and must escape to the pipeline.
            throw cancellationError
        } catch {
            settleLoadingTask(.failure(error), generation: generation)
            throw error
        }
    }

    private func settleLoadingTask(
        _ result: Result<VadManager, Error>,
        generation: UUID?
    ) {
        guard loadingGeneration == generation else { return }
        loadingTask = nil
        loadingGeneration = nil
        switch result {
        case .success(let manager):
            self.manager = manager
        case .failure(let error):
            log.error("Failed to initialize Silero VAD: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolves only a complete, already-compiled FluidAudio cache bundle.
    /// Unlike `VadManager()` this path never invokes download utilities.
    nonisolated static func cachedModelURL(
        fileManager: FileManager = .default
    ) -> URL? {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let modelsDirectory = appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        return cachedModelURL(in: modelsDirectory, fileManager: fileManager)
    }

    nonisolated static func cachedModelURL(
        in modelsDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let modelURL = modelsDirectory
            .appendingPathComponent(Repo.vad.folderName, isDirectory: true)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: modelURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              isNonEmptyFile(modelURL.appendingPathComponent("coremldata.bin"), fileManager: fileManager),
              isNonEmptyFile(modelURL.appendingPathComponent("model.mil"), fileManager: fileManager),
              isNonEmptyFile(
                  modelURL.appendingPathComponent("weights/weight.bin"),
                  fileManager: fileManager
              )
        else {
            return nil
        }
        return modelURL
    }

    /// Downloads the VAD helper only from an explicit model-download action.
    nonisolated static func downloadModelCache() async throws {
        guard cachedModelURL() == nil,
              let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first else {
            return
        }
        let modelsDirectory = appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try await DownloadUtils.downloadRepo(.vad, to: modelsDirectory)
    }

    /// Builds a VAD manager from an already-complete cache. This deliberately
    /// avoids `VadManager()` because that convenience initializer downloads.
    nonisolated static func makeCachedManager() throws -> VadManager {
        guard let modelURL = cachedModelURL() else {
            throw DictationVADSegmenterError.cachedModelUnavailable
        }
        return VadManager(config: .default, vadModel: try MLModel(contentsOf: modelURL))
    }

    private nonisolated static func isNonEmptyFile(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.int64Value > 0
    }
}

enum DictationVADSegmenterError: LocalizedError {
    case cachedModelUnavailable

    var errorDescription: String? {
        switch self {
        case .cachedModelUnavailable:
            "Cached Silero VAD model is unavailable"
        }
    }
}

enum DictationSegmentRecovery {
    static let minimumClipDuration: TimeInterval = 5

    static func shouldAnalyzeAudio(clipDuration: TimeInterval) -> Bool {
        clipDuration >= minimumClipDuration
    }

    static func shouldAttemptSegmentRecovery(
        originalTranscript: String,
        clipDuration: TimeInterval,
        speechSegments: [DictationAudioAnalyzer.SpeechSegment]
    ) -> Bool {
        guard shouldAnalyzeAudio(clipDuration: clipDuration) else { return false }
        guard speechSegments.count >= 2 else { return false }

        let voicedDuration = speechSegments.reduce(0) { $0 + $1.durationSeconds }
        guard voicedDuration >= 2.2 else { return false }

        let wordCount = originalTranscript.wordCount
        if wordCount <= 2 { return true }

        let wordsPerSecond = Double(wordCount) / max(voicedDuration, 1)
        if wordsPerSecond < 0.9 || wordCount <= speechSegments.count + 2 {
            return true
        }

        let longPauseCount = zip(speechSegments, speechSegments.dropFirst())
            .map { max(0, $1.startTime - $0.endTime) }
            .filter { $0 >= 0.55 }
            .count

        return speechSegments.count >= 3 && longPauseCount >= 2 && wordCount <= speechSegments.count * 4
    }

    static func shouldPreferRecoveredTranscript(
        originalTranscript: String,
        recoveredTranscript: String
    ) -> Bool {
        let original = originalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let recovered = recoveredTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !recovered.isEmpty else { return false }
        guard recovered != original else { return false }
        guard recovered.wordCount > original.wordCount else { return false }

        if original.isEmpty {
            return true
        }

        if recovered.wordCount >= original.wordCount + 2 {
            return true
        }

        return recovered.nonWhitespaceCount >= original.nonWhitespaceCount + 10
    }

    static func combine(_ segments: [String]) -> String {
        segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var wordCount: Int {
        split { $0.isWhitespace || $0.isNewline }.count
    }

    var nonWhitespaceCount: Int {
        unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                count += 1
            }
        }
    }
}
