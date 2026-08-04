import Foundation
import SwiftUI

// MARK: - Speaker Attribution

/// Identifies which side of the conversation produced an utterance.
enum MeetingSpeaker: Codable, Sendable, Hashable {
    case you
    case them
    case participant(id: String)

    var displayLabel: String {
        legacyDisplayLabel
    }

    var legacyDisplayLabel: String {
        switch self {
        case .you: return "You"
        case .them: return "Them"
        case .participant(let id):
            // DiarizerManager emits IDs like "SPEAKER_0", "SPEAKER_1" — show friendly labels
            if let index = Self.participantIndex(for: id) {
                return "Speaker \(index + 1)"
            }
            return "Speaker"
        }
    }

    func resolvedDisplayLabel(using aliases: MeetingSpeakerAliasMap) -> String {
        let normalizedAliases = MeetingSpeakerAliasResolver.normalized(aliases)
        if let alias = normalizedAliases[storageKey] {
            return alias
        }
        return legacyDisplayLabel
    }

    var color: Color {
        switch self {
        case .you:  Color(red: 0.35, green: 0.55, blue: 0.75)   // muted blue
        case .them: Color(red: 0.82, green: 0.6, blue: 0.3)     // warm amber
        case .participant(let id):
            Self.participantColors[abs(id.hashValue) % Self.participantColors.count]
        }
    }

    private static let participantColors: [Color] = [
        Color(red: 0.82, green: 0.6, blue: 0.3),    // amber
        Color(red: 0.4, green: 0.7, blue: 0.5),      // green
        Color(red: 0.7, green: 0.45, blue: 0.55),     // rose
        Color(red: 0.5, green: 0.6, blue: 0.75),      // slate blue
    ]

    /// Stable key for JSONL persistence.
    var storageKey: String {
        switch self {
        case .you: "you"
        case .them: "them"
        case .participant(let id): "participant:\(id)"
        }
    }

    var isFixedChannelSpeaker: Bool {
        switch self {
        case .you, .them:
            true
        case .participant:
            false
        }
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "you": self = .you
        case "them": self = .them
        default:
            if raw.hasPrefix("participant:") {
                self = .participant(id: String(raw.dropFirst("participant:".count)))
            } else {
                self = .them
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }

    init?(storageKey: String) {
        let trimmed = storageKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed {
        case "you":
            self = .you
        case "them":
            self = .them
        default:
            guard trimmed.hasPrefix("participant:") else { return nil }
            self = .participant(id: String(trimmed.dropFirst("participant:".count)))
        }
    }

    static func legacySpeaker(forTranscriptLabel label: String) -> MeetingSpeaker? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "you":
            return .you
        case "them":
            return .them
        default:
            guard trimmed.lowercased().hasPrefix("speaker ") else { return nil }
            let suffix = trimmed.dropFirst("Speaker ".count)
            guard let index = Int(suffix), index > 0 else { return nil }
            return .participant(id: "SPEAKER_\(index - 1)")
        }
    }

    static func participantIndex(for id: String) -> Int? {
        id.split(separator: "_").last.flatMap { Int($0) }
    }
}

// MARK: - Utterance

/// A single transcribed speech segment with speaker attribution and timestamp.
struct MeetingUtterance: Identifiable, Codable, Sendable {
    let id: UUID
    let text: String
    let speaker: MeetingSpeaker
    let timestamp: Date

    init(text: String, speaker: MeetingSpeaker, timestamp: Date = .now) {
        self.id = UUID()
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
    }
}

// MARK: - JSONL Record

/// Codable record for append-only JSONL session persistence.
/// Minimal — just what's needed to reconstruct the transcript.
struct MeetingSessionRecord: Codable, Sendable {
    let speaker: MeetingSpeaker
    let text: String
    let timestamp: Date
}

// MARK: - Meeting App

/// A meeting app identifier, preserved for crash recovery and display.
struct MeetingApp: Sendable, Hashable, Codable {
    let bundleID: String
    let name: String
}

enum MeetingRecordingOrigin: String, Codable, Sendable {
    case automatic = "automatic"
    case manual = "manual"
    case promptAccepted = "promptAccepted"
    case importedAudio = "importedAudio"
    case manualNotes = "manualNotes"
    case rebound = "rebound"

    var detailDisplayLabel: String {
        switch self {
        case .automatic:
            return "Auto-recorded"
        case .manual:
            return "Started manually"
        case .promptAccepted:
            return "Started from prompt"
        case .importedAudio:
            return "Imported audio"
        case .manualNotes:
            return "Notes only"
        case .rebound:
            return "Rebound to calendar event"
        }
    }

    var untitledMeetingLabel: String {
        switch self {
        case .manual:
            return "Ad-hoc meeting"
        case .importedAudio:
            return "Imported meeting"
        case .manualNotes:
            return "Notes-only meeting"
        case .automatic, .promptAccepted, .rebound:
            return "Meeting"
        }
    }
}

enum MeetingCaptureMode: String, Sendable, Equatable {
    case onlineCall
    case room
    case importedAudio

    var usesRoomMicrophoneDiarization: Bool {
        self == .room
    }

    var displayLabel: String {
        switch self {
        case .onlineCall:
            return "Online call"
        case .room:
            return "Room mode"
        case .importedAudio:
            return "Imported audio"
        }
    }

    static func resolve(
        detectedApp: MeetingApp?,
        captureContext: MeetingCaptureContext?
    ) -> MeetingCaptureMode {
        if captureContext?.recordingOrigin == .importedAudio {
            return .importedAudio
        }

        let hasRealDetectedMeetingApp = detectedApp.map {
            $0.bundleID.caseInsensitiveCompare(MeetingContextDetector.calendarOnlyBundleID) != .orderedSame
        } ?? false

        if hasRealDetectedMeetingApp || captureContext?.hasConferencingURL == true {
            return .onlineCall
        }

        guard let captureContext else {
            return .room
        }

        switch captureContext.recordingOrigin {
        case .manual, .manualNotes, .promptAccepted:
            return .room
        case .automatic, .rebound:
            return .onlineCall
        case .importedAudio:
            return .importedAudio
        }
    }
}

func fallbackMeetingTitle(detectedApp: String?, recordingOrigin: MeetingRecordingOrigin?) -> String {
    if let detectedApp = detectedApp?.trimmingCharacters(in: .whitespacesAndNewlines),
       !detectedApp.isEmpty {
        return "Meeting \u{00B7} \(detectedApp)"
    }
    return recordingOrigin?.untitledMeetingLabel ?? "Meeting"
}

struct MeetingCaptureContext: Sendable, Codable, Equatable {
    let calendarEventID: String?
    let scheduledStartAt: Date?
    let scheduledEndAt: Date?
    let organizerName: String?
    let attendeeNames: [String]
    let attendeeEmails: [String]
    let conferencingURL: String?
    let calendarName: String?
    let title: String?
    let recordingOrigin: MeetingRecordingOrigin

    var isCalendarBacked: Bool {
        calendarEventID != nil
    }

    var effectiveTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasConferencingURL: Bool {
        conferencingURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func adHoc(
        title: String? = nil,
        recordingOrigin: MeetingRecordingOrigin
    ) -> MeetingCaptureContext {
        MeetingCaptureContext(
            calendarEventID: nil,
            scheduledStartAt: nil,
            scheduledEndAt: nil,
            organizerName: nil,
            attendeeNames: [],
            attendeeEmails: [],
            conferencingURL: nil,
            calendarName: nil,
            title: title,
            recordingOrigin: recordingOrigin
        )
    }
}

// MARK: - Session Info

/// Metadata for an active meeting session.
struct MeetingSessionInfo: Sendable {
    let id: UUID
    let startedAt: Date
    let detectedApp: MeetingApp?
    var suggestedTitle: String?
    var captureContext: MeetingCaptureContext?
    let captureMode: MeetingCaptureMode
    let transcriptionBackendAtStart: String
    let jsonlRelativePath: String
    let jsonlURL: URL
}

/// Completed session with all data needed for markdown export.
struct CompletedMeetingSession: Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let detectedApp: MeetingApp?
    let suggestedTitle: String?
    let captureContext: MeetingCaptureContext?
    let speakerAliases: MeetingSpeakerAliasMap
    let utterances: [MeetingUtterance]
    let liveNotes: String
    let postMeetingNotes: String
    let recordingURL: URL?
    let shouldDeleteRecordingAfterSave: Bool

    var durationSeconds: Double {
        endedAt.timeIntervalSince(startedAt)
    }

    var wordCount: Int {
        utterances.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    var transcriptText: String {
        utterances
            .map { "\($0.speaker.resolvedDisplayLabel(using: speakerAliases)): \($0.text)" }
            .joined(separator: "\n")
    }
}
