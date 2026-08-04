import Foundation
import SwiftData

/// Shared query layer for workspace data. Used by both the MCP server and the local HTTP API.
final class WorkspaceQueryEngine {

    let dataStore: DataStore

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    // MARK: - Shared timeline

    /// Computes a date range from the flexible timeline parameters.
    /// Priority: explicit from/to > days > fallback default.
    struct TimeRange {
        let from: Date
        let to: Date

        init(from: Date? = nil, to: Date? = nil, days: Int? = nil, defaultDays: Int = 30) {
            self.to = to ?? Date()
            if let from {
                self.from = from
            } else {
                let d = days ?? defaultDays
                self.from = Calendar.current.date(byAdding: .day, value: -d, to: self.to) ?? self.to
            }
        }
    }

    // MARK: - Date parsing helper

    /// Parses flexible date strings: "2026-03-25", "2026-03-25T14:00:00", ISO8601, or relative like "today", "yesterday", "3d", "2w".
    static func parseDate(_ string: String) -> Date? {
        WorkspaceDateParser.parse(string)
    }

    // MARK: - Search

    struct SearchParams {
        var query: String
        var type: String?
        var days: Int? = nil
        var from: Date? = nil
        var to: Date? = nil
        var limit: Int = 20
        var app: String? = nil
        var urlHost: String? = nil
        var windowSubstring: String? = nil

        var timeRange: TimeRange {
            TimeRange(from: from, to: to, days: days, defaultDays: 30)
        }
    }

    struct SearchResult {
        let type: String
        let id: String
        let date: Date
        let score: Int
        let fields: [String: String]
    }

    func search(_ params: SearchParams) async -> [SearchResult] {
        let range = params.timeRange
        let terms = Self.tokenize(params.query)
        guard !terms.isEmpty else { return [] }
        let limit = min(params.limit, 500)
        var results: [SearchResult] = []

        if params.type == nil || params.type == "dictation" {
            let cutoff = range.from
            let ceiling = range.to
            let descriptor = FetchDescriptor<DictationEntry>(
                predicate: #Predicate { $0.date >= cutoff && $0.date <= ceiling },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            let appFilter = params.app?.lowercased()
            for entry in await fetchDictations(descriptor) {
                if let appFilter, !entry.appName.lowercased().contains(appFilter) { continue }

                let textScore = Self.scoreTerms(terms, in: entry.text) * 2
                let appScore = Self.scoreTerms(terms, in: entry.appName) * 3
                let windowScore = Self.scoreTerms(terms, in: entry.windowTitle)
                let urlScore = Self.scoreTerms(terms, in: entry.browserURL)
                let fileScore = Self.scoreTerms(terms, in: entry.codeFileName)
                let slackScore = Self.scoreTerms(terms, in: entry.slackRecipient) * 2
                let totalScore = textScore + appScore + windowScore + urlScore + fileScore + slackScore

                if totalScore > 0 {
                    var fields: [String: String] = [
                        "app": entry.appName,
                        "text": Self.extractBestSnippet(terms: terms, from: entry.text, maxLen: 500),
                        "context": [entry.windowTitle, entry.browserURL, entry.codeFileName, entry.slackRecipient]
                            .compactMap(Self.nonEmpty)
                            .joined(separator: " | ")
                    ]
                    if let wt = Self.nonEmpty(entry.windowTitle) { fields["window"] = wt }
                    if let url = Self.nonEmpty(entry.browserURL) { fields["url"] = url }

                    results.append(SearchResult(
                        type: "dictation",
                        id: entry.id.uuidString,
                        date: entry.date,
                        score: totalScore,
                        fields: fields
                    ))
                }
            }
        }

        if params.type == nil || params.type == "memo" {
            let cutoff = range.from
            let ceiling = range.to
            let descriptor = FetchDescriptor<MemoEntry>(
                predicate: #Predicate { $0.date >= cutoff && $0.date <= ceiling },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            for entry in await fetchMemos(descriptor) {
                let titleScore = Self.scoreTerms(terms, in: entry.title) * 4
                let textScore = Self.scoreTerms(terms, in: entry.text) * 2
                let summaryScore = Self.scoreTerms(terms, in: entry.distilledText) * 3
                let totalScore = titleScore + textScore + summaryScore

                if totalScore > 0 {
                    results.append(SearchResult(
                        type: "memo",
                        id: entry.id.uuidString,
                        date: entry.date,
                        score: totalScore,
                        fields: [
                            "title": entry.title,
                            "text": Self.extractBestSnippet(terms: terms, from: entry.text, maxLen: 500)
                        ]
                    ))
                }
            }
        }

        if params.type == nil || params.type == "meeting" {
            let cutoff = range.from
            let ceiling = range.to
            let descriptor = FetchDescriptor<MeetingEntry>(
                predicate: #Predicate { $0.startedAt >= cutoff && $0.startedAt <= ceiling },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
            for entry in await fetchMeetings(descriptor) where entry.activeJSONLPath == nil {
                let titleScore = Self.scoreTerms(terms, in: entry.displayTitle) * 4
                let notesScore = Self.scoreTerms(terms, in: entry.userNotes) * 2
                    + Self.scoreTerms(terms, in: entry.postMeetingNotes) * 2
                var transcriptScore = 0
                var transcript: String?

                if titleScore + notesScore == 0 {
                    transcript = Self.loadMeetingTranscript(markdownPath: entry.markdownPath)
                    transcriptScore = Self.scoreTerms(terms, in: transcript)
                }

                let totalScore = titleScore + notesScore + transcriptScore
                if totalScore > 0 {
                    let snippetSource = transcriptScore > 0
                        ? transcript
                        : (Self.nonEmpty(entry.userNotes) ?? Self.nonEmpty(entry.postMeetingNotes) ?? entry.displayTitle)
                    let snippet = Self.extractBestSnippet(terms: terms, from: snippetSource, maxLen: 300)
                    results.append(SearchResult(
                        type: "meeting",
                        id: entry.id.uuidString,
                        date: entry.startedAt,
                        score: totalScore,
                        fields: [
                            "title": entry.displayTitle,
                            "duration": entry.formattedDuration,
                            "snippet": snippet
                        ]
                    ))
                }
            }
        }

        if params.type == nil || params.type == "ambient" {
            results.append(contentsOf: await ambientSearch(params))
        }

        if params.type == nil || params.type == "journal" {
            let cutoff = range.from
            let ceiling = range.to
            let descriptor = FetchDescriptor<JournalDay>(
                predicate: #Predicate { $0.date >= cutoff && $0.date <= ceiling },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            for journal in await fetchJournals(descriptor) {
                let summaryScore = Self.scoreTerms(terms, in: journal.summary) * 3
                let blocks = (try? JSONDecoder().decode([JournalBlock].self, from: journal.blocksJSON)) ?? []
                var blockHaystack = ""
                for block in blocks {
                    blockHaystack += " \(block.appName)"
                    if let topic = block.topicLabel { blockHaystack += " \(topic)" }
                    if let ctx = block.contextLabel { blockHaystack += " \(ctx)" }
                    if let bSummary = block.summary { blockHaystack += " \(bSummary)" }
                    if let accomplishment = block.accomplishment { blockHaystack += " \(accomplishment)" }
                    blockHaystack += " " + block.entries.joined(separator: " ")
                }
                let blockScore = Self.scoreTerms(terms, in: blockHaystack)
                let totalScore = summaryScore + blockScore
                if totalScore > 0 {
                    let snippetSource = blockScore > 0 ? blockHaystack : (journal.summary ?? "")
                    results.append(SearchResult(
                        type: "journal",
                        id: dateFormatter.string(from: journal.date),
                        date: journal.date,
                        score: totalScore,
                        fields: [
                            "title": "Journal " + dateFormatter.string(from: journal.date),
                            "snippet": Self.extractBestSnippet(terms: terms, from: snippetSource, maxLen: 300)
                        ]
                    ))
                }
            }
        }

        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.date > b.date
        }

        return Array(results.prefix(limit))
    }

    /// Serialize search results to [[String: String]] for JSON/MCP output.
    func serializeSearchResults(_ results: [SearchResult]) -> [[String: String]] {
        let iso = ISO8601DateFormatter()
        return results.map { result in
            var item = result.fields
            item["type"] = result.type
            item["id"] = result.id
            item["date"] = iso.string(from: result.date)
            item["score"] = "\(result.score)"
            return item
        }
    }

    // MARK: - Recent activity

    struct RecentActivityParams {
        var hours: Int? = nil
        var from: Date? = nil
        var to: Date? = nil
        var limit: Int = 50

        var cutoff: Date {
            if let from { return from }
            return Date().addingTimeInterval(-Double(hours ?? 24) * 3600)
        }

        var ceiling: Date {
            to ?? Date()
        }
    }

    struct ActivityItem {
        let type: String
        let date: Date
        let id: String
        let text: String
        let context: String
    }

    func recentActivity(_ params: RecentActivityParams) async -> [ActivityItem] {
        let cutoff = params.cutoff
        let ceiling = params.ceiling
        let limit = min(params.limit, 1000)
        var items: [ActivityItem] = []

        let dictDescriptor = FetchDescriptor<DictationEntry>(
            predicate: #Predicate { $0.date >= cutoff && $0.date <= ceiling },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        for entry in await fetchDictations(dictDescriptor) {
            let context = [
                entry.appName,
                entry.windowTitle,
                entry.browserURL,
                entry.codeFileName,
                entry.slackRecipient
            ]
            .compactMap(Self.nonEmpty)
            .joined(separator: " | ")
            items.append(ActivityItem(
                type: "dictation",
                date: entry.date,
                id: entry.id.uuidString,
                text: entry.text,
                context: context
            ))
        }

        let memoDescriptor = FetchDescriptor<MemoEntry>(
            predicate: #Predicate { $0.date >= cutoff && $0.date <= ceiling },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        for entry in await fetchMemos(memoDescriptor) {
            items.append(ActivityItem(
                type: "memo",
                date: entry.date,
                id: entry.id.uuidString,
                text: "\(entry.title): \(entry.text)",
                context: ""
            ))
        }

        let meetingDescriptor = FetchDescriptor<MeetingEntry>(
            predicate: #Predicate { $0.startedAt >= cutoff && $0.startedAt <= ceiling },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        for entry in await fetchMeetings(meetingDescriptor) where entry.activeJSONLPath == nil {
            items.append(ActivityItem(
                type: "meeting",
                date: entry.startedAt,
                id: entry.id.uuidString,
                text: "\(entry.displayTitle) (\(entry.formattedDuration), \(entry.wordCount) words)",
                context: entry.detectedApp ?? ""
            ))
        }

        let ambientDescriptor = FetchDescriptor<AmbientContextSnapshot>(
            predicate: #Predicate { $0.timestamp >= cutoff && $0.timestamp <= ceiling },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        for snapshot in await fetchAmbientSnapshots(ambientDescriptor) {
            let dwell = snapshot.dwellDurationSeconds.map { String(format: "%.0fs", $0) } ?? ""
            let context = [snapshot.windowTitle, snapshot.browserURL, snapshot.codeFileName]
                .compactMap(Self.nonEmpty)
                .joined(separator: " | ")
            items.append(ActivityItem(
                type: "ambient",
                date: snapshot.timestamp,
                id: snapshot.id.uuidString,
                text: "\(snapshot.appName)\(dwell.isEmpty ? "" : " (\(dwell))")",
                context: context
            ))
        }

        items.sort { $0.date > $1.date }
        return Array(items.prefix(limit))
    }

    // MARK: - Meetings

    struct ListParams {
        var days: Int? = nil
        var from: Date? = nil
        var to: Date? = nil
        var limit: Int = 20
        var app: String? = nil
        var organizer: String? = nil
        var attendee: String? = nil

        var timeRange: TimeRange {
            TimeRange(from: from, to: to, days: days, defaultDays: 7)
        }
    }

    func listMeetings(_ params: ListParams) async -> [[String: String]] {
        let range = params.timeRange
        let cutoff = range.from
        let ceiling = range.to
        let organizerFilter = params.organizer?.lowercased()
        let attendeeFilter = params.attendee?.lowercased()
        let needsPostFilter = organizerFilter != nil || attendeeFilter != nil
        let requestedLimit = max(0, min(params.limit, 500))
        let pageSize = 200
        let maxScan = 5_000
        let descriptor = FetchDescriptor<MeetingEntry>(
            predicate: #Predicate { $0.startedAt >= cutoff && $0.startedAt <= ceiling },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )

        let iso = ISO8601DateFormatter()
        var out: [[String: String]] = []
        func appendIfMatching(_ entry: MeetingSnapshot) {
            guard entry.activeJSONLPath == nil else { return }
            if let organizerFilter {
                guard let organizer = entry.organizerName?.lowercased(),
                      organizer.contains(organizerFilter) else { return }
            }
            if let attendeeFilter {
                let hasMatch = entry.attendeeNames.contains { $0.lowercased().contains(attendeeFilter) }
                guard hasMatch else { return }
            }
            var item = [
                "id": entry.id.uuidString,
                "title": entry.displayTitle,
                "date": iso.string(from: entry.startedAt),
                "duration": entry.formattedDuration,
                "words": "\(entry.wordCount)",
                "app": entry.detectedApp ?? ""
            ]
            if let organizer = Self.nonEmpty(entry.organizerName) {
                item["organizer"] = organizer
            }
            if let participantSummary = Self.nonEmpty(entry.participantSummary) {
                item["participants"] = participantSummary
            }
            if let calendar = Self.nonEmpty(entry.calendarName) {
                item["calendar"] = calendar
            }
            if let recordingOrigin = Self.nonEmpty(entry.recordingOriginRaw) {
                item["recordingOrigin"] = recordingOrigin
            }
            out.append(item)
        }

        if needsPostFilter {
            var offset = 0
            while out.count < requestedLimit && offset < maxScan {
                let fetchLimit = min(pageSize, maxScan - offset)
                var pageDescriptor = descriptor
                pageDescriptor.fetchOffset = offset
                pageDescriptor.fetchLimit = fetchLimit

                let page = await fetchMeetings(pageDescriptor)
                if page.isEmpty { break }

                for entry in page {
                    appendIfMatching(entry)
                    if out.count >= requestedLimit { break }
                }

                if page.count < fetchLimit { break }
                offset += page.count
            }
        } else {
            var limitedDescriptor = descriptor
            limitedDescriptor.fetchLimit = requestedLimit
            for entry in await fetchMeetings(limitedDescriptor) {
                appendIfMatching(entry)
                if out.count >= requestedLimit { break }
            }
        }
        return out
    }

    func getMeeting(id: UUID) async -> [String: Any]? {
        let descriptor = FetchDescriptor<MeetingEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entry = await fetchMeetings(descriptor).first(where: { $0.activeJSONLPath == nil }) else {
            return nil
        }
        return serializeMeeting(entry)
    }

    func getMeeting(title: String) async -> [String: Any]? {
        let normalizedTitle = normalizedMeetingTitle(title)
        guard !normalizedTitle.isEmpty else { return nil }

        let descriptor = FetchDescriptor<MeetingEntry>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        guard let entry = await fetchMeetings(descriptor).first(where: {
            $0.activeJSONLPath == nil && normalizedMeetingTitle($0.displayTitle) == normalizedTitle
        }) else {
            return nil
        }

        return serializeMeeting(entry)
    }

    private func serializeMeeting(_ entry: MeetingSnapshot) -> [String: Any] {
        var result: [String: Any] = [
            "id": entry.id.uuidString,
            "title": entry.displayTitle,
            "date": ISO8601DateFormatter().string(from: entry.startedAt),
            "duration": entry.formattedDuration,
            "words": entry.wordCount
        ]
        if let app = Self.nonEmpty(entry.detectedApp) { result["app"] = app }
        if let calendarEventID = Self.nonEmpty(entry.calendarEventID) { result["calendarEventId"] = calendarEventID }
        if let scheduledStart = entry.scheduledStartAt { result["scheduledStart"] = ISO8601DateFormatter().string(from: scheduledStart) }
        if let scheduledEnd = entry.scheduledEndAt { result["scheduledEnd"] = ISO8601DateFormatter().string(from: scheduledEnd) }
        if let organizer = Self.nonEmpty(entry.organizerName) { result["organizer"] = organizer }
        if !entry.attendeeNames.isEmpty { result["attendees"] = entry.attendeeNames }
        if let calendarName = Self.nonEmpty(entry.calendarName) { result["calendar"] = calendarName }
        if let conferencingURL = Self.nonEmpty(entry.conferencingURL) { result["conferencingURL"] = conferencingURL }
        if let recordingOrigin = Self.nonEmpty(entry.recordingOriginRaw) { result["recordingOrigin"] = recordingOrigin }
        if let markdownPath = Self.nonEmpty(entry.markdownPath) { result["markdownPath"] = markdownPath }
        if let audioPath = Self.nonEmpty(entry.audioPath) { result["audioPath"] = audioPath }
        if let notes = Self.nonEmpty(entry.userNotes) { result["notes"] = notes }
        if let postNotes = Self.nonEmpty(entry.postMeetingNotes) { result["postMeetingNotes"] = postNotes }
        if let summary = Self.nonEmpty(entry.summary) { result["summary"] = summary }
        if let transcript = Self.loadMeetingTranscript(markdownPath: entry.markdownPath) {
            result["transcript"] = transcript
        }
        return result
    }

    private func normalizedMeetingTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    // MARK: - Dictations

    func listDictations(_ params: ListParams) async -> [[String: String]] {
        let range = params.timeRange
        let cutoff = range.from
        let ceiling = range.to
        let appFilter = params.app?.lowercased()
        var descriptor = FetchDescriptor<DictationEntry>(
            predicate: #Predicate { $0.date >= cutoff && $0.date <= ceiling },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = appFilter == nil ? min(params.limit, 1000) : min(params.limit, 1000) * 3

        let iso = ISO8601DateFormatter()
        var results: [[String: String]] = []

        for entry in await fetchDictations(descriptor) {
            if let appFilter, !entry.appName.lowercased().contains(appFilter) { continue }

            var item: [String: String] = [
                "id": entry.id.uuidString,
                "date": iso.string(from: entry.date),
                "app": entry.appName,
                "text": String(entry.text.prefix(200)),
                "words": "\(entry.wordCount)"
            ]
            if let windowTitle = Self.nonEmpty(entry.windowTitle) { item["window"] = windowTitle }
            if let url = Self.nonEmpty(entry.browserURL) { item["url"] = url }
            if let file = Self.nonEmpty(entry.codeFileName) { item["file"] = file }
            if let slack = Self.nonEmpty(entry.slackRecipient) { item["slack"] = slack }
            results.append(item)

            if results.count >= min(params.limit, 1000) {
                break
            }
        }

        return results
    }

    func getDictation(id: UUID) async -> [String: Any]? {
        let descriptor = FetchDescriptor<DictationEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entry = await fetchDictations(descriptor).first else { return nil }

        let iso = ISO8601DateFormatter()
        var result: [String: Any] = [
            "id": entry.id.uuidString,
            "date": iso.string(from: entry.date),
            "app": entry.appName,
            "bundleId": entry.bundleId,
            "text": entry.text,
            "words": entry.wordCount,
            "duration": entry.duration
        ]
        if let windowTitle = Self.nonEmpty(entry.windowTitle) { result["window"] = windowTitle }
        if let url = Self.nonEmpty(entry.browserURL) { result["url"] = url }
        if let file = Self.nonEmpty(entry.codeFileName) { result["file"] = file }
        if let slack = Self.nonEmpty(entry.slackRecipient) { result["slack"] = slack }
        if let rawTranscript = Self.nonEmpty(entry.rawTranscript), rawTranscript != entry.text {
            result["rawTranscript"] = rawTranscript
        }
        if let selectedText = Self.nonEmpty(entry.selectedText) { result["selectedText"] = selectedText }
        if let deliveredText = Self.nonEmpty(entry.deliveredText), deliveredText != entry.text {
            result["deliveredText"] = deliveredText
        }
        if let focusedFieldContent = Self.nonEmpty(entry.focusedFieldContent) {
            result["focusedFieldContent"] = focusedFieldContent
        }
        if !entry.visibleTextSnippets.isEmpty {
            result["visibleTextSnippets"] = entry.visibleTextSnippets
        }
        return result
    }

    // MARK: - Memos

    func listMemos(_ params: ListParams) async -> [[String: String]] {
        let range = TimeRange(from: params.from, to: params.to, days: params.days, defaultDays: 30)
        let cutoff = range.from
        let ceiling = range.to
        var descriptor = FetchDescriptor<MemoEntry>(
            predicate: #Predicate { $0.date >= cutoff && $0.date <= ceiling },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = min(params.limit, 1000)

        let iso = ISO8601DateFormatter()
        return await fetchMemos(descriptor).map { entry in
            var item: [String: String] = [
                "id": entry.id.uuidString,
                "title": entry.displayTitle,
                "date": iso.string(from: entry.date),
                "duration": String(format: "%.0f", entry.duration)
            ]
            if let distilled = Self.nonEmpty(entry.distilledText) {
                item["summary"] = String(distilled.prefix(200))
            } else {
                item["text"] = String(entry.text.prefix(200))
            }
            return item
        }
    }

    func getMemo(id: UUID) async -> [String: Any]? {
        let descriptor = FetchDescriptor<MemoEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entry = await fetchMemos(descriptor).first else { return nil }

        let iso = ISO8601DateFormatter()
        var result: [String: Any] = [
            "id": entry.id.uuidString,
            "title": entry.displayTitle,
            "date": iso.string(from: entry.date),
            "text": entry.text,
            "duration": entry.duration
        ]
        if let distilled = Self.nonEmpty(entry.distilledText) { result["summary"] = distilled }
        return result
    }

    // MARK: - Journal

    func getJournal(date: Date?) async -> [String: Any]? {
        let targetDate = Calendar.current.startOfDay(for: date ?? Date())
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: targetDate) ?? targetDate
        let descriptor = FetchDescriptor<JournalDay>(
            predicate: #Predicate { $0.date >= targetDate && $0.date < nextDay }
        )

        guard let journal = await fetchJournals(descriptor).first else { return nil }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        var result: [String: Any] = [
            "date": dateFormatter.string(from: targetDate)
        ]
        if let summary = Self.nonEmpty(journal.summary) { result["summary"] = summary }

        let blocks = ((try? JSONDecoder().decode([JournalBlock].self, from: journal.blocksJSON)) ?? [])
            .sorted { $0.startTime < $1.startTime }
        result["blocks"] = blocks.map { block -> [String: Any] in
            var item: [String: Any] = [
                "start": timeFormatter.string(from: block.startTime),
                "end": timeFormatter.string(from: block.endTime),
                "app": block.appName
            ]
            if let label = Self.nonEmpty(block.contextLabel) { item["context"] = label }
            if let topic = Self.nonEmpty(block.topicLabel) { item["topic"] = topic }
            if let summary = Self.nonEmpty(block.summary) { item["summary"] = summary }
            if let accomplishment = Self.nonEmpty(block.accomplishment) { item["accomplishment"] = accomplishment }
            if !block.entries.isEmpty { item["entries"] = block.entries }
            return item
        }

        return result
    }

    // MARK: - Journal listing

    func listJournals(_ params: ListParams) async -> [[String: Any]] {
        let range = TimeRange(from: params.from, to: params.to, days: params.days, defaultDays: 7)
        let cutoff = Calendar.current.startOfDay(for: range.from)
        let ceiling = range.to
        var descriptor = FetchDescriptor<JournalDay>(
            predicate: #Predicate { $0.date >= cutoff && $0.date <= ceiling },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = min(params.limit, 365)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        return await fetchJournals(descriptor).map { journal -> [String: Any] in
            let blocks = ((try? JSONDecoder().decode([JournalBlock].self, from: journal.blocksJSON)) ?? [])
            var item: [String: Any] = [
                "date": dateFormatter.string(from: journal.date),
                "blockCount": blocks.count
            ]
            if let summary = Self.nonEmpty(journal.summary) { item["summary"] = summary }
            return item
        }
    }

    // MARK: - Ambient context

    struct AmbientTimelineParams {
        var days: Int? = nil
        var from: Date? = nil
        var to: Date? = nil
        var limit: Int = 100
        var app: String? = nil
        var urlHost: String? = nil
        var windowSubstring: String? = nil

        var timeRange: TimeRange {
            TimeRange(from: from, to: to, days: days, defaultDays: 1)
        }
    }

    func ambientTimeline(_ params: AmbientTimelineParams) async -> [[String: String]] {
        let range = params.timeRange
        let cutoff = range.from
        let ceiling = range.to
        let appFilter = params.app?.lowercased()
        let urlHostFilter = params.urlHost?.lowercased()
        let windowFilter = params.windowSubstring?.lowercased()
        let hasPostFilter = appFilter != nil || urlHostFilter != nil || windowFilter != nil
        var descriptor = FetchDescriptor<AmbientContextSnapshot>(
            predicate: #Predicate { $0.timestamp >= cutoff && $0.timestamp <= ceiling },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = hasPostFilter ? min(params.limit, 1000) * 3 : min(params.limit, 1000)

        let iso = ISO8601DateFormatter()
        var results: [[String: String]] = []

        for snapshot in await fetchAmbientSnapshots(descriptor) {
            if let appFilter, !snapshot.appName.lowercased().contains(appFilter) { continue }
            if let urlHostFilter {
                guard let url = snapshot.browserURL?.lowercased(),
                      Self.urlHost(url).contains(urlHostFilter) else { continue }
            }
            if let windowFilter {
                guard let window = snapshot.windowTitle?.lowercased(),
                      window.contains(windowFilter) else { continue }
            }

            var item: [String: String] = [
                "id": snapshot.id.uuidString,
                "timestamp": iso.string(from: snapshot.timestamp),
                "app": snapshot.appName,
                "bundleId": snapshot.bundleId
            ]
            if let windowTitle = Self.nonEmpty(snapshot.windowTitle) { item["window"] = windowTitle }
            if let url = Self.nonEmpty(snapshot.browserURL) { item["url"] = url }
            if let file = Self.nonEmpty(snapshot.codeFileName) { item["file"] = file }
            if let slack = Self.nonEmpty(snapshot.slackRecipient) { item["slack"] = slack }
            if let dwell = snapshot.dwellDurationSeconds {
                item["dwell"] = String(format: "%.0fs", dwell)
            }
            if let clipboard = Self.nonEmpty(snapshot.clipboardText) {
                item["clipboard"] = String(clipboard.prefix(200))
            }
            if let notification = Self.nonEmpty(snapshot.notificationText) {
                item["notification"] = String(notification.prefix(300))
            }
            if !snapshot.browserTabs.isEmpty {
                item["tabs"] = snapshot.browserTabs.joined(separator: " | ")
            }
            let snippetCount = snapshot.visibleTextSnippets.count
            if snippetCount > 0 { item["snippets"] = "\(snippetCount) text elements captured" }

            results.append(item)
            if results.count >= min(params.limit, 1000) {
                break
            }
        }

        return results
    }

    struct AmbientUsageParams {
        var days: Int? = nil
        var from: Date? = nil
        var to: Date? = nil

        var timeRange: TimeRange {
            TimeRange(from: from, to: to, days: days, defaultDays: 1)
        }
    }

    func ambientAppUsage(_ params: AmbientUsageParams) async -> [[String: String]] {
        let range = params.timeRange
        let cutoff = range.from
        let ceiling = range.to
        let descriptor = FetchDescriptor<AmbientContextSnapshot>(
            predicate: #Predicate { $0.timestamp >= cutoff && $0.timestamp <= ceiling },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        var appDwell: [String: Double] = [:]
        var appSwitches: [String: Int] = [:]

        for snapshot in await fetchAmbientSnapshots(descriptor) {
            let key = snapshot.appName
            appSwitches[key, default: 0] += 1
            if let dwell = snapshot.dwellDurationSeconds {
                appDwell[key, default: 0] += dwell
            }
        }

        return appDwell.sorted { $0.value > $1.value }.map { app, totalSeconds in
            let switches = appSwitches[app] ?? 0
            let hours = Int(totalSeconds) / 3600
            let minutes = (Int(totalSeconds) % 3600) / 60
            let formatted = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
            return [
                "app": app,
                "totalDwell": formatted,
                "totalSeconds": String(format: "%.0f", totalSeconds),
                "switches": "\(switches)"
            ]
        }
    }

    func ambientSearch(_ params: SearchParams) async -> [SearchResult] {
        let range = params.timeRange
        let terms = Self.tokenize(params.query)
        guard !terms.isEmpty else { return [] }
        let cutoff = range.from
        let ceiling = range.to
        let appFilter = params.app?.lowercased()
        let urlHostFilter = params.urlHost?.lowercased()
        let windowFilter = params.windowSubstring?.lowercased()
        var descriptor = FetchDescriptor<AmbientContextSnapshot>(
            predicate: #Predicate { $0.timestamp >= cutoff && $0.timestamp <= ceiling },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = min(params.limit, 500) * 5

        var results: [SearchResult] = []

        for snapshot in await fetchAmbientSnapshots(descriptor) {
            if let appFilter, !snapshot.appName.lowercased().contains(appFilter) { continue }
            if let urlHostFilter {
                guard let url = snapshot.browserURL?.lowercased(),
                      Self.urlHost(url).contains(urlHostFilter) else { continue }
            }
            if let windowFilter {
                guard let window = snapshot.windowTitle?.lowercased(),
                      window.contains(windowFilter) else { continue }
            }
            let appScore = Self.scoreTerms(terms, in: snapshot.appName) * 3
            let windowScore = Self.scoreTerms(terms, in: snapshot.windowTitle) * 2
            let urlScore = Self.scoreTerms(terms, in: snapshot.browserURL) * 2
            let fileScore = Self.scoreTerms(terms, in: snapshot.codeFileName)
            let slackScore = Self.scoreTerms(terms, in: snapshot.slackRecipient) * 2
            let clipScore = Self.scoreTerms(terms, in: snapshot.clipboardText)
            let notificationScore = Self.scoreTerms(terms, in: snapshot.notificationText) * 3
            let cheapScore = appScore + windowScore + urlScore + fileScore + slackScore + clipScore + notificationScore

            var snippetScore = 0
            var tabScore = 0
            var snippetText = ""
            if cheapScore == 0 {
                snippetText = snapshot.visibleTextSnippets.joined(separator: " ")
                snippetScore = Self.scoreTerms(terms, in: snippetText)
                let tabText = snapshot.browserTabs.joined(separator: " ")
                tabScore = Self.scoreTerms(terms, in: tabText)
            }
            let totalScore = cheapScore + snippetScore + tabScore

            if totalScore > 0 {
                var fields: [String: String] = ["app": snapshot.appName]
                if let windowTitle = Self.nonEmpty(snapshot.windowTitle) { fields["window"] = windowTitle }
                if let url = Self.nonEmpty(snapshot.browserURL) { fields["url"] = url }
                if let notification = Self.nonEmpty(snapshot.notificationText) { fields["notification"] = notification }
                if let dwell = snapshot.dwellDurationSeconds { fields["dwell"] = String(format: "%.0fs", dwell) }
                if snippetScore > 0 {
                    fields["snippet"] = Self.extractBestSnippet(terms: terms, from: snippetText, maxLen: 300)
                }

                results.append(SearchResult(
                    type: "ambient",
                    id: snapshot.id.uuidString,
                    date: snapshot.timestamp,
                    score: totalScore,
                    fields: fields
                ))
            }
        }

        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.date > b.date
        }

        return Array(results.prefix(min(params.limit, 500)))
    }

    // MARK: - Background fetch helpers

    private func fetchDictations(_ descriptor: FetchDescriptor<DictationEntry>) async -> [DictationSnapshot] {
        await dataStore.fetchMappedInBackground(descriptor) { entry in
            DictationSnapshot(
                id: entry.id,
                text: entry.text,
                appName: entry.appName,
                bundleId: entry.bundleId,
                windowTitle: entry.windowTitle,
                browserURL: entry.browserURL,
                codeFileName: entry.codeFileName,
                slackRecipient: entry.slackRecipient,
                wordCount: entry.wordCount,
                duration: entry.duration,
                date: entry.date,
                rawTranscript: entry.rawTranscript,
                selectedText: entry.selectedText,
                deliveredText: entry.deliveredText,
                focusedFieldContent: entry.focusedFieldContent,
                visibleTextSnippets: decodeJSONStringArray(entry.visibleTextSnippetsJSON)
            )
        }
    }

    private func fetchMemos(_ descriptor: FetchDescriptor<MemoEntry>) async -> [MemoSnapshot] {
        await dataStore.fetchMappedInBackground(descriptor) { entry in
            MemoSnapshot(
                id: entry.id,
                text: entry.text,
                title: entry.title,
                distilledText: entry.distilledText,
                duration: entry.duration,
                date: entry.date
            )
        }
    }

    private func fetchMeetings(_ descriptor: FetchDescriptor<MeetingEntry>) async -> [MeetingSnapshot] {
        await dataStore.fetchMappedInBackground(descriptor) { entry in
            MeetingSnapshot(
                id: entry.id,
                startedAt: entry.startedAt,
                detectedApp: entry.detectedApp,
                customTitle: entry.customTitle,
                durationSeconds: entry.durationSeconds,
                wordCount: entry.wordCount,
                markdownPath: entry.markdownPath,
                audioPath: entry.audioPath,
                activeJSONLPath: entry.activeJSONLPath,
                userNotes: entry.userNotes,
                postMeetingNotes: entry.postMeetingNotes,
                summary: entry.summary,
                calendarEventID: entry.calendarEventID,
                scheduledStartAt: entry.scheduledStartAt,
                scheduledEndAt: entry.scheduledEndAt,
                organizerName: entry.organizerName,
                attendeeNames: decodeJSONStringArray(entry.attendeeNamesJSON),
                conferencingURL: entry.conferencingURL,
                calendarName: entry.calendarName,
                recordingOriginRaw: entry.recordingOriginRaw
            )
        }
    }

    private func fetchAmbientSnapshots(_ descriptor: FetchDescriptor<AmbientContextSnapshot>) async -> [AmbientSnapshot] {
        await dataStore.fetchMappedInBackground(descriptor) { snapshot in
            AmbientSnapshot(
                id: snapshot.id,
                timestamp: snapshot.timestamp,
                appName: snapshot.appName,
                bundleId: snapshot.bundleId,
                windowTitle: snapshot.windowTitle,
                browserURL: snapshot.browserURL,
                codeFileName: snapshot.codeFileName,
                slackRecipient: snapshot.slackRecipient,
                focusedFieldContent: snapshot.focusedFieldContent,
                visibleTextSnippets: decodeJSONStringArray(snapshot.visibleTextSnippetsJSON),
                dwellDurationSeconds: snapshot.dwellDurationSeconds,
                clipboardText: snapshot.clipboardText,
                browserTabs: decodeJSONStringArray(snapshot.browserTabsJSON),
                notificationAppName: snapshot.notificationAppName,
                notificationBundleId: snapshot.notificationBundleId,
                notificationTitle: snapshot.notificationTitle,
                notificationBody: snapshot.notificationBody,
                notificationURL: snapshot.notificationURL,
                notificationReceivedAt: snapshot.notificationReceivedAt
            )
        }
    }

    private func fetchJournals(_ descriptor: FetchDescriptor<JournalDay>) async -> [JournalSnapshot] {
        await dataStore.fetchMappedInBackground(descriptor) { journal in
            JournalSnapshot(
                date: journal.date,
                summary: journal.summary,
                blocksJSON: journal.blocksJSON
            )
        }
    }

    // MARK: - Search helpers

    /// Tokenize a query string into lowercase search terms.
    /// Quoted phrases are kept as single terms: `"project update" slack` → ["project update", "slack"]
    static func tokenize(_ query: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var inQuote = false

        for char in query {
            if char == "\"" {
                if inQuote {
                    let trimmed = current.trimmingCharacters(in: .whitespaces).lowercased()
                    if !trimmed.isEmpty { terms.append(trimmed) }
                    current = ""
                    inQuote = false
                } else {
                    for word in current.split(separator: " ") {
                        let lowered = word.lowercased()
                        if !lowered.isEmpty { terms.append(lowered) }
                    }
                    current = ""
                    inQuote = true
                }
            } else {
                current.append(char)
            }
        }

        if inQuote {
            for word in current.split(separator: " ") {
                let lowered = word.lowercased()
                if !lowered.isEmpty { terms.append(lowered) }
            }
        } else {
            for word in current.split(separator: " ") {
                let lowered = word.lowercased()
                if !lowered.isEmpty { terms.append(lowered) }
            }
        }

        return terms
    }

    /// Score how well a set of terms matches a text. Returns 0 if any term is missing (AND logic).
    /// Score is the count of total term occurrences (so repeated matches score higher).
    static func scoreTerms(_ terms: [String], in text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        let lower = text.lowercased()

        var totalHits = 0
        for term in terms {
            let count = lower.countOccurrences(of: term)
            if count == 0 { return 0 }
            totalHits += count
        }
        return totalHits
    }

    /// Extract the best snippet around the first matching term.
    static func extractBestSnippet(terms: [String], from text: String?, maxLen: Int = 300) -> String {
        guard let text, !text.isEmpty else { return "" }
        let lower = text.lowercased()

        var bestPos = text.count
        for term in terms {
            if let range = lower.range(of: term) {
                let position = text.distance(from: text.startIndex, to: range.lowerBound)
                if position < bestPos { bestPos = position }
            }
        }

        if bestPos == text.count {
            return String(text.prefix(maxLen))
        }

        let contextBefore = maxLen / 4
        let start = max(0, bestPos - contextBefore)
        let end = min(text.count, start + maxLen)

        let startIndex = text.index(text.startIndex, offsetBy: start)
        let endIndex = text.index(text.startIndex, offsetBy: end)
        var snippet = String(text[startIndex..<endIndex])
        if start > 0 { snippet = "…" + snippet }
        if end < text.count { snippet += "…" }
        return snippet
    }

    // MARK: - File helpers

    static func loadMeetingTranscript(markdownPath: String?) -> String? {
        guard let markdownPath, !markdownPath.isEmpty else { return nil }
        let url: URL
        if markdownPath.hasPrefix("/") {
            url = URL(fileURLWithPath: markdownPath)
        } else {
            url = AppSupportPaths.resonantRoot().appendingPathComponent(markdownPath)
        }
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MeetingMarkdownExporter.extractTranscript(from: markdown)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Extract the host portion from a URL string. Returns the input lowercased if URL parsing fails.
    static func urlHost(_ url: String) -> String {
        if let parsed = URL(string: url), let host = parsed.host {
            return host.lowercased()
        }
        return url.lowercased()
    }
}

private struct DictationSnapshot: Sendable {
    let id: UUID
    let text: String
    let appName: String
    let bundleId: String
    let windowTitle: String?
    let browserURL: String?
    let codeFileName: String?
    let slackRecipient: String?
    let wordCount: Int
    let duration: TimeInterval
    let date: Date
    let rawTranscript: String?
    let selectedText: String?
    let deliveredText: String?
    let focusedFieldContent: String?
    let visibleTextSnippets: [String]
}

private struct MemoSnapshot: Sendable {
    let id: UUID
    let text: String
    let title: String
    let distilledText: String?
    let duration: TimeInterval
    let date: Date

    var displayTitle: String {
        title.isEmpty ? String(text.prefix(50)) : title
    }
}

private struct MeetingSnapshot: Sendable {
    let id: UUID
    let startedAt: Date
    let detectedApp: String?
    let customTitle: String?
    let durationSeconds: Double
    let wordCount: Int
    let markdownPath: String?
    let audioPath: String?
    let activeJSONLPath: String?
    let userNotes: String?
    let postMeetingNotes: String?
    let summary: String?
    let calendarEventID: String?
    let scheduledStartAt: Date?
    let scheduledEndAt: Date?
    let organizerName: String?
    let attendeeNames: [String]
    let conferencingURL: String?
    let calendarName: String?
    let recordingOriginRaw: String?

    var fallbackTitle: String {
        fallbackMeetingTitle(
            detectedApp: detectedApp,
            recordingOrigin: recordingOriginRaw.flatMap(MeetingRecordingOrigin.init(rawValue:))
        )
    }

    var displayTitle: String {
        if let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return fallbackTitle
    }

    var formattedDuration: String {
        let total = Int(durationSeconds)
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let seconds = total % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }

    var participantSummary: String? {
        if let organizerName, !organizerName.isEmpty {
            return organizerName
        }
        return attendeeNames.first
    }
}

private struct AmbientSnapshot: Sendable {
    let id: UUID
    let timestamp: Date
    let appName: String
    let bundleId: String
    let windowTitle: String?
    let browserURL: String?
    let codeFileName: String?
    let slackRecipient: String?
    let focusedFieldContent: String?
    let visibleTextSnippets: [String]
    let dwellDurationSeconds: Double?
    let clipboardText: String?
    let browserTabs: [String]
    let notificationAppName: String?
    let notificationBundleId: String?
    let notificationTitle: String?
    let notificationBody: String?
    let notificationURL: String?
    let notificationReceivedAt: Date?

    var notificationText: String? {
        let text = [notificationAppName, notificationTitle, notificationBody, notificationURL]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " | ")
        return text.isEmpty ? nil : text
    }
}

private struct JournalSnapshot: Sendable {
    let date: Date
    let summary: String?
    let blocksJSON: Data
}

private extension String {
    /// Count non-overlapping occurrences of a substring.
    func countOccurrences(of target: String) -> Int {
        guard !target.isEmpty else { return 0 }
        var count = 0
        var searchRange = startIndex..<endIndex
        while let range = self.range(of: target, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<endIndex
        }
        return count
    }
}
