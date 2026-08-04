import XCTest
@testable import Resonant

@MainActor
final class AudioRecorderTests: XCTestCase {

    func testNormalizedAudioPowerClampsToExpectedRange() {
        XCTAssertEqual(AudioRecorder.normalizedAudioPower(-160), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioRecorder.normalizedAudioPower(0), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioRecorder.normalizedAudioPower(6), 1, accuracy: 0.0001)
    }

    func testNormalizedAudioPowerKeepsMidrangeResponsive() {
        XCTAssertEqual(AudioRecorder.normalizedAudioPower(-30), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AudioRecorder.normalizedAudioPower(-45), 0.25, accuracy: 0.0001)
    }

    func testNormalizedAudioPowerRejectsNonFiniteValues() {
        XCTAssertEqual(AudioRecorder.normalizedAudioPower(.nan), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioRecorder.normalizedAudioPower(.infinity), 0, accuracy: 0.0001)
    }

    func testSharedAsyncOperationSharesOneInFlightResult() async throws {
        let operation = SharedAsyncOperation<Int>()
        var invocationCount = 0

        let first = Task { @MainActor in
            try await operation.value {
                invocationCount += 1
                try await Task.sleep(for: .milliseconds(40))
                return 42
            }
        }
        while invocationCount == 0 {
            await Task.yield()
        }

        let second = Task { @MainActor in
            try await operation.value {
                invocationCount += 1
                return 99
            }
        }

        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, 42)
        XCTAssertEqual(secondValue, 42)
        XCTAssertEqual(invocationCount, 1)
    }

    func testSharedAsyncOperationSharesOneInFlightError() async {
        let operation = SharedAsyncOperation<Int>()
        var invocationCount = 0

        let first = Task { @MainActor in
            try? await operation.value {
                invocationCount += 1
                try await Task.sleep(for: .milliseconds(40))
                throw StubOperationError.expected
            }
        }
        while invocationCount == 0 {
            await Task.yield()
        }

        let second = Task { @MainActor in
            try? await operation.value {
                invocationCount += 1
                return 99
            }
        }

        let firstValue = await first.value
        let secondValue = await second.value
        XCTAssertNil(firstValue)
        XCTAssertNil(secondValue)
        XCTAssertEqual(invocationCount, 1)
    }

    func testSharedAsyncOperationResetAllowsNewOperation() async throws {
        let operation = SharedAsyncOperation<Int>()
        var invocationCount = 0

        let firstValue = try await operation.value {
            invocationCount += 1
            return invocationCount
        }
        let cachedValue = try await operation.value {
            invocationCount += 1
            return invocationCount
        }

        XCTAssertTrue(operation.reset())

        let resetValue = try await operation.value {
            invocationCount += 1
            return invocationCount
        }

        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(cachedValue, 1)
        XCTAssertEqual(resetValue, 2)
        XCTAssertEqual(invocationCount, 2)
    }

    func testSharedAsyncOperationLateCallerReceivesCachedTerminalResult() async throws {
        let operation = SharedAsyncOperation<Int>()
        var invocationCount = 0

        let firstValue = try await operation.value {
            invocationCount += 1
            return 42
        }
        let lateValue = try await operation.value {
            invocationCount += 1
            return 99
        }

        XCTAssertTrue(operation.isCompleted)
        XCTAssertEqual(firstValue, 42)
        XCTAssertEqual(lateValue, 42)
        XCTAssertEqual(invocationCount, 1)
    }

    func testSharedAsyncOperationRefusesResetWhileInFlight() async throws {
        let operation = SharedAsyncOperation<Int>()
        var invocationCount = 0

        let first = Task { @MainActor in
            try await operation.value {
                invocationCount += 1
                try await Task.sleep(for: .milliseconds(40))
                return 42
            }
        }
        while invocationCount == 0 {
            await Task.yield()
        }

        XCTAssertFalse(operation.reset())
        let joinedValue = try await operation.value {
            invocationCount += 1
            return 99
        }

        let firstValue = try await first.value
        XCTAssertEqual(firstValue, 42)
        XCTAssertEqual(joinedValue, 42)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(operation.reset())
    }

    func testCaptureLifecycleRejectsStartWhileActiveOrFinalizing() {
        var lifecycle = AudioCaptureLifecycleStateMachine()
        let generation = try! XCTUnwrap(lifecycle.beginStart())

        XCTAssertEqual(lifecycle.phase, .starting)
        XCTAssertNil(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.captureDidStart(generation))
        XCTAssertEqual(lifecycle.phase, .recording)
        XCTAssertNil(lifecycle.beginStart())

        XCTAssertTrue(lifecycle.requestFinalization(generation, intent: .stop))
        XCTAssertEqual(lifecycle.phase, .finalizing)
        XCTAssertNil(lifecycle.beginStart())
    }

    func testCaptureLifecycleCancelDominatesConcurrentStopDisposition() {
        var lifecycle = AudioCaptureLifecycleStateMachine()
        let generation = try! XCTUnwrap(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.captureDidStart(generation))

        XCTAssertTrue(lifecycle.requestFinalization(generation, intent: .stop))
        XCTAssertFalse(lifecycle.cancellationRequested)
        XCTAssertTrue(lifecycle.requestFinalization(generation, intent: .cancel))
        XCTAssertTrue(lifecycle.cancellationRequested)
        XCTAssertEqual(lifecycle.phase, .finalizing)

        XCTAssertTrue(lifecycle.markTerminal(generation))
        XCTAssertTrue(lifecycle.requestFinalization(generation, intent: .stop))
        XCTAssertTrue(lifecycle.cancellationRequested)
    }

    func testCaptureLifecycleFinalizationDuringStartupKeepsOwnershipUntilBackendStarts() {
        var lifecycle = AudioCaptureLifecycleStateMachine()
        let generation = try! XCTUnwrap(lifecycle.beginStart())

        XCTAssertTrue(lifecycle.requestFinalization(generation, intent: .cancel))
        XCTAssertEqual(lifecycle.phase, .finalizing)
        XCTAssertTrue(lifecycle.captureDidStart(generation))
        XCTAssertEqual(lifecycle.phase, .finalizing)
        XCTAssertTrue(lifecycle.cancellationRequested)
        XCTAssertNil(lifecycle.beginStart())
    }

    func testCaptureLifecycleResetRequiresTerminalState() {
        var lifecycle = AudioCaptureLifecycleStateMachine()
        let firstGeneration = try! XCTUnwrap(lifecycle.beginStart())

        XCTAssertFalse(lifecycle.reset())
        XCTAssertTrue(lifecycle.requestFinalization(firstGeneration, intent: .stop))
        XCTAssertFalse(lifecycle.reset())
        XCTAssertTrue(lifecycle.markTerminal(firstGeneration))
        XCTAssertTrue(lifecycle.reset())
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertNil(lifecycle.generation)

        let secondGeneration = try! XCTUnwrap(lifecycle.beginStart())
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertFalse(lifecycle.requestFinalization(firstGeneration, intent: .cancel))
        XCTAssertFalse(lifecycle.cancellationRequested)
    }

    func testStartupCancellationJoinReturnsBeforeSuspendedStartupCompletes() async {
        let completion = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(180))
        }
        let clock = ContinuousClock()
        let start = clock.now

        let joined = await AudioCaptureCancellationJoin.wait(
            for: completion,
            timeoutNanoseconds: 15_000_000
        )
        let elapsed = start.duration(to: clock.now)

        XCTAssertFalse(joined)
        XCTAssertLessThan(elapsed, .milliseconds(120))
        await completion.value
    }

    func testCancelledStartupFailureIsClassifiedAsCancellation() {
        let cancelled = AudioCaptureStartupErrorPolicy.errorToThrow(
            StubOperationError.expected,
            cancellationRequested: true
        )
        let ordinary = AudioCaptureStartupErrorPolicy.errorToThrow(
            StubOperationError.expected,
            cancellationRequested: false
        )

        XCTAssertTrue(cancelled is CancellationError)
        XCTAssertTrue(ordinary is StubOperationError)
    }

    func testCaptureStartBarrierWaitsForDelegateAcknowledgement() async {
        let barrier = AudioCaptureStartBarrier(generation: 41)
        let url = URL(fileURLWithPath: "/tmp/acknowledged.caf")
        let acknowledgedAt = Date()
        let waiter = Task {
            await barrier.wait(timeoutNanoseconds: 500_000_000)
        }

        await Task.yield()
        XCTAssertTrue(barrier.resolve(.started(url, acknowledgedAt)))
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .started(url, acknowledgedAt))
        XCTAssertFalse(barrier.resolve(.cancelled))
        XCTAssertEqual(barrier.generation, 41)
    }

    func testCaptureStartBarrierFailsWhenRecordingFinishesBeforeStart() async {
        let barrier = AudioCaptureStartBarrier(generation: 7)
        XCTAssertTrue(barrier.resolve(.finishedBeforeStart("device disconnected")))

        let outcome = await barrier.wait(timeoutNanoseconds: 500_000_000)

        XCTAssertEqual(outcome, .finishedBeforeStart("device disconnected"))
        XCTAssertFalse(
            barrier.resolve(
                .started(URL(fileURLWithPath: "/tmp/too-late.caf"), Date())
            )
        )
    }

    func testCaptureStartBarrierTimesOutWithoutAcknowledgement() async {
        let barrier = AudioCaptureStartBarrier(generation: 9)
        let clock = ContinuousClock()
        let startedAt = clock.now

        let outcome = await barrier.wait(timeoutNanoseconds: 15_000_000)
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(elapsed, .milliseconds(120))
        XCTAssertFalse(
            barrier.resolve(
                .started(URL(fileURLWithPath: "/tmp/too-late.caf"), Date())
            )
        )
    }

    func testCaptureStartBarrierCancellationReleasesWaiter() async {
        let barrier = AudioCaptureStartBarrier(generation: 11)
        let waiter = Task {
            await barrier.wait(timeoutNanoseconds: 1_000_000_000)
        }

        await Task.yield()
        waiter.cancel()

        let outcome = await waiter.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testWarmPromotionResolvesMatchingInFlightBuildOnCaptureQueue() {
        XCTAssertTrue(
            AudioWarmPromotionPolicy.shouldResolveOnCaptureQueue(
                requestedDeviceUID: "mic-a",
                captureDeviceUID: "mic-a"
            )
        )
        XCTAssertFalse(
            AudioWarmPromotionPolicy.shouldResolveOnCaptureQueue(
                requestedDeviceUID: "mic-a",
                captureDeviceUID: "mic-b"
            )
        )
        XCTAssertFalse(
            AudioWarmPromotionPolicy.shouldResolveOnCaptureQueue(
                requestedDeviceUID: nil,
                captureDeviceUID: "mic-a"
            )
        )
    }

    func testWarmPromotionRequiresExactGenerationAndDevice() {
        XCTAssertTrue(
            AudioWarmPromotionPolicy.canPromote(
                requestedGeneration: 12,
                requestedDeviceUID: "mic-a",
                builtGeneration: 12,
                builtDeviceUID: "mic-a"
            )
        )
        XCTAssertFalse(
            AudioWarmPromotionPolicy.canPromote(
                requestedGeneration: 12,
                requestedDeviceUID: "mic-a",
                builtGeneration: 11,
                builtDeviceUID: "mic-a"
            )
        )
        XCTAssertFalse(
            AudioWarmPromotionPolicy.canPromote(
                requestedGeneration: 12,
                requestedDeviceUID: "mic-a",
                builtGeneration: 12,
                builtDeviceUID: "mic-b"
            )
        )
    }
}

private enum StubOperationError: Error {
    case expected
}
