import Accelerate
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Dispatch
import Foundation
import os

/// Captures system output audio via a Core Audio process tap.
/// Ported from OpenOats — adapted for Resonant.
@available(macOS 14.2, *)
final class SystemAudioCapture: @unchecked Sendable {

    /// Makeup gain applied to captured system audio to compensate for Apple's known
    /// attenuation on multi-stream output devices (~3 dB per extra stereo pair).
    /// 6 dB = ×2.0 linear. Clamped post-gain to prevent wrap on loud inputs.
    private static let systemAudioGainDb: Float = 6.0
    private static let systemAudioGainLinear: Float = {
        pow(10.0, systemAudioGainDb / 20.0)
    }()

    private static let logger = Logger.resonant("SystemAudioCapture")

    private let _aggregateDeviceID = OSAllocatedUnfairLock<AudioObjectID>(
        uncheckedState: AudioObjectID(kAudioObjectUnknown)
    )
    private let _tapID = OSAllocatedUnfairLock<AudioObjectID>(
        uncheckedState: AudioObjectID(kAudioObjectUnknown)
    )
    private let _ioProcID = OSAllocatedUnfairLock<AudioDeviceIOProcID?>(uncheckedState: nil)
    private let _sysContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(
        uncheckedState: nil
    )
    private let _audioLevel = OSAllocatedUnfairLock<Float>(uncheckedState: 0)
    private let _sampleCount = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
    private let callbackQueue = DispatchQueue(
        label: "com.resonance.resonant.system-audio",
        qos: .userInteractive
    )
    private let _defaultOutputListener = OSAllocatedUnfairLock<AudioObjectPropertyListenerBlock?>(
        uncheckedState: nil
    )

    var audioLevel: Float { _audioLevel.withLock { $0 } }

    struct CaptureStreams {
        let systemAudio: AsyncStream<AVAudioPCMBuffer>
        let resolvedDeviceTransport: MeetingAudioTransport
        let isDeviceScoped: Bool
    }

    /// What to capture. Device scope taps a physical output device and is vulnerable
    /// to Bluetooth / device-switch failures. Process scopes tap meeting apps' output
    /// mixdown pre-routing, independent of the user's active output device.
    enum CaptureScope: Sendable {
        case device(AudioDeviceID?)
        case processObjectIDs([AudioObjectID])
        case bundleIDs([String])
    }

    func bufferStream(scope: CaptureScope = .device(nil)) async throws -> CaptureStreams {
        await stop()

        let sysStream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self._sysContinuation.withLock { $0 = continuation }
        }

        let tapUUID = UUID()
        let clockDeviceID: AudioDeviceID
        let clockSubDeviceUID: String
        let isDeviceScoped: Bool
        let tapDescription: CATapDescription

        switch scope {
        case .device(let requestedID):
            let deviceID = try (requestedID ?? Self.defaultOutputDeviceID())
            let uid = try Self.deviceUID(for: deviceID)
            clockDeviceID = deviceID
            clockSubDeviceUID = uid
            isDeviceScoped = true

            let desc = CATapDescription()
            desc.name = "Resonant System Audio"
            desc.uuid = tapUUID
            desc.processes = []
            desc.isPrivate = true
            desc.muteBehavior = .unmuted
            desc.isMixdown = true
            desc.isMono = true
            desc.isExclusive = true
            desc.deviceUID = uid
            desc.stream = 0
            tapDescription = desc

        case .processObjectIDs(let objectIDs):
            guard !objectIDs.isEmpty else {
                _sysContinuation.withLock { $0?.finish(); $0 = nil }
                throw CaptureError.emptyProcessScope
            }
            // Pin the aggregate clock to built-in output so the IO callback keeps
            // firing even if the user's active output device disappears (Bluetooth
            // disconnect, HDMI unplug, etc.). The tap content is process-scoped so
            // it is independent of which device is playing audio.
            clockDeviceID = try Self.builtInOutputDeviceID()
            clockSubDeviceUID = try Self.deviceUID(for: clockDeviceID)
            isDeviceScoped = false

            // `initMonoMixdownOfProcesses:` already sets mono/mixdown/exclusive=false
            // and leaves deviceUID nil — process-scoped taps read pre-routing.
            let desc = CATapDescription(monoMixdownOfProcesses: objectIDs)
            desc.name = "Resonant Meeting Audio"
            desc.uuid = tapUUID
            desc.isPrivate = true
            desc.muteBehavior = CATapMuteBehavior.unmuted
            tapDescription = desc

        case .bundleIDs(let bundles):
            guard !bundles.isEmpty else {
                _sysContinuation.withLock { $0?.finish(); $0 = nil }
                throw CaptureError.emptyProcessScope
            }
            guard #available(macOS 26.0, *) else {
                _sysContinuation.withLock { $0?.finish(); $0 = nil }
                throw CaptureError.bundleIDsUnavailable
            }
            clockDeviceID = try Self.builtInOutputDeviceID()
            clockSubDeviceUID = try Self.deviceUID(for: clockDeviceID)
            isDeviceScoped = false

            let desc = CATapDescription()
            desc.name = "Resonant Meeting Audio"
            desc.uuid = tapUUID
            desc.isPrivate = true
            desc.muteBehavior = CATapMuteBehavior.unmuted
            desc.isMono = true
            desc.isMixdown = true
            desc.isExclusive = false
            desc.bundleIDs = bundles
            desc.isProcessRestoreEnabled = true
            tapDescription = desc
        }

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            _sysContinuation.withLock { $0?.finish(); $0 = nil }
            throw CaptureError.tapCreationFailed(status)
        }

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Resonant System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: clockSubDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: clockSubDeviceUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard status == noErr else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            _sysContinuation.withLock { $0?.finish(); $0 = nil }
            throw CaptureError.aggregateDeviceCreationFailed(status)
        }

        let streamDescription = try Self.tapStreamDescription(for: tapID)
        var mutableStreamDescription = streamDescription
        guard let format = AVAudioFormat(streamDescription: &mutableStreamDescription) else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            _sysContinuation.withLock { $0?.finish(); $0 = nil }
            throw CaptureError.invalidTapFormat
        }

        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            callbackQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleInputData(inInputData, format: format)
        }
        guard status == noErr, let ioProcID else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            _sysContinuation.withLock { $0?.finish(); $0 = nil }
            throw CaptureError.ioProcCreationFailed(status)
        }

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            _sysContinuation.withLock { $0?.finish(); $0 = nil }
            throw CaptureError.startFailed(status)
        }

        let finalTapID = tapID
        let finalAggregateDeviceID = aggregateDeviceID
        _tapID.withLock { $0 = finalTapID }
        _aggregateDeviceID.withLock { $0 = finalAggregateDeviceID }
        _ioProcID.withLock { $0 = ioProcID }
        _sampleCount.withLock { $0 = 0 }

        let resolvedTransport = MeetingAudioTransportInfo.transport(for: clockDeviceID)
        let clockName = MeetingAudioTransportInfo.deviceName(for: clockDeviceID) ?? "unknown"
        let scopeLabel = isDeviceScoped ? "device" : "process"
        Self.logger.info("System audio capture started (format: \(format.sampleRate)Hz, \(format.channelCount)ch, scope: \(scopeLabel, privacy: .public), clock: \(clockName, privacy: .public))")

        return CaptureStreams(
            systemAudio: sysStream,
            resolvedDeviceTransport: resolvedTransport,
            isDeviceScoped: isDeviceScoped
        )
    }

    /// Finish the async stream so consumers exit their for-await loop.
    func finishStream() {
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
    }

    /// Registers a listener on `kAudioHardwarePropertyDefaultOutputDevice`. The block
    /// is invoked on `callbackQueue` when the system's default output changes — callers
    /// must hop to MainActor before mutating engine state.
    /// Idempotent: replacing the previous listener if one exists.
    func startObservingDefaultOutputChanges(onChange: @Sendable @escaping () -> Void) {
        stopObservingDefaultOutputChanges()

        var address = Self.propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            callbackQueue,
            block
        )
        if status == noErr {
            _defaultOutputListener.withLock { $0 = block }
        } else {
            Self.logger.error("Failed to add default-output listener: \(status)")
        }
    }

    func stopObservingDefaultOutputChanges() {
        let block = _defaultOutputListener.withLock { state -> AudioObjectPropertyListenerBlock? in
            let current = state
            state = nil
            return current
        }
        guard let block else { return }
        var address = Self.propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            callbackQueue,
            block
        )
    }

    func stop() async {
        stopObservingDefaultOutputChanges()
        finishStream()

        let aggregateDeviceID = _aggregateDeviceID.withLock { state -> AudioObjectID in
            let current = state
            state = AudioObjectID(kAudioObjectUnknown)
            return current
        }
        let ioProcID = _ioProcID.withLock { state -> AudioDeviceIOProcID? in
            let current = state
            state = nil
            return current
        }
        let tapID = _tapID.withLock { state -> AudioObjectID in
            let current = state
            state = AudioObjectID(kAudioObjectUnknown)
            return current
        }

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }

        _audioLevel.withLock { $0 = 0 }
        _sampleCount.withLock { $0 = 0 }

        Self.logger.info("System audio capture stopped")
    }

    // MARK: - IO Callback

    private func handleInputData(
        _ inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let streamDescription = format.streamDescription
        let bytesPerFrame = Int(streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, let firstBuffer = sourceBuffers.first else { return }

        let frameCount = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            return
        }
        pcmBuffer.frameLength = frameCount

        let destinationBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        guard destinationBuffers.count == sourceBuffers.count else { return }

        for index in 0..<sourceBuffers.count {
            let source = sourceBuffers[index]
            let copySize = min(
                Int(source.mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            guard copySize > 0,
                  let sourceData = source.mData,
                  let destinationData = destinationBuffers[index].mData
            else {
                continue
            }

            memcpy(destinationData, sourceData, copySize)
            destinationBuffers[index].mDataByteSize = UInt32(copySize)
        }

        Self.applyGain(to: pcmBuffer)

        let rms = Self.normalizedRMS(from: pcmBuffer)
        _audioLevel.withLock { $0 = min(rms * 25, 1.0) }

        let count = _sampleCount.withLock { state -> Int in
            state += 1
            return state
        }
        if count <= 3 {
            Self.logger.debug("System audio buffer #\(count): frames=\(frameCount) sr=\(streamDescription.pointee.mSampleRate) ch=\(streamDescription.pointee.mChannelsPerFrame)")
        }

        _ = _sysContinuation.withLock { $0?.yield(pcmBuffer) }
    }

    // MARK: - CoreAudio Helpers

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw CaptureError.noOutputDevice
        }
        return deviceID
    }

    /// Returns the first built-in output device. Used as a stable clock source
    /// (aggregate device `mainSubDeviceKey`) for process-scoped taps so the IO
    /// callback keeps firing regardless of what physical output the user is using.
    /// Falls back to the current default output if no built-in device is present.
    static func builtInOutputDeviceID() throws -> AudioDeviceID {
        var address = propertyAddress(selector: kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else {
            return try defaultOutputDeviceID()
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices
        )
        guard status == noErr else {
            return try defaultOutputDeviceID()
        }

        for deviceID in devices {
            var streamAddress = propertyAddress(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioDevicePropertyScopeOutput
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            if MeetingAudioTransportInfo.transport(for: deviceID) == .builtIn {
                return deviceID
            }
        }

        Self.logger.warning("No built-in output device found; falling back to default output")
        return try defaultOutputDeviceID()
    }

    private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var address = propertyAddress(selector: kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &uid
        )

        guard status == noErr, let uid else {
            throw CaptureError.outputDeviceUIDUnavailable(status)
        }
        return uid.takeRetainedValue() as String
    }

    private static func tapStreamDescription(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(selector: kAudioTapPropertyFormat)
        var streamDescription = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &dataSize,
            &streamDescription
        )

        guard status == noErr else {
            throw CaptureError.tapFormatUnavailable(status)
        }
        return streamDescription
    }

    // MARK: - Gain

    /// Applies `systemAudioGainLinear` to the buffer in-place with saturation clamping.
    /// Compensates for Apple's multi-stream output attenuation bug on devices like
    /// 4-pair USB audio interfaces (~12 dB of otherwise-silent signal).
    private static func applyGain(to buffer: AVAudioPCMBuffer) {
        let gain = systemAudioGainLinear
        guard gain != 1.0, buffer.frameLength > 0 else { return }
        let frameLength = vDSP_Length(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))

        if let channelData = buffer.floatChannelData {
            var gainMut = gain
            var low: Float = -1.0
            var high: Float = 1.0
            let planeCount = buffer.format.isInterleaved ? 1 : channelCount
            let planeLength = buffer.format.isInterleaved
                ? frameLength * vDSP_Length(channelCount)
                : frameLength
            for plane in 0..<planeCount {
                let ptr = channelData[plane]
                vDSP_vsmul(ptr, 1, &gainMut, ptr, 1, planeLength)
                vDSP_vclip(ptr, 1, &low, &high, ptr, 1, planeLength)
            }
            return
        }

        if let channelData = buffer.int16ChannelData {
            let planeCount = buffer.format.isInterleaved ? 1 : channelCount
            let planeLength = buffer.format.isInterleaved
                ? Int(frameLength) * channelCount
                : Int(frameLength)
            var gainMut = gain
            var low = Float(Int16.min)
            var high = Float(Int16.max)
            withUnsafeTemporaryAllocation(of: Float.self, capacity: planeLength) { scratch in
                guard let base = scratch.baseAddress else { return }
                let length = vDSP_Length(planeLength)
                for plane in 0..<planeCount {
                    let ptr = channelData[plane]
                    vDSP_vflt16(ptr, 1, base, 1, length)
                    vDSP_vsmul(base, 1, &gainMut, base, 1, length)
                    vDSP_vclip(base, 1, &low, &high, base, 1, length)
                    vDSP_vfix16(base, 1, ptr, 1, length)
                }
            }
            return
        }

        if let channelData = buffer.int32ChannelData {
            let planeCount = buffer.format.isInterleaved ? 1 : channelCount
            let planeLength = buffer.format.isInterleaved
                ? Int(frameLength) * channelCount
                : Int(frameLength)
            var gainMut = gain
            var low = Float(Int32.min)
            var high = Float(Int32.max)
            withUnsafeTemporaryAllocation(of: Float.self, capacity: planeLength) { scratch in
                guard let base = scratch.baseAddress else { return }
                let length = vDSP_Length(planeLength)
                for plane in 0..<planeCount {
                    let ptr = channelData[plane]
                    vDSP_vflt32(ptr, 1, base, 1, length)
                    vDSP_vsmul(base, 1, &gainMut, base, 1, length)
                    vDSP_vclip(base, 1, &low, &high, base, 1, length)
                    vDSP_vfix32(base, 1, ptr, 1, length)
                }
            }
            return
        }
    }

    // MARK: - RMS Calculation

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    return channelData[0][(frame * channelCount) + channel]
                }
                return channelData[channel][frame]
            }
        }

        if let channelData = buffer.int16ChannelData {
            let scale: Float = 1 / Float(Int16.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    return Float(channelData[0][(frame * channelCount) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
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

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case noOutputDevice
        case outputDeviceUIDUnavailable(OSStatus)
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case tapFormatUnavailable(OSStatus)
        case invalidTapFormat
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)
        case emptyProcessScope
        case bundleIDsUnavailable

        var errorDescription: String? {
            switch self {
            case .noOutputDevice:
                "No audio output device is currently available."
            case .outputDeviceUIDUnavailable(let status):
                "Unable to inspect the system output device (OSStatus \(status))."
            case .tapCreationFailed(let status):
                "System audio capture could not start. Enable System Audio Recording for Resonant in System Settings > Privacy & Security (OSStatus \(status))."
            case .aggregateDeviceCreationFailed(let status):
                "Unable to create the Core Audio aggregate device (OSStatus \(status))."
            case .tapFormatUnavailable(let status):
                "Unable to inspect the system audio tap format (OSStatus \(status))."
            case .invalidTapFormat:
                "System audio capture produced an unsupported audio format."
            case .ioProcCreationFailed(let status):
                "Unable to create the system audio IO callback (OSStatus \(status))."
            case .startFailed(let status):
                "Unable to start system audio capture (OSStatus \(status))."
            case .emptyProcessScope:
                "Process-scoped capture requires at least one process or bundle identifier."
            case .bundleIDsUnavailable:
                "Bundle-ID based process taps require macOS 26 or later."
            }
        }
    }
}
