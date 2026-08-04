import AppKit
import CoreAudio
import Foundation
import os

/// Resolves running meeting apps to CoreAudio process `AudioObjectID`s and publishes
/// the set whenever it changes. Used by `SystemAudioCapture` on macOS 14.2-25.x to
/// build process-scoped taps. On macOS 26+ we hand bundle IDs directly to
/// `CATapDescription.bundleIDs` + `isProcessRestoreEnabled`, so this resolver is
/// only needed on earlier systems.
@MainActor
final class MeetingAudioProcessResolver {

    /// Bundle IDs that can host meeting audio: native meeting apps plus every
    /// browser known to `BrowserCatalog` (web conferencing in Meet, Zoom Web,
    /// Teams Web, Whereby, etc.). Sourced from the two shared catalogs so new
    /// browsers / apps are picked up without changes here.
    nonisolated static let knownMeetingBundleIDs: [String] = {
        let natives = MeetingContextDetector.nativeMeetingBundleIDs
        let browsers = BrowserCatalog.allBundleIDs
        return Array(natives).map { $0.lowercased() } + browsers
    }()

    struct ResolvedProcesses: Sendable, Equatable {
        let ids: [AudioObjectID]
        let bundleIDs: [String]
    }

    private(set) var current: ResolvedProcesses = ResolvedProcesses(ids: [], bundleIDs: [])

    /// Called on MainActor when the resolved set changes. Subscribers should restart
    /// the active capture against the new PID list.
    var onChange: ((ResolvedProcesses) -> Void)?

    private let log = Logger.resonant("MeetingAudioProcessResolver")
    private let targetBundleIDs: Set<String>

    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private static let debounceInterval: Duration = .milliseconds(500)

    init(bundleIDs: [String] = MeetingAudioProcessResolver.knownMeetingBundleIDs) {
        self.targetBundleIDs = Set(bundleIDs.map { $0.lowercased() })
    }

    deinit {
        // Defensive cleanup if the owner releases us without calling stop().
        // NSWorkspace.notificationCenter.removeObserver is thread-safe and
        // observers stored as NSObjectProtocol can be removed off-MainActor.
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
        }
        debounceTask?.cancel()
    }

    func start() {
        refresh()

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleDebounced() }
        }
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleDebounced() }
        }
    }

    func stop() {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
        }
        launchObserver = nil
        terminateObserver = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func scheduleDebounced() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard let self, !Task.isCancelled else { return }
            self.refresh()
        }
    }

    private func refresh() {
        let running = NSWorkspace.shared.runningApplications

        var pids: [(bundleID: String, pid: pid_t)] = []
        for app in running {
            guard let bid = app.bundleIdentifier?.lowercased(),
                  targetBundleIDs.contains(bid),
                  app.processIdentifier > 0
            else { continue }
            pids.append((bid, app.processIdentifier))
        }

        var ids: [AudioObjectID] = []
        var bundleIDs: [String] = []
        for entry in pids {
            if let objectID = Self.translatePIDToProcessObject(entry.pid),
               objectID != AudioObjectID(kAudioObjectUnknown) {
                ids.append(objectID)
                bundleIDs.append(entry.bundleID)
            } else {
                // Per AudioHardware.h: translate returns kAudioObjectUnknown for
                // processes that have not yet registered with CoreAudio (i.e., the
                // process exists but hasn't played audio). The bring-up watcher in
                // MeetingTranscriptionEngine retries when new apps launch.
                log.debug("No CoreAudio process object yet for \(entry.bundleID, privacy: .public) pid=\(entry.pid)")
            }
        }

        let next = ResolvedProcesses(ids: ids, bundleIDs: bundleIDs)
        guard next != current else { return }
        current = next
        onChange?(next)
    }

    private static func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutablePID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = withUnsafePointer(to: &mutablePID) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &dataSize,
                &objectID
            )
        }
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return objectID
    }
}
