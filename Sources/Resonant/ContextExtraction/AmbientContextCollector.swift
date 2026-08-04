import AppKit
import Foundation
import ObjCExceptionCatcher
import SwiftData

/// Passively captures screen context to build a dense activity log for ambient AI agents.
///
/// Two-tier capture strategy:
/// - **Lightweight poll** (every 5s): reads only window title + URL — costs microseconds.
/// - **Full snapshot** (on change): walks the AX tree for visible text, field content, tabs, etc.
///
/// Also monitors clipboard changes and app switches. Heavy AX work runs off the
/// main thread; AppKit pasteboard access stays on the main actor.
@MainActor
@Observable
final class AmbientContextCollector {
    typealias CorrectionSnapshotExtractor = @MainActor (
        pid_t,
        String?
    ) async -> CorrectionHotSnapshot?
    typealias FrontmostProcessIdentifierProvider = @MainActor () -> pid_t?

    private struct TrackedTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct PendingSnapshotFinalization: Sendable {
        let snapshotID: UUID
        let dwellDurationSeconds: TimeInterval
    }

    private struct PollRequest: Sendable {
        let processIdentifier: pid_t
        let bundleId: String
    }

    private struct ClipboardUpdate: Sendable {
        let changeCount: Int
        let text: String?
    }

    private struct PollSnapshot: Sendable {
        let isScreenLocked: Bool
        let windowTitle: String
        let browserURL: String
    }

    struct NotificationHint: Sendable {
        let appName: String
        let bundleId: String?
        let title: String?
        let body: String?
        let url: String?
        let receivedAt: Date
    }

    private let contextExtractor: ContextExtractor
    private let dataStore: DataStore
    private let settingsManager: SettingsManager
    private let activityStreamWriter: ActivityStreamWriter
    private let correctionSnapshotExtractor: CorrectionSnapshotExtractor
    private let frontmostProcessIdentifierProvider: FrontmostProcessIdentifierProvider

    // Observers
    private var appSwitchObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var triggerTasks: [UUID: Task<Void, Never>] = [:]
    private var finalizationTask: TrackedTask?
    private var lifecycleGeneration: UInt64 = 0

    // Dedup state — `lastSnapshotKey` is the canonical key set only in `captureSnapshot`.
    private var lastSnapshotKey: String?
    private var lastSnapshotTimestamp: Date?
    private var lastSnapshot: AmbientContextSnapshot?
    private var lastClipboardChangeCount: Int = 0
    private var lastClipboardText: String?
    private var pendingNotificationHint: NotificationHint?

    private static let minimumSnapshotInterval: TimeInterval = 0.5
    private static let settleDelay: UInt64 = 200_000_000 // 200ms
    private static let pollInterval: TimeInterval = 5.0
    private var isCapturing = false
    private(set) var isActive = false

    init(
        contextExtractor: ContextExtractor,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        activityStreamWriter: ActivityStreamWriter,
        correctionSnapshotExtractor: CorrectionSnapshotExtractor? = nil,
        frontmostProcessIdentifierProvider: @escaping FrontmostProcessIdentifierProvider = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    ) {
        self.contextExtractor = contextExtractor
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.activityStreamWriter = activityStreamWriter
        self.correctionSnapshotExtractor = correctionSnapshotExtractor ?? { [contextExtractor] processIdentifier, _ in
            guard let app = NSRunningApplication(
                processIdentifier: processIdentifier
            ) else { return nil }
            return await contextExtractor.extractCorrectionHotSnapshot(from: app)
        }
        self.frontmostProcessIdentifierProvider = frontmostProcessIdentifierProvider
        self.lastClipboardChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isActive = true

        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.enqueueAppSwitch(app, generation: generation)
            }
        }

        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.enqueuePollTick(generation: generation)
            }
        }
        timer.tolerance = 1.0
        pollTimer = timer

    }

    func stop() {
        beginStop(finalizePendingSnapshot: true)
    }

    /// Retires every app-switch/poll capture and joins the optional dwell-time
    /// finalization. Once this returns, the collector cannot mutate SwiftData or
    /// the ambient stream until `start()` creates a new lifecycle generation.
    func stopAndWait(finalizePendingSnapshot: Bool = true) async {
        if isActive {
            beginStop(finalizePendingSnapshot: finalizePendingSnapshot)
        }
        let finalization = finalizationTask
        await finalization?.task.value
        if finalizationTask?.id == finalization?.id {
            finalizationTask = nil
        }
    }

    private func beginStop(finalizePendingSnapshot shouldFinalize: Bool) {
        guard isActive else { return }
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        isActive = false
        lifecycleGeneration &+= 1
        let stoppedGeneration = lifecycleGeneration

        let triggers = Array(triggerTasks.values)
        triggerTasks.removeAll()
        triggers.forEach { $0.cancel() }
        let pendingFinalization = takePendingSnapshotFinalization(at: Date())
        let precedingFinalization = finalizationTask?.task

        let finalizationID = UUID()
        let task = Task { @MainActor [weak self] in
            await precedingFinalization?.value
            for trigger in triggers {
                await trigger.value
            }
            guard let self, !Task.isCancelled else { return }
            if shouldFinalize, let pendingFinalization {
                await self.finalizePendingSnapshot(
                    pendingFinalization,
                    stoppedGeneration: stoppedGeneration
                )
            }
            if self.finalizationTask?.id == finalizationID {
                self.finalizationTask = nil
            }
        }
        finalizationTask = TrackedTask(id: finalizationID, task: task)
    }

    func recordNotificationHint(_ hint: NotificationHint) {
        pendingNotificationHint = hint
        guard isActive else { return }
        enqueuePollTick(generation: lifecycleGeneration)
    }

    private func enqueueAppSwitch(_ app: NSRunningApplication, generation: UInt64) {
        guard isGenerationActive(generation) else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handleAppSwitch(app, generation: generation)
            self.triggerTasks.removeValue(forKey: id)
        }
        triggerTasks[id] = task
    }

    private func enqueuePollTick(generation: UInt64) {
        guard isGenerationActive(generation) else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handlePollTick(generation: generation)
            self.triggerTasks.removeValue(forKey: id)
        }
        triggerTasks[id] = task
    }

    private func isGenerationActive(_ generation: UInt64) -> Bool {
        isActive && lifecycleGeneration == generation
    }

    // MARK: - App switch

    private func handleAppSwitch(_ app: NSRunningApplication, generation: UInt64) async {
        guard isGenerationActive(generation), isEnabled() else { return }
        let bundleId = app.bundleIdentifier ?? ""
        if shouldExclude(bundleId: bundleId) { return }

        // Settle delay — capture `app` locally so a subsequent switch can't change it
        try? await Task.sleep(nanoseconds: Self.settleDelay)
        guard !Task.isCancelled, isGenerationActive(generation) else { return }

        await captureSnapshot(for: app, generation: generation)
    }

    // MARK: - Poll tick (lightweight)

    private func handlePollTick(generation: UInt64) async {
        guard isGenerationActive(generation), isEnabled() else { return }

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleId = app.bundleIdentifier ?? ""
        if shouldExclude(bundleId: bundleId) { return }

        let lastChangeCount = lastClipboardChangeCount
        let pollRequest = PollRequest(
            processIdentifier: app.processIdentifier,
            bundleId: bundleId
        )

        let snapshotTask = Task.detached(priority: .utility) {
            Self.collectPollSnapshot(for: pollRequest)
        }
        let clipboardUpdate = Self.clipboardUpdate(since: lastChangeCount)
        let pollSnapshot = await snapshotTask.value
        guard !Task.isCancelled, isGenerationActive(generation) else { return }

        if let clipboardUpdate {
            lastClipboardChangeCount = clipboardUpdate.changeCount
            lastClipboardText = clipboardUpdate.text
        }

        if pollSnapshot.isScreenLocked { return }

        let key = CapturedContext(
            bundleId: bundleId,
            windowTitle: pollSnapshot.windowTitle,
            browserURL: pollSnapshot.browserURL
        ).persistenceKey
        if key != lastSnapshotKey || pendingNotificationHint != nil {
            await captureSnapshot(for: app, generation: generation)
        }
    }

    // MARK: - Full snapshot capture (single code path for both triggers)

    private func captureSnapshot(for app: NSRunningApplication, generation: UInt64) async {
        guard isGenerationActive(generation), !Task.isCancelled else { return }
        guard !isCapturing else { return }
        let bundleId = app.bundleIdentifier ?? ""
        if shouldExclude(bundleId: bundleId) { return }
        if Self.isScreenLocked() { return }

        if let lastTimestamp = lastSnapshotTimestamp,
           Date().timeIntervalSince(lastTimestamp) < Self.minimumSnapshotInterval {
            return
        }

        isCapturing = true
        defer { isCapturing = false }

        let pid = app.processIdentifier
        async let contextTask = contextExtractor.extract(
            from: app,
            allowBrowserAutomationFallback: false
        )
        async let browserTabsTask = Task.detached(priority: .utility) {
            Self.extractBrowserTabs(pid: pid, bundleId: bundleId)
        }.value
        let (context, browserTabs) = await (contextTask, browserTabsTask)
        guard isGenerationActive(generation), !Task.isCancelled else { return }

        let storedContext = LocalContextPersistencePolicy.ambientContext(from: context)
        let key = storedContext.persistenceKey
        let now = Date()
        let notificationHint = matchingNotificationHint(for: storedContext, now: now)
        guard key != lastSnapshotKey || notificationHint != nil else { return }

        if let prev = lastSnapshot, let prevTimestamp = lastSnapshotTimestamp {
            let prevID = prev.id
            let dwellDurationSeconds = now.timeIntervalSince(prevTimestamp)
            _ = await dataStore.performBackgroundWrite { context in
                var descriptor = FetchDescriptor<AmbientContextSnapshot>(
                    predicate: #Predicate { $0.id == prevID }
                )
                descriptor.fetchLimit = 1
                guard let snapshot = try? context.fetch(descriptor).first else { return }
                snapshot.dwellDurationSeconds = dwellDurationSeconds
            }
            guard isGenerationActive(generation), !Task.isCancelled else { return }
            if let persisted = dataStore.ambientSnapshot(id: prevID) {
                await activityStreamWriter.writeAmbientSnapshot(persisted)
                guard isGenerationActive(generation), !Task.isCancelled else { return }
                lastSnapshot = persisted
            }
        }

        let snapshotID = UUID()
        let clipboardText = lastClipboardText
        _ = await dataStore.performBackgroundWrite { context in
            let snapshot = AmbientContextSnapshot(
                id: snapshotID,
                timestamp: now,
                appName: storedContext.storedAppName,
                bundleId: storedContext.storedBundleId,
                windowTitle: storedContext.windowTitle,
                browserURL: storedContext.browserURL,
                codeFileName: storedContext.codeFileName,
                slackRecipient: storedContext.slackRecipient,
                focusedFieldContent: storedContext.focusedFieldContent,
                visibleTextSnippetsJSON: encodeJSONStringArray(storedContext.visibleTextSnippets),
                dwellDurationSeconds: nil,
                clipboardText: clipboardText,
                browserTabsJSON: encodeJSONStringArray(browserTabs),
                notificationAppName: notificationHint?.appName,
                notificationBundleId: notificationHint?.bundleId,
                notificationTitle: notificationHint?.title,
                notificationBody: notificationHint?.body,
                notificationURL: notificationHint?.url,
                notificationReceivedAt: notificationHint?.receivedAt
            )
            context.insert(snapshot)
        }
        guard isGenerationActive(generation), !Task.isCancelled else { return }
        if let persisted = dataStore.ambientSnapshot(id: snapshotID) {
            await activityStreamWriter.writeCurrentAmbientSnapshot(persisted)
            guard isGenerationActive(generation), !Task.isCancelled else { return }
            lastSnapshot = persisted
        }

        lastSnapshotKey = key
        lastSnapshotTimestamp = now
    }

    private func matchingNotificationHint(
        for context: CapturedContext,
        now: Date
    ) -> NotificationHint? {
        guard let hint = pendingNotificationHint else { return nil }
        guard now.timeIntervalSince(hint.receivedAt) <= 10 * 60 else {
            pendingNotificationHint = nil
            return nil
        }

        let contextBundle = normalizedNonEmpty(context.bundleId)
        let hintBundle = normalizedNonEmpty(hint.bundleId)
        let contextApp = normalizedNonEmpty(context.appName)
        let hintApp = normalizedNonEmpty(hint.appName)
        let contextHost = context.browserURL
            .flatMap(URL.init(string:))?
            .host(percentEncoded: false)?
            .lowercased()
        let hintHost = hint.url
            .flatMap(URL.init(string:))?
            .host(percentEncoded: false)?
            .lowercased()

        let matches = (contextBundle != nil && contextBundle == hintBundle)
            || (contextHost != nil && contextHost == hintHost)
            || appNamesMatch(contextApp, hintApp)

        guard matches else { return nil }
        pendingNotificationHint = nil
        return hint
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        let normalized = value?
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private func appNamesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs == rhs { return true }

        let ignored: Set<String> = ["app", "web", "browser", "desktop", "google", "chrome", "safari"]
        let lhsTokens = Set(lhs.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .filter { $0.count >= 4 && !ignored.contains($0) }
        let rhsTokens = Set(rhs.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .filter { $0.count >= 4 && !ignored.contains($0) }
        return !lhsTokens.isDisjoint(with: rhsTokens)
    }

    // MARK: - Browser tab extraction

    private nonisolated static func extractBrowserTabs(pid: pid_t, bundleId: String) -> [String] {
        guard BrowserCatalog.isBrowser(bundleId) else { return [] }

        let axApp = AXUIElementCreateApplication(pid)
        var tabs: [String] = []

        ContextExtractor.walkTree(element: axApp, depth: 0, maxDepth: 6) { element in
            guard tabs.count < 30 else { return false }

            var role: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)

            if role as? String == "AXRadioButton" || role as? String == "AXButton" {
                var titleRef: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String,
                   title.count > 2,
                   title.count < 200 {
                    tabs.append(title)
                }
            }
            return true
        }

        return Array(Set(tabs)).sorted()
    }

    // MARK: - Privacy helpers

    private func isEnabled() -> Bool {
        settingsManager.ambientContextEnabled
            && settingsManager.contextMetadataEnabled
            && !settingsManager.hipaaMode
    }

    private func shouldExclude(bundleId: String) -> Bool {
        if bundleId == Bundle.main.bundleIdentifier { return true }
        return settingsManager.ambientExcludedBundleIds.contains(bundleId)
    }

    private nonisolated static func collectPollSnapshot(for request: PollRequest) -> PollSnapshot {
        let isScreenLocked = isScreenLocked()
        guard !isScreenLocked else {
            return PollSnapshot(
                isScreenLocked: true,
                windowTitle: "",
                browserURL: ""
            )
        }

        let axApp = AXUIElementCreateApplication(request.processIdentifier)
        let windowTitle = ContextExtractor.windowTitle(axApp: axApp)
        let browserURL = BrowserCatalog.isBrowser(request.bundleId)
            ? ContextExtractor.browserURL(axApp: axApp)
            : ""

        let resolvedContext: (String, String)
        if BrowserCatalog.isBrowser(request.bundleId),
           let browserContext = BrowserAutomationSupport.fallbackContext(
                bundleId: request.bundleId,
                currentWindowTitle: windowTitle,
                currentURL: browserURL,
                allowUserPrompt: false
           ) {
            resolvedContext = (
                windowTitle.isEmpty ? (browserContext.windowTitle ?? "") : windowTitle,
                browserURL.isEmpty ? (browserContext.browserURL ?? "") : browserURL
            )
        } else {
            resolvedContext = (windowTitle, browserURL)
        }

        return PollSnapshot(
            isScreenLocked: false,
            windowTitle: resolvedContext.0,
            browserURL: resolvedContext.1
        )
    }

    private static func clipboardUpdate(since lastClipboardChangeCount: Int) -> ClipboardUpdate? {
        let pasteboard = NSPasteboard.general
        var changeCount = NSInteger(lastClipboardChangeCount)
        var caughtException: NSException?
        let text = ObjCSafePasteboardString(
            pasteboard,
            .string,
            &changeCount,
            &caughtException
        )
        let currentCount = Int(changeCount)

        if caughtException != nil {
            guard currentCount != lastClipboardChangeCount else { return nil }
            return ClipboardUpdate(changeCount: currentCount, text: nil)
        }

        guard currentCount != lastClipboardChangeCount else { return nil }

        guard let text,
              !text.isEmpty,
              text.count <= 2000,
              !looksLikeSensitive(text) else {
            return ClipboardUpdate(changeCount: currentCount, text: nil)
        }

        return ClipboardUpdate(changeCount: currentCount, text: text)
    }

    private nonisolated static func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// Skip clipboard content that looks like a secret or token.
    /// Intentionally conservative — may skip long UUIDs or SHAs to avoid capturing passwords.
    nonisolated static func looksLikeSensitive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Multi-line clipboard payloads commonly contain private keys,
        // environment files, recovery codes, or structured credentials. The
        // ambient collector is optional context, so prefer dropping them.
        if trimmed.contains("\n") || trimmed.contains("\r") { return true }

        let lowercase = trimmed.lowercased()
        let secretMarkers = [
            "-----begin ",
            "authorization: bearer ",
            "api_key=",
            "apikey=",
            "api-key:",
            "client_secret=",
            "password=",
            "private_key=",
        ]
        if secretMarkers.contains(where: lowercase.contains) { return true }

        // A single long token-like value is much more likely to be a password,
        // session token, UUID, or hash than useful prose.
        if trimmed.count > 20 && trimmed.rangeOfCharacter(from: .whitespaces) == nil { return true }
        return false
    }

    private func truncate(_ text: String, max: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(max))
    }

    private func takePendingSnapshotFinalization(at time: Date) -> PendingSnapshotFinalization? {
        guard let snapshot = lastSnapshot, let lastTimestamp = lastSnapshotTimestamp else { return nil }

        lastSnapshot = nil
        lastSnapshotTimestamp = nil
        lastSnapshotKey = nil
        return PendingSnapshotFinalization(
            snapshotID: snapshot.id,
            dwellDurationSeconds: max(time.timeIntervalSince(lastTimestamp), 0)
        )
    }

    private func finalizePendingSnapshot(
        _ finalization: PendingSnapshotFinalization,
        stoppedGeneration: UInt64
    ) async {
        let snapshotID = finalization.snapshotID
        let dwellDurationSeconds = finalization.dwellDurationSeconds
        _ = await dataStore.performBackgroundWrite { context in
            var descriptor = FetchDescriptor<AmbientContextSnapshot>(
                predicate: #Predicate { $0.id == snapshotID }
            )
            descriptor.fetchLimit = 1
            guard let persisted = try? context.fetch(descriptor).first else { return }
            persisted.dwellDurationSeconds = dwellDurationSeconds
        }
        // A fresh start owns current.json. Never let an older stop erase it.
        guard !Task.isCancelled,
              !isActive,
              lifecycleGeneration == stoppedGeneration
        else { return }
        if let persisted = dataStore.ambientSnapshot(id: snapshotID) {
            await activityStreamWriter.writeAmbientSnapshot(persisted)
        }
        guard !Task.isCancelled,
              !isActive,
              lifecycleGeneration == stoppedGeneration
        else { return }
        await activityStreamWriter.clearCurrentAmbientSnapshot()
    }
}

// MARK: - Correction readback fallback

extension AmbientContextCollector: AmbientFieldContentProviding {
    /// On-demand correction extraction over the background AX path. It is
    /// independent of ambient-history collection and never persists the full
    /// field value. The frontmost PID is checked on both sides of the await so
    /// an app switch cannot relabel a snapshot from another process.
    func correctionHotSnapshot(
        for app: NSRunningApplication?
    ) async -> CorrectionHotSnapshot? {
        guard let app else { return nil }
        return await correctionHotSnapshot(
            expectedProcessIdentifier: app.processIdentifier,
            expectedBundleIdentifier: app.bundleIdentifier
        )
    }

    /// Testable identity-only surface. Production callers enter through the
    /// `NSRunningApplication` overload, while both paths retain the same
    /// before/after frontmost-process checks around extraction.
    func correctionHotSnapshot(
        expectedProcessIdentifier expectedPID: pid_t,
        expectedBundleIdentifier: String?
    ) async -> CorrectionHotSnapshot? {
        let beforePID = frontmostProcessIdentifierProvider()
        guard beforePID == expectedPID else { return nil }

        let snapshot = await correctionSnapshotExtractor(
            expectedPID,
            expectedBundleIdentifier
        )
        guard !Task.isCancelled else { return nil }
        let afterPID = frontmostProcessIdentifierProvider()
        return Self.validatedCorrectionSnapshot(
            expectedProcessIdentifier: expectedPID,
            expectedBundleIdentifier: expectedBundleIdentifier,
            beforeProcessIdentifier: beforePID,
            afterProcessIdentifier: afterPID,
            snapshot: snapshot
        )
    }

    /// Compatibility surface for callers that have not migrated to the
    /// identity-bearing snapshot. CorrectionObserver never uses this API.
    func currentFieldContent(for app: NSRunningApplication?) async -> String? {
        await correctionHotSnapshot(for: app)?.fullFieldContent
    }

    static func validatedCorrectionSnapshot(
        expectedProcessIdentifier: pid_t,
        expectedBundleIdentifier: String?,
        beforeProcessIdentifier: pid_t?,
        afterProcessIdentifier: pid_t?,
        snapshot: CorrectionHotSnapshot?
    ) -> CorrectionHotSnapshot? {
        guard beforeProcessIdentifier == expectedProcessIdentifier,
              afterProcessIdentifier == expectedProcessIdentifier,
              let snapshot,
              snapshot.processIdentifier == expectedProcessIdentifier else {
            return nil
        }
        if let expectedBundleIdentifier {
            guard snapshot.bundleIdentifier == expectedBundleIdentifier else {
                return nil
            }
        }
        return snapshot
    }
}
