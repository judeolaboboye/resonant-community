import AVFoundation
import FluidAudio
import XCTest
@testable import Resonant

final class DictationAudioAnalyzerTests: XCTestCase {

    func testSegmentationUsesVADOutputWhenAvailable() async throws {
        let samples = Array(repeating: Float.zero, count: DictationAudioAnalyzer.sampleRate * 5)
        let segmenter = StubSegmenter(
            result: .success([
                VadSegment(startTime: 0.4, endTime: 2.1),
                VadSegment(startTime: 3.0, endTime: 4.2),
            ])
        )

        let result = try await DictationAudioAnalyzer.segmentSpeechSamples(
            in: samples,
            segmenter: segmenter
        )

        XCTAssertEqual(result.source, DictationAudioAnalyzer.SegmentationSource.sileroVAD)
        XCTAssertEqual(result.speechSegments.count, 2)
        XCTAssertEqual(result.speechSegments[0].startSample, 6_400)
        XCTAssertEqual(result.speechSegments[0].endSample, 33_600)
        XCTAssertEqual(result.speechSegments[1].startSample, 48_000)
        XCTAssertEqual(result.speechSegments[1].endSample, 67_200)
    }

    func testSegmentationFallsBackToEnergyDetectorWhenVADFails() async throws {
        let samples = makeSamples([
            .silence(0.35),
            .speech(1.8),
            .silence(1.0),
            .speech(1.25),
            .silence(0.3),
        ])

        let result = try await DictationAudioAnalyzer.segmentSpeechSamples(
            in: samples,
            segmenter: StubSegmenter(result: .failure(StubError.segmenterUnavailable))
        )
        let segments = result.speechSegments

        XCTAssertEqual(result.source, DictationAudioAnalyzer.SegmentationSource.energyFallback)
        XCTAssertEqual(segments.count, 2)
        XCTAssertLessThan(abs(segments[0].startTime - 0.24), 0.2)
        XCTAssertLessThan(abs(segments[0].endTime - 2.33), 0.25)
        XCTAssertLessThan(abs(segments[1].startTime - 3.03), 0.25)
        XCTAssertLessThan(abs(segments[1].endTime - 4.78), 0.25)
    }

    func testFallbackSegmentationKeepsBriefPauseInsideSingleUtterance() async throws {
        let samples = makeSamples([
            .silence(0.25),
            .speech(1.6),
            .silence(0.35),
            .speech(1.4),
            .silence(0.2),
        ])

        let result = try await DictationAudioAnalyzer.segmentSpeechSamples(
            in: samples,
            segmenter: StubSegmenter(result: .failure(StubError.segmenterUnavailable))
        )
        let segments = result.speechSegments

        XCTAssertEqual(result.source, DictationAudioAnalyzer.SegmentationSource.energyFallback)
        XCTAssertEqual(segments.count, 1)
        XCTAssertGreaterThan(segments[0].durationSeconds, 3.0)
    }

    func testPreTranscriptionGateRejectsSilence() {
        let samples = Array(repeating: Float.zero, count: DictationAudioAnalyzer.sampleRate)
        let config = DictationAudioAnalyzer.DetectionConfig.preTranscriptionGate
        let segments = DictationAudioAnalyzer.detectSpeechSegments(in: samples, config: config)
        let diagnostics = DictationAudioAnalyzer.diagnostics(
            for: samples,
            segmentation: DictationAudioAnalyzer.SegmentationResult(
                speechSegments: segments,
                source: .energyFallback
            ),
            fallbackConfig: config
        )

        XCTAssertEqual(diagnostics?.speechSegmentCount, 0)
        XCTAssertTrue(diagnostics.map(DictationAudioAnalyzer.shouldRejectBeforeTranscription) ?? false)
    }

    func testPreTranscriptionGateRejectsVeryShortCapture() {
        let samples = Array(repeating: Float.zero, count: Int(Double(DictationAudioAnalyzer.sampleRate) * 0.08))
        let config = DictationAudioAnalyzer.DetectionConfig.preTranscriptionGate
        let segments = DictationAudioAnalyzer.detectSpeechSegments(in: samples, config: config)
        let diagnostics = DictationAudioAnalyzer.diagnostics(
            for: samples,
            segmentation: DictationAudioAnalyzer.SegmentationResult(
                speechSegments: segments,
                source: .energyFallback
            ),
            fallbackConfig: config
        )

        XCTAssertEqual(diagnostics?.speechSegmentCount, 0)
        XCTAssertTrue(diagnostics.map(DictationAudioAnalyzer.shouldRejectBeforeTranscription) ?? false)
    }

    func testPreTranscriptionGateRejectsLowLevelBackgroundNoiseWithoutSpeech() {
        let samples = makeSamples([
            .noise(1.0),
        ])
        let config = DictationAudioAnalyzer.DetectionConfig.preTranscriptionGate
        let segments = DictationAudioAnalyzer.detectSpeechSegments(in: samples, config: config)
        let diagnostics = DictationAudioAnalyzer.diagnostics(
            for: samples,
            segmentation: DictationAudioAnalyzer.SegmentationResult(
                speechSegments: segments,
                source: .energyFallback
            ),
            fallbackConfig: config
        )

        XCTAssertEqual(diagnostics?.speechSegmentCount, 0)
        XCTAssertTrue(diagnostics.map(DictationAudioAnalyzer.shouldRejectBeforeTranscription) ?? false)
    }

    func testPreTranscriptionGateAllowsBriefSpeech() {
        let samples = makeSamples([
            .silence(0.3),
            .speech(0.24),
            .silence(0.5),
        ])
        let config = DictationAudioAnalyzer.DetectionConfig.preTranscriptionGate
        let segments = DictationAudioAnalyzer.detectSpeechSegments(in: samples, config: config)
        let diagnostics = DictationAudioAnalyzer.diagnostics(
            for: samples,
            segmentation: DictationAudioAnalyzer.SegmentationResult(
                speechSegments: segments,
                source: .energyFallback
            ),
            fallbackConfig: config
        )

        XCTAssertNotEqual(diagnostics?.speechSegmentCount, 0)
        XCTAssertFalse(diagnostics.map(DictationAudioAnalyzer.shouldRejectBeforeTranscription) ?? true)
    }

    func testPreTranscriptionGateAllowsAudibleContinuousSpeechWhenEnergySegmentationFails() {
        let samples = makeSamples([
            .speech(1.0),
        ])
        let config = DictationAudioAnalyzer.DetectionConfig.preTranscriptionGate
        let segments = DictationAudioAnalyzer.detectSpeechSegments(in: samples, config: config)
        let diagnostics = DictationAudioAnalyzer.diagnostics(
            for: samples,
            segmentation: DictationAudioAnalyzer.SegmentationResult(
                speechSegments: segments,
                source: .energyFallback
            ),
            fallbackConfig: config
        )

        XCTAssertEqual(diagnostics?.speechSegmentCount, 0)
        XCTAssertGreaterThan(diagnostics?.peakRMS ?? 0, 0.00025)
        XCTAssertFalse(diagnostics.map(DictationAudioAnalyzer.shouldRejectBeforeTranscription) ?? true)
    }

    func testDiagnosticsReportClipRatioAndTruePeakForSaturatedCapture() {
        // 5% of samples pinned at full scale, the rest a loud-but-clean tone. This is
        // the shouting-into-a-hot-mic signature: a moderate frame RMS hiding per-sample
        // saturation that 20ms RMS averaging smears away.
        let total = DictationAudioAnalyzer.sampleRate
        let clipped = total / 20
        var samples = [Float](repeating: 0, count: total)
        for index in 0..<total {
            if index < clipped {
                samples[index] = index.isMultiple(of: 2) ? 1.0 : -1.0
            } else {
                let time = Double(index) / Double(DictationAudioAnalyzer.sampleRate)
                samples[index] = Float(0.25 * sin(2 * Double.pi * 180 * time))
            }
        }

        let diagnostics = DictationAudioAnalyzer.diagnostics(
            for: samples,
            segmentation: DictationAudioAnalyzer.SegmentationResult(
                speechSegments: [],
                source: .energyFallback
            )
        )

        XCTAssertNotNil(diagnostics)
        XCTAssertEqual(diagnostics?.truePeak ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(diagnostics?.clipRatio ?? 0, 0.05, accuracy: 0.005)
        XCTAssertTrue(diagnostics?.indicatesClipping ?? false)
    }

    func testDiagnosticsReportNoClippingForCleanLoudTone() {
        let total = DictationAudioAnalyzer.sampleRate
        let samples: [Float] = (0..<total).map { index in
            let time = Double(index) / Double(DictationAudioAnalyzer.sampleRate)
            return Float(0.25 * sin(2 * Double.pi * 180 * time))
        }

        let diagnostics = DictationAudioAnalyzer.diagnostics(
            for: samples,
            segmentation: DictationAudioAnalyzer.SegmentationResult(
                speechSegments: [],
                source: .energyFallback
            )
        )

        XCTAssertEqual(diagnostics?.clipRatio ?? 1, 0, accuracy: 0.0001)
        XCTAssertLessThan(diagnostics?.truePeak ?? 1, 0.95)
        // peakDb for a 0.25 tone is ~-15 dB, below the -10 dB hot-frame trigger.
        XCTAssertFalse(diagnostics?.indicatesClipping ?? true)
    }

    func testIndicatesClippingBandsDriveTheCorrectMessage() {
        func diag(peakRMS: Float, truePeak: Float, clipRatio: Float) -> DictationAudioAnalyzer.Diagnostics {
            DictationAudioAnalyzer.Diagnostics(
                audioDurationSeconds: 2,
                peakRMS: peakRMS,
                truePeak: truePeak,
                clipRatio: clipRatio,
                meanRMS: peakRMS / 2,
                noiseFloorRMS: 0.0005,
                thresholdRMS: 0.0015,
                frameCount: 200,
                speechSegmentCount: 0,
                voicedDurationSeconds: 0,
                segmenterSource: .energyFallback
            )
        }

        // Quiet capture (peak ~-60 dB) and normal speech are not clipping.
        XCTAssertFalse(diag(peakRMS: 0.001, truePeak: 0.002, clipRatio: 0).indicatesClipping)
        XCTAssertFalse(diag(peakRMS: 0.05, truePeak: 0.1, clipRatio: 0).indicatesClipping)
        // Any one of the three signals trips it: saturated samples, full-scale true
        // peak, or a very hot loudest frame (>-10 dB).
        XCTAssertTrue(diag(peakRMS: 0.25, truePeak: 1.0, clipRatio: 0.03).indicatesClipping)
        XCTAssertTrue(diag(peakRMS: 0.2, truePeak: 0.99, clipRatio: 0).indicatesClipping)
        XCTAssertTrue(diag(peakRMS: 0.4, truePeak: 0.5, clipRatio: 0).indicatesClipping)
    }

    func testIndicatesHighBackgroundNoiseDistinguishesAcFromQuietRoom() {
        func diag(peakRMS: Float, noiseFloorRMS: Float) -> DictationAudioAnalyzer.Diagnostics {
            DictationAudioAnalyzer.Diagnostics(
                audioDurationSeconds: 2,
                peakRMS: peakRMS,
                truePeak: peakRMS,
                clipRatio: 0,
                meanRMS: peakRMS / 2,
                noiseFloorRMS: noiseFloorRMS,
                thresholdRMS: noiseFloorRMS * 3,
                frameCount: 200,
                speechSegmentCount: 0,
                voicedDurationSeconds: 0,
                segmenterSource: .energyFallback
            )
        }

        // Loud constant background (floor ~-34 dB) with the voice only ~8 dB above it:
        // the AC-drowning-out-speech case.
        XCTAssertTrue(diag(peakRMS: 0.05, noiseFloorRMS: 0.02).indicatesHighBackgroundNoise)
        // Quiet room (floor ~-66 dB) never blames noise, no matter the speech level.
        XCTAssertFalse(diag(peakRMS: 0.05, noiseFloorRMS: 0.0005).indicatesHighBackgroundNoise)
        XCTAssertFalse(diag(peakRMS: 0.3, noiseFloorRMS: 0.0005).indicatesHighBackgroundNoise)
        // High floor but the voice clears it comfortably (e.g. headset in a noisy
        // room): SNR is healthy, so this is not flagged as noise-buried.
        XCTAssertFalse(diag(peakRMS: 0.4, noiseFloorRMS: 0.02).indicatesHighBackgroundNoise)
    }

    func testDiagnosticsKeepNonFiniteSamplesOutOfDbValues() {
        let samples: [Float] = [
            .nan,
            .infinity,
            -.infinity,
            0.3,
            -0.3,
            0
        ]
        let diagnostics = DictationAudioAnalyzer.diagnostics(
            for: samples,
            segmentation: DictationAudioAnalyzer.SegmentationResult(
                speechSegments: [],
                source: .energyFallback
            )
        )

        XCTAssertNotNil(diagnostics)
        XCTAssertTrue(diagnostics?.peakDb.isFinite ?? false)
        XCTAssertTrue(diagnostics?.meanDb.isFinite ?? false)
        XCTAssertTrue(diagnostics?.noiseFloorDb.isFinite ?? false)
        XCTAssertTrue(diagnostics?.thresholdDb.isFinite ?? false)
        XCTAssertEqual(DictationAudioAnalyzer.Diagnostics.toDecibels(.infinity), -120)
        XCTAssertEqual(DictationAudioAnalyzer.Diagnostics.toDecibels(.nan), -120)
    }

    func testSegmentRecoveryTriggersForSuspiciouslyShortTranscript() {
        let segments = [
            DictationAudioAnalyzer.SpeechSegment(startSample: 2_000, endSample: 30_000),
            DictationAudioAnalyzer.SpeechSegment(startSample: 42_000, endSample: 64_000),
        ]

        XCTAssertTrue(
            DictationSegmentRecovery.shouldAttemptSegmentRecovery(
                originalTranscript: "By that is",
                clipDuration: 7.29,
                speechSegments: segments
            )
        )
    }

    func testSegmentRecoveryAnalysisSkipsBeforeFiveSecondBoundary() {
        XCTAssertFalse(DictationSegmentRecovery.shouldAnalyzeAudio(clipDuration: 4.999))
        XCTAssertTrue(DictationSegmentRecovery.shouldAnalyzeAudio(clipDuration: 5.0))
    }

    func testSegmentRecoverySkipsHealthyTranscript() {
        let segments = [
            DictationAudioAnalyzer.SpeechSegment(startSample: 1_000, endSample: 36_000),
            DictationAudioAnalyzer.SpeechSegment(startSample: 46_000, endSample: 70_000),
        ]

        XCTAssertFalse(
            DictationSegmentRecovery.shouldAttemptSegmentRecovery(
                originalTranscript: "Now you need to make this into a design, what I mean by that is.",
                clipDuration: 7.29,
                speechSegments: segments
            )
        )
    }

    func testSegmentRecoveryTriggersForLongMultiPauseTranscript() {
        let segments = [
            DictationAudioAnalyzer.SpeechSegment(startSample: 16_560, endSample: 41_616),
            DictationAudioAnalyzer.SpeechSegment(startSample: 59_328, endSample: 74_928),
            DictationAudioAnalyzer.SpeechSegment(startSample: 86_592, endSample: 98_064),
        ]

        XCTAssertTrue(
            DictationSegmentRecovery.shouldAttemptSegmentRecovery(
                originalTranscript: "By that is look at logs. Why did that happen?",
                clipDuration: 6.71,
                speechSegments: segments
            )
        )
    }

    func testRecoveredTranscriptMustBeMeaningfullyBetter() {
        XCTAssertTrue(
            DictationSegmentRecovery.shouldPreferRecoveredTranscript(
                originalTranscript: "By that is",
                recoveredTranscript: "Now you need to make this into a design what I mean by that is"
            )
        )

        XCTAssertFalse(
            DictationSegmentRecovery.shouldPreferRecoveredTranscript(
                originalTranscript: "By that is",
                recoveredTranscript: "By that is"
            )
        )
    }

    func testSampleAnalysisSanitizesWithoutPaddingOrAttenuation() async throws {
        let raw: [Float] = [0.25, .nan, .infinity, -0.5]
        let analysis = try await DictationAudioAnalyzer.analyze(
            audioSamples: raw,
            segmenter: StubSegmenter(result: .success([]))
        )

        XCTAssertEqual(analysis.samples, [0.25, 0, 0, -0.5])
        XCTAssertEqual(analysis.samples.count, raw.count)
        XCTAssertEqual(analysis.samples[3], -0.5, "Analysis must not apply ASR attenuation")
    }

    func testSegmentationPreservesCancellationInsteadOfFallingBack() async {
        do {
            _ = try await DictationAudioAnalyzer.segmentSpeechSamples(
                in: [Float](repeating: 0.1, count: DictationAudioAnalyzer.sampleRate),
                segmenter: CancellingSegmenter()
            )
            XCTFail("Expected cancellation to escape")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAbsentCachedVADFallsBackWithoutInvokingModelLoader() async throws {
        let loaderCalls = LockedCounter()
        let segmenter = DictationVADSegmenter(
            modelURLProvider: { nil },
            modelLoader: { _ in
                loaderCalls.increment()
                throw StubError.segmenterUnavailable
            }
        )
        let samples = makeSamples([.silence(0.2), .speech(0.8), .silence(0.2)])

        let result = try await DictationAudioAnalyzer.segmentSpeechSamples(
            in: samples,
            segmenter: segmenter
        )

        XCTAssertEqual(result.source, .energyFallback)
        XCTAssertEqual(loaderCalls.value, 0)
    }

    func testCachedVADResolverUsesFluidAudioRepositoryFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let modelURL = root
            .appendingPathComponent(Repo.vad.folderName, isDirectory: true)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
        for relativePath in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
            let fileURL = modelURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([1]).write(to: fileURL)
        }

        XCTAssertEqual(
            DictationVADSegmenter.cachedModelURL(in: root)?.standardizedFileURL,
            modelURL.standardizedFileURL
        )
    }

    func testCancelledInitialVADWaiterDoesNotPoisonFailedSharedLoad() async {
        let loaderCalls = LockedCounter()
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        let segmenter = DictationVADSegmenter(
            modelURLProvider: { URL(fileURLWithPath: "/tmp/test-vad.mlmodelc") },
            modelLoader: { _ in
                loaderCalls.increment()
                if loaderCalls.value == 1 {
                    releaseFirstLoad.wait()
                }
                throw StubError.segmenterUnavailable
            }
        )
        let samples = [Float](repeating: 0.1, count: 256)
        let first = Task {
            try await segmenter.segment(samples: samples, config: .default)
        }

        while loaderCalls.value == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected the first waiter to cancel")
        } catch is CancellationError {
            // The shared detached load is intentionally still running.
        } catch {
            XCTFail("Unexpected first-waiter error: \(error)")
        }

        releaseFirstLoad.signal()
        do {
            _ = try await segmenter.segment(samples: samples, config: .default)
            XCTFail("Expected the next load observation to fail")
        } catch StubError.segmenterUnavailable {
            // Depending on scheduling, this either observes the shared failure
            // or starts the first retry after independent settlement.
        } catch {
            XCTFail("Unexpected shared-load error: \(error)")
        }

        do {
            _ = try await segmenter.segment(samples: samples, config: .default)
            XCTFail("Expected the retry load to fail")
        } catch StubError.segmenterUnavailable {
            // A new attempt was made rather than reusing the poisoned task.
        } catch {
            XCTFail("Unexpected retry error: \(error)")
        }
        XCTAssertGreaterThanOrEqual(loaderCalls.value, 2)
    }

    func testAudioLoaderDrains44100HzTail() throws {
        try assertResampledTail(sourceSampleRate: 44_100, sourceSampleCount: 13_230)
    }

    func testAudioLoaderDrains48000HzTail() throws {
        try assertResampledTail(sourceSampleRate: 48_000, sourceSampleCount: 14_400)
    }

    private func assertResampledTail(
        sourceSampleRate: Double,
        sourceSampleCount: Int
    ) throws {
        let markerFrameCount = Int(sourceSampleRate * 0.02)
        let url = try makeAudioFile(
            sampleRate: sourceSampleRate,
            sampleCount: sourceSampleCount,
            trailingMarkerFrameCount: markerFrameCount
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try DictationAudioAnalyzer.loadMono16kSamples(from: url)
        let expectedCount = Int(
            (Double(sourceSampleCount) * Double(DictationAudioAnalyzer.sampleRate) / sourceSampleRate)
                .rounded()
        )
        let tail = samples.suffix(min(160, samples.count))

        XCTAssertLessThanOrEqual(abs(samples.count - expectedCount), 1)
        XCTAssertGreaterThan(tail.map { abs($0) }.max() ?? 0, 0.25)
    }

    private func makeAudioFile(
        sampleRate: Double,
        sampleCount: Int,
        trailingMarkerFrameCount: Int
    ) throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleCount)
        )!
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        let markerStart = max(0, sampleCount - trailingMarkerFrameCount)
        let channel = buffer.floatChannelData![0]
        for index in 0..<sampleCount {
            channel[index] = index >= markerStart ? 0.75 : 0
        }
        try file.write(from: buffer)
        return url
    }

    private func makeSamples(_ chunks: [Chunk]) -> [Float] {
        var allSamples: [Float] = []
        for chunk in chunks {
            let sampleCount = Int(chunk.duration * Double(DictationAudioAnalyzer.sampleRate))
            switch chunk.kind {
            case .silence:
                allSamples.append(contentsOf: Array(repeating: 0, count: sampleCount))
            case .speech:
                let speechSamples: [Float] = (0..<sampleCount).map { index in
                    let time = Double(index) / Double(DictationAudioAnalyzer.sampleRate)
                    let carrier = sin(2 * Double.pi * 180 * time)
                    let wobble = sin(2 * Double.pi * 3 * time)
                    return Float(0.018 * carrier * (0.65 + (0.35 * wobble)))
                }
                allSamples.append(contentsOf: speechSamples)
            case .noise:
                let noiseSamples: [Float] = (0..<sampleCount).map { index in
                    let time = Double(index) / Double(DictationAudioAnalyzer.sampleRate)
                    return Float(0.0015 * sin(2 * Double.pi * 73 * time))
                }
                allSamples.append(contentsOf: noiseSamples)
            }
        }
        return allSamples
    }
}

private extension DictationAudioAnalyzerTests {
    actor StubSegmenter: DictationSpeechSegmenting {
        let result: Result<[VadSegment], Error>

        init(result: Result<[VadSegment], Error>) {
            self.result = result
        }

        func segment(samples: [Float], config: VadSegmentationConfig) async throws -> [VadSegment] {
            try result.get()
        }
    }

    actor CancellingSegmenter: DictationSpeechSegmenting {
        func segment(samples: [Float], config: VadSegmentationConfig) async throws -> [VadSegment] {
            throw CancellationError()
        }
    }

    final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.withLock { storage }
        }

        func increment() {
            lock.withLock { storage += 1 }
        }
    }

    enum StubError: Error {
        case segmenterUnavailable
    }

    struct Chunk {
        enum Kind {
            case silence
            case speech
            case noise
        }

        let kind: Kind
        let duration: TimeInterval

        static func silence(_ duration: TimeInterval) -> Chunk {
            Chunk(kind: .silence, duration: duration)
        }

        static func speech(_ duration: TimeInterval) -> Chunk {
            Chunk(kind: .speech, duration: duration)
        }

        static func noise(_ duration: TimeInterval) -> Chunk {
            Chunk(kind: .noise, duration: duration)
        }
    }
}

// MARK: - Background-noise guidance bar

extension DictationAudioAnalyzerTests {

    private func noiseDiagnostics(
        peakRMS: Float,
        noiseFloorRMS: Float
    ) -> DictationAudioAnalyzer.Diagnostics {
        DictationAudioAnalyzer.Diagnostics(
            audioDurationSeconds: 2,
            peakRMS: peakRMS,
            truePeak: peakRMS * 1.5,
            clipRatio: 0,
            meanRMS: peakRMS / 2,
            noiseFloorRMS: noiseFloorRMS,
            thresholdRMS: noiseFloorRMS * 3,
            frameCount: 200,
            speechSegmentCount: 0,
            voicedDurationSeconds: 0,
            segmenterSource: .energyFallback
        )
    }

    func testElevatedFloorWithModerateSNRWarrantsGuidanceButNotStrictFlag() {
        // Floor -42 dB, peak -25 dB (SNR 17): too much headroom for the strict
        // analytics flag, but the environment copy should still fire.
        let diag = noiseDiagnostics(peakRMS: 0.056, noiseFloorRMS: 0.0079)
        XCTAssertFalse(diag.indicatesHighBackgroundNoise)
        XCTAssertTrue(diag.warrantsBackgroundNoiseGuidance)
    }

    func testDominantFloorAlwaysWarrantsGuidance() {
        // Floor -38 dB: the room is loud enough to name regardless of SNR.
        let diag = noiseDiagnostics(peakRMS: 0.5, noiseFloorRMS: 0.0126)
        XCTAssertTrue(diag.warrantsBackgroundNoiseGuidance)
    }

    func testQuietRoomNeverWarrantsNoiseGuidance() {
        // Floor -60 dB: any failure there is not the environment's fault.
        let diag = noiseDiagnostics(peakRMS: 0.02, noiseFloorRMS: 0.001)
        XCTAssertFalse(diag.warrantsBackgroundNoiseGuidance)
        XCTAssertFalse(diag.indicatesHighBackgroundNoise)
    }

    func testElevatedFloorWithStrongVoiceDoesNotWarrantGuidance() {
        // Floor -44 dB but peak -18 dB (SNR 26): the voice clears the noise;
        // a failure is not the environment's fault.
        let diag = noiseDiagnostics(peakRMS: 0.126, noiseFloorRMS: 0.0063)
        XCTAssertFalse(diag.warrantsBackgroundNoiseGuidance)
    }
}
