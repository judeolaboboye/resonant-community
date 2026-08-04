import AVFoundation
import os
import XCTest
@testable import Resonant

final class MeetingMicrophoneCaptureSourceTests: XCTestCase {

    func testRouteUsesSystemDefaultWhenNoInputIsSelected() {
        XCTAssertEqual(
            MeetingMicrophoneCaptureRoute.resolve(inputDeviceUID: nil, defaultDeviceUID: "default"),
            .systemDefault
        )
    }

    func testRouteUsesSystemDefaultWhenSelectedInputIsTheDefaultDevice() {
        XCTAssertEqual(
            MeetingMicrophoneCaptureRoute.resolve(inputDeviceUID: "default", defaultDeviceUID: "default"),
            .systemDefault
        )
    }

    func testRouteUsesSelectedInputWhenItDiffersFromDefaultDevice() {
        XCTAssertEqual(
            MeetingMicrophoneCaptureRoute.resolve(inputDeviceUID: "usb-mic", defaultDeviceUID: "default"),
            .selectedInput(uid: "usb-mic")
        )
    }

    func testStartedSourceIsRejectedWhenTeardownOrCancellationWinsTheRace() {
        XCTAssertTrue(
            MeetingMicrophoneCaptureStartPolicy.shouldRetainStartedSource(
                isTornDown: false,
                isTaskCancelled: false,
                isStillCurrent: true
            )
        )

        for veto in 0..<3 {
            XCTAssertFalse(
                MeetingMicrophoneCaptureStartPolicy.shouldRetainStartedSource(
                    isTornDown: veto == 0,
                    isTaskCancelled: veto == 1,
                    isStillCurrent: veto != 2
                )
            )
        }
    }

    func testSourceStartIsRejectedBeforeHardwareOpenAfterPermissionSuspension() {
        XCTAssertTrue(
            MeetingMicrophoneCaptureStartPolicy.shouldBeginSourceStart(
                isTornDown: false,
                isTaskCancelled: false
            )
        )
        XCTAssertFalse(
            MeetingMicrophoneCaptureStartPolicy.shouldBeginSourceStart(
                isTornDown: true,
                isTaskCancelled: false
            )
        )
        XCTAssertFalse(
            MeetingMicrophoneCaptureStartPolicy.shouldBeginSourceStart(
                isTornDown: false,
                isTaskCancelled: true
            )
        )
    }

    func testSourceStopPublishedBeforeStartEnqueueVetoesInputConstruction() {
        let gate = AudioCaptureStartGate()
        gate.publishStop()
        var didConstructInput = false

        XCTAssertFalse(
            gate.performInputConstructionIfAllowed {
                didConstructInput = true
            }
        )
        XCTAssertFalse(didConstructInput)
        XCTAssertFalse(gate.allowsStart)
    }

    func testFactoryPreservesSystemDefaultRoute() throws {
        var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        _ = AsyncStream<AVAudioPCMBuffer> { continuation in
            streamContinuation = continuation
        }

        let context = MeetingMicrophoneCaptureContext(
            continuation: try XCTUnwrap(streamContinuation),
            levelRef: OSAllocatedUnfairLock(initialState: Float(0)),
            bufferTimestamp: OSAllocatedUnfairLock(initialState: Date.distantPast),
            log: Logger(subsystem: "com.resonance.resonant.tests", category: "MicSourceFactory")
        )
        let source = MeetingMicrophoneCaptureSourceFactory.make(
            inputDeviceUID: nil,
            context: context
        )

        XCTAssertTrue(source.usesSystemDefault)
        XCTAssertNil(source.configurationChangeNotificationObject)
        streamContinuation?.finish()
    }

    func testAudioMeterComputesFloatMonoRMS() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples[0] = 1
        samples[1] = -1
        samples[2] = 0
        samples[3] = 0

        XCTAssertEqual(
            MeetingMicrophoneAudioMeter.normalizedRMS(from: buffer),
            sqrt(0.5),
            accuracy: 0.0001
        )
    }

    func testSelectedMicrophoneCaptureSourceDeliversLiveBuffersWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RESONANT_RUN_LIVE_MIC_TESTS"] == "1" else {
            throw XCTSkip("Set RESONANT_RUN_LIVE_MIC_TESTS=1 to run the live microphone smoke test.")
        }

        guard await MeetingMicrophoneCapturePermission.ensureMicrophoneAccess() else {
            throw XCTSkip(
                "Microphone access is \(MeetingMicrophoneCapturePermission.statusDescription()); live capture cannot run."
            )
        }

        let requestedName = environment["RESONANT_LIVE_MIC_NAME_CONTAINS"] ?? "TONOR"
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        guard let device = devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(requestedName) }) else {
            let availableNames = devices.map(\.localizedName).joined(separator: ", ")
            throw XCTSkip("No microphone matching '\(requestedName)' found. Available: \(availableNames)")
        }

        var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            streamContinuation = continuation
        }

        let levelRef = OSAllocatedUnfairLock(initialState: Float(0))
        let timestampRef = OSAllocatedUnfairLock(initialState: Date.distantPast)
        let context = MeetingMicrophoneCaptureContext(
            continuation: try XCTUnwrap(streamContinuation),
            levelRef: levelRef,
            bufferTimestamp: timestampRef,
            log: Logger(subsystem: "com.resonance.resonant.tests", category: "LiveMic")
        )
        let source = MeetingMicrophoneCaptureSourceFactory.make(
            inputDeviceUID: device.uniqueID,
            context: context
        )
        XCTAssertFalse(source.usesSystemDefault)

        try await source.start()
        defer {
            source.stop()
            streamContinuation?.finish()
        }

        let buffer = try await Self.firstBuffer(from: stream, timeoutNanoseconds: 5_000_000_000)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        XCTAssertGreaterThan(timestampRef.withLock { $0 }, Date.distantPast)
    }

    private enum LiveMicTestError: Error {
        case streamEnded
        case timeout
    }

    private static func firstBuffer(
        from stream: AsyncStream<AVAudioPCMBuffer>,
        timeoutNanoseconds: UInt64
    ) async throws -> AVAudioPCMBuffer {
        try await withThrowingTaskGroup(of: AVAudioPCMBuffer.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let buffer = await iterator.next() else {
                    throw LiveMicTestError.streamEnded
                }
                return buffer
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw LiveMicTestError.timeout
            }

            guard let buffer = try await group.next() else {
                throw LiveMicTestError.streamEnded
            }
            group.cancelAll()
            return buffer
        }
    }
}
