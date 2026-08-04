import Foundation
import SwiftData

// MARK: - Shared JSON helpers

func encodeJSONStringArray(_ values: [String]?) -> String? {
    guard let values, !values.isEmpty,
          let data = try? JSONEncoder().encode(values) else { return nil }
    return String(data: data, encoding: .utf8)
}

func decodeJSONStringArray(_ json: String?) -> [String] {
    guard let json, let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return decoded
}

func encodeJSONStringDictionary(_ values: [String: String]?) -> String? {
    let normalized = MeetingSpeakerAliasResolver.normalized(values ?? [:])
    guard !normalized.isEmpty,
          let data = try? JSONEncoder().encode(normalized) else { return nil }
    return String(data: data, encoding: .utf8)
}

func decodeJSONStringDictionary(_ json: String?) -> [String: String] {
    guard let json, let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return MeetingSpeakerAliasResolver.normalized(decoded)
}

// MARK: - Dictation history

@Model
final class DictationEntry {
    var id: UUID
    var externalID: String?
    var text: String
    var appName: String
    var bundleId: String
    var windowTitle: String?
    var browserURL: String?
    var codeFileName: String?
    var slackRecipient: String?
    var wordCount: Int
    var duration: TimeInterval
    var mode: String          // DictationMode.rawValue
    var date: Date

    // Archive-enriched fields (all optional for backward compat)
    var audioPath: String?
    var rawTranscript: String?
    var deliveredText: String?
    var selectedText: String?
    var autoPasted: Bool?
    var copiedToClipboard: Bool?
    var autoSent: Bool?
    var focusedFieldContent: String?
    var visibleTextSnippetsJSON: String?   // JSON-encoded [String]
    /// JSON-encoded `VocabularyBoostAuditSummary`. Optional and local-only so
    /// existing stores migrate with nil and corrupt payloads fail open.
    var vocabularyBoostAuditJSON: Data?

    var visibleTextSnippets: [String] {
        decodeJSONStringArray(visibleTextSnippetsJSON)
    }

    var vocabularyBoostAuditSummary: VocabularyBoostAuditSummary? {
        get { VocabularyBoostAuditSummary.decode(from: vocabularyBoostAuditJSON) }
        set { vocabularyBoostAuditJSON = newValue?.encodedData() }
    }

    init(id: UUID, text: String, appName: String, bundleId: String,
         windowTitle: String? = nil, browserURL: String? = nil,
         codeFileName: String? = nil, slackRecipient: String? = nil,
         wordCount: Int, duration: TimeInterval, mode: DictationMode, date: Date,
         audioPath: String? = nil, rawTranscript: String? = nil,
         deliveredText: String? = nil, selectedText: String? = nil,
         autoPasted: Bool? = nil, copiedToClipboard: Bool? = nil,
         autoSent: Bool? = nil,
         focusedFieldContent: String? = nil,
         visibleTextSnippetsJSON: String? = nil,
         vocabularyBoostAuditSummary: VocabularyBoostAuditSummary? = nil,
         externalID: String? = nil) {
        self.id = id
        self.externalID = externalID
        self.text = text
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.codeFileName = codeFileName
        self.slackRecipient = slackRecipient
        self.wordCount = wordCount
        self.duration = duration
        self.mode = mode.rawValue
        self.date = date
        self.audioPath = audioPath
        self.rawTranscript = rawTranscript
        self.deliveredText = deliveredText
        self.selectedText = selectedText
        self.autoPasted = autoPasted
        self.copiedToClipboard = copiedToClipboard
        self.autoSent = autoSent
        self.focusedFieldContent = focusedFieldContent
        self.visibleTextSnippetsJSON = visibleTextSnippetsJSON
        self.vocabularyBoostAuditJSON = vocabularyBoostAuditSummary?.encodedData()
    }

    var dictationMode: DictationMode {
        DictationMode(rawValue: mode) ?? .dictation
    }
}

// MARK: - Voice memos

@Model
final class MemoEntry {
    var id: UUID
    var externalID: String?
    var text: String
    var title: String
    var distilledText: String?
    var duration: TimeInterval
    var date: Date
    var audioPath: String?    // relative path under ~/Library/Application Support/Resonant/audio/

    init(id: UUID, text: String, title: String, duration: TimeInterval,
         date: Date,
         audioPath: String? = nil,
         distilledText: String? = nil,
         externalID: String? = nil) {
        self.id = id
        self.externalID = externalID
        self.text = text
        self.title = title
        self.distilledText = distilledText
        self.duration = duration
        self.date = date
        self.audioPath = audioPath
    }

    var displayTitle: String {
        title.isEmpty ? String(text.prefix(50)) : title
    }
}

// MARK: - Meeting recordings

@Model
final class MeetingEntry {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var detectedApp: String?
    var customTitle: String?
    var durationSeconds: Double
    var wordCount: Int
    var markdownPath: String?
    var audioPath: String?
    var activeJSONLPath: String?
    var userNotes: String?
    var postMeetingNotes: String?
    var summary: String?
    var calendarEventID: String?
    var scheduledStartAt: Date?
    var scheduledEndAt: Date?
    var organizerName: String?
    var attendeeNamesJSON: String?
    var attendeeEmailsJSON: String?
    var speakerAliasesJSON: String?
    var conferencingURL: String?
    var calendarName: String?
    var recordingOriginRaw: String?
    var distilledSummary: String?

    init(id: UUID, startedAt: Date, endedAt: Date? = nil,
         detectedApp: String? = nil, customTitle: String? = nil, durationSeconds: Double = 0,
         wordCount: Int = 0, markdownPath: String? = nil,
         audioPath: String? = nil, activeJSONLPath: String? = nil,
         userNotes: String? = nil, postMeetingNotes: String? = nil,
         summary: String? = nil,
         calendarEventID: String? = nil,
         scheduledStartAt: Date? = nil,
         scheduledEndAt: Date? = nil,
         organizerName: String? = nil,
         attendeeNamesJSON: String? = nil,
         attendeeEmailsJSON: String? = nil,
         speakerAliasesJSON: String? = nil,
         conferencingURL: String? = nil,
         calendarName: String? = nil,
         recordingOriginRaw: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.detectedApp = detectedApp
        self.customTitle = customTitle
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.markdownPath = markdownPath
        self.audioPath = audioPath
        self.activeJSONLPath = activeJSONLPath
        self.userNotes = userNotes
        self.postMeetingNotes = postMeetingNotes
        self.summary = summary
        self.calendarEventID = calendarEventID
        self.scheduledStartAt = scheduledStartAt
        self.scheduledEndAt = scheduledEndAt
        self.organizerName = organizerName
        self.attendeeNamesJSON = attendeeNamesJSON
        self.attendeeEmailsJSON = attendeeEmailsJSON
        self.speakerAliasesJSON = speakerAliasesJSON
        self.conferencingURL = conferencingURL
        self.calendarName = calendarName
        self.recordingOriginRaw = recordingOriginRaw
    }

    var attendeeNames: [String] {
        decodeJSONStringArray(attendeeNamesJSON)
    }

    var attendeeEmails: [String] {
        decodeJSONStringArray(attendeeEmailsJSON)
    }

    var speakerAliases: MeetingSpeakerAliasMap {
        get {
            decodeJSONStringDictionary(speakerAliasesJSON)
        }
        set {
            speakerAliasesJSON = encodeJSONStringDictionary(newValue)
        }
    }

    var recordingOrigin: MeetingRecordingOrigin? {
        get {
            guard let recordingOriginRaw else { return nil }
            return MeetingRecordingOrigin(rawValue: recordingOriginRaw)
        }
        set {
            recordingOriginRaw = newValue?.rawValue
        }
    }

    var captureContext: MeetingCaptureContext? {
        guard calendarEventID != nil
            || scheduledStartAt != nil
            || scheduledEndAt != nil
            || organizerName?.isEmpty == false
            || !attendeeNames.isEmpty
            || !attendeeEmails.isEmpty
            || conferencingURL?.isEmpty == false
            || calendarName?.isEmpty == false
            || customTitle?.isEmpty == false
            || recordingOrigin != nil
        else {
            return nil
        }

        return MeetingCaptureContext(
            calendarEventID: calendarEventID,
            scheduledStartAt: scheduledStartAt,
            scheduledEndAt: scheduledEndAt,
            organizerName: organizerName,
            attendeeNames: attendeeNames,
            attendeeEmails: attendeeEmails,
            conferencingURL: conferencingURL,
            calendarName: calendarName,
            title: customTitle,
            recordingOrigin: recordingOrigin ?? .manual
        )
    }

    func applyCaptureContext(_ context: MeetingCaptureContext?) {
        calendarEventID = context?.calendarEventID
        scheduledStartAt = context?.scheduledStartAt
        scheduledEndAt = context?.scheduledEndAt
        organizerName = context?.organizerName
        attendeeNamesJSON = encodeJSONStringArray(context?.attendeeNames)
        attendeeEmailsJSON = encodeJSONStringArray(context?.attendeeEmails)
        conferencingURL = context?.conferencingURL
        calendarName = context?.calendarName
        if let context {
            if let title = context.effectiveTitle {
                customTitle = title
            }
            recordingOrigin = context.recordingOrigin
        }
    }

    var fallbackTitle: String {
        fallbackMeetingTitle(detectedApp: detectedApp, recordingOrigin: recordingOrigin)
    }

    var displayTitle: String {
        if let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return fallbackTitle
    }

    var hasMeaningfulDuration: Bool {
        durationSeconds >= 1
    }

    var formattedDuration: String {
        let total = Int(durationSeconds)
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }

    var participantSummary: String? {
        if let organizerName, !organizerName.isEmpty {
            return organizerName
        }
        return attendeeNames.first
    }
}

// MARK: - Dictionary words

@Model
final class DictionaryWord {
    var id: UUID
    var spoken: String       // what ASR produces
    var written: String      // what the user wants instead
    var createdAt: Date

    // Auto-learn tracking
    var correctedCount: Int          // times user made this correction
    var seenUncorrectedCount: Int    // times spoken appeared and user left it alone
    var isAutoLearned: Bool          // false = manually added (always applied)
    var isSuppressed: Bool           // user rejected this auto-correction
    var spokenIsRealWord: Bool       // tier 1 (non-word) vs tier 2 (real word)
    var lastSeenAt: Date

    init(
        id: UUID = UUID(),
        spoken: String,
        written: String,
        createdAt: Date = Date(),
        correctedCount: Int = 0,
        seenUncorrectedCount: Int = 0,
        isAutoLearned: Bool = false,
        isSuppressed: Bool = false,
        spokenIsRealWord: Bool = false,
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.spoken = spoken
        self.written = written
        self.createdAt = createdAt
        self.correctedCount = correctedCount
        self.seenUncorrectedCount = seenUncorrectedCount
        self.isAutoLearned = isAutoLearned
        self.isSuppressed = isSuppressed
        self.spokenIsRealWord = spokenIsRealWord
        self.lastSeenAt = lastSeenAt
    }
}

// MARK: - Journal days

@Model
final class JournalDay {
    var id: UUID
    var date: Date
    var blocksJSON: Data     // [JournalBlock] encoded as JSON
    var summary: String?
    var narrativeBrief: String?
    var chatHistoryJSON: Data?   // [TodayChatMessage] encoded as JSON
    var generatedAt: Date

    init(id: UUID = UUID(), date: Date, blocksJSON: Data = Data(),
         summary: String? = nil, narrativeBrief: String? = nil,
         chatHistoryJSON: Data? = nil, generatedAt: Date = Date()) {
        self.id = id
        self.date = date
        self.blocksJSON = blocksJSON
        self.summary = summary
        self.narrativeBrief = narrativeBrief
        self.chatHistoryJSON = chatHistoryJSON
        self.generatedAt = generatedAt
    }

    var blocks: [JournalBlock] {
        (try? JSONDecoder().decode([JournalBlock].self, from: blocksJSON)) ?? []
    }

    func updateBlocks(_ blocks: [JournalBlock]) {
        blocksJSON = (try? JSONEncoder().encode(blocks)) ?? Data()
    }

    var chatHistory: [TodayChatMessage] {
        guard let data = chatHistoryJSON else { return [] }
        return (try? JSONDecoder().decode([TodayChatMessage].self, from: data)) ?? []
    }

    func updateChatHistory(_ messages: [TodayChatMessage]) {
        chatHistoryJSON = (try? JSONEncoder().encode(messages))
    }
}

struct TodayChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id: UUID = UUID()
    var role: Role
    var text: String
    var createdAt: Date = Date()
}

// MARK: - Ambient context snapshots

@Model
final class AmbientContextSnapshot {
    var id: UUID
    var timestamp: Date
    var appName: String
    var bundleId: String
    var windowTitle: String?
    var browserURL: String?
    var codeFileName: String?
    var slackRecipient: String?
    var focusedFieldContent: String?
    var visibleTextSnippetsJSON: String?
    var dwellDurationSeconds: Double?
    var clipboardText: String?
    var browserTabsJSON: String?          // JSON-encoded [String] of all open tab titles
    var notificationAppName: String?
    var notificationBundleId: String?
    var notificationTitle: String?
    var notificationBody: String?
    var notificationURL: String?
    var notificationReceivedAt: Date?

    init(id: UUID = UUID(), timestamp: Date, appName: String, bundleId: String,
         windowTitle: String? = nil, browserURL: String? = nil,
         codeFileName: String? = nil, slackRecipient: String? = nil,
         focusedFieldContent: String? = nil, visibleTextSnippetsJSON: String? = nil,
         dwellDurationSeconds: Double? = nil, clipboardText: String? = nil,
         browserTabsJSON: String? = nil,
         notificationAppName: String? = nil,
         notificationBundleId: String? = nil,
         notificationTitle: String? = nil,
         notificationBody: String? = nil,
         notificationURL: String? = nil,
         notificationReceivedAt: Date? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.codeFileName = codeFileName
        self.slackRecipient = slackRecipient
        self.focusedFieldContent = focusedFieldContent
        self.visibleTextSnippetsJSON = visibleTextSnippetsJSON
        self.dwellDurationSeconds = dwellDurationSeconds
        self.clipboardText = clipboardText
        self.browserTabsJSON = browserTabsJSON
        self.notificationAppName = notificationAppName
        self.notificationBundleId = notificationBundleId
        self.notificationTitle = notificationTitle
        self.notificationBody = notificationBody
        self.notificationURL = notificationURL
        self.notificationReceivedAt = notificationReceivedAt
    }

    var visibleTextSnippets: [String] {
        decodeJSONStringArray(visibleTextSnippetsJSON)
    }

    var browserTabs: [String] {
        decodeJSONStringArray(browserTabsJSON)
    }
}

// MARK: - Journal block (not a SwiftData model, used in JournalDay.blocksJSON)

struct BlockAppInfo: Codable {
    var appName: String
    var bundleId: String
    var entryCount: Int
    var wordCount: Int
}

struct JournalBlock: Codable, Identifiable {
    var id: UUID = UUID()
    var appName: String
    var bundleId: String
    var contextLabel: String?
    var entries: [String]    // text of each dictation in this block
    var startTime: Date
    var endTime: Date
    var summary: String?
    var wordCount: Int
    var appsUsed: [BlockAppInfo]?
    var topicLabel: String?
    var contextClues: [String]?
    var accomplishment: String?

    // Meeting support (optional for backward compat)
    var isMeeting: Bool?
    var meetingTitle: String?
    var meetingApp: String?
    var meetingDurationSeconds: Double?
}
