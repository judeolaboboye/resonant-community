import CoreAudio
import Foundation
import os

protocol MeetingAudioSignalSource: Sendable {
    var signals: AsyncStream<Bool> { get }
    func currentValue() -> Bool
}

/// Observes whether any physical input device is currently running.
/// This reads CoreAudio device state only; it does not capture audio samples.
final class CoreAudioMeetingAudioSignalSource: MeetingAudioSignalSource, @unchecked Sendable {

    /// Identifies `listenerQueue` so `deinit` can detect when it is already
    /// executing on that queue and avoid a re-entrant `sync` (libdispatch traps
    /// on `dispatch_sync` called on a queue already owned by the current thread).
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    private let listenerQueue = DispatchQueue(label: "com.resonance.resonant.meeting-audio-signal")
    private let log = Logger.resonant("MeetingAudioSignal")
    private var deviceIDs: [AudioDeviceID] = []
    private var continuation: AsyncStream<Bool>.Continuation?
    private var lastEmittedValue = false
    private var isObservingSystemDevices = false
    private var pollTimer: DispatchSourceTimer?

    let signals: AsyncStream<Bool>

    init() {
        var stream: AsyncStream<Bool>!
        var capturedContinuation: AsyncStream<Bool>.Continuation!

        stream = AsyncStream<Bool> { continuation in
            capturedContinuation = continuation
        }

        signals = stream

        listenerQueue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))

        listenerQueue.sync {
            continuation = capturedContinuation
            installSystemDeviceListener()
            refreshObservedDevices(emitIfChanged: false)
            lastEmittedValue = deviceIDs.contains { Self.isDeviceRunning($0) }
            startPollingFallback()
        }
    }

    deinit {
        // `deinit` can be reached from a `[weak self]` block already running on
        // `listenerQueue` (e.g. the poll timer dropping the last strong ref). In
        // that case `listenerQueue.sync` would re-enter the queue we already own
        // and trap, so run the teardown inline; otherwise serialize as usual.
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) {
            tearDown()
        } else {
            listenerQueue.sync { tearDown() }
        }
    }

    private func tearDown() {
        pollTimer?.cancel()
        pollTimer = nil
        removeSystemDeviceListener()
        removeRunningListeners(for: deviceIDs)
        deviceIDs.removeAll()
        continuation?.finish()
        continuation = nil
    }

    func currentValue() -> Bool {
        listenerQueue.sync {
            refreshObservedDevices(emitIfChanged: true)
            return lastEmittedValue
        }
    }

    private static let listenerCallback: AudioObjectPropertyListenerProc = {
        _, numberAddresses, addresses, clientData in
        guard let clientData else { return kAudioHardwareNoError }
        let source = Unmanaged<CoreAudioMeetingAudioSignalSource>.fromOpaque(clientData).takeUnretainedValue()
        let changedSelectors = (0..<Int(numberAddresses)).map { addresses[$0].mSelector }
        if changedSelectors.contains(kAudioHardwarePropertyDevices) {
            source.refreshDevicesAndEmit()
        } else {
            source.checkAndEmit()
        }
        return kAudioHardwareNoError
    }

    private func refreshDevicesAndEmit() {
        listenerQueue.async { [weak self] in
            self?.refreshObservedDevices(emitIfChanged: true)
        }
    }

    private func checkAndEmit() {
        listenerQueue.async { [weak self] in
            guard let self else { return }
            let anyRunning = self.deviceIDs.contains { Self.isDeviceRunning($0) }
            guard anyRunning != self.lastEmittedValue else { return }
            self.lastEmittedValue = anyRunning
            self.continuation?.yield(anyRunning)
        }
    }

    private func refreshObservedDevices(emitIfChanged: Bool) {
        let refreshedDeviceIDs = Self.physicalInputDeviceIDs()
        let oldSet = Set(deviceIDs)
        let newSet = Set(refreshedDeviceIDs)

        let removed = deviceIDs.filter { !newSet.contains($0) }
        let added = refreshedDeviceIDs.filter { !oldSet.contains($0) }

        removeRunningListeners(for: removed)
        addRunningListeners(for: added)
        deviceIDs = refreshedDeviceIDs

        let anyRunning = deviceIDs.contains { Self.isDeviceRunning($0) }
        guard emitIfChanged, anyRunning != lastEmittedValue else {
            lastEmittedValue = anyRunning
            return
        }
        lastEmittedValue = anyRunning
        continuation?.yield(anyRunning)
    }

    private func startPollingFallback() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: listenerQueue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.refreshObservedDevices(emitIfChanged: true)
        }
        pollTimer = timer
        timer.resume()
    }

    private func installSystemDeviceListener() {
        guard !isObservingSystemDevices else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.listenerCallback,
            selfPtr
        )
        if status == noErr {
            isObservingSystemDevices = true
        } else {
            log.warning("system_device_listener_add_failed status=\(status)")
        }
    }

    private func removeSystemDeviceListener() {
        guard isObservingSystemDevices else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.listenerCallback,
            selfPtr
        )
        isObservingSystemDevices = false
    }

    private func addRunningListeners(for deviceIDs: [AudioDeviceID]) {
        for deviceID in deviceIDs {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            let status = AudioObjectAddPropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
            if status != noErr {
                log.warning("running_listener_add_failed device=\(deviceID) status=\(status)")
            }
        }
    }

    private func removeRunningListeners(for deviceIDs: [AudioDeviceID]) {
        for deviceID in deviceIDs {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            AudioObjectRemovePropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
        }
    }

    private static func physicalInputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.filter { deviceID in
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)
            return status == noErr && inputSize > 0
        }
    }

    private static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }
}
