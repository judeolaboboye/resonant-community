import AppKit
import Foundation
import os

@MainActor
final class MeetingContextDetector {

    private let log = Logger.resonant("MeetingDetector")

    struct DetectedMeeting: Sendable, Equatable {
        let app: MeetingApp
        let windowTitle: String?
        let browserURL: String?
        let calendarHint: MeetingCalendarHint?
        let autoStartEligible: Bool

        var isCalendarOnly: Bool {
            app.bundleID.caseInsensitiveCompare(MeetingContextDetector.calendarOnlyBundleID) == .orderedSame
        }

        var promptSignature: String {
            let normalizedBundleID = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let calendarEventID = calendarHint?.id.trimmedNilIfEmpty?.lowercased() {
                return "calendar|\(calendarEventID)"
            }
            if let normalizedMeetingURL = MeetingContextDetector.normalizedPromptMeetingURL(
                browserURL ?? calendarHint?.conferencingURL
            ) {
                return "url|\(normalizedMeetingURL)"
            }
            if let windowTitle = windowTitle?.trimmedNilIfEmpty {
                let normalizedWindowTitle = MeetingContextDetector.normalizedText(windowTitle)
                guard !normalizedWindowTitle.isEmpty else {
                    return "\(normalizedBundleID)|app|\(app.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
                }
                return "\(normalizedBundleID)|title|\(normalizedWindowTitle)"
            }
            return "\(normalizedBundleID)|app|\(app.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }

        var promptSuppressionKey: String {
            let normalizedBundleID = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let calendarEventID = calendarHint?.id.trimmedNilIfEmpty?.lowercased() {
                return "calendar|\(calendarEventID)"
            }
            if let normalizedMeetingURL = MeetingContextDetector.normalizedPromptMeetingURL(
                browserURL ?? calendarHint?.conferencingURL
            ) {
                return "url|\(normalizedMeetingURL)"
            }
            return "\(normalizedBundleID)|app"
        }

        var hasStablePromptIdentity: Bool {
            calendarHint?.id.trimmedNilIfEmpty != nil
                || MeetingContextDetector.normalizedPromptMeetingURL(
                    browserURL ?? calendarHint?.conferencingURL
                ) != nil
        }

        func matchesLifecycleIdentity(of other: DetectedMeeting) -> Bool {
            if app.bundleID.caseInsensitiveCompare(other.app.bundleID) == .orderedSame {
                return true
            }

            if promptSignature == other.promptSignature {
                return true
            }

            guard hasStablePromptIdentity || other.hasStablePromptIdentity else {
                return false
            }
            return promptSuppressionKey == other.promptSuppressionKey
        }
    }

    var onMeetingDetected: ((DetectedMeeting) async -> Void)?
    var onMeetingJoined: ((DetectedMeeting) async -> Void)?
    var onLifecycleMeetingUpdated: ((DetectedMeeting) async -> Void)?
    var shouldEndTrackedMeeting: ((MeetingEndCandidate) async -> Bool)?
    var onMeetingLeft: ((DetectedMeeting, LifecycleSignal) async -> Void)?

    private(set) var currentMeeting: DetectedMeeting?

    private let contextExtractor: ContextExtractor
    private let settingsManager: SettingsManager
    private let injectedAudioSignalSource: (any MeetingAudioSignalSource)?
    private let injectedCameraSignalSource: (any MeetingCameraSignalSource)?
    private let calendarHintSource: any MeetingCalendarHintSource
    private var audioSignalSource: (any MeetingAudioSignalSource)?
    private var cameraSignalSource: (any MeetingCameraSignalSource)?

    private struct LifecycleTrackingState {
        var meeting: DetectedMeeting
        var weakEndSignalCount = 0
    }

    struct MeetingEndCandidate: Equatable {
        let meeting: DetectedMeeting
        let lifecycleSignal: LifecycleSignal
        let isCameraActive: Bool
    }

    private struct DismissedPromptState {
        let suppressionKey: String
        let suppressedUntil: Date
        let survivesDetectionDrop: Bool
    }

    enum LifecycleSignal: Equatable {
        case active(DetectedMeeting)
        case ambiguous
        case weakEndSignal
        case strongEndSignal
    }

    private var appSwitchObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private let browserURLObserver = BrowserURLChangeObserver()
    private var pendingBrowserEventTask: Task<Void, Never>?
    private var audioSignalTask: Task<Void, Never>?
    private var cameraSignalTask: Task<Void, Never>?
    private var pendingDetectionTask: Task<Void, Never>?
    private var pendingAudioDetectionTask: Task<Void, Never>?
    private var lifecycleTrackingState: LifecycleTrackingState?
    private var lifecyclePollingTask: Task<Void, Never>?
    private var lastPromptSignature: String?
    private var lastPromptedAt: Date?
    private var dismissedPromptState: DismissedPromptState?
    private var isMicrophoneActive = false
    private var isCameraActive = false
    private var isMicrophoneDetectionReady = false

    private static let settleDelay: UInt64 = 900_000_000
    private static let browserEventSettleDelay: UInt64 = 150_000_000
    private static let audioDetectionDebounce: UInt64 = 3_000_000_000
    private static let repromptCooldown: TimeInterval = 15 * 60
    private static let dismissedPromptFallbackDuration: TimeInterval = 2 * 60 * 60
    private static let lifecyclePollInterval: UInt64 = 12_000_000_000
    private static let weakEndSignalThreshold = 2
    private static let calendarStartLeadTime: TimeInterval = 10 * 60
    private static let calendarEndGracePeriod: TimeInterval = 10 * 60
    private static let autoStartCalendarMatchThreshold = 4
    nonisolated static let calendarOnlyBundleID = "com.resonance.resonant.calendar"
    private static let calendarOnlyAppName = "Scheduled meeting"

    init(
        contextExtractor: ContextExtractor,
        settingsManager: SettingsManager,
        audioSignalSource: (any MeetingAudioSignalSource)? = nil,
        cameraSignalSource: (any MeetingCameraSignalSource)? = nil,
        calendarHintSource: any MeetingCalendarHintSource
    ) {
        self.contextExtractor = contextExtractor
        self.settingsManager = settingsManager
        self.injectedAudioSignalSource = audioSignalSource
        self.injectedCameraSignalSource = cameraSignalSource
        self.calendarHintSource = calendarHintSource
    }

    func start() {
        guard appSwitchObserver == nil, audioSignalTask == nil else { return }

        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleAppActivation(app)
            }
        }

        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.handleAppTermination(app)
            }
        }

        let audioSignalSource = activeAudioSignalSource()
        let cameraSignalSource = activeCameraSignalSource()

        isMicrophoneActive = audioSignalSource.currentValue()
        isMicrophoneDetectionReady = false
        audioSignalTask = Task { [weak self, audioSignalSource] in
            guard let self else { return }
            if self.isMicrophoneActive {
                await self.handleMicrophoneSignal(true)
            }
            for await isActive in audioSignalSource.signals {
                guard !Task.isCancelled else { break }
                await self.handleMicrophoneSignal(isActive)
            }
        }

        isCameraActive = cameraSignalSource.currentValue()
        cameraSignalTask = Task { [weak self, cameraSignalSource] in
            guard let self else { return }
            if self.isCameraActive {
                await self.handleCameraSignal(true)
            }
            for await isActive in cameraSignalSource.signals {
                guard !Task.isCancelled else { break }
                await self.handleCameraSignal(isActive)
            }
        }

        browserURLObserver.onBrowserEvent = { [weak self] app in
            self?.handleBrowserURLEvent(app)
        }
        browserURLObserver.start()

        Task { [weak self] in
            await self?.reevaluateDetection()
        }
    }

    func stop() {
        browserURLObserver.stop()
        pendingBrowserEventTask?.cancel()
        pendingBrowserEventTask = nil
        audioSignalTask?.cancel()
        audioSignalTask = nil
        cameraSignalTask?.cancel()
        cameraSignalTask = nil
        pendingDetectionTask?.cancel()
        pendingDetectionTask = nil
        pendingAudioDetectionTask?.cancel()
        pendingAudioDetectionTask = nil
        setCurrentMeeting(nil)
        stopLifecycleTracking()
        isMicrophoneActive = false
        isCameraActive = false
        isMicrophoneDetectionReady = false

        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }

        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
            self.appTerminationObserver = nil
        }

        releaseSignalSourcesIfNeeded()
    }

    private func activeAudioSignalSource() -> any MeetingAudioSignalSource {
        if let audioSignalSource { return audioSignalSource }
        let source = injectedAudioSignalSource ?? CoreAudioMeetingAudioSignalSource()
        audioSignalSource = source
        return source
    }

    private func activeCameraSignalSource() -> any MeetingCameraSignalSource {
        if let cameraSignalSource { return cameraSignalSource }
        let source = injectedCameraSignalSource ?? CoreMediaIOMeetingCameraSignalSource()
        cameraSignalSource = source
        return source
    }

    private func releaseSignalSourcesIfNeeded() {
        if injectedAudioSignalSource == nil {
            audioSignalSource = nil
        }
        if injectedCameraSignalSource == nil {
            cameraSignalSource = nil
        }
    }

    func evaluateFrontmostApplication() async {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            setCurrentMeeting(nil)
            return
        }
        await evaluate(app)
    }

    func reevaluateDetection() async {
        await evaluateFrontmostApplication()
        guard Self.shouldScanForActiveMeeting(
            isMicrophoneDetectionReady: isMicrophoneDetectionReady,
            isCameraActive: isCameraActive,
            isCalendarHintsEnabled: settingsManager.meetingUseCalendarHints
        ) else { return }
        await scanRunningApplicationsForActiveMeeting()
    }

    func beginLifecycleTracking(for meeting: DetectedMeeting) {
        lifecycleTrackingState = LifecycleTrackingState(meeting: meeting)
        ensureLifecyclePolling()
    }

    func stopLifecycleTracking() {
        lifecyclePollingTask?.cancel()
        lifecyclePollingTask = nil
        lifecycleTrackingState = nil
    }

    func refreshLifecycleTracking() async {
        await evaluateTrackedMeeting()
    }

    func requestCalendarAuthorizationIfNeeded() async -> Bool {
        await calendarHintSource.requestAuthorizationIfNeeded()
    }

    func recordPromptDismissal(for meeting: DetectedMeeting, now: Date = Date()) {
        dismissedPromptState = DismissedPromptState(
            suppressionKey: meeting.promptSuppressionKey,
            suppressedUntil: Self.dismissedPromptDeadline(for: meeting, now: now),
            survivesDetectionDrop: meeting.hasStablePromptIdentity
        )
    }

    private func handleBrowserURLEvent(_ app: NSRunningApplication) {
        log.info("handleBrowserURLEvent bundle=\(app.bundleIdentifier ?? "nil", privacy: .public)")
        pendingBrowserEventTask?.cancel()
        pendingBrowserEventTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.browserEventSettleDelay)
            guard !Task.isCancelled else { return }
            await self?.evaluate(app)
        }
    }

    private func handleAppActivation(_ app: NSRunningApplication) {
        pendingDetectionTask?.cancel()
        pendingDetectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.settleDelay)
            guard !Task.isCancelled else { return }
            await self?.evaluate(app)
        }
    }

    private func handleAppTermination(_ app: NSRunningApplication) async {
        guard let bundleID = app.bundleIdentifier?.lowercased(),
              let trackedMeeting = lifecycleTrackingState?.meeting,
              trackedMeeting.app.bundleID.lowercased() == bundleID
        else {
            return
        }

        await requestTrackedMeetingEnd(trackedMeeting, signal: .strongEndSignal)
    }

    private func evaluate(_ app: NSRunningApplication) async {
        log.info("evaluate bundle=\(app.bundleIdentifier ?? "nil", privacy: .public)")
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            setCurrentMeeting(nil)
            return
        }

        let context = await contextExtractor.extract(
            from: app,
            captureRichContext: true,
            allowBrowserAutomationFallback: false
        )
        log.info("extracted browserURL=\(context.browserURL, privacy: .public)")
        if let detectedMeeting = Self.detectMeeting(from: context) {
            log.info("detectMeeting=yes bundle=\(detectedMeeting.app.bundleID, privacy: .public) eligible=\(detectedMeeting.autoStartEligible)")
            let matchedHint = Self.bestCalendarHint(for: detectedMeeting, hints: await activeCalendarHints())
            let enrichedMeeting = DetectedMeeting(
                app: detectedMeeting.app,
                windowTitle: detectedMeeting.windowTitle,
                browserURL: detectedMeeting.browserURL,
                calendarHint: matchedHint,
                autoStartEligible: detectedMeeting.autoStartEligible
            )
            setCurrentMeeting(enrichedMeeting)
            if settingsManager.meetingRecordingEnabled,
               settingsManager.meetingJoinPromptEnabled,
               Self.shouldPromptImmediately(enrichedMeeting) {
                await deliverPromptIfNeeded(for: enrichedMeeting)
            }
        } else {
            log.info("detectMeeting=no")
            setCurrentMeeting(nil)
        }

        log.info("gating micReady=\(self.isMicrophoneDetectionReady) camera=\(self.isCameraActive) calendarHints=\(self.settingsManager.meetingUseCalendarHints) promptEnabled=\(self.settingsManager.meetingJoinPromptEnabled)")
        guard Self.shouldScanForActiveMeeting(
            isMicrophoneDetectionReady: isMicrophoneDetectionReady,
            isCameraActive: isCameraActive,
            isCalendarHintsEnabled: settingsManager.meetingUseCalendarHints
        ) else { return }
        await scanRunningApplicationsForActiveMeeting(preferredBundleID: app.bundleIdentifier)
    }

    /// Camera activation is a high-confidence meeting signal — no debounce, immediate scan.
    private func handleCameraSignal(_ isActive: Bool) async {
        isCameraActive = isActive
        guard isActive else { return }

        guard settingsManager.meetingRecordingEnabled,
              settingsManager.meetingJoinPromptEnabled || settingsManager.meetingAutoStartEnabled
        else {
            return
        }

        await scanRunningApplicationsForActiveMeeting()
    }

    private func handleMicrophoneSignal(_ isActive: Bool) async {
        isMicrophoneActive = isActive
        pendingAudioDetectionTask?.cancel()

        guard isActive else {
            isMicrophoneDetectionReady = false
            return
        }

        guard settingsManager.meetingRecordingEnabled,
              settingsManager.meetingJoinPromptEnabled || settingsManager.meetingAutoStartEnabled
        else {
            return
        }

        isMicrophoneDetectionReady = false
        pendingAudioDetectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.audioDetectionDebounce)
            guard !Task.isCancelled else { return }
            await self?.finishAudioDetectionDebounce()
        }
    }

    private func finishAudioDetectionDebounce() async {
        guard isMicrophoneActive else { return }
        isMicrophoneDetectionReady = true
        await scanRunningApplicationsForActiveMeeting()
    }

    private func scanRunningApplicationsForActiveMeeting(preferredBundleID: String? = nil) async {
        guard settingsManager.meetingRecordingEnabled else { return }
        let perEventAutoRecord = isMarkedForAutoRecord(preferredBundleID: preferredBundleID)
        guard settingsManager.meetingJoinPromptEnabled || settingsManager.meetingAutoStartEnabled || perEventAutoRecord else { return }
        let calendarHints = await activeCalendarHints()
        guard let detectedMeeting =
            await detectMeetingAcrossRunningApplications(
                preferredBundleID: preferredBundleID,
                calendarHints: calendarHints
            )
            ?? Self.calendarOnlyMeeting(from: calendarHints)
        else {
            return
        }

        let hasRuntimeMeetingSignal = isMicrophoneDetectionReady || isCameraActive
        let calendarPrimed = Self.isCalendarAutomationPrimed(detectedMeeting) || detectedMeeting.isCalendarOnly
        guard hasRuntimeMeetingSignal || calendarPrimed else { return }

        setCurrentMeeting(detectedMeeting)

        let matchedEventAutoRecord = isMarkedForAutoRecord(eventID: detectedMeeting.calendarHint?.id)

        if matchedEventAutoRecord {
            guard Self.shouldStartMarkedAutoRecord(
                detectedMeeting,
                hasRuntimeMeetingSignal: hasRuntimeMeetingSignal
            ) else {
                return
            }
            await onMeetingJoined?(detectedMeeting)
        } else if settingsManager.meetingJoinPromptEnabled {
            await deliverPromptIfNeeded(for: detectedMeeting)
        } else if settingsManager.meetingAutoStartEnabled && Self.shouldAutoStart(detectedMeeting) {
            await onMeetingJoined?(detectedMeeting)
        }
    }

    private func isMarkedForAutoRecord(eventID: String?) -> Bool {
        guard let eventID = eventID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventID.isEmpty else {
            return false
        }
        return settingsManager.meetingTimelineAutoRecordEventIDs.contains(eventID)
    }

    /// Quick pre-gate: if any currently active calendar event is flagged for auto-record,
    /// force the scan to proceed even when the global autoStart/joinPrompt toggles are off.
    private func isMarkedForAutoRecord(preferredBundleID: String?) -> Bool {
        guard !settingsManager.meetingTimelineAutoRecordEventIDs.isEmpty else { return false }
        return true
    }

    private func detectMeetingAcrossRunningApplications(
        preferredBundleID: String? = nil,
        calendarHints: [MeetingCalendarHint]
    ) async -> DetectedMeeting? {
        var bestMatch: DetectedMeeting?
        var bestScore = Int.min

        for app in orderedMeetingCandidateApplications(preferredBundleID: preferredBundleID) {
            let context = await contextExtractor.extract(
                from: app,
                captureRichContext: true,
                allowBrowserAutomationFallback: false
            )
            let detectedMeeting: DetectedMeeting?
            if let contextMeeting = Self.detectMeeting(from: context) {
                detectedMeeting = contextMeeting
            } else {
                detectedMeeting = await detectBrowserMeetingAcrossTabs(from: app)
            }
            guard let detectedMeeting else {
                log.debug("scan_candidate_no_match bundle=\(app.bundleIdentifier ?? "nil", privacy: .public)")
                continue
            }

            let matchedHint = Self.bestCalendarHint(for: detectedMeeting, hints: calendarHints)
            let enrichedMeeting = DetectedMeeting(
                app: detectedMeeting.app,
                windowTitle: detectedMeeting.windowTitle,
                browserURL: detectedMeeting.browserURL,
                calendarHint: matchedHint,
                autoStartEligible: detectedMeeting.autoStartEligible
            )
            let score = matchedHint.map { Self.calendarMatchScore(for: detectedMeeting, hint: $0) } ?? 0

            if bestMatch == nil || score > bestScore {
                bestMatch = enrichedMeeting
                bestScore = score
            }
        }

        return bestMatch
    }

    private func detectBrowserMeetingAcrossTabs(from app: NSRunningApplication) async -> DetectedMeeting? {
        guard BrowserCatalog.isBrowser(app.bundleIdentifier) else { return nil }
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? BrowserCatalog.displayName(for: bundleID) ?? ""

        let tabContexts = await Task.detached(priority: .utility) {
            BrowserAutomationSupport.allTabContexts(
                bundleId: bundleID,
                allowUserPrompt: false
            )
        }.value

        for tabContext in tabContexts {
            var context = ContextExtractor.Context()
            context.appName = appName
            context.bundleId = bundleID
            context.windowTitle = tabContext.windowTitle ?? ""
            context.browserURL = tabContext.browserURL ?? ""

            if let detectedMeeting = Self.detectMeeting(from: context) {
                log.info("detectMeeting=browser_tab bundle=\(bundleID, privacy: .public) url=\(context.browserURL, privacy: .public)")
                return detectedMeeting
            }
        }

        if !tabContexts.isEmpty {
            log.debug("browser_tab_scan_no_match bundle=\(bundleID, privacy: .public) tabs=\(tabContexts.count)")
        }
        return nil
    }

    private func orderedMeetingCandidateApplications(preferredBundleID: String? = nil) -> [NSRunningApplication] {
        let preferred = preferredBundleID?.lowercased()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()

        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
                return Self.canHostMeeting(bundleID: app.bundleIdentifier)
            }
            .sorted { lhs, rhs in
                let lhsPreferred = lhs.bundleIdentifier?.lowercased() == preferred
                let rhsPreferred = rhs.bundleIdentifier?.lowercased() == preferred
                if lhsPreferred != rhsPreferred { return lhsPreferred }

                let lhsFrontmost = lhs.bundleIdentifier?.lowercased() == frontmost
                let rhsFrontmost = rhs.bundleIdentifier?.lowercased() == frontmost
                if lhsFrontmost != rhsFrontmost { return lhsFrontmost }

                return (lhs.localizedName ?? "").localizedCaseInsensitiveCompare(rhs.localizedName ?? "") == .orderedAscending
            }
    }

    private func deliverPromptIfNeeded(for detectedMeeting: DetectedMeeting) async {
        let now = Date()
        if shouldSuppressDismissedPrompt(for: detectedMeeting, now: now) {
            return
        }
        guard Self.shouldPrompt(
            signature: detectedMeeting.promptSignature,
            lastSignature: lastPromptSignature,
            lastPromptedAt: lastPromptedAt,
            now: now
        ) else {
            return
        }

        lastPromptSignature = detectedMeeting.promptSignature
        lastPromptedAt = now
        await onMeetingDetected?(detectedMeeting)
    }

    private func ensureLifecyclePolling() {
        guard lifecyclePollingTask == nil else { return }

        lifecyclePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.lifecyclePollInterval)
                guard !Task.isCancelled else { return }
                await self?.evaluateTrackedMeeting()
            }
        }
    }

    private func evaluateTrackedMeeting() async {
        guard var tracking = lifecycleTrackingState else { return }
        if tracking.meeting.isCalendarOnly {
            if let promotedMeeting = await promotedCalendarOnlyLifecycleMeeting(from: tracking.meeting) {
                lifecycleTrackingState = LifecycleTrackingState(meeting: promotedMeeting)
                setCurrentMeeting(promotedMeeting)
                await onLifecycleMeetingUpdated?(promotedMeeting)
                return
            }

            if Self.calendarSuggestsMeetingEnded(tracking.meeting, now: Date()) {
                await requestTrackedMeetingEnd(tracking.meeting, signal: .weakEndSignal)
            }
            return
        }

        guard let runningApp = runningApplication(bundleID: tracking.meeting.app.bundleID) else {
            await requestTrackedMeetingEnd(tracking.meeting, signal: .strongEndSignal)
            return
        }

        let context = await contextExtractor.extract(
            from: runningApp,
            captureRichContext: true,
            allowBrowserAutomationFallback: false
        )
        let isFrontmostTrackedApp =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
            == tracking.meeting.app.bundleID.lowercased()

        switch Self.lifecycleSignal(
            for: context,
            expected: tracking.meeting,
            isFrontmostApp: isFrontmostTrackedApp
        ) {
        case .active(let updatedMeeting):
            tracking.meeting = Self.mergeCalendarHint(from: tracking.meeting, into: updatedMeeting)
            tracking.weakEndSignalCount = 0
            lifecycleTrackingState = tracking
            await onLifecycleMeetingUpdated?(tracking.meeting)
        case .ambiguous:
            if Self.calendarSuggestsMeetingEnded(tracking.meeting, now: Date()) {
                await requestTrackedMeetingEnd(tracking.meeting, signal: .weakEndSignal)
                return
            }
            tracking.weakEndSignalCount = 0
            lifecycleTrackingState = tracking
        case .weakEndSignal:
            if Self.calendarSuggestsMeetingEnded(tracking.meeting, now: Date()) {
                await requestTrackedMeetingEnd(tracking.meeting, signal: .weakEndSignal)
                return
            }
            tracking.weakEndSignalCount += 1
            lifecycleTrackingState = tracking
            guard tracking.weakEndSignalCount >= Self.weakEndSignalThreshold else { return }
            await requestTrackedMeetingEnd(tracking.meeting, signal: .weakEndSignal)
        case .strongEndSignal:
            await requestTrackedMeetingEnd(tracking.meeting, signal: .strongEndSignal)
        }
    }

    private func promotedCalendarOnlyLifecycleMeeting(
        from calendarOnlyMeeting: DetectedMeeting
    ) async -> DetectedMeeting? {
        guard let hint = calendarOnlyMeeting.calendarHint else { return nil }
        guard let detectedMeeting = await detectMeetingAcrossRunningApplications(calendarHints: [hint]) else {
            return nil
        }
        guard Self.shouldPromoteCalendarOnlyLifecycle(
            from: calendarOnlyMeeting,
            to: detectedMeeting,
            now: Date()
        ) else {
            return nil
        }

        return Self.mergeCalendarHint(from: calendarOnlyMeeting, into: detectedMeeting)
    }

    private func activeCalendarHints(now: Date = Date()) async -> [MeetingCalendarHint] {
        guard settingsManager.meetingUseCalendarHints else { return [] }
        return await calendarHintSource.activeMeetingHints(now: now)
    }

    private func requestTrackedMeetingEnd(
        _ meeting: DetectedMeeting,
        signal: LifecycleSignal
    ) async {
        let candidate = MeetingEndCandidate(
            meeting: meeting,
            lifecycleSignal: signal,
            isCameraActive: isCameraActive
        )
        if let shouldEndTrackedMeeting {
            let shouldEnd = await shouldEndTrackedMeeting(candidate)
            guard shouldEnd else { return }
        }

        await handleTrackedMeetingEnded(meeting, signal: signal)
    }

    private func handleTrackedMeetingEnded(
        _ meeting: DetectedMeeting,
        signal: LifecycleSignal
    ) async {
        stopLifecycleTracking()
        if currentMeeting?.app.bundleID.lowercased() == meeting.app.bundleID.lowercased() {
            setCurrentMeeting(nil)
        }
        await onMeetingLeft?(meeting, signal)
    }

    private func setCurrentMeeting(_ meeting: DetectedMeeting?) {
        currentMeeting = meeting
        if meeting == nil, dismissedPromptState?.survivesDetectionDrop != true {
            dismissedPromptState = nil
        }
    }

    private func shouldSuppressDismissedPrompt(for meeting: DetectedMeeting, now: Date) -> Bool {
        guard let dismissedPromptState else { return false }
        guard Self.shouldSuppressDismissedPrompt(
            suppressionKey: meeting.promptSuppressionKey,
            dismissedPromptKey: dismissedPromptState.suppressionKey,
            dismissedUntil: dismissedPromptState.suppressedUntil,
            now: now
        ) else {
            self.dismissedPromptState = nil
            return false
        }
        return true
    }

    private func runningApplication(bundleID: String) -> NSRunningApplication? {
        let normalizedBundleID = bundleID.lowercased()
        return NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier?.lowercased() == normalizedBundleID
        }
    }

    static func shouldPrompt(
        signature: String,
        lastSignature: String?,
        lastPromptedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let lastSignature, let lastPromptedAt else { return true }
        guard lastSignature == signature else { return true }
        return now.timeIntervalSince(lastPromptedAt) >= repromptCooldown
    }

    static func shouldSuppressDismissedPrompt(
        suppressionKey: String,
        dismissedPromptKey: String?,
        dismissedUntil: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let dismissedPromptKey, let dismissedUntil else { return false }
        guard dismissedPromptKey == suppressionKey else { return false }
        return now < dismissedUntil
    }

    static func shouldScanForActiveMeeting(
        isMicrophoneDetectionReady: Bool,
        isCameraActive: Bool,
        isCalendarHintsEnabled: Bool
    ) -> Bool {
        isMicrophoneDetectionReady || isCameraActive || isCalendarHintsEnabled
    }

    static func lifecycleSignal(
        for context: ContextExtractor.Context,
        expected: DetectedMeeting,
        isFrontmostApp: Bool
    ) -> LifecycleSignal {
        if looksLikeExplicitMeetingEnd(context, expected: expected) {
            return .strongEndSignal
        }

        if let detectedMeeting = detectMeeting(from: context),
           detectedMeeting.app.bundleID.caseInsensitiveCompare(expected.app.bundleID) == .orderedSame {
            return .active(detectedMeeting)
        }

        if expected.browserURL?.trimmedNilIfEmpty != nil || BrowserCatalog.isBrowser(expected.app.bundleID) {
            return .weakEndSignal
        }

        return isFrontmostApp ? .weakEndSignal : .ambiguous
    }

    static func shouldAutoStopAfterMicrophoneInactivity(_ signal: LifecycleSignal) -> Bool {
        switch signal {
        case .weakEndSignal, .strongEndSignal:
            return true
        case .active, .ambiguous:
            return false
        }
    }

    static func canHostMeeting(bundleID: String?) -> Bool {
        guard let normalizedBundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedBundleID.isEmpty
        else {
            return false
        }

        return BrowserCatalog.isBrowser(normalizedBundleID) || nativeMeetingBundleIDs.contains(normalizedBundleID)
    }

    static func detectMeeting(from context: ContextExtractor.Context) -> DetectedMeeting? {
        let bundleID = context.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return nil }

        if let browserMeeting = detectBrowserMeeting(from: context) {
            return browserMeeting
        }

        return detectNativeMeeting(from: context)
    }

    static func bestCalendarHint(
        for detectedMeeting: DetectedMeeting,
        hints: [MeetingCalendarHint]
    ) -> MeetingCalendarHint? {
        var bestHint: MeetingCalendarHint?
        var bestScore = 0

        for hint in hints {
            let score = calendarMatchScore(for: detectedMeeting, hint: hint)
            guard score > bestScore else { continue }
            bestScore = score
            bestHint = hint
        }

        return bestHint
    }

    static func calendarMatchScore(for detectedMeeting: DetectedMeeting, hint: MeetingCalendarHint) -> Int {
        let hintText = hint.searchableText
        let providerTerms = providerTerms(for: detectedMeeting.app.name)
        let titleTerms = normalizedTerms(from: detectedMeeting.windowTitle)

        var score = 0

        if let browserURL = detectedMeeting.browserURL,
           let conferencingURL = hint.conferencingURL,
           let browserHost = normalizedHost(from: browserURL),
           let hintHost = normalizedHost(from: conferencingURL),
           browserHostsMatch(browserHost, hintHost) {
            score += 8
        }

        if providerTerms.contains(where: hintText.contains) {
            score += 4
        }

        if !titleTerms.isEmpty && titleTerms.contains(where: hintText.contains) {
            score += 2
        }

        return score
    }

    static func calendarSuggestsMeetingEnded(_ meeting: DetectedMeeting, now: Date = Date()) -> Bool {
        guard let scheduledEnd = meeting.calendarHint?.endDate else { return false }
        return now >= scheduledEnd.addingTimeInterval(calendarEndGracePeriod)
    }

    static func shouldPromoteCalendarOnlyLifecycle(
        from calendarOnlyMeeting: DetectedMeeting,
        to detectedMeeting: DetectedMeeting,
        now: Date = Date()
    ) -> Bool {
        guard calendarOnlyMeeting.isCalendarOnly,
              !detectedMeeting.isCalendarOnly,
              let hint = calendarOnlyMeeting.calendarHint
        else {
            return false
        }

        let isWithinScheduledWindow =
            now >= hint.startDate.addingTimeInterval(-calendarStartLeadTime)
            && now <= hint.endDate.addingTimeInterval(calendarEndGracePeriod)
        guard isWithinScheduledWindow else { return false }

        return calendarMatchScore(for: detectedMeeting, hint: hint) >= autoStartCalendarMatchThreshold
    }

    static func shouldAutoStart(_ meeting: DetectedMeeting) -> Bool {
        if let hint = meeting.calendarHint,
           hint.conferencingURL?.trimmedNilIfEmpty != nil,
           calendarMatchScore(for: meeting, hint: hint) >= autoStartCalendarMatchThreshold {
            return true
        }

        return meeting.autoStartEligible
    }

    static func shouldPromptImmediately(_ meeting: DetectedMeeting) -> Bool {
        guard !meeting.isCalendarOnly else { return false }
        return meeting.autoStartEligible || shouldAutoStart(meeting)
    }

    static func shouldStartMarkedAutoRecord(
        _ meeting: DetectedMeeting,
        hasRuntimeMeetingSignal: Bool,
        now: Date = Date()
    ) -> Bool {
        guard let hint = meeting.calendarHint else {
            return hasRuntimeMeetingSignal && shouldAutoStart(meeting)
        }

        let scheduledWindowHasStarted =
            now >= hint.startDate
            && now <= hint.endDate.addingTimeInterval(calendarEndGracePeriod)

        if meeting.isCalendarOnly {
            return scheduledWindowHasStarted
        }

        guard hasRuntimeMeetingSignal else {
            return false
        }

        return scheduledWindowHasStarted || shouldAutoStart(meeting)
    }

    static func isCalendarAutomationPrimed(_ meeting: DetectedMeeting, now: Date = Date()) -> Bool {
        guard let hint = meeting.calendarHint,
              hint.conferencingURL?.trimmedNilIfEmpty != nil
        else {
            return false
        }

        let isWithinScheduledWindow =
            now >= hint.startDate.addingTimeInterval(-calendarStartLeadTime)
            && now <= hint.endDate.addingTimeInterval(calendarEndGracePeriod)
        guard isWithinScheduledWindow else { return false }

        return calendarMatchScore(for: meeting, hint: hint) >= autoStartCalendarMatchThreshold
    }

    private static func detectBrowserMeeting(from context: ContextExtractor.Context) -> DetectedMeeting? {
        guard let host = normalizedHost(from: context.browserURL) else { return nil }
        let evidence = normalizedText(
            ([context.windowTitle, context.browserURL] + context.visibleTextSnippets).joined(separator: " ")
        )

        if let meetingName = browserConferencingMeetingName(host: host) {
            guard browserMeetingPageState(host: host, browserURL: context.browserURL) == .active else {
                return nil
            }

            return DetectedMeeting(
                app: MeetingApp(bundleID: context.bundleId, name: meetingName),
                windowTitle: context.windowTitle.trimmedNilIfEmpty,
                browserURL: context.browserURL.trimmedNilIfEmpty,
                calendarHint: nil,
                autoStartEligible: browserAutoStartEligible(
                    host: host,
                    browserURL: context.browserURL,
                    evidence: evidence
                )
            )
        }

        if let meetingName = browserMessagingCallName(host: host),
           looksLikeMessagingCall(evidence) {
            return DetectedMeeting(
                app: MeetingApp(bundleID: context.bundleId, name: meetingName),
                windowTitle: context.windowTitle.trimmedNilIfEmpty,
                browserURL: context.browserURL.trimmedNilIfEmpty,
                calendarHint: nil,
                autoStartEligible: browserAutoStartEligible(
                    host: host,
                    browserURL: context.browserURL,
                    evidence: evidence
                )
            )
        }

        return nil
    }

    private static func browserConferencingMeetingName(host: String) -> String? {
        return switch host {
        case let host where host == "meet.google.com":
            "Google Meet"
        case let host where host.hasSuffix(".zoom.us") || host == "zoom.us":
            "Zoom"
        case let host where host == "teams.microsoft.com" || host == "teams.live.com":
            "Teams"
        case let host where host.hasSuffix(".webex.com") || host == "webex.com":
            "Webex"
        case let host where host == "meet.proton.me":
            "Proton Meet"
        case "v.ringcentral.com", "meetings.ringcentral.com", "app.ringcentral.com":
            "RingCentral"
        case "global.gotomeeting.com", "app.gotomeeting.com", "meet.goto.com", "gotomeet.me":
            "GoTo Meeting"
        case "meet.jit.si":
            "Jitsi Meet"
        case let host where host == "8x8.vc" || host.hasSuffix(".8x8.vc"):
            "Jitsi Meet"
        case let host where host == "whereby.com" || host.hasSuffix(".whereby.com"):
            "Whereby"
        case "app.chime.aws", "chime.aws":
            "Amazon Chime"
        case "meeting.zoho.com", "meet.zoho.com":
            "Zoho Meeting"
        case "meetings.dialpad.com":
            "Dialpad Meetings"
        default:
            nil
        }
    }

    private static func browserMessagingCallName(host: String) -> String? {
        return switch host {
        case "app.slack.com":
            "Slack Huddle"
        case "discord.com", "canary.discord.com", "ptb.discord.com":
            "Discord Call"
        case "chat.google.com":
            "Google Chat Call"
        case "messenger.com", "www.messenger.com":
            "Messenger Call"
        case let host where host == "facebook.com" || host.hasSuffix(".facebook.com"):
            "Messenger Call"
        case "instagram.com", "www.instagram.com":
            "Instagram Call"
        case "web.skype.com":
            "Skype Call"
        case "web.whatsapp.com":
            "WhatsApp Call"
        case "web.telegram.org":
            "Telegram Call"
        default:
            nil
        }
    }

    static func calendarOnlyMeeting(
        from hints: [MeetingCalendarHint],
        now: Date = Date()
    ) -> DetectedMeeting? {
        let sortedHints = hints.sorted { lhs, rhs in
            let lhsInProgress = now >= lhs.startDate && now <= lhs.endDate
            let rhsInProgress = now >= rhs.startDate && now <= rhs.endDate
            if lhsInProgress != rhsInProgress {
                return lhsInProgress
            }

            let lhsHasConferenceURL = lhs.conferencingURL?.trimmedNilIfEmpty != nil
            let rhsHasConferenceURL = rhs.conferencingURL?.trimmedNilIfEmpty != nil
            if lhsHasConferenceURL != rhsHasConferenceURL {
                return lhsHasConferenceURL
            }

            let lhsDistance = abs(lhs.startDate.timeIntervalSince(now))
            let rhsDistance = abs(rhs.startDate.timeIntervalSince(now))
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        guard let hint = sortedHints.first else { return nil }

        return DetectedMeeting(
            app: MeetingApp(bundleID: calendarOnlyBundleID, name: calendarOnlyAppName),
            windowTitle: hint.title,
            browserURL: hint.conferencingURL?.trimmedNilIfEmpty,
            calendarHint: hint,
            autoStartEligible: false
        )
    }

    private static func detectNativeMeeting(from context: ContextExtractor.Context) -> DetectedMeeting? {
        let bundleID = context.bundleId.lowercased()
        let title = normalizedText(context.windowTitle)
        let evidence = normalizedText(
            ([context.windowTitle] + context.visibleTextSnippets).joined(separator: " ")
        )

        switch bundleID {
        case "us.zoom.xos":
            guard containsAny(evidence, keywords: commonCallKeywords + ["zoom meeting"]) else {
                return nil
            }
            return makeDetectedMeeting(
                name: "Zoom",
                context: context,
                autoStartEligible: nativeAutoStartEligible(bundleID: bundleID, evidence: evidence)
            )
        case "com.microsoft.teams", "com.microsoft.teams2":
            guard containsAny(evidence, keywords: commonCallKeywords + ["teams meeting", "present now"]) else {
                return nil
            }
            return makeDetectedMeeting(
                name: "Teams",
                context: context,
                autoStartEligible: nativeAutoStartEligible(bundleID: bundleID, evidence: evidence)
            )
        case "cisco-systems.spark", "com.webex.meetingmanager":
            guard containsAny(evidence, keywords: commonCallKeywords + ["webex"]) else {
                return nil
            }
            return makeDetectedMeeting(
                name: "Webex",
                context: context,
                autoStartEligible: nativeAutoStartEligible(bundleID: bundleID, evidence: evidence)
            )
        case "com.apple.facetime":
            guard containsAny(evidence, keywords: commonCallKeywords + ["facetime"])
                || (!title.isEmpty && title != "facetime")
            else {
                return nil
            }
            return makeDetectedMeeting(
                name: "FaceTime",
                context: context,
                autoStartEligible: nativeAutoStartEligible(bundleID: bundleID, evidence: evidence)
            )
        case "com.tinyspeck.slackmacgap":
            guard containsAny(evidence, keywords: ["huddle", "call", "video call", "voice call"]) else {
                return nil
            }
            return makeDetectedMeeting(
                name: "Slack Huddle",
                context: context,
                autoStartEligible: nativeAutoStartEligible(bundleID: bundleID, evidence: evidence)
            )
        case let bundleID where nativeMessagingCallName(bundleID: bundleID) != nil:
            guard looksLikeMessagingCall(evidence) else {
                return nil
            }
            return makeDetectedMeeting(
                name: nativeMessagingCallName(bundleID: bundleID) ?? "Call",
                context: context,
                autoStartEligible: nativeAutoStartEligible(bundleID: bundleID, evidence: evidence)
            )
        case "com.hnc.discord", "com.discord", "com.ranchero.discord":
            guard containsAny(evidence, keywords: ["call", "voice", "video", "stage", "watch stream"]) else {
                return nil
            }
            return makeDetectedMeeting(
                name: "Discord Call",
                context: context,
                autoStartEligible: nativeAutoStartEligible(bundleID: bundleID, evidence: evidence)
            )
        default:
            return nil
        }
    }

    nonisolated static let nativeMeetingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "cisco-systems.spark",
        "com.webex.meetingmanager",
        "com.apple.facetime",
        "com.tinyspeck.slackmacgap",
        "com.facebook.archon",
        "com.facebook.messenger",
        "net.whatsapp.whatsapp",
        "ru.keepcoder.telegram",
        "org.telegram.desktop",
        "org.whispersystems.signal-desktop",
        "com.skype.skype",
        "com.viber.osx",
        "jp.naver.line.mac",
        "com.tencent.xinwechat",
        "com.tencent.wechat",
        "com.hnc.discord",
        "com.discord",
        "com.ranchero.discord",
    ]

    nonisolated private static func normalizedPromptMeetingURL(_ rawURL: String?) -> String? {
        guard let normalizedMeetingURL = EventKitMeetingCalendarHintSource.normalizedMeetingURL(rawURL),
              var components = URLComponents(string: normalizedMeetingURL)
        else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        return components.string?.lowercased()
    }

    private static func dismissedPromptDeadline(for meeting: DetectedMeeting, now: Date) -> Date {
        let minimumDeadline = now.addingTimeInterval(repromptCooldown)
        guard let scheduledEnd = meeting.calendarHint?.endDate else {
            return now.addingTimeInterval(dismissedPromptFallbackDuration)
        }
        return max(
            minimumDeadline,
            scheduledEnd.addingTimeInterval(calendarEndGracePeriod)
        )
    }

    private static let commonCallKeywords = [
        "meeting",
        "call",
        "webinar",
        "huddle",
        "mute",
        "unmute",
        "camera",
        "microphone",
        "raise hand",
        "participants",
        "leave",
        "end call",
        "share screen",
        "recording",
    ]

    private static let explicitEndKeywords = [
        "meeting ended",
        "call ended",
        "you left the meeting",
        "you left the call",
        "this meeting has ended",
        "this call has ended",
        "huddle ended",
        "webinar has ended",
    ]

    private static let strongCallUIKeywords = [
        "mute",
        "unmute",
        "participants",
        "share screen",
        "screen share",
        "recording",
        "raise hand",
        "leave call",
        "end call",
        "disconnect",
        "deafen",
        "present now",
        "watch stream",
        "leave huddle",
        "you left the meeting",
    ]

    private static func makeDetectedMeeting(
        name: String,
        context: ContextExtractor.Context,
        autoStartEligible: Bool
    ) -> DetectedMeeting {
        DetectedMeeting(
            app: MeetingApp(bundleID: context.bundleId, name: name),
            windowTitle: context.windowTitle.trimmedNilIfEmpty,
            browserURL: context.browserURL.trimmedNilIfEmpty,
            calendarHint: nil,
            autoStartEligible: autoStartEligible
        )
    }

    private static func nativeAutoStartEligible(bundleID: String, evidence: String) -> Bool {
        let providerKeywords: [String]
        switch bundleID {
        case "us.zoom.xos":
            providerKeywords = ["zoom meeting", "zoom workplace"]
        case "com.microsoft.teams", "com.microsoft.teams2":
            providerKeywords = ["teams meeting", "present now"]
        case "cisco-systems.spark", "com.webex.meetingmanager":
            providerKeywords = ["webex"]
        case "com.apple.facetime":
            providerKeywords = ["facetime", "mic mode"]
        case "com.tinyspeck.slackmacgap":
            providerKeywords = ["huddle", "leave huddle"]
        case "com.facebook.archon", "com.facebook.messenger":
            providerKeywords = ["messenger call", "voice call", "video call", "end call"]
        case "net.whatsapp.whatsapp":
            providerKeywords = ["voice call", "video call", "end call"]
        case "ru.keepcoder.telegram", "org.telegram.desktop":
            providerKeywords = ["voice chat", "video chat", "end call"]
        case "org.whispersystems.signal-desktop":
            providerKeywords = ["voice call", "video call", "end call"]
        case "com.skype.skype":
            providerKeywords = ["skype call", "voice call", "video call", "end call"]
        case "com.viber.osx":
            providerKeywords = ["viber call", "voice call", "video call", "end call"]
        case "jp.naver.line.mac":
            providerKeywords = ["line call", "voice call", "video call", "end call"]
        case "com.tencent.xinwechat", "com.tencent.wechat":
            providerKeywords = ["wechat call", "voice call", "video call", "end call"]
        case "com.hnc.discord", "com.discord", "com.ranchero.discord":
            providerKeywords = ["watch stream", "disconnect", "deafen"]
        default:
            providerKeywords = []
        }

        return containsAny(evidence, keywords: strongCallUIKeywords + providerKeywords)
    }

    private static func browserAutoStartEligible(host: String, browserURL: String?, evidence: String) -> Bool {
        if containsAny(evidence, keywords: strongCallUIKeywords) {
            return true
        }

        guard let browserURL else { return false }
        let normalizedURL = browserURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch host {
        case "meet.google.com":
            return browserMeetingPageState(host: host, browserURL: normalizedURL) == .active
        case let host where host.hasSuffix(".zoom.us") || host == "zoom.us":
            return normalizedURL.contains("/j/")
                || normalizedURL.contains("/wc/")
                || normalizedURL.contains("/join")
        case let host where host == "teams.microsoft.com" || host == "teams.live.com":
            return normalizedURL.contains("meetup-join")
        case let host where host.hasSuffix(".webex.com") || host == "webex.com":
            return normalizedURL.contains("/meet/")
                || normalizedURL.contains("/join/")
        case "meet.proton.me":
            return normalizedURL.contains("/join/")
        case "v.ringcentral.com", "meetings.ringcentral.com", "app.ringcentral.com":
            return normalizedURL.contains("/join")
                || normalizedURL.contains("/meeting")
                || normalizedURL.contains("/video")
        case "global.gotomeeting.com", "app.gotomeeting.com", "meet.goto.com", "gotomeet.me":
            return normalizedURL.contains("/join")
                || normalizedURL.contains("/meeting")
                || normalizedURL.contains("meet.goto.com/")
                || normalizedURL.contains("gotomeet.me/")
        case "meet.jit.si":
            return browserMeetingPageState(host: host, browserURL: normalizedURL) == .active
        case let host where host == "8x8.vc" || host.hasSuffix(".8x8.vc"):
            return browserMeetingPageState(host: host, browserURL: normalizedURL) == .active
        case let host where host == "whereby.com" || host.hasSuffix(".whereby.com"):
            return browserMeetingPageState(host: host, browserURL: normalizedURL) == .active
        case "app.chime.aws", "chime.aws":
            return normalizedURL.contains("/meetings")
                || normalizedURL.contains("/meeting")
        case "meeting.zoho.com", "meet.zoho.com":
            return normalizedURL.contains("/meeting")
                || normalizedURL.contains("/join")
        case "meetings.dialpad.com":
            return browserMeetingPageState(host: host, browserURL: normalizedURL) == .active
        case let host where browserMessagingCallName(host: host) != nil:
            return looksLikeMessagingCall(evidence)
        default:
            return false
        }
    }

    private static func looksLikeExplicitMeetingEnd(
        _ context: ContextExtractor.Context,
        expected: DetectedMeeting
    ) -> Bool {
        let evidence = normalizedText(
            ([context.windowTitle, context.browserURL] + context.visibleTextSnippets).joined(separator: " ")
        )

        if let host = normalizedHost(from: context.browserURL),
           browserMeetingPageState(host: host, browserURL: context.browserURL) == .ended {
            return true
        }

        let providerKeywords: [String]
        switch expected.app.name.lowercased() {
        case let name where name.contains("google meet"):
            providerKeywords = ["you left the meeting"]
        case let name where name.contains("slack"):
            providerKeywords = ["huddle ended"]
        default:
            providerKeywords = []
        }

        return containsAny(evidence, keywords: explicitEndKeywords + providerKeywords)
    }

    private static func containsAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private static func providerTerms(for meetingAppName: String) -> [String] {
        let normalizedName = meetingAppName.lowercased()
        switch normalizedName {
        case let name where name.contains("google meet"):
            return ["google meet", "meet.google.com", "meet"]
        case let name where name.contains("zoom"):
            return ["zoom", "zoom meeting"]
        case let name where name.contains("teams"):
            return ["teams", "microsoft teams"]
        case let name where name.contains("webex"):
            return ["webex"]
        case let name where name.contains("facetime"):
            return ["facetime"]
        case let name where name.contains("slack"):
            return ["slack", "huddle"]
        case let name where name.contains("messenger"):
            return ["messenger", "facebook"]
        case let name where name.contains("whatsapp"):
            return ["whatsapp", "whatsapp call"]
        case let name where name.contains("telegram"):
            return ["telegram", "telegram call"]
        case let name where name.contains("signal"):
            return ["signal", "signal call"]
        case let name where name.contains("google chat"):
            return ["google chat", "chat.google.com"]
        case let name where name.contains("instagram"):
            return ["instagram", "instagram call"]
        case let name where name.contains("skype"):
            return ["skype", "skype call"]
        case let name where name.contains("viber"):
            return ["viber", "viber call"]
        case let name where name.contains("line"):
            return ["line", "line call"]
        case let name where name.contains("wechat"):
            return ["wechat", "wechat call"]
        case let name where name.contains("discord"):
            return ["discord", "voice", "video"]
        case let name where name.contains("proton"):
            return ["proton meet", "meet.proton.me", "proton"]
        case let name where name.contains("ringcentral"):
            return ["ringcentral", "v.ringcentral.com"]
        case let name where name.contains("goto"):
            return ["goto meeting", "gotomeeting", "meet.goto.com"]
        case let name where name.contains("jitsi"):
            return ["jitsi", "meet.jit.si"]
        case let name where name.contains("whereby"):
            return ["whereby"]
        case let name where name.contains("chime"):
            return ["amazon chime", "chime.aws"]
        case let name where name.contains("zoho"):
            return ["zoho meeting", "meeting.zoho.com"]
        case let name where name.contains("dialpad"):
            return ["dialpad", "dialpad meetings"]
        default:
            return [normalizedName]
        }
    }

    private static func normalizedTerms(from text: String?) -> [String] {
        guard let text else { return [] }
        return text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 }
    }

    private static func browserHostsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasSuffix(".\(rhs)") || rhs.hasSuffix(".\(lhs)")
    }

    private static func looksLikeMessagingCall(_ evidence: String) -> Bool {
        if containsAny(evidence, keywords: explicitMessagingCallKeywords) {
            return true
        }

        let controlMatchCount = messagingCallControlKeywords.reduce(0) { count, keyword in
            count + (evidence.contains(keyword) ? 1 : 0)
        }
        return controlMatchCount >= 2
    }

    private static func nativeMessagingCallName(bundleID: String) -> String? {
        return switch bundleID {
        case "com.facebook.archon", "com.facebook.messenger":
            "Messenger Call"
        case "net.whatsapp.whatsapp":
            "WhatsApp Call"
        case "ru.keepcoder.telegram", "org.telegram.desktop":
            "Telegram Call"
        case "org.whispersystems.signal-desktop":
            "Signal Call"
        case "com.skype.skype":
            "Skype Call"
        case "com.viber.osx":
            "Viber Call"
        case "jp.naver.line.mac":
            "LINE Call"
        case "com.tencent.xinwechat", "com.tencent.wechat":
            "WeChat Call"
        default:
            nil
        }
    }

    private static func mergeCalendarHint(from existing: DetectedMeeting, into updated: DetectedMeeting) -> DetectedMeeting {
        guard updated.calendarHint == nil, let existingHint = existing.calendarHint else {
            return updated
        }
        return DetectedMeeting(
            app: updated.app,
            windowTitle: updated.windowTitle,
            browserURL: updated.browserURL,
            calendarHint: existingHint,
            autoStartEligible: updated.autoStartEligible
        )
    }

    private static func normalizedHost(from rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URLComponents(string: withScheme)?.host?.lowercased()
    }

    nonisolated private static func normalizedText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private enum BrowserMeetingPageState {
        case active
        case ended
        case ignore
    }

    private static let explicitMessagingCallKeywords = [
        "audio call",
        "voice call",
        "video call",
        "incoming call",
        "outgoing call",
        "call in progress",
        "return to call",
        "join call",
        "joined the call",
        "leave call",
        "end call",
        "call ended",
        "calling",
        "ringing",
        "huddle",
        "leave huddle",
        "start huddle",
        "voice chat",
        "video chat",
        "2 participants",
        "two participants",
        "2 people",
        "two people",
        "2 speakers",
        "two speakers",
    ]

    private static let messagingCallControlKeywords = [
        "mute",
        "unmute",
        "microphone",
        "camera",
        "speaker",
        "participants",
        "share screen",
        "screen share",
    ]

    private static func browserMeetingPageState(host: String, browserURL: String?) -> BrowserMeetingPageState {
        guard let browserURL = browserURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !browserURL.isEmpty
        else {
            return .ignore
        }

        let withScheme = browserURL.contains("://") ? browserURL : "https://\(browserURL)"
        guard let components = URLComponents(string: withScheme) else {
            return .ignore
        }

        let path = components.path.lowercased()
        let normalizedPath =
            path == "/" ? "" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        switch host {
        case "meet.google.com":
            if ["", "landing", "new"].contains(normalizedPath) {
                return normalizedPath == "landing" ? .ended : .ignore
            }
            return looksLikeGoogleMeetRoomCode(normalizedPath) ? .active : .ignore
        case let host where host.hasSuffix(".zoom.us") || host == "zoom.us":
            if normalizedPath.contains("/j/")
                || normalizedPath.hasPrefix("j/")
                || normalizedPath.contains("/wc/")
                || normalizedPath.hasPrefix("wc/")
                || normalizedPath.contains("/join")
                || normalizedPath.hasPrefix("join") {
                return .active
            }
            return .ignore
        case let host where host == "teams.microsoft.com" || host == "teams.live.com":
            if normalizedPath.contains("meetup-join") || normalizedPath.hasPrefix("meet/") {
                return .active
            }
            return .ignore
        case let host where host.hasSuffix(".webex.com") || host == "webex.com":
            if normalizedPath.contains("/meet/")
                || normalizedPath.hasPrefix("meet/")
                || normalizedPath.contains("/join/")
                || normalizedPath.hasPrefix("join/") {
                return .active
            }
            return .ignore
        case "meet.proton.me":
            return normalizedPath.hasPrefix("join/") ? .active : .ignore
        case "v.ringcentral.com", "meetings.ringcentral.com", "app.ringcentral.com":
            if normalizedPath.contains("join")
                || normalizedPath.contains("meeting")
                || normalizedPath.contains("video") {
                return .active
            }
            return .ignore
        case "global.gotomeeting.com", "app.gotomeeting.com":
            if normalizedPath.contains("join") || normalizedPath.contains("meeting") {
                return .active
            }
            return .ignore
        case "meet.goto.com", "gotomeet.me", "meet.jit.si", "meetings.dialpad.com":
            return normalizedPath.isEmpty ? .ignore : .active
        case let host where host == "8x8.vc" || host.hasSuffix(".8x8.vc"):
            return normalizedPath.isEmpty ? .ignore : .active
        case let host where host == "whereby.com" || host.hasSuffix(".whereby.com"):
            guard !normalizedPath.isEmpty,
                  !["login", "user", "signup", "pricing"].contains(normalizedPath)
            else {
                return .ignore
            }
            return .active
        case "app.chime.aws", "chime.aws":
            if normalizedPath.contains("meetings") || normalizedPath.contains("meeting") {
                return .active
            }
            return .ignore
        case "meeting.zoho.com", "meet.zoho.com":
            if normalizedPath.contains("meeting")
                || normalizedPath.contains("join")
                || components.query?.lowercased().contains("meeting") == true {
                return .active
            }
            return .ignore
        default:
            return .ignore
        }
    }

    private static func looksLikeGoogleMeetRoomCode(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 3 else { return false }
        let expectedLengths = [3, 4, 3]
        for (part, length) in zip(parts, expectedLengths) {
            guard part.count == length, part.allSatisfy(\.isLetter) else {
                return false
            }
        }
        return true
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
