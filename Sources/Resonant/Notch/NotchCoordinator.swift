import CoreGraphics
import Foundation
import Observation

enum NotchPresentationStyle: Equatable {
    case compact
    case minimal
    case panel
}

enum NotchTab: Equatable {
    case home
    case screens
}

/// Central state for the notch overlay. NotchWindowManager and NotchContentView observe this.
/// No IPC — driven directly by AppState.
@MainActor
@Observable
final class NotchCoordinator {

    // MARK: - Primary state

    private(set) var state: NotchOverlayState = .idle

    // MARK: - Expression overlay (level up, streak, achievement)

    var activeExpression: ExpressionType?
    var expressionVisible = false
    var homeVisible = false
    var homeHovered = false
    var currentTab: NotchTab = .home
    var recordingLocked = false
    var recordingHint: String?
    /// Best-effort streaming transcript shown while recording (see
    /// DictationLivePreviewController). Cleared whenever recording ends.
    var recordingLiveText: String?
    var targetBundleId: String?
    var targetWindowTitle: String?
    var targetBrowserURL: String?
    private var autoDismissTask: Task<Void, Never>?
    private var deferredPresentationTask: Task<Void, Never>?
    private var expressionDismissTask: Task<Void, Never>?
    private var presentationStateMachine = NotchPresentationStateMachine()
    /// Speaks state transitions to VoiceOver users. Injectable for tests.
    @ObservationIgnored var voiceOverAnnouncer: VoiceOverAnnouncer = .shared

    // MARK: - Meeting recording (background indicator, independent of primary state)

    var isMeetingRecording = false
    var meetingElapsed: TimeInterval = 0
    var meetingDetectedApp: String?

    // MARK: - Convenience helpers

    func setState(_ state: NotchOverlayState) {
        applyPresentationRequest(NotchPresentationRequest(state: state))
    }

    func showDone(_ text: String, timeout: Duration = .seconds(4), fallback: NotchOverlayState = .idle) {
        applyPresentationRequest(NotchPresentationRequest(
            state: .done(text: text),
            autoDismiss: NotchAutoDismiss(timeout: timeout, fallback: fallback)
        ))
    }

    func showNotice(_ notice: NotchOverlayState.Notice, timeout: Duration = .seconds(4)) {
        applyPresentationRequest(NotchPresentationRequest(
            state: .notice(notice),
            autoDismiss: NotchAutoDismiss(timeout: timeout, fallback: .idle)
        ))
    }

    func showError(_ message: String, subtype: NotchOverlayState.ErrorSubtype = .generic) {
        applyPresentationRequest(NotchPresentationRequest(
            state: .error(message: message, subtype: subtype),
            autoDismiss: NotchAutoDismiss(
                timeout: NotchErrorPresentationPolicy.autoDismissDuration(for: subtype),
                fallback: .idle
            )
        ))
    }

    func triggerExpression(_ expression: ExpressionType) {
        activeExpression = expression
        expressionVisible = true
        expressionDismissTask?.cancel()
        expressionDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.expressionVisible = false
        }
    }

    func setTargetContext(bundleId: String?, windowTitle: String?, browserURL: String? = nil) {
        targetBundleId = bundleId?.trimmedNilIfEmpty
        targetWindowTitle = windowTitle?.trimmedNilIfEmpty
        targetBrowserURL = browserURL?.trimmedNilIfEmpty
    }

    func clearTargetContext() {
        targetBundleId = nil
        targetWindowTitle = nil
        targetBrowserURL = nil
    }

    // MARK: - Derived properties (used by views)

    var showsHome: Bool {
        homeVisible && isCompactState && !expressionVisible
    }

    var isCompactState: Bool {
        switch state {
        case .idle, .done:
            return true
        default:
            return false
        }
    }

    var isHotMicActive: Bool {
        if case .hotMic = state { return true }
        return false
    }

    var hotMicLiveText: String? {
        if case .hotMic(_, let text) = state { return text }
        return nil
    }

    var voiceMode: String {
        switch state {
        case .idle:
            return "idle"
        case .recording(let mode, _, _):
            return mode == .memo ? "memo" : "listening"
        case .processing:
            return "processing"
        case .done:
            return "success"
        case .notice:
            return "notice"
        case .error:
            return "error"
        case .hotMic:
            return "hotMic"
        case .command:
            return "command"
        }
    }

    var modeLabel: String {
        switch state {
        case .idle:                          return ""
        case .recording(let mode, _, _):
            if isRecordingLocked {
                return mode == .memo ? "Memo locked…" : "Locked. Keep talking…"
            }
            if let recordingHint {
                return recordingHint
            }
            switch mode {
            case .dictation: return "Listening…"
            case .memo:      return "Recording memo…"
            case .command:   return "Listening for command…"
            }
        case .processing(_, let stage):     return stage
        case .done:                         return "Done"
        case .notice(let notice):           return notice.title
        case .error(let msg, _):            return msg
        case .hotMic:                       return "Hot mic"
        case .command(let stage):
            switch stage {
            case .listening:          return "Listening for command…"
            case .awaitingFollowUp(_, _, let status): return status
            case .thinking(let status): return status
            case .result(let text, _): return text
            }
        }
    }

    var audioLevel: Float {
        if case .recording(_, let level, _) = state { return level }
        if case .hotMic(let level, _) = state { return level }
        if case .command(.listening(let level, _)) = state { return level }
        if case .command(.awaitingFollowUp(let level, _, _)) = state { return level }
        return 0
    }

    var isCommandThinking: Bool {
        if case .command(.thinking(_)) = state { return true }
        return false
    }

    var processingProgress: Double {
        if case .processing(let p, _) = state { return p }
        return 0
    }

    var doneText: String? {
        if case .done(let text) = state { return text }
        return nil
    }

    var errorSubtype: NotchOverlayState.ErrorSubtype? {
        if case .error(_, let sub) = state { return sub }
        return nil
    }

    var recordingElapsed: TimeInterval {
        if case .recording(_, _, let t) = state { return t }
        if case .command(.listening(_, let t)) = state { return t }
        if case .command(.awaitingFollowUp(_, let t, _)) = state { return t }
        return 0
    }

    var recordingMode: DictationMode? {
        if case .recording(let m, _, _) = state { return m }
        return nil
    }

    var isRecordingLocked: Bool {
        recordingLocked && recordingMode != nil
    }

    func presentationStyle(for overlayMode: OverlayMode) -> NotchPresentationStyle {
        if expressionVisible || showsHome {
            return .panel
        }

        switch state {
        case .idle:
            // Show the meeting recording strip when a meeting is being recorded
            // but the primary dictation state is idle.
            if isMeetingRecording {
                return .minimal
            }
            return .compact
        case .done:
            return isLocalModelReadyDone ? .minimal : .compact
        case .notice, .error, .recording, .processing, .hotMic, .command:
            return overlayMode == .panel ? .panel : .minimal
        }
    }

    func isOpen(for overlayMode: OverlayMode) -> Bool {
        presentationStyle(for: overlayMode) != .compact
    }

    func preferredSize(for overlayMode: OverlayMode) -> CGSize {
        CGSize(
            width: preferredWidth(for: overlayMode),
            height: preferredHeight(for: overlayMode)
        )
    }

    // MARK: - Private

    private func applyPresentationRequest(_ request: NotchPresentationRequest) {
        switch presentationStateMachine.apply(request, current: state) {
        case .display(let request):
            deferredPresentationTask?.cancel()
            deferredPresentationTask = nil
            display(request)
        case .deferUntil(let date):
            scheduleDeferredPresentation(until: date)
        }
    }

    private func display(_ request: NotchPresentationRequest) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        commitState(request.state)

        if let autoDismiss = request.autoDismiss {
            scheduleAutoDismiss(autoDismiss, expectedState: request.state)
        }
    }

    private func commitState(_ newState: NotchOverlayState) {
        let oldState = state
        state = newState
        onStateChanged(old: oldState, new: newState)
    }

    private func scheduleAutoDismiss(_ autoDismiss: NotchAutoDismiss, expectedState: NotchOverlayState) {
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: autoDismiss.timeout)
            guard let self, !Task.isCancelled, self.state == expectedState else { return }
            self.setState(autoDismiss.fallback)
        }
    }

    private func scheduleDeferredPresentation(until date: Date) {
        deferredPresentationTask?.cancel()
        deferredPresentationTask = Task { @MainActor [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self,
                  !Task.isCancelled,
                  let request = self.presentationStateMachine.releaseDeferredRequestIfReady(current: self.state)
            else { return }
            self.display(request)
        }
    }

    private func preferredWidth(for overlayMode: OverlayMode) -> CGFloat {
        let closedSize = currentClosedNotchSize()

        if showsHome {
            return NotchSizes.idleOpenWidth
        }

        if expressionVisible && state == .idle {
            return NotchSizes.idleOpenWidth
        }

        switch presentationStyle(for: overlayMode) {
        case .compact:
            return closedSize.width
        case .minimal:
            if isLocalModelReadyDone {
                return NotchSizes.minimalStripWidth(for: closedSize)
            }
            if hasBelowNotchTextRow {
                return max(NotchSizes.minimalStripWidth(for: closedSize), 460)
            }
            if case .error = state {
                return max(NotchSizes.minimalStripWidth(for: closedSize), 460)
            }
            if case .notice = state {
                return max(NotchSizes.minimalStripWidth(for: closedSize), 460)
            }
            return NotchSizes.minimalStripWidth(for: closedSize)
        case .panel:
            return NotchSizes.openWidth
        }
    }

    private func preferredHeight(for overlayMode: OverlayMode) -> CGFloat {
        let closedSize = currentClosedNotchSize()

        if showsHome {
            return NotchSizes.idleOpenHeight
        }

        if expressionVisible && state == .idle {
            return NotchSizes.idleOpenHeight
        }

        switch presentationStyle(for: overlayMode) {
        case .compact:
            // Shave a few points so the overlay tucks fully behind the
            // hardware notch and doesn't peek below it.
            return closedSize.height - 4
        case .minimal:
            if hasBelowNotchTextRow {
                return closedSize.height + NotchSizes.minimalTextRowHeight
            }
            if case .error = state {
                return closedSize.height + 70
            }
            if case .notice = state {
                return closedSize.height + 70
            }
            return closedSize.height + 1
        case .panel:
            return NotchSizes.openHeight
        }
    }

    private var hasBelowNotchTextRow: Bool {
        if isMeetingRecording && isCompactState {
            return true
        }
        if isLocalModelReadyDone {
            return true
        }
        switch state {
        case .command:
            return true
        case .hotMic(_, let liveText):
            return liveText.trimmedNilIfEmpty != nil
        case .recording(let mode, _, _):
            return mode != .memo && recordingLiveText?.trimmedNilIfEmpty != nil
        default:
            return false
        }
    }

    var isLocalModelReadyDone: Bool {
        guard case .done(let text) = state else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Local model ready") == .orderedSame
    }

    private func onStateChanged(old: NotchOverlayState, new: NotchOverlayState) {
        if case .recording = new {
            // Preserve lock state until the recording session explicitly ends.
        } else {
            recordingLocked = false
            recordingHint = nil
            recordingLiveText = nil
        }

        if case .idle = new {
            clearTargetContext()
        }

        announceIfNeeded(old: old, new: new)
    }

    /// VoiceOver has no other signal for these transitions — the notch is purely
    /// visual and the audio cues are undifferentiated tones. Only announce when the
    /// spoken text actually changes, so the ~20 Hz `.recording` level updates and
    /// processing progress ticks stay silent.
    private func announceIfNeeded(old: NotchOverlayState, new: NotchOverlayState) {
        guard let message = Self.announcement(for: new),
              message != Self.announcement(for: old) else { return }

        if case .error = new {
            voiceOverAnnouncer.announce(message, priority: .high)
        } else {
            voiceOverAnnouncer.announce(message)
        }
    }

    /// Short spoken form of a state, or nil when there is nothing worth saying.
    static func announcement(for state: NotchOverlayState) -> String? {
        switch state {
        case .recording(let mode, _, _):
            return mode == .memo ? "Recording memo" : "Recording"
        case .processing:
            return "Transcribing"
        case .done(let text):
            return text.trimmedNilIfEmpty
        case .error(let message, _):
            return message.trimmedNilIfEmpty
        case .idle, .notice, .hotMic, .command:
            return nil
        }
    }

    func showHotMicDone(_ text: String) {
        showDone(text, timeout: .seconds(1.5), fallback: .hotMic(level: 0, liveText: ""))
    }
}

extension NotchOverlayState.CommandStage {
    var isListening: Bool {
        if case .listening = self { return true }
        if case .awaitingFollowUp = self { return true }
        return false
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
