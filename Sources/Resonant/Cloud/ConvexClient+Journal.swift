import Foundation

// MARK: - Memos, journal summaries, day brief + chat

extension ConvexClient {
    /// Typed memo processing. Distinguishes quota, auth, and transport
    /// failures so callers can react instead of guessing at `nil`.
    func processMemoDetailed(
        text: String,
        modelRoute: CloudTextModelRoute? = nil
    ) async -> Result<String, CloudProcessingFailure> {
        guard canPerformCloudRequest() else {
            return .failure(resolvedCloudBearerToken == nil ? .signInRequired : .cloudUnavailable)
        }
        guard let userID = resolvedUserID else {
            return .failure(.signInRequired)
        }

        let memoPath = "cloudProcessing:processMemo"
        let startedAt = Date()
        var args: [String: Any] = [
            "userId": userID,
            "transcript": text
        ]
        if let modelRoute {
            args["modelRoute"] = modelRoute.rawValue
        }

        var route = modelRoute
        var fallbackReason: String?
        while true {
            do {
                let response = try await runCloudTextAttempt(CloudTextAttempt(
                    path: memoPath,
                    args: args,
                    timeoutMs: CloudTimeouts.memo(for: route)
                ))
                AnalyticsManager.shared.capture("cloud_processing_used", properties: cloudProcessingUsedProperties(
                    path: memoPath,
                    appKey: nil,
                    clientDurationMs: Self.millisecondsSince(startedAt),
                    serverDurationMs: response.durationMs,
                    fallbackReason: fallbackReason
                ))
                guard let trimmed = response.text.trimmedNilIfEmpty else {
                    return .failure(.outputRejected(reason: "empty-output"))
                }
                return .success(trimmed)
            } catch {
                if fallbackReason == nil,
                   route != nil,
                   Self.shouldRetryMemoWithoutModelRoute(errorText: String(describing: error)) {
                    // Older backends reject the modelRoute field; retry without it.
                    args.removeValue(forKey: "modelRoute")
                    route = nil
                    fallbackReason = "model_route_unsupported"
                    continue
                }
                AnalyticsManager.shared.capture("cloud_processing_failed", properties: cloudProcessingFailedProperties(
                    path: memoPath,
                    appKey: nil,
                    clientDurationMs: Self.millisecondsSince(startedAt),
                    error: error,
                    fallbackReason: fallbackReason
                ))
                SentryManager.shared.cloudProcessingError(path: memoPath, error: error)
                return .failure(CloudProcessingFailure.classify(error))
            }
        }
    }

    func processMemo(
        text: String,
        modelRoute: CloudTextModelRoute? = nil
    ) async -> String? {
        try? await processMemoDetailed(
            text: text,
            modelRoute: modelRoute
        ).get()
    }

    nonisolated static func memoProcessingTimeoutMs(for modelRoute: CloudTextModelRoute?) -> Int {
        CloudTimeouts.memo(for: modelRoute)
    }

    nonisolated static func shouldRetryMemoWithoutModelRoute(errorText: String) -> Bool {
        CloudErrorClassifier.hasExtraFieldValidationError(errorText, fields: ["modelRoute"])
    }

    func classifyJournalBlockTopic(_ block: JournalBlock) async -> String? {
        let appsDescription = (block.appsUsed ?? []).map(\.appName).joined(separator: ", ")
        let cluesDescription = (block.contextClues ?? []).prefix(8).joined(separator: ", ")
        let entrySample = block.entries.prefix(5).joined(separator: "\n")

        let prompt = """
        Infer a concrete task or workstream label for this dictation session.
        Return ONLY the label, nothing else.
        Prefer specific feature names, files, docs, customers, or conversations the user would recognize later.
        Avoid generic labels like "coding", "work", "Slack", or the app name by itself.
        Keep it to 2-5 words.

        Apps used: \(appsDescription.isEmpty ? block.appName : appsDescription)
        Context: \(cluesDescription.isEmpty ? (block.contextLabel ?? "none") : cluesDescription)
        Time: \(block.startTime.formatted(date: .omitted, time: .shortened)) - \(block.endTime.formatted(date: .omitted, time: .shortened))

        Dictation entries:
        \(entrySample)
        """

        guard let result = await processMemo(
            text: prompt,
            modelRoute: .meetingSummary
        ) else { return nil }

        // Sanitize: strip quotes, enforce 2-60 char length
        let cleaned = result
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^\"+|\"+$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count >= 2, cleaned.count <= 60 else { return nil }
        return cleaned
    }

    func summarizeJournalBlock(_ block: JournalBlock) async -> String? {
        let transcript = block.entries.joined(separator: "\n")
        guard !transcript.isEmpty else { return nil }

        let prompt = """
        Summarize this work session for a personal work journal in 1-2 sentences.
        Lead with the concrete task or outcome.
        Write from the user's perspective in past tense.
        Avoid filler and never say "the speaker", "the user", or "this session".

        Context: \(block.contextLabel ?? block.appName)
        Time: \(block.startTime.formatted(date: .omitted, time: .shortened)) - \(block.endTime.formatted(date: .omitted, time: .shortened))

        Transcript:
        \(transcript)
        """

        return Self.normalizedJournalSummary(
            from: await processMemo(text: prompt, modelRoute: .meetingSummary),
            maxSentences: 3
        )
    }

    func generateBlockAccomplishment(_ block: JournalBlock) async -> String? {
        let summaryText = block.summary ?? block.entries.joined(separator: " ")
        guard !summaryText.isEmpty else { return nil }

        let appsDescription = (block.appsUsed ?? []).map(\.appName).joined(separator: ", ")
        let topicText = block.topicLabel ?? block.contextLabel ?? block.appName

        let prompt = """
        Rewrite this work session as a single accomplishment statement.
        Focus on what was delivered, completed, decided, or made progress on.
        Write in past tense, first person implied (no "I").
        Be specific and concrete. Keep it to 1 sentence, max 20 words.
        Return ONLY the accomplishment statement, nothing else.

        Topic: \(topicText)
        Apps: \(appsDescription.isEmpty ? block.appName : appsDescription)

        Summary:
        \(summaryText)
        """

        return Self.normalizedJournalSummary(
            from: await processMemo(text: prompt, modelRoute: .meetingSummary),
            maxSentences: 2
        )
    }

    func summarizeJournalDay(blocks: [JournalBlock], date: Date) async -> String? {
        guard !blocks.isEmpty else { return nil }

        let threads = JournalDaySummaryInput.buildThreads(from: blocks)
        let dominantApps = JournalDaySummaryInput.dominantApps(from: blocks, limit: 4)

        let threadsText = threads.enumerated().map { index, thread in
            JournalDaySummaryInput.serialize(thread: thread, index: index + 1)
        }
        .joined(separator: "\n\n")

        let prompt = """
        Summarize this user's day as 4-6 concise bullet points for their daily review.

        STRICT RULES — follow every one:

        1. GROUND every bullet in the thread notes below. Never invent actions. If notes show a question or exploration, say "asked about…" or "explored…" — never "built", "shipped", "made a to-do", or "sent" unless the notes explicitly show that action.

        2. TOOLS vs. PROJECTS. The apps below are tools, not products the user is building:
           - Claude, ChatGPT, Cursor, Code (VS Code), OpenCode, Notion, Obsidian, Bear, Notes, Terminal, iTerm, Brave, Chrome, Safari, Arc, Mail, Slack, Discord.
           When the user is working IN one of these tools, describe the SUBJECT of the work (the feature, document, person, or project being worked on), NEVER the tool itself. Never write "designed Claude", "worked on Cursor", "refined Notion" — those are wrong. Instead: "Designed the review page" or "Drafted the compound engineering article."

        3. KEEP DISTINCT THREADS SEPARATE. Do NOT stitch unrelated threads together with "and" or lists. If a hackathon signup, a logo removal, and a Windows bug are three different threads, they get three different bullets (or are omitted if minor). Never combine threads that don't share clear subject matter.

        4. BALANCE across the day. If there are 4+ different projects/topics, surface different ones; do NOT cluster 3+ bullets around the same thread (e.g., all email, all one feature).

        5. USE DOMINANT APPS as a hint about where real work happened. If the user spent 2+ hours in a code editor, development work MUST appear; do not omit it in favor of comms/email. But remember rule 2 — describe the *subject* of the dev work, not the editor.

        6. BE SPECIFIC. Name the project, person, feature, or topic. Replace "responded to emails" with what the email was about. Replace "worked on project" with what was actually done.

        7. VOICE: Past tense, first-person, active voice. No filler like "Today, I…", "The user…", "Also, I…", or closing sentences.

        8. OUTPUT: One bullet per line, each starting with "- ". No numbering, no headings, no commentary.

        CONTEXT
        Date: \(date.formatted(date: .abbreviated, time: .omitted))
        Dominant apps today (by time): \(dominantApps)
        Total threads: \(threads.count)

        THREADS (pre-grouped; each represents a related chunk of work):
        \(threadsText)

        OUTPUT
        Return 4-6 bullet points, each on its own line starting with "- ". Nothing else.
        """

        let raw = await processMemo(text: prompt, modelRoute: .meetingSummary)
        return Self.normalizedBulletedSummary(from: raw, maxBullets: 6)
            ?? Self.normalizedJournalSummary(from: raw, maxSentences: 6)
    }

    // MARK: - Today brief + chat

    /// Generates a 3-paragraph narrative brief for the day.
    /// Paragraph 1: what today was about. Paragraph 2: what you said you'd do next.
    /// Paragraph 3: a pattern observed (time-of-day, topic loop, app shift).
    func generateDayBrief(blocks: [JournalBlock], date: Date) async -> String? {
        guard !blocks.isEmpty else { return nil }

        let threads = JournalDaySummaryInput.buildThreads(from: blocks)
        let dominantApps = JournalDaySummaryInput.dominantApps(from: blocks, limit: 4)
        let threadsText = threads.enumerated().map { index, thread in
            JournalDaySummaryInput.serialize(thread: thread, index: index + 1)
        }.joined(separator: "\n\n")

        let prompt = """
        You are summarizing a user's workday for their daily chat/reflection page inside Resonant — a macOS tool that captures their voice dictations (speech-to-text they spoke while working) and their meeting transcripts (audio from video calls). The threads below are real content they spoke or discussed today.

        Write a SHORT, SCANNABLE brief with 4 sections using the EXACT markdown template below. The user will re-read this tomorrow — every word has to earn its place. Second person ("you"). Past tense. No filler, no moralizing, no "Overall,", no "Today, you…", no "Great work."

        TEMPLATE (use these exact headings, in this order, no others):

        ## Lede
        One sentence, 12–20 words. Captures the essence of the day. Italicize it using *one asterisk* at start and end.

        ## What happened
        3–5 bullet points. Each bullet MUST start with "- " (a hyphen + space) on its own line — this is markdown, and bullets are non-negotiable. Each bullet: 8–16 words. Start with a concrete verb (shipped, drafted, debated, reviewed, explored, decided, sketched, paired, asked). Mention the subject of the work — the feature, document, person, project. Never describe the tool itself ("worked on Cursor") — describe what was done IN the tool ("refined the onboarding copy in Cursor"). Bold the subject using **double asterisks** so it pops. Example of the exact format:
        - Refined the **onboarding flow** copy after watching three user sessions.
        - Debated **pricing tiers** with Maya, landed on a single $15 plan.

        ## Commitments
        2–4 bullet points OR the single line "— Nothing committed today." if truly none surfaced. Each commitment bullet MUST start with "- " on its own line. Each bullet: what you said you'd do next. Pull these from explicit "I'll…", "I need to…", "Let's…", "I decided…", or meeting action items. Keep them 6–14 words. Example:
        - Send the **revised proposal** to Alex before Friday standup.
        - Decide on **auth provider** once the Clerk trial expires.

        ## Pattern
        One sentence, 12–25 words. ONE real observation about the SHAPE of the day (time of day, app shifts, topic loops, meeting cadence, focus vs scatter). Not a judgment, just a read. Examples: "Scattered across five apps before 11, then two-hour focus block in Cursor." "Three back-to-back meetings bookended the afternoon writing session." "You circled back to the onboarding flow four separate times."

        STRICT RULES:
        1. GROUND every claim in the threads. Never invent actions. If a thread shows questioning, say "asked" or "explored" — never "shipped" or "built" unless the notes show delivery.
        2. TOOLS vs. SUBJECTS. Apps (Claude, Cursor, VS Code, Notion, Slack, Chrome, Zoom) are tools, not projects. Describe the SUBJECT.
        3. BE SPECIFIC. Name the feature, document, person, customer, or topic. Replace "emails" with what the email was about.
        4. USE THE USER'S OWN WORDS from dictation snippets when a quote is punchy.
        5. OUTPUT THE TEMPLATE EXACTLY. No extra headings, no intro, no outro. Start with "## Lede".

        CONTEXT
        Date: \(date.formatted(date: .complete, time: .omitted))
        Dominant apps (by time): \(dominantApps)
        Total threads: \(threads.count)

        THREADS (pre-grouped by topic, most significant first — dictation transcripts and meeting summaries):
        \(threadsText)

        OUTPUT
        The template, filled in. Nothing else.
        """

        guard let raw = await processMemo(
            text: prompt,
            modelRoute: .meetingSummary
        ) else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Chat with the day's context. `history` is prior turns; `userMessage` is the new question.
    func chatWithDay(
        blocks: [JournalBlock],
        date: Date,
        history: [TodayChatMessage],
        userMessage: String,
        attachments: [ChatMentionAttachment] = []
    ) async -> String? {
        guard let prompt = buildChatPrompt(
            blocks: blocks,
            date: date,
            history: history,
            userMessage: userMessage,
            attachments: attachments
        ) else { return nil }

        guard let raw = await processMemo(
            text: prompt,
            modelRoute: .meetingSummary
        ) else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Builds the day-chat prompt shared by `chatWithDay` and the streaming path.
    func buildChatPrompt(
        blocks: [JournalBlock],
        date: Date,
        history: [TodayChatMessage],
        userMessage: String,
        attachments: [ChatMentionAttachment] = []
    ) -> String? {
        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

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

        let historyText = history.isEmpty
            ? "(no prior turns)"
            : history.suffix(10).map { msg in
                let label = msg.role == .user ? "USER" : "ASSISTANT"
                return "\(label): \(msg.text)"
            }.joined(separator: "\n\n")

        let attachmentsSection = Self.formatAttachments(attachments)

        return """
        You are the user's reflection partner inside Resonant — a macOS tool that captures their voice dictations (speech-to-text they spoke while working, across any app) and their meeting transcripts (audio recorded from video calls). The day context below is REAL content from their own voice today. You're helping them think about their day.

        STYLE RULES:
        - Second person ("you"). Past tense for what happened. Present for reflection/advice.
        - No preamble, no recap of the question, no "Great question", no "Based on your day…".
        - PREFER bullets or short paragraphs over long prose. Scannable beats eloquent.
        - Use **bold** to mark subjects (features, people, topics). Use markdown formatting.
        - When quoting the user, use their actual words from the transcripts, in quotes.
        - Reference specific apps and times when relevant ("in your 10:40 dictation in Cursor…").
        - Never say "the user", "the speaker", "the transcript", or "based on the context".
        - Keep it under 180 words unless the user explicitly asks for depth.
        - If the context can't answer, say so in one sentence and suggest what to ask instead.
        - When the user references a specific meeting or memo via an `@"kind: Title"` token, ground your answer in the matching REFERENCED ATTACHMENT block below.

        FORMATTING RULES:
        - Use markdown: **bold**, *italic*, `inline code`, `- ` for bullets.
        - Short paragraphs (1–3 sentences). Blank lines between them.
        - Lead with the answer. Details follow.

        DAY CONTEXT (dictation threads + meeting summaries from today)
        \(dayContext)
        \(attachmentsSection)
        PRIOR CONVERSATION
        \(historyText)

        USER MESSAGE
        \(trimmed)

        RESPONSE (markdown, concise, grounded)
        """
    }

    private static func formatAttachments(_ attachments: [ChatMentionAttachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        let blocks = attachments.map { $0.promptBlock() }.joined(separator: "\n\n")
        return """


        REFERENCED ATTACHMENTS (meetings/memos the user @-mentioned in their message)
        \(blocks)

        """
    }

    /// Stream a Groq-backed chat reply token by token.
    /// Yields incremental content deltas. Throws on auth/network/quota failure.
    func streamChat(prompt: String) -> AsyncThrowingStream<String, Error> {
        streamCloudText(
            endpointPath: "chat-stream",
            prompt: prompt,
            timeout: CloudTimeouts.chatStreamSeconds
        )
    }

    /// Stream a voice command to the Convex cloud for LLM-powered action classification.
    func streamCommandChat(prompt: String) -> AsyncThrowingStream<String, Error> {
        streamCloudText(
            endpointPath: "command-stream",
            prompt: prompt,
            timeout: CloudTimeouts.commandStreamSeconds
        )
    }

    /// Shared SSE streaming against Convex httpActions (`<deployment>.convex.site`).
    private func streamCloudText(
        endpointPath: String,
        prompt: String,
        timeout: TimeInterval
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard canPerformCloudRequest() else {
                    continuation.finish(throwing: ConvexError.httpError("Cloud processing unavailable"))
                    return
                }
                guard let userID = resolvedUserID else {
                    continuation.finish(throwing: ConvexError.httpError("No user"))
                    return
                }
                guard let token = resolvedCloudBearerToken else {
                    continuation.finish(throwing: ConvexError.httpError("No auth token"))
                    return
                }

                // Convex httpActions live at `<deployment>.convex.site`, not `.convex.cloud`.
                let siteURLString = baseURL.absoluteString
                    .replacingOccurrences(of: ".convex.cloud", with: ".convex.site")
                guard let siteURL = URL(string: siteURLString) else {
                    continuation.finish(throwing: ConvexError.httpError("Bad site URL"))
                    return
                }

                var request = URLRequest(url: siteURL.appending(path: endpointPath))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = timeout
                let bodyJSON: [String: Any] = ["userId": userID, "prompt": prompt]
                request.httpBody = try? JSONSerialization.data(withJSONObject: bodyJSON)

                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        continuation.finish(throwing: ConvexError.httpError("\(endpointPath) HTTP \(code)"))
                        return
                    }

                    for try await line in bytes.lines {
                        guard let content = Self.sseContentDelta(fromLine: line) else {
                            if Self.isSSETerminator(line) { break }
                            continue
                        }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    nonisolated static func isSSETerminator(_ line: String) -> Bool {
        line == "data: [DONE]"
    }

    /// Parses one SSE line in OpenAI delta format; returns the content chunk or nil.
    nonisolated static func sseContentDelta(fromLine line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else { return nil }
        return content
    }

    // MARK: - Output normalization helpers

    nonisolated static func normalizedJournalSummary(from text: String?, maxSentences: Int) -> String? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        var sentences: [String] = []
        cleaned.enumerateSubstrings(in: cleaned.startIndex..<cleaned.endIndex, options: .bySentences) { substring, _, _, stop in
            guard let substring else { return }
            let sentence = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return }
            sentences.append(sentence)
            if sentences.count >= maxSentences {
                stop = true
            }
        }

        if !sentences.isEmpty {
            return sentences.joined(separator: " ")
        }

        return cleaned
    }

    /// Parses an LLM response that should contain bullet points (starting with
    /// "-", "•", "*", or "1."). Returns the bullets joined by spaces so the
    /// existing SummaryBulletizer can re-split cleanly. Returns nil when the
    /// response isn't bulleted (caller falls back to sentence normalization).
    nonisolated static func normalizedBulletedSummary(from text: String?, maxBullets: Int) -> String? {
        guard let text else { return nil }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var bullets: [String] = []
        for line in lines {
            guard let bullet = stripBulletPrefix(line) else { continue }
            guard bullet.count >= 8 else { continue }
            bullets.append(ensureSentenceTerminator(bullet))
            if bullets.count >= maxBullets { break }
        }

        guard bullets.count >= 2 else { return nil }
        return bullets.joined(separator: " ")
    }

    private nonisolated static func stripBulletPrefix(_ line: String) -> String? {
        let prefixes = ["- ", "* ", "• ", "● ", "– ", "— "]
        for prefix in prefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Numbered: "1. ", "2) "
        if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return String(line[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private nonisolated static func ensureSentenceTerminator(_ text: String) -> String {
        guard let last = text.last else { return text }
        if last == "." || last == "!" || last == "?" { return text }
        return text + "."
    }
}

// MARK: - Day summary input builder

enum JournalDaySummaryInput {
    struct Thread {
        let title: String
        let appName: String
        let contextLabel: String?
        let startTime: Date
        let endTime: Date
        let totalMinutes: Int
        let totalWords: Int
        let blockCount: Int
        let isMeeting: Bool
        let summaries: [String]         // per-block summaries (deduped, trimmed)
        let rawSnippets: [String]       // 2-3 longest raw entries, truncated
    }

    /// Groups blocks into topical threads so the LLM sees pre-grouped work,
    /// making balanced coverage across projects easier.
    static func buildThreads(from blocks: [JournalBlock]) -> [Thread] {
        struct Bucket {
            var title: String
            var appName: String
            var contextLabel: String?
            var startTime: Date
            var endTime: Date
            var totalSeconds: Double
            var totalWords: Int
            var blockCount: Int
            var isMeeting: Bool
            var summaries: [String] = []
            var rawEntries: [String] = []
        }

        var buckets: [String: Bucket] = [:]
        var order: [String] = []

        for block in blocks.sorted(by: { $0.startTime < $1.startTime }) {
            let key = threadKey(for: block)
            let duration = max(block.endTime.timeIntervalSince(block.startTime), 0)

            if var bucket = buckets[key] {
                bucket.endTime = max(bucket.endTime, block.endTime)
                bucket.startTime = min(bucket.startTime, block.startTime)
                bucket.totalSeconds += duration
                bucket.totalWords += block.wordCount
                bucket.blockCount += 1
                if let summary = block.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !summary.isEmpty, !bucket.summaries.contains(summary) {
                    bucket.summaries.append(summary)
                }
                bucket.rawEntries.append(contentsOf: block.entries)
                buckets[key] = bucket
            } else {
                var bucket = Bucket(
                    title: threadTitle(for: block),
                    appName: block.appName,
                    contextLabel: block.contextLabel,
                    startTime: block.startTime,
                    endTime: block.endTime,
                    totalSeconds: duration,
                    totalWords: block.wordCount,
                    blockCount: 1,
                    isMeeting: block.isMeeting == true
                )
                if let summary = block.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !summary.isEmpty {
                    bucket.summaries.append(summary)
                }
                bucket.rawEntries.append(contentsOf: block.entries)
                buckets[key] = bucket
                order.append(key)
            }
        }

        let threads: [Thread] = order.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            let topSnippets = bucket.rawEntries
                .filter { $0.split(whereSeparator: \.isWhitespace).count >= 6 }
                .sorted { $0.count > $1.count }
                .prefix(2)
                .map { truncate($0, to: 280) }
            return Thread(
                title: bucket.title,
                appName: bucket.appName,
                contextLabel: bucket.contextLabel,
                startTime: bucket.startTime,
                endTime: bucket.endTime,
                totalMinutes: max(Int(bucket.totalSeconds / 60), 1),
                totalWords: bucket.totalWords,
                blockCount: bucket.blockCount,
                isMeeting: bucket.isMeeting,
                summaries: Array(bucket.summaries.prefix(3)),
                rawSnippets: Array(topSnippets)
            )
        }

        // Sort by significance — word count + minutes — so the LLM sees
        // heaviest threads first and prioritizes them.
        return threads.sorted { lhs, rhs in
            score(lhs) > score(rhs)
        }
    }

    static func dominantApps(from blocks: [JournalBlock], limit: Int) -> String {
        var byBundle: [String: (name: String, minutes: Double)] = [:]
        for block in blocks where block.isMeeting != true {
            let duration = max(block.endTime.timeIntervalSince(block.startTime) / 60, 1)
            let key = block.bundleId.isEmpty ? block.appName : block.bundleId
            var entry = byBundle[key] ?? (block.appName, 0)
            entry.minutes += duration
            byBundle[key] = entry
        }
        let sorted = byBundle.values
            .sorted { $0.minutes > $1.minutes }
            .prefix(limit)
        if sorted.isEmpty { return "none" }
        return sorted
            .map { "\($0.name) (\(Int($0.minutes))m)" }
            .joined(separator: ", ")
    }

    static func serialize(thread: Thread, index: Int) -> String {
        var lines: [String] = []
        var header = "[\(index)] \(thread.title)"
        if thread.isMeeting {
            header += " — MEETING"
        }
        lines.append(header)

        var metaParts: [String] = []
        metaParts.append("App: \(thread.appName)")
        if let context = thread.contextLabel, context != thread.appName {
            metaParts.append("Context: \(context)")
        }
        metaParts.append("Time: \(timeRange(from: thread.startTime, to: thread.endTime))")
        metaParts.append("Duration: \(thread.totalMinutes)m")
        metaParts.append("\(thread.totalWords) words")
        metaParts.append("\(thread.blockCount) session\(thread.blockCount == 1 ? "" : "s")")
        lines.append("  " + metaParts.joined(separator: " · "))

        if !thread.summaries.isEmpty {
            lines.append("  Summary: " + thread.summaries.joined(separator: " / "))
        }

        if !thread.rawSnippets.isEmpty {
            for snippet in thread.rawSnippets {
                lines.append("  • \"\(snippet)\"")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func threadKey(for block: JournalBlock) -> String {
        if block.isMeeting == true {
            return "meeting::\(block.meetingTitle ?? block.contextLabel ?? block.appName)"
        }
        if let topic = block.topicLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !topic.isEmpty {
            return "topic::\(topic.lowercased())"
        }
        if let context = block.contextLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !context.isEmpty, context != block.appName {
            return "ctx::\(block.bundleId.lowercased())::\(context.lowercased())"
        }
        return "app::\(block.bundleId.lowercased())"
    }

    private static func threadTitle(for block: JournalBlock) -> String {
        if block.isMeeting == true {
            return block.meetingTitle ?? block.contextLabel ?? "\(block.appName) meeting"
        }
        if let topic = block.topicLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !topic.isEmpty {
            return topic
        }
        if let context = block.contextLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !context.isEmpty, context != block.appName {
            return "\(block.appName): \(context)"
        }
        return block.appName
    }

    private static func score(_ thread: Thread) -> Double {
        let minutesWeight = min(Double(thread.totalMinutes), 240) * 1.0
        let wordsWeight = min(Double(thread.totalWords), 2_000) * 0.08
        let meetingBonus = thread.isMeeting ? 20.0 : 0.0
        return minutesWeight + wordsWeight + meetingBonus
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)) + "…"
    }

    private static func timeRange(from start: Date, to end: Date) -> String {
        let startStr = start.formatted(date: .omitted, time: .shortened)
        let endStr = end.formatted(date: .omitted, time: .shortened)
        return "\(startStr) – \(endStr)"
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
