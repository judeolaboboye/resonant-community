import Foundation

enum MeetingRecapShareBuilder {
    static let teamContactEmail = "team@onresonant.com"

    static func publicDisclosureText(
        expirationDays: Int = MeetingRecapSharePolicy.defaultExpirationDays
    ) -> String {
        let days = MeetingRecapSharePolicy.normalizedExpirationDays(expirationDays)
        return "This publishes the recap as an unlisted public web page for \(days) days. Anyone with the link can view it. For more privacy, share copied notes directly instead."
    }

    static func emailShareURL(
        meetingTitle: String,
        shareURL: URL,
        expirationDays: Int = MeetingRecapSharePolicy.defaultExpirationDays
    ) -> URL? {
        let days = MeetingRecapSharePolicy.normalizedExpirationDays(expirationDays)
        var components = URLComponents()
        components.scheme = "mailto"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "\(meetingTitle) recap"),
            URLQueryItem(
                name: "body",
                value: "Here's the meeting recap:\n\n\(shareURL.absoluteString)\n\nThis public web link expires in \(days) days."
            )
        ]
        return components.url
    }

    static func privateLinkRequestURL(meetingTitle: String) -> URL? {
        supportMailURL(
            subject: "Private recap links",
            body: """
            Hi Resonant team,

            I would like recipient-verified private recap links for meetings like "\(meetingTitle)".

            """
        )
    }

    static func workspaceSharingContactURL(meetingTitle: String) -> URL? {
        supportMailURL(
            subject: "Workspace-only recap sharing",
            body: """
            Hi Resonant team,

            I am interested in workspace-only recap sharing for our company. Example meeting: "\(meetingTitle)".

            """
        )
    }

    static func localRecapText(for meeting: MeetingEntry) -> String? {
        guard let payload = payload(for: meeting) else { return nil }
        return localRecapText(from: payload)
    }

    static func localRecapText(from payload: MeetingRecapPayload) -> String {
        var sections: [String] = ["# \(payload.meetingTitle)"]

        sections.append("## Summary\n\(payload.summary)")

        if !payload.decisions.isEmpty {
            sections.append("## Decisions\n" + payload.decisions.map { "- \($0.text)" }.joined(separator: "\n"))
        }

        if !payload.actionItems.isEmpty {
            sections.append("## Action items\n" + payload.actionItems.map { "- \(actionItemLine($0))" }.joined(separator: "\n"))
        }

        if !payload.attendees.isEmpty {
            sections.append("## Attendees\n" + payload.attendees.map { "- \($0)" }.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    static func payload(for meeting: MeetingEntry) -> MeetingRecapPayload? {
        guard let summarySource = shareSource(for: meeting),
              let summary = summaryBody(from: summarySource)
        else {
            return nil
        }

        let sourceText = [
            meeting.distilledSummary,
            meeting.summary,
            meeting.postMeetingNotes,
            meeting.userNotes
        ]
            .compactMap { $0?.trimmedNilIfEmpty }
            .joined(separator: "\n\n")

        return MeetingRecapPayload(
            meetingTitle: meeting.displayTitle,
            meetingStartedAt: meeting.startedAt,
            summary: summary,
            decisions: decisions(from: sourceText),
            actionItems: actionItems(from: sourceText),
            attendees: attendees(from: meeting),
            transcriptExcerpt: nil
        )
    }

    static func shareSummary(for meeting: MeetingEntry) -> String? {
        guard let source = shareSource(for: meeting) else { return nil }
        return summaryBody(from: source)
    }

    private static func shareSource(for meeting: MeetingEntry) -> String? {
        [
            meeting.distilledSummary,
            meeting.summary,
            meeting.postMeetingNotes,
            meeting.userNotes
        ]
            .compactMap { $0?.trimmedNilIfEmpty }
            .first
    }

    private static func summaryBody(from text: String) -> String? {
        guard let trimmedText = text.trimmedNilIfEmpty else { return nil }

        var preambleLines: [String] = []
        var summaryLines: [String] = []
        var isCapturingSummary = false
        var sawStructuredHeading = false

        for rawLine in trimmedText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if isHeading(line) {
                let heading = normalizedHeading(line)
                let isSummaryHeading = heading.contains("summary")
                let isStructuredHeading = isSummaryHeading
                    || heading.contains("decision")
                    || heading.contains("action")
                    || heading.contains("next step")
                    || heading.contains("follow")
                    || heading.contains("todo")
                    || heading.contains("open question")

                sawStructuredHeading = sawStructuredHeading || isStructuredHeading
                isCapturingSummary = isSummaryHeading
                continue
            }

            if isCapturingSummary {
                summaryLines.append(rawLine)
            } else if !sawStructuredHeading {
                preambleLines.append(rawLine)
            }
        }

        if let summary = joinedTrimmedLines(summaryLines) {
            return summary
        }

        if sawStructuredHeading, let preamble = joinedTrimmedLines(preambleLines) {
            return preamble
        }

        return sawStructuredHeading ? nil : trimmedText
    }

    static func decisions(from text: String) -> [MeetingRecapDecision] {
        extractBullets(from: text, sectionKeywords: ["decision", "decisions"])
            .map { MeetingRecapDecision(text: $0) }
    }

    static func actionItems(from text: String) -> [MeetingRecapActionItem] {
        extractBullets(from: text, sectionKeywords: ["action", "actions", "next step", "next steps", "follow up", "follow-up", "todo"])
            .map { MeetingRecapActionItem(text: $0) }
    }

    static func attendees(from meeting: MeetingEntry) -> [String] {
        var values: [String] = []
        if let organizer = meeting.organizerName?.trimmedNilIfEmpty {
            values.append(organizer)
        }
        values.append(contentsOf: meeting.attendeeNames)
        if values.isEmpty {
            values.append(contentsOf: meeting.attendeeEmails)
        }
        return uniqueTrimmed(values)
    }

    private static func extractBullets(from text: String, sectionKeywords: [String]) -> [String] {
        var output: [String] = []
        var isInMatchingSection = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if isHeading(line) {
                let heading = normalizedHeading(line)
                isInMatchingSection = sectionKeywords.contains { heading.contains($0) }
                continue
            }

            guard isInMatchingSection, let bullet = normalizedBullet(line) else { continue }
            output.append(bullet)
        }

        return uniqueTrimmed(output)
    }

    private static func isHeading(_ line: String) -> Bool {
        line.hasPrefix("#")
            || (line.hasSuffix(":") && normalizedHeading(line).count <= 48)
    }

    private static func normalizedHeading(_ line: String) -> String {
        line
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*: -"))
            .lowercased()
    }

    private static func normalizedBullet(_ line: String) -> String? {
        let markers = ["- [ ]", "- [x]", "- ", "* ", "• ", "– "]
        for marker in markers where line.lowercased().hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmedNilIfEmpty
        }
        return nil
    }

    private static func joinedTrimmedLines(_ lines: [String]) -> String? {
        lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmedNilIfEmpty
    }

    private static func uniqueTrimmed(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            guard let trimmed = value.trimmedNilIfEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(trimmed)
        }
        return output
    }

    private static func actionItemLine(_ item: MeetingRecapActionItem) -> String {
        var details: [String] = []
        if let owner = item.owner?.trimmedNilIfEmpty {
            details.append(owner)
        }
        if let dueDate = item.dueDate?.trimmedNilIfEmpty {
            details.append(dueDate)
        }
        guard !details.isEmpty else { return item.text }
        return "\(item.text) (\(details.joined(separator: ", ")))"
    }

    private static func supportMailURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = teamContactEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
