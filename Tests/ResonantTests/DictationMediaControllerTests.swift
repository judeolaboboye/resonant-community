import XCTest
@testable import Resonant

@MainActor
final class DictationMediaControllerTests: XCTestCase {

    func testPauseOnlyPausesSupportedPlayersThatAreActivelyPlaying() async {
        let environment = ScriptEnvironment(
            runningBundleIDs: ["com.apple.Music", "com.spotify.client"],
            playbackStateByBundleID: [
                "com.apple.Music": "playing",
                "com.spotify.client": "paused",
            ]
        )
        let controller = DictationMediaController(
            runAppleScript: { source in environment.run(source) },
            isAppRunning: { bundleId in environment.isRunning(bundleId: bundleId) }
        )

        await controller.pausePlaybackIfNeeded(enabled: true)

        XCTAssertEqual(environment.playbackStateByBundleID["com.apple.Music"], "paused")
        XCTAssertEqual(environment.playbackStateByBundleID["com.spotify.client"], "paused")
        XCTAssertEqual(environment.pauseCommands.count, 1)
        XCTAssertEqual(environment.playCommands.count, 0)
    }

    func testResumeOnlyRestartsPlayersPausedByResonant() async {
        let environment = ScriptEnvironment(
            runningBundleIDs: ["com.apple.Music", "com.spotify.client"],
            playbackStateByBundleID: [
                "com.apple.Music": "playing",
                "com.spotify.client": "paused",
            ]
        )
        let controller = DictationMediaController(
            runAppleScript: { source in environment.run(source) },
            isAppRunning: { bundleId in environment.isRunning(bundleId: bundleId) }
        )

        await controller.pausePlaybackIfNeeded(enabled: true)
        await controller.resumePlaybackIfNeeded()

        XCTAssertEqual(environment.playbackStateByBundleID["com.apple.Music"], "playing")
        XCTAssertEqual(environment.playbackStateByBundleID["com.spotify.client"], "paused")
        XCTAssertEqual(environment.pauseCommands.count, 1)
        XCTAssertEqual(environment.playCommands.count, 1)
        XCTAssertTrue(environment.playCommands.allSatisfy { $0.contains("com.apple.Music") })
    }

    func testResumeSkipsPlayersNoLongerPaused() async {
        let environment = ScriptEnvironment(
            runningBundleIDs: ["com.apple.Music"],
            playbackStateByBundleID: ["com.apple.Music": "playing"]
        )
        let controller = DictationMediaController(
            runAppleScript: { source in environment.run(source) },
            isAppRunning: { bundleId in environment.isRunning(bundleId: bundleId) }
        )

        await controller.pausePlaybackIfNeeded(enabled: true)
        environment.playbackStateByBundleID["com.apple.Music"] = "playing"

        await controller.resumePlaybackIfNeeded()

        XCTAssertEqual(environment.pauseCommands.count, 1)
        XCTAssertEqual(environment.playCommands.count, 0)
    }

    func testPauseDoesNothingWhenFeatureDisabled() async {
        let environment = ScriptEnvironment(
            runningBundleIDs: ["com.apple.Music"],
            playbackStateByBundleID: ["com.apple.Music": "playing"]
        )
        let controller = DictationMediaController(
            runAppleScript: { source in environment.run(source) },
            isAppRunning: { bundleId in environment.isRunning(bundleId: bundleId) }
        )

        await controller.pausePlaybackIfNeeded(enabled: false)

        XCTAssertEqual(environment.playbackStateByBundleID["com.apple.Music"], "playing")
        XCTAssertTrue(environment.executedScripts.isEmpty)
    }

    func testPauseAndResumeBrowserPlaybackForSupportedMediaSite() async {
        let environment = ScriptEnvironment(
            runningBundleIDs: ["company.thebrowser.browser"],
            playbackStateByBundleID: [:],
            browserTabsByBundleID: [
                "company.thebrowser.browser": [
                    BrowserTabState(
                        title: "Inbox",
                        url: "https://mail.google.com/mail/u/0/",
                        playbackState: "stopped",
                        isSelected: true
                    ),
                    BrowserTabState(
                        title: "Lo-fi mix - YouTube",
                        url: "https://www.youtube.com/watch?v=abc123",
                        playbackState: "playing",
                        isSelected: false
                    ),
                ]
            ]
        )
        let controller = DictationMediaController(
            runAppleScript: { source in environment.run(source) },
            isAppRunning: { bundleId in environment.isRunning(bundleId: bundleId) }
        )

        await controller.pausePlaybackIfNeeded(enabled: true)
        await controller.resumePlaybackIfNeeded()

        XCTAssertEqual(
            environment.browserTab(
                bundleId: "company.thebrowser.browser",
                url: "https://www.youtube.com/watch?v=abc123"
            )?.playbackState,
            "playing"
        )
        XCTAssertEqual(environment.browserPauseCommands.count, 1)
        XCTAssertEqual(environment.browserPlayCommands.count, 1)
    }

    func testPauseAndResumeBrowserPlaybackForGenericMediaSite() async {
        let environment = ScriptEnvironment(
            runningBundleIDs: ["company.thebrowser.browser"],
            playbackStateByBundleID: [:],
            browserTabsByBundleID: [
                "company.thebrowser.browser": [
                    BrowserTabState(
                        title: "Podcast",
                        url: "https://example.fm/episode-1",
                        playbackState: "playing",
                        isSelected: false
                    ),
                    BrowserTabState(
                        title: "Inbox",
                        url: "https://mail.google.com/mail/u/0/",
                        playbackState: "stopped",
                        isSelected: true
                    ),
                ]
            ]
        )
        let controller = DictationMediaController(
            runAppleScript: { source in environment.run(source) },
            isAppRunning: { bundleId in environment.isRunning(bundleId: bundleId) }
        )

        await controller.pausePlaybackIfNeeded(enabled: true)
        await controller.resumePlaybackIfNeeded()

        XCTAssertEqual(
            environment.browserTab(
                bundleId: "company.thebrowser.browser",
                url: "https://example.fm/episode-1"
            )?.playbackState,
            "playing"
        )
    }

    func testResumeSkipsBrowserWhenPausedTabCloses() async {
        let environment = ScriptEnvironment(
            runningBundleIDs: ["company.thebrowser.browser"],
            playbackStateByBundleID: [:],
            browserTabsByBundleID: [
                "company.thebrowser.browser": [
                    BrowserTabState(
                        title: "Inbox",
                        url: "https://mail.google.com/mail/u/0/",
                        playbackState: "stopped",
                        isSelected: true
                    ),
                    BrowserTabState(
                        title: "Lo-fi mix - YouTube",
                        url: "https://www.youtube.com/watch?v=abc123",
                        playbackState: "playing",
                        isSelected: false
                    ),
                ]
            ]
        )
        let controller = DictationMediaController(
            runAppleScript: { source in environment.run(source) },
            isAppRunning: { bundleId in environment.isRunning(bundleId: bundleId) }
        )

        await controller.pausePlaybackIfNeeded(enabled: true)
        environment.browserTabsByBundleID["company.thebrowser.browser"] = [
            BrowserTabState(
                title: "Inbox",
                url: "https://mail.google.com/mail/u/0/",
                playbackState: "stopped",
                isSelected: true
            )
        ]

        await controller.resumePlaybackIfNeeded()

        XCTAssertEqual(environment.browserPauseCommands.count, 1)
        XCTAssertNil(
            environment.browserTab(
                bundleId: "company.thebrowser.browser",
                url: "https://www.youtube.com/watch?v=abc123"
            )
        )
        XCTAssertEqual(
            environment.browserTab(
                bundleId: "company.thebrowser.browser",
                url: "https://mail.google.com/mail/u/0/"
            )?.playbackState,
            "stopped"
        )
    }

    func testPauseSkipsWorkMeetingBrowserTabs() async {
        let environment = ScriptEnvironment(
            runningBundleIDs: ["company.thebrowser.browser"],
            playbackStateByBundleID: [:],
            browserTabsByBundleID: [
                "company.thebrowser.browser": [
                    BrowserTabState(
                        title: "RingCentral",
                        url: "https://v.ringcentral.com/join/123456",
                        playbackState: "playing",
                        isSelected: true
                    ),
                    BrowserTabState(
                        title: "Lo-fi mix - YouTube",
                        url: "https://www.youtube.com/watch?v=abc123",
                        playbackState: "playing",
                        isSelected: false
                    ),
                ]
            ]
        )
        let controller = DictationMediaController(
            runAppleScript: { source in environment.run(source) },
            isAppRunning: { bundleId in environment.isRunning(bundleId: bundleId) }
        )

        await controller.pausePlaybackIfNeeded(enabled: true)

        XCTAssertEqual(
            environment.browserTab(
                bundleId: "company.thebrowser.browser",
                url: "https://v.ringcentral.com/join/123456"
            )?.playbackState,
            "playing"
        )
        XCTAssertEqual(
            environment.browserTab(
                bundleId: "company.thebrowser.browser",
                url: "https://www.youtube.com/watch?v=abc123"
            )?.playbackState,
            "paused"
        )
    }

    func testBackgroundPauseCanResumeAfterQuickStop() async {
        let environment = ScriptEnvironment(
            runningBundleIDs: ["com.apple.Music"],
            playbackStateByBundleID: ["com.apple.Music": "playing"]
        )
        let controller = DictationMediaController(
            runAppleScript: { source in
                usleep(150_000)
                return environment.run(source)
            },
            isAppRunning: { bundleId in environment.isRunning(bundleId: bundleId) }
        )

        controller.beginPausePlaybackIfNeeded(enabled: true)

        XCTAssertEqual(environment.playbackStateByBundleID["com.apple.Music"], "playing")
        await controller.resumePlaybackIfNeeded()

        XCTAssertEqual(environment.playbackStateByBundleID["com.apple.Music"], "playing")
        XCTAssertEqual(environment.pauseCommands.count, 1)
        XCTAssertEqual(environment.playCommands.count, 1)
    }
}

private struct BrowserTabState {
    var title: String
    var url: String
    var playbackState: String
    var isSelected: Bool
}

private final class ScriptEnvironment: @unchecked Sendable {
    let runningBundleIDs: Set<String>
    var playbackStateByBundleID: [String: String]
    var browserTabsByBundleID: [String: [BrowserTabState]]
    private(set) var executedScripts: [String] = []

    init(
        runningBundleIDs: Set<String>,
        playbackStateByBundleID: [String: String],
        browserTabsByBundleID: [String: [BrowserTabState]] = [:]
    ) {
        self.runningBundleIDs = runningBundleIDs
        self.playbackStateByBundleID = playbackStateByBundleID
        self.browserTabsByBundleID = browserTabsByBundleID
    }

    func isRunning(bundleId: String) -> Bool {
        runningBundleIDs.contains(bundleId)
    }

    func run(_ source: String) -> String? {
        executedScripts.append(source)
        guard let bundleId = bundleId(in: source) else { return nil }
        let lines = source
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if source.contains("return tabTitle & (ASCII character 31) & tabURL"),
           let browserTab = selectedBrowserTab(for: bundleId) {
            return "\(browserTab.title)\u{1F}\(browserTab.url)"
        }

        if source.contains("resonant_media_pause_supported_tabs") {
            let pausedURLs = browserTabsByBundleID[bundleId, default: []]
                .enumerated()
                .compactMap { index, browserTab -> String? in
                    let host = URL(string: browserTab.url)?.host?.lowercased() ?? ""
                    let meetingHosts = [
                        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com",
                        "meet.proton.me", "v.ringcentral.com", "meetings.ringcentral.com", "app.ringcentral.com",
                        "global.gotomeeting.com", "app.gotomeeting.com", "meet.goto.com", "gotomeet.me",
                        "meet.jit.si", "8x8.vc", "whereby.com", "app.chime.aws", "chime.aws",
                        "meeting.zoho.com", "meet.zoho.com", "meetings.dialpad.com",
                    ]
                    guard !meetingHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }),
                          browserTab.playbackState == "playing"
                    else {
                        return nil
                    }
                    browserTabsByBundleID[bundleId]?[index].playbackState = "paused"
                    return browserTab.url
                }
            return pausedURLs.joined(separator: "\n")
        }

        if source.contains("resonant_media_resume_matching_url") {
            guard let targetURL = targetURL(in: source),
                  let index = browserTabsByBundleID[bundleId]?.firstIndex(where: { $0.url == targetURL }),
                  browserTabsByBundleID[bundleId]?[index].playbackState == "paused"
            else {
                return "noop"
            }
            browserTabsByBundleID[bundleId]?[index].playbackState = "playing"
            return "ok"
        }

        if source.contains("querySelectorAll('audio, video')") {
            guard let browserTab = selectedBrowserTab(for: bundleId) else { return "unknown" }
            let host = URL(string: browserTab.url)?.host?.lowercased() ?? ""
            let meetingHosts = [
                "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com",
                "meet.proton.me", "v.ringcentral.com", "meetings.ringcentral.com", "app.ringcentral.com",
                "global.gotomeeting.com", "app.gotomeeting.com", "meet.goto.com", "gotomeet.me",
                "meet.jit.si", "8x8.vc", "whereby.com", "app.chime.aws", "chime.aws",
                "meeting.zoho.com", "meet.zoho.com", "meetings.dialpad.com",
            ]
            guard !meetingHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return "unsupported" }

            if source.contains("element.pause()") {
                if browserTab.playbackState == "playing" {
                    updateBrowserTab(bundleId: bundleId, url: browserTab.url, playbackState: "paused")
                    return "ok"
                }
                return "noop"
            }

            if source.contains("element.play()") {
                if browserTab.playbackState == "paused" {
                    updateBrowserTab(bundleId: bundleId, url: browserTab.url, playbackState: "playing")
                    return "ok"
                }
                return "noop"
            }

            return browserTab.playbackState
        }

        if source.contains("player state") {
            return playbackStateByBundleID[bundleId] ?? "unknown"
        }
        if lines.contains("pause") {
            playbackStateByBundleID[bundleId] = "paused"
            return "ok"
        }
        if lines.contains("play") {
            playbackStateByBundleID[bundleId] = "playing"
            return "ok"
        }

        return nil
    }

    var pauseCommands: [String] {
        executedScripts.filter {
            $0.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains("pause")
        }
    }

    var playCommands: [String] {
        executedScripts.filter {
            $0.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains("play")
        }
    }

    var browserPauseCommands: [String] {
        executedScripts.filter { $0.contains("element.pause()") }
    }

    var browserPlayCommands: [String] {
        executedScripts.filter { $0.contains("element.play()") }
    }

    func browserTab(bundleId: String, url: String) -> BrowserTabState? {
        browserTabsByBundleID[bundleId]?.first(where: { $0.url == url })
    }

    private func bundleId(in source: String) -> String? {
        if source.contains("\"com.apple.Music\"") {
            return "com.apple.Music"
        }
        if source.contains("\"com.spotify.client\"") {
            return "com.spotify.client"
        }
        if source.contains("\"company.thebrowser.browser\"") {
            return "company.thebrowser.browser"
        }
        if source.contains("\"com.google.chrome\"") {
            return "com.google.chrome"
        }
        if source.contains("\"com.apple.safari\"") {
            return "com.apple.safari"
        }
        return nil
    }

    private func selectedBrowserTab(for bundleId: String) -> BrowserTabState? {
        browserTabsByBundleID[bundleId]?.first(where: \.isSelected)
            ?? browserTabsByBundleID[bundleId]?.first
    }

    private func updateBrowserTab(bundleId: String, url: String, playbackState: String) {
        guard let index = browserTabsByBundleID[bundleId]?.firstIndex(where: { $0.url == url }) else { return }
        browserTabsByBundleID[bundleId]?[index].playbackState = playbackState
    }

    private func targetURL(in source: String) -> String? {
        guard let prefixRange = source.range(of: "set targetURL to \"") else { return nil }
        let remaining = source[prefixRange.upperBound...]
        guard let endQuote = remaining.firstIndex(of: "\"") else { return nil }
        return String(remaining[..<endQuote])
    }
}
