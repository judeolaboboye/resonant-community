import XCTest
@testable import Resonant

final class DictationPipelinePrimitivesTests: XCTestCase {
    func testEphemeralRecordingPolicyDeletesOnEveryPipelineExit() {
        XCTAssertTrue(DictationRecordingRetentionPolicy.ephemeral.deletesRecordingWhenPipelineExits)
        XCTAssertFalse(DictationRecordingRetentionPolicy.recoverable.deletesRecordingWhenPipelineExits)

        XCTAssertTrue(DictationRecordingRetentionPolicy.ephemeral
            .deletesRecordingAfterFailedFinalization(cancellationRequested: false))
        XCTAssertFalse(DictationRecordingRetentionPolicy.recoverable
            .deletesRecordingAfterFailedFinalization(cancellationRequested: false))
        XCTAssertTrue(DictationRecordingRetentionPolicy.recoverable
            .deletesRecordingAfterFailedFinalization(cancellationRequested: true))
    }

    func testShutdownCleanupRequiresNoCaptureOrRecoveryOwner() {
        XCTAssertTrue(DictationShutdownCleanupPolicy.shouldDeleteRecorderArtifacts(
            isRecording: false,
            isStartingRecording: false,
            isFinishingCapture: false,
            hasRecoveryOwnership: false
        ))

        for state in [
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
        ] {
            XCTAssertFalse(DictationShutdownCleanupPolicy.shouldDeleteRecorderArtifacts(
                isRecording: state.0,
                isStartingRecording: state.1,
                isFinishingCapture: state.2,
                hasRecoveryOwnership: state.3
            ))
        }
    }

    func testRecordingDeletionIsVerifiedAndIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-delete-\(UUID().uuidString).caf")
        try Data([1, 2, 3]).write(to: url)

        XCTAssertTrue(DictationRecordingFileDeletion.removeIfPresent(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(DictationRecordingFileDeletion.removeIfPresent(url))
    }


    func testStaleCaptureStartCannotFinishNewAttempt() {
        var ownership = CaptureStartAttemptOwnership()
        let first = ownership.begin()
        ownership.cancel()
        let second = ownership.begin()

        XCTAssertFalse(ownership.finish(first))
        XCTAssertTrue(ownership.owns(second))
        XCTAssertTrue(ownership.finish(second))
        XCTAssertNil(ownership.activeID)
    }

    func testStaleCaptureStartCannotCancelNewAttemptByIdentity() {
        var ownership = CaptureStartAttemptOwnership()
        let first = ownership.begin()
        let second = ownership.begin()

        XCTAssertFalse(ownership.owns(first))
        XCTAssertTrue(ownership.owns(second))
    }

    func testCancellationDefersForAudioOrPipelineRetirement() {
        XCTAssertFalse(DictationCancellationJoinPolicy.requiresDeferredRetirement(
            hasPendingAudioFinalization: false,
            hasActivePipeline: false
        ))
        XCTAssertTrue(DictationCancellationJoinPolicy.requiresDeferredRetirement(
            hasPendingAudioFinalization: true,
            hasActivePipeline: false
        ))
        XCTAssertTrue(DictationCancellationJoinPolicy.requiresDeferredRetirement(
            hasPendingAudioFinalization: false,
            hasActivePipeline: true
        ))
        XCTAssertFalse(DictationCancellationJoinPolicy.resultTaskOwnsTerminalArtifacts(
            hasActiveResultTask: false
        ))
        XCTAssertTrue(DictationCancellationJoinPolicy.resultTaskOwnsTerminalArtifacts(
            hasActiveResultTask: true
        ))
    }

    func testCaptureFinalizationRetirementReleasesAllWaiters() async {
        let retirement = CaptureFinalizationRetirement()
        async let first: Void = retirement.wait()
        async let second: Void = retirement.wait()
        await retirement.complete()
        _ = await (first, second)
        await retirement.wait()
    }

    func testDeadlineReturnsPromptlyWithoutCancellingLateTask() async {
        let task = Task<String, Never> {
            try? await Task.sleep(for: .milliseconds(180))
            return "late metadata"
        }
        let clock = ContinuousClock()
        let start = clock.now

        let immediate = await DictationAsyncDeadline.valueIfReady(
            task,
            timeoutNanoseconds: 15_000_000
        )
        let elapsed = start.duration(to: clock.now)

        XCTAssertNil(immediate)
        XCTAssertLessThan(elapsed, .milliseconds(120))
        let lateValue = await task.value
        XCTAssertEqual(lateValue, "late metadata")
    }

    func testDeadlineReturnsReadyValue() async {
        let task = Task<String, Never> { "ready" }
        let value = await DictationAsyncDeadline.valueIfReady(
            task,
            timeoutNanoseconds: 500_000_000
        )
        XCTAssertEqual(value, "ready")
    }

    func testCancellationStopsWaitingForNonCooperativeSourceTask() async {
        let source = Task<String, Never> {
            try? await Task.sleep(for: .milliseconds(180))
            return "eventual context"
        }
        let clock = ContinuousClock()
        let start = clock.now
        let waiter = Task {
            await DictationAsyncDeadline.valueUnlessCancelled(source)
        }

        try? await Task.sleep(for: .milliseconds(10))
        waiter.cancel()
        let value = await waiter.value
        let elapsed = start.duration(to: clock.now)

        XCTAssertNil(value)
        XCTAssertLessThan(elapsed, .milliseconds(120))
        let sourceValue = await source.value
        XCTAssertEqual(sourceValue, "eventual context")
    }

    func testThrowingCancellationStopsWaitingForNonCooperativeOperation() async {
        let clock = ContinuousClock()
        let start = clock.now
        let waiter = Task {
            try await DictationAsyncDeadline.throwingValueUnlessCancelled {
                try? await Task.sleep(for: .milliseconds(180))
                return "eventual audio"
            }
        }

        try? await Task.sleep(for: .milliseconds(10))
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(120))
    }

    func testThrowingCancellationPreservesSourceError() async {
        do {
            _ = try await DictationAsyncDeadline.throwingValueUnlessCancelled {
                throw StubPipelineError.expected
            } as String
            XCTFail("Expected source error")
        } catch StubPipelineError.expected {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFirstResultGateResumesExactlyOnceUnderContention() async {
        for _ in 0..<100 {
            let gate = FirstResultGate<Int>()
            async let first = gate.resolve(1)
            async let second = gate.resolve(2)
            let wins = await [first, second]
            let value = await gate.value()
            XCTAssertEqual(wins.filter { $0 }.count, 1)
            XCTAssertTrue([1, 2].contains(value))
        }
    }

    func testLongAudioRoutingNeverInvokesCanonicalLoader() async throws {
        let counter = InvocationCounter()
        let result = try await DictationAudioRouting.loadCanonicalSamplesIfNeeded(
            from: URL(fileURLWithPath: "/unused"),
            estimatedSampleCount: 480_001,
            supportsDiskBackedURLTranscription: true
        ) { _ in
            await counter.increment()
            return [1]
        }

        let invocationCount = await counter.value
        XCTAssertNil(result)
        XCTAssertEqual(invocationCount, 0)
    }

    func testCanonicalRoutingIncludesBoundaryAndInvokesLoaderOnce() async throws {
        let counter = InvocationCounter()
        let result = try await DictationAudioRouting.loadCanonicalSamplesIfNeeded(
            from: URL(fileURLWithPath: "/unused"),
            estimatedSampleCount: 480_000,
            supportsDiskBackedURLTranscription: true
        ) { _ in
            await counter.increment()
            return [0.25]
        }

        let invocationCount = await counter.value
        XCTAssertEqual(result, [0.25])
        XCTAssertEqual(invocationCount, 1)
    }

    func testLongAudioStillLoadsCanonicalSamplesForMemoryBackedURLAdapter() async throws {
        let counter = InvocationCounter()
        let result = try await DictationAudioRouting.loadCanonicalSamplesIfNeeded(
            from: URL(fileURLWithPath: "/unused"),
            estimatedSampleCount: 480_001,
            supportsDiskBackedURLTranscription: false
        ) { _ in
            await counter.increment()
            return [0.5]
        }

        XCTAssertEqual(result, [0.5])
        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 1)
    }
}

private actor InvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private enum StubPipelineError: Error {
    case expected
}

// MARK: - Empty-result classification

final class DictationEmptyResultClassificationTests: XCTestCase {

    func testShortRealWordCountsAsSpeech() {
        // A 0.2s "yes" that ASR whiffed on must not be reported as "no speech".
        XCTAssertTrue(
            DictationEmptyResultClassification.isSpeechDetected(
                speechSegmentCount: 1,
                voicedDurationSeconds: 0.2
            )
        )
    }

    func testSubGateVoicedDurationIsNotSpeech() {
        XCTAssertFalse(
            DictationEmptyResultClassification.isSpeechDetected(
                speechSegmentCount: 1,
                voicedDurationSeconds: 0.1
            )
        )
    }

    func testZeroSegmentsIsNotSpeechRegardlessOfVoicedDuration() {
        XCTAssertFalse(
            DictationEmptyResultClassification.isSpeechDetected(
                speechSegmentCount: 0,
                voicedDurationSeconds: 1.0
            )
        )
    }
}

// MARK: - Voiced-window retry

final class DictationVoicedWindowRetryTests: XCTestCase {

    private func segment(_ start: Int, _ end: Int) -> DictationAudioAnalyzer.SpeechSegment {
        DictationAudioAnalyzer.SpeechSegment(startSample: start, endSample: end)
    }

    func testOnlyShortClipsAttemptRetry() {
        XCTAssertTrue(DictationVoicedWindowRetry.shouldAttempt(clipDuration: 1.5))
        XCTAssertFalse(DictationVoicedWindowRetry.shouldAttempt(clipDuration: 0))
        // At/above the segment-recovery bound the long-form machinery owns it.
        XCTAssertFalse(
            DictationVoicedWindowRetry.shouldAttempt(
                clipDuration: DictationSegmentRecovery.minimumClipDuration
            )
        )
    }

    func testWindowPadsAroundVoicedSpanAndClampsToClip() {
        // 3s clip (48k samples), speech at 20k..24k: window pads ±4k.
        let bounds = DictationVoicedWindowRetry.windowBounds(
            segments: [segment(20_000, 24_000)],
            sampleCount: 48_000
        )
        XCTAssertEqual(bounds, 16_000..<28_000)

        // Speech at the very start clamps to 0.
        let leading = DictationVoicedWindowRetry.windowBounds(
            segments: [segment(1_000, 8_000)],
            sampleCount: 48_000
        )
        XCTAssertEqual(leading, 0..<12_000)
    }

    func testWindowSpansAllSegments() {
        let bounds = DictationVoicedWindowRetry.windowBounds(
            segments: [segment(30_000, 34_000), segment(10_000, 12_000)],
            sampleCount: 48_000
        )
        XCTAssertEqual(bounds, 6_000..<38_000)
    }

    func testWholeClipWindowSkipsRetry() {
        // Trimming saves almost nothing — the retry would repeat the decode
        // the adapter already retried internally.
        XCTAssertNil(
            DictationVoicedWindowRetry.windowBounds(
                segments: [segment(0, 15_000)],
                sampleCount: 16_000
            )
        )
    }

    func testEmptySegmentsProduceNoWindow() {
        XCTAssertNil(
            DictationVoicedWindowRetry.windowBounds(segments: [], sampleCount: 48_000)
        )
    }
}

// MARK: - Recording level window (live noise-bed detection)

final class RecordingLevelWindowTests: XCTestCase {

    private func window(levels: [Float]) -> RecordingLevelWindow {
        var window = RecordingLevelWindow()
        for level in levels {
            window.append(level)
        }
        return window
    }

    func testSteadyLoudBedIsDetected() {
        // ~-42 dB bed with ±0.02 wobble for 1.5s: machinery, no voice yet.
        let levels = (0..<15).map { Float(0.30) + (($0 % 2 == 0) ? 0.01 : -0.01) }
        let window = window(levels: levels)
        XCTAssertTrue(window.indicatesSteadyLoudBed)
        XCTAssertFalse(window.indicatesSpeechDynamics)
    }

    func testSpeechOverBedIsNotASteadyBed() {
        let levels: [Float] = Array(repeating: 0.30, count: 10) + [0.55, 0.6, 0.5, 0.58]
        let window = window(levels: levels)
        XCTAssertFalse(window.indicatesSteadyLoudBed)
        XCTAssertTrue(window.indicatesSpeechDynamics)
    }

    func testQuietRoomIsNeitherBedNorSpeech() {
        let window = window(levels: Array(repeating: 0.01, count: 15))
        XCTAssertFalse(window.indicatesSteadyLoudBed)
        XCTAssertFalse(window.indicatesSpeechDynamics)
    }

    func testTooFewSamplesNeverJudgeABed() {
        let window = window(levels: Array(repeating: 0.30, count: 5))
        XCTAssertFalse(window.indicatesSteadyLoudBed)
    }

    func testWindowKeepsOnlyRecentSamples() {
        // Old speech peaks scroll out; the surviving window is pure bed.
        var window = RecordingLevelWindow()
        for level in [Float(0.6), 0.55] + Array(repeating: Float(0.30), count: 25) {
            window.append(level)
        }
        XCTAssertEqual(window.samples.count, RecordingLevelWindow.capacity)
        XCTAssertTrue(window.indicatesSteadyLoudBed)
    }
}
