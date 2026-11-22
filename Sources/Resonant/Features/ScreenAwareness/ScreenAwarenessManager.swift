import AppKit
import CoreGraphics
import os

/// Orchestrates the screen-awareness feature: left-Option press captures a
/// screenshot and starts a local dictation recording; release stops it,
/// transcribes locally, gates the request behind a Touch ID / password
/// approval (`ScreenAwarenessActionApproval`), then hands the screenshot +
/// spoken request to the `claude` CLI, which can answer questions or take a
/// narrow set of actions (open an app/URL, web lookup — see
/// `ClaudeCLIRunner` for the exact tool scoping). Entirely local/free STT —
/// no cloud speech-to-text, no paid API key.
///
/// Deliberately does NOT route through `AppState.startDictation()`/
/// `endDictation()` — it calls `DictationManager`'s lower-level API directly,
/// the same one `AppState` itself uses, so the primary dictation hotkey state
/// machine is never touched.
@MainActor
final class ScreenAwarenessManager {
    private let log = Logger.resonant("ScreenAwarenessManager")

    private let dictationManager: DictationManager
    private let settingsManager: SettingsManager
    private let screenshotCapturer = ScreenAwarenessScreenshotCapturer()
    private let claudeCLIRunner = ClaudeCLIRunner()
    private let overlay = ScreenAwarenessOverlayWindowManager()
    private let approval = ScreenAwarenessActionApproval()
    private var talkback: ScreenAwarenessTalkback?

    private var lifecycle = ScreenAwarenessLifecycle()
    private var pendingScreenshotURL: URL?

    /// True while `handleTriggerDown` is still mid-flight (recording start +
    /// screenshot capture, both `await`s). MainActor tasks interleave at
    /// `await` points, so a fast tap can get `handleTriggerUp` running before
    /// `handleTriggerDown` finishes — without this guard, `handleTriggerUp`
    /// would call `stopAndTranscribe` before recording ever started,
    /// producing empty/garbled transcripts and leaving the shared recorder in
    /// an inconsistent state that could then block ordinary right-Option
    /// dictation. Mirrors `AppState.isStartingRecording` /
    /// `pendingStopAfterStart` exactly.
    private var isStartingCapture = false
    private var pendingStopAfterStart = false

    /// Set by `AppState` once its own stored properties exist (can't be wired
    /// during `init` before `self` is fully formed). Reads
    /// `isRecording`/`isStartingRecording`/`isFinishingCapture` so this
    /// feature never races the shared microphone/audio pipeline with
    /// dictation, and vice versa.
    var isDictationBusyProvider: (() -> Bool)?

    init(dictationManager: DictationManager, settingsManager: SettingsManager) {
        self.dictationManager = dictationManager
        self.settingsManager = settingsManager
    }

    /// Whether the left-Option hotkey should be armed: the feature is enabled
    /// in settings AND the user hasn't separately bound left Option as a
    /// custom dictation trigger (which would otherwise double-fire on every
    /// press).
    var isHotkeyAvailable: Bool {
        guard settingsManager.screenAwarenessEnabled else { return false }
        return !settingsManager.hotkeyTriggers.contains(.custom(keyCode: ScreenAwarenessTrigger.keyCode))
    }

    func teardown() {
        overlay.teardown()
        talkback?.stop()
    }

    // MARK: - Trigger handlers

    func handleTriggerDown() async {
        // Left Option while an answer is being spoken means "stop talking,"
        // not "ask something new" — this press is entirely consumed as an
        // interrupt (its paired release is a no-op, since `lifecycle` never
        // entered a capturing state for it).
        if let talkback, talkback.isSpeaking {
            talkback.stop()
            overlay.dismiss()
            return
        }

        guard lifecycle.canStart else { return }
        guard isDictationBusyProvider?() != true else {
            log.notice("Screen awareness skipped: dictation is busy")
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            log.notice("Screen Recording permission not yet granted — prompted, waiting for grant")
            return
        }

        lifecycle.beginCapture()
        isStartingCapture = true
        pendingStopAfterStart = false
        overlay.showRecording()

        // Start the microphone FIRST, before the screenshot — this is the
        // window that would otherwise clip the user's first words. The
        // screenshot happens while they keep talking.
        do {
            try await dictationManager.startRecording(
                selectedInputDeviceUID: settingsManager.inputDeviceUID,
                outputURL: nil,
                recordingRetention: .ephemeral
            )
        } catch {
            log.error("Failed to start recording for screen awareness: \(error, privacy: .public)")
            isStartingCapture = false
            await fail(.screenshotCaptureFailed)
            return
        }

        do {
            pendingScreenshotURL = try await screenshotCapturer.captureFrontDisplay()
        } catch {
            isStartingCapture = false
            _ = try? await dictationManager.stopAndTranscribe(
                targetApplication: nil,
                extractColdContext: false,
                recordingRetention: .ephemeral
            )
            await fail(.screenshotCaptureFailed)
            return
        }

        isStartingCapture = false
        if pendingStopAfterStart {
            pendingStopAfterStart = false
            await finishCapture()
        }
    }

    func handleTriggerUp() async {
        guard lifecycle.isCapturing else { return }
        guard !isStartingCapture else {
            // Recording/screenshot start is still in flight (fast tap) —
            // defer the stop until `handleTriggerDown` finishes, exactly
            // like `AppState.pendingStopAfterStart`, instead of racing ahead
            // of a capture that hasn't started yet.
            pendingStopAfterStart = true
            return
        }
        await finishCapture()
    }

    func cancel() async {
        guard lifecycle.isCapturing else { return }
        if isStartingCapture {
            pendingStopAfterStart = false
            isStartingCapture = false
        }
        _ = try? await dictationManager.stopAndTranscribe(
            targetApplication: nil,
            extractColdContext: false,
            recordingRetention: .ephemeral
        )
        if let pendingScreenshotURL {
            try? FileManager.default.removeItem(at: pendingScreenshotURL)
        }
        pendingScreenshotURL = nil
        overlay.dismiss()
        lifecycle.endCapture()
    }

    private func finishCapture() async {
        overlay.showThinking()

        let transcript: String
        do {
            let result = try await dictationManager.stopAndTranscribe(
                targetApplication: NSWorkspace.shared.frontmostApplication,
                extractColdContext: false,
                recordingRetention: .ephemeral
            )
            transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            log.error("Transcription failed for screen awareness: \(error, privacy: .public)")
            await fail(.emptyTranscript)
            return
        }

        guard !transcript.isEmpty else {
            await fail(.emptyTranscript)
            return
        }

        guard let screenshotURL = pendingScreenshotURL else {
            await fail(.screenshotCaptureFailed)
            return
        }

        defer {
            try? FileManager.default.removeItem(at: screenshotURL)
            pendingScreenshotURL = nil
        }

        // Request-level confirmation, every time: this can act on the Mac,
        // so nothing runs without an explicit Touch ID / password approval
        // for THIS specific request first. See `ScreenAwarenessActionApproval`
        // for why this can't be a per-individual-action confirmation.
        overlay.showAwaitingApproval()
        switch await approval.requestApproval(for: transcript) {
        case .approved:
            overlay.showThinking()
        case .denied:
            await fail(.approvalDenied)
            return
        case .unavailable:
            await fail(.approvalUnavailable)
            return
        }

        do {
            let prompt = Self.buildPrompt(screenshotPath: screenshotURL.path, question: transcript)
            let answer = try await claudeCLIRunner.run(prompt: prompt)
            overlay.showAnswer(answer)
            if settingsManager.screenAwarenessTalkbackEnabled {
                let speaker = talkback ?? ScreenAwarenessTalkback()
                talkback = speaker
                speaker.speak(answer)
            }
        } catch let error as ScreenAwarenessError {
            await fail(error)
            return
        } catch {
            log.error("claude CLI run failed: \(error, privacy: .public)")
            await fail(.claudeCLIFailed(exitCode: -1, stderrTail: ""))
            return
        }

        lifecycle.endCapture()
    }

    // MARK: - Helpers

    private func fail(_ error: ScreenAwarenessError) async {
        log.error("Screen awareness failed: \(String(describing: error), privacy: .public)")
        overlay.showError(error.userFacingMessage)
        if let pendingScreenshotURL {
            try? FileManager.default.removeItem(at: pendingScreenshotURL)
        }
        pendingScreenshotURL = nil
        lifecycle.endCapture()
    }

    private static func buildPrompt(screenshotPath: String, question: String) -> String {
        """
        You're a voice-triggered Mac assistant. A screenshot of the user's screen was just \
        captured at: \(screenshotPath) — use your Read tool to look at it for context on what \
        they're doing.

        The user's spoken request follows. If it's a question, just answer it concisely (a few \
        sentences, plain text, no markdown headers). You can also open an app or a URL, or look \
        something up on the web, if that's what they asked for — briefly confirm in plain text \
        what you did. You do NOT have general command execution, file editing, or any other \
        system access beyond that; if the request needs more than opening something or a web \
        lookup, say so instead of trying to work around it.

        User's request: \(question)
        """
    }
}
