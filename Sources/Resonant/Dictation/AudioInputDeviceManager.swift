import AVFoundation
import CoreAudio
import Observation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isSystemDefault: Bool
    let isBuiltIn: Bool
}

@MainActor
@Observable
final class AudioInputDeviceManager {

    private(set) var devices: [AudioInputDevice] = []

    /// Fires on the main actor whenever the system reports a hardware change
    /// (USB mic plugged/unplugged, Bluetooth connect/disconnect, default input switch).
    /// Subscribers can invalidate cached device handles or warm capture sessions.
    var onHardwareChange: (() -> Void)?

    private var listenersInstalled = false
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        installHardwareListeners()
    }

    func refresh() {
        devices = Self.availableDevices()
    }

    private func installHardwareListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.onHardwareChange?()
            }
        }

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            nil,
            block
        )
        devicesListener = block

        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr,
            nil,
            block
        )
        defaultInputListener = block
    }


    func containsDevice(with uid: String?) -> Bool {
        guard let uid else { return true }
        return devices.contains(where: { $0.id == uid })
    }

    func device(with uid: String?) -> AudioInputDevice? {
        guard let uid else { return nil }
        return devices.first(where: { $0.id == uid })
    }

    func firstNonBuiltInDevice(excluding uid: String?) -> AudioInputDevice? {
        devices.first(where: { !$0.isBuiltIn && $0.id != uid })
    }

    func effectiveDevice(for uid: String?) -> AudioInputDevice? {
        if let uid,
           let match = devices.first(where: { $0.id == uid }) {
            return match
        }

        if let systemDefault = devices.first(where: \.isSystemDefault) {
            return systemDefault
        }

        return devices.first
    }

    nonisolated static func resolveCaptureDevice(uid: String?) -> AVCaptureDevice? {
        let devices = captureDevices()
        if let uid,
           let match = devices.first(where: { $0.uniqueID == uid }) {
            return match
        }

        return AVCaptureDevice.default(for: .audio) ?? devices.first
    }

    private nonisolated static func availableDevices() -> [AudioInputDevice] {
        let defaultUID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let builtInUIDs = builtInInputDeviceUIDs()

        return captureDevices().map { device in
            AudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isSystemDefault: device.uniqueID == defaultUID,
                isBuiltIn: builtInUIDs.contains(device.uniqueID)
            )
        }
    }

    private nonisolated static func captureDevices() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )

        return discoverySession.devices.sorted {
            $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
        }
    }

    /// CoreAudio reports the laptop's internal microphone array via
    /// `kAudioDevicePropertyTransportType == kAudioDeviceTransportTypeBuiltIn`.
    /// More reliable than uniqueID prefix matching, which varies across hardware generations.
    private nonisolated static func builtInInputDeviceUIDs() -> Set<String> {
        var uids = Set<String>()
        for deviceID in inputCapableDeviceIDs() {
            guard transportType(for: deviceID) == kAudioDeviceTransportTypeBuiltIn,
                  let uid = deviceUID(for: deviceID) else {
                continue
            }
            uids.insert(uid)
        }
        return uids
    }

    private nonisolated static func inputCapableDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size
        ) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }
        return ids.filter { hasInputStreams($0) }
    }

    private nonisolated static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private nonisolated static func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return nil
        }
        return transport
    }

    private nonisolated static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var cfUID: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfUID else { return nil }
        return cfUID as String
    }
}
