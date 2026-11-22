import Foundation

/// Fixed keyCode 58 (left Option) for v1 — not user-remappable, to keep the
/// collision surface with the primary dictation trigger small. `HotkeyManager`
/// disables this trigger entirely if the user has separately bound left Option
/// as a custom dictation trigger (see `ScreenAwarenessManager.isHotkeyAvailable`).
enum ScreenAwarenessTrigger {
    static let keyCode: UInt16 = 58
    static let displayName = "Left Option"
}

enum ScreenAwarenessState: Equatable {
    case idle
    case capturingScreenshot
    case recording(startedAt: Date)
    case transcribing
    case queryingClaude
    case presentingAnswer(String)
    case failed(ScreenAwarenessError)
}

enum ScreenAwarenessError: Error, Equatable {
    case screenRecordingPermissionDenied
    case screenshotCaptureFailed
    case captureBusyWithDictation
    case emptyTranscript
    case claudeCLINotFound
    case claudeCLIFailed(exitCode: Int32, stderrTail: String)
    case claudeCLITimedOut
    case approvalDenied
    case approvalUnavailable

    var userFacingMessage: String {
        switch self {
        case .screenRecordingPermissionDenied:
            "Screen Recording permission is needed. Grant it in System Settings → Privacy & Security → Screen Recording."
        case .screenshotCaptureFailed:
            "Couldn't capture the screen. Try again."
        case .captureBusyWithDictation:
            "Dictation is already recording — try again once it's finished."
        case .emptyTranscript:
            "Didn't catch a question — try holding the key a little longer."
        case .claudeCLINotFound:
            "Claude Code CLI wasn't found. Make sure `claude` is installed and on your PATH."
        case .claudeCLIFailed:
            "Claude Code couldn't answer that. Try again."
        case .claudeCLITimedOut:
            "Claude Code took too long to respond."
        case .approvalDenied:
            "Cancelled — not approved."
        case .approvalUnavailable:
            "No Touch ID or password auth available on this Mac to confirm this request."
        }
    }
}
