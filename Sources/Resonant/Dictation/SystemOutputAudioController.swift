import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class SystemOutputAudioController {

    private enum Error: Swift.Error {
        case unsupportedOS
    }

    private struct AttenuatedState {
        let deviceID: AudioDeviceID
        let originalVolume: Float32
        let generation: Int
    }

    nonisolated private static let duckedVolume: Float32 = 0.15

    private let defaultOutputDeviceIDProvider: () throws -> AudioDeviceID
    private let getVolume: (AudioDeviceID) -> Float32?
    private let setVolume: (AudioDeviceID, Float32) -> Bool
    private let workQueue = DispatchQueue(label: "com.resonance.resonant.system-output-audio")
    private var attenuatedState: AttenuatedState?
    private var duckingGeneration = 0
    private var duckingInFlight = false
    private var duckingRequested = false

    init() {
        self.defaultOutputDeviceIDProvider = Self.defaultOutputDeviceID
        self.getVolume = Self.outputVolume
        self.setVolume = Self.setOutputVolume
    }

    init(
        defaultOutputDeviceIDProvider: @escaping () throws -> AudioDeviceID,
        getVolume: @escaping (AudioDeviceID) -> Float32?,
        setVolume: @escaping (AudioDeviceID, Float32) -> Bool
    ) {
        self.defaultOutputDeviceIDProvider = defaultOutputDeviceIDProvider
        self.getVolume = getVolume
        self.setVolume = setVolume
    }

    func beginDuckingIfNeeded(enabled: Bool) {
        guard enabled else { return }
        duckingRequested = true
        guard attenuatedState == nil, !duckingInFlight else { return }
        duckingGeneration += 1
        duckingInFlight = true
        let generation = duckingGeneration
        let defaultOutputDeviceIDProvider = self.defaultOutputDeviceIDProvider
        let getVolume = self.getVolume
        let setVolume = self.setVolume

        workQueue.async {
            guard let deviceID = try? defaultOutputDeviceIDProvider(),
                  let originalVolume = getVolume(deviceID)
            else {
                Task { @MainActor in
                    self.finishDuckingAttempt(generation: generation)
                }
                return
            }

            let targetVolume = min(originalVolume, Self.duckedVolume)
            guard targetVolume < originalVolume else {
                Task { @MainActor in
                    self.finishDuckingAttempt(generation: generation)
                }
                return
            }
            guard setVolume(deviceID, targetVolume) else {
                Task { @MainActor in
                    self.finishDuckingAttempt(generation: generation)
                }
                return
            }

            Task { @MainActor in
                self.finishAppliedDuckingAttempt(
                    generation: generation,
                    deviceID: deviceID,
                    originalVolume: originalVolume,
                    setVolume: setVolume
                )
            }
        }
    }

    func endDuckingIfNeeded() {
        duckingRequested = false
        duckingGeneration += 1
        duckingInFlight = false
        guard let attenuatedState else { return }
        self.attenuatedState = nil
        let setVolume = self.setVolume
        workQueue.async {
            _ = setVolume(attenuatedState.deviceID, attenuatedState.originalVolume)
        }
    }

    private func finishAppliedDuckingAttempt(
        generation: Int,
        deviceID: AudioDeviceID,
        originalVolume: Float32,
        setVolume: @escaping (AudioDeviceID, Float32) -> Bool
    ) {
        finishDuckingAttempt(generation: generation)

        guard duckingRequested else {
            restoreVolume(deviceID: deviceID, volume: originalVolume, setVolume: setVolume)
            return
        }

        guard let currentState = attenuatedState else {
            attenuatedState = AttenuatedState(
                deviceID: deviceID,
                originalVolume: originalVolume,
                generation: generation
            )
            return
        }

        guard currentState.deviceID != deviceID else { return }
        guard generation >= currentState.generation else {
            restoreVolume(deviceID: deviceID, volume: originalVolume, setVolume: setVolume)
            return
        }

        attenuatedState = AttenuatedState(
            deviceID: deviceID,
            originalVolume: originalVolume,
            generation: generation
        )
        restoreVolume(
            deviceID: currentState.deviceID,
            volume: currentState.originalVolume,
            setVolume: setVolume
        )
    }

    private func finishDuckingAttempt(generation: Int) {
        if duckingGeneration == generation {
            duckingInFlight = false
        }
    }

    private func restoreVolume(
        deviceID: AudioDeviceID,
        volume: Float32,
        setVolume: @escaping (AudioDeviceID, Float32) -> Bool
    ) {
        workQueue.async {
            _ = setVolume(deviceID, volume)
        }
    }

    private static func defaultOutputDeviceID() throws -> AudioDeviceID {
        guard #available(macOS 14.2, *) else {
            throw Error.unsupportedOS
        }
        return try SystemAudioCapture.defaultOutputDeviceID()
    }

    private static func outputVolume(deviceID: AudioDeviceID) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &volume
        )
        guard status == noErr else { return nil }
        return volume
    }

    private static func setOutputVolume(deviceID: AudioDeviceID, volume: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var clampedVolume = min(max(volume, 0), 1)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &clampedVolume
        )
        return status == noErr
    }
}
