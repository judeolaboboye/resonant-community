import Foundation

/// Pure lifecycle state for a meeting session.
///
/// `MeetingRecorderManager` still owns the concrete audio, transcription, and
/// persistence adapters. This value owns the ordering-sensitive flags and
/// active-session metadata those adapters operate around.
struct MeetingSessionLifecycle {
    private(set) var isRecording = false
    private(set) var isFinalizing = false
    private(set) var isStartingSession = false
    private(set) var activeSession: MeetingSessionInfo?
    private(set) var recordingStartedAt: Date?

    var canStartSession: Bool {
        !isRecording && !isFinalizing && !isStartingSession
    }

    var canImportAudio: Bool {
        !isRecording && !isFinalizing && !isStartingSession
    }

    @discardableResult
    mutating func beginStartingSession() -> Bool {
        guard canStartSession else { return false }
        isStartingSession = true
        return true
    }

    mutating func finishStartingSession() {
        isStartingSession = false
    }

    mutating func markRecordingStarted(_ session: MeetingSessionInfo) {
        activeSession = session
        recordingStartedAt = session.startedAt
        isRecording = true
    }

    mutating func markStartFailed() {
        isRecording = false
        activeSession = nil
        recordingStartedAt = nil
    }

    @discardableResult
    mutating func beginEndingSession() -> MeetingSessionInfo? {
        guard let session = activeSession else {
            clearInconsistentSession()
            return nil
        }
        isRecording = false
        isFinalizing = true
        return session
    }

    mutating func detachFinalizedSession() {
        activeSession = nil
        recordingStartedAt = nil
    }

    mutating func finishFinalizingSession() {
        isFinalizing = false
    }

    @discardableResult
    mutating func beginDiscardingSession() -> MeetingSessionInfo? {
        guard isRecording, let session = activeSession else { return nil }
        isRecording = false
        isFinalizing = false
        return session
    }

    mutating func finishDiscardingSession() {
        resetToIdle()
    }

    @discardableResult
    mutating func beginImport() -> Bool {
        guard canImportAudio else { return false }
        isFinalizing = true
        return true
    }

    mutating func finishImport() {
        isFinalizing = false
    }

    mutating func rebindActiveSession(
        to captureContext: MeetingCaptureContext,
        suggestedTitle: String?
    ) -> MeetingSessionInfo? {
        guard var session = activeSession else { return nil }
        session.captureContext = captureContext
        let trimmedSuggestedTitle = suggestedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSuggestedTitle: String?
        if let trimmedSuggestedTitle, !trimmedSuggestedTitle.isEmpty {
            normalizedSuggestedTitle = trimmedSuggestedTitle
        } else {
            normalizedSuggestedTitle = nil
        }
        session.suggestedTitle = normalizedSuggestedTitle
            ?? captureContext.effectiveTitle
            ?? session.suggestedTitle
        activeSession = session
        return session
    }

    mutating func clearInconsistentSession() {
        isRecording = false
        isFinalizing = false
        activeSession = nil
        recordingStartedAt = nil
    }

    private mutating func resetToIdle() {
        isRecording = false
        isFinalizing = false
        isStartingSession = false
        activeSession = nil
        recordingStartedAt = nil
    }
}
