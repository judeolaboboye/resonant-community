import AppKit
import Carbon
import Foundation

enum BrowserAutomationSupport {
    struct TabContext: Equatable {
        let windowTitle: String?
        let browserURL: String?
    }

    struct MediaTabSession: Equatable, Hashable {
        let browserURL: String
    }

    enum MediaPlaybackState: String, Equatable {
        case playing
        case paused
        case stopped
        case unsupported
        case unknown
    }

    private enum BrowserFamily {
        case chromium
        case safari
    }

    private struct ScriptableBrowser {
        let bundleId: String
        let family: BrowserFamily
    }

    private static let fieldSeparator = "\u{1F}"
    private static let chromiumBundleIDs: Set<String> = [
        "com.brave.browser",
        "com.brave.browser.beta",
        "com.duckduckgo.macos.browser",
        "com.google.chrome",
        "com.google.chrome.canary",
        "com.microsoft.edgemac",
        "com.operasoftware.opera",
        "com.operasoftware.operagx",
        "com.vivaldi.vivaldi",
        "company.thebrowser.browser",
    ]
    private static let safariBundleIDs: Set<String> = [
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
    ]
    private static let appleScriptQueue = DispatchQueue(
        label: "com.resonance.resonant.browser-automation"
    )

    static func fallbackContext(
        bundleId: String?,
        currentWindowTitle: String,
        currentURL: String,
        allowUserPrompt: Bool = true
    ) -> TabContext? {
        guard currentWindowTitle.isEmpty || currentURL.isEmpty else { return nil }
        return activeTabContext(bundleId: bundleId, allowUserPrompt: allowUserPrompt)
    }

    static func fallbackContext(
        bundleId: String?,
        currentWindowTitle: String,
        currentURL: String,
        allowUserPrompt: Bool,
        runner: (String) -> String?
    ) -> TabContext? {
        guard currentWindowTitle.isEmpty || currentURL.isEmpty else { return nil }
        return activeTabContext(
            bundleId: bundleId,
            allowUserPrompt: allowUserPrompt,
            runner: runner
        )
    }

    static func activeTabContext(bundleId: String?) -> TabContext? {
        activeTabContext(bundleId: bundleId, allowUserPrompt: true, runner: runAppleScript)
    }

    static func activeTabContext(bundleId: String?, allowUserPrompt: Bool) -> TabContext? {
        activeTabContext(
            bundleId: bundleId,
            allowUserPrompt: allowUserPrompt,
            runner: runAppleScript
        )
    }

    static func activeTabContext(
        bundleId: String?,
        allowUserPrompt: Bool = true,
        runner: (String) -> String?
    ) -> TabContext? {
        guard let browser = scriptableBrowser(for: bundleId) else {
            return nil
        }
        guard allowUserPrompt || hasAutomationConsent(for: browser) else {
            return nil
        }

        let source = scriptSource(for: browser)
        guard let output = runner(source),
              let tabContext = parseTabContext(output)
        else {
            return nil
        }

        return TabContext(
            windowTitle: synthesizedWindowTitle(
                from: tabContext.windowTitle,
                bundleId: browser.bundleId
            ),
            browserURL: tabContext.browserURL
        )
    }

    static func allTabContexts(bundleId: String?, allowUserPrompt: Bool = true) -> [TabContext] {
        allTabContexts(bundleId: bundleId, allowUserPrompt: allowUserPrompt, runner: runAppleScript)
    }

    static func allTabContexts(
        bundleId: String?,
        allowUserPrompt: Bool = true,
        runner: (String) -> String?
    ) -> [TabContext] {
        guard let browser = scriptableBrowser(for: bundleId) else {
            return []
        }
        guard allowUserPrompt || hasAutomationConsent(for: browser) else {
            return []
        }

        guard let output = runner(allTabsScriptSource(for: browser)) else {
            return []
        }

        return parseTabContexts(output)
    }

    static func mediaPlaybackState(bundleId: String?) -> MediaPlaybackState {
        mediaPlaybackState(bundleId: bundleId, runner: runAppleScript)
    }

    static func mediaPlaybackState(
        bundleId: String?,
        runner: (String) -> String?
    ) -> MediaPlaybackState {
        guard let browser = scriptableBrowser(for: bundleId),
              let rawState = runner(mediaStateScript(for: browser))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        else {
            return .unknown
        }

        return MediaPlaybackState(rawValue: rawState) ?? .unknown
    }

    static func pauseMedia(bundleId: String?) -> Bool {
        pauseMedia(bundleId: bundleId, runner: runAppleScript)
    }

    static func pauseMedia(
        bundleId: String?,
        runner: (String) -> String?
    ) -> Bool {
        guard let browser = scriptableBrowser(for: bundleId) else { return false }
        return runner(mediaPauseScript(for: browser)) == "ok"
    }

    static func resumeMedia(bundleId: String?) -> Bool {
        resumeMedia(bundleId: bundleId, runner: runAppleScript)
    }

    static func resumeMedia(
        bundleId: String?,
        runner: (String) -> String?
    ) -> Bool {
        guard let browser = scriptableBrowser(for: bundleId) else { return false }
        return runner(mediaResumeScript(for: browser)) == "ok"
    }

    static func pauseSupportedMediaTabs(bundleId: String?) -> [MediaTabSession] {
        pauseSupportedMediaTabs(bundleId: bundleId, runner: runAppleScript)
    }

    static func pauseSupportedMediaTabs(
        bundleId: String?,
        runner: (String) -> String?
    ) -> [MediaTabSession] {
        guard let browser = scriptableBrowser(for: bundleId),
              let output = runner(mediaPauseAllTabsScript(for: browser))
        else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { normalizedURL(String($0)) }
            .map(MediaTabSession.init(browserURL:))
    }

    static func resumeMediaTab(bundleId: String?, browserURL: String) -> Bool {
        resumeMediaTab(bundleId: bundleId, browserURL: browserURL, runner: runAppleScript)
    }

    static func resumeMediaTab(
        bundleId: String?,
        browserURL: String,
        runner: (String) -> String?
    ) -> Bool {
        guard let browser = scriptableBrowser(for: bundleId),
              let normalizedURL = normalizedURL(browserURL)
        else {
            return false
        }

        return runner(mediaResumeTabScript(for: browser, browserURL: normalizedURL)) == "ok"
    }

    static func allScriptableBrowserBundleIDs() -> [String] {
        Array(chromiumBundleIDs.union(safariBundleIDs)).sorted()
    }

    static func scriptSource(for bundleId: String?) -> String? {
        guard let browser = scriptableBrowser(for: bundleId) else { return nil }
        return scriptSource(for: browser)
    }

    static func parseTabContext(_ output: String) -> TabContext? {
        let fields = output.components(separatedBy: fieldSeparator)
        guard fields.count == 2 else { return nil }

        let title = normalizedField(fields[0])
        let browserURL = normalizedURL(fields[1])
        guard title != nil || browserURL != nil else { return nil }

        return TabContext(windowTitle: title, browserURL: browserURL)
    }

    static func parseTabContexts(_ output: String) -> [TabContext] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { parseTabContext(String($0)) }
    }

    private static func scriptableBrowser(for bundleId: String?) -> ScriptableBrowser? {
        guard let normalizedBundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedBundleId.isEmpty
        else {
            return nil
        }

        if chromiumBundleIDs.contains(normalizedBundleId) {
            return ScriptableBrowser(bundleId: normalizedBundleId, family: .chromium)
        }
        if safariBundleIDs.contains(normalizedBundleId) {
            return ScriptableBrowser(bundleId: normalizedBundleId, family: .safari)
        }

        return nil
    }

    private static func scriptSource(for browser: ScriptableBrowser) -> String {
        let body: String = switch browser.family {
        case .chromium:
            """
            if (count of windows) > 0 then
                try
                    set tabTitle to title of active tab of front window
                end try
                try
                    set tabURL to URL of active tab of front window
                end try
            end if
            """
        case .safari:
            """
            if (count of windows) > 0 then
                try
                    set tabTitle to name of front document
                end try
                try
                    set tabURL to URL of front document
                end try
            end if
            """
        }

        return """
        tell application id "\(browser.bundleId)"
            set tabTitle to ""
            set tabURL to ""
        \(body)
            return tabTitle & (ASCII character 31) & tabURL
        end tell
        """
    }

    private static func allTabsScriptSource(for browser: ScriptableBrowser) -> String {
        let loopBody: String = switch browser.family {
        case .chromium:
            """
                    repeat with tabRef in tabs of browserWindow
                        try
                            set tabTitle to title of tabRef
                            set tabURL to URL of tabRef
                            if tabTitle is not missing value or tabURL is not missing value then
                                set end of tabContexts to ((tabTitle as text) & fieldSeparator & (tabURL as text))
                            end if
                        end try
                    end repeat
            """
        case .safari:
            """
                    repeat with tabRef in tabs of browserWindow
                        try
                            set tabTitle to name of tabRef
                            set tabURL to URL of tabRef
                            if tabTitle is not missing value or tabURL is not missing value then
                                set end of tabContexts to ((tabTitle as text) & fieldSeparator & (tabURL as text))
                            end if
                        end try
                    end repeat
            """
        }

        return """
        -- resonant_all_browser_tabs
        tell application id "\(browser.bundleId)"
            set fieldSeparator to (ASCII character 31)
            set tabContexts to {}
            if (count of windows) > 0 then
                repeat with browserWindow in windows
        \(loopBody)
                end repeat
            end if
            if (count of tabContexts) > 0 then
                set AppleScript's text item delimiters to linefeed
                set joinedContexts to tabContexts as text
                set AppleScript's text item delimiters to ""
                return joinedContexts
            end if
            return ""
        end tell
        """
    }

    private static func mediaStateScript(for browser: ScriptableBrowser) -> String {
        let script = mediaJavaScript(mode: .state)
        return javaScriptExecutionAppleScript(for: browser, javaScript: script)
    }

    private static func mediaPauseScript(for browser: ScriptableBrowser) -> String {
        let script = mediaJavaScript(mode: .pause)
        return javaScriptExecutionAppleScript(for: browser, javaScript: script)
    }

    private static func mediaResumeScript(for browser: ScriptableBrowser) -> String {
        let script = mediaJavaScript(mode: .resume)
        return javaScriptExecutionAppleScript(for: browser, javaScript: script)
    }

    private static func mediaPauseAllTabsScript(for browser: ScriptableBrowser) -> String {
        let stateScript = appleScriptQuoted(mediaJavaScript(mode: .state))
        let pauseScript = appleScriptQuoted(mediaJavaScript(mode: .pause))
        let loopBody: String = switch browser.family {
        case .chromium:
            """
                        set playbackState to execute tabRef javascript "\(stateScript)"
                        if playbackState is "playing" then
                            set pauseResult to execute tabRef javascript "\(pauseScript)"
                            if pauseResult is "ok" then
                                set end of pausedURLs to (URL of tabRef as text)
                            end if
                        end if
            """
        case .safari:
            """
                        set playbackState to do JavaScript "\(stateScript)" in tabRef
                        if playbackState is "playing" then
                            set pauseResult to do JavaScript "\(pauseScript)" in tabRef
                            if pauseResult is "ok" then
                                set end of pausedURLs to (URL of tabRef as text)
                            end if
                        end if
            """
        }

        return """
        -- resonant_media_pause_supported_tabs
        tell application id "\(browser.bundleId)"
            set pausedURLs to {}
            if (count of windows) > 0 then
                repeat with browserWindow in windows
                    repeat with tabRef in tabs of browserWindow
                        try
        \(loopBody)
                        end try
                    end repeat
                end repeat
            end if
            if (count of pausedURLs) > 0 then
                set AppleScript's text item delimiters to linefeed
                set joinedURLs to pausedURLs as text
                set AppleScript's text item delimiters to ""
                return joinedURLs
            end if
            return ""
        end tell
        """
    }

    private static func mediaResumeTabScript(for browser: ScriptableBrowser, browserURL: String) -> String {
        let resumeScript = appleScriptQuoted(mediaJavaScript(mode: .resume))
        let loopBody: String = switch browser.family {
        case .chromium:
            """
                        if (URL of tabRef as text) is targetURL then
                            set resumeResult to execute tabRef javascript "\(resumeScript)"
                            if resumeResult is "ok" then return "ok"
                        end if
            """
        case .safari:
            """
                        if (URL of tabRef as text) is targetURL then
                            set resumeResult to do JavaScript "\(resumeScript)" in tabRef
                            if resumeResult is "ok" then return "ok"
                        end if
            """
        }

        return """
        -- resonant_media_resume_matching_url
        tell application id "\(browser.bundleId)"
            set targetURL to "\(appleScriptQuoted(browserURL))"
            if (count of windows) > 0 then
                repeat with browserWindow in windows
                    repeat with tabRef in tabs of browserWindow
                        try
        \(loopBody)
                        end try
                    end repeat
                end repeat
            end if
            return "noop"
        end tell
        """
    }

    private enum MediaControlMode {
        case state
        case pause
        case resume
    }

    private static func mediaJavaScript(mode: MediaControlMode) -> String {
        let action: String = switch mode {
        case .state:
            """
            if (media.some(element => !element.paused && !element.ended)) return 'playing';
            if (media.some(element => element.paused && !element.ended)) return 'paused';
            return 'stopped';
            """
        case .pause:
            """
            let changed = false;
            for (const element of media) {
              if (!element.paused && !element.ended) {
                element.pause();
                changed = true;
              }
            }
            return changed ? 'ok' : 'noop';
            """
        case .resume:
            """
            let changed = false;
            for (const element of media) {
              if (element.paused && !element.ended) {
                const playResult = element.play();
                if (playResult && typeof playResult.catch === 'function') {
                  playResult.catch(() => {});
                }
                changed = true;
              }
            }
            return changed ? 'ok' : 'noop';
            """
        }

        return """
        (function() {
          const host = (window.location.host || '').toLowerCase();
          const meetingHosts = ['meet.google.com', 'zoom.us', 'teams.microsoft.com', 'teams.live.com', 'webex.com', 'meet.proton.me', 'v.ringcentral.com', 'meetings.ringcentral.com', 'app.ringcentral.com', 'global.gotomeeting.com', 'app.gotomeeting.com', 'meet.goto.com', 'gotomeet.me', 'meet.jit.si', '8x8.vc', 'whereby.com', 'app.chime.aws', 'chime.aws', 'meeting.zoho.com', 'meet.zoho.com', 'meetings.dialpad.com'];
          const isMeetingHost = meetingHosts.some(candidate => host === candidate || host.endsWith('.' + candidate));
          if (isMeetingHost) return 'unsupported';
          const media = Array.from(document.querySelectorAll('audio, video'));
          if (!media.length) return 'stopped';
          \(action)
        })()
        """
    }

    private static func javaScriptExecutionAppleScript(
        for browser: ScriptableBrowser,
        javaScript: String
    ) -> String {
        let escapedScript = appleScriptQuoted(javaScript)
        let body: String = switch browser.family {
        case .chromium:
            """
            if (count of windows) > 0 then
                try
                    return execute active tab of front window javascript "\(escapedScript)"
                end try
            end if
            """
        case .safari:
            """
            if (count of windows) > 0 then
                try
                    return do JavaScript "\(escapedScript)" in current tab of front window
                end try
            end if
            """
        }

        return """
        tell application id "\(browser.bundleId)"
        \(body)
            return "unknown"
        end tell
        """
    }

    private static func runAppleScript(_ source: String) -> String? {
        appleScriptQueue.sync {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return nil }
            let descriptor = script.executeAndReturnError(&error)
            guard error == nil else { return nil }
            return descriptor.stringValue
        }
    }

    private static func hasAutomationConsent(for browser: ScriptableBrowser) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleId).isEmpty else {
            return false
        }

        var addressDesc = AEAddressDesc()
        let bundleIDData = Data(browser.bundleId.utf8)
        let createStatus: OSStatus = bundleIDData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(paramErr) }
            return OSStatus(
                AECreateDesc(
                    DescType(typeApplicationBundleID),
                    baseAddress,
                    bundleIDData.count,
                    &addressDesc
                )
            )
        }
        guard createStatus == noErr else {
            return false
        }
        defer { AEDisposeDesc(&addressDesc) }

        let status = AEDeterminePermissionToAutomateTarget(
            &addressDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        )
        return status == noErr
    }

    private static func normalizedField(_ field: String) -> String? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "missing value" else { return nil }
        return trimmed
    }

    private static func normalizedURL(_ field: String) -> String? {
        guard let normalizedField = normalizedField(field),
              ContextExtractor.looksLikeURL(normalizedField)
        else {
            return nil
        }

        if normalizedField.hasPrefix("http://") || normalizedField.hasPrefix("https://") {
            return normalizedField
        }
        return "https://\(normalizedField)"
    }

    private static func synthesizedWindowTitle(from title: String?, bundleId: String) -> String? {
        guard let title else { return nil }
        guard let browserName = BrowserCatalog.displayName(for: bundleId) else { return title }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return nil }

        let knownSuffixes = [
            " - \(browserName)",
            " \u{2014} \(browserName)",
            " \u{2013} \(browserName)"
        ]
        if knownSuffixes.contains(where: { normalizedTitle.hasSuffix($0) }) {
            return normalizedTitle
        }

        return "\(normalizedTitle) - \(browserName)"
    }

    private static func appleScriptQuoted(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
