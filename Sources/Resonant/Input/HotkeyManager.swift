import AppKit
import CoreGraphics
import ApplicationServices
import IOKit.hid
import os

private struct SideSpecificModifierKey {
    let familyFlag: NSEvent.ModifierFlags
    let deviceMask: UInt
    let familyDeviceMask: UInt

    private static let leftControlMask: UInt = 0x0000_0001
    private static let leftShiftMask: UInt = 0x0000_0002
    private static let rightShiftMask: UInt = 0x0000_0004
    private static let leftCommandMask: UInt = 0x0000_0008
    private static let rightCommandMask: UInt = 0x0000_0010
    private static let leftOptionMask: UInt = 0x0000_0020
    private static let rightOptionMask: UInt = 0x0000_0040
    private static let rightControlMask: UInt = 0x0000_2000

    private static let commandFamilyMask = leftCommandMask | rightCommandMask
    private static let shiftFamilyMask = leftShiftMask | rightShiftMask
    private static let optionFamilyMask = leftOptionMask | rightOptionMask
    private static let controlFamilyMask = leftControlMask | rightControlMask

    static let byKeyCode: [UInt16: SideSpecificModifierKey] = [
        54: SideSpecificModifierKey(familyFlag: .command, deviceMask: rightCommandMask, familyDeviceMask: commandFamilyMask),
        55: SideSpecificModifierKey(familyFlag: .command, deviceMask: leftCommandMask, familyDeviceMask: commandFamilyMask),
        56: SideSpecificModifierKey(familyFlag: .shift, deviceMask: leftShiftMask, familyDeviceMask: shiftFamilyMask),
        60: SideSpecificModifierKey(familyFlag: .shift, deviceMask: rightShiftMask, familyDeviceMask: shiftFamilyMask),
        58: SideSpecificModifierKey(familyFlag: .option, deviceMask: leftOptionMask, familyDeviceMask: optionFamilyMask),
        61: SideSpecificModifierKey(familyFlag: .option, deviceMask: rightOptionMask, familyDeviceMask: optionFamilyMask),
        59: SideSpecificModifierKey(familyFlag: .control, deviceMask: leftControlMask, familyDeviceMask: controlFamilyMask),
        62: SideSpecificModifierKey(familyFlag: .control, deviceMask: rightControlMask, familyDeviceMask: controlFamilyMask),
    ]

    static func descriptor(for keyCode: UInt16) -> SideSpecificModifierKey? {
        byKeyCode[keyCode]
    }

    static func isPressed(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool? {
        guard let descriptor = descriptor(for: keyCode) else { return nil }
        guard modifierFlags.contains(descriptor.familyFlag) else { return false }

        let rawValue = modifierFlags.rawValue
        let hasSideSpecificBits = (rawValue & descriptor.familyDeviceMask) != 0
        if hasSideSpecificBits {
            return (rawValue & descriptor.deviceMask) != 0
        }

        return nil
    }

    static func shouldUpdateState(for keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, changedKeyCode: UInt16) -> Bool {
        guard let keyDescriptor = descriptor(for: keyCode) else {
            return keyCode == changedKeyCode
        }

        let changedDescriptor = descriptor(for: changedKeyCode)
        let changedSameFamily = changedDescriptor?.familyFlag == keyDescriptor.familyFlag
        let familyIsUp = !modifierFlags.contains(keyDescriptor.familyFlag)
        let eventHasFamilySideBits = (modifierFlags.rawValue & keyDescriptor.familyDeviceMask) != 0

        if eventHasFamilySideBits || familyIsUp {
            return true
        }

        return changedSameFamily && keyCode == changedKeyCode
    }
}

private final class SpaceChordSuppressionState: @unchecked Sendable {
    private let lock = NSLock()
    private var keyStateProvider: (UInt16) -> Bool = { keyCode in
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
            || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }
    private var observesFn = true
    private var observesRightOption = false
    private var customKeyCodes: Set<UInt16> = []
    private var canSuppressEvents = false
    private var lockChordEnabled = true
    private var suppressingSpaceSequence = false
    private var observedFnDown = false
    private var observedRightOptionDown = false
    private var observedCustomKeyCodesDown: Set<UInt16> = []

    func updateTriggers(_ triggers: [HotkeyTrigger]) {
        lock.lock()
        observesFn = triggers.contains(.fn)
        observesRightOption = triggers.contains(.rightOption)
        customKeyCodes = Set(triggers.compactMap { trigger in
            guard case .custom(let keyCode) = trigger,
                  keyCode != 49,
                  HotkeyTrigger.isAllowedCustomKeyCode(keyCode)
            else { return nil }
            return keyCode
        })
        if !observesFn {
            observedFnDown = false
        }
        if !observesRightOption {
            observedRightOptionDown = false
        }
        observedCustomKeyCodesDown.formIntersection(customKeyCodes)
        lock.unlock()
    }

    func setLockChordEnabled(_ value: Bool) {
        lock.lock()
        lockChordEnabled = value
        if !value {
            suppressingSpaceSequence = false
        }
        lock.unlock()
    }

    func setCanSuppressEvents(_ value: Bool) {
        lock.lock()
        canSuppressEvents = value
        if !value {
            suppressingSpaceSequence = false
        }
        lock.unlock()
    }

    func resetObservedTriggerState() {
        lock.lock()
        observedFnDown = false
        observedRightOptionDown = false
        observedCustomKeyCodesDown.removeAll()
        suppressingSpaceSequence = false
        lock.unlock()
    }

    func observeEvent(eventType: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        guard eventType == .flagsChanged || eventType == .keyDown || eventType == .keyUp else {
            return
        }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))

        lock.lock()
        switch eventType {
        case .flagsChanged:
            if observesFn {
                observedFnDown = modifierFlags.contains(.function)
            }
            if observesRightOption,
               SideSpecificModifierKey.shouldUpdateState(for: 61, modifierFlags: modifierFlags, changedKeyCode: keyCode) {
                observedRightOptionDown = isModifierPressed(
                    modifierFlags: modifierFlags,
                    keyCode: 61
                )
            }
            for customKeyCode in customKeyCodes where KeyCodeNames.isModifierKey(customKeyCode) {
                guard SideSpecificModifierKey.shouldUpdateState(
                    for: customKeyCode,
                    modifierFlags: modifierFlags,
                    changedKeyCode: keyCode
                ) else {
                    continue
                }

                if isModifierPressed(
                    modifierFlags: modifierFlags,
                    keyCode: customKeyCode
                ) {
                    observedCustomKeyCodesDown.insert(customKeyCode)
                } else {
                    observedCustomKeyCodesDown.remove(customKeyCode)
                }
            }
        case .keyDown:
            if observesFn, keyCode == 63 || keyCode == 0xB3 {
                observedFnDown = true
            }
            if observesRightOption, keyCode == 61 {
                observedRightOptionDown = true
            }
            if customKeyCodes.contains(keyCode) {
                observedCustomKeyCodesDown.insert(keyCode)
            }
        case .keyUp:
            if observesFn, keyCode == 63 || keyCode == 0xB3 {
                observedFnDown = false
            }
            if observesRightOption, keyCode == 61 {
                observedRightOptionDown = false
            }
            if customKeyCodes.contains(keyCode) {
                observedCustomKeyCodesDown.remove(keyCode)
            }
        default:
            break
        }
        lock.unlock()
    }

    func anyObservedTriggerDown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedFnDown || observedRightOptionDown || !observedCustomKeyCodesDown.isEmpty
    }

    func requiresActiveSuppression() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let observedTriggerDown = observedFnDown || observedRightOptionDown || !observedCustomKeyCodesDown.isEmpty
        return lockChordEnabled && (observedTriggerDown || suppressingSpaceSequence)
    }

    func observesKeyCode(_ keyCode: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if keyCode == 63 || keyCode == 0xB3 { return observesFn || customKeyCodes.contains(keyCode) }
        if keyCode == 61 { return observesRightOption || customKeyCodes.contains(keyCode) }
        return customKeyCodes.contains(keyCode)
    }

    func shouldSuppressEvent(eventType: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard eventType == .keyDown || eventType == .keyUp, keyCode == 49 else {
            return false
        }

        lock.lock()
        let canSuppressEvents = canSuppressEvents
        let lockChordEnabled = lockChordEnabled
        let suppressingSpaceSequence = suppressingSpaceSequence
        let observedTriggerDown = observedFnDown || observedRightOptionDown || !observedCustomKeyCodesDown.isEmpty
        lock.unlock()

        guard canSuppressEvents, lockChordEnabled else { return false }

        switch eventType {
        case .keyDown:
            if suppressingSpaceSequence {
                return true
            }

            let shouldSuppress = observedTriggerDown

            lock.lock()
            self.suppressingSpaceSequence = shouldSuppress
            lock.unlock()
            return shouldSuppress
        case .keyUp:
            guard suppressingSpaceSequence else { return false }
            lock.lock()
            self.suppressingSpaceSequence = false
            lock.unlock()
            return true
        default:
            return false
        }
    }

#if DEBUG
    func debugSetKeyStateProvider(_ provider: @escaping (UInt16) -> Bool) {
        lock.lock()
        keyStateProvider = provider
        lock.unlock()
    }

    func debugShouldSuppressSpaceEvent(eventType: CGEventType, keyCode: UInt16, triggerPressed: Bool) -> Bool {
        guard eventType == .keyDown || eventType == .keyUp, keyCode == 49 else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        guard lockChordEnabled else { return false }
        observedFnDown = triggerPressed

        switch eventType {
        case .keyDown:
            if suppressingSpaceSequence {
                return true
            }
            suppressingSpaceSequence = triggerPressed
            return triggerPressed
        case .keyUp:
            guard suppressingSpaceSequence else { return false }
            suppressingSpaceSequence = false
            return true
        default:
            return false
        }
    }
#endif

    private func isModifierPressed(
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16,
    ) -> Bool {
        if let pressed = SideSpecificModifierKey.isPressed(
            keyCode: keyCode,
            modifierFlags: modifierFlags
        ) {
            return pressed
        }

        if SideSpecificModifierKey.descriptor(for: keyCode) != nil {
            return keyStateProvider(keyCode)
        }

        switch keyCode {
        case 57:     return modifierFlags.contains(.capsLock)
        case 63:     return modifierFlags.contains(.function)
        default:     return false
        }
    }

}

/// Detects FN (Globe) or Right Option key press/release via CGEventTap.
/// Hold mode starts immediately on trigger-down so the notch responds on press.
@MainActor
final class HotkeyManager {
    private enum DeferredLockChordAction {
        case none
        case lockAfterTrigger
        case stopAfterTrigger
    }

    private enum EventTapMode: Equatable {
        case observeOnly
        case activeSuppression

        var options: CGEventTapOptions {
            switch self {
            case .observeOnly:
                return .listenOnly
            case .activeSuppression:
                return .defaultTap
            }
        }
    }

    private enum ToggleDictationState {
        case idle
        case starting
        case active
        case stopping
    }

    private static let lockChordGraceDuration: Duration = .milliseconds(250)
    private static let holdTriggerReleaseConfirmationDelay: Duration = .milliseconds(60)
    private static let commandChordGraceDuration: Duration = .milliseconds(250)
    private static let toggleTapRescueInitialDelay: Duration = .milliseconds(80)
    private static let toggleTapRescueRetryDelay: Duration = .milliseconds(50)
    private static let toggleTapRescueRetryCount = 5
    // Fn/Globe can arrive through multiple event paths; tap mode needs a short
    // guard so one physical tap cannot become start followed by immediate stop.
    private static let toggleTapActionCooldown: TimeInterval = 0.18
    private static let toggleStopBounceCooldown: TimeInterval = 0.75
    private static let toggleStopArmDelay: TimeInterval = 0.65
    private static let idlePollingInterval: Duration = .milliseconds(50)
    private static let activePollingInterval: Duration = .milliseconds(16)
    private static let escapeKeyCode: UInt16 = 53

    // MARK: - Callbacks (set by AppState)

    var onDictationStart: (() async -> Void)?
    var onDictationEnd:   (() async -> Void)?
    var onMemoStart:      (() async -> Void)?
    var onMemoEnd:        (() async -> Void)?
    var onRecordingLock:  (() async -> Void)?
    var onCancel:         (() async -> Void)?
    var onCommandToggle:  (() async -> Void)?
    var onCommandStart:   (() async -> Void)?
    var onCommandEnd:     (() async -> Void)?

    // MARK: - Config

    private var triggers: [HotkeyTrigger] = [.fn]
    private var mode: HotkeyMode = .hold
    private var holdToTalkLockEnabled = true
    private var customKeyCodes: Set<UInt16> = []
    private let log = Logger.resonant("HotkeyManager")

    // MARK: - State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hidManager: IOHIDManager?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var pollingTask: Task<Void, Never>?
    private var eventTapWatchdogTask: Task<Void, Never>?
    private let spaceChordSuppressionState = SpaceChordSuppressionState()
    private let inputRunLoop = InputRunLoopThread(name: "com.resonance.resonant.hotkey-input")
    private var eventTapRequestedMode: EventTapMode?
    private var tapReenableBackoff = EventTapReenableBackoff()
    private var tapReenableBlockedUntil: Date?
    private var tapReenableTask: Task<Void, Never>?

    private var fnDown = false
    private var hidFnDown = false
    private var hidRightOptionDown = false
    private var hidControlDown = false
    private var keyEventTriggerDown = false
    private var flagsFnDown = false
    private var flagsRightOptionDown = false
    private var flagsTriggerDown: Bool {
        flagsFnDown || flagsRightOptionDown
    }
    private var systemTriggerDown = false
    private var pollTriggerDown = false
    private var customKeysDown: Set<UInt16> = []
    private var flagsControlDown = false
    private var pollControlDown = false
    private var recordingActive = false
    private var recordingLocked = false
    private var pendingLockedStop = false
    private var pendingLockAfterStart = false
    private var lockChordKeyDown = false
    private var suppressNextTriggerUpEnd = false
    private var deferredLockChordAction: DeferredLockChordAction = .none
    private var lockChordGraceTask: Task<Void, Never>?
    private var holdTriggerReleaseConfirmationTask: Task<Void, Never>?
    private var toggleTapRescueTask: Task<Void, Never>?
    private var chordMode: DictationMode = .dictation
    private var activeMode: DictationMode = .dictation
    private var startTask: Task<Void, Never>?
    private var pendingHoldEnd = false
    private var toggleDictationState: ToggleDictationState = .idle
    private var toggleTapEligible = false
    private var toggleTapInvalidated = false
    private var toggleStartActionAt: Date?
    private var lastToggleTapActionAt: Date?
    private var lastToggleStopActionAt: Date?
    private var toggleStopFinalizing = false
    private var pendingToggleRestart = false
    private var captureTriggerStateMachine = CaptureTriggerStateMachine()
    private var escapeKeyDown = false
    private(set) var lastTriggerSource = "None"
    private var keyStateOverrides: [CGKeyCode: Bool] = [:]

    private var shouldObserveFnTrigger: Bool {
        triggers.contains(.fn)
    }

    private var shouldObserveRightOptionTrigger: Bool {
        triggers.contains(.rightOption)
    }

    private var shouldObserveCustomTrigger: Bool {
        !customKeyCodes.isEmpty
    }

    private var shouldObserveHIDKeyboard: Bool {
        shouldObserveFnTrigger || shouldObserveRightOptionTrigger
    }

    var isListening: Bool {
        eventTap != nil
            || globalFlagsMonitor != nil
            || localFlagsMonitor != nil
            || globalKeyMonitor != nil
            || localKeyMonitor != nil
            || pollingTask != nil
            || hidManager != nil
    }
    var hasAccessibilityPermission: Bool { Self.isAccessibilityTrusted(promptIfNeeded: false) }
    var hasInputMonitoringPermission: Bool { Self.hasListenEventAccess(promptIfNeeded: false) }

    // MARK: - Setup

    func setup(
        triggers: [HotkeyTrigger] = [.fn],
        mode: HotkeyMode = .hold,
        holdToTalkLockEnabled: Bool = true
    ) {
        applyTriggers(triggers)
        self.mode = mode.normalized
        self.holdToTalkLockEnabled = holdToTalkLockEnabled
        spaceChordSuppressionState.setLockChordEnabled(holdToTalkLockEnabled)
        resetObservedInputState()
        _ = refreshRegistration(promptIfNeeded: false)
    }

    func setup(
        trigger: HotkeyTrigger = .fn,
        mode: HotkeyMode = .hold,
        holdToTalkLockEnabled: Bool = true
    ) {
        setup(
            triggers: [trigger],
            mode: mode,
            holdToTalkLockEnabled: holdToTalkLockEnabled
        )
    }

    deinit {
        // Safety net: if `teardown()` was never called, the CGEventTap and its
        // CFRunLoopSource would leak and the input thread would keep spinning.
        // At deinit no other reference remains, so touching these is race-free.
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            inputRunLoop.performSync { runLoop in
                CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
            }
        }
        inputRunLoop.stop()
    }

    func teardown() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            inputRunLoop.performSync { runLoop in
                CFRunLoopRemoveSource(runLoop, src, .commonModes)
            }
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        pollingTask?.cancel()
        eventTapWatchdogTask?.cancel()
        clearTapReenableBackoff()
        if let hidManager {
            inputRunLoop.performSync { runLoop in
                IOHIDManagerUnscheduleFromRunLoop(hidManager, runLoop, CFRunLoopMode.commonModes.rawValue as CFString)
            }
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        eventTap = nil
        runLoopSource = nil
        hidManager = nil
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        pollingTask = nil
        eventTapWatchdogTask = nil
        inputRunLoop.stop()
        resetObservedInputState()
    }

    func reconfigure(
        triggers: [HotkeyTrigger],
        mode: HotkeyMode,
        holdToTalkLockEnabled: Bool = true
    ) {
        applyTriggers(triggers)
        self.mode = mode.normalized
        self.holdToTalkLockEnabled = holdToTalkLockEnabled
        spaceChordSuppressionState.setLockChordEnabled(holdToTalkLockEnabled)
        resetObservedInputState()
        _ = refreshRegistration(promptIfNeeded: false)
    }

    func reconfigure(
        trigger: HotkeyTrigger,
        mode: HotkeyMode,
        holdToTalkLockEnabled: Bool = true
    ) {
        reconfigure(
            triggers: [trigger],
            mode: mode,
            holdToTalkLockEnabled: holdToTalkLockEnabled
        )
    }

    private func applyTriggers(_ triggers: [HotkeyTrigger]) {
        self.triggers = HotkeyTrigger.normalizedList(triggers)
        syncCustomKeyCodes()
        spaceChordSuppressionState.updateTriggers(self.triggers)
    }

    private func syncCustomKeyCodes() {
        customKeyCodes = Set(triggers.compactMap { trigger in
            guard case .custom(let keyCode) = trigger else { return nil }
            return keyCode
        })
    }

    var isRecordingLocked: Bool {
        recordingLocked
    }

    func syncRecordingState(isActive: Bool, isLocked: Bool, isFinishing: Bool = false) {
        recordingActive = isActive
        recordingLocked = isActive && isLocked
        let isToggleDictationFinishing = mode == .toggle && activeMode == .dictation && !isActive && isFinishing
        toggleStopFinalizing = isToggleDictationFinishing

        if activeMode == .dictation {
            if isActive {
                toggleStopFinalizing = false
                if toggleDictationState != .stopping, mode == .toggle {
                    toggleDictationState = .active
                }
            } else if isToggleDictationFinishing {
                toggleDictationState = .stopping
                pendingToggleRestart = false
            } else {
                toggleDictationState = .idle
                toggleStartActionAt = nil
            }
        }

        if !isActive {
            pendingLockedStop = false
            pendingLockAfterStart = false
            // Note: lockChordKeyDown is intentionally NOT cleared here — it is
            // reset by the spacebar-up / trigger-up events.  Clearing it during
            // the async stop callback creates a race where a duplicate spacebar
            // event (HID + CGEventTap both fire for the same press) slips past
            // the guard and phantom-locks with no active recording.
            suppressNextTriggerUpEnd = false
            clearHoldTriggerReleaseConfirmationTask()
            toggleTapEligible = false
            toggleTapInvalidated = false
            clearDeferredLockChordAction()
            clearToggleTapRescueTask()

            if !isToggleDictationFinishing, pendingToggleRestart {
                pendingToggleRestart = false
                Task { @MainActor [weak self] in
                    self?.startToggleDictation()
                }
            }
        }
    }

    @discardableResult
    func refreshRegistration(promptIfNeeded: Bool) -> Bool {
        let hasAccessibilityPermission = Self.isAccessibilityTrusted(promptIfNeeded: promptIfNeeded)
        let hasInputMonitoringPermission = Self.hasListenEventAccess(promptIfNeeded: promptIfNeeded)
        let shouldInstallGlobalMonitors = hasAccessibilityPermission || hasInputMonitoringPermission

        // Reinstall when the current trigger state changes the tap kind we need
        // (active suppression vs passive observation).
        if hasInputMonitoringPermission, eventTap != nil, eventTapRequestedMode != desiredEventTapMode {
            teardownEventTap()
        }

        if hasInputMonitoringPermission, eventTap == nil {
            installTap()
        } else if hasInputMonitoringPermission, let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else if !hasInputMonitoringPermission {
            teardownEventTap()
        }

        installEventMonitors(includeGlobal: shouldInstallGlobalMonitors)
        let shouldEnablePolling =
            Self.shouldUseSupplementalFnPolling(
                observesFn: shouldObserveFnTrigger,
                hasInputMonitoringPermission: hasInputMonitoringPermission
            )
            || Self.shouldUsePollingFallback(
                hasAccessibilityPermission: hasAccessibilityPermission,
                hasInputMonitoringPermission: hasInputMonitoringPermission
            )
        updatePollingFallback(
            isEnabled: shouldEnablePolling
        )
        updateEventTapWatchdog(isEnabled: Self.shouldRunEventTapWatchdog(
            hasInputMonitoringPermission: hasInputMonitoringPermission
        ))
        installHIDManagerIfNeeded(hasInputMonitoringPermission: hasInputMonitoringPermission)
        removeHIDManagerIfNeeded(hasInputMonitoringPermission: hasInputMonitoringPermission)

        if !shouldInstallGlobalMonitors {
            if let globalFlagsMonitor {
                NSEvent.removeMonitor(globalFlagsMonitor)
                self.globalFlagsMonitor = nil
            }
            if let globalKeyMonitor {
                NSEvent.removeMonitor(globalKeyMonitor)
                self.globalKeyMonitor = nil
            }
        }

        if shouldEnablePolling {
            log.debug("Hotkey polling active")
        }

        return isListening
    }

    nonisolated static func shouldUseSupplementalFnPolling(
        observesFn: Bool,
        hasInputMonitoringPermission: Bool
    ) -> Bool {
        observesFn && !hasInputMonitoringPermission
    }

    nonisolated static func shouldUsePollingFallback(
        hasAccessibilityPermission: Bool,
        hasInputMonitoringPermission: Bool
    ) -> Bool {
        !(hasAccessibilityPermission || hasInputMonitoringPermission)
    }

    nonisolated static func shouldRunEventTapWatchdog(hasInputMonitoringPermission: Bool) -> Bool {
        hasInputMonitoringPermission
    }

    // MARK: - CGEventTap

    private var desiredEventTapMode: EventTapMode {
        holdToTalkLockEnabled && shouldArmActiveSuppression
            ? .activeSuppression
            : .observeOnly
    }

    // Deliberately ignores lockChordKeyDown: a bare space press (no trigger
    // held) must not flip the tap to .defaultTap — rebuilding an active tap
    // around every space keystroke races the in-flight event's delivery and
    // can double the space in the focused app. Chord windows are covered by
    // the trigger state and an in-flight suppressed space sequence.
    private var shouldArmActiveSuppression: Bool {
        fnDown
            || hidTriggerPressed
            || keyEventTriggerDown
            || flagsTriggerDown
            || systemTriggerDown
            || pollTriggerDown
            || customTriggerPressed
            || spaceChordSuppressionState.requiresActiveSuppression()
    }

    private func installTap() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let tapCallback: CGEventTapCallBack = { _, type, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

            // Re-enable on tap-disable so hotkeys recover without waiting for the 5s watchdog.
            // Timeout disables go through backoff: re-arming instantly while the process
            // is stalling turns one stall into sustained system-wide keyboard latency.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                manager.spaceChordSuppressionState.resetObservedTriggerState()
                if type == .tapDisabledByTimeout {
                    Task { @MainActor in manager.handleTapDisabledByTimeout() }
                } else {
                    Task { @MainActor in manager.reenableEventTapIfNeeded() }
                }
                return Unmanaged.passUnretained(event)
            }

            // Extract scalar values synchronously — CGEvent is not Sendable
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            manager.spaceChordSuppressionState.observeEvent(eventType: type, keyCode: keyCode, flags: flags)
            let shouldSuppressEvent = manager.spaceChordSuppressionState.shouldSuppressEvent(
                eventType: type,
                keyCode: keyCode,
                flags: flags
            )
            let shouldRefreshTapMode =
                type == .flagsChanged
                || keyCode == 49
                || manager.spaceChordSuppressionState.observesKeyCode(keyCode)
                || shouldSuppressEvent

            // Skip MainActor dispatch for typing keys we don't observe and that can't affect trigger state.
            let isKeyEvent = type == .keyDown || type == .keyUp
            let mustDispatch =
                !isKeyEvent
                || keyCode == HotkeyManager.escapeKeyCode
                || keyCode == 49
                || manager.spaceChordSuppressionState.observesKeyCode(keyCode)
                || manager.spaceChordSuppressionState.anyObservedTriggerDown()

            if mustDispatch {
                Task { @MainActor in manager.handleRawEvent(eventType: type, keyCode: keyCode, flags: flags) }
            }
            if shouldRefreshTapMode {
                Task { @MainActor in manager.refreshEventTapModeIfNeeded() }
            }
            return shouldSuppressEvent ? nil : Unmanaged.passUnretained(event)
        }

        // An active (.defaultTap) tap makes every keystroke on the system wait on
        // this process, so keep the idle tap passive and arm active suppression
        // only around trigger+Space lock-chord windows.
        let requestedMode = desiredEventTapMode
        var resolvedMode = requestedMode
        var tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: resolvedMode.options,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: selfPtr
        )

        if tap == nil, resolvedMode == .activeSuppression {
            resolvedMode = .observeOnly
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: resolvedMode.options,
                eventsOfInterest: mask,
                callback: tapCallback,
                userInfo: selfPtr
            )
        }

        guard let resolvedTap = tap else {
            print("[HotkeyManager] CGEventTap creation failed — check Accessibility permission")
            return
        }

        spaceChordSuppressionState.setCanSuppressEvents(resolvedMode == .activeSuppression)

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, resolvedTap, 0)
        inputRunLoop.performSync { runLoop in
            CFRunLoopAddSource(runLoop, src, .commonModes)
        }
        CGEvent.tapEnable(tap: resolvedTap, enable: true)

        eventTap = resolvedTap
        runLoopSource = src
        eventTapRequestedMode = requestedMode
    }

    private func reenableEventTapIfNeeded() {
        if let tapReenableBlockedUntil, Date() < tapReenableBlockedUntil { return }
        guard eventTapRequestedMode == desiredEventTapMode else {
            refreshEventTapModeIfNeeded()
            return
        }
        guard let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func refreshEventTapModeIfNeeded() {
        guard eventTap != nil else { return }
        guard eventTapRequestedMode != desiredEventTapMode else { return }
        teardownEventTap()
        installTap()
    }

    private func handleTapDisabledByTimeout() {
        let delay = tapReenableBackoff.recordTimeout()
        guard delay > 0 else {
            reenableEventTapIfNeeded()
            return
        }

        log.warning("event tap timed out x\(self.tapReenableBackoff.consecutiveTimeouts, privacy: .public); re-enabling in \(delay, privacy: .public)s")
        tapReenableBlockedUntil = Date().addingTimeInterval(delay)
        tapReenableTask?.cancel()
        tapReenableTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.tapReenableBlockedUntil = nil
                self.reenableEventTapIfNeeded()
            }
        }
    }

    private func clearTapReenableBackoff() {
        tapReenableTask?.cancel()
        tapReenableTask = nil
        tapReenableBlockedUntil = nil
        tapReenableBackoff = EventTapReenableBackoff()
    }

    private func stopInputRunLoopIfIdle() {
        guard eventTap == nil, hidManager == nil else { return }
        inputRunLoop.stop()
    }

    private func teardownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            inputRunLoop.performSync { runLoop in
                CFRunLoopRemoveSource(runLoop, src, .commonModes)
            }
        }
        spaceChordSuppressionState.setCanSuppressEvents(false)
        clearTapReenableBackoff()
        eventTap = nil
        runLoopSource = nil
        eventTapRequestedMode = nil
        stopInputRunLoopIfIdle()
    }

    private func installEventMonitors(includeGlobal: Bool) {
        if includeGlobal, globalFlagsMonitor == nil {
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleFlagsChanged(modifierFlags: event.modifierFlags, keyCode: event.keyCode)
                }
            }
        }

        if localFlagsMonitor == nil {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleFlagsChanged(modifierFlags: event.modifierFlags, keyCode: event.keyCode)
                }
                return event
            }
        }

        if includeGlobal, globalKeyMonitor == nil {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .systemDefined]) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleAppKitEvent(event)
                }
            }
        }

        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .systemDefined]) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleAppKitEvent(event)
                }
                return event
            }
        }
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Duration? = await MainActor.run { [weak self] in
                    guard let self else { return nil }
                    self.pollHotkeyState()
                    return self.currentPollingInterval()
                }
                try? await Task.sleep(for: interval ?? Self.idlePollingInterval)
            }
        }
    }

    private func stopPollingIfNeeded() {
        guard pollingTask != nil else { return }
        pollingTask?.cancel()
        pollingTask = nil

        let hadPollingState = pollTriggerDown || pollControlDown
        pollTriggerDown = false
        pollControlDown = false
        if hadPollingState {
            refreshTriggerState(source: "pollFallback")
        }
    }

    private func updatePollingFallback(isEnabled: Bool) {
        if isEnabled {
            startPollingIfNeeded()
        } else {
            stopPollingIfNeeded()
        }
    }

    private func currentPollingInterval() -> Duration {
        pollTriggerDown || pollControlDown || lockChordKeyDown
            ? Self.activePollingInterval
            : Self.idlePollingInterval
    }

    private func startEventTapWatchdogIfNeeded() {
        guard eventTapWatchdogTask == nil else { return }

        eventTapWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    self?.reenableEventTapIfNeeded()
                }
            }
        }
    }

    private func stopEventTapWatchdogIfNeeded() {
        eventTapWatchdogTask?.cancel()
        eventTapWatchdogTask = nil
    }

    private func updateEventTapWatchdog(isEnabled: Bool) {
        if isEnabled {
            startEventTapWatchdogIfNeeded()
        } else {
            stopEventTapWatchdogIfNeeded()
        }
    }

    private func pollHotkeyState() {
        var activeCustomKeys: Set<UInt16> = []
        for code in customKeyCodes {
            let isPressed = currentKeyState(CGKeyCode(code))
            if isPressed {
                activeCustomKeys.insert(code)
            }
        }
        customKeysDown = activeCustomKeys

        let isTriggerPressed =
            (shouldObserveFnTrigger && isFnPressedInCurrentState())
            || (shouldObserveRightOptionTrigger && isRightOptionPressedInCurrentState())
            || !activeCustomKeys.isEmpty

        let isControlPressed = CGEventSource.keyState(.hidSystemState, key: 59)
            || CGEventSource.keyState(.hidSystemState, key: 62)
            || CGEventSource.keyState(.combinedSessionState, key: 59)
            || CGEventSource.keyState(.combinedSessionState, key: 62)

        pollTriggerDown = isTriggerPressed
        pollControlDown = isControlPressed
        refreshTriggerState(source: "poll")
    }

    private func installHIDManagerIfNeeded(hasInputMonitoringPermission: Bool) {
        guard shouldObserveHIDKeyboard else { return }
        // IOHIDManagerOpen against keyboard devices can make macOS surface the
        // Input Monitoring privacy prompt. Only install it after the user has
        // already granted access; polling and AppKit monitors cover the launch
        // path without re-prompting.
        guard hasInputMonitoringPermission else { return }
        guard hidManager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let keyboardMatches: [[String: Int]] = [
            [
                kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop),
                kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Keyboard),
            ],
            [
                kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop),
                kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Keypad),
            ],
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, keyboardMatches as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let usagePage = UInt32(IOHIDElementGetUsagePage(element))
            let usage = UInt32(IOHIDElementGetUsage(element))
            let intValue = IOHIDValueGetIntegerValue(value)
            Task { @MainActor in
                manager.handleHIDValue(usagePage: usagePage, usage: usage, intValue: intValue)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        inputRunLoop.performSync { runLoop in
            IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.commonModes.rawValue as CFString)
        }

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            inputRunLoop.performSync { runLoop in
                IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.commonModes.rawValue as CFString)
            }
            stopInputRunLoopIfIdle()
            return
        }

        hidManager = manager
    }

    private func removeHIDManagerIfNeeded(hasInputMonitoringPermission: Bool) {
        guard (!shouldObserveHIDKeyboard || !hasInputMonitoringPermission), let hidManager else { return }

        inputRunLoop.performSync { runLoop in
            IOHIDManagerUnscheduleFromRunLoop(hidManager, runLoop, CFRunLoopMode.commonModes.rawValue as CFString)
        }
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = nil
        stopInputRunLoopIfIdle()
    }

    private func handleHIDValue(usagePage: UInt32, usage: UInt32, intValue: CFIndex) {
        guard shouldObserveHIDKeyboard else { return }
        let isPressed = intValue != 0
        let keyboardPage = UInt32(kHIDPage_KeyboardOrKeypad)

        let isFnUsage = usagePage == 0xFF && usage == 0x03
        let isGlobeKeyUsage = usagePage == keyboardPage && usage == 0xB3
        let isRightOptionUsage = usagePage == keyboardPage && usage == 0xE6
        let isLeftControlUsage = usagePage == keyboardPage && usage == 0xE0
        let isRightControlUsage = usagePage == keyboardPage && usage == 0xE4
        // HID usage 0x2C = Spacebar on the keyboard page.
        // Detected here because macOS may consume ctrl+space (input-source switching)
        // before it reaches CGEventTap / NSEvent monitors, preventing the lock chord
        // from firing during memo recording (fn+ctrl held).
        let isSpacebarUsage = usagePage == keyboardPage && usage == 0x2C

        if isFnUsage || isGlobeKeyUsage {
            hidFnDown = isPressed
        }
        if isRightOptionUsage {
            hidRightOptionDown = isPressed
        }
        if isLeftControlUsage || isRightControlUsage {
            hidControlDown = isPressed
        }
        if isSpacebarUsage {
            if isPressed {
                handleLockChordKeyDown()
            } else {
                handleLockChordKeyUp()
            }
            return
        }

        guard isFnUsage || isGlobeKeyUsage || isRightOptionUsage || isLeftControlUsage || isRightControlUsage else {
            return
        }

        refreshTriggerState(source: "hid")
    }

    private static func isAccessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func hasListenEventAccess(promptIfNeeded: Bool) -> Bool {
        if promptIfNeeded {
            return CGRequestListenEventAccess()
        }

        return CGPreflightListenEventAccess()
    }

    // MARK: - Event handling

    /// Handles pre-extracted event data from the CGEventTap callback.
    /// Values are extracted synchronously in the callback to avoid passing CGEvent across actor boundaries.
    private func handleRawEvent(eventType: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))

        switch eventType {
        case .flagsChanged:
            handleFlagsChanged(modifierFlags: modifierFlags, keyCode: keyCode)
        case .keyDown, .keyUp:
            let appKitType: NSEvent.EventType = eventType == .keyDown ? .keyDown : .keyUp
            handleKeyEvent(type: appKitType, keyCode: keyCode)
        default:
            break
        }
    }

    private func handleAppKitEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp:
            handleKeyEvent(type: event.type, keyCode: event.keyCode)
        case .systemDefined:
            handleSystemDefinedEvent(event)
        default:
            break
        }
    }

    private func handleFlagsChanged(modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16) {
        handleCommandChord(modifierFlags: modifierFlags)

        let modifierPressed = isCustomModifierPressed(
            modifierFlags: modifierFlags,
            keyCode: keyCode
        )
        flagsControlDown = modifierFlags.contains(.control)
        flagsFnDown = shouldObserveFnTrigger && isFnPressed(modifierFlags: modifierFlags, keyCode: keyCode)
        if shouldObserveRightOptionTrigger,
           SideSpecificModifierKey.shouldUpdateState(for: 61, modifierFlags: modifierFlags, changedKeyCode: keyCode) {
            flagsRightOptionDown = isRightOptionPressed(modifierFlags: modifierFlags)
        } else if !shouldObserveRightOptionTrigger {
            flagsRightOptionDown = false
        }
        updateCustomModifierState(modifierFlags: modifierFlags, changedKeyCode: keyCode)

        if mode == .toggle,
           fnDown,
           modifierPressed,
           !isObservedTriggerKeyCode(keyCode) {
            invalidateToggleTapCandidate()
        }

        refreshTriggerState(source: "flagsChanged")
    }

    private func handleCommandChord(modifierFlags: NSEvent.ModifierFlags) {
        let transition = captureTriggerStateMachine.handleCommandChord(
            functionDown: modifierFlags.contains(.function),
            shiftDown: modifierFlags.contains(.shift),
            configuration: captureTriggerConfiguration
        )

        if transition.shouldCancelPendingHoldTrigger {
            cancelPendingTriggerForCommandChord()
        }

        switch transition.action {
        case .startOrToggleCommand:
            Task { @MainActor [weak self] in
                if let onCommandStart = self?.onCommandStart {
                    await onCommandStart()
                } else {
                    await self?.onCommandToggle?()
                }
            }
        case .endCommand:
            if let onCommandEnd {
                Task { @MainActor in
                    await onCommandEnd()
                }
            }
        case nil:
            break
        }
    }

    private func handleKeyEvent(type: NSEvent.EventType, keyCode: UInt16) {
        if keyCode == Self.escapeKeyCode {
            handleEscapeKeyEvent(type: type)
            return
        }

        if customKeyCodes.contains(keyCode), !KeyCodeNames.isModifierKey(keyCode) {
            if type == .keyDown {
                customKeysDown.insert(keyCode)
            } else if type == .keyUp {
                customKeysDown.remove(keyCode)
            }
            refreshTriggerState(source: "customKey")

            if keyCode == 49 {
                return
            }
        }

        if mode == .toggle,
           fnDown,
           type == .keyDown,
           !isObservedTriggerKeyCode(keyCode) {
            invalidateToggleTapCandidate()
        }

        if isObservedModifierTriggerKeyCode(keyCode) {
            switch type {
            case .keyDown:
                keyEventTriggerDown = true
            case .keyUp:
                keyEventTriggerDown = false
            default:
                break
            }
            refreshTriggerState(source: "keyEvent")
            return
        }

        if keyCode == 49 {
            switch type {
            case .keyDown:
                handleLockChordKeyDown()
            case .keyUp:
                handleLockChordKeyUp()
            default:
                break
            }
            return
        }
    }

    private func handleEscapeKeyEvent(type: NSEvent.EventType) {
        switch type {
        case .keyDown:
            guard !escapeKeyDown else { return }
            resetObservedInputState()
            escapeKeyDown = true
            lastTriggerSource = "escape: cancel"
            Task { [weak self] in
                await self?.onCancel?()
            }
        case .keyUp:
            escapeKeyDown = false
        default:
            break
        }
    }

    private func handleSystemDefinedEvent(_ event: NSEvent) {
        guard shouldObserveFnTrigger else { return }

        let rawData = UInt32(bitPattern: Int32(event.data1))
        let keyCode = UInt16((rawData & 0xFFFF0000) >> 16)
        let state = UInt8((rawData & 0x0000FF00) >> 8)
        let isDown = state == 0x0A
        let isUp = state == 0x0B

        // .systemDefined events do not support NSEvent.keyCode. Only trust the packed data payload.
        guard keyCode == 0xB3 || keyCode == 63 else {
            return
        }

        if isDown || isUp {
            systemTriggerDown = isDown
            refreshTriggerState(source: "systemDefined")
        }
    }

    private var isToggleDictationSessionInProgress: Bool {
        mode == .toggle && toggleDictationState != .idle
    }

    private var isMemoHoldSessionInProgress: Bool {
        activeMode == .memo && (recordingActive || startTask != nil || recordingLocked)
    }

    private func beginToggleTapCandidate() {
        fnDown = true
        toggleTapEligible = true
        toggleTapInvalidated = false
        armToggleTapRescue()
    }

    private func invalidateToggleTapCandidate() {
        guard toggleTapEligible else { return }
        toggleTapInvalidated = true
        clearToggleTapRescueTask()
    }

    private func handleToggleTriggerUp() {
        defer {
            toggleTapEligible = false
            toggleTapInvalidated = false
            clearToggleTapRescueTask()
        }

        guard toggleTapEligible, !toggleTapInvalidated else { return }
        let now = Date()

        guard !shouldSuppressToggleTapBounce(now: now) else {
            lastTriggerSource = "toggle: bounceSuppressed"
            return
        }

        switch toggleDictationState {
        case .idle:
            noteToggleTapAction(at: now)
            startToggleDictation(startedAt: now)
        case .starting, .active:
            guard canStopToggleDictation(now: now) else {
                lastTriggerSource = "toggle: stopSuppressed"
                return
            }
            noteToggleTapAction(at: now)
            noteToggleStopAction(at: now)
            requestToggleDictationStop()
        case .stopping:
            guard !toggleStopFinalizing else {
                lastTriggerSource = "toggle: finishingSuppressed"
                return
            }
            noteToggleTapAction(at: now)
            pendingToggleRestart = true
        }
    }

    private func startToggleDictation(startedAt: Date = Date()) {
        activeMode = .dictation
        toggleDictationState = .starting
        toggleStartActionAt = startedAt
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.fireStart(mode: .dictation)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.startTask = nil
                if self.toggleDictationState == .starting {
                    self.toggleDictationState = self.recordingActive ? .active : .idle
                }
            }
        }
    }

    private func requestToggleDictationStop() {
        toggleDictationState = .stopping
        Task { [weak self] in
            await self?.fireEnd(mode: .dictation)
        }
    }

    private func noteToggleTapAction(at date: Date) {
        lastToggleTapActionAt = date
    }

    private func noteToggleStopAction(at date: Date) {
        lastToggleStopActionAt = date
    }

    private func shouldSuppressToggleTapBounce(now: Date) -> Bool {
        if let lastToggleTapActionAt,
           now.timeIntervalSince(lastToggleTapActionAt) < Self.toggleTapActionCooldown {
            return true
        }

        if let lastToggleStopActionAt,
           now.timeIntervalSince(lastToggleStopActionAt) < Self.toggleStopBounceCooldown {
            return true
        }

        return false
    }

    private func canStopToggleDictation(now: Date) -> Bool {
        guard let toggleStartActionAt else { return true }
        return now.timeIntervalSince(toggleStartActionAt) >= Self.toggleStopArmDelay
    }

    private func isObservedTriggerKeyCode(_ keyCode: UInt16) -> Bool {
        if keyCode == 63, shouldObserveFnTrigger {
            return true
        }

        if keyCode == 0xB3, shouldObserveFnTrigger {
            return true
        }

        if keyCode == 61, shouldObserveRightOptionTrigger {
            return true
        }

        return customKeyCodes.contains(keyCode)
    }

    private func isObservedModifierTriggerKeyCode(_ keyCode: UInt16) -> Bool {
        isObservedTriggerKeyCode(keyCode) && (KeyCodeNames.isModifierKey(keyCode) || keyCode == 0xB3)
    }

    private func handleLockChordKeyDown() {
        defer { refreshEventTapModeIfNeeded() }

        guard holdToTalkLockEnabled else {
            if mode == .toggle, fnDown {
                invalidateToggleTapCandidate()
            }
            return
        }

        if mode == .toggle, !isMemoHoldSessionInProgress {
            invalidateToggleTapCandidate()
            return
        }
        guard !lockChordKeyDown else { return }
        lockChordKeyDown = true
        lockChordGraceTask?.cancel()

        let triggerPressed = fnDown
            || hidTriggerPressed
            || keyEventTriggerDown
            || flagsTriggerDown
            || systemTriggerDown
            || pollTriggerDown
            || customTriggerPressed

        if recordingLocked {
            guard triggerPressed else {
                deferredLockChordAction = .stopAfterTrigger
                lastTriggerSource = "spaceChord: stopPending"
                return
            }

            // If the trigger is already held, stop immediately so the chord has an
            // explicit effect instead of looking like a plain trigger tap.
            if fnDown {
                completeLockedStopUsingChord()
            } else {
                fnDown = true
                pendingLockedStop = true
                deferredLockChordAction = .stopAfterTrigger
                lastTriggerSource = "spaceChord: stopPending"
            }
            return
        }

        if startTask != nil {
            recordingLocked = true
            pendingLockAfterStart = true
            pendingHoldEnd = false
            deferredLockChordAction = .lockAfterTrigger
            lastTriggerSource = "spaceChord: lockPending"
            return
        }

        if recordingActive {
            clearDeferredLockChordAction()
            requestRecordingLock()
            return
        }

        if !triggerPressed {
            pendingLockAfterStart = true
            pendingHoldEnd = false
            deferredLockChordAction = .lockAfterTrigger
            lastTriggerSource = "spaceChord: lockPending"
            return
        }

        clearDeferredLockChordAction()
        requestRecordingLock()
    }

    private func handleLockChordKeyUp() {
        defer { refreshEventTapModeIfNeeded() }

        lockChordKeyDown = false

        guard deferredLockChordAction != .none, !fnDown else {
            clearPendingLockIfIdle()
            return
        }

        lockChordGraceTask?.cancel()
        lockChordGraceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lockChordGraceDuration)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !self.lockChordKeyDown, !self.fnDown else { return }
                self.clearDeferredLockChordAction()
                self.clearPendingLockIfIdle()
            }
        }
    }

    private func refreshTriggerState(source: String) {
        defer { refreshEventTapModeIfNeeded() }

        let isTriggerPressed = hidTriggerPressed
            || keyEventTriggerDown
            || flagsTriggerDown
            || systemTriggerDown
            || pollTriggerDown
            || customTriggerPressed

        let isControlPressed = (hidControlDown
            || flagsControlDown
            || pollControlDown)
            && !isControlConfiguredAsTrigger

        handleTriggerState(isPressed: isTriggerPressed, controlHeld: isControlPressed, source: source)
    }

    private func handleTriggerState(isPressed: Bool, controlHeld: Bool, source: String) {
        switch captureTriggerStateMachine.handleTriggerRefresh(isPressed: isPressed) {
        case .accept:
            break
        case .suppressUntilReleased:
            lastTriggerSource = "\(source): commandChordSuppressed"
            return
        }

        if isPressed {
            clearHoldTriggerReleaseConfirmationTask()
        }

        if isPressed && !fnDown {
            lastTriggerSource = "\(source): down"
            log.info("trigger down (source=\(source, privacy: .public) control=\(controlHeld, privacy: .public) mode=\(String(describing: self.mode), privacy: .public))")
            onTriggerDown(controlHeld: controlHeld)
        } else if !isPressed && fnDown {
            if scheduleHoldTriggerReleaseConfirmationIfNeeded(source: source) {
                return
            }
            lastTriggerSource = "\(source): up"
            log.info("trigger up (source=\(source, privacy: .public))")
            onTriggerUp()
        } else if fnDown {
            lastTriggerSource = "\(source): hold"
            updateChordMode(controlHeld: controlHeld)
        }
    }

    private func onTriggerDown(controlHeld: Bool) {
        clearHoldTriggerReleaseConfirmationTask()

        if recordingLocked {
            if deferredLockChordAction == .stopAfterTrigger {
                fnDown = true
                clearDeferredLockChordAction()
                completeLockedStopUsingChord()
                return
            }

            fnDown = true
            pendingLockedStop = true
            lastTriggerSource = "lockedTrigger: stopPending"
            return
        }

        if mode == .toggle, isToggleDictationSessionInProgress {
            switch toggleDictationState {
            case .starting, .active, .stopping:
                beginToggleTapCandidate()
            case .idle:
                fnDown = true
                toggleTapEligible = false
                toggleTapInvalidated = true
            }
            return
        }

        if mode == .toggle, !controlHeld, !isMemoHoldSessionInProgress {
            switch toggleDictationState {
            case .idle:
                beginToggleTapCandidate()
            case .starting, .active:
                beginToggleTapCandidate()
            case .stopping:
                fnDown = true
                toggleTapEligible = false
                toggleTapInvalidated = true
            }
            return
        }

        beginHoldRecording(controlHeld: controlHeld)
    }

    private func beginHoldRecording(controlHeld: Bool) {
        fnDown = true
        chordMode = controlHeld ? .memo : .dictation
        pendingHoldEnd = false
        if pendingLockAfterStart || lockChordKeyDown || deferredLockChordAction == .lockAfterTrigger {
            recordingLocked = true
            clearDeferredLockChordAction()
        }

        activeMode = chordMode
        startTask?.cancel()
        let startedMode = activeMode
        let shouldWaitForCommandChord = shouldDelayHoldStartForCommandChord(controlHeld: controlHeld)
        startTask = Task { [weak self] in
            if shouldWaitForCommandChord {
                try? await Task.sleep(for: Self.commandChordGraceDuration)
                guard !Task.isCancelled else { return }
            }
            await self?.fireStart(mode: startedMode)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.startTask = nil
                if self.pendingLockAfterStart {
                    self.requestRecordingLock()
                }
                guard self.pendingHoldEnd, !self.fnDown else { return }
                self.pendingHoldEnd = false
                Task { [weak self] in
                    await self?.fireEnd(mode: startedMode)
                }
            }
        }
    }

    private func updateChordMode(controlHeld: Bool) {
        chordMode = controlHeld ? .memo : .dictation
    }

    private func shouldDelayHoldStartForCommandChord(controlHeld: Bool) -> Bool {
        captureTriggerStateMachine.shouldDelayHoldStartForPossibleCommandChord(
            controlHeld: controlHeld,
            configuration: captureTriggerConfiguration
        )
    }

    private var hasCommandShortcut: Bool {
        onCommandStart != nil || onCommandEnd != nil || onCommandToggle != nil
    }

    private var captureTriggerConfiguration: CaptureTriggerStateMachine.Configuration {
        CaptureTriggerStateMachine.Configuration(
            mode: mode,
            observesFnTrigger: shouldObserveFnTrigger,
            hasCommandShortcut: hasCommandShortcut
        )
    }

    private func cancelPendingTriggerForCommandChord() {
        guard fnDown, startTask != nil, !recordingActive else { return }
        startTask?.cancel()
        startTask = nil
        fnDown = false
        pendingHoldEnd = false
        pendingLockAfterStart = false
        lockChordKeyDown = false
        clearDeferredLockChordAction()
        clearHoldTriggerReleaseConfirmationTask()
    }

    private func onTriggerUp() {
        clearHoldTriggerReleaseConfirmationTask()
        fnDown = false
        lockChordKeyDown = false

        if suppressNextTriggerUpEnd {
            suppressNextTriggerUpEnd = false
            pendingLockedStop = false
            return
        }

        if mode == .toggle, !isMemoHoldSessionInProgress, (toggleTapEligible || isToggleDictationSessionInProgress) {
            handleToggleTriggerUp()
            return
        }

        if recordingLocked {
            if pendingLockedStop {
                pendingLockedStop = false
                recordingLocked = false
                let endingMode = activeMode
                Task { [weak self] in
                    await self?.fireEnd(mode: endingMode)
                }
            }
            return
        }

        if startTask != nil {
            pendingHoldEnd = !(pendingLockAfterStart || lockChordKeyDown)
        } else {
            let endingMode = activeMode
            Task { [weak self] in
                await self?.fireEnd(mode: endingMode)
            }
        }
    }

    // MARK: - Fire actions

    private func fireStart(mode: DictationMode) async {
        switch mode {
        case .dictation: await onDictationStart?()
        case .memo:      await onMemoStart?()
        case .command:   break // command mode is triggered via dedicated shortcut, not hotkey
        }
    }

    private func fireEnd(mode: DictationMode) async {
        switch mode {
        case .dictation: await onDictationEnd?()
        case .memo:      await onMemoEnd?()
        case .command:   break // command mode is triggered via dedicated shortcut, not hotkey
        }
    }

    private func requestRecordingLock() {
        recordingLocked = true
        pendingLockAfterStart = false
        pendingHoldEnd = false
        pendingLockedStop = false
        lastTriggerSource = "spaceChord: lock"
        Task { [weak self] in
            await self?.onRecordingLock?()
        }
    }

    private func completeLockedStopUsingChord() {
        guard recordingLocked else { return }

        recordingLocked = false
        pendingLockedStop = false
        pendingLockAfterStart = false
        pendingHoldEnd = false
        suppressNextTriggerUpEnd = true
        lastTriggerSource = "spaceChord: stop"

        let endingMode = activeMode
        Task { [weak self] in
            await self?.fireEnd(mode: endingMode)
        }
    }

    private var hidTriggerPressed: Bool {
        (shouldObserveFnTrigger && hidFnDown)
            || (shouldObserveRightOptionTrigger && hidRightOptionDown)
    }

    private var customTriggerPressed: Bool {
        !customKeysDown.isEmpty
    }

    private var isControlConfiguredAsTrigger: Bool {
        customKeyCodes.contains(59) || customKeyCodes.contains(62)
    }

    private func armToggleTapRescue() {
        clearToggleTapRescueTask()
        toggleTapRescueTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toggleTapRescueInitialDelay)

            for _ in 0..<Self.toggleTapRescueRetryCount {
                guard !Task.isCancelled, let self else { return }
                guard self.mode == .toggle, self.fnDown, self.toggleTapEligible, !self.toggleTapInvalidated else { return }

                if !self.isTriggerPressedInCurrentState() {
                    self.clearObservedTriggerState()
                    self.lastTriggerSource = "toggleRescue: up"
                    self.onTriggerUp()
                    return
                }

                try? await Task.sleep(for: Self.toggleTapRescueRetryDelay)
            }
        }
    }

    private func scheduleHoldTriggerReleaseConfirmationIfNeeded(source: String) -> Bool {
        guard mode == .hold, shouldObserveFnTrigger else { return false }

        if isTriggerPressedInCurrentState() {
            lastTriggerSource = "\(source): releaseRescued"
            return true
        }

        guard holdTriggerReleaseConfirmationTask == nil else { return true }

        lastTriggerSource = "\(source): upPending"
        holdTriggerReleaseConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdTriggerReleaseConfirmationDelay)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.holdTriggerReleaseConfirmationTask = nil
                guard self.fnDown, self.mode == .hold else { return }

                if self.isTriggerPressedInCurrentState() {
                    self.lastTriggerSource = "\(source): releaseRescued"
                    self.log.debug("Rescued transient trigger release source=\(source, privacy: .public)")
                    return
                }

                self.lastTriggerSource = "\(source): upConfirmed"
                self.log.debug("Confirmed trigger release source=\(source, privacy: .public)")
                self.onTriggerUp()
            }
        }
        return true
    }

    private func clearHoldTriggerReleaseConfirmationTask() {
        holdTriggerReleaseConfirmationTask?.cancel()
        holdTriggerReleaseConfirmationTask = nil
    }

    private func clearToggleTapRescueTask() {
        toggleTapRescueTask?.cancel()
        toggleTapRescueTask = nil
    }

    private func resetObservedInputState() {
        fnDown = false
        hidFnDown = false
        hidRightOptionDown = false
        hidControlDown = false
        keyEventTriggerDown = false
        flagsFnDown = false
        flagsRightOptionDown = false
        systemTriggerDown = false
        pollTriggerDown = false
        customKeysDown.removeAll()
        flagsControlDown = false
        pollControlDown = false
        recordingActive = false
        recordingLocked = false
        pendingLockedStop = false
        pendingLockAfterStart = false
        lockChordKeyDown = false
        suppressNextTriggerUpEnd = false
        clearDeferredLockChordAction()
        clearHoldTriggerReleaseConfirmationTask()
        clearToggleTapRescueTask()
        pendingHoldEnd = false
        toggleDictationState = .idle
        toggleTapEligible = false
        toggleTapInvalidated = false
        toggleStartActionAt = nil
        lastToggleTapActionAt = nil
        lastToggleStopActionAt = nil
        toggleStopFinalizing = false
        pendingToggleRestart = false
        captureTriggerStateMachine.reset()
        escapeKeyDown = false
        startTask?.cancel()
        startTask = nil
        spaceChordSuppressionState.resetObservedTriggerState()
        refreshEventTapModeIfNeeded()
    }

    private func clearPendingLockIfIdle() {
        guard !recordingLocked, startTask == nil, !fnDown else { return }
        pendingLockAfterStart = false
    }

    private func clearDeferredLockChordAction() {
        lockChordGraceTask?.cancel()
        lockChordGraceTask = nil
        deferredLockChordAction = .none
    }

#if DEBUG
    func debugConfigure(
        triggers: [HotkeyTrigger] = [.fn],
        mode: HotkeyMode = .hold,
        holdToTalkLockEnabled: Bool = true
    ) {
        applyTriggers(triggers)
        self.mode = mode.normalized
        self.holdToTalkLockEnabled = holdToTalkLockEnabled
        spaceChordSuppressionState.setLockChordEnabled(holdToTalkLockEnabled)
        resetObservedInputState()
    }

    func debugConfigure(
        trigger: HotkeyTrigger = .fn,
        mode: HotkeyMode = .hold,
        holdToTalkLockEnabled: Bool = true
    ) {
        debugConfigure(
            triggers: [trigger],
            mode: mode,
            holdToTalkLockEnabled: holdToTalkLockEnabled
        )
    }

    var debugWantsActiveEventTap: Bool {
        desiredEventTapMode == .activeSuppression
    }

    func debugSetTriggerHeldForTapPolicy(_ isHeld: Bool) {
        fnDown = isHeld
        refreshEventTapModeIfNeeded()
    }

    func debugSetLockChordHeldForTapPolicy(_ isHeld: Bool) {
        lockChordKeyDown = isHeld
        refreshEventTapModeIfNeeded()
    }

    func debugSimulateTriggerDown(controlHeld: Bool = false) {
        onTriggerDown(controlHeld: controlHeld)
    }

    func debugSimulateTriggerUp() {
        onTriggerUp()
    }

    func debugAllowImmediateToggleStop() {
        toggleStartActionAt = Date(timeIntervalSinceNow: -Self.toggleStopArmDelay)
    }

    func debugExpireToggleTapBounceCooldown() {
        lastToggleTapActionAt = Date(timeIntervalSinceNow: -Self.toggleTapActionCooldown)
    }

    func debugExpireToggleStopBounceCooldown() {
        lastToggleStopActionAt = Date(timeIntervalSinceNow: -Self.toggleStopBounceCooldown)
    }

    func debugSimulateObservedTriggerDrop(source: String = "debugDrop") {
        clearObservedTriggerState()
        refreshTriggerState(source: source)
    }

    func debugSetCurrentKeyState(_ isPressed: Bool, for keyCode: UInt16) {
        keyStateOverrides[CGKeyCode(keyCode)] = isPressed
        let overrides = keyStateOverrides
        spaceChordSuppressionState.debugSetKeyStateProvider { keyCode in
            if let override = overrides[CGKeyCode(keyCode)] {
                return override
            }
            return HotkeyManager.defaultKeyState(CGKeyCode(keyCode))
        }
    }

    func debugClearCurrentKeyStates() {
        keyStateOverrides.removeAll()
        spaceChordSuppressionState.debugSetKeyStateProvider { keyCode in
            HotkeyManager.defaultKeyState(CGKeyCode(keyCode))
        }
    }

    func debugSimulateLockChordKeyDown() {
        handleLockChordKeyDown()
    }

    func debugSimulateLockChordKeyUp() {
        lockChordKeyDown = false
    }

    func debugSimulateHIDFnDown() {
        handleHIDValue(usagePage: 0xFF, usage: 0x03, intValue: 1)
    }

    func debugSimulateHIDFnUp() {
        handleHIDValue(usagePage: 0xFF, usage: 0x03, intValue: 0)
    }

    func debugSimulateTriggerKeyDown(keyCode: UInt16 = 63) {
        handleKeyEvent(type: .keyDown, keyCode: keyCode)
    }

    func debugSimulateTriggerKeyUp(keyCode: UInt16 = 63) {
        handleKeyEvent(type: .keyUp, keyCode: keyCode)
    }

    func debugSimulateEscapeKeyDown() {
        handleKeyEvent(type: .keyDown, keyCode: Self.escapeKeyCode)
    }

    func debugSimulateEscapeKeyUp() {
        handleKeyEvent(type: .keyUp, keyCode: Self.escapeKeyCode)
    }

    func debugSimulateCommandChord(function: Bool, shift: Bool) {
        var modifierFlags: NSEvent.ModifierFlags = []
        if function {
            modifierFlags.insert(.function)
        }
        if shift {
            modifierFlags.insert(.shift)
        }
        handleCommandChord(modifierFlags: modifierFlags)
    }

    func debugSimulateFlagsChanged(
        function: Bool,
        shift: Bool,
        control: Bool = false,
        command: Bool = false,
        option: Bool = false,
        keyCode: UInt16,
        deviceKeyCodes: Set<UInt16>? = nil
    ) {
        let modifierFlags = Self.debugModifierFlags(
            function: function,
            shift: shift,
            control: control,
            command: command,
            option: option,
            changedKeyCode: keyCode,
            deviceKeyCodes: deviceKeyCodes
        )
        handleFlagsChanged(modifierFlags: modifierFlags, keyCode: keyCode)
    }

    func debugSimulateSuppressionFlagsChanged(
        function: Bool,
        shift: Bool,
        control: Bool = false,
        command: Bool = false,
        option: Bool = false,
        keyCode: UInt16,
        deviceKeyCodes: Set<UInt16>? = nil
    ) {
        let modifierFlags = Self.debugModifierFlags(
            function: function,
            shift: shift,
            control: control,
            command: command,
            option: option,
            changedKeyCode: keyCode,
            deviceKeyCodes: deviceKeyCodes
        )
        let flags = CGEventFlags(rawValue: UInt64(modifierFlags.rawValue))
        spaceChordSuppressionState.observeEvent(eventType: .flagsChanged, keyCode: keyCode, flags: flags)
    }

    var debugSuppressionHasObservedTriggerDown: Bool {
        spaceChordSuppressionState.anyObservedTriggerDown()
    }

    private static func debugModifierFlags(
        function: Bool,
        shift: Bool,
        control: Bool,
        command: Bool,
        option: Bool,
        changedKeyCode: UInt16,
        deviceKeyCodes: Set<UInt16>?
    ) -> NSEvent.ModifierFlags {
        var modifierFlags: NSEvent.ModifierFlags = []
        if function {
            modifierFlags.insert(.function)
        }
        if shift {
            modifierFlags.insert(.shift)
        }
        if control {
            modifierFlags.insert(.control)
        }
        if command {
            modifierFlags.insert(.command)
        }
        if option {
            modifierFlags.insert(.option)
        }

        let effectiveDeviceKeyCodes: Set<UInt16>
        if let deviceKeyCodes {
            effectiveDeviceKeyCodes = deviceKeyCodes
        } else if let descriptor = SideSpecificModifierKey.descriptor(for: changedKeyCode),
                  modifierFlags.contains(descriptor.familyFlag) {
            effectiveDeviceKeyCodes = [changedKeyCode]
        } else {
            effectiveDeviceKeyCodes = []
        }

        let rawValue = effectiveDeviceKeyCodes.reduce(modifierFlags.rawValue) { partialValue, keyCode in
            guard let descriptor = SideSpecificModifierKey.descriptor(for: keyCode) else {
                return partialValue
            }
            return partialValue | descriptor.deviceMask
        }

        return NSEvent.ModifierFlags(rawValue: rawValue)
    }

    func debugSimulateHIDSpaceDown() {
        handleHIDValue(
            usagePage: UInt32(kHIDPage_KeyboardOrKeypad),
            usage: 0x2C,
            intValue: 1
        )
    }

    func debugSimulateHIDSpaceUp() {
        handleHIDValue(
            usagePage: UInt32(kHIDPage_KeyboardOrKeypad),
            usage: 0x2C,
            intValue: 0
        )
    }

    func debugShouldSuppressSpaceTapEvent(eventType: CGEventType, keyCode: UInt16 = 49, triggerPressed: Bool) -> Bool {
        spaceChordSuppressionState.debugShouldSuppressSpaceEvent(
            eventType: eventType,
            keyCode: keyCode,
            triggerPressed: triggerPressed
        )
    }
#endif

    private static func defaultKeyState(_ keyCode: CGKeyCode) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: keyCode)
            || CGEventSource.keyState(.combinedSessionState, key: keyCode)
    }

    private func currentKeyState(_ keyCode: CGKeyCode) -> Bool {
        if let override = keyStateOverrides[keyCode] {
            return override
        }

        return Self.defaultKeyState(keyCode)
    }

    private func isFnPressedInCurrentState() -> Bool {
        currentKeyState(63)
            || currentKeyState(0xB3)
    }

    private func isRightOptionPressedInCurrentState() -> Bool {
        currentKeyState(61)
    }

    private func isTriggerPressedInCurrentState() -> Bool {
        let customPressed = customKeyCodes.contains { keyCode in
            currentKeyState(CGKeyCode(keyCode))
        }

        return (shouldObserveFnTrigger && isFnPressedInCurrentState())
            || (shouldObserveRightOptionTrigger && isRightOptionPressedInCurrentState())
            || customPressed
    }

    private func clearObservedTriggerState() {
        hidFnDown = false
        hidRightOptionDown = false
        keyEventTriggerDown = false
        flagsFnDown = false
        flagsRightOptionDown = false
        systemTriggerDown = false
        pollTriggerDown = false
        customKeysDown.removeAll()
        spaceChordSuppressionState.resetObservedTriggerState()
        refreshEventTapModeIfNeeded()
    }

    private func isFnPressed(modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        modifierFlags.contains(.function)
    }

    private func isRightOptionPressed(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        if let pressed = SideSpecificModifierKey.isPressed(
            keyCode: 61,
            modifierFlags: modifierFlags
        ) {
            return pressed
        }

        return currentKeyState(61)
    }

    private func isCustomModifierPressed(
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> Bool {
        if let pressed = SideSpecificModifierKey.isPressed(
            keyCode: keyCode,
            modifierFlags: modifierFlags
        ) {
            return pressed
        }

        if SideSpecificModifierKey.descriptor(for: keyCode) != nil {
            return currentKeyState(CGKeyCode(keyCode))
        }

        switch keyCode {
        case 57:     return modifierFlags.contains(.capsLock)
        case 63:     return modifierFlags.contains(.function)
        default:     return false
        }
    }

    private func updateCustomModifierState(modifierFlags: NSEvent.ModifierFlags, changedKeyCode: UInt16) {
        for keyCode in customKeyCodes where KeyCodeNames.isModifierKey(keyCode) {
            guard SideSpecificModifierKey.shouldUpdateState(
                for: keyCode,
                modifierFlags: modifierFlags,
                changedKeyCode: changedKeyCode
            ) else {
                continue
            }

            if isCustomModifierPressed(
                modifierFlags: modifierFlags,
                keyCode: keyCode
            ) {
                customKeysDown.insert(keyCode)
            } else {
                customKeysDown.remove(keyCode)
            }
        }
    }

}
