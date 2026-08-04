import Foundation
import IOKit
import IOKit.pwr_mgt
import os
import Defaults

/// Switches the active microphone away from the laptop's built-in array when
/// the lid is closed (clamshell mode), since the internal mic is muffled or
/// unusable. Restores the previous selection when the lid reopens.
@MainActor
final class ClamshellMicrophoneSwitcher {

    private static let log = Logger.resonant("ClamshellMic")
    private static let clamshellPropertyKey = "AppleClamshellState"

    private let settingsManager: SettingsManager
    private let audioInputDeviceManager: AudioInputDeviceManager

    /// Invoked after the active microphone is changed by the switcher. AppState
    /// uses this to refresh routing state and re-warm low-latency capture.
    var onSelectionChanged: (() -> Void)?
    var onAutomaticSwitch: ((_ previousDevice: AudioInputDevice, _ newDevice: AudioInputDevice) -> Void)?

    private var rootDomainService: io_service_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notificationIterator: io_object_t = 0
    private var lidClosed = false
    private var preClamshellDeviceUID: String?
    private var switchedToUID: String?
    private var didSwitchOnClamshell = false
    private var isStarted = false

    init(
        settingsManager: SettingsManager,
        audioInputDeviceManager: AudioInputDeviceManager
    ) {
        self.settingsManager = settingsManager
        self.audioInputDeviceManager = audioInputDeviceManager
    }

    func start() {
        guard !isStarted else { return }
        restorePersistedBookkeeping()
        isStarted = true
        installLidObserver()
        lidClosed = Self.readLidClosed() ?? false
        if lidClosed {
            switchAwayFromBuiltInIfNeeded()
        } else if didSwitchOnClamshell {
            restorePreClamshellDevice()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        removeLidObserver()
        if didSwitchOnClamshell {
            restorePreClamshellDevice()
        }
    }

    /// Re-evaluate after the available device list changes. If the lid is
    /// closed, take another pass now in case a new external mic appeared or
    /// the previously selected one disappeared.
    func reevaluateAfterDeviceChange() {
        guard isStarted, lidClosed else { return }
        switchAwayFromBuiltInIfNeeded()
    }

    // MARK: - IOKit observation

    private func installLidObserver() {
        let port = kIOMainPortDefault
        let service = IOServiceGetMatchingService(port, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            Self.log.warning("Could not match IOPMrootDomain; clamshell switch disabled")
            return
        }
        rootDomainService = service

        let notifyPort = IONotificationPortCreate(port)
        notificationPort = notifyPort
        if let notifyPort,
           let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else { return }
            let switcher = Unmanaged<ClamshellMicrophoneSwitcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                switcher.handleInterestEvent()
            }
        }

        let result = IOServiceAddInterestNotification(
            notifyPort,
            service,
            kIOGeneralInterest,
            callback,
            context,
            &notificationIterator
        )
        if result != KERN_SUCCESS {
            Self.log.error("IOServiceAddInterestNotification failed: \(result)")
        }
    }

    private func removeLidObserver() {
        if notificationIterator != 0 {
            IOObjectRelease(notificationIterator)
            notificationIterator = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if rootDomainService != 0 {
            IOObjectRelease(rootDomainService)
            rootDomainService = 0
        }
    }

    private func handleInterestEvent() {
        let nextLidClosed = Self.readLidClosed() ?? false
        guard nextLidClosed != lidClosed else { return }
        lidClosed = nextLidClosed
        Self.log.info("Lid state changed, closed=\(nextLidClosed)")
        if nextLidClosed {
            switchAwayFromBuiltInIfNeeded()
        } else if didSwitchOnClamshell {
            restorePreClamshellDevice()
        }
    }

    // MARK: - Switch logic

    private func switchAwayFromBuiltInIfNeeded() {
        guard settingsManager.clamshellMicSwitchEnabled else { return }
        audioInputDeviceManager.refresh()

        let currentSelection = settingsManager.inputDeviceUID
        guard let effective = audioInputDeviceManager.effectiveDevice(for: currentSelection),
              effective.isBuiltIn else {
            return
        }

        guard let candidate = audioInputDeviceManager.firstNonBuiltInDevice(excluding: effective.id) else {
            Self.log.info("Lid closed but no non-built-in microphone available")
            return
        }

        if !didSwitchOnClamshell {
            preClamshellDeviceUID = currentSelection
        }
        didSwitchOnClamshell = true
        switchedToUID = candidate.id
        persistBookkeeping()
        settingsManager.inputDeviceUID = candidate.id
        onSelectionChanged?()
        onAutomaticSwitch?(effective, candidate)
        Self.log.info("Lid closed → switched microphone to \(candidate.name)")
    }

    private func restorePreClamshellDevice() {
        let target = preClamshellDeviceUID
        let switchedToUID = switchedToUID
        let shouldRestore = switchedToUID != nil && settingsManager.inputDeviceUID == switchedToUID

        clearBookkeeping()

        guard shouldRestore else { return }

        settingsManager.inputDeviceUID = target
        onSelectionChanged?()
        Self.log.info("Lid opened → restored previous microphone selection")
    }

    private func restorePersistedBookkeeping() {
        preClamshellDeviceUID = Defaults[.clamshellMicPreSwitchUID]
        switchedToUID = Defaults[.clamshellMicSwitchedToUID]
        didSwitchOnClamshell = switchedToUID != nil
    }

    private func persistBookkeeping() {
        Defaults[.clamshellMicPreSwitchUID] = preClamshellDeviceUID
        Defaults[.clamshellMicSwitchedToUID] = switchedToUID
    }

    private func clearBookkeeping() {
        preClamshellDeviceUID = nil
        switchedToUID = nil
        didSwitchOnClamshell = false
        Defaults[.clamshellMicPreSwitchUID] = nil
        Defaults[.clamshellMicSwitchedToUID] = nil
    }

    // MARK: - Lid state probe

    private static func readLidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            clamshellPropertyKey as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        let value = unmanaged.takeRetainedValue()
        return (value as? NSNumber)?.boolValue
    }
}
