import AppKit
import Foundation
import os

@MainActor
final class DictationMediaController {
    typealias AppleScriptRunner = @Sendable (String) -> String?
    typealias AppRunningChecker = @Sendable (String) -> Bool

    private struct ScriptablePlayer: Sendable {
        let bundleId: String
        let displayName: String
    }

    private struct BrowserPlaybackSession: Hashable, Sendable {
        let bundleId: String
        let browserURL: String
    }

    private struct PauseResult: Sendable {
        let pausedBundleIDs: Set<String>
        let pausedBrowserSessions: Set<BrowserPlaybackSession>
    }

    private enum PlaybackState: String, Sendable {
        case playing
        case paused
        case stopped
        case unknown
    }

    private nonisolated static let supportedPlayers: [ScriptablePlayer] = [
        ScriptablePlayer(bundleId: "com.apple.Music", displayName: "Music"),
        ScriptablePlayer(bundleId: "com.spotify.client", displayName: "Spotify"),
    ]
    private let log = Logger.resonant("DictationMediaController")
    private let workQueue = DispatchQueue(label: "com.resonance.resonant.dictation-media")

    private let runAppleScript: AppleScriptRunner
    private let isAppRunning: AppRunningChecker
    private var pausedBundleIDs: Set<String> = []
    private var pausedBrowserSessions: Set<BrowserPlaybackSession> = []
    private var pendingPauseTask: Task<PauseResult, Never>?

    init() {
        self.runAppleScript = { source in
            Self.runAppleScript(source)
        }
        self.isAppRunning = { bundleId in
            Self.defaultIsAppRunning(bundleId: bundleId)
        }
    }

    init(
        runAppleScript: @escaping AppleScriptRunner,
        isAppRunning: @escaping AppRunningChecker
    ) {
        self.runAppleScript = runAppleScript
        self.isAppRunning = isAppRunning
    }

    func beginPausePlaybackIfNeeded(enabled: Bool) {
        guard enabled, pausedBundleIDs.isEmpty, pausedBrowserSessions.isEmpty, pendingPauseTask == nil else { return }

        let workQueue = self.workQueue
        let runAppleScript = self.runAppleScript
        let isAppRunning = self.isAppRunning
        pendingPauseTask = Task {
            await withCheckedContinuation { continuation in
                workQueue.async {
                    continuation.resume(
                        returning: Self.computePauseResult(
                            runAppleScript: runAppleScript,
                            isAppRunning: isAppRunning
                        )
                    )
                }
            }
        }
    }

    func pausePlaybackIfNeeded(enabled: Bool) async {
        beginPausePlaybackIfNeeded(enabled: enabled)
        await resolvePendingPauseIfNeeded()
    }

    func resumePlaybackIfNeeded() async {
        await resolvePendingPauseIfNeeded()

        let bundlesToResume = pausedBundleIDs
        let browserSessionsToResume = pausedBrowserSessions
        pausedBundleIDs.removeAll()
        pausedBrowserSessions.removeAll()

        guard !bundlesToResume.isEmpty || !browserSessionsToResume.isEmpty else { return }

        let workQueue = self.workQueue
        let runAppleScript = self.runAppleScript
        let isAppRunning = self.isAppRunning
        await withCheckedContinuation { continuation in
            workQueue.async {
                Self.resumePlayback(
                    bundlesToResume: bundlesToResume,
                    browserSessionsToResume: browserSessionsToResume,
                    runAppleScript: runAppleScript,
                    isAppRunning: isAppRunning
                )
                continuation.resume()
            }
        }
    }

    private func resolvePendingPauseIfNeeded() async {
        guard let pendingPauseTask else { return }

        let pauseResult = await pendingPauseTask.value
        self.pendingPauseTask = nil
        pausedBundleIDs = pauseResult.pausedBundleIDs
        pausedBrowserSessions = pauseResult.pausedBrowserSessions

        if !pauseResult.pausedBundleIDs.isEmpty || !pauseResult.pausedBrowserSessions.isEmpty {
            log.debug(
                "Playback pause completed players=\(pauseResult.pausedBundleIDs.count, privacy: .public) browser_sessions=\(pauseResult.pausedBrowserSessions.count, privacy: .public)"
            )
        }
    }

    private nonisolated static func computePauseResult(
        runAppleScript: AppleScriptRunner,
        isAppRunning: AppRunningChecker
    ) -> PauseResult {
        var pausedBundleIDs: Set<String> = []
        var pausedBrowserSessions: Set<BrowserPlaybackSession> = []

        for player in supportedPlayers {
            guard isAppRunning(player.bundleId) else { continue }
            guard playbackState(for: player, runner: runAppleScript) == .playing else { continue }
            guard runAppleScript(pauseScript(for: player)) != nil else { continue }
            pausedBundleIDs.insert(player.bundleId)
        }

        for browserBundleID in BrowserAutomationSupport.allScriptableBrowserBundleIDs() {
            guard isAppRunning(browserBundleID) else { continue }
            let pausedTabs = BrowserAutomationSupport.pauseSupportedMediaTabs(
                bundleId: browserBundleID,
                runner: runAppleScript
            )
            guard !pausedTabs.isEmpty else { continue }
            for pausedTab in pausedTabs {
                pausedBrowserSessions.insert(
                    BrowserPlaybackSession(
                        bundleId: browserBundleID,
                        browserURL: pausedTab.browserURL
                    )
                )
            }
        }

        return PauseResult(
            pausedBundleIDs: pausedBundleIDs,
            pausedBrowserSessions: pausedBrowserSessions
        )
    }

    private nonisolated static func resumePlayback(
        bundlesToResume: Set<String>,
        browserSessionsToResume: Set<BrowserPlaybackSession>,
        runAppleScript: AppleScriptRunner,
        isAppRunning: AppRunningChecker
    ) {
        for player in supportedPlayers where bundlesToResume.contains(player.bundleId) {
            guard isAppRunning(player.bundleId) else { continue }
            guard playbackState(for: player, runner: runAppleScript) == .paused else { continue }
            _ = runAppleScript(playScript(for: player))
        }

        for session in browserSessionsToResume {
            guard isAppRunning(session.bundleId) else { continue }
            _ = BrowserAutomationSupport.resumeMediaTab(
                bundleId: session.bundleId,
                browserURL: session.browserURL,
                runner: runAppleScript
            )
        }
    }

    private nonisolated static func playbackState(
        for player: ScriptablePlayer,
        runner: AppleScriptRunner
    ) -> PlaybackState {
        guard let rawState = runner(stateScript(for: player))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return .unknown
        }

        return PlaybackState(rawValue: rawState) ?? .unknown
    }

    private nonisolated static func stateScript(for player: ScriptablePlayer) -> String {
        """
        tell application id "\(player.bundleId)"
            try
                if player state is playing then return "playing"
                if player state is paused then return "paused"
                if player state is stopped then return "stopped"
            end try
            return "unknown"
        end tell
        """
    }

    private nonisolated static func pauseScript(for player: ScriptablePlayer) -> String {
        """
        tell application id "\(player.bundleId)"
            pause
            return "ok"
        end tell
        """
    }

    private nonisolated static func playScript(for player: ScriptablePlayer) -> String {
        """
        tell application id "\(player.bundleId)"
            play
            return "ok"
        end tell
        """
    }

    private nonisolated static func defaultIsAppRunning(bundleId: String) -> Bool {
        let normalizedBundleID = bundleId.lowercased()
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier?.lowercased() == normalizedBundleID
        }
    }

    private nonisolated static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return descriptor.stringValue
    }
}
