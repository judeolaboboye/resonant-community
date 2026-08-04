import Foundation

struct NotchAutoDismiss {
    let timeout: Duration
    let fallback: NotchOverlayState
}

struct NotchPresentationRequest {
    let state: NotchOverlayState
    let autoDismiss: NotchAutoDismiss?

    init(state: NotchOverlayState, autoDismiss: NotchAutoDismiss? = nil) {
        self.state = state
        self.autoDismiss = autoDismiss
    }
}

enum NotchPresentationDecision {
    case display(NotchPresentationRequest)
    case deferUntil(Date)
}

enum NotchErrorPresentationPolicy {
    static let minimumVisibleSeconds: TimeInterval = 1.6

    static func autoDismissDuration(for subtype: NotchOverlayState.ErrorSubtype) -> Duration {
        switch subtype {
        case .paste:
            .seconds(6)
        case .transcription, .microphone:
            .seconds(7)
        case .model:
            .seconds(4)
        case .generic:
            .seconds(3)
        case .meetingSystemAudio:
            .seconds(15)
        }
    }
}

struct NotchPresentationStateMachine {
    private var visibleErrorStartedAt: Date?
    private var deferredRequestAfterError: NotchPresentationRequest?
    private let minimumErrorVisibleSeconds: TimeInterval

    init(minimumErrorVisibleSeconds: TimeInterval = NotchErrorPresentationPolicy.minimumVisibleSeconds) {
        self.minimumErrorVisibleSeconds = minimumErrorVisibleSeconds
    }

    mutating func apply(
        _ request: NotchPresentationRequest,
        current currentState: NotchOverlayState,
        now: Date = Date()
    ) -> NotchPresentationDecision {
        if case .error = request.state {
            visibleErrorStartedAt = now
            deferredRequestAfterError = nil
            return .display(request)
        }

        guard case .error = currentState,
              let visibleErrorStartedAt
        else {
            clearErrorHold()
            return .display(request)
        }

        if request.state.interruptsVisibleError {
            clearErrorHold()
            return .display(request)
        }

        let visibleSeconds = now.timeIntervalSince(visibleErrorStartedAt)
        guard visibleSeconds < minimumErrorVisibleSeconds else {
            clearErrorHold()
            return .display(request)
        }

        deferredRequestAfterError = request
        return .deferUntil(visibleErrorStartedAt.addingTimeInterval(minimumErrorVisibleSeconds))
    }

    mutating func releaseDeferredRequestIfReady(
        current currentState: NotchOverlayState,
        now: Date = Date()
    ) -> NotchPresentationRequest? {
        guard case .error = currentState,
              let visibleErrorStartedAt,
              now.timeIntervalSince(visibleErrorStartedAt) >= minimumErrorVisibleSeconds
        else {
            if case .error = currentState {
                return nil
            }
            clearErrorHold()
            return nil
        }

        let request = deferredRequestAfterError
        clearErrorHold()
        return request
    }

    private mutating func clearErrorHold() {
        visibleErrorStartedAt = nil
        deferredRequestAfterError = nil
    }
}

private extension NotchOverlayState {
    var interruptsVisibleError: Bool {
        switch self {
        case .recording:
            return true
        case .idle, .processing, .done, .notice, .error, .hotMic, .command:
            return false
        }
    }
}
