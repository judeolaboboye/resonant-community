import Foundation

/// Converts a completed meeting session into a markdown string with YAML frontmatter.
/// Stateless — all methods are static.
enum MeetingMarkdownExporter {

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func markdown(
        for session: CompletedMeetingSession,
        title: String? = nil,
        summary: String? = nil,
        speakerAliases: MeetingSpeakerAliasMap = [:]
    ) -> String {
        let resolvedSpeakerAliases = speakerAliases.isEmpty ? session.speakerAliases : speakerAliases
        var md = frontmatter(for: session, title: title, speakerAliases: resolvedSpeakerAliases)
        md += heading(for: session, title: title)

        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            md += "## Summary\n\n"
            md += summary
            md += "\n\n"
        }

        md += transcript(for: session, speakerAliases: resolvedSpeakerAliases)

        if !session.liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += "\n## Notes\n\n"
            md += session.liveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            md += "\n"
        }

        if !session.postMeetingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += "\n## Post-Meeting Notes\n\n"
            md += session.postMeetingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            md += "\n"
        }

        return md
    }

    static func extractTranscript(from markdown: String) -> String? {
        let content = stripFrontmatter(from: markdown)
        let transcript = extractSectionBody(heading: "Transcript", from: content)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let transcript, !transcript.isEmpty else { return nil }
        return transcript
    }

    // MARK: - Private

    static func effectiveTitle(
        appName: String?,
        customTitle: String?,
        recordingOrigin: MeetingRecordingOrigin? = nil
    ) -> String {
        if let customTitle = normalizedTitle(customTitle) {
            return customTitle
        }
        return fallbackMeetingTitle(detectedApp: appName, recordingOrigin: recordingOrigin)
    }

    static func headingTitle(startedAt: Date, customTitle: String?) -> String {
        if let customTitle = normalizedTitle(customTitle) {
            return customTitle
        }
        let time = timeFormatter.string(from: startedAt)
        let date = dateFormatter.string(from: startedAt)
        return "Meeting \u{2014} \(date) \(time)"
    }

    private static func frontmatter(
        for session: CompletedMeetingSession,
        title: String?,
        speakerAliases: MeetingSpeakerAliasMap
    ) -> String {
        let speakers = Array(Set(session.utterances.map { $0.speaker.resolvedDisplayLabel(using: speakerAliases) })).sorted()
        let speakersYAML = "[" + speakers.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        let attendeeNames = session.captureContext?.attendeeNames ?? []
        let attendeesYAML = "[" + attendeeNames.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ") + "]"
        let effectiveMeetingTitle = effectiveTitle(
            appName: session.detectedApp?.name,
            customTitle: title,
            recordingOrigin: session.captureContext?.recordingOrigin
        )

        var yaml = "---\n"
        yaml += "type: meeting\n"
        yaml += "id: \(session.id.uuidString)\n"
        yaml += "title: \(yamlQuote(effectiveMeetingTitle))\n"
        yaml += "date: \(iso8601Formatter.string(from: session.startedAt))\n"
        yaml += "duration_seconds: \(Int(session.durationSeconds))\n"
        yaml += "word_count: \(session.wordCount)\n"
        if let app = session.detectedApp {
            yaml += "app: \(yamlQuote(app.name))\n"
        }
        if let captureContext = session.captureContext {
            if let calendarEventID = captureContext.calendarEventID {
                yaml += "calendar_event_id: \(yamlQuote(calendarEventID))\n"
            }
            if let scheduledStartAt = captureContext.scheduledStartAt {
                yaml += "scheduled_start: \(iso8601Formatter.string(from: scheduledStartAt))\n"
            }
            if let scheduledEndAt = captureContext.scheduledEndAt {
                yaml += "scheduled_end: \(iso8601Formatter.string(from: scheduledEndAt))\n"
            }
            if let organizerName = captureContext.organizerName {
                yaml += "organizer: \(yamlQuote(organizerName))\n"
            }
            if !captureContext.attendeeNames.isEmpty {
                yaml += "attendees: \(attendeesYAML)\n"
            }
            if let conferencingURL = captureContext.conferencingURL {
                yaml += "conferencing_url: \(yamlQuote(conferencingURL))\n"
            }
            if let calendarName = captureContext.calendarName {
                yaml += "calendar_name: \(yamlQuote(calendarName))\n"
            }
            yaml += "recording_origin: \(yamlQuote(captureContext.recordingOrigin.rawValue))\n"
        }
        yaml += "speakers: \(speakersYAML)\n"
        yaml += "---\n\n"
        return yaml
    }

    private static func heading(for session: CompletedMeetingSession, title: String?) -> String {
        let duration = formatDuration(session.durationSeconds)
        let words = formatNumber(session.wordCount)
        let app = session.detectedApp?.name
        let organizerName = session.captureContext?.organizerName

        var line = "# \(headingTitle(startedAt: session.startedAt, customTitle: title))\n\n"
        line += "**Duration:** \(duration)"
        line += " \u{00B7} **Words:** \(words)"
        if let app {
            line += " \u{00B7} **App:** \(app)"
        }
        if let organizerName, !organizerName.isEmpty {
            line += " \u{00B7} **Organizer:** \(organizerName)"
        }
        line += "\n\n"
        return line
    }

    private static func transcript(
        for session: CompletedMeetingSession,
        speakerAliases: MeetingSpeakerAliasMap
    ) -> String {
        guard !session.utterances.isEmpty else {
            return "## Transcript\n\n*No speech detected.*\n"
        }

        var md = "## Transcript\n\n"
        let sessionStart = session.startedAt

        for utterance in session.utterances {
            let offset = utterance.timestamp.timeIntervalSince(sessionStart)
            let timestamp = formatTimestamp(offset)
            let speakerLabel = utterance.speaker.resolvedDisplayLabel(using: speakerAliases)
            md += "**\(speakerLabel)** (\(timestamp)) <!-- speaker:\(utterance.speaker.storageKey) -->\n"
            md += utterance.text + "\n\n"
        }

        return md
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return s == 0 ? "\(h)h \(m)m" : "\(h)h \(m)m \(s)s"
        }
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static func formatNumber(_ n: Int) -> String {
        numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func yamlQuote(_ value: String) -> String {
        if value.contains(":") || value.contains("\"") || value.contains("#")
            || value.hasPrefix(" ") || value.hasSuffix(" ") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func stripFrontmatter(from markdown: String) -> String {
        guard markdown.hasPrefix("---\n"),
              let closingRange = markdown.range(of: "\n---\n") else {
            return markdown
        }
        return String(markdown[closingRange.upperBound...])
    }

    private static func extractSectionBody(heading: String, from markdown: String) -> String? {
        let marker = "## \(heading)\n"
        guard let markerRange = markdown.range(of: marker) else { return nil }
        let sectionStart = markerRange.upperBound
        let remaining = markdown[sectionStart...]
        let sectionEnd = remaining.range(of: "\n## ")?.lowerBound ?? markdown.endIndex
        return String(markdown[sectionStart..<sectionEnd])
    }
}
