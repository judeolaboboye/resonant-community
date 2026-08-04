import AppKit
import ApplicationServices
import Foundation
import os

private final class BrowserURLObserverPidContext: @unchecked Sendable {
    let pid: pid_t
    let ownerRef: Unmanaged<BrowserURLChangeObserver>

    init(pid: pid_t, ownerRef: Unmanaged<BrowserURLChangeObserver>) {
        self.pid = pid
        self.ownerRef = ownerRef
    }
}

private struct BrowserURLObserverRegistration: @unchecked Sendable {
    let pid: pid_t
    let observer: AXObserver
    let appElement: AXUIElement
    let context: BrowserURLObserverPidContext
    let focusedWindowElement: AXUIElement?
}

private enum BrowserURLObserverRegistrationResult: @unchecked Sendable {
    case success(BrowserURLObserverRegistration)
    case failure(pid: pid_t, bundleIdentifier: String?, status: AXError)
}

/// Push-based browser URL-change detection. Subscribes to AXObserver notifications
/// on every running browser process so navigation fires an event instantly instead
/// of waiting for a polling timer or an app activation.
@MainActor
final class BrowserURLChangeObserver {

    var onBrowserEvent: ((NSRunningApplication) -> Void)?

    private let log = Logger.resonant("BrowserURLObserver")

    private struct Entry {
        let pid: pid_t
        let observer: AXObserver
        let appElement: AXUIElement
        let context: BrowserURLObserverPidContext
        var focusedWindowElement: AXUIElement?
        var debounceTask: Task<Void, Never>?
    }

    private var entries: [pid_t: Entry] = [:]
    private var pendingRegistrations: Set<pid_t> = []
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var registrationGeneration = 0

    private static let debounceNanos: UInt64 = 200_000_000
    private static let registrationQueue = DispatchQueue(
        label: "com.resonance.resonant.browser-url-observer.registration",
        qos: .utility
    )

    func start() {
        guard launchObserver == nil else { return }
        log.info("start()")
        registrationGeneration += 1

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.enqueueRegisterIfBrowser(app)
            }
        }

        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.unregister(pid: app.processIdentifier)
            }
        }

        for app in NSWorkspace.shared.runningApplications {
            enqueueRegisterIfBrowser(app)
        }
    }

    func stop() {
        registrationGeneration += 1
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
        pendingRegistrations.removeAll()
        for pid in Array(entries.keys) {
            unregister(pid: pid)
        }
    }

    private func enqueueRegisterIfBrowser(_ app: NSRunningApplication) {
        guard BrowserCatalog.isBrowser(app.bundleIdentifier) else { return }
        let pid = app.processIdentifier
        guard pid > 0, entries[pid] == nil, !pendingRegistrations.contains(pid) else { return }

        pendingRegistrations.insert(pid)
        let generation = registrationGeneration
        let bundleIdentifier = app.bundleIdentifier
        let ownerRef = Unmanaged.passUnretained(self)
        Self.registrationQueue.async {
            let result = Self.makeRegistration(
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                ownerRef: ownerRef
            )
            Task { @MainActor in
                ownerRef.takeUnretainedValue().completeRegistration(result, generation: generation)
            }
        }
    }

    private nonisolated static func makeRegistration(
        pid: pid_t,
        bundleIdentifier: String?,
        ownerRef: Unmanaged<BrowserURLChangeObserver>
    ) -> BrowserURLObserverRegistrationResult {
        let appElement = AXUIElementCreateApplication(pid)
        var axObserver: AXObserver?
        let createStatus = AXObserverCreate(pid, Self.axCallback, &axObserver)
        guard createStatus == .success, let observer = axObserver else {
            return .failure(pid: pid, bundleIdentifier: bundleIdentifier, status: createStatus)
        }

        let context = BrowserURLObserverPidContext(pid: pid, ownerRef: ownerRef)
        let refcon = Unmanaged.passUnretained(context).toOpaque()

        let appLevelNotifications: [String] = [
            kAXFocusedWindowChangedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXMainWindowChangedNotification,
            kAXTitleChangedNotification,
        ]
        for name in appLevelNotifications {
            _ = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
        }

        var focusedWindowElement: AXUIElement?
        if let window = focusedWindow(of: appElement) {
            _ = AXObserverAddNotification(
                observer,
                window,
                kAXTitleChangedNotification as CFString,
                refcon
            )
            focusedWindowElement = window
        }

        return .success(BrowserURLObserverRegistration(
            pid: pid,
            observer: observer,
            appElement: appElement,
            context: context,
            focusedWindowElement: focusedWindowElement
        ))
    }

    private func completeRegistration(
        _ result: BrowserURLObserverRegistrationResult,
        generation: Int
    ) {
        switch result {
        case .success(let registration):
            guard generation == registrationGeneration,
                  pendingRegistrations.remove(registration.pid) != nil,
                  entries[registration.pid] == nil else {
                return
            }

            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(registration.observer),
                .defaultMode
            )

            entries[registration.pid] = Entry(
                pid: registration.pid,
                observer: registration.observer,
                appElement: registration.appElement,
                context: registration.context,
                focusedWindowElement: registration.focusedWindowElement,
                debounceTask: nil
            )
            log.info("registered pid=\(registration.pid)")
        case .failure(let pid, let bundleIdentifier, let status):
            pendingRegistrations.remove(pid)
            guard generation == registrationGeneration else { return }
            log.error("AXObserverCreate failed for pid=\(pid) bundle=\(bundleIdentifier ?? "nil", privacy: .public) status=\(status.rawValue)")
        }
    }

    private func unregister(pid: pid_t) {
        pendingRegistrations.remove(pid)
        guard let entry = entries.removeValue(forKey: pid) else { return }
        entry.debounceTask?.cancel()
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(entry.observer),
            .defaultMode
        )
    }

    private nonisolated static func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success, let raw = value,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    fileprivate func handleAXEvent(pid: pid_t, notification: String) {
        log.debug("ax event pid=\(pid) notif=\(notification, privacy: .public)")
        guard var entry = entries[pid] else { return }

        if let newWindow = Self.focusedWindow(of: entry.appElement) {
            let isSameWindow: Bool = {
                guard let current = entry.focusedWindowElement else { return false }
                return CFEqual(current, newWindow)
            }()
            if !isSameWindow {
                if let old = entry.focusedWindowElement {
                    AXObserverRemoveNotification(
                        entry.observer,
                        old,
                        kAXTitleChangedNotification as CFString
                    )
                }
                let refcon = Unmanaged.passUnretained(entry.context).toOpaque()
                _ = AXObserverAddNotification(
                    entry.observer,
                    newWindow,
                    kAXTitleChangedNotification as CFString,
                    refcon
                )
                entry.focusedWindowElement = newWindow
            }
        }

        entry.debounceTask?.cancel()
        entry.debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            guard !Task.isCancelled else { return }
            await self?.fireCallback(pid: pid)
        }
        entries[pid] = entry
    }

    private func fireCallback(pid: pid_t) async {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        log.info("fireCallback pid=\(pid)")
        onBrowserEvent?(app)
    }

    nonisolated private static let axCallback: AXObserverCallback = { _, _, notification, refconPointer in
        guard let refconPointer else { return }
        let ctx = Unmanaged<BrowserURLObserverPidContext>.fromOpaque(refconPointer).takeUnretainedValue()
        let pid = ctx.pid
        let ownerRef = ctx.ownerRef
        let notificationName = notification as String
        Task { @MainActor in
            ownerRef.takeUnretainedValue().handleAXEvent(pid: pid, notification: notificationName)
        }
    }
}
