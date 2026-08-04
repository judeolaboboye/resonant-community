import Foundation
import Observation

enum MeetingStartOrigin: String, Sendable, Equatable {
    case automatic
    case prompt
    case menuBar
    case notch
    case app
    case meetingsTab
    case calendar
    case quickStart
    case importedAudio
    case notesOnly
    case rebound

    var displayLabel: String {
        switch self {
        case .automatic:
            return "Auto-detected"
        case .prompt:
            return "Started from prompt"
        case .menuBar:
            return "Started from menu bar"
        case .notch:
            return "Started from notch"
        case .app:
            return "Started from app"
        case .meetingsTab:
            return "Started from Meetings"
        case .calendar:
            return "Started from calendar"
        case .quickStart:
            return "Quick start"
        case .importedAudio:
            return "Imported audio"
        case .notesOnly:
            return "Notes only"
        case .rebound:
            return "Rebound to calendar"
        }
    }

    init(recordingOrigin: MeetingRecordingOrigin, isCalendarBacked: Bool) {
        switch recordingOrigin {
        case .automatic:
            self = .automatic
        case .promptAccepted:
            self = .prompt
        case .manual:
            self = isCalendarBacked ? .calendar : .app
        case .importedAudio:
            self = .importedAudio
        case .manualNotes:
            self = .notesOnly
        case .rebound:
            self = .rebound
        }
    }
}

@MainActor
@Observable
final class MeetingCompanionState {
    enum Phase: String, Sendable, Equatable {
        case hidden
        case detecting
        case starting
        case recording
        case processing
        case error
        case saved
    }

    var phase: Phase = .hidden
    var isExpanded = false
    var origin: MeetingStartOrigin = .app
    var title: String?
    var subtitle: String?
    var detectedAppName: String?
    var startedAt: Date?
    var statusDetail: String?
    var audioHealthMessage: String?
    var errorMessage: String?
    var lastSavedWordCount: Int?

    var isVisible: Bool {
        phase != .hidden
    }

    func showDetected(_ meeting: MeetingContextDetector.DetectedMeeting) {
        phase = .detecting
        isExpanded = false
        origin = .automatic
        title = meeting.calendarHint?.title ?? meeting.app.name
        subtitle = detectionEvidence(for: meeting)
        detectedAppName = meeting.app.name
        startedAt = nil
        statusDetail = "Possible meeting detected"
        audioHealthMessage = nil
        errorMessage = nil
        lastSavedWordCount = nil
    }

    func beginStarting(
        origin: MeetingStartOrigin,
        title: String?,
        detectedAppName: String?,
        subtitle: String?
    ) {
        phase = .starting
        isExpanded = true
        self.origin = origin
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.detectedAppName = detectedAppName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        startedAt = Date()
        statusDetail = "Preparing local transcription"
        audioHealthMessage = nil
        errorMessage = nil
        lastSavedWordCount = nil
    }

    func markRecording(session: MeetingSessionInfo) {
        phase = .recording
        isExpanded = true
        title = session.suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? session.captureContext?.effectiveTitle
            ?? session.detectedApp.map { "Meeting - \($0.name)" }
            ?? title
        subtitle = origin.displayLabel
        detectedAppName = session.detectedApp?.name ?? detectedAppName
        startedAt = session.startedAt
        statusDetail = "Recording locally"
        errorMessage = nil
    }

    func markProcessing(title: String?) {
        phase = .processing
        isExpanded = true
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            self.title = title
        }
        statusDetail = "Wrapping up meeting"
        audioHealthMessage = nil
        errorMessage = nil
    }

    func markSaved(wordCount: Int) {
        phase = .saved
        isExpanded = false
        statusDetail = "Meeting saved"
        lastSavedWordCount = wordCount
        audioHealthMessage = nil
        errorMessage = nil
    }

    func markError(_ message: String) {
        phase = .error
        isExpanded = true
        statusDetail = "Meeting could not start"
        errorMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Something went wrong."
        audioHealthMessage = nil
    }

    func updateAudioHealth(_ message: String?) {
        audioHealthMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func hide() {
        phase = .hidden
        isExpanded = false
        statusDetail = nil
        audioHealthMessage = nil
        errorMessage = nil
        lastSavedWordCount = nil
    }

    private func detectionEvidence(for meeting: MeetingContextDetector.DetectedMeeting) -> String {
        var parts: [String] = []
        if meeting.calendarHint != nil {
            parts.append("calendar match")
        }
        if meeting.browserURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            parts.append("meeting link")
        }
        if meeting.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            parts.append("active window")
        }
        if parts.isEmpty {
            parts.append(meeting.app.name)
        }
        return parts.joined(separator: " - ")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
