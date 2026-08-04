import AVFoundation
import XCTest
@testable import Resonant

final class TranscriberAudioSupportTests: XCTestCase {

    func testPreparedInputPadsShortAudioFilesToMinimumSampleCount() throws {
        let expectedSampleCount = 5_600
        let url = try makeAudioFile(sampleCount: expectedSampleCount)
        defer { try? FileManager.default.removeItem(at: url) }

        let preparedInput = try TranscriberAudioSupport.preparedInput(from: url)
        let totalPadding = TranscriberAudioSupport.minimumSampleCount - expectedSampleCount
        let expectedLeadingPadding = min(
            TranscriberAudioSupport.preferredLeadingPaddingSampleCount,
            totalPadding / 2
        )
        let expectedTrailingPadding = totalPadding - expectedLeadingPadding

        XCTAssertEqual(preparedInput.originalSampleCount, expectedSampleCount)
        XCTAssertEqual(preparedInput.leadingPaddingSampleCount, expectedLeadingPadding)
        XCTAssertEqual(preparedInput.trailingPaddingSampleCount, expectedTrailingPadding)
        XCTAssertEqual(preparedInput.preparedSamples.count, TranscriberAudioSupport.minimumSampleCount)
        XCTAssertTrue(
            Array(preparedInput.preparedSamples.prefix(expectedLeadingPadding)).allSatisfy { $0 == 0 },
            "Expected leading padding to be silence"
        )
        XCTAssertTrue(
            Array(preparedInput.preparedSamples.suffix(expectedTrailingPadding)).allSatisfy { $0 == 0 },
            "Expected trailing padding to be silence"
        )
    }

    func testPreparedInputLeavesLongerAudioFilesUnchanged() throws {
        let expectedSampleCount = 20_000
        let url = try makeAudioFile(sampleCount: expectedSampleCount)
        defer { try? FileManager.default.removeItem(at: url) }

        let preparedInput = try TranscriberAudioSupport.preparedInput(from: url)

        XCTAssertGreaterThan(preparedInput.originalSampleCount, TranscriberAudioSupport.minimumSampleCount)
        XCTAssertEqual(preparedInput.leadingPaddingSampleCount, 0)
        XCTAssertEqual(preparedInput.trailingPaddingSampleCount, 0)
        XCTAssertEqual(preparedInput.preparedSamples.count, preparedInput.originalSampleCount)
    }

    func testDetailedSampleRequirementDynamicallyDispatchesThroughExistential() async throws {
        let concrete = DetailedSentinelTranscriber()
        let existential: any Transcriber = concrete

        let result = try await existential.transcribeDetailed(
            audioSamples: [0.25],
            language: "en"
        )

        XCTAssertEqual(result.text, "detailed-sample")
        XCTAssertEqual(result.tokenTimings, [
            TranscriptTokenTiming(token: "detailed", startTime: 0, endTime: 0.1)
        ])
        XCTAssertEqual(concrete.plainSampleCallCount, 0)
        XCTAssertEqual(concrete.detailedSampleCallCount, 1)
    }

    func testPreparedTimingNormalizationReturnsRawCaptureCoordinates() throws {
        let samples = [Float](repeating: 0.1, count: 15_000)
        let preparedInput = try TranscriberAudioSupport.preparedInput(samples)
        let offset = Double(preparedInput.leadingPaddingSampleCount)
            / Double(DictationAudioAnalyzer.sampleRate)
        let rawDuration = Double(samples.count) / Double(DictationAudioAnalyzer.sampleRate)

        let normalized = TranscriberAudioSupport.normalizedTokenTimings(
            [
                TranscriptTokenTiming(
                    token: "near",
                    startTime: offset - 0.02,
                    endTime: offset + 0.18
                ),
                TranscriptTokenTiming(
                    token: "edge",
                    startTime: offset + 0.85,
                    endTime: offset + rawDuration + 0.04
                ),
            ],
            for: preparedInput
        )

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].startTime, 0, accuracy: 0.000_001)
        XCTAssertEqual(normalized[0].endTime, 0.18, accuracy: 0.000_001)
        XCTAssertEqual(normalized[1].startTime, 0.85, accuracy: 0.000_001)
        XCTAssertEqual(normalized[1].endTime, rawDuration, accuracy: 0.000_001)
    }

    func testPreparedTimingNormalizationRejectsPaddingOnlyAndInvalidSequences() throws {
        let preparedInput = try TranscriberAudioSupport.preparedInput(
            [Float](repeating: 0.1, count: 5_600)
        )

        XCTAssertTrue(
            TranscriberAudioSupport.normalizedTokenTimings(
                [TranscriptTokenTiming(token: "padding", startTime: 0, endTime: 0.02)],
                for: preparedInput
            ).isEmpty
        )
        XCTAssertTrue(
            TranscriberAudioSupport.normalizedTokenTimings(
                [
                    TranscriptTokenTiming(token: "later", startTime: 0.5, endTime: 0.7),
                    TranscriptTokenTiming(token: "earlier", startTime: 0.4, endTime: 0.6),
                ],
                for: preparedInput
            ).isEmpty
        )
        XCTAssertTrue(
            TranscriberAudioSupport.normalizedTokenTimings(
                [TranscriptTokenTiming(token: "nan", startTime: .nan, endTime: 0.2)],
                for: preparedInput
            ).isEmpty
        )
    }

    func testFluidRetryPolicyDoesNotRetryCancellation() async {
        var attempts = 0

        do {
            let _: String = try await FluidAudioRetryPolicy.retryOnce(
                operation: {
                    attempts += 1
                    throw CancellationError()
                },
                retry: {
                    attempts += 1
                    return "retried"
                }
            )
            XCTFail("Expected cancellation to escape")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 1)
    }

    func testFluidRetryPolicyRetriesOneEmptyResult() async throws {
        let counter = RetryInvocationCounter()
        let result: String = try await FluidAudioRetryPolicy.retryOnce(
            operation: {
                await counter.increment()
                return ""
            },
            retry: {
                await counter.increment()
                return "short dictation"
            },
            shouldRetryResult: { $0.isEmpty }
        )

        XCTAssertEqual(result, "short dictation")
        let attempts = await counter.value
        XCTAssertEqual(attempts, 2)
    }

    func testFluidRetryPolicyDoesNotRetryGenericErrorAfterCancellation() async {
        let counter = RetryInvocationCounter()
        let task = Task {
            try await FluidAudioRetryPolicy.retryOnce(
                operation: {
                    await counter.increment()
                    throw RetryStubError.expected
                },
                retry: {
                    await counter.increment()
                    return "unexpected retry"
                }
            ) as String
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let attempts = await counter.value
        XCTAssertEqual(attempts, 1)
    }

    func testFluidEmptyResultRetryFailureDoesNotRunThirdAttempt() async {
        let counter = RetryInvocationCounter()
        do {
            let _: String = try await FluidAudioRetryPolicy.retryOnce(
                operation: {
                    await counter.increment()
                    return ""
                },
                retry: {
                    await counter.increment()
                    throw RetryStubError.expected
                },
                shouldRetryResult: { $0.isEmpty }
            )
            XCTFail("Expected retry error")
        } catch RetryStubError.expected {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let attempts = await counter.value
        XCTAssertEqual(attempts, 2)
    }

    func testOnlyFluidDeclaresBoundedMemoryURLTranscription() {
        let defaultBackend: any Transcriber = DetailedSentinelTranscriber()
        let fluidBackend: any Transcriber = FluidAudioAdapter()

        XCTAssertFalse(defaultBackend.supportsDiskBackedURLTranscription)
        XCTAssertTrue(fluidBackend.supportsDiskBackedURLTranscription)
        XCTAssertFalse(CohereTranscribeAdapter().supportsDiskBackedURLTranscription)
        if #available(macOS 15, *) {
            XCTAssertFalse(Qwen3AudioAdapter().supportsDiskBackedURLTranscription)
        }
    }

    func testPreparedSamplesAddLeadingAndTrailingContextForShortUtterances() throws {
        let audioSamples: [Float] = [0.25, 0.5, 0.75]

        let preparedSamples = try TranscriberAudioSupport.preparedSamples(audioSamples)
        let leadingPaddingCount = TranscriberAudioSupport.preferredLeadingPaddingSampleCount
        let paddedUtterance = Array(preparedSamples[leadingPaddingCount..<(leadingPaddingCount + audioSamples.count)])

        XCTAssertEqual(preparedSamples.count, TranscriberAudioSupport.minimumSampleCount)
        XCTAssertEqual(
            Array(preparedSamples.prefix(leadingPaddingCount)),
            Array<Float>(repeating: 0, count: leadingPaddingCount)
        )
        XCTAssertEqual(paddedUtterance, audioSamples)
        XCTAssertEqual(preparedSamples.last, 0)
    }

    func testPreparedSamplesAttenuateClippedCaptureToTargetPeak() throws {
        // Long enough to skip padding so the returned buffer is the scaled signal.
        var samples = [Float](repeating: 0.3, count: TranscriberAudioSupport.minimumSampleCount)
        samples[0] = 1.0
        samples[1] = -1.0

        let prepared = try TranscriberAudioSupport.preparedSamples(samples)

        let peak = prepared.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, TranscriberAudioSupport.normalizationTargetPeak, accuracy: 0.0001)
        // Relative shape is preserved — every sample scaled by 0.9 / 1.0.
        XCTAssertEqual(prepared[0], 0.9, accuracy: 0.0001)
        XCTAssertEqual(prepared[2], Float(0.3) * 0.9, accuracy: 0.0001)
    }

    func testPreparedSamplesAttenuateNearFullScaleCapture() throws {
        var samples = [Float](repeating: 0.2, count: TranscriberAudioSupport.minimumSampleCount)
        samples[0] = 0.96

        let prepared = try TranscriberAudioSupport.preparedSamples(samples)

        let peak = prepared.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, TranscriberAudioSupport.normalizationTargetPeak, accuracy: 0.0001)
    }

    func testPreparedSamplesLeaveModerateLevelsUntouched() throws {
        var samples = [Float](repeating: 0.1, count: TranscriberAudioSupport.minimumSampleCount)
        samples[0] = 0.5

        let prepared = try TranscriberAudioSupport.preparedSamples(samples)

        // Peak below the 0.95 ceiling — the buffer must be returned unscaled.
        XCTAssertEqual(prepared, samples)
    }

    func testPreparedSamplesRejectAllSilence() {
        XCTAssertThrowsError(
            try TranscriberAudioSupport.preparedSamples(Array(repeating: 0, count: 4_000))
        )
    }

    func testPreparedSamplesReplaceNonFiniteSamplesBeforePadding() throws {
        let preparedSamples = try TranscriberAudioSupport.preparedSamples([0.5, .nan, .infinity, -0.25])
        let leadingPaddingCount = TranscriberAudioSupport.preferredLeadingPaddingSampleCount
        let paddedUtterance = Array(preparedSamples[leadingPaddingCount..<(leadingPaddingCount + 4)])

        XCTAssertEqual(paddedUtterance, [0.5, 0, 0, -0.25])
    }

    private func makeAudioFile(sampleCount: Int, sampleRate: Double = 16_000) throws -> URL {
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

        let channel = buffer.floatChannelData![0]
        for index in 0..<sampleCount {
            let time = Double(index) / sampleRate
            channel[index] = Float(sin(2 * Double.pi * 220 * time) * 0.1)
        }

        try file.write(from: buffer)
        return url
    }
}

private final class DetailedSentinelTranscriber: Transcriber, @unchecked Sendable {
    let id = "detailed-sentinel"
    let displayName = "Detailed sentinel"
    let description = "Exercises existential protocol dispatch"
    let isLoaded = true
    let isDownloaded = true
    let requiresDownload = false
    let downloadSizeBytes: Int64 = 0
    let modelURL: URL? = nil
    let supportedLanguageCodes: Set<String> = []
    let supportsAutoLanguageDetection = true

    private(set) var plainSampleCallCount = 0
    private(set) var detailedSampleCallCount = 0

    func download(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {}
    func load() async throws {}

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        "plain-url"
    }

    func transcribe(audioSamples: [Float], language: String?) async throws -> String {
        plainSampleCallCount += 1
        return "plain-sample"
    }

    func transcribeDetailed(
        audioSamples: [Float],
        language: String?
    ) async throws -> DetailedTranscription {
        detailedSampleCallCount += 1
        return DetailedTranscription(
            text: "detailed-sample",
            tokenTimings: [
                TranscriptTokenTiming(token: "detailed", startTime: 0, endTime: 0.1)
            ]
        )
    }

    func unload() {}
}

private actor RetryInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private enum RetryStubError: Error {
    case expected
}
