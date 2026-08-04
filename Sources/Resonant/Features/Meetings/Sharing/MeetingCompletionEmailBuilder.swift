import Foundation

struct MeetingCompletionEmailPayload: Equatable, Sendable {
    let meetingId: String
    let meetingTitle: String
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Double
    let detectedApp: String?
    let conferencingURL: String?
    let markdownPath: String?
    let transcript: String
}

enum MeetingCompletionEmailBuilder {
    static func payload(
        for session: CompletedMeetingSession,
        entry: MeetingEntry
    ) -> MeetingCompletionEmailPayload? {
        guard let transcript = session.transcriptText.trimmedNilIfEmpty else {
            return nil
        }

        return MeetingCompletionEmailPayload(
            meetingId: session.id.uuidString,
            meetingTitle: entry.displayTitle,
            startedAt: entry.startedAt,
            endedAt: entry.endedAt ?? session.endedAt,
            durationSeconds: max(entry.durationSeconds, session.durationSeconds),
            detectedApp: entry.detectedApp?.trimmedNilIfEmpty ?? session.detectedApp?.name.trimmedNilIfEmpty,
            conferencingURL: entry.conferencingURL?.trimmedNilIfEmpty ?? session.captureContext?.conferencingURL?.trimmedNilIfEmpty,
            markdownPath: entry.markdownPath?.trimmedNilIfEmpty,
            transcript: transcript
        )
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
