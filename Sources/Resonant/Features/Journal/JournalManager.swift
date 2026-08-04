import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class JournalManager {
    struct GenerationOutcome {
        let day: JournalDay?
        let usedCloudFeatures: Bool
    }

    private enum Constants {
        static let blockGap: TimeInterval = 15 * 60
        static let recentDayLimit = 30
    }

    private(set) var days: [JournalDay] = []
    private(set) var isLoading = false
    private(set) var lastErrorMessage: String?

    private var daysByDate: [DateComponents: JournalDay] = [:]

    private var dataStore: DataStore?
    private var convexClient: ConvexClient?
    private var settingsManager: SettingsManager?

    func load(from store: DataStore, convexClient: ConvexClient, settingsManager: SettingsManager? = nil) async {
        dataStore = store
        self.convexClient = convexClient
        self.settingsManager = settingsManager
        await reload()
    }

    func reload(limit: Int = Constants.recentDayLimit) async {
        guard let dataStore else {
            days = []
            daysByDate = [:]
            return
        }

        isLoading = true
        defer { isLoading = false }

        var descriptor = FetchDescriptor<JournalDay>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        days = await dataStore.fetchInBackground(descriptor)
        rebuildDateCache()
    }

    private static func dateKey(for date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    private func rebuildDateCache() {
        daysByDate = Dictionary(
            days.map { (Self.dateKey(for: $0.date), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Fast synchronous lookup — returns nil on cache miss (use `journalAsync` for DB fallback).
    func journal(on date: Date) -> JournalDay? {
        daysByDate[Self.dateKey(for: date)]
    }

    /// Async lookup that falls back to the database on cache miss.
    func journalAsync(on date: Date) async -> JournalDay? {
        if let cached = daysByDate[Self.dateKey(for: date)] {
            return cached
        }
        guard let dataStore else { return nil }
        let dayStart = Calendar.current.startOfDay(for: date)
        if let day = await existingJournalAsync(on: dayStart, from: dataStore) {
            upsert(day, on: dayStart)
            return day
        }
        return nil
    }

    func hasJournal(on date: Date) async -> Bool {
        if daysByDate[Self.dateKey(for: date)] != nil {
            return true
        }
        guard let dataStore else { return false }
        let dayStart = Calendar.current.startOfDay(for: date)
        return await dataStore.countInBackground(Self.journalDayDescriptor(on: dayStart)) > 0
    }

    @discardableResult
    func generate(for date: Date) async -> GenerationOutcome {
        guard let dataStore else {
            return GenerationOutcome(day: nil, usedCloudFeatures: false)
        }

        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        let dayStart = Calendar.current.startOfDay(for: date)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let entries = await fetchDictations(from: dataStore, dayStart: dayStart, dayEnd: dayEnd)
        let meetings = await fetchMeetings(from: dataStore, dayStart: dayStart, dayEnd: dayEnd)

        guard !entries.isEmpty || !meetings.isEmpty else {
            _ = await dataStore.performBackgroundWrite { context in
                var descriptor = Self.journalDayDescriptor(on: dayStart)
                descriptor.fetchLimit = 1
                guard let existing = try? context.fetch(descriptor).first else { return }
                context.delete(existing)
            }
            upsert(nil, on: dayStart)
            return GenerationOutcome(day: nil, usedCloudFeatures: false)
        }

        var blocks = JournalBlockOrganizer.buildBlocks(from: entries, blockGap: Constants.blockGap)

        // Convert meetings to journal blocks and merge chronologically
        let meetingBlocks = meetings.map { meeting -> JournalBlock in
            let endTime = meeting.endedAt ?? meeting.startedAt.addingTimeInterval(meeting.durationSeconds)
            return JournalBlock(
                appName: meeting.detectedApp ?? "Meeting",
                bundleId: meetingBundleId(for: meeting.detectedApp),
                contextLabel: meeting.displayTitle,
                entries: [meeting.summary, meeting.userNotes, meeting.postMeetingNotes]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                startTime: meeting.startedAt,
                endTime: endTime,
                summary: meeting.summary,
                wordCount: meeting.wordCount,
                isMeeting: true,
                meetingTitle: meeting.displayTitle,
                meetingApp: meeting.detectedApp,
                meetingDurationSeconds: meeting.durationSeconds
            )
        }
        blocks.append(contentsOf: meetingBlocks)
        blocks.sort { $0.startTime < $1.startTime }
        var usedCloudFeatures = false
        let useCloudSummaries = AppFeatureVisibility.hostedServices
            && SettingsManager.shared.journalSummarizationEnabled
        if useCloudSummaries, let convexClient {
            let summarized = await summarizeBlocks(blocks, using: convexClient)
            blocks = summarized.blocks
            usedCloudFeatures = usedCloudFeatures || summarized.usedCloudFeatures

            let classified = await classifyBlockTopics(
                blocks,
                using: convexClient
            )
            blocks = classified.blocks
            usedCloudFeatures = usedCloudFeatures || classified.usedCloudFeatures

            let accomplished = await generateAccomplishments(blocks, using: convexClient)
            blocks = accomplished.blocks
            usedCloudFeatures = usedCloudFeatures || accomplished.usedCloudFeatures
        } else {
            // Local fallback: use contextLabel if it differs from appName
            for i in blocks.indices {
                if let label = blocks[i].contextLabel, label != blocks[i].appName {
                    blocks[i].topicLabel = label
                }
            }
        }

        let summary: String
        if useCloudSummaries,
           let cloudSummary = await convexClient?.summarizeJournalDay(
            blocks: blocks,
            date: dayStart
           ) {
            summary = cloudSummary
            usedCloudFeatures = true
        } else {
            summary = JournalBlockOrganizer.extractiveDaySummary(from: blocks)
        }

        var narrativeBrief: String?
        if useCloudSummaries, !blocks.isEmpty,
           let brief = await convexClient?.generateDayBrief(
            blocks: blocks,
            date: dayStart
           ) {
            narrativeBrief = brief
            usedCloudFeatures = true
        }

        let generatedAt = Date()
        let savedBlocks = blocks
        let savedBrief = narrativeBrief
        let saved = await dataStore.performBackgroundWrite { context -> UUID in
            var descriptor = Self.journalDayDescriptor(on: dayStart)
            descriptor.fetchLimit = 1
            let journal: JournalDay
            if let existing = try? context.fetch(descriptor).first {
                journal = existing
            } else {
                journal = JournalDay(date: dayStart)
                context.insert(journal)
            }
            journal.updateBlocks(savedBlocks)
            journal.summary = summary.nilIfEmpty
            if let savedBrief { journal.narrativeBrief = savedBrief }
            journal.generatedAt = generatedAt
            return journal.id
        }
        guard saved != nil else {
            lastErrorMessage = "Could not save journal."
            return GenerationOutcome(day: nil, usedCloudFeatures: usedCloudFeatures)
        }
        let journal = dataStore.journalDay(on: dayStart)
        upsert(journal, on: dayStart)
        return GenerationOutcome(day: journal, usedCloudFeatures: usedCloudFeatures)
    }

    private func fetchDictations(
        from dataStore: DataStore,
        dayStart: Date,
        dayEnd: Date
    ) async -> [JournalDictationSnapshot] {
        let descriptor = FetchDescriptor<DictationEntry>(
            predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd },
            sortBy: [SortDescriptor(\.date)]
        )
        return await dataStore.fetchMappedInBackground(descriptor) { entry in
            JournalDictationSnapshot(entry: entry)
        }
    }

    private func fetchMeetings(
        from dataStore: DataStore,
        dayStart: Date,
        dayEnd: Date
    ) async -> [JournalMeetingSnapshot] {
        let descriptor = FetchDescriptor<MeetingEntry>(
            predicate: #Predicate { $0.startedAt >= dayStart && $0.startedAt < dayEnd },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        return await dataStore.fetchMappedInBackground(descriptor) { entry in
            JournalMeetingSnapshot(entry: entry)
        }
        .filter { $0.activeJSONLPath == nil }
    }

    private func meetingBundleId(for appName: String?) -> String {
        let known: [String: String] = [
            "Zoom": "us.zoom.xos",
            "zoom": "us.zoom.xos",
            "Google Meet": "com.google.meet",
            "Teams": "com.microsoft.teams2",
            "Microsoft Teams": "com.microsoft.teams2",
            "Webex": "com.cisco.webexmeetings",
            "FaceTime": "com.apple.FaceTime",
            "Slack": "com.tinyspeck.slackmacgap",
            "Discord": "com.hnc.Discord"
        ]
        return known[appName ?? ""] ?? "com.resonant.meeting"
    }

    private func existingJournal(on date: Date, from dataStore: DataStore) -> JournalDay? {
        dataStore.fetch(Self.journalDayDescriptor(on: date)).first
    }

    private func existingJournalAsync(on date: Date, from dataStore: DataStore) async -> JournalDay? {
        (await dataStore.fetchInBackground(Self.journalDayDescriptor(on: date))).first
    }

    private nonisolated static func journalDayDescriptor(on date: Date) -> FetchDescriptor<JournalDay> {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        var descriptor = FetchDescriptor<JournalDay>(
            predicate: #Predicate { $0.date >= date && $0.date < dayEnd }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    private func upsert(_ journal: JournalDay?, on date: Date) {
        let key = Self.dateKey(for: date)
        days.removeAll { Self.dateKey(for: $0.date) == key }
        daysByDate[key] = nil
        if let journal {
            let insertionIndex = days.firstIndex { $0.date < journal.date } ?? days.endIndex
            days.insert(journal, at: insertionIndex)
            daysByDate[key] = journal
        }
    }

    /// Regenerate just the narrative brief for a day (keeps blocks/summary intact).
    @discardableResult
    func regenerateBrief(for date: Date) async -> String? {
        guard let dataStore, let convexClient else { return nil }
        let dayStart = Calendar.current.startOfDay(for: date)
        guard let existing = await journalAsync(on: dayStart) else { return nil }
        let blocks = existing.blocks
        guard !blocks.isEmpty else { return nil }

        guard let brief = await convexClient.generateDayBrief(
            blocks: blocks,
            date: dayStart
        ) else { return nil }

        _ = await dataStore.performBackgroundWrite { context -> UUID? in
            var descriptor = Self.journalDayDescriptor(on: dayStart)
            descriptor.fetchLimit = 1
            guard let day = try? context.fetch(descriptor).first else { return nil }
            day.narrativeBrief = brief
            return day.id
        }

        let refreshed = dataStore.journalDay(on: dayStart)
        upsert(refreshed, on: dayStart)
        return brief
    }

    /// Stream a chat reply for the given day, yielding content deltas.
    /// Persists the final assistant message to history when complete.
    func streamChatMessage(
        for date: Date,
        userMessage: String,
        attachments: [ChatMentionAttachment] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor [weak self] in
                guard let self, let dataStore = self.dataStore, let convexClient = self.convexClient else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                let dayStart = Calendar.current.startOfDay(for: date)
                let day = await self.journalAsync(on: dayStart)
                let blocks = day?.blocks ?? []
                let history = day?.chatHistory ?? []
                guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continuation.finish()
                    return
                }

                // Persist user turn immediately so the UI can render it.
                let userTurn = TodayChatMessage(role: .user, text: userMessage)
                _ = await dataStore.performBackgroundWrite { context -> UUID? in
                    var descriptor = Self.journalDayDescriptor(on: dayStart)
                    descriptor.fetchLimit = 1
                    let target: JournalDay
                    if let existing = try? context.fetch(descriptor).first {
                        target = existing
                    } else {
                        target = JournalDay(date: dayStart)
                        context.insert(target)
                    }
                    target.updateChatHistory(history + [userTurn])
                    return target.id
                }
                self.upsert(dataStore.journalDay(on: dayStart), on: dayStart)

                let stream: AsyncThrowingStream<String, Error>
                /*
                if let anthropicStream = self.anthropicWorkspaceChatStream(
                    dataStore: dataStore,
                    blocks: blocks,
                    date: dayStart,
                    history: history,
                    userMessage: userMessage,
                    attachments: attachments
                ) {
                    stream = anthropicStream
                } else {
                */
                guard let prompt = convexClient.buildChatPrompt(
                    blocks: blocks,
                    date: dayStart,
                    history: history,
                    userMessage: userMessage,
                    attachments: attachments
                ) else {
                    continuation.finish()
                    return
                }
                stream = convexClient.streamChat(prompt: prompt)
                // }

                var accumulated = ""
                do {
                    for try await delta in stream {
                        accumulated += delta
                        continuation.yield(delta)
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let cleaned = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    let assistantTurn = TodayChatMessage(role: .assistant, text: cleaned)
                    _ = await dataStore.performBackgroundWrite { context -> UUID? in
                        var descriptor = Self.journalDayDescriptor(on: dayStart)
                        descriptor.fetchLimit = 1
                        guard let target = try? context.fetch(descriptor).first else { return nil }
                        target.updateChatHistory(target.chatHistory + [assistantTurn])
                        return target.id
                    }
                    self.upsert(dataStore.journalDay(on: dayStart), on: dayStart)
                }
                continuation.finish()
            }
        }
    }

    /*
    private func anthropicWorkspaceChatStream(
        dataStore: DataStore,
        blocks: [JournalBlock],
        date: Date,
        history: [TodayChatMessage],
        userMessage: String,
        attachments: [ChatMentionAttachment]
    ) -> AsyncThrowingStream<String, Error>? {
        guard let settingsManager,
              settingsManager.byokEnabled,
              settingsManager.byokProvider == .anthropic else {
            return nil
        }

        let apiKey = settingsManager.byokAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }

        let client = AnthropicWorkspaceChatClient(apiKey: apiKey, dataStore: dataStore)
        return client.streamChat(
            systemPrompt: Self.anthropicWorkspaceChatSystemPrompt(
                blocks: blocks,
                date: date,
                attachments: attachments
            ),
            history: history,
            userMessage: userMessage
        )
    }
    */

    private static func anthropicWorkspaceChatSystemPrompt(
        blocks: [JournalBlock],
        date: Date,
        attachments: [ChatMentionAttachment]
    ) -> String {
        let dayContext: String
        if blocks.isEmpty {
            dayContext = "No dictations or meetings recorded on this day."
        } else {
            let threads = JournalDaySummaryInput.buildThreads(from: blocks)
            let dominantApps = JournalDaySummaryInput.dominantApps(from: blocks, limit: 4)
            let threadsText = threads.enumerated().map { index, thread in
                JournalDaySummaryInput.serialize(thread: thread, index: index + 1)
            }.joined(separator: "\n\n")
            dayContext = """
            Date: \(date.formatted(date: .complete, time: .omitted))
            Dominant apps (by time): \(dominantApps)
            Total threads: \(threads.count)

            THREADS:
            \(threadsText)
            """
        }

        let attachmentsSection: String
        if attachments.isEmpty {
            attachmentsSection = ""
        } else {
            attachmentsSection = """

            REFERENCED ATTACHMENTS (meetings/memos the user @-mentioned in their message)
            \(attachments.map { $0.promptBlock() }.joined(separator: "\n\n"))
            """
        }

        return """
        You are the user's reflection partner inside Resonant, a macOS tool that captures their voice dictations, meetings, memos, journal, and ambient work context.

        Answer with concise markdown grounded in the user's local workspace data.

        STYLE RULES:
        - Second person ("you"). Past tense for what happened. Present tense for reflection and advice.
        - No preamble, no recap of the question, no "Great question".
        - Prefer bullets or short paragraphs over long prose.
        - Use **bold** to mark concrete subjects: features, people, projects, documents, meetings.
        - Quote the user's actual words when relevant.
        - Reference specific apps and times when useful.
        - Never say "the user", "the speaker", "the transcript", or "based on the context".
        - Keep it under 180 words unless the user explicitly asks for depth.
        - If the available context cannot answer, say so in one sentence and use tools to find relevant workspace data before giving up.
        - When the user references a specific meeting or memo via an `@"kind: Title"` token, ground your answer in the matching referenced attachment block.
        - When you use workspace tools, cite stable IDs inline like [meeting:id], [memo:id], [dictation:id], [journal:date], or [ambient:id] for factual claims that come from tool results.

        TOOL USE:
        - Use search, recent_activity, list_* and get_* tools when the user asks about workspace data beyond the selected day, asks for specifics, or asks for evidence.
        - Prefer list tools before get tools when you need to find the right item.
        - Use get tools to drill into full details only when needed.
        - Do not expose raw JSON to the user.

        SELECTED DAY CONTEXT
        \(dayContext)
        \(attachmentsSection)
        """
    }

    /// Send a chat message for the given day, append both user and assistant turns to history.
    @discardableResult
    func sendChatMessage(
        for date: Date,
        userMessage: String,
        attachments: [ChatMentionAttachment] = []
    ) async -> String? {
        guard let dataStore, let convexClient else { return nil }
        let dayStart = Calendar.current.startOfDay(for: date)

        let day = await journalAsync(on: dayStart)
        let blocks = day?.blocks ?? []
        let history = day?.chatHistory ?? []

        guard let reply = await convexClient.chatWithDay(
            blocks: blocks,
            date: dayStart,
            history: history,
            userMessage: userMessage,
            attachments: attachments
        ) else { return nil }

        let assistantTurn = TodayChatMessage(role: .assistant, text: reply)
        // The streaming path pre-persists the user turn so it shows up
        // instantly. If we're acting as the fallback after a stream failure,
        // the user turn is already at the tail of history — don't duplicate it.
        let userAlreadyPersisted = history.last?.role == .user && history.last?.text == userMessage
        let updated: [TodayChatMessage]
        if userAlreadyPersisted {
            updated = history + [assistantTurn]
        } else {
            let userTurn = TodayChatMessage(role: .user, text: userMessage)
            updated = history + [userTurn, assistantTurn]
        }

        _ = await dataStore.performBackgroundWrite { context -> UUID? in
            var descriptor = Self.journalDayDescriptor(on: dayStart)
            descriptor.fetchLimit = 1
            let target: JournalDay
            if let existing = try? context.fetch(descriptor).first {
                target = existing
            } else {
                target = JournalDay(date: dayStart)
                context.insert(target)
            }
            target.updateChatHistory(updated)
            return target.id
        }

        let refreshed = dataStore.journalDay(on: dayStart)
        upsert(refreshed, on: dayStart)
        return reply
    }

    func clearChatHistory(for date: Date) async {
        guard let dataStore else { return }
        let dayStart = Calendar.current.startOfDay(for: date)
        _ = await dataStore.performBackgroundWrite { context -> UUID? in
            var descriptor = Self.journalDayDescriptor(on: dayStart)
            descriptor.fetchLimit = 1
            guard let day = try? context.fetch(descriptor).first else { return nil }
            day.updateChatHistory([])
            return day.id
        }
        let refreshed = dataStore.journalDay(on: dayStart)
        upsert(refreshed, on: dayStart)
    }

    func clearWorkspaceData() {
        days = []
        daysByDate = [:]
        isLoading = false
        lastErrorMessage = nil
    }

    private func summarizeBlocks(
        _ blocks: [JournalBlock],
        using convexClient: ConvexClient
    ) async -> (blocks: [JournalBlock], usedCloudFeatures: Bool) {
        var summarized = blocks
        var usedCloudFeatures = false

        for index in summarized.indices {
            guard summarized[index].isMeeting != true else { continue }
            guard summarized[index].wordCount >= 20 else { continue }
            guard let summary = await convexClient.summarizeJournalBlock(
                summarized[index]
            ) else { continue }
            summarized[index].summary = summary
            usedCloudFeatures = true
        }

        return (summarized, usedCloudFeatures)
    }

    private func generateAccomplishments(
        _ blocks: [JournalBlock],
        using convexClient: ConvexClient
    ) async -> (blocks: [JournalBlock], usedCloudFeatures: Bool) {
        var updated = blocks
        var usedCloudFeatures = false

        let highlights = JournalReviewEngine.accomplishmentHighlights(from: blocks)
        let highlightIDs = Set(highlights.map(\.id))

        for index in updated.indices {
            guard highlightIDs.contains(updated[index].id) else { continue }
            guard updated[index].accomplishment == nil else { continue }
            if let accomplishment = await convexClient.generateBlockAccomplishment(
                updated[index]
            ) {
                updated[index].accomplishment = accomplishment
                usedCloudFeatures = true
            }
        }

        return (updated, usedCloudFeatures)
    }

    private func classifyBlockTopics(
        _ blocks: [JournalBlock],
        using convexClient: ConvexClient
    ) async -> (blocks: [JournalBlock], usedCloudFeatures: Bool) {
        var classified = blocks
        var usedCloudFeatures = false

        for index in classified.indices {
            guard classified[index].isMeeting != true else { continue }
            guard classified[index].wordCount >= 15 else { continue }
            if let topic = await convexClient.classifyJournalBlockTopic(
                classified[index]
            ) {
                classified[index].topicLabel = topic
                usedCloudFeatures = true
            } else if let label = classified[index].contextLabel, label != classified[index].appName {
                classified[index].topicLabel = label
            }
        }

        return (classified, usedCloudFeatures)
    }

}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
