import AppKit
import ApplicationServices
import AVFoundation
import LaunchAtLogin
import Sparkle
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    let appState = AppState()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var updaterController: SPUStandardUpdaterController?
    private var availableUpdateTitle: String?
    private var pendingAutomaticUpdateInstall: (() -> Void)?
    private var didStartUpdater = false
    private var didPresentInstallLocationAlert = false
    private let idleStatusImage = AppDelegate.makeStatusImage(resourceBaseName: "trayIconTemplate", filledFallback: false)
    private let recordingStatusImage = AppDelegate.makeStatusImage(resourceBaseName: "trayIconRecordingTemplate", filledFallback: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        // Cap all AX calls at 150ms process-wide. Default is 6 seconds, which
        // lets a wedged target (Electron apps especially) stall dictation and
        // paste for multiple seconds. Setting the timeout on the system-wide
        // element applies to every AXUIElement in this process per Apple's
        // AXUIElement.h docs.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.15)
        MainThreadStallMonitor.shared.start()
        SingleInstanceGuard.terminateOlderInstances()
        guard presentInstallLocationWarningIfNeeded() else {
            NSApp.terminate(nil)
            return
        }
        if AppFeatureVisibility.hostedServices {
            AuthManager.registerPreferredURLSchemeHandler()
        }
        LaunchAtLogin.migrateIfNeeded()
        appState.settingsManager.synchronizeLaunchAtLoginState()
        installMainMenu()
        if AppRuntime.supportsUserNotifications {
            UNUserNotificationCenter.current().delegate = self
            appState.meetingPromptNotifier.configure()
        }

        let sparkleFeedURL = (Bundle.main.infoDictionary?["SUFeedURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if AppRuntime.hasValidMainBundle, !sparkleFeedURL.isEmpty {
            // Defer automatic update checks during onboarding so fresh installs
            // don't immediately show an "update available" prompt.
            let shouldStartImmediately = appState.settingsManager.onboardingCompleted
            didStartUpdater = shouldStartImmediately
            updaterController = SPUStandardUpdaterController(
                startingUpdater: shouldStartImmediately,
                updaterDelegate: self,
                userDriverDelegate: self
            )
            enableAutomaticUpdateDownloadsIfAllowed()
            appState.onRelaunchForUpdate = { [weak self] in
                guard let self else { return }
                if let pendingAutomaticUpdateInstall {
                    pendingAutomaticUpdateInstall()
                } else {
                    updaterController?.checkForUpdates(nil)
                }
            }
        }

        appState.onMenuBarRecordingActivityChange = { [weak self] isRecording in
            self?.updateStatusItemIcon(isRecording: isRecording)
            self?.rebuildMenu()
        }

        if !didStartUpdater {
            NotificationCenter.default.addObserver(
                forName: .onboardingCompleted,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.startUpdaterIfReady()
                }
            }
        }

        setupStatusItem()
        Task { await appState.launch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainThreadStallMonitor.shared.stop()
        appState.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState.refreshRuntimePermissions()
        startUpdaterIfReady()
        if AppFeatureVisibility.hostedServices {
            Task { await appState.refreshAuthenticationStateFromPersistence() }
        }
        rebuildMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            appState.showPrimaryWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard AppFeatureVisibility.hostedServices else { return }
        for url in urls where AuthManager.isAppScheme(url) {
            Task { await appState.handleIncomingURL(url) }
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.setAccessibilityLabel("Resonant")
        updateStatusItemIcon(isRecording: appState.isRecording)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusMenu = menu
        statusItem?.menu = menu

        rebuildMenu()
    }

    func rebuildMenu() {
        appState.refreshAudioInputStatus()

        let menu = statusMenu ?? NSMenu()
        menu.removeAllItems()

        // A missing permission means dictation is broken, so it leads the menu.
        // Absent entirely when everything is granted.
        let missingPermissions = MissingSystemPermission.current()
        if !missingPermissions.isEmpty {
            let fixPermissionsItem = NSMenuItem(title: "Fix Permissions…", action: nil, keyEquivalent: "")
            fixPermissionsItem.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Permissions"
            )
            fixPermissionsItem.image?.size = NSSize(width: 14, height: 14)
            fixPermissionsItem.submenu = buildPermissionRepairMenu(missing: missingPermissions)
            menu.addItem(fixPermissionsItem)
            menu.addItem(.separator())
        }

        let homeItem = NSMenuItem(title: "Home", action: #selector(openHome), keyEquivalent: "")
        homeItem.target = self
        homeItem.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Home")
        homeItem.image?.size = NSSize(width: 14, height: 14)
        menu.addItem(homeItem)

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let pasteLastTranscriptItem = NSMenuItem(
            title: "Paste last transcript",
            action: #selector(pasteLastTranscript),
            keyEquivalent: "v"
        )
        pasteLastTranscriptItem.target = self
        pasteLastTranscriptItem.keyEquivalentModifierMask = [.control, .command]
        pasteLastTranscriptItem.isEnabled = appState.canReuseLastDictation
        pasteLastTranscriptItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste")
        pasteLastTranscriptItem.image?.size = NSSize(width: 14, height: 14)
        menu.addItem(pasteLastTranscriptItem)

        // Meeting recording
        if let manager = appState.meetingRecorderManager {
            let meetingItem = NSMenuItem(
                title: manager.isRecording ? "Stop Meeting Recording" : "Start Meeting Recording",
                action: #selector(toggleMeetingRecording),
                keyEquivalent: ""
            )
            meetingItem.target = self
            meetingItem.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Meeting")
            meetingItem.image?.size = NSSize(width: 14, height: 14)
            if manager.isRecording {
                let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                dot?.size = NSSize(width: 8, height: 8)
                meetingItem.image = dot
            }
            menu.addItem(meetingItem)
        }
        menu.addItem(.separator())

        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        hotkeyItem.image = NSImage(systemSymbolName: "command.key", accessibilityDescription: "Hotkey")
        hotkeyItem.image?.size = NSSize(width: 14, height: 14)
        hotkeyItem.submenu = buildTriggerMenu()
        menu.addItem(hotkeyItem)

        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Microphone")
        microphoneItem.image?.size = NSSize(width: 14, height: 14)
        microphoneItem.submenu = buildMicrophoneMenu()
        menu.addItem(microphoneItem)
        menu.addItem(.separator())

        let contactSupportItem = NSMenuItem(title: "Contact support", action: #selector(openSupport), keyEquivalent: "")
        contactSupportItem.target = self
        contactSupportItem.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: "Email")
        contactSupportItem.image?.size = NSSize(width: 14, height: 14)
        menu.addItem(contactSupportItem)

        let checkForUpdatesItem = NSMenuItem(
            title: availableUpdateTitle ?? "Check for updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        checkForUpdatesItem.isEnabled = updaterController != nil
        menu.addItem(checkForUpdatesItem)

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let versionItem = NSMenuItem(title: "Resonant v\(appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Resonant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        if statusMenu == nil {
            menu.delegate = self
            menu.autoenablesItems = false
            statusMenu = menu
        }
        statusItem?.menu = menu
    }

    private func updateStatusItemIcon(isRecording: Bool) {
        guard let button = statusItem?.button else { return }
        let image = (isRecording ? recordingStatusImage : idleStatusImage) ?? idleStatusImage
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        button.image = image.map { AppDelegate.shiftedDownStatusImage($0, by: 0.5) } ?? image
    }

    // The system centers status item images vertically. To nudge the logo
    // down by N points, render it onto a canvas that is 2N points taller
    // and draw the logo at the bottom edge — centering then places the
    // logo N points below its original position.
    private static func shiftedDownStatusImage(_ source: NSImage, by offset: CGFloat) -> NSImage {
        let canvasSize = NSSize(width: source.size.width, height: source.size.height + offset * 2)
        let shifted = NSImage(size: canvasSize)
        shifted.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: source.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        shifted.unlockFocus()
        shifted.isTemplate = true
        return shifted
    }

    private static func makeStatusImage(resourceBaseName: String, filledFallback: Bool) -> NSImage? {
        if let image = loadStatusImageFromResources(resourceBaseName: resourceBaseName) {
            return image
        }

        return makeFallbackStatusImage(filled: filledFallback)
    }

    private static func loadStatusImageFromResources(resourceBaseName: String) -> NSImage? {
        guard let resourceBundle = AppResources.bundle(named: AppResources.appBundleName) else {
            return nil
        }

        let image = NSImage(size: NSSize(width: 16, height: 16))
        for resourceName in [resourceBaseName, "\(resourceBaseName)@2x"] {
            guard let url = resourceBundle.url(forResource: resourceName, withExtension: "png"),
                  let loadedImage = NSImage(contentsOf: url) else {
                continue
            }
            for representation in loadedImage.representations {
                image.addRepresentation(representation)
            }
        }

        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }

    private static func makeFallbackStatusImage(filled: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()

        let path = NSBezierPath(
            roundedRect: NSRect(x: 3.5, y: 3.5, width: 9, height: 9),
            xRadius: 1.5,
            yRadius: 1.5
        )
        var transform = AffineTransform(translationByX: 8, byY: 8)
        transform.rotate(byDegrees: 45)
        transform.translate(x: -8, y: -8)
        path.transform(using: transform)

        NSColor.black.setFill()
        NSColor.black.setStroke()
        if filled {
            path.fill()
        } else {
            path.lineWidth = 1.5
            path.stroke()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        appState.refreshRuntimePermissions()
        rebuildMenu()
    }

    /// A system permission dictation needs that the user has not granted.
    /// Recomputed on every menu open (`menuWillOpen` → `rebuildMenu`) so the
    /// item disappears as soon as the permission is fixed.
    private enum MissingSystemPermission: String, CaseIterable {
        case microphone
        case accessibility
        case inputMonitoring

        var menuTitle: String {
            switch self {
            case .microphone: "Allow Microphone…"
            case .accessibility: "Allow Accessibility…"
            case .inputMonitoring: "Allow Input Monitoring…"
            }
        }

        var isGranted: Bool {
            switch self {
            case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            case .accessibility: AXIsProcessTrusted()
            case .inputMonitoring: CGPreflightListenEventAccess()
            }
        }

        static func current() -> [MissingSystemPermission] {
            allCases.filter { !$0.isGranted }
        }
    }

    private static let microphonePrivacySettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    private func buildPermissionRepairMenu(missing: [MissingSystemPermission]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for permission in missing {
            let item = NSMenuItem(
                title: permission.menuTitle,
                action: #selector(openPermissionSettings(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = permission.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let recheckItem = NSMenuItem(
            title: "Re-check permissions",
            action: #selector(refreshPermissions),
            keyEquivalent: ""
        )
        recheckItem.target = self
        menu.addItem(recheckItem)

        return menu
    }

    private func buildTriggerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let selectedTrigger = appState.settingsManager.hotkeyTrigger

        var menuTriggers = HotkeyTrigger.presets
        // Include the current custom trigger in the menu if it's not a preset
        if case .custom = selectedTrigger {
            menuTriggers.append(selectedTrigger)
        }

        for trigger in menuTriggers {
            let item = NSMenuItem(title: trigger.displayName, action: #selector(selectTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = trigger.rawValue
            item.state = selectedTrigger == trigger ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let changeTriggerItem = NSMenuItem(
            title: "Change trigger key…",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        changeTriggerItem.target = self
        menu.addItem(changeTriggerItem)

        return menu
    }

    private func buildMicrophoneMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let selectedInputUID = appState.settingsManager.inputDeviceUID

        let systemDefaultName = appState.audioInputDeviceManager.devices.first(where: \.isSystemDefault)?.name
        let systemDefaultTitle = if let systemDefaultName {
            "System Default (\(systemDefaultName))"
        } else {
            "System Default"
        }
        let systemDefaultItem = NSMenuItem(
            title: systemDefaultTitle,
            action: #selector(selectSystemDefaultMicrophone),
            keyEquivalent: ""
        )
        systemDefaultItem.target = self
        systemDefaultItem.state = selectedInputUID == nil ? .on : .off
        menu.addItem(systemDefaultItem)

        if appState.audioInputDeviceManager.devices.isEmpty {
            let emptyStateItem = NSMenuItem(title: "No microphones found", action: nil, keyEquivalent: "")
            emptyStateItem.isEnabled = false
            menu.addItem(emptyStateItem)
        } else {
            for device in appState.audioInputDeviceManager.devices {
                let title = device.isSystemDefault ? "\(device.name) (Default)" : device.name
                let item = NSMenuItem(title: title, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.id
                item.state = selectedInputUID == device.id ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Microphones", action: #selector(refreshMicrophones), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        return menu
    }

    @objc private func toggleMeetingRecording() {
        Task {
            guard let manager = appState.meetingRecorderManager else { return }
            if manager.isRecording {
                await appState.stopMeetingRecording()
            } else {
                await appState.startMeetingRecording(startOrigin: .menuBar)
            }
            rebuildMenu()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if MicrophoneSwitchNotifier.handlesNotification(identifier: notification.request.identifier) {
            completionHandler([.banner, .list])
            return
        }

        if WordLearnPromptNotifier.isLearnPromptIdentifier(notification.request.identifier) {
            completionHandler([.banner, .list])
            return
        }

        guard notification.request.identifier == MeetingPromptNotifier.requestIdentifier
            || MeetingPromptNotifier.isCalendarPromptIdentifier(notification.request.identifier)
        else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self else { return }

            if MicrophoneSwitchNotifier.handlesNotification(identifier: response.notification.request.identifier) {
                if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                    self.appState.showPrimaryWindow(selectedTab: .dictation)
                }
                return
            }

            if WordLearnPromptNotifier.isLearnPromptIdentifier(response.notification.request.identifier) {
                self.appState.handleWordLearnPromptResponse(response)
                return
            }

            if MeetingPromptNotifier.isCalendarPromptIdentifier(response.notification.request.identifier) {
                await self.handleCalendarPromptResponse(response)
                return
            }

            guard response.notification.request.identifier == MeetingPromptNotifier.requestIdentifier else {
                return
            }

            if response.actionIdentifier == MeetingPromptNotifier.startRecordingActionIdentifier,
               let detectedMeeting = self.detectedMeeting(from: response.notification) {
                self.appState.analyticsManager.capture("meeting_prompt_accepted", properties: [
                    "app_name": detectedMeeting.app.name,
                    "has_calendar_hint": detectedMeeting.calendarHint != nil
                ])
                await self.appState.startMeetingRecording(
                    lifecycleMeeting: detectedMeeting,
                    recordingOriginOverride: .promptAccepted,
                    startOrigin: .prompt
                )
                self.rebuildMenu()
                return
            }

            if (response.actionIdentifier == MeetingPromptNotifier.skipPromptActionIdentifier
                || response.actionIdentifier == UNNotificationDismissActionIdentifier),
               let detectedMeeting = self.detectedMeeting(from: response.notification) {
                self.appState.dismissMeetingPrompt(for: detectedMeeting)
                return
            }

            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                self.appState.showPrimaryWindow(selectedTab: .meetings)
            }
        }
    }

    private func handleCalendarPromptResponse(_ response: UNNotificationResponse) async {
        guard let detectedMeeting = detectedMeeting(from: response.notification) else { return }

        let actionIdentifier = response.actionIdentifier
        if actionIdentifier == MeetingPromptNotifier.calendarPromptSkipActionIdentifier
            || actionIdentifier == UNNotificationDismissActionIdentifier {
            appState.dismissMeetingPrompt(for: detectedMeeting)
            return
        }

        let shouldOpenCall = actionIdentifier == MeetingPromptNotifier.calendarPromptOpenCallAndStartActionIdentifier
            || actionIdentifier == MeetingPromptNotifier.calendarPromptOpenCallOnlyActionIdentifier
            || actionIdentifier == UNNotificationDefaultActionIdentifier
        if shouldOpenCall {
            _ = openConferenceURL(for: detectedMeeting)
        }

        if actionIdentifier == MeetingPromptNotifier.calendarPromptOpenCallOnlyActionIdentifier {
            appState.dismissMeetingPrompt(for: detectedMeeting)
            return
        }

        guard actionIdentifier == MeetingPromptNotifier.calendarPromptOpenCallAndStartActionIdentifier
            || actionIdentifier == UNNotificationDefaultActionIdentifier
        else {
            return
        }

        appState.analyticsManager.capture("meeting_calendar_prompt_accepted", properties: [
            "app_name": detectedMeeting.app.name,
            "has_calendar_hint": detectedMeeting.calendarHint != nil,
            "opened_call": shouldOpenCall
        ])
        await appState.startMeetingRecording(
            lifecycleMeeting: detectedMeeting,
            recordingOriginOverride: .promptAccepted,
            startOrigin: .calendar
        )
        rebuildMenu()
    }

    private func openConferenceURL(for detectedMeeting: MeetingContextDetector.DetectedMeeting) -> Bool {
        let rawURL = detectedMeeting.calendarHint?.conferencingURL ?? detectedMeeting.browserURL
        guard let url = Self.normalizedConferenceURL(from: rawURL) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private nonisolated static func normalizedConferenceURL(from rawURL: String?) -> URL? {
        guard let trimmed = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }

    private func detectedMeeting(from notification: UNNotification) -> MeetingContextDetector.DetectedMeeting? {
        guard let appName = notification.request.content.userInfo[MeetingPromptNotifier.userInfoAppNameKey] as? String,
              let bundleID = notification.request.content.userInfo[MeetingPromptNotifier.userInfoBundleIDKey] as? String
        else {
            return nil
        }

        let windowTitle =
            (notification.request.content.userInfo[MeetingPromptNotifier.userInfoWindowTitleKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let browserURL =
            (notification.request.content.userInfo[MeetingPromptNotifier.userInfoBrowserURLKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarTitle =
            (notification.request.content.userInfo[MeetingPromptNotifier.userInfoCalendarTitleKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarID =
            (notification.request.content.userInfo[MeetingPromptNotifier.userInfoCalendarIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarStartTime =
            notification.request.content.userInfo[MeetingPromptNotifier.userInfoCalendarStartDateKey] as? Double
        let calendarEndTime =
            notification.request.content.userInfo[MeetingPromptNotifier.userInfoCalendarEndDateKey] as? Double
        let calendarURL =
            (notification.request.content.userInfo[MeetingPromptNotifier.userInfoCalendarURLKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarName =
            (notification.request.content.userInfo[MeetingPromptNotifier.userInfoCalendarNameKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let organizerName =
            (notification.request.content.userInfo[MeetingPromptNotifier.userInfoOrganizerNameKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attendeeNames =
            notification.request.content.userInfo[MeetingPromptNotifier.userInfoAttendeeNamesKey] as? [String] ?? []
        let attendeeEmails =
            notification.request.content.userInfo[MeetingPromptNotifier.userInfoAttendeeEmailsKey] as? [String] ?? []

        let calendarHint: MeetingCalendarHint?
        if let calendarTitle, !calendarTitle.isEmpty,
           let calendarStartTime, let calendarEndTime {
            let resolvedCalendarID = (calendarID?.isEmpty == false ? calendarID : nil) ?? UUID().uuidString
            calendarHint = MeetingCalendarHint(
                id: resolvedCalendarID,
                title: calendarTitle,
                startDate: Date(timeIntervalSince1970: calendarStartTime),
                endDate: Date(timeIntervalSince1970: calendarEndTime),
                organizerName: organizerName?.isEmpty == false ? organizerName : nil,
                attendeeNames: attendeeNames,
                attendeeEmails: attendeeEmails,
                conferencingURL: calendarURL?.isEmpty == false ? calendarURL : nil,
                calendarName: calendarName?.isEmpty == false ? calendarName : nil,
                searchableText: [calendarTitle.lowercased(), calendarURL?.lowercased()]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        } else {
            calendarHint = nil
        }

        return MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: bundleID, name: appName),
            windowTitle: windowTitle?.isEmpty == false ? windowTitle : nil,
            browserURL: browserURL?.isEmpty == false ? browserURL : nil,
            calendarHint: calendarHint,
            autoStartEligible: false
        )
    }

    @objc private func openHome() {
        appState.showPrimaryWindow(selectedTab: .home)
    }

    @objc private func openSettings() {
        appState.showPrimaryWindow()
        appState.openSettingsAtPreferredTab()
    }

    @objc private func openSupport() {
        appState.showPrimaryWindow(selectedTab: .support)
    }

    @objc private func pasteLastTranscript() {
        Task {
            await appState.retryLastDictation()
            rebuildMenu()
        }
    }

    @objc private func toggleHotMic() {
        appState.settingsManager.hotMicEnabled.toggle()
        rebuildMenu()
    }

    @objc private func checkForUpdates() {
        guard let updaterController else { return }
        updaterController.checkForUpdates(nil)
    }

    /// Starts the Sparkle updater if onboarding is complete but it hasn't been started yet.
    /// Called from both the `.onboardingCompleted` notification and `applicationDidBecomeActive`
    /// to cover the workspace-sync path where onboarding gets marked complete without the notification.
    private func startUpdaterIfReady() {
        guard !didStartUpdater, appState.settingsManager.onboardingCompleted else { return }
        didStartUpdater = true
        try? updaterController?.updater.start()
        enableAutomaticUpdateDownloadsIfAllowed()
    }

    private func enableAutomaticUpdateDownloadsIfAllowed() {
        guard let updater = updaterController?.updater, updater.allowsAutomaticUpdates else { return }
        updater.automaticallyDownloadsUpdates = true
    }

    private func makeAvailableUpdateTitle(for item: SUAppcastItem) -> String {
        let version = item.displayVersionString
        let build = item.versionString
        if build.isEmpty || build == version {
            return "Update Available: \(version)"
        }
        return "Update Available: \(version) (\(build))"
    }

    private func refreshAvailableUpdateState(
        _ item: SUAppcastItem?,
        phase: AppState.AvailableUpdateInfo.Phase = .available,
        clearsSidebarCard: Bool = true
    ) {
        availableUpdateTitle = item.map(makeAvailableUpdateTitle(for:))
        if let item {
            appState.availableUpdate = AppState.AvailableUpdateInfo(
                version: item.displayVersionString,
                build: item.versionString,
                phase: phase
            )
        } else if clearsSidebarCard {
            pendingAutomaticUpdateInstall = nil
            appState.availableUpdate = nil
        }
        rebuildMenu()
    }

    @objc private func refreshPermissions() {
        appState.requestRuntimePermissions()
        rebuildMenu()
    }

    @objc private func openInputMonitoringSettings() {
        appState.openInputMonitoringSettings()
    }

    @objc private func openAccessibilitySettings() {
        appState.openAccessibilitySettings()
    }

    @objc private func openMicrophoneSettings() {
        guard let url = URL(string: Self.microphonePrivacySettingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openPermissionSettings(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let permission = MissingSystemPermission(rawValue: rawValue) else {
            return
        }

        switch permission {
        case .microphone: openMicrophoneSettings()
        case .accessibility: openAccessibilitySettings()
        case .inputMonitoring: openInputMonitoringSettings()
        }
    }

    @objc private func refreshMicrophones() {
        appState.refreshAudioInputStatus()
        rebuildMenu()
    }

    @objc private func selectTrigger(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let trigger = HotkeyTrigger(rawValue: rawValue) else {
            return
        }

        appState.settingsManager.setHotkeyBindings(
            primary: trigger,
            alternates: appState.settingsManager.hotkeyAlternateTriggers
        )
        appState.hotkeyManager.reconfigure(
            triggers: appState.settingsManager.hotkeyTriggers,
            mode: appState.settingsManager.hotkeyMode,
            holdToTalkLockEnabled: appState.settingsManager.hotkeyHoldLockEnabled
        )
        rebuildMenu()
    }

    @objc private func selectSystemDefaultMicrophone() {
        appState.settingsManager.inputDeviceUID = nil
        appState.didChangeInputSelection()
        rebuildMenu()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? String else { return }
        appState.settingsManager.inputDeviceUID = deviceID
        appState.didChangeInputSelection()
        rebuildMenu()
    }

    #if DEBUG
    @objc private func showTestNotch() {
        appState.showTestNotch()
    }
    #endif

    // MARK: - Main menu (enables Cmd+C / Cmd+V / Cmd+X / Cmd+A in text fields)

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Resonant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleDictationFromMenu() {
        Task {
            if appState.isRecording {
                await appState.endDictation()
            } else {
                await appState.startDictation()
            }
            rebuildMenu()
        }
    }

    private func presentInstallLocationWarningIfNeeded() -> Bool {
        guard !didPresentInstallLocationAlert,
              let issue = AppRuntime.installLocationIssue else {
            return true
        }

        didPresentInstallLocationAlert = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = issue.title
        alert.informativeText = issue.message
        alert.addButton(withTitle: "Move & Relaunch")
        alert.addButton(withTitle: "Reveal Current App")
        alert.addButton(withTitle: "Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            installCurrentAppInApplicationsAndRelaunch()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default:
            break
        }

        return false
    }

    private func installCurrentAppInApplicationsAndRelaunch() {
        let fileManager = FileManager.default
        let sourceURL = Bundle.main.bundleURL.standardizedFileURL
        let destinationURL = AppRuntime.installedApplicationURL
        let stagingPrefix = AppRuntime.distributionFlavor == .community
            ? ".Resonant Community.app.installing"
            : ".Resonant.app.installing"
        let stagingURL = AppRuntime.applicationsDirectoryURL
            .appendingPathComponent("\(stagingPrefix)-\(UUID().uuidString)", isDirectory: true)

        do {
            terminateInstalledCopies(at: destinationURL)
            try? fileManager.removeItem(at: stagingURL)
            try runInstallTool("/usr/bin/ditto", arguments: [sourceURL.path, stagingURL.path])
            try runInstallTool("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", stagingURL.path])

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            try runInstallTool("/usr/bin/open", arguments: ["-n", destinationURL.path])
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            presentInstallFailure(error: error, destinationURL: destinationURL)
        }
    }

    private func terminateInstalledCopies(at destinationURL: URL) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let destinationPath = destinationURL.standardizedFileURL.path
        let installedCopies = NSRunningApplication
            .runningApplications(withBundleIdentifier: AppRuntime.bundleIdentifier)
            .filter { runningApp in
                runningApp.processIdentifier != currentPID
                    && runningApp.bundleURL?.standardizedFileURL.path == destinationPath
            }

        guard !installedCopies.isEmpty else { return }

        installedCopies.forEach { $0.terminate() }
        for _ in 0..<30 {
            if installedCopies.allSatisfy({ $0.isTerminated }) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        installedCopies.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    private func runInstallTool(_ executablePath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "com.resonance.resonant.install",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executablePath).lastPathComponent) failed with exit code \(process.terminationStatus)."
                ]
            )
        }
    }

    private func presentInstallFailure(error: Error, destinationURL: URL) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could Not Move Resonant"
        alert.informativeText = """
        Resonant could not install itself to \(destinationURL.path).

        \(error.localizedDescription)
        """
        alert.addButton(withTitle: "Open Applications")
        alert.addButton(withTitle: "Reveal Current App")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(AppRuntime.applicationsDirectoryURL)
        default:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }
}

@MainActor
extension AppDelegate: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        refreshAvailableUpdateState(item)

        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        refreshAvailableUpdateState(nil)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        refreshAvailableUpdateState(item, phase: .downloading)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        refreshAvailableUpdateState(item, phase: .preparingToInstall)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        refreshAvailableUpdateState(nil)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        refreshAvailableUpdateState(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        pendingAutomaticUpdateInstall = immediateInstallationBlock
        refreshAvailableUpdateState(item, phase: .readyToRestart)
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        refreshAvailableUpdateState(nil)
    }
}

@MainActor
extension AppDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        refreshAvailableUpdateState(update)

        if !state.userInitiated && !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        refreshAvailableUpdateState(nil, clearsSidebarCard: false)
    }

    func standardUserDriverWillFinishUpdateSession() {
        refreshAvailableUpdateState(nil, clearsSidebarCard: false)
    }
}
