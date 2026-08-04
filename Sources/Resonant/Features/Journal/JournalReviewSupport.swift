import Foundation

struct JournalDictationSnapshot: Sendable, Equatable {
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
    let mode: String
    let date: Date

    init(entry: DictationEntry) {
        id = entry.id
        text = entry.text
        appName = entry.appName
        bundleId = entry.bundleId
        windowTitle = entry.windowTitle
        browserURL = entry.browserURL
        codeFileName = entry.codeFileName
        slackRecipient = entry.slackRecipient
        wordCount = entry.wordCount
        duration = entry.duration
        mode = entry.mode
        date = entry.date
    }
}

struct JournalMeetingSnapshot: Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let detectedApp: String?
    let customTitle: String?
    let durationSeconds: Double
    let wordCount: Int
    let activeJSONLPath: String?
    let userNotes: String?
    let postMeetingNotes: String?
    let summary: String?
    let recordingOriginRaw: String?

    init(entry: MeetingEntry) {
        id = entry.id
        startedAt = entry.startedAt
        endedAt = entry.endedAt
        detectedApp = entry.detectedApp
        customTitle = entry.customTitle
        durationSeconds = entry.durationSeconds
        wordCount = entry.wordCount
        activeJSONLPath = entry.activeJSONLPath
        userNotes = entry.userNotes
        postMeetingNotes = entry.postMeetingNotes
        summary = entry.summary
        recordingOriginRaw = entry.recordingOriginRaw
    }

    var displayTitle: String {
        if let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return fallbackMeetingTitle(
            detectedApp: detectedApp,
            recordingOrigin: recordingOriginRaw.flatMap(MeetingRecordingOrigin.init(rawValue:))
        )
    }
}

enum JournalBlockOrganizer {
    private static let regroupGraceWindow: TimeInterval = 5 * 60

    static func buildBlocks(from entries: [DictationEntry], blockGap: TimeInterval) -> [JournalBlock] {
        buildBlocks(from: entries.map(JournalDictationSnapshot.init(entry:)), blockGap: blockGap)
    }

    static func buildBlocks(from entries: [JournalDictationSnapshot], blockGap: TimeInterval) -> [JournalBlock] {
        guard let first = entries.first else { return [] }

        var clusters: [[JournalDictationSnapshot]] = [[first]]

        for entry in entries.dropFirst() {
            if shouldAppend(entry, to: clusters[clusters.count - 1], blockGap: blockGap) {
                clusters[clusters.count - 1].append(entry)
            } else {
                clusters.append([entry])
            }
        }

        return clusters.map(buildBlock(from:))
    }

    static func extractiveSummary(from texts: [String], maxSentences: Int = 3) -> String {
        var sentences: [String] = []
        var seen = Set<String>()

        for text in texts {
            let sentence = firstSentence(in: text)
            let normalized = normalize(sentence)
            guard !sentence.isEmpty, !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            sentences.append(sentence)
            if sentences.count >= maxSentences { break }
        }

        return sentences.joined(separator: " ")
    }

    static func extractiveDaySummary(from blocks: [JournalBlock]) -> String {
        let summaries = blocks.compactMap { nonEmpty($0.summary) }
        if !summaries.isEmpty {
            return Array(summaries.prefix(3)).joined(separator: " ")
        }
        return extractiveSummary(from: blocks.flatMap(\.entries), maxSentences: 4)
    }

    private static func shouldAppend(
        _ entry: JournalDictationSnapshot,
        to cluster: [JournalDictationSnapshot],
        blockGap: TimeInterval
    ) -> Bool {
        guard let previous = cluster.last else { return true }

        let gap = entry.date.timeIntervalSince(previous.date)
        guard gap <= blockGap else { return false }
        guard sharesPrimarySurface(previous, entry) else { return false }

        let previousContext = groupingContext(for: previous)
        let nextContext = groupingContext(for: entry)

        switch (previousContext, nextContext) {
        case let (.codeFile(lhs), .codeFile(rhs)):
            return normalizeFileStem(lhs) == normalizeFileStem(rhs) || gap <= regroupGraceWindow

        case let (.slackRecipient(lhs), .slackRecipient(rhs)):
            return normalize(lhs) == normalize(rhs)

        case let (.browserHost(lhs), .browserHost(rhs)):
            return normalize(lhs) == normalize(rhs)

        case let (.windowTitle(lhs), .windowTitle(rhs)):
            return normalize(lhs) == normalize(rhs) || gap <= regroupGraceWindow

        case (.app, .app):
            return true

        case let (lhs, rhs):
            return !(lhs.isStrong && rhs.isStrong)
        }
    }

    private static func sharesPrimarySurface(_ lhs: JournalDictationSnapshot, _ rhs: JournalDictationSnapshot) -> Bool {
        if let leftBundleID = nonEmpty(lhs.bundleId), let rightBundleID = nonEmpty(rhs.bundleId) {
            return normalize(leftBundleID) == normalize(rightBundleID)
        }
        return normalize(lhs.appName) == normalize(rhs.appName)
    }

    private static func buildBlock(from entries: [JournalDictationSnapshot]) -> JournalBlock {
        let primary = entries.max(by: { contextScore(for: $0) < contextScore(for: $1) }) ?? entries[0]
        let texts = entries.map(\.text)

        let grouped = Dictionary(grouping: entries) { $0.bundleId }
        let appsUsed = grouped.map { _, group -> BlockAppInfo in
            BlockAppInfo(
                appName: nonEmpty(group.first?.appName) ?? "Resonant",
                bundleId: group.first?.bundleId ?? "",
                entryCount: group.count,
                wordCount: group.reduce(0) { $0 + wordCount(in: $1.text) }
            )
        }
        .sorted { $0.wordCount > $1.wordCount }

        var clues: [String] = []
        for entry in entries {
            if let code = nonEmpty(entry.codeFileName) { clues.append(code) }
            if let recipient = nonEmpty(entry.slackRecipient) { clues.append(recipient) }
            if let url = nonEmpty(entry.browserURL), let host = URL(string: url)?.host.flatMap(nonEmpty) { clues.append(host) }
            if let title = nonEmpty(entry.windowTitle) {
                clues.append(cleanedWindowTitle(title, appName: entry.appName))
            }
        }
        let uniqueClues = clues.reduce(into: [String]()) { result, clue in
            if !result.contains(clue) {
                result.append(clue)
            }
        }

        return JournalBlock(
            appName: nonEmpty(primary.appName) ?? "Resonant",
            bundleId: primary.bundleId,
            contextLabel: improvedContextLabel(for: entries, primary: primary),
            entries: texts,
            startTime: entries.first?.date ?? Date(),
            endTime: entries.last?.date ?? Date(),
            summary: extractiveSummary(from: texts),
            wordCount: texts.reduce(0) { $0 + wordCount(in: $1) },
            appsUsed: appsUsed,
            contextClues: uniqueClues.isEmpty ? nil : uniqueClues
        )
    }

    private static func improvedContextLabel(
        for entries: [JournalDictationSnapshot],
        primary: JournalDictationSnapshot
    ) -> String? {
        for entry in entries {
            if let code = nonEmpty(entry.codeFileName) { return code }
        }

        for entry in entries {
            if let recipient = nonEmpty(entry.slackRecipient) { return recipient }
        }

        for entry in entries {
            if let url = nonEmpty(entry.browserURL),
               let host = URL(string: url)?.host.flatMap(nonEmpty) {
                if let title = nonEmpty(entry.windowTitle) {
                    let cleaned = cleanedWindowTitle(title, appName: entry.appName)
                    if !cleaned.isEmpty, cleaned != entry.appName { return cleaned }
                }
                return host
            }
        }

        for entry in entries {
            if let title = nonEmpty(entry.windowTitle) {
                let cleaned = cleanedWindowTitle(title, appName: entry.appName)
                if !cleaned.isEmpty, cleaned != entry.appName { return cleaned }
            }
        }

        return nonEmpty(primary.appName)
    }

    private static func cleanedWindowTitle(_ title: String, appName: String) -> String {
        let separators = [" — ", " -- ", " - ", " | "]
        for separator in separators {
            let parts = title.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }
            let last = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if last.localizedCaseInsensitiveCompare(appName) == .orderedSame
                || last.localizedCaseInsensitiveContains(appName) {
                return parts.dropLast().joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return title
    }

    private static func groupingContext(for entry: JournalDictationSnapshot) -> GroupingContext {
        if let code = nonEmpty(entry.codeFileName) {
            return .codeFile(code)
        }
        if let recipient = nonEmpty(entry.slackRecipient) {
            return .slackRecipient(recipient)
        }
        if let url = nonEmpty(entry.browserURL),
           let host = URL(string: url)?.host.flatMap(nonEmpty) {
            return .browserHost(host)
        }
        if let title = nonEmpty(entry.windowTitle) {
            return .windowTitle(cleanedWindowTitle(title, appName: entry.appName))
        }
        return .app
    }

    private static func contextScore(for entry: JournalDictationSnapshot) -> Int {
        switch groupingContext(for: entry) {
        case .codeFile:
            return 4
        case .slackRecipient:
            return 3
        case .browserHost:
            return 2
        case .windowTitle:
            return 1
        case .app:
            return 0
        }
    }

    private static func firstSentence(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let range = trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) {
            let sentence = String(trimmed[..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.count > 160 ? truncate(sentence, limit: 160) : sentence
        }

        return trimmed.count > 160 ? truncate(trimmed, limit: 160) : trimmed
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let truncated = String(text.prefix(limit))
        return truncated.replacingOccurrences(of: "\\s+\\S*$", with: "", options: .regularExpression) + "..."
    }

    private static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeFileStem(_ text: String) -> String {
        let stem = URL(fileURLWithPath: text).deletingPathExtension().lastPathComponent
        return normalize(stem)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}

private extension JournalBlockOrganizer {
    enum GroupingContext {
        case codeFile(String)
        case slackRecipient(String)
        case browserHost(String)
        case windowTitle(String)
        case app

        var isStrong: Bool {
            switch self {
            case .codeFile, .slackRecipient, .browserHost:
                return true
            case .windowTitle, .app:
                return false
            }
        }
    }
}

struct JournalAccomplishment: Identifiable, Equatable {
    let id: UUID
    let title: String
    let detail: String?
    let primaryBundleId: String
    let appNames: [String]
    let startTime: Date
    let endTime: Date
    let duration: TimeInterval
    let sessionCount: Int
    let wordCount: Int
}

enum JournalReviewEngine {
    private static let fillerPrefixes = [
        "the work session focused on ",
        "the work session involved ",
        "the work session reviewed ",
        "the work session covered ",
        "the work session was about ",
        "the user worked on ",
        "the user focused on ",
        "the user reviewed ",
        "the user discussed ",
        "the speaker decided to ",
        "the speaker mentioned ",
        "the speaker discussed ",
        "the speaker talked about ",
        "during this session, ",
        "in this session, ",
        "this session focused on ",
        "this session covered ",
        "worked on "
    ]

    static func taskTitle(for block: JournalBlock) -> String {
        if block.isMeeting == true {
            return nonEmpty(block.meetingTitle)
                ?? nonEmpty(block.contextLabel)
                ?? "Meeting"
        }
        return nonEmpty(block.topicLabel)
            ?? nonEmpty(block.contextLabel)
            ?? nonEmpty(block.appName)
            ?? "Untitled task"
    }

    static func cleanedSummary(for block: JournalBlock) -> String? {
        cleanedSummaryText(block.summary)
    }

    static func accomplishmentHighlights(from blocks: [JournalBlock], limit: Int = 4) -> [JournalAccomplishment] {
        guard limit > 0 else { return [] }

        var groups: [AccomplishmentCandidate] = []
        var indexByKey: [String: Int] = [:]

        for block in blocks.sorted(by: { $0.startTime < $1.startTime }) {
            let candidate = candidate(for: block)
            if let key = mergeKey(for: block, title: candidate.accomplishment.title),
               let existingIndex = indexByKey[key] {
                groups[existingIndex].merge(with: candidate)
            } else {
                groups.append(candidate)
                if let key = mergeKey(for: block, title: candidate.accomplishment.title) {
                    indexByKey[key] = groups.count - 1
                }
            }
        }

        return groups
            .sorted {
                if $0.score == $1.score {
                    return $0.startTime < $1.startTime
                }
                return $0.score > $1.score
            }
            .prefix(limit)
            .sorted { $0.startTime < $1.startTime }
            .map(\.accomplishment)
    }

    private static func candidate(for block: JournalBlock) -> AccomplishmentCandidate {
        let title = taskTitle(for: block)
        let detail = accomplishmentDetail(for: block, title: title)
        let duration = max(block.endTime.timeIntervalSince(block.startTime), 0)
        let appNames = block.appsUsed?.map(\.appName).filter { !$0.isEmpty } ?? [block.appName]
        let score = significanceScore(for: block, detail: detail)

        return AccomplishmentCandidate(
            accomplishment: JournalAccomplishment(
                id: block.id,
                title: title,
                detail: detail,
                primaryBundleId: nonEmpty(block.bundleId) ?? block.appName,
                appNames: uniqueAppNames(from: appNames),
                startTime: block.startTime,
                endTime: block.endTime,
                duration: duration,
                sessionCount: 1,
                wordCount: block.wordCount
            ),
            score: score
        )
    }

    private static func accomplishmentDetail(for block: JournalBlock, title: String) -> String? {
        let source = cleanedSummaryText(block.accomplishment)
            ?? cleanedSummaryText(block.summary)
            ?? cleanedSummaryText(JournalBlockOrganizer.extractiveSummary(from: block.entries, maxSentences: 1))
        guard var detail = source else { return nil }

        let detailLower = detail.lowercased()
        let titleLower = title.lowercased()
        if detailLower.hasPrefix(titleLower) {
            detail = String(detail.dropFirst(title.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " :-–—,."))
        }

        guard let trimmed = nonEmpty(detail) else { return nil }
        guard normalize(trimmed) != normalize(title) else { return nil }
        return trimmed
    }

    private static func cleanedSummaryText(_ text: String?) -> String? {
        guard var cleaned = nonEmpty(text)?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) else {
            return nil
        }

        var lowercased = cleaned.lowercased()
        var strippedPrefix = true

        while strippedPrefix {
            strippedPrefix = false
            for prefix in fillerPrefixes where lowercased.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                lowercased = cleaned.lowercased()
                strippedPrefix = true
                break
            }
        }

        guard var normalized = nonEmpty(cleaned) else { return nil }
        if let first = normalized.first, first.isLowercase {
            normalized = first.uppercased() + normalized.dropFirst()
        }
        return normalized
    }

    private static func mergeKey(for block: JournalBlock, title: String) -> String? {
        guard let topic = nonEmpty(block.topicLabel) else { return nil }
        let normalizedTopic = normalize(topic)
        guard normalizedTopic.count >= 6 else { return nil }
        guard normalizedTopic != normalize(block.appName) else { return nil }
        guard normalizedTopic == normalize(title) else { return nil }
        return normalizedTopic
    }

    private static func significanceScore(for block: JournalBlock, detail: String?) -> Double {
        let durationMinutes = max(block.endTime.timeIntervalSince(block.startTime), 0) / 60
        var score = min(Double(block.wordCount), 180) / 18
        score += min(durationMinutes, 90) / 18
        if detail != nil {
            score += 1.4
        }
        if nonEmpty(block.topicLabel) != nil {
            score += 0.8
        }
        if (block.appsUsed?.count ?? 0) > 1 {
            score += 0.3
        }
        return score
    }

    private static func uniqueAppNames(from names: [String]) -> [String] {
        names.reduce(into: [String]()) { result, name in
            guard let trimmed = nonEmpty(name), !result.contains(trimmed) else { return }
            result.append(trimmed)
        }
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}

private struct AccomplishmentCandidate {
    var accomplishment: JournalAccomplishment
    var score: Double

    var startTime: Date { accomplishment.startTime }

    mutating func merge(with other: AccomplishmentCandidate) {
        let mergedApps = (accomplishment.appNames + other.accomplishment.appNames)
            .reduce(into: [String]()) { result, appName in
                if !result.contains(appName) {
                    result.append(appName)
                }
            }

        accomplishment = JournalAccomplishment(
            id: accomplishment.id,
            title: accomplishment.title,
            detail: betterDetail(current: accomplishment.detail, incoming: other.accomplishment.detail),
            primaryBundleId: accomplishment.primaryBundleId,
            appNames: mergedApps,
            startTime: min(accomplishment.startTime, other.accomplishment.startTime),
            endTime: max(accomplishment.endTime, other.accomplishment.endTime),
            duration: accomplishment.duration + other.accomplishment.duration,
            sessionCount: accomplishment.sessionCount + other.accomplishment.sessionCount,
            wordCount: accomplishment.wordCount + other.accomplishment.wordCount
        )
        score += other.score
    }

    private func betterDetail(current: String?, incoming: String?) -> String? {
        switch (current, incoming) {
        case let (current?, incoming?):
            return incoming.count > current.count ? incoming : current
        case (.none, let incoming?):
            return incoming
        case (let current?, .none):
            return current
        case (.none, .none):
            return nil
        }
    }
}

// MARK: - Day Review helpers (lede, commitments, captures)

struct DayCommitment: Identifiable, Equatable {
    let id: UUID
    let text: String
    let appName: String
    let bundleId: String
    let time: Date
    let kind: Kind

    enum Kind: String {
        case commitment   // "I should…", "I'll…", "need to…"
        case decision     // "Let's…", "going with…"
        case question     // "what if…", "should I…"
    }
}

struct DayCapture: Identifiable, Equatable {
    let id: UUID
    let text: String
    let appName: String
    let bundleId: String
    let time: Date
    let wordCount: Int
}

struct DayShape {
    struct AppSlice: Identifiable {
        let id: String        // bundleId
        let appName: String
        let bundleId: String
        let minutes: Int
        let wordCount: Int
    }

    let slices: [AppSlice]    // sorted desc by minutes
    let totalMinutes: Int
    let meetingCount: Int
    let sessionCount: Int
    let dictationCount: Int
    let totalWords: Int
}

enum DayReviewEngine {
    // MARK: Lede

    /// One-line characterization of the day: "Shipping + writing day", "Meeting-heavy", etc.
    static func characterization(for shape: DayShape) -> String {
        if shape.totalMinutes == 0 { return "Quiet day." }

        let top = Array(shape.slices.prefix(3))
        let categories = top.map { category(forBundleId: $0.bundleId, appName: $0.appName) }.uniqued()

        let meetingHeavy = shape.meetingCount >= 3
            || (shape.meetingCount > 0 && Double(shape.meetingCount * 30) > Double(shape.totalMinutes) * 0.4)

        var descriptors: [String] = []
        if meetingHeavy { descriptors.append("meeting-heavy") }

        for category in categories.prefix(2) {
            descriptors.append(category.label)
        }

        if descriptors.isEmpty {
            return "Mixed work day."
        }

        let joined = descriptors.joined(separator: " + ")
        return joined.prefix(1).uppercased() + joined.dropFirst() + " day."
    }

    /// Dominant category for the day — used to tint the lede.
    static func dominantCategoryKey(for shape: DayShape) -> String {
        guard let top = shape.slices.first else { return "other" }
        if shape.meetingCount >= 3
            || (shape.meetingCount > 0 && Double(shape.meetingCount * 30) > Double(shape.totalMinutes) * 0.4) {
            return "meetings"
        }
        return category(forBundleId: top.bundleId, appName: top.appName).key
    }

    // MARK: Time shape

    static func shape(for blocks: [JournalBlock]) -> DayShape {
        var minutesByBundle: [String: (app: String, mins: Int, words: Int)] = [:]
        var meetingCount = 0
        var sessionCount = 0
        var dictationCount = 0
        var totalWords = 0
        var totalMinutes = 0

        for block in blocks {
            let durationMins = max(Int(block.endTime.timeIntervalSince(block.startTime) / 60), 1)
            totalMinutes += durationMins
            totalWords += block.wordCount
            if block.isMeeting == true {
                meetingCount += 1
            } else {
                sessionCount += 1
                dictationCount += block.entries.count
            }
            let key = block.bundleId.journalTrimmed ?? block.appName
            var current = minutesByBundle[key] ?? (block.appName, 0, 0)
            current.mins += durationMins
            current.words += block.wordCount
            minutesByBundle[key] = current
        }

        let slices = minutesByBundle
            .map { DayShape.AppSlice(id: $0.key, appName: $0.value.app, bundleId: $0.key, minutes: $0.value.mins, wordCount: $0.value.words) }
            .sorted { $0.minutes > $1.minutes }

        return DayShape(
            slices: slices,
            totalMinutes: totalMinutes,
            meetingCount: meetingCount,
            sessionCount: sessionCount,
            dictationCount: dictationCount,
            totalWords: totalWords
        )
    }

    // MARK: Commitments & decisions (regex-mined from dictation text)

    private static let commitmentPatterns: [(regex: NSRegularExpression, kind: DayCommitment.Kind)] = {
        func compile(_ pattern: String) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        return [
            (compile(#"(?:^|[.!?\n]\s*)(i(?:'| a)?ll\b[^.!?\n]{8,200}[.!?])"#), .commitment),
            (compile(#"(?:^|[.!?\n]\s*)(i(?:'m| am) going to\b[^.!?\n]{8,200}[.!?])"#), .commitment),
            (compile(#"(?:^|[.!?\n]\s*)(i (?:should|need to|have to|want to|must)\b[^.!?\n]{8,200}[.!?])"#), .commitment),
            (compile(#"(?:^|[.!?\n]\s*)(we (?:should|need to|have to)\b[^.!?\n]{8,200}[.!?])"#), .commitment),
            (compile(#"(?:^|[.!?\n]\s*)(let'?s\b[^.!?\n]{8,200}[.!?])"#), .decision),
            (compile(#"(?:^|[.!?\n]\s*)(i (?:decided|chose|picked|went with|committed)[^.!?\n]{5,200}[.!?])"#), .decision),
            (compile(#"(?:^|[.!?\n]\s*)((?:remind me to|todo:|todo )\b[^.!?\n]{5,200}[.!?])"#), .commitment),
        ]
    }()

    /// Mines up to `limit` commitment/decision sentences from a day's blocks.
    /// Deduplicates by normalized text; prefers longest variant; preserves chronological order.
    static func commitments(from blocks: [JournalBlock], limit: Int = 6) -> [DayCommitment] {
        struct Match {
            let text: String
            let kind: DayCommitment.Kind
            let appName: String
            let bundleId: String
            let time: Date
        }

        var matches: [Match] = []
        for block in blocks where block.isMeeting != true {
            for entry in block.entries {
                let searchText = entry as NSString
                let range = NSRange(location: 0, length: searchText.length)
                for (regex, kind) in commitmentPatterns {
                    let results = regex.matches(in: entry, options: [], range: range)
                    for result in results where result.numberOfRanges >= 2 {
                        let captured = searchText.substring(with: result.range(at: 1))
                        let trimmed = captured.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.count >= 12 else { continue }
                        matches.append(Match(
                            text: polishSentence(trimmed),
                            kind: kind,
                            appName: block.appName,
                            bundleId: block.bundleId,
                            time: block.startTime
                        ))
                    }
                }
            }
        }

        // Dedupe by normalized text, prefer longest
        var bucket: [String: Match] = [:]
        for match in matches {
            let key = normalizeForDedup(match.text)
            if let existing = bucket[key] {
                if match.text.count > existing.text.count {
                    bucket[key] = match
                }
            } else {
                bucket[key] = match
            }
        }

        return bucket.values
            .sorted { $0.time < $1.time }
            .prefix(limit)
            .map { DayCommitment(
                id: UUID(),
                text: $0.text,
                appName: $0.appName,
                bundleId: $0.bundleId,
                time: $0.time,
                kind: $0.kind
            )}
    }

    // MARK: Captures (longest, most-substantive dictations)

    static func captures(from blocks: [JournalBlock], limit: Int = 5) -> [DayCapture] {
        var candidates: [DayCapture] = []
        for block in blocks where block.isMeeting != true {
            for entry in block.entries {
                let words = entry.split(whereSeparator: \.isWhitespace).count
                guard words >= 30 else { continue }
                candidates.append(DayCapture(
                    id: UUID(),
                    text: entry,
                    appName: block.appName,
                    bundleId: block.bundleId,
                    time: block.startTime,
                    wordCount: words
                ))
            }
        }
        return candidates
            .sorted { $0.wordCount > $1.wordCount }
            .prefix(limit)
            .sorted { $0.time < $1.time }
    }

    // MARK: Helpers

    private struct Category: Equatable {
        let key: String
        let label: String
    }

    private static func category(forBundleId bundleId: String, appName: String) -> Category {
        let bid = bundleId.lowercased()
        let name = appName.lowercased()

        if bid.contains("xcode") || bid.contains("vscode") || bid.contains("visualstudio")
            || name.contains("opencode") || name.contains("cursor") || bid.contains("jetbrains")
            || bid.contains("iterm") || bid.contains("terminal") || bid.contains("ghostty") {
            return Category(key: "code", label: "shipping")
        }
        if bid.contains("slack") || bid.contains("linear") || bid.contains("discord")
            || bid.contains("mail") || bid.contains("gmail") || bid.contains("superhuman") {
            return Category(key: "comms", label: "comms")
        }
        if bid.contains("notion") || bid.contains("obsidian") || bid.contains("bear")
            || bid.contains("notes") || bid.contains("craft") || name.contains("claude")
            || name.contains("chatgpt") {
            return Category(key: "writing", label: "writing")
        }
        if bid.contains("chrome") || bid.contains("safari") || bid.contains("arc")
            || bid.contains("brave") || bid.contains("firefox") {
            return Category(key: "browsing", label: "research")
        }
        if bid.contains("figma") || bid.contains("sketch") {
            return Category(key: "design", label: "design")
        }
        return Category(key: "other", label: appName.lowercased())
    }

    private static func polishSentence(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if let first = cleaned.first, first.isLowercase {
            cleaned = first.uppercased() + cleaned.dropFirst()
        }
        if !cleaned.hasSuffix(".") && !cleaned.hasSuffix("!") && !cleaned.hasSuffix("?") {
            cleaned += "."
        }
        return cleaned
    }

    private static func normalizeForDedup(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]+", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .prefix(10)
            .joined(separator: " ")
    }
}

private extension Array where Element: Equatable {
    func uniqued() -> [Element] {
        reduce(into: []) { result, item in
            if !result.contains(item) { result.append(item) }
        }
    }
}
