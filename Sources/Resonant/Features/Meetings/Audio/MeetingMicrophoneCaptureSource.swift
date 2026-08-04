@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

struct MeetingMicrophoneCaptureContext: Sendable {
    let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let levelRef: OSAllocatedUnfairLock<Float>
    let bufferTimestamp: OSAllocatedUnfairLock<Date>
    let log: Logger
}

enum MeetingMicrophoneCaptureRoute: Equatable, Sendable {
    case systemDefault
    case selectedInput(uid: String)

    var usesSystemDefault: Bool {
        self == .systemDefault
    }

    static func resolve(
        inputDeviceUID: String?,
        defaultDeviceUID: String? = AVCaptureDevice.default(for: .audio)?.uniqueID
    ) -> MeetingMicrophoneCaptureRoute {
        guard let inputDeviceUID,
              inputDeviceUID != defaultDeviceUID else {
            return .systemDefault
        }
        return .selectedInput(uid: inputDeviceUID)
    }
}

protocol MeetingMicrophoneCaptureSource: AnyObject {
    var displayName: String { get }
    var usesSystemDefault: Bool { get }
    var configurationChangeNotificationObject: AnyObject? { get }

    func start() async throws
    func stop()
}

enum MeetingMicrophoneCaptureSourceFactory {
    static func make(
        inputDeviceUID: String?,
        context: MeetingMicrophoneCaptureContext
    ) -> any MeetingMicrophoneCaptureSource {
        switch MeetingMicrophoneCaptureRoute.resolve(inputDeviceUID: inputDeviceUID) {
        case .systemDefault:
            return MeetingCaptureSessionMicrophoneSource(deviceUID: nil, usesSystemDefault: true, context: context)
        case .selectedInput(let uid):
            return MeetingCaptureSessionMicrophoneSource(deviceUID: uid, usesSystemDefault: false, context: context)
        }
    }
}

enum MeetingMicrophoneCapturePermission {
    static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func statusDescription() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "not_determined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
}

enum MeetingAudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case noInputDevice
    case captureSessionStartFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is not enabled. Open System Settings -> Privacy & Security -> Microphone and enable Resonant."
        case .noInputDevice:
            return "The selected microphone is not available."
        case .captureSessionStartFailed:
            return "The selected microphone could not start."
        }
    }
}

private final class MeetingCaptureSessionMicrophoneSource: NSObject, MeetingMicrophoneCaptureSource, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let deviceUID: String?
    let usesSystemDefault: Bool
    private let context: MeetingMicrophoneCaptureContext
    private let lifecycleQueue = AudioCaptureHardwareCoordinator.lifecycleQueue
    private let sampleQueue = DispatchQueue(
        label: "com.resonance.resonant.meeting-mic-samples",
        qos: .userInteractive
    )
    private let didLogFirstBuffer = OSAllocatedUnfairLock(initialState: false)
    private let startGate = AudioCaptureStartGate()

    private var session: AVCaptureSession?
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureAudioDataOutput?
    private var resolvedDisplayName: String?

    var displayName: String {
        resolvedDisplayName
            ?? resolvedDevice()?.localizedName
            ?? (usesSystemDefault ? "System Default" : "Selected microphone")
    }

    let configurationChangeNotificationObject: AnyObject? = nil

    init(deviceUID: String?, usesSystemDefault: Bool, context: MeetingMicrophoneCaptureContext) {
        self.deviceUID = deviceUID
        self.usesSystemDefault = usesSystemDefault
        self.context = context
        super.init()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lifecycleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                var configuredSession: AVCaptureSession?
                var configuredOutput: AVCaptureAudioDataOutput?

                do {
                    var input: AVCaptureDeviceInput?
                    guard try self.startGate.performInputConstructionIfAllowed({
                        guard let device = self.resolvedDevice() else {
                            throw MeetingAudioCaptureError.noInputDevice
                        }
                        self.resolvedDisplayName = device.localizedName
                        let routeLabel = self.usesSystemDefault ? "system default" : "selected input"
                        self.context.log.notice("Mic input device selection using AVCaptureSession route=\(routeLabel, privacy: .public) name=\(device.localizedName, privacy: .public)")
                        input = try AVCaptureDeviceInput(device: device)
                    }) else {
                        throw CancellationError()
                    }
                    // A concurrent stop makes its veto visible before waiting
                    // for an in-flight initializer. Abandon the local input on
                    // this lifecycle queue before configuring a session.
                    guard self.startGate.allowsStart, let input else {
                        throw CancellationError()
                    }

                    let session = AVCaptureSession()
                    configuredSession = session
                    session.beginConfiguration()
                    var didCommitConfiguration = false
                    defer {
                        if !didCommitConfiguration {
                            session.commitConfiguration()
                        }
                    }

                    guard session.canAddInput(input) else {
                        throw MeetingAudioCaptureError.captureSessionStartFailed
                    }
                    session.addInput(input)

                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: self.sampleQueue)
                    configuredOutput = output
                    guard session.canAddOutput(output) else {
                        throw MeetingAudioCaptureError.captureSessionStartFailed
                    }
                    session.addOutput(output)
                    session.commitConfiguration()
                    didCommitConfiguration = true

                    session.startRunning()
                    guard session.isRunning else {
                        throw MeetingAudioCaptureError.captureSessionStartFailed
                    }

                    self.session = session
                    self.input = input
                    self.output = output
                    continuation.resume()
                } catch {
                    configuredOutput?.setSampleBufferDelegate(nil, queue: nil)
                    if configuredSession?.isRunning == true {
                        configuredSession?.stopRunning()
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resolvedDevice() -> AVCaptureDevice? {
        if let deviceUID {
            return AudioInputDeviceManager.resolveCaptureDevice(uid: deviceUID)
        }
        return AVCaptureDevice.default(for: .audio)
            ?? AudioInputDeviceManager.resolveCaptureDevice(uid: nil)
    }

    func stop() {
        // Publish before enqueueing. If start() has not reached lifecycleQueue
        // yet, its later block will self-veto instead of running after this
        // empty stop and reopening retired hardware.
        startGate.publishStop()

        // Retain the source until stop and property clearing finish. Capturing
        // all three objects locally keeps their final releases on the shared
        // lifecycle queue, after stopRunning has completed.
        lifecycleQueue.async { [self] in
            let session = self.session
            let input = self.input
            let output = self.output
            output?.setSampleBufferDelegate(nil, queue: nil)
            if session?.isRunning == true {
                session?.stopRunning()
            }
            self.session = nil
            self.input = nil
            self.output = nil
            withExtendedLifetime((session, input, output)) {}
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = Self.copyPCMBuffer(from: sampleBuffer) else {
            context.log.error("Dropping mic sample buffer: unsupported PCM format")
            return
        }

        context.continuation.yield(buffer)
        context.bufferTimestamp.withLock { $0 = Date() }
        context.levelRef.withLock {
            $0 = min(MeetingMicrophoneAudioMeter.normalizedRMS(from: buffer) * 5, 1)
        }

        let shouldLog = didLogFirstBuffer.withLock { didLog -> Bool in
            guard !didLog else { return false }
            didLog = true
            return true
        }
        if shouldLog {
            let format = buffer.format
            context.log.notice("First mic AVCapture buffer system_default=\(self.usesSystemDefault, privacy: .public) frames=\(Int(buffer.frameLength), privacy: .public) sample_rate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")
        }
    }

    private static func copyPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        var mutableDescription = streamDescription.pointee
        guard let format = AVAudioFormat(streamDescription: &mutableDescription) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            return nil
        }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }
}

enum MeetingMicrophoneAudioMeter {
    static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            return rms(frameLength: frameLength, channelCount: channelCount) { frame, channel in
                if buffer.format.isInterleaved {
                    return channelData[0][(frame * channelCount) + channel]
                }
                return channelData[channel][frame]
            }
        }

        if let channelData = buffer.int16ChannelData {
            let scale: Float = 1 / Float(Int16.max)
            return rms(frameLength: frameLength, channelCount: channelCount) { frame, channel in
                if buffer.format.isInterleaved {
                    return Float(channelData[0][(frame * channelCount) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            return rms(frameLength: frameLength, channelCount: channelCount) { frame, channel in
                if buffer.format.isInterleaved {
                    return Float(channelData[0][(frame * channelCount) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        return 0
    }

    private static func rms(
        frameLength: Int,
        channelCount: Int,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> Float {
        var sum: Float = 0
        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let sample = sampleAt(frame, channel)
                sum += sample * sample
            }
        }
        let sampleCount = Float(frameLength * channelCount)
        return sampleCount > 0 ? sqrt(sum / sampleCount) : 0
    }
}
