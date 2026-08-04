import CoreMediaIO
import Foundation
import os

protocol MeetingCameraSignalSource: Sendable {
    var signals: AsyncStream<Bool> { get }
    func currentValue() -> Bool
}

/// Observes whether any video device is currently running (camera active).
/// Reads CoreMediaIO device state only; does not capture video.
final class CoreMediaIOMeetingCameraSignalSource: MeetingCameraSignalSource, @unchecked Sendable {

    /// Identifies `listenerQueue` so `deinit` can detect when it is already
    /// executing on that queue and avoid a re-entrant `sync` (libdispatch traps
    /// on `dispatch_sync` called on a queue already owned by the current thread).
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    private let listenerQueue = DispatchQueue(label: "com.resonance.resonant.meeting-camera-signal")
    private let log = Logger.resonant("MeetingCameraSignal")
    private var deviceIDs: [CMIOObjectID] = []
    private var listenerBlocks: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var systemDeviceListenerBlock: CMIOObjectPropertyListenerBlock?
    private var continuation: AsyncStream<Bool>.Continuation?
    private var lastEmittedValue = false
    private var pollTimer: DispatchSourceTimer?

    let signals: AsyncStream<Bool>

    init() {
        Self.enableDALDevices()

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

    private func checkAndEmit() {
        listenerQueue.async { [weak self] in
            self?.emitCurrentValueIfChanged()
        }
    }

    private func refreshDevicesAndEmit() {
        listenerQueue.async { [weak self] in
            self?.refreshObservedDevices(emitIfChanged: true)
        }
    }

    private func emitCurrentValueIfChanged() {
        let anyRunning = deviceIDs.contains { Self.isDeviceRunning($0) }
        guard anyRunning != self.lastEmittedValue else { return }
        self.lastEmittedValue = anyRunning
        self.continuation?.yield(anyRunning)
    }

    private func refreshObservedDevices(emitIfChanged: Bool) {
        let refreshedDeviceIDs = Self.videoDeviceIDs()
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
        guard systemDeviceListenerBlock == nil else { return }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let listenerBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevicesAndEmit()
        }
        let status = CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            listenerQueue,
            listenerBlock
        )
        if status == noErr {
            systemDeviceListenerBlock = listenerBlock
        } else {
            log.warning("system_device_listener_add_failed status=\(status)")
        }
    }

    private func removeSystemDeviceListener() {
        guard let listenerBlock = systemDeviceListenerBlock else { return }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectRemovePropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            listenerQueue,
            listenerBlock
        )
        systemDeviceListenerBlock = nil
    }

    private func addRunningListeners(for deviceIDs: [CMIOObjectID]) {
        for deviceID in deviceIDs {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )

            let listenerBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.checkAndEmit()
            }
            let status = CMIOObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, listenerBlock)
            if status == noErr {
                listenerBlocks[deviceID] = listenerBlock
            } else {
                log.warning("running_listener_add_failed device=\(deviceID) status=\(status)")
            }
        }
    }

    private func removeRunningListeners(for deviceIDs: [CMIOObjectID]) {
        for deviceID in deviceIDs {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            if let listenerBlock = listenerBlocks.removeValue(forKey: deviceID) {
                CMIOObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, listenerBlock)
            }
        }
    }

    // MARK: - CoreMediaIO Helpers

    /// Allow access to DAL (Device Abstraction Layer) virtual devices.
    private static func enableDALDevices() {
        var property = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &property,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    private static func videoDeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var deviceIDs = [CMIOObjectID](repeating: 0, count: count)
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.filter { hasVideoStreams($0) }
    }

    private static func hasVideoStreams(_ deviceID: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        let status = CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    private static func isDeviceRunning(_ deviceID: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var isRunning: UInt32 = 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(deviceID, &address, 0, nil, dataSize, &dataUsed, &isRunning)
        return status == noErr && isRunning != 0
    }
}
